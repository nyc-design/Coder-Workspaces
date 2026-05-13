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

# First-boot ownership fix: see code-server-launch.sh for the rationale.
sudo find /home/coder -xdev -not -user coder -exec chown coder:coder {} + 2>/dev/null || true

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

# Activation gate: vscode-web's --extensions-dir activates every extension
# subdir it finds (including the symlinks we just created into the shared
# cache). Disable any cached extension that isn't in the union of currently
# active manifests so only the manifest set is enabled.
# compute-extension-disable-list is baked into base-dev.
disable_args=()
if command -v compute-extension-disable-list >/dev/null 2>&1; then
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    disable_args+=(--disable-extension "$id")
  done < <(EXTENSIONS_DIR="$EXTENSIONS_DIR" compute-extension-disable-list 2>/dev/null || true)
fi

echo "Launching vscode-web on 127.0.0.1:$PORT (extensions: $EXTENSIONS_DIR, disabled: $${#disable_args[@]})"
"$VSCODE_WEB" serve-local \
  --port="$PORT" \
  --host=127.0.0.1 \
  --accept-server-license-terms \
  --without-connection-token \
  --telemetry-level="$TELEMETRY_LEVEL" \
  --extensions-dir="$EXTENSIONS_DIR" \
  $SERVER_BASE_PATH_ARG \
  "$${disable_args[@]}" \
  > "$LOG_PATH" 2>&1 &

echo "vscode-web PID $!; logs: $LOG_PATH"
