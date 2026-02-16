#!/usr/bin/env bash
set -eu

log() { printf '[mcp-cleanup-init] %s\n' "$*"; }

# Start the periodic orphan reaper in the background.
# This is a safety net — the primary defense is mcp-wrap setting
# PR_SET_PDEATHSIG so the kernel kills MCP servers when their parent dies.
# The watcher catches edge cases (grandchild processes, npx wrappers, etc.).
if command -v mcp-cleanup &>/dev/null; then
  nohup mcp-cleanup --watch > /tmp/mcp-cleanup.log 2>&1 &
  log "started mcp-cleanup watcher (pid $!)"
else
  log "mcp-cleanup not found, skipping"
fi
