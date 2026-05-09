# coder-agents-sidecars

Single OCI image that lets Coder Agents draw on **Claude Pro/Max**, **ChatGPT
Plus/Pro (Codex)**, and **Gemini Advanced** subscriptions instead of
pay-as-you-go API billing — with [Headroom](https://github.com/chopratejas/headroom)
local prompt compression in front of all three.

Published to GHCR by `.github/workflows/build-coder-agents-sidecars.yaml`:

```
ghcr.io/nyc-design/host-services/coder-agents-sidecars:latest
ghcr.io/nyc-design/host-services/coder-agents-sidecars:sha-<commit>
```

Multi-arch (`linux/amd64` + `linux/arm64`).

## What's inside

Three processes supervised by [s6-overlay v3](https://github.com/just-containers/s6-overlay):

```
                                ┌─► 127.0.0.1:3456 claude-sidecar    (Meridian + Claude SDK) ─► api.anthropic.com
:8787 (only exposed)            │
  └─► headroom (compress) ──────┤
                                │
                                └─► 127.0.0.1:8317 cliproxy-sidecar  (CLIProxyAPI: Codex + Gemini OAuth)
                                                                       ├─► chatgpt.com/backend-api/codex
                                                                       └─► generativelanguage.googleapis.com
```

| Provider Coder sees | Backed by sidecar | Underlying tool | Subscription |
|---|---|---|---|
| Anthropic | claude-sidecar | [Meridian](https://github.com/rynfar/meridian) + `@anthropic-ai/claude-code` SDK | Claude Pro/Max |
| OpenAI | cliproxy-sidecar | [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (Codex mode) | ChatGPT Plus/Pro |
| Google | cliproxy-sidecar | [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (Gemini mode) | Gemini Advanced |

CLIProxyAPI handles both Codex and Gemini OAuth from one process, dispatched by
path. Headroom routes per request path so Coder Agents only ever configures one
URL per provider — `http://coder-agents-sidecars:8787` — and Headroom forwards.
Compression is fully local (rule-based + ONNX `Kompress-base`, plus the bundled
[RTK](https://github.com/rtk-ai/rtk) for shell-output rewriting); no extra LLM
key required.

## Deploy

Append `docker-compose.snippet.yml` to whatever compose file already runs
`coder` on your host VM. Then:

```bash
# 1. Set required env in the host .env
cat >> .env <<EOF
SIDECAR_SHARED_API_KEY=$(openssl rand -hex 32)
CLAUDE_CODE_OAUTH_TOKEN=$(claude setup-token | tail -1)   # run on a host with claude CLI
EOF

# 2. Pull + start
docker compose pull coder-agents-sidecars
docker compose up -d coder-agents-sidecars

# 3. One-time interactive logins (browser-based, run from your laptop)
docker exec -it coder-agents-sidecars cli-proxy-api --auth-dir /data/auth/cliproxy --login codex
docker exec -it coder-agents-sidecars cli-proxy-api --auth-dir /data/auth/cliproxy --login gemini

# 4. Pick up the new credentials
docker restart coder-agents-sidecars

# 5. Smoke-test
curl -fsS http://localhost:8787/readyz   # 200 from Headroom = all three healthy
```

Credentials persist in the named volume `coder-agents-sidecars-auth` (mounted at
`/data/auth`) so steps 3-4 only run once.

## Wire into Coder Agents

In **Coder admin → Deployment → AI → Providers**, override base URL on each
provider you want to back with a subscription. **All three use the same URL +
key** — Headroom dispatches by request path automatically:

| Provider | Base URL (Coder admin) | API key (Coder admin) | Path Headroom dispatches on | Routed to |
|---|---|---|---|---|
| Anthropic | `http://coder-agents-sidecars:8787` | `SIDECAR_SHARED_API_KEY` | `/v1/messages` | claude-sidecar |
| OpenAI | `http://coder-agents-sidecars:8787` | `SIDECAR_SHARED_API_KEY` | `/v1/responses` | cliproxy-sidecar |
| Google | `http://coder-agents-sidecars:8787` | `SIDECAR_SHARED_API_KEY` | `/v1beta/models/{model}:generateContent` | cliproxy-sidecar |

The path column is informational — fantasy's provider libraries (which chatd
uses) automatically pre-pend the right path when given a base URL, so you don't
configure paths yourself. Each provider library is hard-wired to its own API
shape; the path divergence is what disambiguates routing.

Substitute `localhost` for `coder-agents-sidecars` if coderd isn't on the same
docker network. The OpenAI provider already calls `WithUseResponsesAPI()` by
default in chatd, so it correctly hits `/v1/responses` (not `/v1/chat/completions`).

To temporarily fall back to raw API billing for any provider, change its base
URL back to the vendor's URL in the admin UI — no container restart needed.

## Auth bootstrap details

| Provider | Headless? | Lifetime | Refresh |
|---|---|---|---|
| Claude | Yes — `claude setup-token` | ~1 year | Manual rotation |
| Claude (alt) | No (browser, in-container `claude login`) | 8h tokens, infinite refresh | Auto via SDK |
| Codex | No (browser, in-container `cli-proxy-api --login codex`) | ~30 days idle | Auto via CLIProxyAPI |
| Gemini | No (browser, in-container `cli-proxy-api --login gemini`) | Months–years if used regularly | Auto via CLIProxyAPI |

Per-provider specifics (token rotation, ToS notes, multi-account) in each
sidecar's `README.md`.

## Subscription constraints (read this)

This stack lets you spend subscription quota instead of API quota. It does not
make subscription quota infinite, and the providers police it.

- **Claude Pro/Max** is *personal use* per Anthropic ToS. Single user behind one
  Coder deployment is defensible. Multi-user team Coder fronted by one OAuth
  token is a clear violation and Anthropic detects it via concurrency
  heuristics. Don't.
- **ChatGPT Plus/Pro Codex** has tight weekly caps (~300 messages/week
  historically) and account-tied auth that's even less amenable to multi-tenancy.
- **Gemini Advanced** is the most generous of the three — but still personal-use.
- The Coder Agents loop fans out into many model invocations per user prompt
  (`spawn_agent` subagents, tool turns). Quota burns faster than running the
  bare CLI. Watch your usage dashboards for the first week.
- Anthropic's April 2026 enforcement specifically blocked OAuth-token-passthrough
  proxies. Meridian dodges this by going through the official Claude Code SDK
  (same fingerprint Anthropic ships and trusts). They could tighten further at
  any release; don't build anything you can't migrate off in a week.

## Compaction & usage limits

Coder Agents owns compaction (`coderd/x/chatd/chatloop/compaction.go`, default
70% threshold). Claude Code's built-in compaction never fires in this topology
because the SDK is invoked one turn at a time. Configure Coder Agents'
threshold and summary prompt admin-side; Claude Code's behavior is not inherited.

Coder Agents has its own per-user usage limits
(`coderd/x/chatd/usagelimit.go` — day/week/month token budgets). Stack any of
those on top of the upstream subscription quotas if you want guardrails.

## Operational notes

- All three processes are supervised by s6-overlay v3. If any one daemon dies it
  restarts in-place; the container stays up. Logs are interleaved on stdout
  with `[service-name]` prefixes from s6.
- Internal sidecars (Meridian, CLIProxyAPI) bind to `127.0.0.1` inside the
  container. Only Headroom listens on `0.0.0.0:8787`. Don't expose `8787`
  publicly without TLS + a real auth layer.
- `SIDECAR_SHARED_API_KEY` is a soft secret — it gates the network hop between
  Coder Agents and Headroom (and onwards to each sidecar). Treat as a regular
  shared API key.
- Each sidecar emits Prometheus metrics; Headroom does too at `/metrics`. Wire
  to your existing observability stack to monitor compression ratios and
  per-provider latency.
- The image rebuilds every push to `main` that touches this directory or the
  workflow file. Pin to a `:sha-<commit>` tag in production if you want to
  control upgrade timing.

## Repo layout

```
host-services/coder-agents-sidecars/
├── README.md                       # this file
├── Dockerfile                      # consolidated multi-process image
├── docker-compose.snippet.yml      # drop into host docker-compose
├── .env.example                    # required env vars
├── .gitignore
├── claude-sidecar/README.md        # Meridian / Claude Code SDK auth + ToS
├── cliproxy-sidecar/
│   ├── README.md                   # CLIProxyAPI: Codex + Gemini auth + multi-account
│   └── config.yaml                 # baked into image at /etc/coder-agents-sidecars/cli-proxy.yaml
├── headroom/README.md              # routing table + compression knobs
└── s6/                             # s6-overlay v3 service tree
    ├── user/contents.d/            # service registration
    ├── headroom/{run,type,dependencies.d/}
    ├── claude-sidecar/{run,type}
    └── cliproxy-sidecar/{run,type}
```

## Limitations / known gaps

- No automated test for end-to-end compaction × subscription-quota interaction.
  Recommend manual smoke-test after first deploy: kick off a long task, watch
  for failures around the compaction threshold.
- Codex and Gemini share one CLIProxyAPI process. A restart affects both
  providers. Acceptable for single-user; for multi-user with HA expectations
  you'd split into two cli-proxy-api processes.
- Coder Agents' `/api/experimental/chats/*` endpoints are explicitly experimental.
  Pin a known-good Coder version and treat each upgrade as a contract review.
- LLMLingua-2 (heavy-compression mode for Headroom) is intentionally not
  installed to keep the image lean. If you want it, rebuild the venv with
  `pip install 'headroom-ai[proxy,ml]'` and set `--llmlingua` in the headroom
  run script.
