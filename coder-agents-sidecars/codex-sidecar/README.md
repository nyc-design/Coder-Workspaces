# codex-sidecar

OpenAI Responses-API-shaped HTTP front-end backed by
[codex-bridge](https://github.com/satriapamudji/codex-bridge), a single-file Node
proxy that forwards to `chatgpt.com/backend-api/codex/responses` using the user's
ChatGPT Plus/Pro Codex CLI OAuth credentials.

Coder Agents' OpenAI provider points at this sidecar (via Headroom) instead of
`api.openai.com`. Coder Agents already calls `WithUseResponsesAPI()` on the OpenAI
provider, so the protocol matches.

## Auth bootstrap

There is no `setup-token` equivalent for Codex — you must run an interactive login
on the host once, then mount the resulting credentials.

On the host (with `codex` CLI installed):

```bash
codex login
# → opens browser, OAuth dance, writes ~/.codex/auth.json
```

Then in `coder-agents-sidecars/.env`:

```
CODEX_HOME=/path/to/your/.codex   # default: ~/.codex on the host
```

The compose file mounts `${CODEX_HOME}` into the container at `/home/sidecar/.codex`.
codex-bridge reads `auth.json`, checks JWT expiry on each request, and refreshes
against `auth.openai.com/oauth/token` using the Codex client_id, writing the new
token back to the file. Volume must be writable by container UID 1000.

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
