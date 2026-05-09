# claude-sidecar

Anthropic-API-shaped HTTP front-end backed by [Meridian](https://github.com/rynfar/meridian),
which routes requests through the official `@anthropic-ai/claude-code` SDK so they
fingerprint as Claude Code at Anthropic and draw on Pro/Max subscription quota.

Coder Agents' Anthropic provider points at this sidecar (via Headroom) instead of
`api.anthropic.com`.

## Auth bootstrap

Two supported flows. Pick one, do **not** combine them.

### Option A — long-lived OAuth token (default in this image)

On any host with `claude` CLI installed and logged in:

```bash
claude setup-token
# → prints a long-lived token (sk-ant-oat01-...)
```

Put the token in the host's `.env`:

```
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
```

The s6 run script wraps it into a `MERIDIAN_PROFILES` JSON block at startup.
Meridian uses an isolated `CLAUDE_CONFIG_DIR=/data/auth/claude` and never falls
back to a `~/.claude` lookup. Token rotation: re-run `claude setup-token`,
update `.env`, `docker restart coder-agents-sidecars`. ~1-year lifetime.

### Option B — full credentials directory (8h refresh cycles)

If you want auto-refresh instead of manual rotation, complete an interactive
login inside the container so credentials land in the persisted volume:

```bash
docker exec -it coder-agents-sidecars claude login
# (browser-based; follow the printed URL)
```

The container's `CLAUDE_CONFIG_DIR` is `/data/auth/claude`, mapped to the
`coder-agents-sidecars-auth` named volume. Meridian will pick the credentials
up on the next request and refresh them in-place every ~8h.

If you set both `CLAUDE_CODE_OAUTH_TOKEN` and run `claude login`, the token
wins (the run script preferentially constructs `MERIDIAN_PROFILES` from the env
var). Unset the env var if you want the credentials-dir flow.

## Endpoints

- `POST /v1/messages` — Anthropic Messages API (streaming SSE supported)
- `POST /v1/chat/completions` — OpenAI-compat alias
- `GET  /v1/models` — model list
- `GET  /health` — liveness

## Passthrough mode

`MERIDIAN_PASSTHROUGH=1` is set so tool_use blocks flow back to the caller (Coder
Agents' chatd) instead of being executed inside the sidecar. Do not unset this —
internal execution would run tools against the *sidecar's* filesystem, not the user's
workspace.

## ToS reminder

Claude Pro/Max ToS limits subscription use to personal use. Single-user OK; fronting
a multi-user Coder deployment with one OAuth token is a clear violation and Anthropic
can detect it via volume/concurrency heuristics. See top-level README §"Subscription
constraints".
