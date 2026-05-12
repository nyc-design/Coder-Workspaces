#!/usr/bin/env bash
set -eu

log() { printf '[vite-init] %s\n' "$*"; }

log "Setting up Vite/React development environment"

mkdir -p /home/coder/projects /home/coder/.cache/node /home/coder/.local/share/pnpm/store
chown -R coder:coder /home/coder/projects /home/coder/.cache /home/coder/.local

# Helpers + env exports for the user shell (idempotent)
if ! grep -q "# --- Vite development helpers ---" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- Vite development environment ---
export NODE_OPTIONS="--max-old-space-size=4096"
export NPM_CONFIG_UPDATE_NOTIFIER=false
export NPM_CONFIG_FUND=false
export PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/ms-playwright"
export PLAYWRIGHT_MCP_CONFIG="$HOME/.playwright/cli.config.json"
export PLAYWRIGHT_MCP_OUTPUT_DIR="$HOME/.playwright-cli"
export MCP_SERVER_PLAYWRIGHT_PORT=3001
export MCP_SERVER_PLAYWRIGHT_HOST=localhost

# --- Vite development helpers ---
# Scaffold a new Vite project (React + TS by default). Drops the user into the
# new directory with deps installed via pnpm.
create-vite() {
    local project_name="${1:-my-app}"
    local template="${2:-react-ts}"
    pnpm create vite@latest "$project_name" --template "$template"
    if [[ -d "$project_name" ]]; then
        cd "$project_name"
        pnpm install
        echo "Vite project ready. Run 'pnpm dev' to start the dev server."
    fi
}

start-mcp-playwright() {
    nohup npx -y @playwright/mcp \
        --port "${MCP_SERVER_PLAYWRIGHT_PORT:-3001}" \
        --host "${MCP_SERVER_PLAYWRIGHT_HOST:-localhost}" \
        > /tmp/mcp-playwright.log 2>&1 &
    echo "MCP Playwright server started on ${MCP_SERVER_PLAYWRIGHT_HOST:-localhost}:${MCP_SERVER_PLAYWRIGHT_PORT:-3001}"
}
stop-mcp-playwright() { pkill -f "@playwright/mcp" && echo "stopped" || echo "not running"; }

# pnpm shortcuts
alias pi='pnpm install'
alias pa='pnpm add'
alias pad='pnpm add -D'
alias pr='pnpm run'
alias pd='pnpm dev'
alias pb='pnpm build'
alias pt='pnpm test'
# ---
EOF
fi

# Install Playwright CLI skills globally for Claude Code (token-efficient browser automation).
log "Installing playwright-cli skills for Claude Code"
(cd /home/coder && playwright-cli install --skills) 2>/dev/null || true

# Install the Playwright MCP-specific browser build (separate from the standard
# chromium baked in at build time).
if command -v npx >/dev/null 2>&1; then
    log "Installing Playwright MCP browser build"
    npx @playwright/mcp@latest install 2>/dev/null || true
fi

chown -R coder:coder /home/coder/.bashrc /home/coder/.local /home/coder/.cache 2>/dev/null || true

log "Vite/React development environment setup complete"
