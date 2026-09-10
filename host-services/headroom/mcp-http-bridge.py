"""Private Streamable HTTP retrieval adapter; uses the proxy's CCR store."""
import os
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
        allowed_hosts=["headroom:*", "localhost:*", "127.0.0.1:*"],
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

mcp.run(transport="streamable-http")
