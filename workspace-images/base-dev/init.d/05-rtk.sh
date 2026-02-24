#!/usr/bin/env bash
# RTK (Reducer ToolKit) — Auto-initialize hooks for all AI agents
# Uses rtk's built-in initialization to configure Claude Code hooks and shell integration

set -euo pipefail

echo "[RTK] Initializing context optimization hooks..."

# Verify RTK is installed
if ! command -v rtk &> /dev/null; then
  echo "[RTK] ERROR: rtk binary not found in PATH" >&2
  exit 1
fi

RTK_VERSION=$(rtk --version 2>&1 | head -n1 || echo "unknown")
echo "[RTK] Found RTK ($RTK_VERSION)"

# Initialize Claude Code hooks using RTK's built-in command
# --auto-patch: Non-interactive mode, automatically patches settings.json
# -g: Global initialization for Claude Code
# RTK handles:
#   - Creating ~/.claude/hooks/rtk-rewrite.sh
#   - Backing up ~/.claude/settings.json to ~/.claude/settings.json.bak
#   - Patching PreToolUse hook configuration
#   - Creating ~/.rtkrc for shell integration
echo "[RTK] Running rtk init -g --auto-patch..."
if rtk init -g --auto-patch 2>&1 | tee /tmp/rtk-init.log; then
  echo "[RTK] Successfully configured Claude Code hooks"
else
  # Check if it failed because hooks already exist
  if grep -q "already exists" /tmp/rtk-init.log 2>/dev/null; then
    echo "[RTK] Hooks already configured (skipping)"
  else
    echo "[RTK] WARNING: rtk init failed, see /tmp/rtk-init.log" >&2
    # Don't exit with error - RTK might already be configured
  fi
fi

# Create minimal RTK reference document (reduces token cost vs inline docs)
# This is separate from RTK's built-in docs and tailored for workspace usage
CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR"

cat > "$CLAUDE_DIR/RTK.md" << 'EOF'
# RTK Usage Reference

RTK (Reducer ToolKit) optimizes LLM context by intelligently summarizing command output.

**Auto-active via PreToolUse hook** — Bash commands are automatically rewritten.
**Manual usage**: `rtk <command>` for any shell command
**Check savings**: `rtk gain` shows cumulative token reduction

Supports: git, ls, tree, find, ps, docker, kubectl, npm, pip, cargo, and more.
EOF

echo "[RTK] Created reference document at $CLAUDE_DIR/RTK.md"
echo "[RTK] Initialization complete. Token savings will be tracked automatically."
echo "[RTK] Note: Restart Claude Code to activate hooks if this is first initialization."
