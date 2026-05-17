#!/usr/bin/env bash
# code-server launcher (replaces registry.coder.com/coder/code-server module).
# Intentionally minimal: assumes the binary is on disk at
# INSTALL_PREFIX/bin/code-server (baked into base-dev) and that
# workspace-init.d has already handled extension installs and symlink curation.
# Templated by Terraform: any token written here without escaping that matches
# the form of an HCL interpolation will be substituted at module-eval time.

set -e

# First-boot ownership fix: envbuilder may leave parts of /home/coder owned
# by uids other than coder. Coder runs coder_agent.startup_script (which has
# its own chown step) in parallel with coder_script resources, so we cannot
# rely on workspace-startup's chown landing first. Doing it inline here keeps
# the launcher correct under any ordering. Idempotent and fast when there's
# nothing to fix. `-h` operates on symlinks without dereferencing, so broken
# symlinks in bind-mounted subdirs (e.g. .claude/debug/latest pointing at a
# rotated log) don't fail the sweep.
sudo find /home/coder -xdev -not -user coder -exec chown -h coder:coder {} + 2>/dev/null || true

# Wait for workspace-startup's init pipeline (in particular
# 25-extensions-install.sh + 30-extensions-activate.sh) to populate the
# per-editor symlink farm before launching the editor. Timeout after 5 min so
# we never block startup indefinitely.
for i in $(seq 1 300); do
  [ -f /tmp/workspace-init.done ] && break
  sleep 1
done

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
