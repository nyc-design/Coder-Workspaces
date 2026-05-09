# codex-sidecar

OpenAI Responses-API-shaped HTTP front-end backed by
[codex-bridge](https://github.com/satriapamudji/codex-bridge), a single-file Node
proxy that forwards to `chatgpt.com/backend-api/codex/responses` using the user's
ChatGPT Plus/Pro Codex CLI OAuth credentials.

Coder Agents' OpenAI provider points at this sidecar (via Headroom) instead of
`api.openai.com`. Coder Agents already calls `WithUseResponsesAPI()` on the OpenAI
provider, so the protocol matches.

## Auth bootstrap

There is no `setup-token` equivalent for Codex — you must run an interactive
login. The image bakes the official `@openai/codex` CLI so the login can run
inside the container, with credentials landing in the persisted volume:

```bash
docker exec -it coder-agents-sidecars codex login
# → prints a URL, opens browser, paste code back; writes /data/auth/codex/auth.json
docker restart coder-agents-sidecars
```

`CODEX_HOME` is preset to `/data/auth/codex` and that path is on the
`coder-agents-sidecars-auth` named volume — credentials survive container
restarts and image upgrades.

codex-bridge reads `auth.json` on each request, checks JWT expiry, and refreshes
against `auth.openai.com/oauth/token` using the Codex `client_id`, writing the
new token back into the file.

### Refresh failure mode

If long-idle (weeks) the refresh token may expire and the sidecar will start
returning 401s. Fix: `codex login` on the host again. Plan on a re-auth cadence
of every ~30 days for safety.

## Endpoints

- `POST /v1/responses` — OpenAI Responses API (streaming SSE supported)
- `GET  /v1/models` — model list (gpt-5-codex variants)
- `GET  /health` — liveness

## Passthrough

codex-bridge is pure HTTP passthrough — it does not invoke tools internally. Any
`tool_use`-shape blocks in the response stream flow back to the caller (Coder
Agents' chatd) for execution against the user's workspace.

## Multi-user / ToS

ChatGPT Plus/Pro ToS limits the subscription to personal use. Codex's account-tied
auth is even less amenable to multi-tenancy than Claude's — concurrent sessions
from one account hit weekly Codex caps fast (~300 messages/week historically).
Single-user only.
