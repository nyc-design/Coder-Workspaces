# omniroute

[OmniRoute](https://github.com/diegosouzapw/OmniRoute) — multi-provider AI
gateway with smart routing, automatic fallback, and Kiro support
(AWS Builder ID + IDC + social OAuth). Compose-only service that pulls
the upstream image directly from Docker Hub
(`diegosouzapw/omniroute:latest`).

## Role in the topology

OmniRoute is the **single provider router** for every protocol shape that
hits the stack. Headroom forwards all compressed traffic here, and
OmniRoute dispatches based on the requested model:

```
client → Traefik /headroom/* → headroom :8787 → omniroute :20128
                                                    │
                                                    ├─→ meridian :3456
                                                    │   (claude-* models, Claude Code SDK,
                                                    │    backed by Pro/Max OAuth)
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
| Dashboard at `/omniroute`      | n/a       | Routing rules ("combos"), models, prompts, OAuth login flows, internal-upstream wiring |
| `config/payloadRules.json`     | JSON      | Per-model upstream payload field injection/removal (narrow scope)    |

There is **no general-purpose YAML/JSON config** for providers, keys, or
routing rules — those split between env vars (direct-key providers) and
the dashboard-backed encrypted SQLite db.

## What's git-managed via this snippet

- `STORAGE_ENCRYPTION_KEY` — encrypts the entire SQLite db at rest.
  **Required.** Generate with `openssl rand -hex 32`. Store in GCP Secret
  Manager and pull into `.env` like any other secret.
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
  `https://llm.tapiavala.com/omniroute`.

## Wiring recipe (one-time, via dashboard or POST /api/v1/providers)

After first start, register the four internal upstreams. OmniRoute has
purpose-built provider classes for each:

| Backend | OmniRoute provider ID prefix | `provider_specific_data.baseUrl` | apiType / mode |
|---|---|---|---|
| meridian (Anthropic Messages) | `anthropic-compatible-cc-meridian` | `http://meridian:3456/v1` | n/a |
| meridian (OpenAI alias)       | `openai-compatible-meridian-oai`   | `http://meridian:3456/v1` | `chat` |
| cliproxy (Codex Responses)    | `openai-compatible-cliproxy-resp`  | `http://cliproxy:8317/v1` | `responses` |
| cliproxy (Gemini)             | use built-in `gemini` provider     | n/a (set upstream-proxy mode) | `cliproxyapi` mode via `PUT /api/upstream-proxy/gemini {mode: "cliproxyapi"}` |

The `anthropic-compatible-cc-` prefix uses Claude Code-style headers,
which is what meridian expects (verified in
`open-sse/services/provider.ts:18`). For Gemini, OmniRoute has
**built-in cliproxyapi upstream-proxy mode** that points the gemini
provider at cliproxy on port 8317 (`src/lib/db/upstreamProxy.ts:36`) —
no separate provider registration needed.

For cliproxy auth, configure the API key as the value of `CLIPROXY_API_KEY`
when registering each cliproxy-backed provider, so OmniRoute presents it
on every upstream call.

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

| Path inside container | Volume            | Contents                                                                         |
|-----------------------|-------------------|----------------------------------------------------------------------------------|
| `/app/data`           | `omniroute-data`  | Encrypted SQLite db: provider configs, OAuth tokens, routing combos, models, logs |

OmniRoute is **SQLite-only** — `package.json` ships `better-sqlite3` and
no Postgres/MySQL driver. `src/lib/db/AGENTS.md` explicitly states
"SQLite over PostgreSQL: simpler deployment, no separate database server".
External Postgres (Neon, Cloud SQL, etc.) would require a fork.

Watchtower upgrades preserve everything via the volume. **Back this volume
up** — losing it means re-bootstrapping every provider OAuth flow,
re-registering meridian/cliproxy, and re-creating every routing combo.

## Bootstrap

1. Set `OMNIROUTE_STORAGE_ENCRYPTION_KEY` in host `.env` (and any
   direct-key API keys you want pre-loaded).
2. `docker compose up -d omniroute`.
3. Visit `https://llm.tapiavala.com/omniroute` and complete dashboard setup.
4. Register internal upstreams: meridian (Anthropic + OpenAI alias) and
   cliproxy (Responses + Gemini-via-upstream-proxy). See "Wiring recipe"
   above.
5. Confirm Compression Settings master switch is OFF.
6. Configure model aliases and combos so requests for `claude-*` go to
   meridian, `gpt-*` go to cliproxy Codex, `gemini-*` go to cliproxy
   Gemini, etc.

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
