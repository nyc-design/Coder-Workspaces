#!/usr/bin/env bash
# Install Continue's config.yaml with CODESTRAL_API_KEY substituted from env.
# Rewritten on every boot so a rotated key is always picked up. Continue is
# autocomplete-only here — chat is served by the Claude Code sidecar — so there
# is no other state worth preserving.

set -euo pipefail

log() { printf '[continue] %s\n' "$*"; }

SRC="${CONTINUE_TEMPLATE:-/usr/local/share/workspace-continue.d/config.yaml}"
DEST="${CONTINUE_CONFIG:-$HOME/.continue/config.yaml}"

if [ ! -f "$SRC" ]; then
  log "no template at $SRC; nothing to apply"
  exit 0
fi

if [ -z "${CODESTRAL_API_KEY:-}" ]; then
  log "CODESTRAL_API_KEY not set; skipping (autocomplete will be inactive)"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
sed "s|__CODESTRAL_API_KEY__|${CODESTRAL_API_KEY}|g" "$SRC" > "$TMP"
mv "$TMP" "$DEST"
chmod 600 "$DEST"

log "wrote $DEST"
