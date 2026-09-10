"""Private Streamable HTTP retrieval adapter; uses the proxy's CCR store."""
import os
import secrets
import uvicorn
import httpx
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations
from starlette.responses import JSONResponse

mcp = FastMCP(
    "headroom", host="0.0.0.0", port=8788,
    stateless_http=True, json_response=True,
    instructions="Use headroom_retrieve to recover original content from Headroom compression markers. Pass only the hash, not the entire marker. Delegation reports are preserved by the proxy.",
    transport_security=TransportSecuritySettings(
        allowed_hosts=["llm.tapiavala.com", "headroom:8788", "localhost:8788", "127.0.0.1:8788"],
        allowed_origins=["https://llm.tapiavala.com"],
    ),
)

@mcp.tool(annotations=ToolAnnotations(readOnlyHint=True, destructiveHint=False))
async def headroom_retrieve(hash: str, query: str | None = None) -> dict:
    """Recover the original behind <<ccr:HASH,...>> or hash=HASH. Optionally search with query."""
    payload = {"hash": hash}
    if query is not None:
        payload["query"] = query
    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.post(
            os.environ.get("HEADROOM_PROXY_URL", "http://127.0.0.1:8787") + "/v1/retrieve",
            json=payload,
        )
        response.raise_for_status()
        return response.json()

@mcp.custom_route("/healthz", methods=["GET"])
async def health(request):
    return JSONResponse({"status": "ok"})

class BearerAuth:
    """Authenticate every MCP HTTP method before dispatch; never trust forwarded identity."""

    def __init__(self, app, secret):
        self.app = app
        self.expected = ("Bearer " + secret).encode("utf-8")

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            path = scope["path"]
            # This bridge is also the public deny backend for upstream retrieval.
            if path.startswith("/v1/retrieve"):
                await JSONResponse({"error": "Not found"}, status_code=404)(scope, receive, send)
                return
            if path == "/mcp" or path.startswith("/mcp/"):
                values = [v for k, v in scope["headers"] if k.lower() == b"authorization"]
                if len(values) != 1 or not secrets.compare_digest(values[0], self.expected):
                    await JSONResponse({"error": "Unauthorized"}, status_code=401,
                                       headers={"WWW-Authenticate": "Bearer"})(scope, receive, send)
                    return
        await self.app(scope, receive, send)


secret = os.environ.get("HEADROOM_MCP_SECRET", "")
if not secret.strip():
    raise SystemExit("HEADROOM_MCP_SECRET is required")
uvicorn.run(BearerAuth(mcp.streamable_http_app(), secret), host="0.0.0.0", port=8788,
            proxy_headers=False)
