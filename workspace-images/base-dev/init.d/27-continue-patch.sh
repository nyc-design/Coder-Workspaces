#!/usr/bin/env bash
set -euo pipefail

log() { printf '[continue-patch-init] %s\n' "$*"; }

readonly helper="/usr/local/bin/continue-patch"

if [ ! -x "$helper" ]; then
  log "ERROR: Continue patch helper is missing or not executable: $helper" >&2
  exit 1
fi

# Keep startup and post-update behavior identical: the user-facing helper owns
# extension discovery, patching, postcondition checks, backups, and validation.
log "checking Continue extension browser compatibility patch"
"$helper"
