# coder-agents-sidecars

Sidecars that let Coder Agents draw on **Claude Pro/Max**, **ChatGPT Plus/Pro
(Codex)**, and **Gemini Advanced** subscriptions instead of pay-as-you-go API
billing — with [Headroom](https://github.com/chopratejas/headroom) compression
in front of all three.

## Topology

```
                         ┌─► claude-sidecar :3456 ─► api.anthropic.com
coderd ─► headroom :8787 ┼─► codex-sidecar  :8080 ─► chatgpt.com/backend-api/codex
                         └─► gemini-sidecar :8317 ─► generativelanguage.googleapis.com
```

One Headroom instance routes per request path. Coder Agents sees three normal
provider endpoints; the rewriting and compression are invisible to it.

| Sidecar | Backed by | Subscription | Native shape |
|---|---|---|---|
| claude-sidecar | [Meridian](https://github.com/rynfar/meridian) + `@anthropic-ai/claude-code` SDK | Claude Pro/Max | Anthropic Messages API |
| codex-sidecar | [codex-bridge](https://github.com/satriapamudji/codex-bridge) | ChatGPT Plus/Pro | OpenAI Responses API |
| gemini-sidecar | [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) | Gemini Advanced (personal Google) | `generativelanguage` v1beta |

## Quick start

```bash
cd coder-agents-sidecars
cp .env.example .env
# Edit .env: set SIDECAR_SHARED_API_KEY and CLAUDE_CODE_OAUTH_TOKEN.

# Bootstrap Codex auth on the host (requires browser):
codex login                              # writes ~/.codex/auth.json
mkdir -p codex-sidecar/auth
cp -r ~/.codex/* codex-sidecar/auth/

# Bootstrap Gemini auth (one-time, requires browser):
mkdir -p gemini-sidecar/auth
docker run --rm -it \
  -v "$PWD/gemini-sidecar/auth:/data/auth" \
  eceasy/cli-proxy-api:latest \
  --auth-dir /data/auth --login gemini

docker compose up -d
docker compose ps                        # all four healthy
curl http://localhost:8787/readyz        # 200 from Headroom
```

## Wiring into Coder Agents

In the Coder admin UI: **Deployment → AI → Providers**. For each provider,
override the base URL to point at Headroom and use `SIDECAR_SHARED_API_KEY` as
the API key. Coder Agents pre-pends the appropriate path automatically; no
config there needed.

| Provider | Base URL | API key field |
|---|---|---|
| Anthropic | `http://<sidecars-host>:8787` | `SIDECAR_SHARED_API_KEY` |
| OpenAI | `http://<sidecars-host>:8787` | `SIDECAR_SHARED_API_KEY` |
| Google | `http://<sidecars-host>:8787` | `SIDECAR_SHARED_API_KEY` |

(`<sidecars-host>` is whatever the coderd process can reach the Headroom
container at — `localhost` if same host, the service IP / DNS name otherwise.
For production, front it with TLS.)

The OpenAI provider already uses Responses API (`WithUseResponsesAPI()` is the
default in `coderd/x/chatd/chatprovider/chatprovider.go:1200`), so no extra
config there.

## Auth bootstrap, per CLI

| CLI | Headless? | Lifetime | Refresh |
|---|---|---|---|
| Claude | Yes — `claude setup-token` | ~1 year | Manual rotation |
| Claude (alt) | No (browser) | 8h tokens, infinite refresh | Auto via SDK |
| Codex | No (browser, `codex login`) | Refresh ~30 days idle | Auto via codex-bridge |
| Gemini | No (browser, CLIProxyAPI `--login`) | Months–years if used regularly | Auto via CLIProxyAPI |

Per-sidecar setup is documented in each `<sidecar>/README.md`.

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

- All sidecars run as UID 1000. If your host credential dirs are owned by a
  different UID, either chown the mounts or rebuild with matching `--build-arg`.
- `SIDECAR_SHARED_API_KEY` is a soft secret — it gates only the local network
  hop between Headroom and the sidecars. Don't expose `8787` publicly without
  TLS + a real auth layer in front.
- Each sidecar emits Prometheus metrics; Headroom does too at `/metrics`. Wire
  to your existing observability stack to monitor compression ratios and
  per-provider latency.
- To temporarily fall back to raw API billing for one provider, point that
  provider's base URL back at the vendor (`https://api.anthropic.com` etc.) in
  the Coder admin UI — no stack restart needed.

## Repo layout

```
coder-agents-sidecars/
├── README.md                  # this file
├── .env.example
├── docker-compose.yml
├── claude-sidecar/
│   ├── Dockerfile
│   └── README.md              # auth bootstrap, ToS notes
├── codex-sidecar/
│   ├── Dockerfile
│   └── README.md
├── gemini-sidecar/
│   ├── config.yaml            # CLIProxyAPI config (Gemini-only)
│   └── README.md
└── headroom/
    └── README.md              # routing table, compression knobs
```

## Limitations / known gaps

- No automated test for end-to-end compaction × subscription-quota interaction.
  Recommend manual smoke-test after first deploy: kick off a long task, watch
  for failures around the compaction threshold.
- Codex multi-account is not configured (codex-bridge is single-user). If you
  need multiple Codex accounts, swap codex-sidecar for CLIProxyAPI with multiple
  credential files (it supports Codex too, just not used here for isolation).
- Coder Agents' `/api/experimental/chats/*` endpoints are explicitly experimental.
  Pin a known-good Coder version and treat each upgrade as a contract review.
