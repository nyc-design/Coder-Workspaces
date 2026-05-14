# omniroute

[OmniRoute](https://github.com/diegosouzapw/OmniRoute) — multi-provider AI
gateway with smart routing, automatic fallback, and Kiro support
(AWS Builder ID + IDC + social OAuth). Compose-only service that pulls
the upstream image directly from Docker Hub
(`diegosouzapw/omniroute:latest`).

## Configuration surface

Verified against OmniRoute commit `41946c4`. There are three layers, in
order of stability:

| Layer                          | Format    | Scope                                                                |
|--------------------------------|-----------|----------------------------------------------------------------------|
| `.env` env vars                | dotenv    | Storage encryption, direct-key provider API keys, ports, OAuth client IDs |
| Dashboard at `/omniroute`      | n/a       | Routing rules ("combos"), models, prompts, OAuth login flows         |
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

## What's still dashboard-managed

- OAuth providers (Claude, Codex, Gemini, Kimi, Antigravity, GitHub
  Copilot, GitLab Duo, Qoder) — OAuth client IDs/secrets can be env vars
  but the actual OAuth handshake needs browser. One-time per provider.
- Routing rules ("combos"), model selection, prompts, webhooks — no file
  format. Configure in the dashboard at `https://llm.tapiavala.com/omniroute`.

## Storage

| Path inside container | Volume            | Contents                                                                         |
|-----------------------|-------------------|----------------------------------------------------------------------------------|
| `/app/data`           | `omniroute-data`  | Encrypted SQLite db: provider configs, OAuth tokens, routing combos, models, logs |

OmniRoute is **SQLite-only** — `package.json` ships `better-sqlite3` and
no Postgres/MySQL driver. `src/lib/db/AGENTS.md` explicitly states
"SQLite over PostgreSQL: simpler deployment, no separate database server".
External Postgres (Neon, Cloud SQL, etc.) would require a fork.

Watchtower upgrades preserve everything via the volume. **Back this volume
up** — losing it means re-bootstrapping every provider OAuth flow and
re-creating every routing combo.

## Bootstrap

1. Set `OMNIROUTE_STORAGE_ENCRYPTION_KEY` in host `.env` (and any
   direct-key API keys you want pre-loaded)
2. `docker compose up -d omniroute`
3. Visit `https://llm.tapiavala.com/omniroute` and complete dashboard setup
4. Add OAuth providers via the UI (Kiro, Claude, etc.) — browser flow
5. Configure routing combos and policies

## Endpoints

OmniRoute exposes the standard OpenAI-compatible API at the root:

- `POST /v1/chat/completions`
- `POST /v1/messages` (Anthropic-shape, when configured)
- `GET  /v1/models`
- `GET  /` — dashboard
