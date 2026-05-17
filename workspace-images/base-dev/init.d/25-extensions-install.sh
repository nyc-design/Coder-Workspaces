#!/usr/bin/env bash
# Install (or refresh) extensions declared in any /usr/local/share/workspace-extensions.d/*.json
# manifest into a host-bound shared cache. Per-editor extension dirs that are
# passed to the editor binaries are populated separately by
# 30-extensions-activate.sh, which symlinks the active manifest set out of this
# cache so each workspace sees only the extensions its manifest requested.
#
# Manifest entries:
#   "publisher.name"             - track latest. On every workspace start we query
#                                  the registry for the current latest version and
#                                  install it into the shared cache if missing.
#   "publisher.name@1.2.3"       - pin exact version. Installed once into the
#                                  shared cache, noop on subsequent runs.
#
# Layout:
#   shared/                      - extracted OpenVSX extensions (code-server source)
#   shared/_cache/               - VSIX blobs fetched from OpenVSX
#   shared/_marketplace/         - extracted Marketplace extensions (vscode-web only)
#   shared/_marketplace/_cache/  - VSIX blobs fetched from the Marketplace
#
# Cache lifecycle:
#   shared/ is a host-bound bind mount used by every workspace on this host, so we
#   never delete a version another workspace might still want. After ensuring the
#   target version of an id is present, we delete OLDER versions of that id only
#   if their mtime is older than EXTENSIONS_TTL_DAYS (default 30). The activate
#   script runs `touch -h` on each symlinked version at workspace start so
#   actively-used versions never age out.
#
# Failure modes:
#   - Registry unreachable for an unpinned id: leave existing shared entries
#     untouched; activate will pick the highest available version.
#   - VSIX download fails for a pinned id: log + skip. Activate will leave the
#     symlink unchanged so the previous version (if any) stays in use.

set -euo pipefail

log() { printf '[extensions-install] %s\n' "$*"; }

MANIFEST_DIR="${MANIFEST_DIR:-/usr/local/share/workspace-extensions.d}"
SHARED_DIR="${SHARED_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/shared}"
MARKETPLACE_DIR="${MARKETPLACE_EXTENSIONS_DIR:-$SHARED_DIR/_marketplace}"
VSIX_CACHE_DIR="${VSIX_CACHE_DIR:-$SHARED_DIR/_cache}"
MARKETPLACE_VSIX_CACHE_DIR="${MARKETPLACE_VSIX_CACHE_DIR:-$MARKETPLACE_DIR/_cache}"
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

mkdir -p "$SHARED_DIR" "$MARKETPLACE_DIR" "$VSIX_CACHE_DIR" "$MARKETPLACE_VSIX_CACHE_DIR"

# Parse "id" or "id@version" -> globals SPEC_ID, SPEC_VERSION.
parse_spec() {
  local spec="$1"
  SPEC_ID="${spec%@*}"
  if [ "$spec" = "$SPEC_ID" ]; then
    SPEC_VERSION=""
  else
    SPEC_VERSION="${spec#*@}"
  fi
}

# Strip platform target suffix (-linux-x64, -universal, ...) from "<version>[-target]".
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

# Echo the on-disk directory name for $id-$version (with any target suffix) under
# $dir, or empty if not present.
installed_dirname() {
  local id="$1" version="$2" dir="$3"
  local id_lc; id_lc="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  shopt -s nullglob
  for entry in "$dir"/${id_lc}-${version} "$dir"/${id_lc}-${version}-*; do
    [ -d "$entry" ] && { basename "$entry"; return 0; }
  done
}

# Query the registry for the latest version of $id. Echoes version string or empty.
fetch_latest_version() {
  local id="$1" source="$2"
  local publisher="${id%%.*}"
  local name="${id#*.}"

  case "$source" in
    openvsx)
      curl -fsSL --max-time 20 "https://open-vsx.org/api/${publisher}/${name}" 2>/dev/null \
        | jq -r '.version // empty' 2>/dev/null
      ;;
    marketplace)
      local payload
      payload=$(printf '{"filters":[{"criteria":[{"filterType":7,"value":"%s"}]}],"flags":914}' "$id")
      curl -fsSL --max-time 20 \
        -H 'Accept: application/json;api-version=3.0-preview.1' \
        -H 'Content-Type: application/json' \
        -X POST \
        --data "$payload" \
        'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' 2>/dev/null \
        | jq -r '.results[0].extensions[0].versions[0].version // empty' 2>/dev/null
      ;;
  esac
}

# Fetch the VSIX for ($id, $version) into $cache_dir. Echoes path on success.
fetch_vsix() {
  local id="$1" version="$2" source="$3" cache_dir="$4"
  local publisher="${id%%.*}"
  local name="${id#*.}"
  local id_lc; id_lc="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  local out="$cache_dir/${id_lc}-${version}.vsix"

  if [ -f "$out" ] && [ -s "$out" ]; then
    printf '%s' "$out"
    return 0
  fi

  local url
  case "$source" in
    openvsx)
      url="https://open-vsx.org/api/${publisher}/${name}/${version}/file/${publisher}.${name}-${version}.vsix"
      ;;
    marketplace)
      url="https://${publisher}.gallery.vsassets.io/_apis/public/gallery/publisher/${publisher}/extension/${name}/${version}/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"
      ;;
    *) return 1 ;;
  esac

  local tmp="${out}.partial"
  if curl -fsSL --max-time 120 -o "$tmp" "$url" 2>/dev/null; then
    mv "$tmp" "$out"
    printf '%s' "$out"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Delete older-than-$want versions of $id from $dir whose mtime is past TTL.
# Same id newer than $want is left alone (other workspaces may want it).
prune_older_versions() {
  local id="$1" want_version="$2" dir="$3" cache_dir="$4"
  local id_lc; id_lc="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  shopt -s nullglob
  for entry in "$dir"/${id_lc}-*/; do
    entry="${entry%/}"
    local name; name="$(basename "$entry")"
    local rest="${name#${id_lc}-}"
    local ver; ver="$(strip_target "$rest")"
    if [ "$ver" = "$want_version" ]; then continue; fi
    # Skip versions >= want.
    if [ "$(printf '%s\n%s\n' "$ver" "$want_version" | sort -V | tail -1)" = "$ver" ]; then
      continue
    fi
    if find "$entry" -maxdepth 0 -mtime "+$EXTENSIONS_TTL_DAYS" -print 2>/dev/null | grep -q .; then
      log "  prune stale $name (older than $want_version, mtime > ${EXTENSIONS_TTL_DAYS}d)"
      rm -rf -- "$entry"
      rm -f -- "$cache_dir/${id_lc}-${ver}.vsix"
    fi
  done
}

# install_one <bin> <dir> <cache_dir> <spec> <label> <source>
install_one() {
  local bin="$1" dir="$2" cache_dir="$3" spec="$4" label="$5" source="$6"
  [ -n "$spec" ] || return 0
  if [ ! -x "$bin" ]; then
    log "[$label] skip $spec (binary $bin not present)"
    return 0
  fi

  parse_spec "$spec"
  local id="$SPEC_ID" want_version="$SPEC_VERSION"

  if [ -z "$want_version" ]; then
    want_version="$(fetch_latest_version "$id" "$source" || true)"
    if [ -z "$want_version" ]; then
      log "[$label] $id: registry lookup failed; keeping existing shared entries"
      return 0
    fi
  fi

  if [ -n "$(installed_dirname "$id" "$want_version" "$dir")" ]; then
    log "[$label] $id@$want_version already in shared cache"
  else
    local vsix
    if ! vsix="$(fetch_vsix "$id" "$want_version" "$source" "$cache_dir")" || [ -z "$vsix" ]; then
      log "[$label] FAILED $id@$want_version (VSIX download)"
      return 0
    fi
    if "$bin" --extensions-dir="$dir" --install-extension "$vsix" > /tmp/ext-install.log 2>&1; then
      log "[$label] installed $id@$want_version into shared (from $(basename "$vsix"))"
    else
      log "[$label] FAILED $id@$want_version (install error)"
      sed 's/^/    /' /tmp/ext-install.log
      return 0
    fi
  fi

  prune_older_versions "$id" "$want_version" "$dir" "$cache_dir"
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
    [ -n "$spec" ] || continue
    install_one "$CODE_SERVER" "$SHARED_DIR" "$VSIX_CACHE_DIR" "$spec" "shared" "openvsx"
  done < <(jq -r '(.shared // [])[]' "$manifest")

  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    install_one "$VSCODE_WEB" "$MARKETPLACE_DIR" "$MARKETPLACE_VSIX_CACHE_DIR" "$spec" "vscode-web-only" "marketplace"
  done < <(jq -r '(.vscode_web_only // [])[]' "$manifest")
done

log "done"
