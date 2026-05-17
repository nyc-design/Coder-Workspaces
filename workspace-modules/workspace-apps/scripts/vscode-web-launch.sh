#!/usr/bin/env bash
# vscode-web launcher (replaces registry.coder.com/coder/vscode-web module).
# Intentionally minimal: assumes the binary is on disk at
# INSTALL_PREFIX/bin/code-server (baked into base-dev) and that
# workspace-init.d has already handled extension installs into the editor's
# own writable extensions dir.
# Templated by Terraform: any token written here without escaping that matches
# the form of an HCL interpolation will be substituted at module-eval time.

set -e

# First-boot ownership fix: see code-server-launch.sh for the rationale.
sudo find /home/coder -xdev -not -user coder -exec chown -h coder:coder {} + 2>/dev/null || true

VSCODE_WEB="${INSTALL_PREFIX}/bin/code-server"
EXTENSIONS_DIR="${EXTENSIONS_DIR}"
LOG_PATH="${LOG_PATH}"
PORT="${PORT}"
TELEMETRY_LEVEL="${TELEMETRY_LEVEL}"
SERVER_BASE_PATH="${SERVER_BASE_PATH}"

mkdir -p "$EXTENSIONS_DIR"

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
