#!/bin/bash
# 11-agent-prompts.sh — Assemble the workspace system prompt and wire it
# into every agent's expected read path.
#
# Skill-catalog canonicalization and image-bundled skill seeding live in
# 13-agent-skills.sh, not here.
#
# How it works:
#   1. Concatenate /usr/local/share/workspace-prompts/*.txt in sorted order.
#      Base image contributes 00-base.txt; child images add 20-<image>.txt
#      (and 30-<image>.txt for grand-children like fullstack-dev).
#   2. Write the assembled prompt to ~/.coder/AGENTS.md, which Coder Agents
#      auto-injects into chat context (default for chatd's workspace-agent
#      lookup — see coder/coder agent/agentcontextconfig/api.go).
#   3. Symlink each provider's expected path to ~/.coder/AGENTS.md so the
#      same content is seen by Claude Code, Codex, and Gemini CLIs running
#      in-workspace. Symlinks are idempotent and preserve any user-edited
#      regular files (we never overwrite a non-link).

set -u

PROMPT_DIR="/usr/local/share/workspace-prompts"
CANONICAL="$HOME/.coder/AGENTS.md"

# 1. Assemble the prompt.
mkdir -p "$HOME/.coder"
if [ ! -d "$PROMPT_DIR" ] || [ -z "$(ls -A "$PROMPT_DIR" 2>/dev/null)" ]; then
  printf "[agent-prompts] No prompt parts found in %s, skipping.\n" "$PROMPT_DIR"
  exit 0
fi

# Concatenate sorted (00-base.txt, 20-<image>.txt, 30-<grandchild>.txt, ...).
# Insert a blank line between parts so sections don't run together.
{
  first=1
  for part in "$PROMPT_DIR"/*.txt; do
    [ -e "$part" ] || continue
    if [ $first -eq 0 ]; then printf "\n"; fi
    cat "$part"
    first=0
  done
} > "$CANONICAL"
printf "[agent-prompts] Assembled %s from %s\n" "$CANONICAL" "$PROMPT_DIR"

# 2. Symlink helper. Replaces existing symlinks; leaves regular files alone.
maybe_link() {
  local target="$1" link="$2"
  mkdir -p "$(dirname "$link")"
  if [ -L "$link" ] || [ ! -e "$link" ]; then
    ln -sf "$target" "$link"
    printf "[agent-prompts] linked %s -> %s\n" "$link" "$target"
  else
    printf "[agent-prompts] %s is a regular file, leaving alone\n" "$link"
  fi
}

# 3. Wire each provider's expected path to the canonical prompt.
maybe_link "$CANONICAL" "$HOME/.claude/CLAUDE.md"     # Claude Code
maybe_link "$CANONICAL" "$HOME/.codex/AGENTS.md"      # Codex CLI
maybe_link "$CANONICAL" "$HOME/.gemini/GEMINI.md"     # Gemini CLI

printf "[agent-prompts] Done.\n"
