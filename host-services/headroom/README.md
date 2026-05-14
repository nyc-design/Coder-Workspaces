# headroom

[Headroom](https://github.com/chopratejas/headroom) — local prompt
compression proxy for AI agent traffic. Compose-only service that pulls
the upstream image directly from GHCR.

## Role in the topology

Headroom is the **single, centralized compression layer** for every
outbound LLM call in the stack. All four protocol shapes hit Headroom,
get compressed, and forward to OmniRoute, which handles the actual
provider routing.

```
client → Traefik /headroom/* → headroom :8787 → omniroute :20128
                                                    │
                                                    ├─→ meridian (Claude Pro/Max)
                                                    ├─→ cliproxy (Codex / Gemini OAuth)
                                                    ├─→ Kiro (built-in)
                                                    └─→ direct API providers
```

OmniRoute's own compression pipeline (RTK + Caveman) is left **disabled**
on purpose — stacking compressors corrupts Anthropic prompt-cache markers
and produces diminishing returns. See `host-services/omniroute/README.md`
for the full rationale.

## Routing (single-upstream)

Headroom dispatches per request path; in our setup all four point at
OmniRoute. OmniRoute then accepts each path natively and dispatches to
the right backend internally:

| Incoming path                                  | Headroom env var             | Resolves to        |
|------------------------------------------------|------------------------------|--------------------|
| `POST /v1/messages`                            | `ANTHROPIC_TARGET_API_URL`   | `omniroute:20128`  |
| `POST /v1/chat/completions` + `/v1/responses`  | `OPENAI_TARGET_API_URL`      | `omniroute:20128`  |
| `POST /v1beta/models/{model}:generateContent`  | `GEMINI_TARGET_API_URL`      | `omniroute:20128`  |
| `POST /v1internal:streamGenerateContent`       | `CLOUDCODE_TARGET_API_URL`   | `omniroute:20128`  |

(All four env vars are real and used; verified in
`headroom/providers/registry.py:97-106`. The official docs page omits
`CLOUDCODE_TARGET_API_URL` but the source reads it.)

## Compression details

ContentRouter pipeline (SmartCrusher for JSON, CodeCompressor for AST,
Kompress for prose) plus tool-result interceptors. No external LLM key
required.

**RTK clarification:** The full RTK shell-output rewriter only fires in
`headroom wrap` mode (CLI tool wrapping). In proxy mode (what we run),
only generic tool-result interceptors run — they can rewrite shell tool
outputs but don't pull the full RTK pipeline. If you need RTK-grade
shell compression for an agent, run `headroom wrap` on the client side
in addition to the proxy.

LLMLingua-2 is not included in the upstream `[proxy]` image. Rebuild
from source with `[proxy,ml]` if you need neural compression (~700 MB).

## Auth

Headroom does **not** inject credentials — it forwards the client's
`Authorization` / `x-api-key` / `x-goog-api-key` headers untouched to
OmniRoute, which validates them against its own configured providers
and forwards to the right upstream (which in turn validates against
its own credentials). Three layers of auth, but only one credential
boundary that clients see.

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
