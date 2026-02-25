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
#
# Loading strategy:
#   - BASH_ENV: Primary mechanism. Bash sources $BASH_ENV for every
#     non-interactive shell invocation (how AI agents run commands).
#   - .profile: Fallback for login shells (bash -l).
#   - .bashrc: Fallback for interactive shells that source it.
#   - The alias file itself guards with [[ $- != *i* ]] so aliases
#     only activate in non-interactive shells (AI agent execution).
echo "[RTK] Configuring shell aliases for Codex/Gemini/HAPI..."

RTK_ALIASES="$HOME/.rtk_aliases"
cat > "$RTK_ALIASES" << 'EOF'
# RTK (Reducer ToolKit) — Shell aliases for automatic context optimization
# These aliases make common commands use rtk automatically for AI agents.
# Claude Code uses PreToolUse hooks instead, so these won't affect it.

# Only enable aliases for AI agent command execution (non-interactive shells)
# Explicitly DISABLE for interactive terminals to prevent user interference
# Detection strategy:
#   - Interactive shells ($- contains 'i'): DISABLE (user's terminal)
#   - Non-interactive shells: ENABLE (AI agents executing commands)
if [[ $- != *i* ]]; then
  # Version control
  alias git='rtk git'
  alias gh='rtk gh'

  # File listing and navigation
  alias ls='rtk ls'
  alias tree='rtk tree'
  alias find='rtk find'

  # File search
  alias grep='rtk grep'
  alias rg='rtk rg'

  # Container tools
  alias docker='rtk docker'
  alias kubectl='rtk kubectl'

  # Package managers
  alias npm='rtk npm'
  alias pip='rtk pip'
fi
EOF

# 3. Set BASH_ENV so non-interactive shells source the aliases file.
# This is the critical path — .bashrc exits early for non-interactive shells,
# and .profile only loads for login shells. BASH_ENV is the only mechanism
# that reliably loads for `bash -c "command"` invocations used by AI agents.

# Add BASH_ENV to .profile (login shells propagate it to child processes)
if ! grep -q 'BASH_ENV=.*\.rtk_aliases' "$HOME/.profile" 2>/dev/null; then
  cat >> "$HOME/.profile" << 'EOF'

# RTK: ensure aliases load in non-interactive shells (AI agent commands)
export BASH_ENV="$HOME/.rtk_aliases"
EOF
  echo "[RTK] ✓ BASH_ENV export added to .profile"
else
  echo "[RTK] ✓ BASH_ENV already configured in .profile"
fi

# Add BASH_ENV to .bashrc (covers interactive shells that spawn subshells)
if ! grep -q 'BASH_ENV=.*\.rtk_aliases' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" << 'EOF'

# RTK: ensure aliases load in non-interactive shells (AI agent commands)
export BASH_ENV="$HOME/.rtk_aliases"
EOF
  echo "[RTK] ✓ BASH_ENV export added to .bashrc"
else
  echo "[RTK] ✓ BASH_ENV already configured in .bashrc"
fi

# Also set BASH_ENV for the current init session so subsequent scripts inherit it
export BASH_ENV="$RTK_ALIASES"

# 4. Create minimal RTK reference document (reduces token cost vs inline docs)
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

Supports: git, ls, tree, find, grep, rg, docker, kubectl, npm, pip, gh, pytest, and more.
EOF

echo "[RTK] ✓ Created reference document at $CLAUDE_DIR/RTK.md"
echo ""
echo "[RTK] Initialization complete! Configuration summary:"
echo "  • Claude Code: PreToolUse hooks (restart Claude Code to activate)"
echo "  • Codex/Gemini/HAPI: Shell aliases via BASH_ENV (active in new shells)"
echo "  • Token savings tracked automatically with: rtk gain"
