# meridian

[Meridian](https://github.com/rynfar/meridian) — Claude Pro/Max
subscription proxy. Translates standard Anthropic Messages API requests
into official Claude Code SDK calls, so any tool that takes an
`ANTHROPIC_BASE_URL` can draw on subscription quota instead of
pay-as-you-go API billing.

Compose-only service that pulls the upstream image directly from GHCR
(`ghcr.io/rynfar/meridian:latest`).

## Endpoints

- `POST /v1/messages` — Anthropic Messages API (streaming SSE supported)
- `POST /v1/chat/completions` — OpenAI-compat alias
- `GET  /v1/models` — model list
- `GET  /health` — liveness with auth status

## Auth

Headless OAuth via long-lived token from `claude setup-token`. Generate on
a host with `claude` CLI installed and logged into the **dedicated meridian
Anthropic account** (keep separate from your dev-machine Claude Code OAuth
to avoid refresh cycle conflicts):

```bash
claude setup-token
# → prints sk-ant-oat01-...
```

Set in the host `.env` as `CLAUDE_CODE_OAUTH_TOKEN`. ~1 year lifetime;
refresh by re-running `claude setup-token`, updating `.env`, and
`docker restart meridian`.

The named `meridian-data` volume preserves SDK session cache across image
swaps, so watchtower upgrades don't reset conversation state or trigger
re-auth.

## Passthrough mode

`MERIDIAN_PASSTHROUGH=1` is set so tool_use blocks flow back to the caller
instead of being executed inside the container. Do not unset — internal
execution would run tools against the meridian container's filesystem,
not the calling workspace.

## ToS reminder

Claude Pro/Max ToS limits subscription use to personal use. Single user
behind one Coder deployment is defensible; fronting a multi-user team
with one OAuth token is a clear violation and Anthropic detects it via
volume/concurrency heuristics.
