#!/usr/bin/env bash
# code-server launcher (replaces registry.coder.com/coder/code-server module).
# Intentionally minimal: assumes the binary is on disk at
# INSTALL_PREFIX/bin/code-server (baked into base-dev) and that
# workspace-init.d has already handled extension installs and any
# settings.json files. This script only ensures the extensions dir exists
# and launches the binary. Templated by Terraform: any token written here
# without escaping that matches the form of an HCL interpolation will be
# substituted at module-eval time.

set -e

CODE_SERVER="${INSTALL_PREFIX}/bin/code-server"
EXTENSIONS_DIR="${EXTENSIONS_DIR}"
LOG_PATH="${LOG_PATH}"
PORT="${PORT}"
APP_NAME="${APP_NAME}"

mkdir -p "$EXTENSIONS_DIR"

echo "Launching code-server on 127.0.0.1:$PORT (extensions: $EXTENSIONS_DIR)"
"$CODE_SERVER" \
  --auth=none \
  --bind-addr="127.0.0.1:$PORT" \
  --app-name="$APP_NAME" \
  --extensions-dir="$EXTENSIONS_DIR" \
  > "$LOG_PATH" 2>&1 &

echo "code-server PID $!; logs: $LOG_PATH"
