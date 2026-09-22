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

`node:22-alpine` + the static-musl CodexBar binary + the pinned `bl` CLI +
`tzdata`. No `codex`/`claude` CLIs: CodexBar reads their credential files
directly. Node is there only because CodexBar's non-cookie Alibaba path is to
spawn `bl` (there is no file reader for Token Plan credentials).

| Provider | Source | Input |
|---|---|---|
| codex | `oauth` | `/home/ubuntu/secrets/.codex/auth.json` (ro mount) |
| claude | `oauth` | `/home/ubuntu/secrets/.claude/.credentials.json` (ro mount) |
| alibabatokenplan | `cli` | `bl usage token-plan` against `/home/ubuntu/secrets/.bailian` (rw mount: `bl` writes state there); `CODEXBAR_ALIBABA_REGION=intl-personal` |

CodexBar never refreshes tokens. Log in from a workspace (`codex login`,
`claude`, `bl auth login`); the dashboard shows a per-provider error until then.
`bl` only reports Personal/Solo usage (the plan in use); a Team plan would need
the `ALIBABA_TOKEN_PLAN_COOKIE` path instead. The Claude token must carry the `user:profile` scope, which
Claude Code sign-in provides.

`docker-entrypoint.sh` renders `config.json` (region substituted) into
`$CODEXBAR_CONFIG`, validates it, and execs
`codexbar serve --host 0.0.0.0 --port 8080 --allow-plain-http --identity redacted`.
Plain HTTP is container-internal only; Traefik terminates TLS.

## Deploy

1. Add `CODEXBAR_DASHBOARD_TOKEN` (`openssl rand -hex 32`) to the host `.env`.
2. Append `docker-compose.snippet.yml` to the host compose file;
   `docker compose up -d codexbar`.
3. Open `https://usage.tapiavala.com`, paste the token when prompted (stored in
   browser localStorage). `/` and `/health` are unauthenticated; `/usage`,
   `/cost` and `/dashboard/v1/snapshot` require `Authorization: Bearer`.

## Validation

Local, in a workspace (`docker build -f host-services/codexbar/Dockerfile .`):
image builds on arm64, `/health` returns 200, `/usage` returns 401 without the
bearer, and with dummy credential files each provider reaches its auth-stage
error (Codex "token expired", Claude scope check, Alibaba "sign in with bl"
from a real `bl 2.0.0` spawn), proving the mounts are consumed. Not verified: amd64 build,
live provider responses, Traefik routing on the host.
