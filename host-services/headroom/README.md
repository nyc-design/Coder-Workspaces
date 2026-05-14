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

Compression is fully local (rule-based + the bundled
[RTK](https://github.com/rtk-ai/rtk) shell-output rewriter); no extra LLM
key required. The image we pull (`headroom-ai[proxy]`) does not include
LLMLingua-2 — rebuild from source with `[proxy,ml]` if you need it
(~700 MB extra).

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

## Telemetry

Off by default. Headroom exposes Prometheus metrics at `/metrics` if you
flip telemetry on.
