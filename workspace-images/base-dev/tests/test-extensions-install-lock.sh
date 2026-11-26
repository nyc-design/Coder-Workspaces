#!/usr/bin/env bash
# Fixture-based test for the install lock in 25-extensions-install.sh: several
# workspaces installing into one host-shared cache at the same time.
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly INSTALL="$repo_root/workspace-images/base-dev/init.d/25-extensions-install.sh"
readonly T="$(mktemp -d)"
lock_holder_pid=""
cleanup() {
  [ -n "$lock_holder_pid" ] && kill "$lock_holder_pid" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

S="$T/shared"; W="$T/vscode-web"; M="$T/manifests"; FAKE_LOG="$T/fake-log"
mkdir -p "$S" "$W" "$M" "$FAKE_LOG"

# Stand-in for the VS Code CLI. Like the real one it extracts into a temp dir
# inside the cache and renames that into place, which fails when another
# install of the same version got there first.
cat > "$T/fake-code-server" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
extensions_dir="" spec=""
for argument in "$@"; do
  case "$argument" in
    --extensions-dir=*) extensions_dir="${argument#*=}" ;;
    --install-extension) ;;
    *) spec="$argument" ;;
  esac
done
extension_id="${spec%@*}"; version="${spec#*@}"
destination="$extensions_dir/${extension_id,,}-$version-universal"

echo "$spec" >> "$FAKE_LOG/invocations"
if ls -l "/proc/$$/fd" | grep -q 'install\.lock'; then
  echo "$spec" >> "$FAKE_LOG/inherited-lock"
fi

extract_dir="$extensions_dir/.extract-$$"
mkdir -p "$extract_dir"
echo "$version" > "$extract_dir/package.json"
sleep "${FAKE_INSTALL_SECONDS:-1}"
# -T makes this a plain rename(2), which refuses a non-empty destination.
if ! mv -T "$extract_dir" "$destination" 2>/dev/null; then
  echo "ENOTEMPTY: directory not empty, rename '$extract_dir' -> '$destination'"
  rm -rf "$extract_dir"
  exit 1
fi
EOF
chmod +x "$T/fake-code-server"

export MANIFEST_DIR="$M" SHARED_EXTENSIONS_DIR="$S" VSCODE_WEB_EXTENSIONS_DIR="$W" \
  CODE_SERVER_BIN="$T/fake-code-server" VSCODE_WEB_BIN="$T/absent" \
  EXTENSIONS_CODE_SERVER_VSCODE_VERSION=1.138.0 FAKE_LOG

fail=0
chk() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
invocations() { wc -l < "$FAKE_LOG/invocations"; }

# Pinned specs only: unpinned ones resolve their version over the network.
printf '{"shared":["Test.first@1.0.0","Test.second@2.0.0"]}\n' > "$M/10-base.json"

echo "===== two workspaces install at once ====="
bash "$INSTALL" > "$T/workspace-a.log" 2>&1 & pid_a=$!
bash "$INSTALL" > "$T/workspace-b.log" 2>&1 & pid_b=$!
rc_a=0; wait "$pid_a" || rc_a=$?
rc_b=0; wait "$pid_b" || rc_b=$?
cat "$T/workspace-a.log" "$T/workspace-b.log"

chk "concurrent: both exit 0"            '[ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ]'
chk "concurrent: no install failed"      '! grep -q "FAILED" "$T/workspace-a.log" "$T/workspace-b.log"'
chk "concurrent: each version installed once" '[ "$(invocations)" -eq 2 ]'
chk "concurrent: both versions in cache" '[ -d "$S/test.first-1.0.0-universal" ] && [ -d "$S/test.second-2.0.0-universal" ]'
chk "concurrent: loser reuses the install" 'grep -q "installed by another workspace" "$T/workspace-a.log" "$T/workspace-b.log"'
chk "concurrent: no extract dir left"    '[ -z "$(find "$S" -maxdepth 1 -name ".extract-*")" ]'
chk "lock not inherited by the CLI"      '[ ! -e "$FAKE_LOG/inherited-lock" ]'

echo "===== cached versions skip the lock ====="
cached_out="$(bash "$INSTALL" 2>&1)"; echo "$cached_out"
chk "cached: reported from cache"        '[ "$(grep -c "already in cache" <<< "$cached_out")" -eq 2 ]'
chk "cached: CLI not invoked"            '[ "$(invocations)" -eq 2 ]'

echo "===== a held lock times out ====="
printf '{"shared":["Test.third@3.0.0"]}\n' > "$M/10-base.json"
# exec keeps the lock's descriptor in the sleep itself, so one kill releases it.
( exec 9> "$S/.install.lock"; flock 9; exec sleep 30 ) > /dev/null 2>&1 & lock_holder_pid=$!
sleep 0.5
timeout_out="$(EXTENSIONS_INSTALL_LOCK_TIMEOUT=1 bash "$INSTALL" 2>&1)"; echo "$timeout_out"
chk "timeout: reported"                  'grep -q "installing without it" <<< "$timeout_out"'
chk "timeout: still installed"           '[ -d "$S/test.third-3.0.0-universal" ]'
kill "$lock_holder_pid" 2>/dev/null || true; lock_holder_pid=""

exit $fail
