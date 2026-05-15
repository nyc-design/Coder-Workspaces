#!/bin/bash
# 13-agent-skills.sh — Build the canonical skills catalog at ~/.agents/skills
# from image-bundled SKILL.md directories plus skills installed via the
# `skills` CLI, then publish per-skill symlinks into every agent's expected
# skills directory.
#
# Persistence: ~/.agents is NOT bind-mounted from the host. The canonical
# catalog is rebuilt from scratch on every workspace start, sourced entirely
# from the immutable image layers below. This keeps per-workspace state in
# step with the running image — no drift across recreates, no manual cleanup
# of stale skills — and means skill updates ride alongside image updates.
# User-installed-at-runtime additions are NOT persisted (use the JSON
# install list below if you want a skill on every workspace).
#
# Inputs (populated by image-layer COPY directives; child images stack
# additively because each child's COPY targets the same shared directory):
#
#   /usr/local/share/workspace-skills.d/<name>/SKILL.md
#     Per-skill subdirectories shipped inside the image. Each must contain
#     SKILL.md. base-dev contributes the four agentmemory skills (recall,
#     remember, session-history, forget). Child images can ship their own —
#     e.g. workspace-images/python-dev/skills.d/python-lint/SKILL.md COPYs
#     to /usr/local/share/workspace-skills.d/python-lint/.
#
#   /usr/local/share/workspace-skills-install.d/<NN>-<name>.json
#     JSON arrays of `skills` CLI package names. The CLI fetches the
#     package and installs it under ~/.agents/skills. Sorted-prefix
#     filenames so child images can stack on top of base. Example
#     contents: ["vercel-labs/agent-skills"].
#
# Pipeline:
#   1. Reset ~/.agents/skills to a known-good state seeded from the image.
#      Confirmatory copy: skill-in-image AND skill-in-canonical → SKIP
#      (preserves anything we've already placed); skill-in-image AND NOT
#      in-canonical → ADD; skill-in-canonical only → LEAVE (never
#      subtractive, so a CLI install from earlier in this same run is not
#      clobbered when we re-enter on the next image-skills.d/ folder).
#   2. For each package listed in /usr/local/share/workspace-skills-install.d/
#      JSON files, invoke `skills add` to install it into the canonical.
#      Skipped if the package is already present (idempotent across runs).
#   3. Publish per-skill symlinks into each provider's expected location:
#        ~/.claude/skills/<name>   → ~/.agents/skills/<name>
#        ~/.codex/skills/<name>    → ~/.agents/skills/<name>
#        ~/.gemini/skills/<name>   → ~/.agents/skills/<name>
#        ~/.coder/skills/<name>    → ~/.agents/skills/<name>
#      Stale symlinks (pointing at ~/.agents/skills/<gone>) are cleaned up
#      first. Non-symlink entries (user-authored or hand-edited skills) are
#      left untouched.
#
# Coder Agents must be told to look at ~/.agents/skills via
# CODER_AGENT_EXP_SKILLS_DIRS in the workspace template's coder_agent env
# (its built-in default resolves .agents/skills relative to the project dir,
# not $HOME).

set -u

CANONICAL_SKILLS="$HOME/.agents/skills"
IMAGE_SKILLS_DIR="/usr/local/share/workspace-skills.d"
INSTALL_LIST_DIR="/usr/local/share/workspace-skills-install.d"

mkdir -p "$CANONICAL_SKILLS"

# 1. Seed image-bundled skills into the canonical catalog.
#    Three-state behavior (confirmatory, not duplicative, never subtractive):
#      - skill in image AND in canonical → SKIP
#      - skill in image AND NOT in canonical → ADD
#      - skill in canonical AND NOT in image → LEAVE
seed_image_skills() {
  local src_root="$1"
  local dst_root="$CANONICAL_SKILLS"
  [ -d "$src_root" ] || return 0

  shopt -s nullglob
  local src name dst
  for src in "$src_root"/*/; do
    [ -f "$src/SKILL.md" ] || continue
    name="$(basename "$src")"
    dst="$dst_root/$name"
    if [ -e "$dst" ]; then
      printf "[agent-skills] skill %s already present, skipping seed\n" "$name"
      continue
    fi
    cp -R "$src" "$dst"
    printf "[agent-skills] seeded skill %s -> %s\n" "$name" "$dst"
  done
  shopt -u nullglob
}

seed_image_skills "$IMAGE_SKILLS_DIR"

# 2. Install CLI-managed skills listed in the *.json files.
#    Each file is a JSON array of strings — skills CLI package names. Sorted
#    order so child-image files (20-*.json, 30-*.json) run after base
#    (10-*.json). `skills add --global` installs into ~/.agents/skills; we
#    pre-check with `skills list` so reruns are no-ops.
install_cli_skills() {
  local list_dir="$1"
  [ -d "$list_dir" ] || return 0

  if ! command -v skills >/dev/null 2>&1; then
    printf "[agent-skills] skills CLI not on PATH, skipping CLI installs\n"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf "[agent-skills] jq not on PATH, skipping CLI installs\n"
    return 0
  fi

  # Snapshot currently-installed packages once so we can cheaply skip duplicates.
  # `skills list` output shape is intentionally not parsed strictly; we just
  # grep for the package string. False positives here just mean we skip an
  # install — re-running with a deleted entry will install correctly.
  local installed
  installed="$(skills list 2>/dev/null || true)"

  shopt -s nullglob
  local list pkg
  for list in "$list_dir"/*.json; do
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      if printf "%s" "$installed" | grep -qF -- "$pkg"; then
        printf "[agent-skills] CLI skill %s already installed, skipping\n" "$pkg"
        continue
      fi
      printf "[agent-skills] installing CLI skill %s\n" "$pkg"
      # --global → ~/.agents/skills, --skill '*' → take everything the package
      # ships, --yes → no prompts. Step 3 normalizes provider symlinks, so we
      # don't care what (if anything) the CLI does to ~/.claude/skills etc.
      if ! skills add "$pkg" --global --skill '*' --yes; then
        printf "[agent-skills] WARNING: skills add %s failed (continuing)\n" "$pkg"
      fi
    done < <(jq -r 'if type=="array" then .[] else empty end' "$list" 2>/dev/null)
  done
  shopt -u nullglob
}

install_cli_skills "$INSTALL_LIST_DIR"

# 3. Publish per-skill symlinks into each agent's expected skills directory.
#    Provider dirs (~/.claude/, ~/.codex/, ~/.gemini/) are bind-mounted from
#    the host, so symlinks placed inside their skills/ subdir persist across
#    workspace recreates. That means we must (a) clean up dangling symlinks
#    pointing at canonical entries we no longer ship, and (b) refresh every
#    live symlink so it points at the current workspace's canonical path.
publish_provider_symlinks() {
  local provider_skills="$1"
  local canonical="$CANONICAL_SKILLS"

  # Old scheme used to symlink the whole skills/ dir to the canonical.
  # Detect that and convert to a real dir so we can place per-skill links.
  if [ -L "$provider_skills" ]; then
    rm "$provider_skills"
  fi
  mkdir -p "$provider_skills"

  # Clean stale per-skill symlinks. A symlink whose target lives under
  # canonical but no longer resolves to an existing file is stale.
  shopt -s nullglob
  local entry target
  for entry in "$provider_skills"/*; do
    [ -L "$entry" ] || continue
    target="$(readlink -- "$entry")"
    case "$target" in
      "$canonical"/*)
        if [ ! -e "$entry" ]; then
          rm -- "$entry"
          printf "[agent-skills] cleaned stale symlink %s\n" "$entry"
        fi
        ;;
    esac
  done
  shopt -u nullglob

  # Re-publish a symlink for every current canonical skill.
  shopt -s nullglob
  local src name link
  for src in "$canonical"/*/; do
    [ -f "$src/SKILL.md" ] || continue
    name="$(basename "$src")"
    link="$provider_skills/$name"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      printf "[agent-skills] %s is a regular file/dir, not relinking\n" "$link"
      continue
    fi
    ln -snf "$canonical/$name" "$link"
  done
  shopt -u nullglob
}

publish_provider_symlinks "$HOME/.claude/skills"
publish_provider_symlinks "$HOME/.codex/skills"
publish_provider_symlinks "$HOME/.gemini/skills"
publish_provider_symlinks "$HOME/.coder/skills"

printf "[agent-skills] Done.\n"
