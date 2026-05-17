#!/usr/bin/env bash
# code-server launcher (replaces registry.coder.com/coder/code-server module).
# Intentionally minimal: assumes the binary is on disk at
# INSTALL_PREFIX/bin/code-server (baked into base-dev) and that
# workspace-init.d has already handled extension installs and any
# settings.json files. This script mirrors the manifest-approved subset of
# the shared OpenVSX extensions dir into code-server's own extensions dir
# (so the editor sees a merged view with zero on-disk duplication) and
# launches the binary. Templated by Terraform: any token written here
# without escaping that matches the form of an HCL interpolation will be
# substituted at module-eval time.

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

CODE_SERVER="${INSTALL_PREFIX}/bin/code-server"
EXTENSIONS_DIR="${EXTENSIONS_DIR}"
SHARED_EXTENSIONS_DIR="${SHARED_EXTENSIONS_DIR}"
LOG_PATH="${LOG_PATH}"
PORT="${PORT}"
APP_NAME="${APP_NAME}"

mkdir -p "$EXTENSIONS_DIR" "$SHARED_EXTENSIONS_DIR"

# Activation gate via filesystem: code-server has no --disable-extension
# flag, so we can't tell it to ignore cache contents at launch. Instead we
# point --extensions-dir at a per-editor dir and symlink in only the
# manifest-approved subset of the shared cache. User installs land as real
# directories in this dir (code-server writes to --extensions-dir) and we
# never touch real directories — only symlinks we own.

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
  # Symlink each manifest-approved cache entry. Leave existing real dirs
  # (user installs) and symlinks pointing at the correct target alone.
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

  # Prune our own stale symlinks: not in manifest, or pointing at a target
  # that's gone. Real directories (user installs) are preserved.
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
  # Fail-open: no manifest available (helper missing, MANIFEST_DIR empty,
  # etc.). Mirror the entire shared cache rather than disabling everything.
  for src in "$SHARED_EXTENSIONS_DIR"/*/; do
    src="$${src%/}"
    name="$(basename "$src")"
    link="$EXTENSIONS_DIR/$name"
    if [ -L "$link" ] || [ ! -e "$link" ]; then
      ln -snf "$src" "$link"
    fi
  done
fi

echo "Launching code-server on 127.0.0.1:$PORT (extensions: $EXTENSIONS_DIR)"
"$CODE_SERVER" \
  --auth=none \
  --bind-addr="127.0.0.1:$PORT" \
  --app-name="$APP_NAME" \
  --extensions-dir="$EXTENSIONS_DIR" \
  > "$LOG_PATH" 2>&1 &

echo "code-server PID $!; logs: $LOG_PATH"
