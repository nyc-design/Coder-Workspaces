#!/usr/bin/env bash
# Fixture-based test for the shared extension cache lifecycle:
#   30-extensions-activate.sh  (promote, one-version-per-id sync, lease)
#   31-extensions-prune.sh     (lease-aware reaping of unused versions)
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly INIT="$repo_root/workspace-images/base-dev/init.d"
readonly T="$(mktemp -d)"
cleanup() {
  [ -f "$T/refresh.pid" ] && kill "$(cat "$T/refresh.pid")" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

mk() { mkdir -p "$1"; echo "$2" > "$1/package.json"; }

S="$T/shared"; W="$T/vscode-web"; CS="$T/code-server"; VS="$T/vscode-server"; CU="$T/cursor-server"
M="$T/manifests"; P="$T/workspaces/proj/.devcontainer"
mkdir -p "$S" "$W" "$CS" "$VS" "$CU" "$M" "$P"

# shared cache: several versions
for v in 2.1.193 2.1.227 2.1.269; do mk "$S/anthropic.claude-code-$v-linux-arm64" "$v"; done
for v in 26.5623.31443 26.5715.31925 26.5908.31748; do mk "$S/openai.chatgpt-$v-linux-arm64" "$v"; done
for v in 2026.60.0 2026.80.0; do mk "$S/charliermarsh.ruff-$v-linux-arm64" "$v"; done
for v in 1.4.0 2.0.0; do mk "$S/abridge.file-explorer-tools-$v-universal" "$v"; done
mk "$S/user.installed-1.0.0-universal" x
mk "$S/user.installed-1.1.0-universal" x
mk "$S/foo.bar-1.0.0-universal" x
mk "$S/foo.bar-baz-9.0.0-universal" x   # prefix collision guard
# vscode-web real dirs
for v in 2.98.0 2.100.0; do mk "$W/google.geminicodeassist-$v" "$v"; done
# code-server: a UI-installed real dir (not in shared) + one dup of shared + old symlinks
mk "$CS/anthropic.claude-code-2.1.300-linux-arm64" "ui-update"
mk "$CS/openai.chatgpt-26.5715.31925-linux-arm64" "dup"
ln -s "$S/charliermarsh.ruff-2026.60.0-linux-arm64" "$CS/charliermarsh.ruff-2026.60.0-linux-arm64"
ln -s "$S/charliermarsh.ruff-2026.80.0-linux-arm64" "$CS/charliermarsh.ruff-2026.80.0-linux-arm64"
ln -s "$S/gone.ext-1.0.0-universal" "$CS/gone.ext-1.0.0-universal"
mk "$CS/local.only-1.0.0-universal" "user-installed, not in manifest"

# manifests: ruff pinned to the OLD version; chatgpt unpinned; claude unpinned
cat > "$M/10-base.json" <<EOF
{"shared":["Anthropic.claude-code","openai.chatgpt","charliermarsh.ruff@2026.60.0","abridge.file-explorer-tools","foo.bar"],"vscode_web_only":["Google.geminicodeassist"]}
EOF
cat > "$P/devcontainer.json" <<EOF
{ // jsonc
  "customizations": { "vscode": { "extensions": ["hashicorp.terraform",], } }
}
EOF

# leases from other workspaces
L="$S/_leases"; mkdir -p "$L"
printf 'shared/openai.chatgpt-26.5623.31443-linux-arm64\n' > "$L/nyc-design--OtherWs"
printf 'shared/anthropic.claude-code-2.1.193-linux-arm64\n' > "$L/nyc-design--DeadWs"
touch -d '60 days ago' "$L/nyc-design--DeadWs"

export MANIFEST_DIR="$M" WORKSPACES_ROOT="$T/workspaces" \
  SHARED_EXTENSIONS_DIR="$S" CODE_SERVER_EXTENSIONS_DIR="$CS" VSCODE_WEB_EXTENSIONS_DIR="$W" \
  VSCODE_SERVER_EXTENSIONS_DIR="$VS" CURSOR_SERVER_EXTENSIONS_DIR="$CU" \
  CODER_WORKSPACE_OWNER_NAME=nyc-design CODER_WORKSPACE_NAME=ThisWs \
  EXTENSIONS_LEASE_REFRESH_PIDFILE="$T/refresh.pid" EXTENSIONS_LEASE_REFRESH_INTERVAL=2s \
  EXTENSIONS_ACTIVATE_OK_MARKER="$T/activate.ok"

echo "===== activate ====="; bash "$INIT/30-extensions-activate.sh"
echo "===== code-server dir ====="; ls -l "$CS" | sed 1d | awk '{print $1, $9, $10, $11}'
echo "===== lease ====="; cat "$L/nyc-design--ThisWs"
echo "===== prune (dry) ====="; EXTENSIONS_PRUNE_DRY_RUN=1 bash "$INIT/31-extensions-prune.sh"
echo "===== prune (real) ====="; bash "$INIT/31-extensions-prune.sh"
echo "===== shared after ====="; ls "$S"; ls "$L"
echo "===== vscode-web after ====="; ls "$W"

fail=0
chk() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
chk "ui-update promoted"              '[ -d "$S/anthropic.claude-code-2.1.300-linux-arm64" ] && [ -L "$CS/anthropic.claude-code-2.1.300-linux-arm64" ]'
chk "dup dropped, replaced by link?"  '[ ! -e "$CS/openai.chatgpt-26.5715.31925-linux-arm64" ]'
chk "only newest chatgpt linked"      '[ -L "$CS/openai.chatgpt-26.5908.31748-linux-arm64" ] && [ ! -e "$CS/openai.chatgpt-26.5623.31443-linux-arm64" ]'
chk "pinned ruff linked, not newest"  '[ -L "$CS/charliermarsh.ruff-2026.60.0-linux-arm64" ] && [ ! -e "$CS/charliermarsh.ruff-2026.80.0-linux-arm64" ]'
chk "dangling symlink removed"        '[ ! -L "$CS/gone.ext-1.0.0-universal" ]'
chk "user real dir untouched"         '[ -d "$CS/local.only-1.0.0-universal" ] && [ ! -L "$CS/local.only-1.0.0-universal" ]'
chk "prefix collision: foo.bar ok"    '[ -L "$CS/foo.bar-1.0.0-universal" ] && [ ! -e "$CS/foo.bar-baz-9.0.0-universal" ]'
chk "prune: old claude gone (no lease)" '[ ! -d "$S/anthropic.claude-code-2.1.193-linux-arm64" ] && [ ! -d "$S/anthropic.claude-code-2.1.227-linux-arm64" ]'
chk "prune: newest claude kept"       '[ -d "$S/anthropic.claude-code-2.1.300-linux-arm64" ]'
chk "prune: leased old chatgpt kept"  '[ -d "$S/openai.chatgpt-26.5623.31443-linux-arm64" ]'
chk "prune: unleased mid chatgpt gone" '[ ! -d "$S/openai.chatgpt-26.5715.31925-linux-arm64" ]'
chk "prune: pinned ruff kept"         '[ -d "$S/charliermarsh.ruff-2026.60.0-linux-arm64" ] && [ -d "$S/charliermarsh.ruff-2026.80.0-linux-arm64" ]'
chk "prune: non-manifest old gone"    '[ ! -d "$S/user.installed-1.0.0-universal" ] && [ -d "$S/user.installed-1.1.0-universal" ]'
chk "prune: prefix collision safe"    '[ -d "$S/foo.bar-1.0.0-universal" ] && [ -d "$S/foo.bar-baz-9.0.0-universal" ]'
chk "prune: stale lease removed"      '[ ! -f "$L/nyc-design--DeadWs" ] && [ -f "$L/nyc-design--OtherWs" ]'
chk "prune: vscode-web old gone"      '[ ! -d "$W/google.geminicodeassist-2.98.0" ] && [ -d "$W/google.geminicodeassist-2.100.0" ]'
chk "lease has gemini"                'grep -q "vscode-web/google.geminicodeassist-2.100.0" "$L/nyc-design--ThisWs"'
chk "refresher running"               'kill -0 "$(cat "$T/refresh.pid")"'
m0=$(stat -c %Y "$L/nyc-design--ThisWs"); touch -d '1 hour ago' "$L/nyc-design--ThisWs"; sleep 3
chk "refresher touches lease"         '[ "$(stat -c %Y "$L/nyc-design--ThisWs")" -ge "$m0" ]'
kill "$(cat "$T/refresh.pid")" 2>/dev/null || true; rm -f "$T/refresh.pid"

# ---------------------------------------------------------------------------
# Regression: a manifest set with NO pinned versions must not trip `set -u`.
# `${#assoc[@]}` on an associative array declared without `=()` and never
# assigned is an unbound-variable error under `set -u`, which crashed activate
# before it created a single symlink (and then let the pruner run unguarded).
# ---------------------------------------------------------------------------
echo "===== no-pin manifest ====="
T2="$(mktemp -d)"
S2="$T2/shared"; CS2="$T2/code-server"; W2="$T2/vscode-web"; M2="$T2/manifests"
mkdir -p "$S2" "$CS2" "$W2" "$M2" "$T2/workspaces"
mk "$S2/eamodio.gitlens-2026.7.180533-universal" v
mk "$S2/eamodio.gitlens-2026.9.92030-universal" v
printf '{"shared":["eamodio.gitlens"]}\n' > "$M2/10-base.json"

set +e
nopin_out="$(MANIFEST_DIR="$M2" WORKSPACES_ROOT="$T2/workspaces" SHARED_EXTENSIONS_DIR="$S2" \
  CODE_SERVER_EXTENSIONS_DIR="$CS2" VSCODE_WEB_EXTENSIONS_DIR="$W2" \
  VSCODE_SERVER_EXTENSIONS_DIR="$T2/vscode-server" CURSOR_SERVER_EXTENSIONS_DIR="$T2/cursor-server" \
  CODER_WORKSPACE_OWNER_NAME=nyc-design CODER_WORKSPACE_NAME=NoPinWs \
  EXTENSIONS_LEASE_REFRESH_PIDFILE="$T2/refresh.pid" EXTENSIONS_LEASE_REFRESH_INTERVAL=1h \
  EXTENSIONS_ACTIVATE_OK_MARKER="$T2/activate.ok" \
  bash "$INIT/30-extensions-activate.sh" 2>&1)"
nopin_rc=$?
set -e
echo "$nopin_out"
chk "no-pin: activate exits 0"      '[ "$nopin_rc" -eq 0 ]'
chk "no-pin: no unbound variable"   '! grep -q "unbound variable" <<< "$nopin_out"'
chk "no-pin: newest version linked" '[ -L "$CS2/eamodio.gitlens-2026.9.92030-universal" ]'
chk "no-pin: ok marker written"     '[ -f "$T2/activate.ok" ]'
kill "$(cat "$T2/refresh.pid" 2>/dev/null)" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Interlock: the pruner must refuse to delete anything when activate did not
# complete, because no lease was refreshed this boot.
# ---------------------------------------------------------------------------
echo "===== prune interlock ====="
mk "$S2/eamodio.gitlens-2026.1.10000-universal" old
rm -f "$T2/activate.ok"
lock_out="$(SHARED_EXTENSIONS_DIR="$S2" VSCODE_WEB_EXTENSIONS_DIR="$W2" MANIFEST_DIR="$M2" \
  EXTENSIONS_ACTIVATE_OK_MARKER="$T2/activate.ok" bash "$INIT/31-extensions-prune.sh" 2>&1)"
echo "$lock_out"
chk "interlock: prune stands down"   'grep -q "SKIP" <<< "$lock_out"'
chk "interlock: nothing deleted"     '[ -d "$S2/eamodio.gitlens-2026.1.10000-universal" ]'

touch "$T2/activate.ok"
SHARED_EXTENSIONS_DIR="$S2" VSCODE_WEB_EXTENSIONS_DIR="$W2" MANIFEST_DIR="$M2" \
  EXTENSIONS_ACTIVATE_OK_MARKER="$T2/activate.ok" bash "$INIT/31-extensions-prune.sh" > /dev/null 2>&1
chk "interlock: prunes once cleared" '[ ! -d "$S2/eamodio.gitlens-2026.1.10000-universal" ]'
rm -rf "$T2"

exit $fail
