#!/usr/bin/env bash
# Runtime install of Playwright browsers + agent skills. Has to be runtime
# rather than build-time because $HOME is on a persistent volume that mounts
# over the image's /home/coder, hiding anything baked in.
set -eu

log() { printf '[vite-init] %s\n' "$*"; }

# Standard Playwright browser build (used by @playwright/test, @playwright/cli).
if command -v npx >/dev/null 2>&1; then
    if [[ -z "$(find "${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}" -maxdepth 2 -name 'chromium-*' -type d 2>/dev/null | head -1)" ]]; then
        log "Installing Playwright Chromium"
        npx playwright@latest install chromium
    fi

    # @playwright/mcp uses its own mcp-chromium-* build separate from the
    # standard chromium-* used above.
    if [[ -z "$(find "${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}" -maxdepth 2 -name 'mcp-chromium-*' -type d 2>/dev/null | head -1)" ]]; then
        log "Installing Playwright MCP browser build"
        npx @playwright/mcp@latest install 2>/dev/null || true
    fi
fi

# Playwright CLI skills for Claude Code (token-efficient browser automation).
# Installs into ~/.claude/skills/ — must run from /home/coder so the path is
# resolved correctly.
if command -v playwright-cli >/dev/null 2>&1; then
    log "Installing playwright-cli skills for Claude Code"
    (cd /home/coder && playwright-cli install --skills) 2>/dev/null || true
fi
