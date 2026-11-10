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
#   clone.sh          the entrypoint's clone
#   lifecycle.sh      the head of the agent startup script

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

# Builds a startup script the way main.tf does: lifecycle.sh, the project
# folder, one base64 call per notice and command, then the init script.
startup_script() {
  local out="$1"
  shift
  {
    cat "$SCRIPTS/lifecycle.sh"
    printf 'devcontainer_enter %s\n' "$(printf '%s' /workspaces/project | base64 -w0)"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        notice) printf 'devcontainer_notice %s\n' "$(printf '%s' "$2" | base64 -w0)" ;;
        *) printf 'run_lifecycle_command %s %s\n' "$1" "$(printf '%s' "$2" | base64 -w0)" ;;
      esac
      shift 2
    done
    echo 'echo init-pipeline-ran'
  } > "$out"
}

# Runs it from the home directory under sh (dash on these images), the
# strictest shell the agent could pick, with its output piped the way the
# agent pipes it. A hang here would leave a workspace stuck in "starting".
run_startup() {
  ws "set -o pipefail; cd ~ && timeout 60 sh /scripts/$1 2>&1 | tee /tmp/$1.log > /dev/null"
}

# Runs clone.sh as the entrypoint does, with the given WORKSPACE_CLONE_* env.
run_clone() {
  docker exec "$@" "$ID" sh -c '. /scripts/clone.sh; [ -z "${WORKSPACE_CLONE_URL:-}${WORKSPACE_CLONE_TOKEN:-}" ]'
}

# ── Fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$TMP/scripts" "$TMP/globalstorage"
cp "$SCRIPTS"/*.sh "$TMP/scripts/"
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
check "/workspaces is writable by coder" ws 'mkdir /workspaces/probe && rmdir /workspaces/probe'
check "parents of nested bind mounts are owned by coder" ws '[ "$(stat -c %U ~/.local/share/code-server ~/.local/share/code-server/User | sort -u)" = coder ]'
check "the agent can create its code-server Machine dir" ws 'mkdir -p ~/.local/share/code-server/Machine'
check "nothing under home or /workspaces is left owned by another user" ws '[ -z "$(find /home/coder /workspaces -xdev -not -user coder | head -1)" ]'

# ── clone.sh ─────────────────────────────────────────────────────────────────
# A local repository stands in for GitHub; authentication is not exercised here.
ws 'git init -q -b main /tmp/remote && cd /tmp/remote && echo hello > README.md && git add . && git -c user.name=t -c user.email=t@example.com commit -q -m init && git branch scaffold/python'
ws 'git config --global credential.helper "store --file=/home/coder/.git-credentials"; rm -f ~/.git-credentials'
CLONE=(-e WORKSPACE_CLONE_URL=/tmp/remote -e WORKSPACE_CLONE_DIR=/workspaces/project -e WORKSPACE_CLONE_TOKEN=secret-token)

check "nothing happens without a repository" run_clone
check "and no folder or log is created" ws '[ ! -e /workspaces/project ] && [ ! -e /tmp/workspace-clone.log ]'
check "a missing repository does not stop the entrypoint" run_clone -e WORKSPACE_CLONE_URL=/tmp/no-such-remote -e WORKSPACE_CLONE_DIR=/workspaces/project
check "the failure is logged and the folder left empty for a retry" ws 'grep -q "^=== Clone failed" /tmp/workspace-clone.log && [ -d /workspaces/project ] && [ -z "$(ls -A /workspaces/project)" ]'
check "an empty folder is cloned into" run_clone "${CLONE[@]}" -e WORKSPACE_CLONE_REF=scaffold/python
check "on the requested branch" ws '[ "$(git -C /workspaces/project branch --show-current)" = scaffold/python ] && [ -f /workspaces/project/README.md ]'
check "the token is not left in the clone or in a credential store" ws '! grep -rq secret-token /workspaces/project/.git ~/.gitconfig && [ ! -e ~/.git-credentials ]'
ws 'echo local-change > /workspaces/project/README.md'
check "a folder with content is left alone" run_clone "${CLONE[@]}"
check "and says so" ws 'grep -q "already has content" /tmp/workspace-clone.log && grep -qx local-change /workspaces/project/README.md'

# ── lifecycle.sh ─────────────────────────────────────────────────────────────
ws 'mkdir -p /workspaces/project/sub'

startup_script "$TMP/scripts/ok.sh" \
  notice 'No .devcontainer/devcontainer.json in octo/app; using base.' \
  onCreateCommand 'pwd > /tmp/lifecycle-pwd; echo one' \
  updateContentCommand "printf '%s\n' \"it's \\\"quoted\\\" \$HOME\" > /tmp/lifecycle-quoting" \
  postCreateCommand "'sh' '-c' 'echo argv-form-ran'" \
  postStartCommand 'cd sub && pwd > /tmp/lifecycle-subdir'
check "lifecycle commands succeed and the startup script still runs" run_startup ok.sh
check "commands run from the project folder" ws '[ "$(cat /tmp/lifecycle-pwd)" = /workspaces/project ]'
check "a command's cd does not leak into the next one" ws '[ "$(cat /tmp/lifecycle-subdir)" = /workspaces/project/sub ] && [ "$(cat /tmp/lifecycle-pwd)" = /workspaces/project ]'
check "quotes and variables reach sh untouched" ws "[ \"\$(cat /tmp/lifecycle-quoting)\" = \"it's \\\"quoted\\\" /home/coder\" ]"
check "an argv-form command runs" ws 'grep -qx "argv-form-ran" /tmp/ok.sh.log'
check "the clone log is shown first" ws 'head -1 /tmp/ok.sh.log | grep -q "already has content"'
check "notices and command output reach the log in order" ws '[ "$(grep -n -e "^=== No .devcontainer" -e "^=== Running onCreateCommand" -e "^one$" -e "^=== Running postStartCommand" -e "^init-pipeline-ran$" /tmp/ok.sh.log | cut -d: -f2 | cut -c1-12 | tr "\n" "|")" = "=== No .devc|=== Running |one|=== Running |init-pipelin|" ]'

startup_script "$TMP/scripts/fail.sh" \
  onCreateCommand 'echo before-failure' \
  postCreateCommand 'echo boom >&2; exit 3' \
  postStartCommand 'touch /tmp/lifecycle-should-not-exist'
check "a failing command does not fail the script" run_startup fail.sh
check "the failure and its output are reported" ws 'grep -qx boom /tmp/fail.sh.log && grep -q "^=== postCreateCommand failed (exit 3)" /tmp/fail.sh.log'
check "the remaining commands are skipped" ws '[ ! -e /tmp/lifecycle-should-not-exist ] && grep -q "^=== Skipping postStartCommand because postCreateCommand failed" /tmp/fail.sh.log'
check "the startup script still runs after a failure" ws 'grep -qx init-pipeline-ran /tmp/fail.sh.log'

# A postStartCommand that starts a server and returns, like Wanderlog-MCP's.
startup_script "$TMP/scripts/daemon.sh" \
  postStartCommand 'sleep 300 & echo $! > /tmp/lifecycle-daemon.pid; echo daemon-started'
check "a command that leaves a daemon behind does not hang startup" run_startup daemon.sh
check "the daemon keeps running" ws 'kill -0 "$(cat /tmp/lifecycle-daemon.pid)"'
check "output written before the daemon detached is shown" ws 'grep -qx daemon-started /tmp/daemon.sh.log'

startup_script "$TMP/scripts/slow.sh" \
  postCreateCommand 'echo first-line; sleep 4; echo last-line'
# Sampled inside one exec: a second `docker exec` can take seconds to return
# while a background process from the first still holds its stdin.
check "output is relayed while the command is still running" ws '(sh /scripts/slow.sh > /tmp/slow.sh.log 2>&1 < /dev/null &) ; sleep 2; grep -qx first-line /tmp/slow.sh.log && ! grep -qx last-line /tmp/slow.sh.log'
check "and the rest follows when it finishes" ws 'sleep 4; grep -qx last-line /tmp/slow.sh.log && grep -qx init-pipeline-ran /tmp/slow.sh.log'

echo
if [ "$FAILED" -ne 0 ]; then
  echo "FAILED ($WORKSPACE_IMAGE)"
  exit 1
fi
echo "All checks passed ($WORKSPACE_IMAGE)"
