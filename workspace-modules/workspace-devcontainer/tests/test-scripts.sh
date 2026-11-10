#!/usr/bin/env bash
# Container-level test for the scripts this module ships, run inside a real
# workspace image with fresh volumes. Needs Docker; no network beyond the image.
#
#   ./test-scripts.sh
#   WORKSPACE_IMAGE=ghcr.io/nyc-design/wanderlog-mcp:latest ./test-scripts.sh
#
# The Terraform side (which image, which commands) is covered by
# devcontainer.tftest.hcl. This covers what those commands do once they run:
#   fix-ownership.sh  the container entrypoint prelude
#   pre-clone.sh      git-clone's pre_clone_script
#   lifecycle.sh      the head of git-clone's post_clone_script

# The checks are single-quoted on purpose: they are evaluated in the container.
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$HERE/../scripts"
WORKSPACE_IMAGE="${WORKSPACE_IMAGE:-ghcr.io/nyc-design/workspace-images/base-dev:latest}"
ID="devcontainer-test-$$"
TMP="$(mktemp -d)"
FAILED=0

cleanup() {
  docker rm -f "$ID" > /dev/null 2>&1 || true
  docker volume rm -f "$ID-home" "$ID-workspaces" > /dev/null 2>&1 || true
  rm -rf "$TMP" 2> /dev/null || sudo rm -rf "$TMP"
}
trap cleanup EXIT

pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  FAILED=1
}
check() {
  local name="$1"
  shift
  if "$@" > /dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}
ws() { docker exec "$ID" bash -c "$1"; }

# Builds a post_clone_script the way main.tf does: shebang, lifecycle.sh, one
# base64 call per notice and command, then the startup script.
post_clone_script() {
  local out="$1"
  shift
  {
    echo '#!/usr/bin/env bash'
    cat "$SCRIPTS/lifecycle.sh"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        notice) printf 'devcontainer_notice %s\n' "$(printf '%s' "$2" | base64 -w0)" ;;
        *) printf 'run_lifecycle_command %s %s\n' "$1" "$(printf '%s' "$2" | base64 -w0)" ;;
      esac
      shift 2
    done
    echo 'echo init-pipeline-ran'
  } > "$out"
  chmod 755 "$out"
}

# Runs it the way the git-clone module does: from the project folder, piped
# through tee twice (run.sh, then the coder_script wrapper), under pipefail.
# A hang here is exactly what would leave a workspace stuck in "starting".
run_post_clone() {
  ws "set -o pipefail; cd /workspaces/project && timeout 60 bash -c '/scripts/$1 2>&1 | tee /tmp/$1.inner.log' 2>&1 | tee /tmp/$1.log > /dev/null"
}

# ── Fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$TMP/scripts" "$TMP/globalstorage"
cp "$SCRIPTS"/*.sh "$TMP/scripts/"
# git-clone writes its pre/post scripts to disk and marks them executable.
chmod 755 "$TMP/scripts"/*.sh
chmod -R a+rX "$TMP"

# Same shape as the real workspace: named volumes for home and /workspaces, and
# a bind mount nested deep enough that Docker has to create its parents.
docker run -d --name "$ID" \
  -v "$ID-home:/home/coder" -v "$ID-workspaces:/workspaces" \
  -v "$TMP/globalstorage:/home/coder/.local/share/code-server/User/globalStorage" \
  -v "$TMP/scripts:/scripts" \
  --entrypoint sh "$WORKSPACE_IMAGE" -c "$(cat "$SCRIPTS/fix-ownership.sh")
exec sleep infinity" > /dev/null
sleep 2

# ── fix-ownership.sh ─────────────────────────────────────────────────────────
check "container runs as coder" ws '[ "$(id -un)" = coder ]'
check "/workspaces is writable by coder" ws 'mkdir -p /workspaces/project'
check "parents of nested bind mounts are owned by coder" ws '[ "$(stat -c %U ~/.local/share/code-server ~/.local/share/code-server/User | sort -u)" = coder ]'
check "the agent can create its code-server Machine dir" ws 'mkdir -p ~/.local/share/code-server/Machine'
check "nothing under home or /workspaces is left owned by another user" ws '[ -z "$(find /home/coder /workspaces -xdev -not -user coder | head -1)" ]'

# ── pre-clone.sh ─────────────────────────────────────────────────────────────
ws 'git config --global --unset-all credential.helper; rm -f ~/.git-credentials; git config --global credential.helper "store --file=/home/coder/.git-credentials"'
check "the image's placeholder store helper is removed before the clone" ws '/scripts/pre-clone.sh && [ -z "$(git config --global --get-all credential.helper)" ]'
check "running it again with no helper is harmless" ws '/scripts/pre-clone.sh'
ws 'git config --global credential.helper "store --file=/home/coder/.git-credentials"; touch ~/.git-credentials'
check "a store helper that already holds credentials is kept" ws '/scripts/pre-clone.sh && git config --global --get-all credential.helper | grep -q "^store"'
ws 'rm -f ~/.git-credentials; git config --global --unset-all credential.helper; git config --global credential.helper "!gh auth git-credential"'
check "the gh helper set by 03-git.sh is kept" ws '/scripts/pre-clone.sh && [ "$(git config --global --get-all credential.helper)" = "!gh auth git-credential" ]'

# ── lifecycle.sh ─────────────────────────────────────────────────────────────
ws 'mkdir -p /workspaces/project/sub'

post_clone_script "$TMP/scripts/ok.sh" \
  notice 'No .devcontainer/devcontainer.json in octo/app; using base.' \
  onCreateCommand 'pwd > /tmp/lifecycle-pwd; echo one' \
  updateContentCommand "printf '%s\n' \"it's \\\"quoted\\\" \$HOME\" > /tmp/lifecycle-quoting" \
  postCreateCommand "'sh' '-c' 'echo argv-form-ran'" \
  postStartCommand 'cd sub && pwd > /tmp/lifecycle-subdir'
check "lifecycle commands succeed and the startup script still runs" run_post_clone ok.sh
check "commands run from the project folder" ws '[ "$(cat /tmp/lifecycle-pwd)" = /workspaces/project ]'
check "a command's cd does not leak into the next one" ws '[ "$(cat /tmp/lifecycle-subdir)" = /workspaces/project/sub ] && [ "$(cat /tmp/lifecycle-pwd)" = /workspaces/project ]'
check "quotes and variables reach sh untouched" ws "[ \"\$(cat /tmp/lifecycle-quoting)\" = \"it's \\\"quoted\\\" /home/coder\" ]"
check "an argv-form command runs" ws 'grep -qx "argv-form-ran" /tmp/ok.sh.log'
check "notices and command output reach the log in order" ws '[ "$(grep -n -e "^=== No .devcontainer" -e "^=== Running onCreateCommand" -e "^one$" -e "^=== Running postStartCommand" -e "^init-pipeline-ran$" /tmp/ok.sh.log | cut -d: -f2 | cut -c1-12 | tr "\n" "|")" = "=== No .devc|=== Running |one|=== Running |init-pipelin|" ]'

post_clone_script "$TMP/scripts/fail.sh" \
  onCreateCommand 'echo before-failure' \
  postCreateCommand 'echo boom >&2; exit 3' \
  postStartCommand 'touch /tmp/lifecycle-should-not-exist'
check "a failing command does not fail the script" run_post_clone fail.sh
check "the failure and its output are reported" ws 'grep -qx boom /tmp/fail.sh.log && grep -q "^=== postCreateCommand failed (exit 3)" /tmp/fail.sh.log'
check "the remaining commands are skipped" ws '[ ! -e /tmp/lifecycle-should-not-exist ] && grep -q "^=== Skipping postStartCommand because postCreateCommand failed" /tmp/fail.sh.log'
check "the startup script still runs after a failure" ws 'grep -qx init-pipeline-ran /tmp/fail.sh.log'

# A postStartCommand that starts a server and returns, like Wanderlog-MCP's.
post_clone_script "$TMP/scripts/daemon.sh" \
  postStartCommand 'sleep 300 & echo $! > /tmp/lifecycle-daemon.pid; echo daemon-started'
check "a command that leaves a daemon behind does not hang startup" run_post_clone daemon.sh
check "the daemon keeps running" ws 'kill -0 "$(cat /tmp/lifecycle-daemon.pid)"'
check "output written before the daemon detached is shown" ws 'grep -qx daemon-started /tmp/daemon.sh.log'

post_clone_script "$TMP/scripts/slow.sh" \
  postCreateCommand 'echo first-line; sleep 4; echo last-line'
# Sampled inside one exec: a second `docker exec` can take seconds to return
# while a background process from the first still holds its stdin.
check "output is relayed while the command is still running" ws 'cd /workspaces/project && (/scripts/slow.sh > /tmp/slow.sh.log 2>&1 < /dev/null &) ; sleep 2; grep -qx first-line /tmp/slow.sh.log && ! grep -qx last-line /tmp/slow.sh.log'
check "and the rest follows when it finishes" ws 'sleep 4; grep -qx last-line /tmp/slow.sh.log && grep -qx init-pipeline-ran /tmp/slow.sh.log'

echo
if [ "$FAILED" -ne 0 ]; then
  echo "FAILED ($WORKSPACE_IMAGE)"
  exit 1
fi
echo "All checks passed ($WORKSPACE_IMAGE)"
