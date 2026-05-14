"""AgentMemory MCP adapter — Coder-aware project-scope resolver.

Diagnostic-first MCP streamable_http server that translates the ephemeral
Coder workspace UUID (forwarded as X-Coder-Workspace-Id when the MCP server
registration sets forward_coder_headers=true) into a stable project key
(e.g. github:nyc-design/<repo>) so memory survives workspace recreate.

This release ships in diagnostic mode only: the sole tool is `memory_scope`,
which returns the resolved project key plus the forwarded Coder identity
headers. Once header forwarding + Coder API resolution is verified end-to-
end, follow-up work will add proxy-to-AgentMemory mode (forwarding upstream
MCP calls to a local iii-engine + agentmemory backend with the project key
injected as scope).

Endpoints:
  POST /mcp     — MCP streamable_http JSON-RPC endpoint
  GET  /healthz — liveness

Inbound auth:           Authorization: Bearer ${AGENTMEMORY_MCP_API_KEY}
Outbound (Coder API):   Coder-Session-Token: ${CODER_API_TOKEN}
"""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass
from typing import Any

import httpx
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

# ── protocol + server identity ───────────────────────────────────────────────

PROTOCOL_VERSION = "2025-06-18"
SERVER_NAME = "agentmemory-adapter"
SERVER_VERSION = "0.1.0"

# ── config from env ──────────────────────────────────────────────────────────

HOST = os.environ.get("AGENTMEMORY_ADAPTER_HOST", "0.0.0.0")
PORT = int(os.environ.get("AGENTMEMORY_ADAPTER_PORT", "8789"))

INBOUND_BEARER = os.environ.get("AGENTMEMORY_MCP_API_KEY", "").strip()
CODER_URL = os.environ.get("CODER_API_URL", "").rstrip("/")
CODER_TOKEN = os.environ.get("CODER_API_TOKEN", "").strip()

# Prefix for github-backed project keys. The workspace's `repo_name` build
# parameter is just the bare repo name; owner is configured once at deploy
# time so the project key shape is `github:<owner>/<repo>`.
PROJECT_NAMESPACE = os.environ.get(
    "AGENTMEMORY_PROJECT_NAMESPACE", "github:nyc-design"
).rstrip("/")

CACHE_TTL_SEC = int(os.environ.get("AGENTMEMORY_CACHE_TTL", "300"))
HTTP_TIMEOUT = float(os.environ.get("AGENTMEMORY_HTTP_TIMEOUT", "5.0"))

logging.basicConfig(
    level=os.environ.get("AGENTMEMORY_LOG_LEVEL", "INFO"),
    format="%(asctime)s [agentmemory-adapter] %(levelname)s %(message)s",
)
log = logging.getLogger("agentmemory-adapter")


# ── workspace → project_key resolver with TTL cache ──────────────────────────


@dataclass
class Scope:
    project_key: str
    workspace_name: str | None
    workspace_id: str
    repo_name: str | None
    source: str            # "build_param" | "workspace_name" | "id_only"
    resolved_at: float


_CACHE: dict[str, Scope] = {}
_HTTP: httpx.AsyncClient | None = None


def _http() -> httpx.AsyncClient:
    global _HTTP
    if _HTTP is None:
        _HTTP = httpx.AsyncClient(timeout=HTTP_TIMEOUT)
    return _HTTP


async def _coder_get(path: str) -> Any:
    if not (CODER_URL and CODER_TOKEN):
        raise RuntimeError("Coder API not configured (CODER_API_URL/CODER_API_TOKEN)")
    resp = await _http().get(
        f"{CODER_URL}{path}",
        headers={
            "Coder-Session-Token": CODER_TOKEN,
            "Accept": "application/json",
        },
    )
    resp.raise_for_status()
    return resp.json()


async def resolve_scope(workspace_id: str) -> Scope:
    """Return cached or freshly-resolved project scope for a Coder workspace.

    Never raises — falls back to coder-workspace:<workspace-name> if the
    workspace has no repo_name build parameter, or coder-workspace:<id> if
    the Coder API is unreachable / unconfigured.
    """
    now = time.time()
    cached = _CACHE.get(workspace_id)
    if cached and (now - cached.resolved_at) < CACHE_TTL_SEC:
        return cached

    workspace_name: str | None = None
    repo_name: str | None = None
    source = "id_only"

    if CODER_URL and CODER_TOKEN:
        try:
            ws = await _coder_get(f"/api/v2/workspaces/{workspace_id}")
            workspace_name = ws.get("name")
            build_id = (ws.get("latest_build") or {}).get("id")
            if build_id:
                params = await _coder_get(
                    f"/api/v2/workspacebuilds/{build_id}/parameters"
                )
                for p in params or []:
                    if p.get("name") == "repo_name" and p.get("value"):
                        repo_name = p["value"]
                        break
        except Exception as exc:
            log.warning("coder API lookup failed for %s: %s", workspace_id, exc)

    if repo_name:
        project_key = f"{PROJECT_NAMESPACE}/{repo_name}"
        source = "build_param"
    elif workspace_name:
        project_key = f"coder-workspace:{workspace_name}"
        source = "workspace_name"
    else:
        project_key = f"coder-workspace:{workspace_id}"
        source = "id_only"

    scope = Scope(
        project_key=project_key,
        workspace_name=workspace_name,
        workspace_id=workspace_id,
        repo_name=repo_name,
        source=source,
        resolved_at=now,
    )
    _CACHE[workspace_id] = scope
    return scope


# ── MCP JSON-RPC handlers ────────────────────────────────────────────────────

JSONRPC_PARSE_ERROR = -32700
JSONRPC_INVALID_REQUEST = -32600
JSONRPC_METHOD_NOT_FOUND = -32601
JSONRPC_INVALID_PARAMS = -32602
JSONRPC_INTERNAL_ERROR = -32603


def _err(req_id: Any, code: int, message: str, data: Any = None) -> dict[str, Any]:
    err: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return {"jsonrpc": "2.0", "id": req_id, "error": err}


def _ok(req_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


TOOLS: list[dict[str, Any]] = [
    {
        "name": "memory_scope",
        "description": (
            "Return the resolved project memory scope for the current Coder "
            "workspace. Diagnostic-only: verifies that Coder Agents is forwarding "
            "the X-Coder-Workspace-Id header and that the adapter can resolve it "
            "via the Coder API to a stable project key (e.g. github:owner/repo). "
            "Falls back to coder-workspace:<workspace-name> if the repo_name build "
            "parameter is missing. The full AgentMemory toolset replaces this in "
            "a follow-up release."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
]

# Methods that produce no response body (one-way notifications).
NOTIFICATIONS = {
    "notifications/initialized",
    "notifications/cancelled",
    "notifications/progress",
}


async def handle_initialize(req_id: Any, _params: dict[str, Any]) -> dict[str, Any]:
    return _ok(
        req_id,
        {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        },
    )


async def handle_tools_list(req_id: Any, _params: dict[str, Any]) -> dict[str, Any]:
    return _ok(req_id, {"tools": TOOLS})


async def handle_tools_call(
    req_id: Any,
    params: dict[str, Any],
    headers: dict[str, str],
) -> dict[str, Any]:
    name = params.get("name")
    if name != "memory_scope":
        return _err(req_id, JSONRPC_INVALID_PARAMS, f"unknown tool: {name!r}")

    workspace_id = (headers.get("x-coder-workspace-id") or "").strip()
    if not workspace_id:
        text = (
            "memory_scope: X-Coder-Workspace-Id header was not forwarded. "
            "Confirm that forward_coder_headers=true is set on the agentmemory "
            "MCP server registration and that the inbound chat has an attached "
            "Coder workspace."
        )
        return _ok(
            req_id,
            {
                "content": [{"type": "text", "text": text}],
                "isError": True,
            },
        )

    scope = await resolve_scope(workspace_id)
    payload = {
        "project_key": scope.project_key,
        "source": scope.source,
        "workspace_id": scope.workspace_id,
        "workspace_name": scope.workspace_name,
        "repo_name": scope.repo_name,
        "namespace": PROJECT_NAMESPACE,
        "owner_id": headers.get("x-coder-owner-id"),
        "chat_id": headers.get("x-coder-chat-id"),
        "subchat_id": headers.get("x-coder-subchat-id"),
        "coder_api_configured": bool(CODER_URL and CODER_TOKEN),
    }
    return _ok(
        req_id,
        {
            "content": [{"type": "text", "text": json.dumps(payload, indent=2)}],
            "isError": False,
        },
    )


async def dispatch(
    rpc: dict[str, Any], headers: dict[str, str]
) -> dict[str, Any] | None:
    method = rpc.get("method")
    req_id = rpc.get("id")
    params = rpc.get("params") or {}

    # Notifications have no `id` and expect no response.
    if method in NOTIFICATIONS or req_id is None:
        return None

    try:
        if method == "initialize":
            return await handle_initialize(req_id, params)
        if method == "tools/list":
            return await handle_tools_list(req_id, params)
        if method == "tools/call":
            return await handle_tools_call(req_id, params, headers)
        if method == "ping":
            return _ok(req_id, {})
        return _err(
            req_id, JSONRPC_METHOD_NOT_FOUND, f"method not found: {method}"
        )
    except Exception as exc:
        log.exception("dispatch error on method=%s", method)
        return _err(req_id, JSONRPC_INTERNAL_ERROR, "internal error", str(exc))


# ── HTTP layer ───────────────────────────────────────────────────────────────


async def mcp_endpoint(request: Request) -> Response:
    auth = request.headers.get("authorization", "")
    if not INBOUND_BEARER or auth != f"Bearer {INBOUND_BEARER}":
        return JSONResponse({"error": "unauthorized"}, status_code=401)

    try:
        body = await request.json()
    except Exception:
        return JSONResponse(
            _err(None, JSONRPC_PARSE_ERROR, "invalid JSON"),
            status_code=400,
        )

    # Case-insensitive header lookups downstream.
    headers = {k.lower(): v for k, v in request.headers.items()}

    # MCP messages are a single request or a batch (array). Notifications
    # produce no response; respond 202 if the whole batch was notifications.
    if isinstance(body, list):
        results: list[dict[str, Any]] = []
        for item in body:
            if not isinstance(item, dict):
                results.append(
                    _err(None, JSONRPC_INVALID_REQUEST, "expected object in batch")
                )
                continue
            resp = await dispatch(item, headers)
            if resp is not None:
                results.append(resp)
        if not results:
            return Response(status_code=202)
        return JSONResponse(results)

    if not isinstance(body, dict):
        return JSONResponse(
            _err(None, JSONRPC_INVALID_REQUEST, "expected object or array"),
            status_code=400,
        )

    resp = await dispatch(body, headers)
    if resp is None:
        return Response(status_code=202)
    return JSONResponse(resp)


async def healthz(_request: Request) -> Response:
    return JSONResponse(
        {
            "status": "ok",
            "server": SERVER_NAME,
            "version": SERVER_VERSION,
            "coder_api_configured": bool(CODER_URL and CODER_TOKEN),
            "namespace": PROJECT_NAMESPACE,
            "cached_workspaces": len(_CACHE),
        }
    )


app = Starlette(
    routes=[
        Route("/mcp", mcp_endpoint, methods=["POST"]),
        Route("/healthz", healthz, methods=["GET"]),
    ]
)


# ── main ─────────────────────────────────────────────────────────────────────


def main() -> None:
    if not INBOUND_BEARER:
        log.error(
            "AGENTMEMORY_MCP_API_KEY not set — refusing to start "
            "(inbound auth would always fail)"
        )
        raise SystemExit(1)
    if not (CODER_URL and CODER_TOKEN):
        log.warning(
            "Coder API not configured (CODER_API_URL=%r, CODER_API_TOKEN set=%s). "
            "memory_scope will fall back to coder-workspace:<id>. Populate "
            "CODER_API_TOKEN in GCP Secret Manager (ai-sidecar-nt) and restart "
            "to enable repo resolution.",
            CODER_URL,
            bool(CODER_TOKEN),
        )

    import uvicorn

    uvicorn.run(app, host=HOST, port=PORT, log_level="info")


if __name__ == "__main__":
    main()
