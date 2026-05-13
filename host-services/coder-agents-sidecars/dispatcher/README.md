# Dispatcher

Single ASGI app (`dispatcher.py`) that fronts two API shapes on
`127.0.0.1:8788` and forwards requests to one of several upstreams based on a
routing prefix in the request body's `model` field.

## Why

Coder Agents (and any `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` consumer) only
supports one base URL and one API key per provider. We want a single URL +
single shared bearer to fan out to multiple subscription-auth backends
(Meridian / CLIProxy / kirocc) and multiple pay-as-you-go backends (Groq /
Cerebras / Codestral / Zen) — without leaking individual provider keys to the
client.

## Routing

| Inbound path | Model prefix | Upstream |
|---|---|---|
| `/v1/messages` | `meridian/claude-*` | Meridian @ `127.0.0.1:3456` (Claude Code OAuth) |
| `/v1/messages` | `subscription/claude-*` | CLIProxyAPI @ `127.0.0.1:8317` (`--login claude`) |
| `/v1/messages` | `kiro/claude-*` | kirocc @ `127.0.0.1:9090` (Kiro Builder ID) |
| `/v1/chat/completions` | `groq/*` | `https://api.groq.com/openai` |
| `/v1/chat/completions` | `cerebras/*` | `https://api.cerebras.ai` |
| `/v1/chat/completions` | `codestral/*` | `https://codestral.mistral.ai` |
| `/v1/chat/completions` | `zen/*` | `https://opencode.ai/zen` |

The prefix is **stripped** before forwarding: e.g. a client sending
`model: "groq/llama-3.3-70b-versatile"` causes the dispatcher to send
`model: "llama-3.3-70b-versatile"` upstream.

## Auth

- **Inbound:** every request must bear `Authorization: Bearer
  $SIDECAR_SHARED_API_KEY` (or the same value under `x-api-key`).
- **Internal upstreams** (Meridian / CLIProxy / kirocc): the shared bearer is
  forwarded as-is; those sidecars gate on the same key.
- **External upstreams**: the shared bearer is dropped and replaced with the
  per-provider credential loaded from `/run/coder-agents-sidecars/secrets.env`
  at startup. Clients never see those keys.

## Bootstrap

`bootstrap_secrets.py` runs once as an s6 oneshot before any longrun starts.
It authenticates to GCP Secret Manager using
`$GOOGLE_APPLICATION_CREDENTIALS_JSON` (a service-account JSON, raw or
base64-encoded — the SA needs `secretmanager.secretAccessor` on
`projects/ai-sidecar-nt`) and writes `secrets.env` to `/run`. All longruns
source that file in their s6 `run` scripts.

If any secret is missing or still set to the literal `REPLACE_ME` placeholder,
the bootstrap fails and the container does not start serving.

## Endpoints

- `POST /v1/messages` — Anthropic Messages API
- `POST /v1/chat/completions` — OpenAI-compatible chat completions
- `GET /healthz` — liveness probe (no auth required)

Streaming (`stream: true`) bodies are pass-through; no buffering.
