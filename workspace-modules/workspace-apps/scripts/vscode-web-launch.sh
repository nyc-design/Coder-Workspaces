#!/usr/bin/env bash
# vscode-web launcher (replaces registry.coder.com/coder/vscode-web module).
# Intentionally minimal: assumes the binary is on disk at
# INSTALL_PREFIX/bin/code-server (baked into base-dev) and that
# workspace-init.d has already handled extension installs and any
# settings.json files. This script only mirrors the shared OpenVSX extension
# directory into vscode-web's extensions dir (so the editor sees a merged
# view with zero on-disk duplication) and launches the binary. Templated by
# Terraform: any token written here without escaping that matches the form
# of an HCL interpolation will be substituted at module-eval time.

set -e

VSCODE_WEB="${INSTALL_PREFIX}/bin/code-server"
EXTENSIONS_DIR="${EXTENSIONS_DIR}"
SHARED_EXTENSIONS_DIR="${SHARED_EXTENSIONS_DIR}"
LOG_PATH="${LOG_PATH}"
PORT="${PORT}"
TELEMETRY_LEVEL="${TELEMETRY_LEVEL}"
SERVER_BASE_PATH="${SERVER_BASE_PATH}"

mkdir -p "$EXTENSIONS_DIR" "$SHARED_EXTENSIONS_DIR"

# Mirror each extension subdirectory from the shared OpenVSX dir into the
# vscode-web extensions dir as a symlink. vscode-web reads the union (its own
# marketplace installs + symlinked shared extensions) without on-disk
# duplication. Real subdirectories already in vscode-web/ (its own installs)
# are left untouched; only stale symlinks are repointed.
shopt -s nullglob
for ext in "$SHARED_EXTENSIONS_DIR"/*/; do
  ext="$${ext%/}"
  name="$(basename "$ext")"
  link="$EXTENSIONS_DIR/$name"
  if [ -L "$link" ] || [ ! -e "$link" ]; then
    ln -snf "$ext" "$link"
  fi
done

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
