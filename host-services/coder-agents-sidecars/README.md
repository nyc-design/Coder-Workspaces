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

Six processes supervised by [s6-overlay v3](https://github.com/just-containers/s6-overlay):

```
                                  ┌─► 127.0.0.1:3456 claude-sidecar    (Meridian + Claude Code SDK)        ─► api.anthropic.com
          ┌─► dispatcher :8788 ──┼─► 127.0.0.1:8317 cliproxy-sidecar  (CLIProxyAPI --login claude)        ─► api.anthropic.com
:8787 ─► headroom (compress)    │  └─► 127.0.0.1:9090 kirocc            (Kiro Builder ID → Messages API)    ─► kiro.amazonaws.com
  └─/codex─────────────────┤
  └─/gemini───────────────┤
                                  └─► 127.0.0.1:8317 cliproxy-sidecar  (Codex + Gemini OAuth)
                                                                         ├─► chatgpt.com/backend-api/codex
                                                                         └─► generativelanguage.googleapis.com

:8788 (dispatcher, /openai/* only) ─► {groq | cerebras | codestral | zen}  (direct HTTPS, key swap server-side)
```

The dispatcher reads a leading `<prefix>/` on the request body's `model` field
to pick the upstream, strips it before forwarding, and (for external lanes)
swaps the inbound shared bearer for the per-upstream API key it loaded from GCP
Secret Manager at startup.

| Coder provider | Lane (model prefix) | Sidecar / upstream | Subscription / key |
|---|---|---|---|
| Anthropic | `meridian/claude-*` | claude-sidecar ([Meridian](https://github.com/rynfar/meridian) + Claude Code SDK) | Claude Pro/Max OAuth |
| Anthropic | `subscription/claude-*` | cliproxy-sidecar ([CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) `--login claude`) | Claude Pro/Max OAuth |
| Anthropic | `kiro/claude-*` | kirocc ([d-kuro/kirocc](https://github.com/d-kuro/kirocc)) | Kiro Builder ID |
| OpenAI (Codex) | n/a (single upstream) | cliproxy-sidecar | ChatGPT Plus/Pro OAuth |
| Google | n/a (single upstream) | cliproxy-sidecar | Gemini Advanced OAuth |
| OpenAI-compat | `groq/*` | api.groq.com | Groq API key |
| OpenAI-compat | `cerebras/*` | api.cerebras.ai | Cerebras API key |
| OpenAI-compat | `codestral/*` | codestral.mistral.ai | Codestral API key |
| OpenAI-compat | `zen/*` | opencode.ai/zen | Zen API key |

All upstream credentials live in **GCP Secret Manager (project `ai-sidecar-nt`)**
and are fetched once at container start by the `bootstrap-secrets` s6 oneshot,
written to `/run/coder-agents-sidecars/secrets.env` (mode 600), then sourced by
each longrun. Clients never see anything beyond the shared bearer.

Compression is fully local (rule-based + ONNX `Kompress-base`, plus the bundled
[RTK](https://github.com/rtk-ai/rtk) for shell-output rewriting); no extra LLM
key required.

## Deploy

Append `docker-compose.snippet.yml` to whatever compose file already runs
`coder` on your host VM. Point `llm.tapiavala.com` DNS at the host so Let's
Encrypt can issue. Then:

```bash
# 1. Issue a runtime SA key and put it in the host .env (one line).
#    The SA has roles/secretmanager.secretAccessor on projects/ai-sidecar-nt.
gcloud iam service-accounts keys create /tmp/sa.json \
  --iam-account=sidecar-runtime@ai-sidecar-nt.iam.gserviceaccount.com
echo "GOOGLE_APPLICATION_CREDENTIALS_JSON='$(jq -c . /tmp/sa.json)'" >> .env
shred -u /tmp/sa.json

# 2. Populate the secrets in GCP Secret Manager (one-time, project: ai-sidecar-nt):
#      SIDECAR_SHARED_API_KEY    openssl rand -hex 32
#      CLAUDE_CODE_OAUTH_TOKEN   claude setup-token   (run on a host with claude CLI)
#      GROQ_API_KEY              from console.groq.com
#      CEREBRAS_API_KEY          from cloud.cerebras.ai
#      CODESTRAL_API_KEY         from console.mistral.ai (Codestral)
#      ZEN_API_KEY               from opencode.ai
#    For each:  echo -n '<value>' | gcloud secrets versions add <NAME> \
#                 --project=ai-sidecar-nt --data-file=-

# 3. Pull + start
docker compose pull coder-agents-sidecars
docker compose up -d coder-agents-sidecars

# 4. One-time interactive logins (browser-based; creds land in the named volume)
docker exec -it coder-agents-sidecars cli-proxy-api --auth-dir /data/auth/cliproxy --login codex
docker exec -it coder-agents-sidecars cli-proxy-api --auth-dir /data/auth/cliproxy --login gemini
docker exec -it coder-agents-sidecars cli-proxy-api --auth-dir /data/auth/cliproxy --login claude   # optional, for `subscription/` lane
docker exec -it coder-agents-sidecars kiro-auth-login                                                # Kiro Builder ID, for `kiro/` lane

# 5. Pick up the new credentials
docker restart coder-agents-sidecars

# 6. Smoke-test (Traefik should be serving by now)
SIDECAR_SHARED_API_KEY=$(gcloud secrets versions access latest \
  --secret=SIDECAR_SHARED_API_KEY --project=ai-sidecar-nt)
curl -fsS -o /dev/null -w '%{http_code}\n' \
     -H "Authorization: Bearer $SIDECAR_SHARED_API_KEY" \
     -H 'Content-Type: application/json' \
     -d '{"model":"meridian/claude-3-5-sonnet-latest","max_tokens":4,"messages":[{"role":"user","content":"hi"}]}' \
     https://llm.tapiavala.com/claude/v1/messages   # expect 200
```

Credentials persist in the named volume `coder-agents-sidecars-auth` (mounted at
`/data/auth`) so step 4 only runs once. Secret rotation is `gcloud secrets
versions add` + `docker restart`; no `.env` edits needed.

## Wire into Coder Agents

In **Coder admin → Deployment → AI → Providers**, override base URL on each
provider (or rely on `coder-agents-config/providers.yaml` to sync them):

| Provider | Base URL (Coder admin) | API key |
|---|---|---|
| Anthropic | `https://llm.tapiavala.com/claude` | `SIDECAR_SHARED_API_KEY` |
| OpenAI    | `https://llm.tapiavala.com/codex`  | `SIDECAR_SHARED_API_KEY` |
| Google    | `https://llm.tapiavala.com/gemini` | `SIDECAR_SHARED_API_KEY` |
| OpenAI-compat | `https://llm.tapiavala.com/openai` | `SIDECAR_SHARED_API_KEY` |

For the Anthropic and OpenAI-compat lanes, **model names carry routing
prefixes**. Examples:

- `meridian/claude-3-5-sonnet-latest` → Meridian + Claude Pro/Max OAuth
- `subscription/claude-3-5-sonnet-latest` → CLIProxy `--login claude`
- `kiro/claude-3-5-sonnet-latest` → kirocc (Kiro Builder ID)
- `groq/llama-3.3-70b-versatile`, `cerebras/llama-3.3-70b`, `codestral/codestral-latest`, `zen/<model>` → direct upstreams

The dispatcher strips the prefix before forwarding, so the actual upstream
receives the native model name.

End-to-end path layering for one Anthropic request:

```
Coder Agents (fantasy provider auto-appends /v1/messages)
       │
https://llm.tapiavala.com/claude/v1/messages
       │
Traefik (matches /claude/, stripPrefix removes it)
       │
http://coder-agents-sidecars:8787/v1/messages
       │
Headroom (compresses, routes by path)
       │
http://127.0.0.1:3456/v1/messages → claude-sidecar (Meridian + Claude SDK)
       │
api.anthropic.com (your subscription)
```

The OpenAI provider already calls `WithUseResponsesAPI()` by default in chatd.
Traefik rewrites `/codex/*` requests to `/codex/v1/*` before stripping the
`/codex` prefix, so the public base URL can stay
`https://llm.tapiavala.com/codex` even though Headroom speaks the usual `/v1/*`
shape internally. Requests that already use `/codex/v1/*` bypass the rewrite.
To
temporarily fall back to raw API billing for any provider, change its base URL
back to the vendor's URL in the admin UI — no container restart needed.

## Use from anywhere (laptop, workspace, automation)

The same three URLs work for **any tool that takes a custom base URL**. Point
your local CLIs at the sidecar to inherit centralized OAuth, free Headroom +
RTK compression, single-key revocation, and subscription-quota draw across
every machine. No need to install Headroom on each box.

```bash
# Claude Code
export ANTHROPIC_BASE_URL=https://llm.tapiavala.com/claude
export ANTHROPIC_API_KEY=$SIDECAR_SHARED_API_KEY
unset CLAUDE_CODE_OAUTH_TOKEN          # don't fall back to laptop's own OAuth
claude

# Codex CLI
export OPENAI_BASE_URL=https://llm.tapiavala.com/codex
export OPENAI_API_KEY=$SIDECAR_SHARED_API_KEY
codex

# Gemini CLI / Google SDKs
export GEMINI_API_BASE=https://llm.tapiavala.com/gemini   # name varies by client
export GOOGLE_API_KEY=$SIDECAR_SHARED_API_KEY

# Aider, Open WebUI, custom scripts — anything OpenAI-compat / Anthropic-compat.
# Use whichever subpath URL matches the protocol shape the tool speaks.
```

Works from Coder workspaces too. Latency overhead from a workspace on the same
host (TLS handshake + Traefik + hairpin NAT) is **~10-120ms warm**, ~50-200ms
cold — negligible vs the 1-5s LLM call itself, and Headroom usually nets
positive by reducing tokens sent upstream.

Security posture: TLS in transit (Let's Encrypt), bearer-token auth (the shared
key, validated at each sidecar). Treat `SIDECAR_SHARED_API_KEY` like a
long-lived OAuth token — rotate periodically, revoke on leak.

## Auth bootstrap details

| Provider | Headless? | Lifetime | Refresh |
|---|---|---|---|
| Claude (`meridian/`) | Yes — `claude setup-token` | ~1 year | Manual rotation |
| Claude (`subscription/`) | No (browser, in-container `cli-proxy-api --login claude`) | 8h tokens, infinite refresh | Auto via CLIProxyAPI |
| Codex | No (browser, in-container `cli-proxy-api --login codex`) | ~30 days idle | Auto via CLIProxyAPI |
| Gemini | No (browser, in-container `cli-proxy-api --login gemini`) | Months–years if used regularly | Auto via CLIProxyAPI |
| Kiro (`kiro/`) | No (device-code, in-container `kiro-auth-login`) | ~90 days idle (Builder ID) | Auto via kirocc (same fig_auth flow as the CLI) |

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
├── .env.example                    # GOOGLE_APPLICATION_CREDENTIALS_JSON only
├── .gitignore
├── claude-sidecar/README.md        # Meridian / Claude Code SDK auth + ToS
├── cliproxy-sidecar/
│   ├── README.md                   # CLIProxyAPI: Codex + Gemini + (opt) Claude auth
│   └── config.yaml                 # baked into image at /etc/coder-agents-sidecars/cli-proxy.yaml
├── kirocc-sidecar/
│   ├── README.md                   # Kiro Builder ID bootstrap
│   └── kiro-auth-login             # in-container wrapper for `q login --use-device-flow`
├── dispatcher/                     # model-prefix router (Python/Starlette)
│   ├── README.md
│   ├── dispatcher.py
│   ├── bootstrap_secrets.py        # s6 oneshot: GCP Secret Manager → /run/.../secrets.env
│   └── requirements.txt
├── headroom/README.md              # routing table + compression knobs
└── s6/                             # s6-overlay v3 service tree
    ├── user/contents.d/            # service registration
    ├── bootstrap-secrets/{type=oneshot,up}
    ├── dispatcher/{run,type,dependencies.d/}
    ├── kirocc/{run,type,dependencies.d/}
    ├── headroom/{run,type,dependencies.d/}
    ├── claude-sidecar/{run,type,dependencies.d/}
    └── cliproxy-sidecar/{run,type,dependencies.d/}
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
