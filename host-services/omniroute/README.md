# omniroute

[OmniRoute](https://github.com/diegosouzapw/OmniRoute) — multi-provider AI
gateway with smart routing, automatic fallback, and Kiro support
(AWS Builder ID + IDC + social OAuth). Compose-only service that pulls
the upstream image directly from Docker Hub
(`diegosouzapw/omniroute:latest`).

## Public dashboard host

Use `https://omniroute.tapiavala.com/`, not
`https://llm.tapiavala.com/omniroute/`. OmniRoute is a Next.js app that
redirects `/` to `/dashboard` and uses root-relative routes such as
`/dashboard`, `/api`, and `/v1`. A Traefik path-prefix mount can strip the
initial `/omniroute`, but it cannot safely rewrite every root-relative
redirect, asset, API, and websocket URL emitted by the app. A dedicated
subdomain is the clean fix.

`https://llm.tapiavala.com/*` remains the client LLM entrypoint (root-mounted
Headroom, which forwards to this OmniRoute on the internal docker network);
`omniroute.tapiavala.com` is just the dashboard host.

## Role in the topology

OmniRoute is the **single provider router** for every protocol shape that
hits the stack. Headroom forwards all compressed traffic here, and
OmniRoute dispatches based on the requested model:

```
client → Traefik :443 (Host=llm.tapiavala.com) → headroom :8787 → omniroute :20128
                                                    │
                                                    ├─→ meridian :3456
                                                    │   (claude-* primary route, Claude Code SDK,
                                                    │    backed by Pro/Max OAuth)
                                                    │
                                                    ├─→ cliproxy :8317 /v1/messages
                                                    │   (claude-* fallback route, Claude Code OAuth)
                                                    │
                                                    ├─→ cliproxy :8317 /v1/responses
                                                    │   (gpt-* models, Codex subscription)
                                                    │
                                                    ├─→ cliproxy :8317 /v1beta/...
                                                    │   (gemini-* models, Gemini subscription)
                                                    │
                                                    ├─→ Kiro adapter
                                                    │   (kiro/* models, AWS Builder ID OAuth)
                                                    │
                                                    └─→ Groq, Cerebras, Mistral, etc.
                                                        (direct API keys via env)
```

This means three things:

- **Headroom is the only compression layer.** OmniRoute's built-in
  compression (RTK + Caveman) stays disabled — see "Compression" below.
- **meridian and cliproxy never face the public internet.** They have no
  Traefik labels; only OmniRoute reaches them over the docker network.
  Defense-in-depth for their long-lived OAuth credentials.
- **All routing logic lives in OmniRoute.** Want to swap which provider
  handles `claude-opus-4.5`? Edit a combo in the OmniRoute dashboard.
  No env-var changes, no container restarts elsewhere.

## Configuration surface

Verified against OmniRoute commit `41946c4`. There are three layers, in
order of stability:

| Layer                          | Format    | Scope                                                                |
|--------------------------------|-----------|----------------------------------------------------------------------|
| `.env` env vars                | dotenv    | Storage encryption, direct-key provider API keys, ports, OAuth client IDs |
| Dashboard at `omniroute.tapiavala.com`      | n/a       | Routing rules ("combos"), models, prompts, OAuth login flows, internal-upstream wiring |
| `config/payloadRules.json`     | JSON      | Per-model upstream payload field injection/removal (narrow scope)    |

There is **no general-purpose YAML/JSON config** for providers, keys, or
routing rules — those split between env vars (direct-key providers) and
the dashboard-backed encrypted SQLite db.

## What's git-managed via this snippet

- `JWT_SECRET` — signs dashboard session cookies. **Required.** Generate
  with `openssl rand -base64 48` and expose as `OMNIROUTE_JWT_SECRET` in
  the host `.env`.
- `API_KEY_SECRET` — encrypts dashboard-managed API key values in SQLite.
  **Required.** Generate with `openssl rand -hex 32` and expose as
  `OMNIROUTE_API_KEY_SECRET`.
- `INITIAL_PASSWORD` — initial dashboard admin password. **Required for
  reverse-proxied Docker/VM installs** because upstream auto-completes the
  unauthenticated onboarding wizard when this is set. Generate/store as
  `OMNIROUTE_INITIAL_PASSWORD`, then log in at `/login`.
- `STORAGE_ENCRYPTION_KEY` — encrypts the entire SQLite db at rest.
  **Required.** Generate with `openssl rand -hex 32`. Store in GCP Secret
  Manager and pull into `.env` like any other secret.
- `NEXT_PUBLIC_BASE_URL=https://omniroute.tapiavala.com` — public origin
  for dashboard links/OAuth callbacks.
- `AUTH_COOKIE_SECURE=true` — secure cookies behind Traefik HTTPS.
- Direct-key provider API keys — Groq, Cerebras, DeepSeek, xAI, Mistral,
  Perplexity, Together, Fireworks, Cohere, NVIDIA, Nebius. Set in `.env`
  to skip the dashboard bootstrap for each. Optional per-provider.

## What's still dashboard-managed (one-time bootstrap)

- **Internal upstreams (meridian + cliproxy)** — register via dashboard
  (Providers → Add) or `POST /api/v1/providers`. See "Wiring recipe" below.
- **OAuth providers** (Claude direct, Codex direct, Gemini direct, Kimi,
  Antigravity, Copilot, etc.) — OAuth client IDs/secrets can come from
  env vars but the actual handshake needs a browser. One-time per
  provider. **Note**: in our stack we route Claude/Codex/Gemini through
  meridian/cliproxy (subscription quotas), so direct OAuth on these is
  redundant unless you specifically want vendor-API fallback.
- **Routing rules ("combos"), model aliases, prompts, webhooks** — no
  file format. Configure in the dashboard at
  `https://omniroute.tapiavala.com`.

## Wiring recipe (one-time, via dashboard or POST /api/v1/providers)

After first start, register the four internal upstreams. OmniRoute has
purpose-built provider classes for each:

| Backend | OmniRoute provider ID prefix | `provider_specific_data.baseUrl` | apiType / mode |
|---|---|---|---|
| meridian (Anthropic Messages, primary) | `anthropic-compatible-cc-meridian` | `http://meridian:3456/v1` | n/a |
| meridian (OpenAI alias)       | `openai-compatible-meridian-oai`   | `http://meridian:3456/v1` | `chat` |
| cliproxy (Claude Messages, fallback) | `anthropic-compatible-cc-cliproxy-claude` | `http://cliproxy:8317/v1` | n/a |
| cliproxy (Codex Responses)    | `openai-compatible-cliproxy-resp`  | `http://cliproxy:8317/v1` | `responses` |
| cliproxy (Gemini)             | use built-in `gemini` provider     | n/a (set upstream-proxy mode) | `cliproxyapi` mode via `PUT /api/upstream-proxy/gemini {mode: "cliproxyapi"}` |

The `anthropic-compatible-cc-` prefix uses Claude Code-style headers,
which is what meridian expects (verified in
`open-sse/services/provider.ts:18`). For Gemini, OmniRoute has
**built-in cliproxyapi upstream-proxy mode** that points the gemini
provider at cliproxy on port 8317 (`src/lib/db/upstreamProxy.ts:36`) —
no separate provider registration needed.

For cliproxy auth, configure the API key as the value of `CLIPROXY_API_KEY`
when registering each cliproxy-backed provider (Claude fallback, Codex, and
Gemini upstream-proxy), so OmniRoute presents it on every upstream call.

## Compression: keep OmniRoute's pipeline OFF

OmniRoute ships a real compression engine (`open-sse/services/compression/`,
RTK + Caveman default pipeline). **We do not enable it.** Headroom is the
single compression layer for the stack.

Why never stack them:

- **Prompt-cache breakage** is the worst harm. OmniRoute's
  `cachingAware.ts` detects Anthropic `cache_control` markers to back
  off — but if Headroom rewrote text around those markers upstream,
  cached prefix hashes change and Anthropic prompt caches miss anyway.
- **Diminishing returns.** RTK regexes won't re-match Headroom-mangled
  text; Caveman would re-strip already-stripped content. The "78–95%"
  marketing number assumes one pass.
- **Token-budget miscounts.** Both layers re-estimate independently;
  analytics and cost accounting diverge.
- **Cumulative semantic loss.** Caveman's "respond in caveman-style"
  output mode on top of Headroom-mangled input is unpredictable.

Verify the master switch is **off** in dashboard → Compression Settings
on first bootstrap. (Default is off; this is just a sanity check.)

## Storage

| Path inside container | Host path                       | Contents                                                                         |
|-----------------------|---------------------------------|----------------------------------------------------------------------------------|
| `/app/data`           | `/opt/coder-stack/omniroute-data` | Encrypted SQLite db: provider configs, OAuth tokens, routing combos, models, logs |

**Bind mount, not a named volume.** The host directory must exist before
the first `docker compose up`:

```bash
sudo mkdir -p /opt/coder-stack/omniroute-data
```

If the container exits on first boot with a permission error, chown to
the UID OmniRoute runs as inside the container (the upstream image's
runuser; check with `docker logs omniroute` and
`docker exec omniroute id`). This is the chmod/chown dance you trade for
direct host visibility of the SQLite file — worth it for backup +
debug ergonomics.

OmniRoute is **SQLite-only** — `package.json` ships `better-sqlite3` and
no Postgres/MySQL driver. `src/lib/db/AGENTS.md` explicitly states
"SQLite over PostgreSQL: simpler deployment, no separate database server".
External Postgres (Neon, Cloud SQL, etc.) would require a fork.

Watchtower upgrades preserve everything via the bind mount. **Back this
directory up** (`/opt/coder-stack/omniroute-data`) — losing it means
re-bootstrapping every provider OAuth flow, re-registering
meridian/cliproxy, and re-creating every routing combo.

## Bootstrap

1. Create the data dir on the host:
   `sudo mkdir -p /opt/coder-stack/omniroute-data`.
2. Set the required OmniRoute secrets in host `.env`:
   `OMNIROUTE_JWT_SECRET`, `OMNIROUTE_API_KEY_SECRET`,
   `OMNIROUTE_INITIAL_PASSWORD`, and `OMNIROUTE_STORAGE_ENCRYPTION_KEY`
   (plus any direct-key API keys you want pre-loaded).
3. `docker compose up -d omniroute`. If it crashes with a permission
   error on `/app/data`, chown the host dir to the container's UID
   (see Storage section).
4. Visit `https://omniroute.tapiavala.com/login` and log in with
   `OMNIROUTE_INITIAL_PASSWORD`. Because this reverse-proxied deployment
   sets `INITIAL_PASSWORD`, upstream skips the unauthenticated onboarding
   wizard and marks setup complete automatically.
5. **Configure the client-facing API key** (Settings → Client API Keys,
   or equivalent in the dashboard). Use the value of `LLM_GATEWAY_API_KEY`
   from your `.env` (generate with `openssl rand -hex 32`). This is the
   key that external callers — Coder Agents, workspace CLIs, your laptop
   — must present. Without it OmniRoute will accept unauthenticated
   traffic from anyone who hits `https://omniroute.tapiavala.com`.
6. Register internal upstreams: meridian (Anthropic + OpenAI alias) and
   cliproxy (Claude fallback + Responses + Gemini-via-upstream-proxy). See "Wiring recipe"
   above. **For each, configure OmniRoute to present the matching
   per-upstream API key on outbound calls** — `MERIDIAN_API_KEY` on the
   meridian provider, `CLIPROXY_API_KEY` on the cliproxy provider. Same
   values that the upstream services validate inbound.
7. Confirm Compression Settings master switch is OFF.
8. Configure model aliases and combos so requests for `claude-*` go to
   meridian primary with cliproxy-Claude fallback, `gpt-*` go to cliproxy
   Codex, `gemini-*` go to cliproxy Gemini, etc.

## Auth model

Three independent API keys, three independent boundaries:

```
client ──[LLM_GATEWAY_API_KEY]──► omniroute ──[MERIDIAN_API_KEY]──► meridian
                                          ╰──[CLIPROXY_API_KEY]──► cliproxy
```

| Key                    | Source                       | Validated by              | Presented by                                 |
|------------------------|------------------------------|---------------------------|----------------------------------------------|
| `LLM_GATEWAY_API_KEY`  | host `.env`, into dashboard  | OmniRoute (dashboard config) | client (`x-api-key` / `Authorization: Bearer`) |
| `CLIPROXY_API_KEY`     | host `.env`                  | cliproxy (env-gated middleware) | OmniRoute (per-provider config in dashboard) |
| `MERIDIAN_API_KEY`     | host `.env`                  | meridian (`src/proxy/auth.ts` middleware) | OmniRoute (per-provider config in dashboard) |

Why three and not one shared key: if any one is compromised, the blast
radius is bounded. A leaked `LLM_GATEWAY_API_KEY` doesn't let the
attacker bypass OmniRoute to hit meridian directly; a compromised
upstream key doesn't expose the public gateway. OmniRoute is the only
component that ever sees all three.

## Endpoints

OmniRoute exposes the standard endpoints at port `20128` (NOT 3000 — the
default changed; verified in upstream `CLAUDE.md`):

- `POST /v1/messages` — Anthropic Messages (auto-converted via translator)
- `POST /v1/chat/completions` — OpenAI Chat
- `POST /v1/responses` — OpenAI Responses (Codex flows)
- `POST /v1beta/models/{model}:generateContent` — Gemini native
- `POST /v1internal:streamGenerateContent` — Cloud Code Assist (Antigravity, Pi)
- `GET /v1/models` — model list
- `GET /` — dashboard

All four protocol shapes work as inbound paths from Headroom; OmniRoute
normalizes through its translator pipeline (verified in
`open-sse/translator/index.ts:131-156`) and dispatches to the right
backend based on the model and any combo rules you've configured.
