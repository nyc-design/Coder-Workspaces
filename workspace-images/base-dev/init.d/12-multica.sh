#!/usr/bin/env bash
set -eu

log() { printf '[multica-init] %s\n' "$*"; }

# --- Multica CLI / daemon (self-hosted) ---
# Configures the Multica CLI against a self-hosted server and starts the
# local agent daemon. Runs side-by-side with HAPI for now; will eventually
# replace it.
#
# Env vars consumed (wired via Terraform + gcp-refresh-secrets):
#   MULTICA_SERVER_URL   Backend API URL (required to enable setup)
#   MULTICA_APP_URL      Frontend URL (falls back to MULTICA_SERVER_URL)
#   MULTICA_TOKEN        Pre-provisioned PAT (starts with `mul_`) for
#                        headless `multica login --token`. The CLI also
#                        reads MULTICA_TOKEN at runtime, so setting it
#                        alone is enough for CLI calls; we still pipe it
#                        through `login --token` so the daemon auto-discovers
#                        and watches every workspace the account belongs to.
#
# Per-task execution directories live under MULTICA_WORKSPACES_ROOT
# (default ~/multica_workspaces). The daemon creates a fresh empty
# workdir per task; agents clone repos on demand via `multica repo
# checkout` — the Coder-cloned repo is intentionally NOT reused.

if ! command -v multica >/dev/null 2>&1; then
  exit 0
fi

if [[ -z "${MULTICA_SERVER_URL:-}" ]]; then
  log "MULTICA_SERVER_URL not set; skipping Multica daemon setup"
  exit 0
fi

APP_URL="${MULTICA_APP_URL:-$MULTICA_SERVER_URL}"
DAEMON_ID="${CODER_WORKSPACE_NAME:-$(hostname)}"

log "configuring Multica CLI for self-hosted server: $MULTICA_SERVER_URL"

multica config set server_url "$MULTICA_SERVER_URL" >/dev/null 2>&1 \
  || log "warning: 'multica config set server_url' failed"
multica config set app_url "$APP_URL" >/dev/null 2>&1 \
  || log "warning: 'multica config set app_url' failed"

# Headless login: pipe the token to `multica login --token` (it reads
# stdin). `autoWatchWorkspaces` blocks up to 5 min when the account has
# zero workspaces — cap it with `timeout` so init never stalls.
if [[ -n "${MULTICA_TOKEN:-}" ]]; then
  log "authenticating via MULTICA_TOKEN"
  if printf '%s\n' "$MULTICA_TOKEN" \
      | timeout 30 multica login --token >/tmp/multica-login.log 2>&1; then
    log "authenticated and auto-watched workspaces"
  else
    log "warning: 'multica login --token' failed/timed out (see /tmp/multica-login.log)"
  fi
else
  log "no MULTICA_TOKEN provided; run 'multica login' in the workspace to finish setup"
fi

log "starting Multica daemon (id: $DAEMON_ID)"
multica daemon start \
    --daemon-id "$DAEMON_ID" \
    --device-name "$DAEMON_ID" \
  >/tmp/multica-daemon.log 2>&1 \
  || log "warning: daemon start failed (see /tmp/multica-daemon.log and ~/.multica/daemon.log)"
