#!/usr/bin/env bash
# Curate per-editor extension directories from the shared cache.
#
# 25-extensions-install.sh populates the shared cache (shared/ for OpenVSX,
# shared/_marketplace/ for Marketplace). This script then:
#
#   1. PROMOTE: any real (non-symlink) extension directory in a per-editor dir
#      whose id is in the manifest is moved into the shared cache, then replaced
#      with a symlink. This is the path for UI-installed updates: code-server's
#      update UI writes a new id-NEWVER-target/ directory into its extensions
#      dir; on the next workspace start we promote it so the new version is
#      available to every workspace.
#
#   2. SYNC: for each manifest id, pick a target version:
#        pinned   -> the pinned version (manifest wins, even if a newer one was
#                    UI-installed)
#        unpinned -> the highest version of that id present in the shared cache
#      Create or repoint a symlink in each per-editor dir to the chosen entry.
#      Drop stale symlinks (wrong version, or id no longer in manifest).
#
#   3. TOUCH: `touch -h` each symlinked shared entry and its cached VSIX so
#      25's TTL prune never evicts an actively-used version.
#
# User-installed extensions whose id is NOT in any manifest are left in place as
# real directories. They survive but are not promoted to the shared cache.

set -euo pipefail

MANIFEST_DIR="${MANIFEST_DIR:-/usr/local/share/workspace-extensions.d}"
WORKSPACES_ROOT="${WORKSPACES_ROOT:-/workspaces}"
SHARED_DIR="${SHARED_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/shared}"
MARKETPLACE_DIR="${MARKETPLACE_EXTENSIONS_DIR:-$SHARED_DIR/_marketplace}"
VSIX_CACHE_DIR="${VSIX_CACHE_DIR:-$SHARED_DIR/_cache}"
MARKETPLACE_VSIX_CACHE_DIR="${MARKETPLACE_VSIX_CACHE_DIR:-$MARKETPLACE_DIR/_cache}"
CODE_SERVER_EXTENSIONS_DIR="${CODE_SERVER_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/code-server}"
VSCODE_WEB_EXTENSIONS_DIR="${VSCODE_WEB_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/vscode-web}"

log() { printf '[extensions-activate] %s\n' "$*"; }

strip_target() {
  local rest="$1"
  case "$rest" in
    *-linux-x64|*-linux-arm64|*-darwin-x64|*-darwin-arm64|*-win32-x64|*-win32-arm64|*-alpine-x64|*-alpine-arm64)
      printf '%s' "${rest%-*-*}"
      ;;
    *-universal|*-web)
      printf '%s' "${rest%-*}"
      ;;
    *)
      printf '%s' "$rest"
      ;;
  esac
}

# Echo "id<TAB>version" parsed from a "<id_lc>-<version>[-target]" directory name.
# Heuristic: split on "-<digit>" since extension versions always start with a digit.
parse_dirname() {
  local name="$1"
  if [[ "$name" =~ ^(.*)-([0-9][^-]*(-[0-9][^-]*)*)((-(linux|darwin|win32|alpine)-[a-z0-9]+|-(universal|web))?)$ ]]; then
    printf '%s\t%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# Build the manifest set: lowercased id -> "pinned_version" or "" (unpinned).
declare -A manifest_pin

add_manifest_spec() {
  local spec="$1"
  [ -n "$spec" ] || return 0
  local id="${spec%@*}" ver=""
  if [ "$spec" != "$id" ]; then ver="${spec#*@}"; fi
  manifest_pin["${id,,}"]="$ver"
}

# Marketplace-only ids (vscode_web_only in manifests). These get their source
# from $MARKETPLACE_DIR instead of $SHARED_DIR.
declare -A marketplace_only

add_marketplace_spec() {
  local spec="$1"
  [ -n "$spec" ] || return 0
  local id="${spec%@*}"
  marketplace_only["${id,,}"]=1
  add_manifest_spec "$spec"
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

# Tier 1 + Tier 2: image manifests.
if [ -d "$MANIFEST_DIR" ] && command -v jq >/dev/null 2>&1; then
  shopt -s nullglob
  for manifest in "$MANIFEST_DIR"/*.json; do
    while IFS= read -r spec; do
      add_manifest_spec "$spec"
    done < <(jq -r '(.shared // [])[]' "$manifest" 2>/dev/null || true)
    while IFS= read -r spec; do
      add_marketplace_spec "$spec"
    done < <(jq -r '(.vscode_web_only // [])[]' "$manifest" 2>/dev/null || true)
  done
fi

# Tier 3: project manifests (always unpinned).
if [ -d "$WORKSPACES_ROOT" ] && command -v node >/dev/null 2>&1; then
  shopt -s nullglob
  for project in "$WORKSPACES_ROOT"/*/; do
    project="${project%/}"
    name="$(basename "$project")"
    case "$name" in .*) continue ;; esac
    for manifest in "$project/.devcontainer/devcontainer.json" "$project/.vscode/extensions.json"; do
      [ -f "$manifest" ] || continue
      while IFS= read -r spec; do
        add_manifest_spec "${spec%@*}"
      done < <(collect_project_extensions "$manifest")
    done
  done
fi

log "manifest ids: ${#manifest_pin[@]} (marketplace-only: ${#marketplace_only[@]})"

mkdir -p "$SHARED_DIR" "$MARKETPLACE_DIR" "$CODE_SERVER_EXTENSIONS_DIR" "$VSCODE_WEB_EXTENSIONS_DIR"

# Source dir for a given manifest id.
source_dir_for() {
  local id_lc="$1"
  if [ -n "${marketplace_only[$id_lc]:-}" ]; then
    printf '%s' "$MARKETPLACE_DIR"
  else
    printf '%s' "$SHARED_DIR"
  fi
}

# 1. PROMOTE: walk each per-editor dir for real dirs whose id is in the manifest
#    and lift them into the shared cache.
promote_editor_dir() {
  local editor_name="$1" target_dir="$2"
  shopt -s nullglob
  local promoted=0
  for entry in "$target_dir"/*/; do
    entry="${entry%/}"
    [ -d "$entry" ] || continue
    [ -L "$entry" ] && continue  # only real dirs
    local name; name="$(basename "$entry")"
    local id_ver; id_ver="$(parse_dirname "$name" || true)"
    [ -z "$id_ver" ] && continue
    local id="${id_ver%%$'\t'*}"
    local id_lc="${id,,}"
    [ -n "${manifest_pin[$id_lc]+x}" ] || continue
    local src_dir; src_dir="$(source_dir_for "$id_lc")"
    local shared_target="$src_dir/$name"
    if [ -e "$shared_target" ] && [ ! -L "$shared_target" ]; then
      # Already in the shared cache; the local copy is redundant.
      rm -rf -- "$entry"
      continue
    fi
    mv -- "$entry" "$shared_target"
    promoted=$((promoted + 1))
  done
  [ "$promoted" -gt 0 ] && log "$editor_name: promoted $promoted UI-installed extension(s) to shared cache"
  return 0
}

# 2+3. SYNC + TOUCH for one editor dir.
sync_editor_dir() {
  local editor_name="$1" target_dir="$2"
  shopt -s nullglob

  # Compute desired (name on disk in shared cache) per manifest id.
  declare -A desired_names=()  # id_lc -> dirname in shared cache
  declare -A desired_versions=() # id_lc -> version
  for id_lc in "${!manifest_pin[@]}"; do
    local pin="${manifest_pin[$id_lc]}"
    local src_dir; src_dir="$(source_dir_for "$id_lc")"
    local best_ver="" best_name=""
    local entry name rest ver
    for entry in "$src_dir"/${id_lc}-*/; do
      entry="${entry%/}"
      name="$(basename "$entry")"
      rest="${name#${id_lc}-}"
      ver="$(strip_target "$rest")"
      if [ -n "$pin" ]; then
        if [ "$ver" = "$pin" ]; then
          best_ver="$ver"; best_name="$name"
          break
        fi
        continue
      fi
      if [ -z "$best_ver" ] || [ "$(printf '%s\n%s\n' "$best_ver" "$ver" | sort -V | tail -1)" = "$ver" ]; then
        best_ver="$ver"; best_name="$name"
      fi
    done
    if [ -n "$best_name" ]; then
      desired_names["$id_lc"]="$best_name"
      desired_versions["$id_lc"]="$best_ver"
    fi
  done

  # Drop symlinks that point at the wrong thing or whose id is no longer in the
  # manifest. Real dirs are left alone (user-installed unmanaged extensions).
  local pruned=0
  for entry in "$target_dir"/*; do
    [ -L "$entry" ] || continue
    local name; name="$(basename "$entry")"
    local id_ver; id_ver="$(parse_dirname "$name" || true)"
    if [ -z "$id_ver" ]; then
      rm -f -- "$entry"; pruned=$((pruned + 1)); continue
    fi
    local id="${id_ver%%$'\t'*}"
    local id_lc="${id,,}"
    local want_name="${desired_names[$id_lc]:-}"
    if [ -z "$want_name" ] || [ "$want_name" != "$name" ]; then
      rm -f -- "$entry"; pruned=$((pruned + 1))
    fi
  done

  # Create/repoint symlinks for each desired entry; touch the shared target and
  # its cached VSIX to refresh TTL.
  local linked=0
  for id_lc in "${!desired_names[@]}"; do
    local name="${desired_names[$id_lc]}"
    local ver="${desired_versions[$id_lc]}"
    local src_dir; src_dir="$(source_dir_for "$id_lc")"
    local cache_dir
    if [ -n "${marketplace_only[$id_lc]:-}" ]; then
      cache_dir="$MARKETPLACE_VSIX_CACHE_DIR"
    else
      cache_dir="$VSIX_CACHE_DIR"
    fi
    local src="$src_dir/$name"
    local link="$target_dir/$name"
    [ -d "$src" ] || continue
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$src" ]; then
      : # already correct
    else
      ln -snf "$src" "$link"
      linked=$((linked + 1))
    fi
    touch -h -- "$src" 2>/dev/null || true
    [ -f "$cache_dir/${id_lc}-${ver}.vsix" ] && touch -- "$cache_dir/${id_lc}-${ver}.vsix" 2>/dev/null || true
  done

  log "$editor_name: synced (linked/repointed: $linked, pruned: $pruned, manifest ids: ${#desired_names[@]})"
}

# Run promote across both per-editor dirs first (so both editors' UI updates can
# contribute to the shared cache), then sync.
promote_editor_dir "code-server" "$CODE_SERVER_EXTENSIONS_DIR"
promote_editor_dir "vscode-web"  "$VSCODE_WEB_EXTENSIONS_DIR"

sync_editor_dir "code-server" "$CODE_SERVER_EXTENSIONS_DIR"
sync_editor_dir "vscode-web"  "$VSCODE_WEB_EXTENSIONS_DIR"
