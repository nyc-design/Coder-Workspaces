#!/usr/bin/env bash
# RTK (Reducer ToolKit) — Auto-initialize hooks for all AI agents
# Configures Claude Code hooks + shell aliases for Codex/Gemini/HAPI

set -euo pipefail

echo "[RTK] Initializing context optimization hooks..."

# Verify RTK is installed
if ! command -v rtk &> /dev/null; then
  echo "[RTK] ERROR: rtk binary not found in PATH" >&2
  exit 1
fi

RTK_VERSION=$(rtk --version 2>&1 | head -n1 || echo "unknown")
echo "[RTK] Found RTK ($RTK_VERSION)"

# 1. Configure Claude Code hooks using RTK's built-in command
# --auto-patch: Non-interactive mode, automatically patches settings.json
# -g: Global initialization for Claude Code
# RTK handles:
#   - Creating ~/.claude/hooks/rtk-rewrite.sh
#   - Backing up ~/.claude/settings.json to ~/.claude/settings.json.bak
#   - Patching PreToolUse hook configuration
echo "[RTK] Running rtk init -g --auto-patch for Claude Code..."
if rtk init -g --auto-patch 2>&1 | tee /tmp/rtk-init.log; then
  echo "[RTK] ✓ Claude Code hooks configured"
else
  # Check if it failed because hooks already exist
  if grep -q "already exists" /tmp/rtk-init.log 2>/dev/null; then
    echo "[RTK] ✓ Claude Code hooks already configured (skipping)"
  else
    echo "[RTK] WARNING: rtk init failed for Claude Code, see /tmp/rtk-init.log" >&2
    # Don't exit with error - continue with shell integration
  fi
fi

# 2. Create shell aliases for Codex, Gemini, and HAPI agents
# Since RTK's PreToolUse hooks only work in Claude Code, we need shell-level
# aliases to make common commands automatically use rtk for other agents.
echo "[RTK] Configuring shell aliases for Codex/Gemini/HAPI..."

RTK_ALIASES="$HOME/.rtk_aliases"
cat > "$RTK_ALIASES" << 'EOF'
# RTK (Reducer ToolKit) — Shell aliases for automatic context optimization
# These aliases make common commands use rtk automatically for all AI agents.
# Claude Code uses PreToolUse hooks instead, so these won't affect it.

# Only enable aliases for non-interactive shells (AI agent sessions)
# This prevents conflicts with user's manual terminal usage
if [[ $- != *i* ]] || [[ -n "${CODER_AGENT_TOKEN:-}" ]]; then
  # Version control
  alias git='rtk git'

  # File listing and navigation
  alias ls='rtk ls'
  alias tree='rtk tree'
  alias find='rtk find'

  # File viewing
  alias cat='rtk cat'
  alias head='rtk head'
  alias tail='rtk tail'
  alias grep='rtk grep'

  # Process management
  alias ps='rtk ps'

  # Container tools
  alias docker='rtk docker'
  alias kubectl='rtk kubectl'

  # Package managers
  alias npm='rtk npm'
  alias pip='rtk pip'
  alias cargo='rtk cargo'
fi
EOF

# Source aliases in .bashrc if not already present
if ! grep -q "source.*\.rtk_aliases" "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" << 'EOF'

# RTK context optimization aliases (auto-configured by workspace init)
if [ -f "$HOME/.rtk_aliases" ]; then
  source "$HOME/.rtk_aliases"
fi
EOF
  echo "[RTK] ✓ Shell aliases added to .bashrc"
else
  echo "[RTK] ✓ Shell aliases already configured in .bashrc"
fi

# 3. Create minimal RTK reference document (reduces token cost vs inline docs)
# This is separate from RTK's built-in docs and tailored for workspace usage
CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR"

cat > "$CLAUDE_DIR/RTK.md" << 'EOF'
# RTK Usage Reference

RTK (Reducer ToolKit) optimizes LLM context by intelligently summarizing command output.

**Claude Code**: Auto-active via PreToolUse hook — Bash commands are automatically rewritten.
**Codex/Gemini/HAPI**: Auto-active via shell aliases — Common commands use rtk automatically.
**Manual usage**: `rtk <command>` for any shell command
**Check savings**: `rtk gain` shows cumulative token reduction

Supports: git, ls, tree, find, ps, docker, kubectl, npm, pip, cargo, and more.
EOF

echo "[RTK] ✓ Created reference document at $CLAUDE_DIR/RTK.md"
echo ""
echo "[RTK] Initialization complete! Configuration summary:"
echo "  • Claude Code: PreToolUse hooks (restart Claude Code to activate)"
echo "  • Codex/Gemini/HAPI: Shell aliases (active in new shell sessions)"
echo "  • Token savings tracked automatically with: rtk gain"
