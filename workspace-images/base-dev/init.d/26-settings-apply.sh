#!/usr/bin/env bash
# Apply settings from /usr/local/share/workspace-settings.d/*.json manifests.
#
# .user    -> ~/.local/share/code-server/User/settings.json
#             written ONCE on first creation; user edits preserved on subsequent boots.
# .machine -> ~/.local/share/code-server/Machine/settings.json   (code-server)
#             -> ~/.vscode-server/data/Machine/settings.json     (vscode-web)
#             overwritten every boot; this is the template-managed default surface.
#
# Manifests are merged in filename-sort order; later wins on key collisions (so Tier 2 / per-env
# manifests can override Tier 1 base defaults if they really want to).

set -euo pipefail

log() { printf '[settings-apply] %s\n' "$*"; }

MANIFEST_DIR="${MANIFEST_DIR:-/usr/local/share/workspace-settings.d}"
USER_FILE="${CODE_SERVER_USER_SETTINGS:-$HOME/.local/share/code-server/User/settings.json}"
MACHINE_FILE_CS="${CODE_SERVER_MACHINE_SETTINGS:-$HOME/.local/share/code-server/Machine/settings.json}"
MACHINE_FILE_WEB="${VSCODE_WEB_MACHINE_SETTINGS:-$HOME/.vscode-server/data/Machine/settings.json}"

if [ ! -d "$MANIFEST_DIR" ]; then
  log "no manifest dir at $MANIFEST_DIR; nothing to apply"
  exit 0
fi

if ! command -v jq > /dev/null 2>&1; then
  log "jq not available; cannot merge settings" >&2
  exit 0
fi

shopt -s nullglob
manifests=("$MANIFEST_DIR"/*.json)
if [ ${#manifests[@]} -eq 0 ]; then
  log "no *.json manifests in $MANIFEST_DIR"
  exit 0
fi

# Merge .user across all manifests (later wins).
USER_MERGED=$(jq -s 'reduce .[] as $m ({}; . * ($m.user // {}))' "${manifests[@]}")
# Merge .machine across all manifests (later wins).
MACHINE_MERGED=$(jq -s 'reduce .[] as $m ({}; . * ($m.machine // {}))' "${manifests[@]}")

write_pretty() {
  local target="$1" payload="$2"
  mkdir -p "$(dirname "$target")"
  printf '%s\n' "$payload" | jq '.' > "$target"
}

if [ "$USER_MERGED" != "{}" ]; then
  if [ ! -f "$USER_FILE" ]; then
    log "writing initial code-server User settings -> $USER_FILE"
    write_pretty "$USER_FILE" "$USER_MERGED"
  else
    log "code-server User settings already present at $USER_FILE; leaving in place"
  fi
else
  log "no .user keys in any manifest"
fi

if [ "$MACHINE_MERGED" != "{}" ]; then
  log "writing code-server Machine settings -> $MACHINE_FILE_CS"
  write_pretty "$MACHINE_FILE_CS" "$MACHINE_MERGED"
  log "writing vscode-web   Machine settings -> $MACHINE_FILE_WEB"
  write_pretty "$MACHINE_FILE_WEB" "$MACHINE_MERGED"
else
  log "no .machine keys in any manifest"
fi

log "done"
