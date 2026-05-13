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

# First-boot ownership fix: envbuilder may leave parts of /home/coder owned
# by uids other than coder. Coder runs coder_agent.startup_script (which has
# its own chown step) in parallel with coder_script resources, so we cannot
# rely on workspace-startup's chown landing first. Doing it inline here keeps
# the launcher correct under any ordering. Idempotent and fast when there's
# nothing to fix.
sudo find /home/coder -xdev -not -user coder -exec chown coder:coder {} + 2>/dev/null || true

CODE_SERVER="${INSTALL_PREFIX}/bin/code-server"
EXTENSIONS_DIR="${EXTENSIONS_DIR}"
LOG_PATH="${LOG_PATH}"
PORT="${PORT}"
APP_NAME="${APP_NAME}"

mkdir -p "$EXTENSIONS_DIR"

# Activation gate: code-server's --extensions-dir flag activates every
# extension subdir it finds, but the shared cache may contain extensions
# from other workspace types (or past projects). Compute the diff between
# cache contents and the union of currently active manifests, and pass
# --disable-extension for each leftover so only the manifest set is
# enabled. compute-extension-disable-list is baked into base-dev.
disable_args=()
if command -v compute-extension-disable-list >/dev/null 2>&1; then
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    disable_args+=(--disable-extension "$id")
  done < <(EXTENSIONS_DIR="$EXTENSIONS_DIR" compute-extension-disable-list 2>/dev/null || true)
fi

echo "Launching code-server on 127.0.0.1:$PORT (extensions: $EXTENSIONS_DIR, disabled: $${#disable_args[@]})"
"$CODE_SERVER" \
  --auth=none \
  --bind-addr="127.0.0.1:$PORT" \
  --app-name="$APP_NAME" \
  --extensions-dir="$EXTENSIONS_DIR" \
  "$${disable_args[@]}" \
  > "$LOG_PATH" 2>&1 &

echo "code-server PID $!; logs: $LOG_PATH"
