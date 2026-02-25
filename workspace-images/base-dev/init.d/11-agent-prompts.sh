#!/bin/bash
# 11-agent-prompts.sh — Write system prompt to all agent config files
#
# Reads the baked-in system_prompt.txt and writes it to the standard
# home directory config locations for Claude, Codex, and Gemini.
# Always overwrites — these are the base agent instructions, not
# project-specific configs. Project CLAUDE.md etc. in the working
# directory are left untouched.

PROMPT_SRC="/usr/local/share/workspace-init.d/system_prompt.txt"

if [ ! -f "$PROMPT_SRC" ]; then
  printf "[agent-prompts] No system_prompt.txt found, skipping.\n"
  exit 0
fi

# Claude Code reads ~/.claude/CLAUDE.md
mkdir -p "$HOME/.claude"
cp "$PROMPT_SRC" "$HOME/.claude/CLAUDE.md"
printf "[agent-prompts] Wrote %s\n" "$HOME/.claude/CLAUDE.md"

# Codex reads ~/.codex/AGENTS.md
mkdir -p "$HOME/.codex"
cp "$PROMPT_SRC" "$HOME/.codex/AGENTS.md"
printf "[agent-prompts] Wrote %s\n" "$HOME/.codex/AGENTS.md"

# Gemini reads ~/.gemini/GEMINI.md
mkdir -p "$HOME/.gemini"
cp "$PROMPT_SRC" "$HOME/.gemini/GEMINI.md"
printf "[agent-prompts] Wrote %s\n" "$HOME/.gemini/GEMINI.md"

printf "[agent-prompts] Done.\n"
