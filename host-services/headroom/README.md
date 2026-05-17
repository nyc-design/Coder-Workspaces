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
client → Traefik :443 (Host=llm.tapiavala.com) → headroom :8787 → omniroute :20128
                                                                      │
                                                                      ├─→ meridian (Claude Pro/Max)
                                                                      ├─→ cliproxy (Claude Code / Codex / Gemini OAuth)
                                                                      ├─→ Kiro (built-in)
                                                                      └─→ direct API providers
```

Headroom is **root-mounted** on `llm.tapiavala.com` — every protocol path
(`/v1/messages`, `/v1/chat/completions`, `/v1/responses`,
`/v1beta/models/{model}:generateContent`, `/v1internal:streamGenerateContent`)
hits Headroom first, gets compressed, and is forwarded to OmniRoute on the
internal docker network.

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

**Tool-result interceptors must be explicitly enabled.** Upstream
default is `intercept_tool_results: bool = False` (see
`headroom/config.py`). We set `HEADROOM_INTERCEPT_ENABLED="1"` in the
compose snippet to turn them on. Without that flag, ContentRouter
selects the no-op pipeline for nearly every tool-result content block —
which is the dominant content type in chatd-driven agent traffic.
Observed effect of leaving it default: 8/36 requests compressed, 0.2%
average savings, $0.00 compression dollar savings vs $0.55 prompt-cache
savings. The fix is one env var, not a behavior tradeoff.

**Prompt cache stays safe.** `PrefixFreezeConfig.enabled` is `True` by
default, so Headroom refuses to rewrite any portion of the request
covered by an Anthropic `cache_control` marker. Turning on tool-result
interceptors only widens what gets compressed in the *non-cached*
suffix (new user turns, fresh tool results). The 90% prefix-cache
discount is untouched.

**RTK clarification:** The full RTK shell-output rewriter only fires in
`headroom wrap` mode (CLI tool wrapping). In proxy mode (what we run),
only generic tool-result interceptors run — they can rewrite shell tool
outputs but don't pull the full RTK pipeline. `headroom wrap` is not
usable in our topology anyway, because chatd-based agents invoke tools
over MCP (the `execute` MCP tool) rather than shelling out to a
wrappable CLI. The chatd-architecture analogue of `headroom wrap` is
`distill` running inside the workspace — see
`workspace-images/base-dev/system_prompt.txt` for the agent-facing
guidance.

LLMLingua-2 is not included in the upstream `[proxy]` image. Rebuild
from source with `[proxy,ml]` if you need neural compression (~700 MB).
Not recommended on the shared Oracle VM (4 vCPU / 24 GB RAM): CPU
inference would contend with active workspaces, and prompt cache is
already capturing the bulk of available savings.


## Local stream-start prelude patch

This deployment still pulls `ghcr.io/chopratejas/headroom:latest`, but the
compose snippet bind-mounts `../headroom-patch/anyllm.py` over Headroom's
installed `headroom/backends/anyllm.py`. The patch emits an immediate empty
OpenAI `chat.completion.chunk` before opening the upstream streaming request.

Why: Coder chatd has a hard-coded 60 second stream startup guard. Long
Claude Code / Meridian / OmniRoute requests can exceed 60 seconds before the
provider yields its first real chunk, causing chatd to cancel and retry the
request. The empty chunk is parsed as a valid stream part, disarms chatd's
startup guard, and carries no user-visible content.

Build/test from the repo root:

```bash
docker compose -f host-services/headroom/docker-compose.snippet.yml config
python3 host-services/headroom-patch/test_stream_prelude.py
```

## Auth

Headroom is **transparent at this layer** — it does not validate or
inject any credentials of its own. It forwards the client's
`Authorization` / `x-api-key` / `x-goog-api-key` headers untouched to
OmniRoute. OmniRoute is where the actual gatekeeping happens:

- **Client-facing**: OmniRoute validates the inbound key against its
  configured `LLM_GATEWAY_API_KEY` (dashboard-backed).
- **Upstream-facing**: OmniRoute swaps in the matching per-upstream
  key (`MERIDIAN_API_KEY` for meridian, `CLIPROXY_API_KEY` for cliproxy)
  when dispatching, so the downstream service can validate the call.

Two important consequences:

1. Clients only see one credential boundary — the `LLM_GATEWAY_API_KEY`.
   They never need to know about `MERIDIAN_API_KEY` or `CLIPROXY_API_KEY`.
2. Headroom does not need any secrets in its `.env` — its `Authorization`
   header is forwarded verbatim. Adding key-handling here would just
   duplicate OmniRoute's gate.

See `host-services/omniroute/README.md` → "Auth model" for the full
three-key diagram.

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
