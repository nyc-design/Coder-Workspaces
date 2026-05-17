#!/usr/bin/env bash
# Install (or refresh) extensions declared in any /usr/local/share/workspace-extensions.d/*.json
# manifest. Two install targets:
#   - "shared"          -> both /home/coder/.vscode-extensions/code-server
#                              and /home/coder/.vscode-extensions/vscode-web
#                         (OpenVSX for code-server, Marketplace for vscode-web)
#   - "vscode_web_only" -> /home/coder/.vscode-extensions/vscode-web only
#                         (Marketplace-only: Copilot, Gemini)
#
# Manifest entries are either:
#   "publisher.name"             - latest version, but never downgrades a newer
#                                  version already installed (e.g. from UI update)
#   "publisher.name@1.2.3"       - pin exact version (force-installs if missing or
#                                  if a different version is on disk)
#
# History / why this design:
#   The previous layout installed every extension into a shared dir and symlinked
#   into per-editor dirs. That broke (a) code-server UI updates (which write a real
#   dir and rimraf'd through symlinks) and (b) version pinning (--install-extension
#   no-ops on any matching id-* dir). The per-editor dirs are now writable and
#   authoritative; the shared host mount is repurposed as a VSIX blob cache so we
#   still only download each (id, version) once across both editors.

set -euo pipefail

log() { printf '[extensions-install] %s\n' "$*"; }

MANIFEST_DIR="${MANIFEST_DIR:-/usr/local/share/workspace-extensions.d}"
CODE_SERVER_DIR="${CODE_SERVER_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/code-server}"
VSCODE_WEB_DIR="${VSCODE_WEB_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/vscode-web}"
VSIX_CACHE_DIR="${VSIX_CACHE_DIR:-/home/coder/.vscode-extensions/shared/_cache}"
CODE_SERVER="${CODE_SERVER_BIN:-/opt/code-server/bin/code-server}"
VSCODE_WEB="${VSCODE_WEB_BIN:-/opt/vscode-web/bin/code-server}"

if [ ! -d "$MANIFEST_DIR" ]; then
  log "no manifest dir at $MANIFEST_DIR; nothing to install"
  exit 0
fi

if ! command -v jq > /dev/null 2>&1; then
  log "jq not available; cannot parse manifests" >&2
  exit 0
fi

mkdir -p "$CODE_SERVER_DIR" "$VSCODE_WEB_DIR" "$VSIX_CACHE_DIR"

# One-time migration: the previous layout populated the per-editor dirs with
# symlinks pointing into the shared cache. Those break code-server's UI update
# path and confuse our installed_version probe. Remove any symlink entries so
# this script can re-install them as real directories. User-installed real
# extension dirs are left untouched.
for dir in "$CODE_SERVER_DIR" "$VSCODE_WEB_DIR"; do
  shopt -s nullglob
  for entry in "$dir"/*; do
    if [ -L "$entry" ]; then
      rm -f "$entry"
    fi
  done
done

# Parse "id" or "id@version" into globals: SPEC_ID, SPEC_VERSION (may be empty).
parse_spec() {
  local spec="$1"
  SPEC_ID="${spec%@*}"
  if [ "$spec" = "$SPEC_ID" ]; then
    SPEC_VERSION=""
  else
    SPEC_VERSION="${spec#*@}"
  fi
}

# Find the installed version of $1 in $2 (the editor extensions dir).
# Echoes the version string, or empty if not installed. Picks the highest version
# if multiple are present (shouldn't normally happen but be safe).
installed_version() {
  local id="$1" dir="$2"
  local id_lc; id_lc="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  shopt -s nullglob
  local best=""
  for entry in "$dir"/${id_lc}-*/; do
    entry="${entry%/}"
    local name; name="$(basename "$entry")"
    # name is publisher.name-version[-target]; strip leading "id-".
    local rest="${name#${id_lc}-}"
    # The trailing target suffix is either a single token ("universal", "web")
    # or two tokens separated by '-' ("linux-x64", "darwin-arm64", etc.).
    # Strip whichever form is present so $ver is just the version.
    local ver="$rest"
    case "$rest" in
      *-linux-x64|*-linux-arm64|*-darwin-x64|*-darwin-arm64|*-win32-x64|*-win32-arm64|*-alpine-x64|*-alpine-arm64)
        ver="${rest%-*-*}"
        ;;
      *-universal|*-web)
        ver="${rest%-*}"
        ;;
    esac
    if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best" "$ver" | sort -V | tail -1)" = "$ver" ]; then
      best="$ver"
    fi
  done
  printf '%s' "$best"
}

# Download a VSIX for (id, version) into the cache. Echoes the cached path on
# success, empty on failure. Tries OpenVSX first, then VS Code Marketplace.
fetch_vsix() {
  local id="$1" version="$2" source="$3"
  local publisher="${id%%.*}"
  local name="${id#*.}"
  local id_lc; id_lc="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  local out="$VSIX_CACHE_DIR/${id_lc}-${version}.vsix"

  if [ -f "$out" ] && [ -s "$out" ]; then
    printf '%s' "$out"
    return 0
  fi

  local urls=()
  case "$source" in
    openvsx)
      urls+=("https://open-vsx.org/api/${publisher}/${name}/${version}/file/${publisher}.${name}-${version}.vsix")
      ;;
    marketplace)
      urls+=("https://${publisher}.gallery.vsassets.io/_apis/public/gallery/publisher/${publisher}/extension/${name}/${version}/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage")
      ;;
    any|*)
      urls+=("https://open-vsx.org/api/${publisher}/${name}/${version}/file/${publisher}.${name}-${version}.vsix")
      urls+=("https://${publisher}.gallery.vsassets.io/_apis/public/gallery/publisher/${publisher}/extension/${name}/${version}/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage")
      ;;
  esac

  local tmp="${out}.partial"
  for url in "${urls[@]}"; do
    if curl -fsSL --max-time 120 -o "$tmp" "$url" 2>/dev/null; then
      mv "$tmp" "$out"
      printf '%s' "$out"
      return 0
    fi
  done
  rm -f "$tmp"
  return 1
}

# install_one <bin> <dir> <spec> <label> <source>
#   source: "openvsx" | "marketplace" (controls VSIX fetch fallback order and the
#           registry the editor binary itself talks to)
install_one() {
  local bin="$1" dir="$2" spec="$3" label="$4" source="$5"
  [ -n "$spec" ] || return 0
  if [ ! -x "$bin" ]; then
    log "[$label] skip $spec (binary $bin not present)"
    return 0
  fi

  parse_spec "$spec"
  local id="$SPEC_ID" want_version="$SPEC_VERSION"
  local have_version; have_version="$(installed_version "$id" "$dir")"

  if [ -n "$want_version" ]; then
    # Pinned version. No-op when already on disk. Replace otherwise.
    if [ "$have_version" = "$want_version" ]; then
      log "[$label] pinned $id@$want_version already installed"
      return 0
    fi
    if [ -n "$have_version" ]; then
      log "[$label] pinned $id@$want_version replacing $have_version"
      "$bin" --extensions-dir="$dir" --uninstall-extension "$id" > /tmp/ext-install.log 2>&1 || true
    fi
    local vsix; vsix="$(fetch_vsix "$id" "$want_version" "$source" || true)"
    if [ -z "$vsix" ]; then
      log "[$label] FAILED $id@$want_version (no VSIX downloadable)"
      return 0
    fi
    if "$bin" --extensions-dir="$dir" --install-extension "$vsix" > /tmp/ext-install.log 2>&1; then
      log "[$label] ok $id@$want_version (from $(basename "$vsix"))"
    else
      log "[$label] FAILED $id@$want_version (install error)"
      sed 's/^/    /' /tmp/ext-install.log
    fi
    return 0
  fi

  # Floating "latest" spec. If any version is already installed, leave it alone
  # so user-driven UI updates are preserved. Otherwise install whatever the
  # editor's registry serves as latest.
  if [ -n "$have_version" ]; then
    log "[$label] $id already installed ($have_version); leaving in place"
    return 0
  fi
  if "$bin" --extensions-dir="$dir" --install-extension "$id" > /tmp/ext-install.log 2>&1; then
    log "[$label] ok $id (latest)"
  else
    log "[$label] FAILED $id (exit $?)"
    sed 's/^/    /' /tmp/ext-install.log
  fi
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
    install_one "$CODE_SERVER" "$CODE_SERVER_DIR" "$spec" "code-server" "openvsx"
    install_one "$VSCODE_WEB"  "$VSCODE_WEB_DIR"  "$spec" "vscode-web"  "marketplace"
  done < <(jq -r '(.shared // [])[]' "$manifest")

  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    install_one "$VSCODE_WEB" "$VSCODE_WEB_DIR" "$spec" "vscode-web" "marketplace"
  done < <(jq -r '(.vscode_web_only // [])[]' "$manifest")
done

log "done"
