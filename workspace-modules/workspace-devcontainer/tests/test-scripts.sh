#!/usr/bin/env bash
# Container-level test for the scripts this module ships, run inside a real
# workspace image with fresh volumes. Needs Docker; no network beyond the image.
#
#   ./test-scripts.sh
#   WORKSPACE_IMAGE=ghcr.io/nyc-design/wanderlog-mcp:latest ./test-scripts.sh
#
# devcontainer.tftest.hcl covers the Terraform side (which image runs). This
# covers everything that happens in the container:
#   fix-ownership.sh  entrypoint: volume ownership
#   clone.sh          entrypoint: the clone
#   devcontainer.sh   entrypoint: devcontainer.json environment and commands
#   lifecycle.sh      agent startup script: running those commands

# The checks are single-quoted on purpose: they are evaluated in the container.
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$HERE/../scripts"
FIXTURES="$HERE/fixtures"
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

# Runs the entrypoint's clone and devcontainer steps the way main.tf joins
# them, then a probe in the same shell, where the agent would start.
#   entrypoint '<probe>' [docker exec options, e.g. -e NAME=value]
entrypoint() {
  local probe="$1"
  shift
  docker exec "$@" "$ID" sh -c ". /scripts/clone.sh; . /scripts/devcontainer.sh; $probe"
}
CLEAN='[ -z "${WORKSPACE_CLONE_URL:-}${WORKSPACE_CLONE_DIR:-}${WORKSPACE_CLONE_TOKEN:-}" ]'
PROJECT=(-e WORKSPACE_CLONE_DIR=/workspaces/project)

# Replaces the project's devcontainer.json with stdin.
devcontainer_json() {
  docker exec -i "$ID" sh -c 'mkdir -p /workspaces/project/.devcontainer && cat > /workspaces/project/.devcontainer/devcontainer.json'
}

# Runs the agent startup script from the home directory under sh (dash on these
# images), the strictest shell the agent could pick, with its output piped the
# way the agent pipes it. A hang here would leave a workspace stuck "starting".
startup() {
  ws 'set -o pipefail; cd ~ && timeout 60 sh /scripts/startup.sh 2>&1 | tee /tmp/startup.log > /dev/null'
}

# ── Fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$TMP/scripts" "$TMP/globalstorage"
cp "$SCRIPTS"/*.sh "$TMP/scripts/"
# The startup script as main.tf builds it.
{
  cat "$SCRIPTS/lifecycle.sh"
  printf 'devcontainer_lifecycle %s\n' "$(printf '%s' /workspaces/project | base64 -w0)"
  echo 'echo init-pipeline-ran'
} > "$TMP/scripts/startup.sh"
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
check "the /.dockerenv marker is removed" ws '[ ! -e /.dockerenv ]'

# ── clone.sh ─────────────────────────────────────────────────────────────────
# A local repository stands in for GitHub; authentication is not exercised here.
ws 'git init -q -b main /tmp/remote && cd /tmp/remote && echo hello > README.md && git add . && git -c user.name=t -c user.email=t@example.com commit -q -m init && git branch scaffold/python'
ws 'git config --global credential.helper "store --file=/home/coder/.git-credentials"; rm -f ~/.git-credentials'
CLONE=("${PROJECT[@]}" -e WORKSPACE_CLONE_URL=/tmp/remote -e WORKSPACE_CLONE_TOKEN=secret-token)

check "nothing happens without a repository" entrypoint "$CLEAN"
check "and no folder or log is created" ws '[ ! -e /workspaces/project ] && [ ! -e /tmp/workspace-clone.log ]'
check "a missing repository does not stop the entrypoint" entrypoint "$CLEAN" "${PROJECT[@]}" -e WORKSPACE_CLONE_URL=/tmp/no-such-remote
check "the failure is logged and the folder left empty for a retry" ws 'grep -q "^=== Clone failed" /tmp/workspace-clone.log && [ -d /workspaces/project ] && [ -z "$(ls -A /workspaces/project)" ]'
check "an empty folder is cloned into" entrypoint "$CLEAN" "${CLONE[@]}" -e WORKSPACE_CLONE_REF=scaffold/python
check "on the requested branch" ws '[ "$(git -C /workspaces/project branch --show-current)" = scaffold/python ] && [ -f /workspaces/project/README.md ]'
check "the token is not left in the clone or in a credential store" ws '! grep -rq secret-token /workspaces/project/.git ~/.gitconfig && [ ! -e ~/.git-credentials ]'
ws 'echo local-change > /workspaces/project/README.md'
check "a folder with content is left alone" entrypoint "$CLEAN" "${CLONE[@]}"
check "and says so" ws 'grep -q "already has content" /tmp/workspace-clone.log && grep -qx local-change /workspaces/project/README.md'
check "a project without devcontainer.json is reported" ws 'grep -q "^=== No .devcontainer/devcontainer.json" /tmp/workspace-clone.log'
check "and its startup script still runs" startup
check "showing the entrypoint's log before the init pipeline" ws 'head -1 /tmp/startup.log | grep -q "already has content" && [ "$(tail -1 /tmp/startup.log)" = init-pipeline-ran ]'

# ── devcontainer.sh: environment ─────────────────────────────────────────────
devcontainer_json < "$FIXTURES/basic.json"
check "containerEnv and remoteEnv are exported, remoteEnv winning" entrypoint '[ "$STATE_DIR" = /home/coder/.local/share/app ] && [ "$SHARED" = from-remote-env ]' "${PROJECT[@]}"
check "workspace folder variables are resolved" entrypoint '[ "$PROJECT_ROOT" = /workspaces/project/src ] && [ "$PROJECT_NAME" = project ]' "${PROJECT[@]}"
check "containerEnv:/localEnv: are resolved from the container" entrypoint '[ "$PATH" = "$OLD_PATH:/opt/tool/bin" ] && [ "$EDITOR_HOME" = "$HOME" ] && command -v git' "${PROJECT[@]}" -e OLD_PATH="$(ws 'printf %s "$PATH"')"
check "a null value sets nothing" entrypoint '[ -z "${UNSET_ME+x}" ]' "${PROJECT[@]}"
check "the clone settings are gone before the agent starts" entrypoint "$CLEAN" "${PROJECT[@]}"

devcontainer_json << 'EOF'
{
  "containerEnv": {
    "CODER_AGENT_TOKEN": "from-devcontainer",
    "DEVCONTAINER_ID": "${devcontainerId}",
    "bad name": "x",
    "COUNT": 3,
    "ENABLED": true,
    "QUOTED": "it's \"quoted\" $HOME `id`"
  }
}
EOF
check "agent credentials cannot be overridden" entrypoint '[ "$CODER_AGENT_TOKEN" = real ]' "${PROJECT[@]}" -e CODER_AGENT_TOKEN=real
check "a variable this cannot resolve is left unset, not passed through" entrypoint '[ -z "${DEVCONTAINER_ID+x}" ]' "${PROJECT[@]}"
check "what was skipped is reported" ws 'grep -q "CODER_AGENT_TOKEN, DEVCONTAINER_ID, bad name\.$" /tmp/workspace-clone.log'
check "numbers and booleans become strings" entrypoint '[ "$COUNT" = 3 ] && [ "$ENABLED" = true ]' "${PROJECT[@]}"
check "values are exported literally, not evaluated" entrypoint '[ "$QUOTED" = "it'\''s \"quoted\" \$HOME \`id\`" ]' "${PROJECT[@]}"
check "a file without an image is reported" ws 'grep -q "has no \"image\"" /tmp/workspace-clone.log'

# ── devcontainer.sh + lifecycle.sh: commands ─────────────────────────────────
ws 'mkdir -p /workspaces/project/sub'
devcontainer_json < "$FIXTURES/jsonc.json"
check "comments and trailing commas parse, strings untouched" entrypoint '[ "$DOCS_URL" = "https://example.com/a//b /* not a comment */" ]' "${PROJECT[@]}"
check "lifecycle commands succeed and the init pipeline still runs" startup
check "every command form runs, in hook order, objects by name" ws '[ "$(grep -v "^===" /tmp/startup.log | tr "\n" "|")" = "it'\''s created a b|first|second|init-pipeline-ran|" ]'
check "commands run from the project folder" ws '[ "$(cat /tmp/lifecycle-pwd)" = /workspaces/project ]'
check "a command's cd does not leak into the next start" ws '[ "$(cat /tmp/lifecycle-subdir)" = /workspaces/project/sub ]'

devcontainer_json << 'EOF'
{
  "onCreateCommand": "echo before-failure",
  "postCreateCommand": "echo boom >&2; exit 3",
  "postStartCommand": "touch /tmp/lifecycle-should-not-exist"
}
EOF
entrypoint true "${PROJECT[@]}" > /dev/null
check "a failing command does not fail the script" startup
check "the failure and its output are reported" ws 'grep -qx boom /tmp/startup.log && grep -q "^=== postCreateCommand failed (exit 3)" /tmp/startup.log'
check "the remaining commands are skipped" ws '[ ! -e /tmp/lifecycle-should-not-exist ] && grep -q "^=== Skipping postStartCommand because postCreateCommand failed" /tmp/startup.log'
check "the init pipeline still runs after a failure" ws 'grep -qx init-pipeline-ran /tmp/startup.log'

# A postStartCommand that starts a server and returns, like Wanderlog-MCP's.
devcontainer_json << 'EOF'
{ "postStartCommand": "sleep 300 & echo $! > /tmp/lifecycle-daemon.pid; echo daemon-started" }
EOF
entrypoint true "${PROJECT[@]}" > /dev/null
check "a command that leaves a daemon behind does not hang startup" startup
check "the daemon keeps running" ws 'kill -0 "$(cat /tmp/lifecycle-daemon.pid)"'
check "output written before the daemon detached is shown" ws 'grep -qx daemon-started /tmp/startup.log'

devcontainer_json << 'EOF'
{ "postCreateCommand": "echo first-line; sleep 4; echo last-line" }
EOF
entrypoint true "${PROJECT[@]}" > /dev/null
# Sampled inside one exec: a second `docker exec` can take seconds to return
# while a background process from the first still holds its stdin.
check "output is relayed while the command is still running" ws '(sh /scripts/startup.sh > /tmp/slow.log 2>&1 < /dev/null &) ; sleep 2; grep -qx first-line /tmp/slow.log && ! grep -qx last-line /tmp/slow.log'
check "and the rest follows when it finishes" ws 'sleep 4; grep -qx last-line /tmp/slow.log && grep -qx init-pipeline-ran /tmp/slow.log'

devcontainer_json << 'EOF'
{ "postCreateCommand": "touch /tmp/lifecycle-from-broken-file", nope
EOF
check "an unparsable file does not stop the entrypoint" entrypoint "$CLEAN" "${PROJECT[@]}"
check "it is reported" ws 'grep -q "could not be parsed" /tmp/workspace-clone.log'
check "and startup runs the init pipeline with no commands" ws 'cd ~ && sh /scripts/startup.sh | grep -qx init-pipeline-ran && [ ! -e /tmp/lifecycle-from-broken-file ]'

echo
if [ "$FAILED" -ne 0 ]; then
  echo "FAILED ($WORKSPACE_IMAGE)"
  exit 1
fi
echo "All checks passed ($WORKSPACE_IMAGE)"
