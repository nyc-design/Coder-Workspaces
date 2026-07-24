#!/usr/bin/env bash
# Install (or refresh) extensions declared in any
# /usr/local/share/workspace-extensions.d/*.json manifest. Three install targets:
#
#   - "shared"            -> /home/coder/.vscode-extensions/shared      (OpenVSX, used by both editors)
#   - "shared_marketplace" -> /home/coder/.vscode-extensions/shared      (native Marketplace VSIX, code-server compatible)
#   - "vscode_web_only"   -> /home/coder/.vscode-extensions/vscode-web  (Marketplace, vscode-web only)
#
# Both target dirs are host-bound (workspace-runtime mounts), so installs
# persist across workspaces. Manifests may pin a version with `<id>@<ver>` or
# leave it unpinned. Behavior:
#
#   - Pinned (`<id>@<ver>`): install only if `<dir>/<id>-<ver>-*/` is absent.
#     The manifest pin always wins -- if the user updated via the UI to a
#     different version, the activate step (30) promotes that real dir into
#     the shared cache, then this script re-asserts the pin on the next start.
#
#   - Unpinned (`<id>`): query the relevant registry (OpenVSX for shared,
#     Marketplace for shared_marketplace and vscode_web_only) for the latest version, then install
#     only if `<dir>/<id>-<latest>-*/` is absent. One HTTP call per unpinned
#     id; no install if we're already current.
#
# Older versions of the same id are NEVER uninstalled here; other workspaces
# may still reference them via their own pin or symlink. Cleanup is handled
# by the TTL prune below.

set -euo pipefail

log() { printf '[extensions-install] %s\n' "$*"; }

MANIFEST_DIR="${MANIFEST_DIR:-/usr/local/share/workspace-extensions.d}"
SHARED_DIR="${SHARED_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/shared}"
VSCODE_WEB_DIR="${VSCODE_WEB_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/vscode-web}"
CODE_SERVER="${CODE_SERVER_BIN:-/opt/code-server/bin/code-server}"
VSCODE_WEB="${VSCODE_WEB_BIN:-/opt/vscode-web/bin/code-server}"
EXTENSIONS_TTL_DAYS="${EXTENSIONS_TTL_DAYS:-30}"

if [ ! -d "$MANIFEST_DIR" ]; then
  log "no manifest dir at $MANIFEST_DIR; nothing to install"
  exit 0
fi

if ! command -v jq > /dev/null 2>&1; then
  log "jq not available; cannot parse manifests" >&2
  exit 0
fi

mkdir -p "$SHARED_DIR" "$VSCODE_WEB_DIR"

# Does `<dir>/<id>-<ver>-*/` exist (case-insensitive on id)?
has_version() {
  local dir="$1" id_lc ver
  id_lc="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  ver="$3"
  shopt -s nullglob nocaseglob
  local hits=("$dir"/${id_lc}-${ver}-*/)
  shopt -u nocaseglob
  [ "${#hits[@]}" -gt 0 ]
}

# Resolve latest version from OpenVSX for `<publisher>.<name>`.
latest_openvsx() {
  local id="$1" pub name
  pub="${id%%.*}"; name="${id#*.}"
  curl -sSfL --max-time 10 "https://open-vsx.org/api/${pub}/${name}" \
    | jq -r '.version // empty' 2>/dev/null
}

# Query VS Code Marketplace metadata for `<publisher>.<name>`.
# flags=914 (0x382): IncludeVersions|IncludeAssetUri|IncludeVersionProperties|ExcludeNonValidated|IncludeLatestVersionOnly
marketplace_versions() {
  local id="$1"
  curl -sSfL --max-time 10 \
    -H 'Accept: application/json;api-version=3.0-preview.1' \
    -H 'Content-Type: application/json' \
    -X POST 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' \
    -d "{\"filters\":[{\"criteria\":[{\"filterType\":7,\"value\":\"${id}\"}]}],\"flags\":914}"
}

latest_marketplace() {
  marketplace_versions "$1" | jq -r '.results[0].extensions[0].versions[0].version // empty' 2>/dev/null
}

marketplace_target_platform() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'linux-x64' ;;
    aarch64|arm64) printf 'linux-arm64' ;;
    *) return 1 ;;
  esac
}

# Print the latest native Marketplace VSIX as `<version>\t<url>`.
marketplace_targeted_vsix() {
  local id="$1" target
  target="$(marketplace_target_platform)" || {
    log "[shared-marketplace] unsupported architecture $(uname -m) for $id"
    return 1
  }

  marketplace_versions "$id" | jq -r --arg target "$target" '
    .results[0].extensions[0].versions[]
    | select(.targetPlatform == $target)
    | . as $version
    | ($version.files[] | select(.assetType == "Microsoft.VisualStudio.Services.VSIXPackage") | .source) as $url
    | "\($version.version)\t\($url)"
  ' 2>/dev/null | head -n1
}

# install_extension <bin> <dir> <spec> <label> <resolver>
#   spec: "id" or "id@ver"
#   resolver: command that prints latest version when spec is unpinned
install_extension() {
  local bin="$1" dir="$2" spec="$3" label="$4" resolver="$5"
  [ -z "$spec" ] && return 0
  if [ ! -x "$bin" ]; then
    log "[$label] skip $spec (binary $bin not present)"
    return 0
  fi

  local id ver
  if [[ "$spec" == *"@"* ]]; then
    id="${spec%@*}"; ver="${spec#*@}"
  else
    id="$spec"; ver=""
    ver="$("$resolver" "$id" || true)"
    if [ -z "$ver" ]; then
      log "[$label] could not resolve latest version for $id; trying install anyway"
    fi
  fi

  if [ -n "$ver" ] && has_version "$dir" "$id" "$ver"; then
    log "[$label] ok $id@$ver (already in cache)"
    return 0
  fi

  local install_spec="$id"
  [ -n "$ver" ] && install_spec="$id@$ver"

  if "$bin" --extensions-dir="$dir" --install-extension "$install_spec" > /tmp/ext-install.log 2>&1; then
    log "[$label] ok $install_spec (installed)"
  else
    rc=$?
    log "[$label] FAILED $install_spec (exit $rc)"
    sed 's/^/    /' /tmp/ext-install.log
  fi
}

# Install the current-architecture Marketplace VSIX into the shared cache so
# code-server can activate it through its normal shared-cache symlink farm.
install_marketplace_targeted_extension() {
  local bin="$1" dir="$2" spec="$3"
  [ -z "$spec" ] && return 0
  if [ ! -x "$bin" ]; then
    log "[shared-marketplace] skip $spec (binary $bin not present)"
    return 0
  fi

  local id requested_ver resolved version url vsix rc
  if [[ "$spec" == *"@"* ]]; then
    id="${spec%@*}"; requested_ver="${spec#*@}"
  else
    id="$spec"; requested_ver=""
  fi
  resolved="$(marketplace_targeted_vsix "$id" || true)"
  if [ -z "$resolved" ]; then
    log "[shared-marketplace] could not resolve targeted Marketplace VSIX for $id"
    return 0
  fi
  IFS=$'\t' read -r version url <<< "$resolved"
  if [ -n "$requested_ver" ] && [ "$requested_ver" != "$version" ]; then
    log "[shared-marketplace] requested $id@$requested_ver but Marketplace exposes $version for this target"
    return 0
  fi
  if has_version "$dir" "$id" "$version"; then
    log "[shared-marketplace] ok $id@$version (already in cache)"
    return 0
  fi

  vsix="$(mktemp /tmp/extension-vsix.XXXXXX)"
  if ! curl -sSfL --max-time 120 -o "$vsix" "$url"; then
    log "[shared-marketplace] FAILED downloading $id@$version"
    rm -f "$vsix"
    return 0
  fi
  if "$bin" --extensions-dir="$dir" --install-extension "$vsix" > /tmp/ext-install.log 2>&1; then
    log "[shared-marketplace] ok $id@$version (installed targeted Marketplace VSIX)"
  else
    rc=$?
    log "[shared-marketplace] FAILED $id@$version (exit $rc)"
    sed 's/^/    /' /tmp/ext-install.log
  fi
  rm -f "$vsix"
}

# Prune <dir>: per id, delete `<id>-<oldver>-*/` whose mtime is older than
# EXTENSIONS_TTL_DAYS, but only if a newer version of the same id is present.
# This keeps active (symlinked, touched by 30) and recently-installed versions
# while reaping abandoned ones.
prune_old_versions() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  local ttl="$EXTENSIONS_TTL_DAYS"
  [ -z "$ttl" ] || [ "$ttl" -le 0 ] && return 0

  shopt -s nullglob
  declare -A latest_mtime
  declare -A latest_path

  # First pass: find the newest mtime per id.
  for entry in "$dir"/*/; do
    entry="${entry%/}"
    local base="$(basename "$entry")"
    case "$base" in _*) continue ;; esac
    # Strip trailing -<ver>-<arch> (e.g. "-1.2.3-universal" or "-1.2.3-linux-x64").
    local id_lc
    id_lc="$(printf '%s' "$base" | sed -E 's/-[0-9][0-9A-Za-z.+-]*(-[a-z0-9_]+(-[a-z0-9_]+)?)?$//' | tr '[:upper:]' '[:lower:]')"
    [ -z "$id_lc" ] && continue
    local m
    m="$(stat -c '%Y' "$entry" 2>/dev/null || echo 0)"
    if [ -z "${latest_mtime[$id_lc]:-}" ] || [ "$m" -gt "${latest_mtime[$id_lc]}" ]; then
      latest_mtime[$id_lc]="$m"
      latest_path[$id_lc]="$entry"
    fi
  done

  # Second pass: delete older entries past TTL.
  local cutoff
  cutoff="$(date -d "$ttl days ago" +%s 2>/dev/null || echo 0)"
  [ "$cutoff" -le 0 ] && return 0
  local pruned=0
  for entry in "$dir"/*/; do
    entry="${entry%/}"
    local base="$(basename "$entry")"
    case "$base" in _*) continue ;; esac
    local id_lc
    id_lc="$(printf '%s' "$base" | sed -E 's/-[0-9][0-9A-Za-z.+-]*(-[a-z0-9_]+(-[a-z0-9_]+)?)?$//' | tr '[:upper:]' '[:lower:]')"
    [ -z "$id_lc" ] && continue
    # Keep the newest version regardless of age.
    [ "$entry" = "${latest_path[$id_lc]:-}" ] && continue
    local m
    m="$(stat -c '%Y' "$entry" 2>/dev/null || echo 0)"
    if [ "$m" -lt "$cutoff" ]; then
      rm -rf -- "$entry"
      pruned=$((pruned + 1))
      log "pruned stale $(basename "$entry")"
    fi
  done
  [ "$pruned" -gt 0 ] && log "pruned $pruned stale entries from $dir"
  return 0
}

shopt -s nullglob
manifests=("$MANIFEST_DIR"/*.json)
if [ ${#manifests[@]} -eq 0 ]; then
  log "no *.json manifests in $MANIFEST_DIR"
  exit 0
fi

for manifest in "${manifests[@]}"; do
  log "reading $(basename "$manifest")"

  while IFS= read -r spec; do
    install_extension "$CODE_SERVER" "$SHARED_DIR" "$spec" "shared" latest_openvsx
  done < <(jq -r '(.shared // [])[]' "$manifest")

  while IFS= read -r spec; do
    install_marketplace_targeted_extension "$CODE_SERVER" "$SHARED_DIR" "$spec"
  done < <(jq -r '(.shared_marketplace // [])[]' "$manifest")

  while IFS= read -r spec; do
    install_extension "$VSCODE_WEB" "$VSCODE_WEB_DIR" "$spec" "vscode-web" latest_marketplace
  done < <(jq -r '(.vscode_web_only // [])[]' "$manifest")
done

prune_old_versions "$SHARED_DIR"
prune_old_versions "$VSCODE_WEB_DIR"

log "done"
