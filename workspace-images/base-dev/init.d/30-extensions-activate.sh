#!/usr/bin/env bash
# Curate editor extension directories from the shared OpenVSX cache.
#
# workspace-init.d installs manifest-declared OpenVSX extensions into the
# shared cache. This script runs after that install step and:
#
#   1. PROMOTE: if a per-editor dir has a REAL (non-symlink) extension dir
#      whose id is in the active manifest set, move it back into the shared
#      cache and replace it with a symlink. This is how code-server UI
#      updates ("Update" button) get reconciled: the UI installs into the
#      per-editor dir, we move it into shared/ on next start so other editors
#      and other workspaces see it too, and 25-extensions-install.sh's manifest
#      pin (if any) will re-assert the pinned version on the next start.
#
#   2. SYNC: link shared-cache entries matching the active manifest set into
#      each per-editor dir (code-server, vscode-web, vscode-server,
#      cursor-server). Stale symlinks (manifest dropped, or target gone) are
#      pruned. Real (non-symlink, non-manifest) entries -- e.g. user-installed
#      extensions -- are never touched.
#
#   3. TOUCH: refresh the mtime of every shared/ dir referenced by an active
#      symlink so the TTL prune in 25-extensions-install.sh never reaps a
#      version that is in active use by any workspace.

set -euo pipefail

MANIFEST_DIR="${MANIFEST_DIR:-/usr/local/share/workspace-extensions.d}"
WORKSPACES_ROOT="${WORKSPACES_ROOT:-/workspaces}"
SHARED_EXTENSIONS_DIR="${SHARED_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/shared}"
CODE_SERVER_EXTENSIONS_DIR="${CODE_SERVER_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/code-server}"
VSCODE_WEB_EXTENSIONS_DIR="${VSCODE_WEB_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/vscode-web}"
VSCODE_SERVER_EXTENSIONS_DIR="${VSCODE_SERVER_EXTENSIONS_DIR:-/home/coder/.vscode-server/extensions}"
CURSOR_SERVER_EXTENSIONS_DIR="${CURSOR_SERVER_EXTENSIONS_DIR:-/home/coder/.cursor-server/extensions}"

log() { printf '[extensions-activate] %s\n' "$*"; }

# Strip trailing -<ver>[-<arch>] (e.g. "-1.2.3-universal" or "-1.2.3-linux-x64").
ext_id() {
  printf '%s' "$1" | sed -E 's/-[0-9][0-9A-Za-z.+-]*(-[a-z0-9_]+(-[a-z0-9_]+)?)?$//'
}

add_manifest_id() {
  local id="$1"
  [ -n "$id" ] || return 0
  # Strip @version suffix if present.
  id="${id%@*}"
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

# Promote a UI-installed real extension dir from a per-editor dir back into
# the shared cache, then replace it with a symlink. No-op when:
#   - the entry is a symlink (already curated)
#   - the id is not in the active manifest set (user-installed; leave it alone)
#   - the shared cache already has the same versioned dir (idempotent re-runs)
promote_real_to_shared() {
  local target_dir="$1"
  [ -d "$target_dir" ] || return 0
  shopt -s nullglob
  local promoted=0
  for entry in "$target_dir"/*/; do
    entry="${entry%/}"
    [ -L "$entry" ] && continue
    local name id
    name="$(basename "$entry")"
    id="$(ext_id "$name")"
    [ -z "$id" ] || [ "$id" = "$name" ] && continue
    [ -z "${manifest_set[${id,,}]:-}" ] && continue

    local dest="$SHARED_EXTENSIONS_DIR/$name"
    if [ -e "$dest" ]; then
      # Shared cache already has this exact version (likely from a previous
      # promote on another editor). Drop the per-editor copy and let SYNC
      # symlink it.
      rm -rf -- "$entry"
    else
      mv -- "$entry" "$dest"
      log "promoted $(basename "$target_dir")/$name -> shared/"
    fi
    promoted=$((promoted + 1))
  done
  return 0
}

# sync_editor_dir <editor_name> <target_dir> <do_promote>
#   do_promote: "1" to promote real dirs back into the shared cache. Pass "0"
#               for vscode-web because its target_dir IS its own host-bound
#               extension store -- there is nowhere to promote to.
sync_editor_dir() {
  local editor_name="$1"
  local target_dir="$2"
  local do_promote="$3"
  mkdir -p "$target_dir" "$SHARED_EXTENSIONS_DIR"

  if [ "$do_promote" = "1" ]; then
    promote_real_to_shared "$target_dir"
  fi

  shopt -s nullglob
  if [ "${#manifest_set[@]}" -gt 0 ]; then
    local linked=0 pruned=0
    for src in "$SHARED_EXTENSIONS_DIR"/*/; do
      src="${src%/}"
      local name id link
      name="$(basename "$src")"
      case "$name" in _*) continue ;; esac
      id="$(ext_id "$name")"
      [ -z "$id" ] || [ "$id" = "$name" ] && continue
      [ -z "${manifest_set[${id,,}]:-}" ] && continue
      link="$target_dir/$name"
      if [ -L "$link" ] || [ ! -e "$link" ]; then
        ln -snf "$src" "$link"
        linked=$((linked + 1))
      fi
      # Touch the shared cache entry so TTL prune (in 25) never reaps an
      # actively-linked version.
      touch -c "$src" 2>/dev/null || true
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
      case "$name" in _*) continue ;; esac
      link="$target_dir/$name"
      if [ -L "$link" ] || [ ! -e "$link" ]; then
        ln -snf "$src" "$link"
        linked=$((linked + 1))
      fi
      touch -c "$src" 2>/dev/null || true
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

sync_editor_dir "code-server"    "$CODE_SERVER_EXTENSIONS_DIR"    1
sync_editor_dir "vscode-web"     "$VSCODE_WEB_EXTENSIONS_DIR"     0
sync_editor_dir "vscode-server"  "$VSCODE_SERVER_EXTENSIONS_DIR"  1
sync_editor_dir "cursor-server"  "$CURSOR_SERVER_EXTENSIONS_DIR"  1
