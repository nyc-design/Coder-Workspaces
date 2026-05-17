#!/usr/bin/env bash
# vscode-web launcher (replaces registry.coder.com/coder/vscode-web module).
# Intentionally minimal: assumes the binary is on disk at
# INSTALL_PREFIX/bin/code-server (baked into base-dev) and that
# workspace-init.d has already handled extension installs and any
# settings.json files. This script mirrors the manifest-approved subset of
# the shared OpenVSX extensions dir into vscode-web's own extensions dir
# (so the editor sees a merged view with zero on-disk duplication) and
# launches the binary. Templated by Terraform: any token written here
# without escaping that matches the form of an HCL interpolation will be
# substituted at module-eval time.

set -e

# First-boot ownership fix: see code-server-launch.sh for the rationale.
sudo find /home/coder -xdev -not -user coder -exec chown -h coder:coder {} + 2>/dev/null || true

VSCODE_WEB="${INSTALL_PREFIX}/bin/code-server"
EXTENSIONS_DIR="${EXTENSIONS_DIR}"
SHARED_EXTENSIONS_DIR="${SHARED_EXTENSIONS_DIR}"
LOG_PATH="${LOG_PATH}"
PORT="${PORT}"
TELEMETRY_LEVEL="${TELEMETRY_LEVEL}"
SERVER_BASE_PATH="${SERVER_BASE_PATH}"

mkdir -p "$EXTENSIONS_DIR" "$SHARED_EXTENSIONS_DIR"

# Activation gate via filesystem: symlink only the manifest-approved subset
# of the shared cache into the per-editor extensions dir. User installs
# land as real directories (vscode-web writes to --extensions-dir) and are
# never touched — we only manage symlinks we own.

declare -A keep_set
if command -v compute-extension-enable-list >/dev/null 2>&1; then
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    keep_set["$${id,,}"]=1
  done < <(compute-extension-enable-list 2>/dev/null || true)
fi

ext_id() {
  printf '%s' "$1" | sed -E 's/-[0-9][0-9A-Za-z.+-]*$//'
}

shopt -s nullglob
if [ "$${#keep_set[@]}" -gt 0 ]; then
  for src in "$SHARED_EXTENSIONS_DIR"/*/; do
    src="$${src%/}"
    name="$(basename "$src")"
    id="$(ext_id "$name")"
    [ -z "$id" ] || [ "$id" = "$name" ] && continue
    [ -z "$${keep_set[$${id,,}]:-}" ] && continue
    link="$EXTENSIONS_DIR/$name"
    if [ -L "$link" ] || [ ! -e "$link" ]; then
      ln -snf "$src" "$link"
    fi
  done

  for entry in "$EXTENSIONS_DIR"/*/; do
    entry="$${entry%/}"
    [ -L "$entry" ] || continue
    name="$(basename "$entry")"
    id="$(ext_id "$name")"
    if [ -z "$${keep_set[$${id,,}]:-}" ] || [ ! -e "$entry" ]; then
      rm -f "$entry"
    fi
  done
else
  # Fail-open: mirror the entire shared cache.
  for src in "$SHARED_EXTENSIONS_DIR"/*/; do
    src="$${src%/}"
    name="$(basename "$src")"
    link="$EXTENSIONS_DIR/$name"
    if [ -L "$link" ] || [ ! -e "$link" ]; then
      ln -snf "$src" "$link"
    fi
  done
fi

SERVER_BASE_PATH_ARG=""
if [ -n "$SERVER_BASE_PATH" ]; then
  SERVER_BASE_PATH_ARG="--server-base-path=$SERVER_BASE_PATH"
fi

echo "Launching vscode-web on 127.0.0.1:$PORT (extensions: $EXTENSIONS_DIR)"
"$VSCODE_WEB" serve-local \
  --port="$PORT" \
  --host=127.0.0.1 \
  --accept-server-license-terms \
  --without-connection-token \
  --telemetry-level="$TELEMETRY_LEVEL" \
  --extensions-dir="$EXTENSIONS_DIR" \
  $SERVER_BASE_PATH_ARG \
  > "$LOG_PATH" 2>&1 &

echo "vscode-web PID $!; logs: $LOG_PATH"
