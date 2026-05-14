# meridian

[Meridian](https://github.com/rynfar/meridian) — Claude Pro/Max
subscription proxy. Translates standard Anthropic Messages API requests
into official Claude Code SDK calls, so any tool that takes an
`ANTHROPIC_BASE_URL` can draw on subscription quota instead of
pay-as-you-go API billing.

Compose-only service that pulls the upstream image directly from GHCR
(`ghcr.io/rynfar/meridian:latest`).

## Role in the topology

Meridian is **internal-only** in our stack. Only OmniRoute reaches it —
no Traefik labels, no public URL. Public traffic flows:

```
client → headroom → omniroute → meridian → api.anthropic.com
```

OmniRoute registers meridian as `anthropic-compatible-cc-meridian`
(verified in `open-sse/services/provider.ts:18`) — that prefix uses
Claude Code-style headers, which is what meridian expects.

The internal-only posture is also defense-in-depth: the long-lived
`CLAUDE_CODE_OAUTH_TOKEN` only travels over the docker network, never
through Traefik or out to the internet on the inbound side.

## Endpoints (from inside the docker network)

- `POST /v1/messages` — Anthropic Messages API (streaming SSE supported)
- `POST /v1/chat/completions` — OpenAI-compat alias
- `GET  /v1/models` — model list
- `GET  /health` — liveness with auth status

Reach via `http://meridian:3456` from any other container on the same
docker network. From the host, `docker exec -it meridian curl ...` works
for diagnostics.

## Auth

Headless OAuth via long-lived token from `claude setup-token`. Generate
on a host with `claude` CLI installed and logged into the **dedicated
meridian Anthropic account** (keep separate from your dev-machine Claude
Code OAuth to avoid refresh cycle conflicts):

```bash
claude setup-token
# → prints sk-ant-oat01-...
```

Set in the host `.env` as `CLAUDE_CODE_OAUTH_TOKEN`. The compose snippet
wraps it into Meridian's native `MERIDIAN_PROFILES` JSON shape inline,
which is the supported way per upstream docs:

```yaml
MERIDIAN_PROFILES: '[{"id":"default","oauthToken":"${CLAUDE_CODE_OAUTH_TOKEN}"}]'
MERIDIAN_DEFAULT_PROFILE: default
```

Not setting `MERIDIAN_PROFILES` and only providing `CLAUDE_CODE_OAUTH_TOKEN`
is NOT enough — the SDK's 401-recovery would otherwise look at
`/home/claude/.claude` credentials that don't exist in this image.

~1 year lifetime; refresh by re-running `claude setup-token`, updating
`.env`, and `docker restart meridian`.

The named `meridian-data` volume preserves per-profile SDK session state
at `/home/claude/.config/meridian/profiles/default/` across image swaps,
so watchtower upgrades don't reset conversation continuity. The OAuth
token itself is delivered via env (never written to disk) so rotation is
just a `docker restart`.

## Inbound auth (`MERIDIAN_API_KEY`)

Meridian's optional API key middleware (`src/proxy/auth.ts`) gates
`/v1/*` and `/settings/*` when `MERIDIAN_API_KEY` is set in the env.
Callers must present a matching value via `x-api-key` or
`Authorization: Bearer`.

In our stack this is **always set**. Even though meridian has no Traefik
labels and is unreachable from outside the docker network, the API key
requirement adds defense-in-depth against any *other* container on the
same docker network accidentally hitting `http://meridian:3456` —
misconfigured agentmemory, a workspace that joins the host network, a
rogue debug script. Only OmniRoute should reach meridian, and OmniRoute
presents the key on every upstream call.

Generate with `openssl rand -hex 32` and set the **same value** in two
places:

1. Host `.env` as `MERIDIAN_API_KEY` — picked up by the compose snippet
   and read by meridian on startup.
2. The meridian provider entry in the OmniRoute dashboard — OmniRoute
   presents this on every outbound call to `http://meridian:3456`.

Rotation is `openssl rand`, update both places, `docker restart meridian`.
Mismatch shows up immediately as 401 in OmniRoute logs.

## Passthrough mode

`MERIDIAN_PASSTHROUGH=1` is set so tool_use blocks flow back to the caller
(through OmniRoute, then Headroom, then to the originating workspace)
instead of being executed inside the container. Do not unset — internal
execution would run tools against the meridian container's filesystem,
not the calling workspace.

## ToS reminder

Claude Pro/Max ToS limits subscription use to personal use. Single user
behind one Coder deployment is defensible; fronting a multi-user team
with one OAuth token is a clear violation and Anthropic detects it via
volume/concurrency heuristics.
