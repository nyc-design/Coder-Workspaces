#!/bin/bash
# 13-agent-skills.sh — Normalize skill catalogs so every agent reads from
# the same canonical folder, and seed image-bundled skills into it.
#
# Skills are persistent across workspace recreates via the host bind mount
# on /home/ubuntu/secrets/.agents → ~/.agents. The `skills` npm CLI also
# installs natively into ~/.agents/skills, so making that the single source
# of truth means everything (image-bundled, CLI-installed, user-edited)
# lives in one place.
#
# What this script does:
#   1. Make ~/.agents/skills the canonical catalog. Each agent's expected
#      skills directory (~/.claude/skills, ~/.codex/skills, ~/.gemini/skills,
#      ~/.coder/skills) becomes a folder-level symlink to it. First run
#      migrates any pre-existing real-dir contents — skill subdirs with
#      SKILL.md are adopted into the canonical if not already present;
#      everything else lands in ~/.agents/skills-migration-backup/ for
#      manual reconciliation.
#   2. Seed image-bundled skills from /usr/local/share/workspace-skills.d/
#      into the canonical, with strictly confirmatory semantics:
#        - skill in skills.d AND in canonical    → SKIP   (never overwrites)
#        - skill in skills.d AND NOT in canonical → ADD
#        - skill in canonical AND NOT in skills.d → LEAVE (never subtractive)
#
# Coder Agents must be told to look at ~/.agents/skills via
# CODER_AGENT_EXP_SKILLS_DIRS in the workspace template's coder_agent env
# (its built-in default resolves .agents/skills relative to the project dir,
# not $HOME).

set -u

CANONICAL_SKILLS="$HOME/.agents/skills"
IMAGE_SKILLS_DIR="/usr/local/share/workspace-skills.d"

mkdir -p "$CANONICAL_SKILLS"

# 1. Canonicalize each agent's skills directory as a symlink to ~/.agents/skills.
#    Idempotent: existing symlinks are refreshed; missing dirs are created;
#    real dirs have their contents migrated before being replaced with a link.
migrate_skills_dir_to_link() {
  local link="$1"
  local canonical="$CANONICAL_SKILLS"

  if [ -L "$link" ]; then
    ln -snf "$canonical" "$link"
    printf "[agent-skills] refreshed symlink %s -> %s\n" "$link" "$canonical"
    return
  fi
  if [ ! -e "$link" ]; then
    mkdir -p "$(dirname "$link")"
    ln -s "$canonical" "$link"
    printf "[agent-skills] linked %s -> %s\n" "$link" "$canonical"
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
      printf "[agent-skills] adopted %s/%s into canonical\n" "$agent_name" "$name"
    else
      mkdir -p "$backup_root"
      mv "$entry" "$backup_root/"
      printf "[agent-skills] backed up %s/%s -> %s\n" "$agent_name" "$name" "$backup_root"
    fi
  done
  shopt -u nullglob dotglob

  rmdir "$link" 2>/dev/null || rm -rf "$link"
  ln -s "$canonical" "$link"
  printf "[agent-skills] linked %s -> %s\n" "$link" "$canonical"
}

migrate_skills_dir_to_link "$HOME/.claude/skills"
migrate_skills_dir_to_link "$HOME/.codex/skills"
migrate_skills_dir_to_link "$HOME/.gemini/skills"
migrate_skills_dir_to_link "$HOME/.coder/skills"

# 2. Seed image-bundled skills into the canonical catalog (confirmatory).
#    Each subdir of /usr/local/share/workspace-skills.d/ is one skill
#    (must contain SKILL.md). The base-dev image installs the four
#    agentmemory skills there; child images can layer their own by
#    adding workspace-images/<child>/skills.d/ and a parallel COPY into
#    /usr/local/share/workspace-skills.d/ in their Dockerfile.
#
# Three-state behavior (confirmatory, not duplicative, never subtractive):
#   - skill present in skills.d AND in canonical → SKIP
#       Persisted catalog wins. Image updates do NOT overwrite skills the
#       user may have edited in place. To force-refresh a skill after a
#       base-image update, `rm -rf ~/.agents/skills/<name>` and restart.
#   - skill present in skills.d AND NOT in canonical → ADD
#       Fresh workspace, or a new skill introduced by an image bump.
#   - skill in canonical AND NOT in skills.d → LEAVE
#       User-installed (via `skills` CLI) or hand-authored. Never removed
#       by this script — it is purely additive against the catalog.
seed_image_skills() {
  local src_root="$1"
  local dst_root="$CANONICAL_SKILLS"
  [ -d "$src_root" ] || return 0

  local src name dst
  for src in "$src_root"/*/; do
    [ -d "$src" ] || continue
    [ -f "$src/SKILL.md" ] || continue
    name="$(basename "$src")"
    dst="$dst_root/$name"
    if [ -e "$dst" ]; then
      printf "[agent-skills] skill %s already present, skipping\n" "$name"
      continue
    fi
    cp -R "$src" "$dst"
    printf "[agent-skills] seeded skill %s -> %s\n" "$name" "$dst"
  done
}

seed_image_skills "$IMAGE_SKILLS_DIR"

printf "[agent-skills] Done.\n"
