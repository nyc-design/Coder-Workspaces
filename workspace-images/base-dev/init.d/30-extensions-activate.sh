#!/usr/bin/env bash
# Curate editor extension directories from the shared OpenVSX cache.
#
# workspace-init.d installs manifest-declared OpenVSX extensions into the
# shared cache. This script runs after that install step and exposes only the
# active manifest set to each editor by symlinking matching shared-cache
# entries into per-editor extension dirs. User-installed extensions are real
# directories in those per-editor dirs; this script never touches them.

set -euo pipefail

MANIFEST_DIR="${MANIFEST_DIR:-/usr/local/share/workspace-extensions.d}"
WORKSPACES_ROOT="${WORKSPACES_ROOT:-/workspaces}"
SHARED_EXTENSIONS_DIR="${SHARED_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/shared}"
CODE_SERVER_EXTENSIONS_DIR="${CODE_SERVER_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/code-server}"
VSCODE_WEB_EXTENSIONS_DIR="${VSCODE_WEB_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/vscode-web}"
VSCODE_SERVER_EXTENSIONS_DIR="${VSCODE_SERVER_EXTENSIONS_DIR:-/home/coder/.vscode-server/extensions}"
CURSOR_SERVER_EXTENSIONS_DIR="${CURSOR_SERVER_EXTENSIONS_DIR:-/home/coder/.cursor-server/extensions}"

log() { printf '[extensions-activate] %s\n' "$*"; }

ext_id() {
  printf '%s' "$1" | sed -E 's/-[0-9][0-9A-Za-z.+-]*$//'
}

add_manifest_id() {
  local id="$1"
  [ -n "$id" ] || return 0
  manifest_set["${id,,}"]=1
}

collect_project_extensions() {
  local manifest="$1"
  FILE="$manifest" node <<'NODE'
const fs = require('fs');
const path = require('path');
const file = process.env.FILE;
let text;
try { text = fs.readFileSync(file, 'utf8'); } catch (e) { process.exit(0); }
text = text
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/^([^"\n]*?)\/\/.*$/gm, '$1')
  .replace(/,(\s*[}\]])/g, '$1');
let data;
try { data = JSON.parse(text); } catch (e) { process.exit(0); }
const base = path.basename(file);
let ids = [];
if (base === 'devcontainer.json') {
  ids = data?.customizations?.vscode?.extensions ?? [];
} else if (base === 'extensions.json') {
  ids = data?.recommendations ?? [];
}
for (const id of ids) {
  if (typeof id === 'string' && id.trim()) {
    process.stdout.write(id.trim() + '\n');
  }
}
NODE
}

sync_editor_dir() {
  local editor_name="$1"
  local target_dir="$2"
  mkdir -p "$target_dir" "$SHARED_EXTENSIONS_DIR"

  shopt -s nullglob
  if [ "${#manifest_set[@]}" -gt 0 ]; then
    local linked=0 pruned=0
    for src in "$SHARED_EXTENSIONS_DIR"/*/; do
      src="${src%/}"
      local name id link
      name="$(basename "$src")"
      id="$(ext_id "$name")"
      [ -z "$id" ] || [ "$id" = "$name" ] && continue
      [ -z "${manifest_set[${id,,}]:-}" ] && continue
      link="$target_dir/$name"
      if [ -L "$link" ] || [ ! -e "$link" ]; then
        ln -snf "$src" "$link"
        linked=$((linked + 1))
      fi
    done

    for entry in "$target_dir"/*; do
      [ -L "$entry" ] || continue
      local name id
      name="$(basename "$entry")"
      id="$(ext_id "$name")"
      if [ -z "${manifest_set[${id,,}]:-}" ] || [ ! -e "$entry" ]; then
        rm -f "$entry"
        pruned=$((pruned + 1))
      fi
    done
    log "$editor_name: synced manifest extensions (linked/repointed: $linked, pruned stale symlinks: $pruned)"
  else
    # Fail-open: no manifest available. Mirror the whole shared cache rather
    # than hiding every extension.
    local linked=0
    for src in "$SHARED_EXTENSIONS_DIR"/*/; do
      src="${src%/}"
      local name link
      name="$(basename "$src")"
      link="$target_dir/$name"
      if [ -L "$link" ] || [ ! -e "$link" ]; then
        ln -snf "$src" "$link"
        linked=$((linked + 1))
      fi
    done
    log "$editor_name: no manifest set found; mirrored shared cache (linked/repointed: $linked)"
  fi
}

declare -A manifest_set

# Tier 1 + Tier 2 manifests baked into the image.
if [ -d "$MANIFEST_DIR" ] && command -v jq >/dev/null 2>&1; then
  shopt -s nullglob
  for manifest in "$MANIFEST_DIR"/*.json; do
    while IFS= read -r ext; do
      add_manifest_id "$ext"
    done < <(jq -r '((.shared // []) + (.vscode_web_only // []))[]' "$manifest" 2>/dev/null || true)
  done
fi

# Tier 3 project manifests.
if [ -d "$WORKSPACES_ROOT" ] && command -v node >/dev/null 2>&1; then
  shopt -s nullglob
  for project in "$WORKSPACES_ROOT"/*/; do
    project="${project%/}"
    name="$(basename "$project")"
    case "$name" in .*) continue ;; esac

    for manifest in "$project/.devcontainer/devcontainer.json" "$project/.vscode/extensions.json"; do
      [ -f "$manifest" ] || continue
      while IFS= read -r ext; do
        add_manifest_id "$ext"
      done < <(collect_project_extensions "$manifest")
    done
  done
fi

log "manifest extension IDs: ${#manifest_set[@]}"

sync_editor_dir "code-server" "$CODE_SERVER_EXTENSIONS_DIR"
sync_editor_dir "vscode-web" "$VSCODE_WEB_EXTENSIONS_DIR"
sync_editor_dir "vscode-server" "$VSCODE_SERVER_EXTENSIONS_DIR"
sync_editor_dir "cursor-server" "$CURSOR_SERVER_EXTENSIONS_DIR"
