#!/usr/bin/env bash
# Install (or refresh) extensions declared in any /usr/local/share/workspace-extensions.d/*.json
# manifest. Two install targets:
#   - "shared"          -> /home/coder/.vscode-extensions/shared      (OpenVSX, used by both editors)
#   - "vscode_web_only" -> /home/coder/.vscode-extensions/vscode-web  (Marketplace-only: Copilot, Gemini)
#
# Both target dirs are host-bound (workspace-runtime mounts), so installs persist across workspaces.
# code-server / vscode-web --install-extension is idempotent: it no-ops when the extension is already
# present, so this can run on every workspace start without churn.

set -euo pipefail

log() { printf '[extensions-install] %s\n' "$*"; }

MANIFEST_DIR="${MANIFEST_DIR:-/usr/local/share/workspace-extensions.d}"
SHARED_DIR="${SHARED_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/shared}"
VSCODE_WEB_DIR="${VSCODE_WEB_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/vscode-web}"
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

mkdir -p "$SHARED_DIR" "$VSCODE_WEB_DIR"

install_one() {
  local bin="$1" dir="$2" ext="$3" label="$4"
  if [ -z "$ext" ]; then return 0; fi
  if [ ! -x "$bin" ]; then
    log "[$label] skip $ext (binary $bin not present)"
    return 0
  fi
  if "$bin" --extensions-dir="$dir" --install-extension "$ext" > /tmp/ext-install.log 2>&1; then
    log "[$label] ok $ext"
  else
    rc=$?
    log "[$label] FAILED $ext (exit $rc)"
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

  while IFS= read -r ext; do
    install_one "$CODE_SERVER" "$SHARED_DIR" "$ext" "shared"
  done < <(jq -r '(.shared // [])[]' "$manifest")

  while IFS= read -r ext; do
    install_one "$VSCODE_WEB" "$VSCODE_WEB_DIR" "$ext" "vscode-web"
  done < <(jq -r '(.vscode_web_only // [])[]' "$manifest")
done

log "done"
