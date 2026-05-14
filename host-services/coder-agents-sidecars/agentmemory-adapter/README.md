# AgentMemory MCP adapter

Coder-aware project-scope resolver that sits between the Coder Agents MCP
client and a (future) AgentMemory backend. Translates the ephemeral Coder
workspace UUID into a stable project key (e.g. `github:nyc-design/<repo>`)
so memory survives workspace recreate.

## Why an adapter

Memory keyed on Coder workspace UUID dies the moment the workspace is
recreated — even when the same human is working on the same repo. The
adapter resolves the workspace's `repo_name` build parameter via the Coder
API once, caches the result in-process, and exposes it to the MCP backend
as a stable scope.

## Mode: diagnostic-only

This release ships diagnostic mode only. The sole MCP tool is
`memory_scope`, which echoes the resolved project key plus the forwarded
Coder identity headers. The actual AgentMemory backend (iii-engine +
[`rohitg00/agentmemory`](https://github.com/rohitg00/agentmemory)) is not
wired in yet — that's the follow-up PR once we've verified header
forwarding works end-to-end in production.

## Env vars

| Var | Required | Default | Purpose |
|---|---|---|---|
| `AGENTMEMORY_MCP_API_KEY` | yes | — | Inbound bearer (Coder MCP client → adapter). Fetched from GCP Secret Manager `ai-sidecar-nt` by `bootstrap-secrets`. |
| `CODER_API_URL` | recommended | — | Base URL of the Coder deployment (e.g. `https://coder.example.com`). Set in container env via host `.env`. |
| `CODER_API_TOKEN` | recommended | — | Owner-scoped Coder API token. Fetched from `ai-sidecar-nt`. Without it, `project_key` falls back to `coder-workspace:<workspace-name>`. |
| `AGENTMEMORY_PROJECT_NAMESPACE` | no | `github:nyc-design` | Prefix for github-backed project keys. |
| `AGENTMEMORY_ADAPTER_HOST` | no | `0.0.0.0` | Bind address. |
| `AGENTMEMORY_ADAPTER_PORT` | no | `8789` | Bind port. |
| `AGENTMEMORY_CACHE_TTL` | no | `300` | Per-workspace scope cache TTL (seconds). |
| `AGENTMEMORY_HTTP_TIMEOUT` | no | `5.0` | Coder API HTTP timeout (seconds). |

## Endpoints

| Path | Method | Purpose |
|---|---|---|
| `/mcp` | POST | MCP streamable_http JSON-RPC endpoint |
| `/healthz` | GET | Liveness probe with config snapshot |

## Resolution order

Per request, the adapter resolves `X-Coder-Workspace-Id` →  `project_key`:

1. Cache hit (TTL 5 min default) → return cached scope.
2. `GET /api/v2/workspaces/{id}` → `.name`, `.latest_build.id`.
3. `GET /api/v2/workspacebuilds/{build_id}/parameters` → find `repo_name`.
4. If found → `${AGENTMEMORY_PROJECT_NAMESPACE}/<repo_name>` (source: `build_param`).
5. Else if `.name` known → `coder-workspace:<workspace-name>` (source: `workspace_name`).
6. Else → `coder-workspace:<workspace-id>` (source: `id_only`).

Coder API failures are logged at WARN and degrade to step 5 or 6. The
adapter never errors out of memory operations — a degraded scope is
better than a refused tool call.

## Public URL

Traefik routes `https://llm.tapiavala.com/agentmemory/mcp` → adapter `/mcp`.
The `/agentmemory` prefix is stripped by middleware before forwarding.

## Local smoke test

```bash
# Inside the running container:
curl -sS -X POST http://127.0.0.1:8789/mcp \
  -H "Authorization: Bearer $AGENTMEMORY_MCP_API_KEY" \
  -H "X-Coder-Workspace-Id: <some-real-uuid>" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"memory_scope"}}' \
  | jq .
```

Expected `result.content[0].text` is a JSON blob with the resolved
`project_key` and resolution `source`.
