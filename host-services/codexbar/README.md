# codexbar

[CodexBar CLI](https://github.com/steipete/CodexBar) `serve` as a host
service: one dashboard at `https://usage.tapiavala.com` for Codex, Claude and
the international Alibaba Token Plan, linked from every workspace as the
"AI Usage" Coder app.

Published to GHCR by `.github/workflows/build-codexbar.yaml`
(`ghcr.io/nyc-design/codexbar:{latest,sha-<commit>}`, amd64 + arm64). Build
context is the repo root so the image reuses the pinned, checksum-verified
`workspace-images/base-dev/scripts/install-codexbar.sh`.

## What is in the image

Alpine + the static-musl CodexBar binary + `tzdata`. No Node, no `bl`, no
`codex`/`claude` CLIs: CodexBar reads their credential files directly.

| Provider | Source | Input |
|---|---|---|
| codex | `oauth` | `/home/ubuntu/secrets/.codex/auth.json` (ro mount) |
| claude | `oauth` | `/home/ubuntu/secrets/.claude/.credentials.json` (ro mount) |
| alibabatokenplan | `auto` + `ALIBABA_TOKEN_PLAN_COOKIE` env | console cookie; `CODEXBAR_ALIBABA_REGION` = `intl-personal` (default) or `intl` (Team) |

Tokens are never refreshed here. Log in from a workspace (`codex login`,
`claude`, browser for the Alibaba cookie); the dashboard shows a per-provider
error until then. The Claude token must carry the `user:profile` scope, which
Claude Code sign-in provides.

`docker-entrypoint.sh` renders `config.json` (region substituted) into
`$CODEXBAR_CONFIG`, validates it, and execs
`codexbar serve --host 0.0.0.0 --port 8080 --allow-plain-http --identity redacted`.
Plain HTTP is container-internal only; Traefik terminates TLS.

## Deploy

1. Add `CODEXBAR_DASHBOARD_TOKEN` (`openssl rand -hex 32`) and
   `ALIBABA_TOKEN_PLAN_COOKIE` to the host `.env`.
2. Append `docker-compose.snippet.yml` to the host compose file;
   `docker compose up -d codexbar`.
3. Open `https://usage.tapiavala.com`, paste the token when prompted (stored in
   browser localStorage). `/` and `/health` are unauthenticated; `/usage`,
   `/cost` and `/dashboard/v1/snapshot` require `Authorization: Bearer`.

## Validation

Local, in a workspace (`docker build -f host-services/codexbar/Dockerfile .`):
image builds on arm64, `/health` returns 200, `/usage` returns 401 without the
bearer, and with dummy credential files each provider reaches its auth-stage
error (Codex "token expired", Claude scope check, Alibaba "login required"),
proving the mounts and cookie env are consumed. Not verified: amd64 build,
live provider responses, Traefik routing on the host.
