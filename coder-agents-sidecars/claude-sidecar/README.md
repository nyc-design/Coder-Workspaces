# claude-sidecar

Anthropic-API-shaped HTTP front-end backed by [Meridian](https://github.com/rynfar/meridian),
which routes requests through the official `@anthropic-ai/claude-code` SDK so they
fingerprint as Claude Code at Anthropic and draw on Pro/Max subscription quota.

Coder Agents' Anthropic provider points at this sidecar (via Headroom) instead of
`api.anthropic.com`.

## Auth bootstrap

Two supported flows. Pick one, do **not** combine them.

### Option A — long-lived OAuth token (recommended for sidecars)

On any host with `claude` CLI installed and logged in:

```bash
claude setup-token
# → prints a long-lived token (sk-ant-oat01-...)
```

Put the token in `coder-agents-sidecars/.env`:

```
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
```

The compose file passes it into a `MERIDIAN_PROFILES` JSON block. No volume mount
needed — Meridian uses an isolated `CLAUDE_CONFIG_DIR` and never writes to disk.
Token rotation: re-run `claude setup-token` and update `.env`. ~1-year lifetime.

### Option B — full credentials directory (mount `~/.claude`)

If you want token *refresh* (8h cycles instead of manual rotation), mount the host's
`~/.claude/` directory. Run `claude login` on the host first to seed credentials,
then enable the volume in `docker-compose.yml`:

```yaml
volumes:
  - ${CLAUDE_HOME:-~/.claude}:/home/sidecar/.claude
```

Container UID is `1000` — match the host owner of `.credentials.json` or refresh
writes will fail silently. If your host user is not UID 1000, either chown the
mount or rebuild with `--build-arg UID=<your uid>`.

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
