# headroom

Single Headroom instance ([chopratejas/headroom](https://github.com/chopratejas/headroom))
sitting in front of all three sidecars. Compresses prompts, tool outputs, and
conversation history before forwarding upstream — fully local (rule-based + ONNX
`Kompress-base`), no LLM API key required.

## Routing

Headroom dispatches per request path to the matching upstream:

| Incoming path | Upstream env var | Container | Default upstream |
|---|---|---|---|
| `POST /v1/messages` | `ANTHROPIC_TARGET_API_URL` | claude-sidecar | `http://claude-sidecar:3456` |
| `POST /v1/responses` | `OPENAI_TARGET_API_URL` | codex-sidecar | `http://codex-sidecar:8080` |
| `POST /v1beta/models/{model}:generateContent` | `GEMINI_TARGET_API_URL` | gemini-sidecar | `http://gemini-sidecar:8317` |
| `POST /v1internal:streamGenerateContent` | `CLOUDCODE_TARGET_API_URL` | gemini-sidecar | `http://gemini-sidecar:8317` |

Coder Agents admin UI sets one base URL per provider, all pointing at this one
Headroom (`http://headroom:8787`). Path routing happens automatically.

## Compression knobs

Defaults in `docker-compose.yml`:

- `HEADROOM_MODE=token` — token-budget-aware compression
- LLMLingua-2 disabled (set `HEADROOM_LLMLINGUA=1` to enable; pulls a torch model)
- `HEADROOM_STATELESS=true` — no fs writes, safe for ephemeral containers

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
