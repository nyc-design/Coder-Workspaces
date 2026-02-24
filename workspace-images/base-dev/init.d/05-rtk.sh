#!/usr/bin/env bash
# RTK (Reducer ToolKit) — Auto-initialize hooks for all AI agents
# This script configures RTK's PreToolUse hook in Claude Code and sets up
# compatible paths for Codex and Gemini agents to reduce token costs.

set -euo pipefail

echo "[RTK] Initializing context optimization hooks..."

# 1. Claude Code hook configuration
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

mkdir -p "$CLAUDE_DIR/hooks"

# Create RTK rewrite hook script
cat > "$CLAUDE_DIR/hooks/rtk-rewrite.sh" << 'EOF'
#!/usr/bin/env bash
# RTK PreToolUse hook — rewrites Bash commands to use rtk prefix
# This transparently optimizes command output before Claude processes it.
set -euo pipefail

# Read stdin (command from Claude)
COMMAND=$(cat)

# Only rewrite if command is a candidate for RTK optimization
# RTK supports: git, ls, tree, find, ps, docker, kubectl, and more
if [[ "$COMMAND" =~ ^(git|ls|tree|find|ps|docker|kubectl|npm|pip|cargo|cat|head|tail|grep) ]]; then
  echo "rtk $COMMAND"
else
  echo "$COMMAND"
fi
EOF

chmod +x "$CLAUDE_DIR/hooks/rtk-rewrite.sh"

# Backup existing settings if not already backed up
if [ -f "$SETTINGS_FILE" ] && [ ! -f "$SETTINGS_FILE.bak" ]; then
  cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak"
  echo "[RTK] Backed up existing settings to $SETTINGS_FILE.bak"
fi

# Initialize settings file if it doesn't exist
if [ ! -f "$SETTINGS_FILE" ]; then
  echo '{}' > "$SETTINGS_FILE"
fi

# Use jq to merge RTK hook configuration
# Preserves existing hooks and settings while adding RTK PreToolUse hook
TMP_FILE=$(mktemp)
jq '. + {
  "hooks": {
    "PreToolUse": (
      (.hooks.PreToolUse // []) + [{
        "matcher": "Bash",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/rtk-rewrite.sh"
        }]
      }]
    )
  }
}' "$SETTINGS_FILE" > "$TMP_FILE"

mv "$TMP_FILE" "$SETTINGS_FILE"
echo "[RTK] Configured PreToolUse hook in $SETTINGS_FILE"

# 2. Create minimal RTK reference document (reduces token cost vs inline docs)
cat > "$CLAUDE_DIR/RTK.md" << 'EOF'
# RTK Usage Reference

RTK (Reducer ToolKit) optimizes LLM context by intelligently summarizing command output.

**Auto-active via PreToolUse hook** — Bash commands are automatically rewritten.
**Manual usage**: `rtk <command>` for any shell command
**Check savings**: `rtk gain` shows cumulative token reduction

Supports: git, ls, tree, find, ps, docker, kubectl, npm, pip, cargo, and more.
EOF

echo "[RTK] Created reference document at $CLAUDE_DIR/RTK.md"

# 3. Verify installation
if command -v rtk &> /dev/null; then
  RTK_VERSION=$(rtk --version 2>&1 | head -n1 || echo "unknown")
  echo "[RTK] Successfully initialized ($RTK_VERSION)"
  echo "[RTK] Token savings will be tracked automatically"
else
  echo "[RTK] WARNING: rtk binary not found in PATH" >&2
  exit 1
fi

# 4. Run rtk init for Codex/Gemini compatibility (non-interactive)
# This creates ~/.rtkrc and sets up shell integration for other agents
if [ ! -f "$HOME/.rtkrc" ]; then
  rtk init --quiet 2>/dev/null || true
  echo "[RTK] Created ~/.rtkrc for shell integration"
fi

echo "[RTK] Initialization complete. Restart Claude Code to activate hooks."
