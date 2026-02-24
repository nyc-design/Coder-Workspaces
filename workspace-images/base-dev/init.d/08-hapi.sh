#!/usr/bin/env bash
set -eu

log() { printf '[hapi-init] %s\n' "$*"; }

# --- HAPI Runner ---
if [[ -n "${HAPI_HUB_URL:-}" && -n "${HAPI_CLI_API_TOKEN:-}" ]]; then
  log "configuring HAPI runner"
  mkdir -p /home/coder/.hapi
  # Write settings directly — hapi reads apiUrl + cliApiToken from settings.json
  if [ ! -f /home/coder/.hapi/settings.json ]; then
    echo '{}' > /home/coder/.hapi/settings.json
  fi
  # Use node to merge apiUrl and cliApiToken into existing settings
  node -e "
    const fs = require('fs');
    const f = '/home/coder/.hapi/settings.json';
    const s = JSON.parse(fs.readFileSync(f, 'utf8'));
    s.apiUrl = process.env.HAPI_HUB_URL;
    s.cliApiToken = process.env.HAPI_CLI_API_TOKEN;
    fs.writeFileSync(f, JSON.stringify(s, null, 2) + '\n');
  "
  # Set HAPI_HOSTNAME so the hub dashboard shows the workspace name
  export HAPI_HOSTNAME="${CODER_WORKSPACE_NAME:-$(hostname)}"
  nohup hapi runner start > /tmp/hapi-runner.log 2>&1 &
  log "HAPI runner started (hub: $HAPI_HUB_URL)"

  # Auto-start a HAPI session for the workspace's coding agent so it
  # appears in the hub dashboard immediately (like agentapi does for Coder).
  HAPI_PROJECT_DIR="${ARG_WORKDIR:-$PWD}"
  HAPI_AGENT_CMD="${HAPI_AGENT:-claude}"
  if [[ -n "$HAPI_PROJECT_DIR" && "$HAPI_PROJECT_DIR" != "/" ]]; then
    (
      # Wait for runner to register with the hub
      sleep 5
      log "starting HAPI $HAPI_AGENT_CMD session in $HAPI_PROJECT_DIR"
      cd "$HAPI_PROJECT_DIR"
      # Launch hapi with the agent subcommand; --started-by runner makes
      # the session show up as remotely-managed in the hub dashboard.
      # --yolo bypasses permission prompts (matches Coder workspace config).
      nohup hapi "$HAPI_AGENT_CMD" \
        --hapi-starting-mode remote \
        --started-by runner \
        --yolo \
        > /tmp/hapi-session.log 2>&1 &
      log "HAPI $HAPI_AGENT_CMD session started (pid $!)"
    ) &
  fi
fi
