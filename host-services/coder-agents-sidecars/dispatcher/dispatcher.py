"""Coder Agents Sidecar dispatcher.

Single ASGI app that fronts /v1/messages (Anthropic) and /v1/chat/completions
(OpenAI-compatible) on 127.0.0.1:8788. It parses the leading "<prefix>/" from
the request body's `model` field, strips it, and proxies the (possibly rewritten)
request to one of several upstreams.

Auth model:
  - All inbound requests carry `Authorization: Bearer SIDECAR_SHARED_API_KEY`.
  - For internal upstreams (Meridian / CLIProxy / kirocc on loopback), the same
    bearer is forwarded; those sidecars already gate on the shared key.
  - For external upstreams (Groq, Cerebras, Codestral, Zen, raw Anthropic), the
    inbound bearer is swapped for the provider-specific credential loaded from
    /run/coder-agents-sidecars/secrets.env at startup.

Routing table (model-prefix → upstream):
  meridian/claude-*       → http://127.0.0.1:3456  (Meridian + Claude Code SDK)
  subscription/claude-*   → http://127.0.0.1:8317  (CLIProxyAPI --login claude)
  kiro/claude-*           → http://127.0.0.1:9090  (kirocc, Kiro Builder ID)
  groq/*                  → https://api.groq.com/openai
  cerebras/*              → https://api.cerebras.ai
  codestral/*             → https://codestral.mistral.ai
  zen/*                   → https://opencode.ai/zen

`/v1/messages` accepts only the three claude-* lanes. `/v1/chat/completions`
accepts the four OpenAI-compat lanes.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from typing import Any

import httpx
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

logging.basicConfig(
    level=os.environ.get("DISPATCHER_LOG_LEVEL", "INFO"),
    format="%(asctime)s [dispatcher] %(levelname)s %(message)s",
)
log = logging.getLogger("dispatcher")

# --- Upstream descriptor ----------------------------------------------------


@dataclass(frozen=True)
class Upstream:
    """One destination the dispatcher can forward to."""

    base_url: str          # scheme + host + optional path prefix (no trailing /)
    auth_mode: str         # "shared" | "bearer" | "x-api-key"
    secret_env: str | None  # name of env var holding the upstream credential
    # Optional override for the request path that the upstream wants. None means
    # forward the inbound path unchanged (i.e. /v1/messages or /v1/chat/completions).
    path_override: str | None = None


# --- Routing table ----------------------------------------------------------

# /v1/messages — Anthropic Messages API. Three subscription-style upstreams.
MESSAGES_ROUTES: dict[str, Upstream] = {
    "meridian": Upstream(
        base_url="http://127.0.0.1:3456",
        auth_mode="shared",
        secret_env=None,
    ),
    "subscription": Upstream(
        base_url="http://127.0.0.1:8317",
        auth_mode="shared",
        secret_env=None,
    ),
    "kiro": Upstream(
        base_url="http://127.0.0.1:9090",
        auth_mode="shared",
        secret_env=None,
    ),
}

# /v1/chat/completions — OpenAI-compatible API. Four direct upstreams.
CHAT_ROUTES: dict[str, Upstream] = {
    "groq": Upstream(
        base_url="https://api.groq.com/openai",
        auth_mode="bearer",
        secret_env="GROQ_API_KEY",
    ),
    "cerebras": Upstream(
        base_url="https://api.cerebras.ai",
        auth_mode="bearer",
        secret_env="CEREBRAS_API_KEY",
    ),
    "codestral": Upstream(
        base_url="https://codestral.mistral.ai",
        auth_mode="bearer",
        secret_env="CODESTRAL_API_KEY",
    ),
    "zen": Upstream(
        base_url="https://opencode.ai/zen",
        auth_mode="bearer",
        secret_env="ZEN_API_KEY",
    ),
}

# --- Shared HTTP client -----------------------------------------------------

# Long timeout for streaming; httpx applies per-read, not per-request total.
HTTP_TIMEOUT = httpx.Timeout(connect=15.0, read=600.0, write=60.0, pool=15.0)
http_client = httpx.AsyncClient(timeout=HTTP_TIMEOUT, follow_redirects=False)

# Headers that must never be proxied: hop-by-hop per RFC 7230 plus the inbound
# Authorization (which we always rewrite).
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
    "authorization",
    "x-api-key",
}


def _strip_prefix(model: str) -> tuple[str | None, str]:
    """Return (prefix, remainder) for "prefix/rest"; (None, model) if no slash."""
    if "/" not in model:
        return None, model
    prefix, _, remainder = model.partition("/")
    if not prefix or not remainder:
        return None, model
    return prefix, remainder


def _build_auth_headers(upstream: Upstream) -> dict[str, str]:
    """Return the auth header(s) to use when calling `upstream`."""
    if upstream.auth_mode == "shared":
        # Internal sidecar — forward the shared key as a Bearer.
        key = os.environ.get("SIDECAR_SHARED_API_KEY", "")
        if not key:
            raise RuntimeError("SIDECAR_SHARED_API_KEY missing from environment")
        return {"authorization": f"Bearer {key}"}
    if upstream.secret_env is None:
        raise RuntimeError(f"upstream {upstream} has auth_mode={upstream.auth_mode} but no secret_env")
    secret = os.environ.get(upstream.secret_env, "")
    if not secret:
        raise RuntimeError(f"{upstream.secret_env} missing from environment")
    if upstream.auth_mode == "bearer":
        return {"authorization": f"Bearer {secret}"}
    if upstream.auth_mode == "x-api-key":
        return {"x-api-key": secret, "anthropic-version": "2023-06-01"}
    raise RuntimeError(f"unknown auth_mode: {upstream.auth_mode}")


def _filter_request_headers(headers: dict[str, str]) -> dict[str, str]:
    """Drop hop-by-hop and inbound auth headers from the request."""
    return {k: v for k, v in headers.items() if k.lower() not in HOP_BY_HOP}


def _filter_response_headers(headers: httpx.Headers) -> dict[str, str]:
    """Drop hop-by-hop headers from the upstream response."""
    out: dict[str, str] = {}
    for k, v in headers.items():
        if k.lower() in HOP_BY_HOP:
            continue
        out[k] = v
    return out


async def _proxy(
    request: Request,
    upstream: Upstream,
    body_bytes: bytes,
    target_path: str,
) -> Response:
    """Forward `body_bytes` to `upstream.base_url + target_path` and stream back."""
    target_url = upstream.base_url.rstrip("/") + target_path
    headers = _filter_request_headers(dict(request.headers))
    headers.update(_build_auth_headers(upstream))
    # Preserve content-type from inbound; httpx will set content-length from body.
    headers.setdefault("content-type", request.headers.get("content-type", "application/json"))

    req = http_client.build_request(
        request.method,
        target_url,
        params=request.query_params,
        headers=headers,
        content=body_bytes,
    )
    try:
        upstream_resp = await http_client.send(req, stream=True)
    except httpx.HTTPError as exc:
        log.warning("upstream %s unreachable: %s", target_url, exc)
        return JSONResponse(
            {"error": {"type": "upstream_unreachable", "message": str(exc)}},
            status_code=502,
        )

    async def body_iter():
        try:
            async for chunk in upstream_resp.aiter_raw():
                yield chunk
        finally:
            await upstream_resp.aclose()

    return StreamingResponse(
        body_iter(),
        status_code=upstream_resp.status_code,
        headers=_filter_response_headers(upstream_resp.headers),
    )


def _verify_inbound_auth(request: Request) -> JSONResponse | None:
    """Reject requests that don't bear the shared key."""
    expected = os.environ.get("SIDECAR_SHARED_API_KEY", "")
    if not expected:
        return JSONResponse(
            {"error": {"type": "server_misconfigured", "message": "SIDECAR_SHARED_API_KEY not loaded"}},
            status_code=500,
        )
    auth = request.headers.get("authorization", "")
    presented = auth[7:] if auth.lower().startswith("bearer ") else request.headers.get("x-api-key", "")
    # Constant-time compare to dodge timing oracles.
    import hmac
    if not presented or not hmac.compare_digest(presented, expected):
        return JSONResponse(
            {"error": {"type": "unauthorized", "message": "invalid bearer"}},
            status_code=401,
        )
    return None


def _parse_model(body_bytes: bytes) -> tuple[dict[str, Any], str | None, str | None]:
    """Return (parsed_body, prefix, stripped_model). All None on parse failure."""
    try:
        body = json.loads(body_bytes)
    except json.JSONDecodeError:
        return {}, None, None
    if not isinstance(body, dict):
        return {}, None, None
    model = body.get("model")
    if not isinstance(model, str):
        return body, None, None
    prefix, remainder = _strip_prefix(model)
    if prefix is None:
        return body, None, model
    return body, prefix, remainder


async def _dispatch(
    request: Request,
    routes: dict[str, Upstream],
    api_label: str,
) -> Response:
    """Common /v1/messages and /v1/chat/completions handler."""
    rejection = _verify_inbound_auth(request)
    if rejection is not None:
        return rejection

    body_bytes = await request.body()
    body, prefix, stripped_model = _parse_model(body_bytes)
    if prefix is None:
        return JSONResponse(
            {
                "error": {
                    "type": "invalid_request_error",
                    "message": (
                        f"{api_label} requires a model with a routing prefix "
                        f"(one of: {sorted(routes)}). Got: {body.get('model')!r}"
                    ),
                }
            },
            status_code=400,
        )
    upstream = routes.get(prefix)
    if upstream is None:
        return JSONResponse(
            {
                "error": {
                    "type": "invalid_request_error",
                    "message": f"unknown routing prefix {prefix!r} for {api_label}. Known: {sorted(routes)}",
                }
            },
            status_code=400,
        )

    body["model"] = stripped_model
    rewritten = json.dumps(body, separators=(",", ":")).encode("utf-8")
    target_path = upstream.path_override or request.url.path
    return await _proxy(request, upstream, rewritten, target_path)


async def messages(request: Request) -> Response:
    return await _dispatch(request, MESSAGES_ROUTES, "/v1/messages")


async def chat_completions(request: Request) -> Response:
    return await _dispatch(request, CHAT_ROUTES, "/v1/chat/completions")


async def healthz(_request: Request) -> Response:
    return JSONResponse({"ok": True})


app = Starlette(
    debug=False,
    routes=[
        Route("/v1/messages", messages, methods=["POST"]),
        Route("/v1/chat/completions", chat_completions, methods=["POST"]),
        Route("/healthz", healthz, methods=["GET"]),
    ],
)


def main() -> None:
    import uvicorn

    host = os.environ.get("DISPATCHER_HOST", "127.0.0.1")
    port = int(os.environ.get("DISPATCHER_PORT", "8788"))
    uvicorn.run(app, host=host, port=port, log_level="info", access_log=False)


if __name__ == "__main__":
    main()
