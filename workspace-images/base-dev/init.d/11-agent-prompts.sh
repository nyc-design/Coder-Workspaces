#!/bin/bash
# 11-agent-prompts.sh — Assemble the workspace system prompt and wire it
# into every agent's expected read path. Also normalize skill catalogs so
# every agent sees the same skills from one canonical folder.
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
#   4. Make ~/.agents/skills the single canonical skill catalog (where the
#      `skills` npm CLI installs natively) and turn each per-agent skills
#      directory into a folder-level symlink to it. First run migrates any
#      pre-existing real-dir contents into the canonical (skills with
#      SKILL.md not already there are adopted; everything else is moved
#      under ~/.agents/skills-migration-backup/). Coder Agents must be
#      told to look at ~/.agents/skills via CODER_AGENT_EXP_SKILLS_DIRS
#      in the workspace template's coder_agent env (its built-in default
#      resolves .agents/skills relative to the project dir, not $HOME).

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

# 4. Single canonical skill catalog at ~/.agents/skills (where the `skills`
#    CLI installs natively + persistent across workspaces via the host bind
#    mount on /home/ubuntu/secrets/.agents). Every agent's skills/ path
#    becomes a folder-level symlink to it. Migration of any pre-existing
#    real-dir contents is idempotent — skill subdirs with SKILL.md are
#    adopted into the canonical if not already present; everything else
#    (loose files, duplicate skill dirs, agent-specific subfolders like
#    Codex's .system/) lands in ~/.agents/skills-migration-backup/<agent>/
#    for manual reconciliation.
mkdir -p "$HOME/.agents/skills"

migrate_skills_dir_to_link() {
  local link="$1"
  local canonical="$HOME/.agents/skills"

  if [ -L "$link" ]; then
    ln -snf "$canonical" "$link"
    printf "[agent-prompts] refreshed symlink %s -> %s\n" "$link" "$canonical"
    return
  fi
  if [ ! -e "$link" ]; then
    mkdir -p "$(dirname "$link")"
    ln -s "$canonical" "$link"
    printf "[agent-prompts] linked %s -> %s\n" "$link" "$canonical"
    return
  fi

  # Real directory present — migrate contents before converting to symlink.
  local agent_name backup_root
  agent_name="$(basename "$(dirname "$link")")"
  backup_root="$HOME/.agents/skills-migration-backup/${agent_name#.}-$(date +%Y%m%d-%H%M%S)"

  shopt -s nullglob dotglob
  local entry name
  for entry in "$link"/*; do
    name="$(basename "$entry")"
    case "$name" in .|..) continue ;; esac

    if [ -L "$entry" ]; then
      # Stale per-skill symlink (skills CLI managed) — already in canonical.
      rm "$entry"
    elif [ -d "$entry" ] && [ -f "$entry/SKILL.md" ] && [ ! -e "$canonical/$name" ]; then
      mv "$entry" "$canonical/"
      printf "[agent-prompts] adopted %s/%s into canonical\n" "$agent_name" "$name"
    else
      mkdir -p "$backup_root"
      mv "$entry" "$backup_root/"
      printf "[agent-prompts] backed up %s/%s -> %s\n" "$agent_name" "$name" "$backup_root"
    fi
  done
  shopt -u nullglob dotglob

  rmdir "$link" 2>/dev/null || rm -rf "$link"
  ln -s "$canonical" "$link"
  printf "[agent-prompts] linked %s -> %s\n" "$link" "$canonical"
}

migrate_skills_dir_to_link "$HOME/.claude/skills"
migrate_skills_dir_to_link "$HOME/.codex/skills"
migrate_skills_dir_to_link "$HOME/.gemini/skills"
migrate_skills_dir_to_link "$HOME/.coder/skills"

# 5. Seed image-bundled skills into the canonical catalog.
#    Each subdir of /usr/local/share/agentmemory-skills/ contains a SKILL.md
#    that wraps an agentmemory MCP tool flow (recall, remember,
#    session-history, forget). We copy each into ~/.agents/skills/<name>/
#    only if absent — idempotent on every workspace start, never overwrites
#    user-modified copies. To force-refresh after a base-image update,
#    delete the target subdir and the next workspace start will re-seed it.
seed_image_skills() {
  local src_root="$1"
  local dst_root="$HOME/.agents/skills"
  [ -d "$src_root" ] || return 0
  mkdir -p "$dst_root"

  local src name dst
  for src in "$src_root"/*/; do
    [ -d "$src" ] || continue
    [ -f "$src/SKILL.md" ] || continue
    name="$(basename "$src")"
    dst="$dst_root/$name"
    if [ -e "$dst" ]; then
      printf "[agent-prompts] skill %s already present, leaving alone\n" "$name"
      continue
    fi
    cp -R "$src" "$dst"
    printf "[agent-prompts] seeded skill %s -> %s\n" "$name" "$dst"
  done
}

seed_image_skills "/usr/local/share/agentmemory-skills"

printf "[agent-prompts] Done.\n"
