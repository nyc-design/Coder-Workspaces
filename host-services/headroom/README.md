# headroom

[Headroom](https://github.com/chopratejas/headroom) — local prompt
compression proxy for AI agent traffic. Compose-only service that pulls
the upstream image directly from GHCR. All routing is configured via env
vars in the compose snippet (no host-side config file).

## Routing

Headroom dispatches per request path to the matching upstream:

| Incoming path                                  | Upstream env var             | Resolves to        |
|------------------------------------------------|------------------------------|--------------------|
| `POST /v1/messages`                            | `ANTHROPIC_TARGET_API_URL`   | `meridian:3456`    |
| `POST /v1/responses`                           | `OPENAI_TARGET_API_URL`      | `cliproxy:8317`    |
| `POST /v1beta/models/{model}:generateContent`  | `GEMINI_TARGET_API_URL`      | `cliproxy:8317`    |
| `POST /v1internal:streamGenerateContent`       | `CLOUDCODE_TARGET_API_URL`   | `cliproxy:8317`    |

Compression is local: ContentRouter pipeline (SmartCrusher for JSON,
CodeCompressor for AST, Kompress for prose) plus tool-result
interceptors. No external LLM key required.

**RTK clarification:** The full RTK shell-output rewriter only fires in
`headroom wrap` mode (CLI tool wrapping). In proxy mode (what we run),
only generic tool-result interceptors run — they can rewrite shell tool
outputs but don't pull the full RTK pipeline. If you need RTK-grade
shell compression for an agent, run `headroom wrap` on the client side
instead of (or in addition to) the proxy.

LLMLingua-2 is not included in the upstream `[proxy]` image. Rebuild
from source with `[proxy,ml]` if you need neural compression (~700 MB).

## Auth

Headroom does **not** inject credentials — it forwards the client's
`Authorization` / `x-api-key` / `x-goog-api-key` headers untouched to the
upstream. Auth is the upstream's responsibility (cliproxy validates the
local API key; meridian validates against Claude OAuth).

## Optional bypass

Clients can pass `X-Headroom-Optimize: false` to bypass compression for a
single request (useful for debugging output diffs). Set
`HEADROOM_OPTIMIZE: "false"` env to disable compression server-wide while
keeping the routing proxy.

## State persistence

We deliberately do NOT set `HEADROOM_STATELESS=true` even though the
rest of the stack is fairly ephemeral. That flag disables all filesystem
writes — which would mean `proxy_savings.json` (the durable
compression-savings ledger) vanishes every restart, and `--memory` would
be useless. Instead we mount `/data` and set `HEADROOM_WORKSPACE_DIR=/data`
so the savings ledger, TOIN telemetry, subscription state, and license
cache survive image swaps from watchtower.

Files Headroom writes (verified in `headroom/paths.py:56-66`):

- `/data/proxy_savings.json` — cumulative tokens saved
- `/data/toin.json` — TOIN telemetry
- `/data/subscription_state.json` — Anthropic OAuth subscription window
- `/data/license_cache.json`
- `/data/memory.db` + `/data/memories/` — only when `--memory` is enabled

## Telemetry

Off by default (`HEADROOM_TELEMETRY=off`). Headroom exposes Prometheus
metrics at `/metrics` if you flip telemetry on — useful for tracking
compression ratios and per-route latency.
