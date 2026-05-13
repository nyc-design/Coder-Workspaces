# headroom

Single Headroom instance ([chopratejas/headroom](https://github.com/chopratejas/headroom))
sitting in front of the two sidecars. Compresses prompts, tool outputs, and
conversation history before forwarding upstream — fully local (rule-based + ONNX
`Kompress-base`, plus the bundled [RTK](https://github.com/rtk-ai/rtk) for
recognized shell-output rewriting). No LLM API key required.

## Routing

Headroom dispatches per request path to the matching upstream (loopback inside
the container — only Headroom's `:8787` is exposed):

| Incoming path | Upstream env var | Resolves to (loopback) |
|---|---|---|
| `POST /v1/messages` | `ANTHROPIC_TARGET_API_URL` | `http://127.0.0.1:8788` (dispatcher → meridian / cliproxy / kirocc) |
| `POST /v1/responses` | `OPENAI_TARGET_API_URL` | `http://127.0.0.1:8317` (cliproxy-sidecar, Codex) |
| `POST /v1beta/models/{model}:generateContent` | `GEMINI_TARGET_API_URL` | `http://127.0.0.1:8317` (cliproxy-sidecar, Gemini) |
| `POST /v1internal:streamGenerateContent` | `CLOUDCODE_TARGET_API_URL` | `http://127.0.0.1:8317` (cliproxy-sidecar, Cloud Code Assist) |

Only `/v1/messages` now goes through the dispatcher — it parses the leading
`<prefix>/` on the request body's `model` field (`meridian/`, `subscription/`,
or `kiro/`) and picks the right Claude upstream. `/codex` and `/gemini` go
straight to CLIProxy because each has only one upstream and one model namespace.
`/openai` (OpenAI-compatible chat completions for Groq/Cerebras/Codestral/Zen)
bypasses Headroom entirely — Traefik routes those requests directly to the
dispatcher on `:8788`.

Traefik in front of this image strips `/claude/`, `/codex/`, `/gemini/` prefixes
before forwarding so Headroom only ever sees the native API paths above. Coder
Agents (and any other client) configures distinct subpath URLs on
`https://llm.tapiavala.com/{claude,codex,gemini}` while Headroom stays
prefix-naive — clean separation between transport routing and protocol routing.

## Compression knobs

Defaults baked into the image:

- `HEADROOM_MODE=token` — token-budget-aware compression
- LLMLingua-2 disabled (image installs `headroom-ai[proxy]`, not `[ml]`).
  Rebuild with `[proxy,ml]` and set `--llmlingua` to enable it (~700MB extra)
- `HEADROOM_STATELESS=true` — no fs writes, safe for ephemeral containers
- RTK shell-output rewriting always-on (bundled in Headroom by default)

To tune: see [Headroom proxy docs](https://github.com/chopratejas/headroom/blob/main/docs/content/docs/proxy.mdx).

## Auth

Headroom does **not** inject credentials — it forwards the client's
`Authorization` / `x-api-key` / `x-goog-api-key` headers untouched to the upstream
sidecar. Auth is the sidecar's responsibility.

## Disabling compression for a specific request

Clients can pass `X-Headroom-Optimize: false` to bypass compression for one
request (useful for debugging output diffs). Or set `--no-optimize` server-wide
via env to disable Headroom entirely while keeping it as a routing proxy.

## Telemetry

Off by default (`HEADROOM_TELEMETRY=off`). Headroom exposes Prometheus metrics
at `/metrics` if you want to scrape compression ratios and per-route latency.
