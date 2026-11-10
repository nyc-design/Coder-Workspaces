#!/usr/bin/env bash
# End-to-end test for the vm-ssh-gateway template's workspace side.
#
# Stands up a throwaway "VM" (a container running only sshd) and a workspace
# container from the real image, runs scripts/vm-gateway.sh plus the image's
# own init scripts, launches code-server the way the shared launcher does, and
# drives it with a headless browser. Needs Docker and outbound internet.
#
#   ./test-vm-gateway.sh              # only this template's extension (fast)
#   FULL_INITS=1 ./test-vm-gateway.sh # the image's whole init pipeline (slow)
#
# WORKSPACE_IMAGE overrides the image under test.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/vm-gateway.sh"
WORKSPACE_IMAGE="${WORKSPACE_IMAGE:-ghcr.io/nyc-design/workspace-images/base-dev:latest}"
PLAYWRIGHT_VERSION="1.49.0"
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble"
ID="vmgw-test-$$"
NET="$ID-net"
VM="$ID-vm"
WS="$ID-ws"
TMP="$(mktemp -d)"
FAILED=0

cleanup() {
  docker rm -f "$VM" "$WS" > /dev/null 2>&1 || true
  docker network rm "$NET" > /dev/null 2>&1 || true
  docker rmi "$ID-vm-image" > /dev/null 2>&1 || true
  rm -rf "$TMP"
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

vm() { docker exec -u ubuntu "$VM" bash -c "$1"; }
ws() { docker exec "$WS" bash -c "$1"; }

# ── Fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$TMP/key"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/key/id_ed25519"
chmod 644 "$TMP/key/id_ed25519" # readable by whatever uid `coder` is in the image

# The "VM" has sshd and nothing else: no curl, no node, no editor.
docker build -q -t "$ID-vm-image" - > /dev/null <<'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends openssh-server procps > /dev/null \
 && mkdir -p /run/sshd /home/ubuntu/.ssh /home/ubuntu/project \
 && echo 'original' > /home/ubuntu/project/VM_MARKER.txt \
 && chown -R ubuntu:ubuntu /home/ubuntu
CMD ["/usr/sbin/sshd", "-D", "-e"]
DOCKERFILE

docker network create "$NET" > /dev/null
docker run -d --name "$VM" --hostname the-vm --network "$NET" --network-alias vm.test "$ID-vm-image" > /dev/null
docker cp "$TMP/key/id_ed25519.pub" "$VM:/home/ubuntu/.ssh/authorized_keys"
docker exec "$VM" sh -c 'chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys && chmod 600 /home/ubuntu/.ssh/authorized_keys'
vm 'find ~' | LC_ALL=C sort > "$TMP/vm-before.txt"

docker run -d --name "$WS" --network "$NET" --network-alias ws.test \
  -v "$TMP/key:/home/coder/secrets/ssh:ro" \
  -v "$SCRIPT:/vm-gateway.sh:ro" \
  -e VM_HOST=vm.test -e VM_USER=ubuntu -e VM_PORT=22 -e VM_REMOTE_DIR=/home/ubuntu/project \
  --entrypoint sleep "$WORKSPACE_IMAGE" infinity > /dev/null

# ── configure + the image's init pipeline ────────────────────────────────────
echo "--- configure"
check "configure succeeds" ws 'bash /vm-gateway.sh configure'
check "workspace file points at the VM folder" ws '[ "$(jq -r ".folders[0].uri" ~/vm.code-workspace)" = "ssh://vm/home/ubuntu/project" ]'

echo "--- init pipeline"
if [ "${FULL_INITS:-0}" = "1" ]; then
  # Some inits fail outside a real workspace (no sysbox, no tokens); the
  # startup module tolerates that too.
  ws '/usr/local/bin/run-workspace-inits > /tmp/workspace-init.log 2>&1 || true'
  ws 'grep -E "init-runner\] ERR" /tmp/workspace-init.log || true'
else
  # Same scripts, restricted to this template's extension manifest.
  ws 'mkdir -p /tmp/manifest && cp /usr/local/share/workspace-extensions.d/90-vm-gateway.json /tmp/manifest/ \
    && cd /usr/local/share/workspace-init.d \
    && ./11-agent-prompts.sh > /dev/null 2>&1 \
    && MANIFEST_DIR=/tmp/manifest ./25-extensions-install.sh > /dev/null 2>&1 \
    && ./26-settings-apply.sh > /dev/null \
    && MANIFEST_DIR=/tmp/manifest ./30-extensions-activate.sh > /dev/null 2>&1'
fi
check "SSH FS extension activated for code-server" ws 'ls ~/.vscode-extensions/code-server | grep -qi "^kelvin.vscode-sshfs-"'
check "Machine settings carry the VM connection" ws '[ "$(jq -r ".[\"sshfs.configs\"][0].host" ~/.local/share/code-server/Machine/settings.json)" = "vm.test" ]'
check "default terminal profile is the VM" ws '[ "$(jq -r ".[\"terminal.integrated.defaultProfile.linux\"]" ~/.local/share/code-server/Machine/settings.json)" = "VM" ]'
check "agent prompt explains the VM" ws 'grep -q "ssh vm" ~/.coder/AGENTS.md'
for f in .claude/CLAUDE.md .codex/AGENTS.md .gemini/GEMINI.md .qwen/QWEN.md; do
  check "VM instructions reach ~/$f" ws "grep -q 'ssh vm' ~/$f"
done

echo "--- check"
check "check succeeds against a reachable VM" ws 'bash /vm-gateway.sh check'
if out="$(docker exec -e VM_USER=nobody-here "$WS" bash -c 'bash /vm-gateway.sh configure > /dev/null && bash /vm-gateway.sh check' 2>&1)"; then
  fail "a rejected key fails the check"
elif grep -q 'ssh-ed25519 ' <<< "$out"; then
  pass "a rejected key fails the check and prints the public key to add"
else
  fail "a rejected key fails the check and prints the public key to add"
fi
ws 'bash /vm-gateway.sh configure > /dev/null' # restore the good config

# ── What an AI agent in the workspace does ───────────────────────────────────
check "ssh vm runs commands on the VM" ws '[ "$(ssh vm hostname)" = "the-vm" ]'
check "repeated ssh vm calls reuse one connection" ws 'ssh vm true && ssh -O check vm'

# ── The editor, through the real UI ──────────────────────────────────────────
echo "--- browser"
# Same flags as workspace-modules/workspace-apps/scripts/code-server-launch.sh,
# except the bind address (the browser is in another container).
docker exec -d "$WS" bash -c '/opt/code-server/bin/code-server --auth=none --bind-addr=0.0.0.0:13337 \
  --app-name=code-server --extensions-dir=/home/coder/.vscode-extensions/code-server > /tmp/code-server.log 2>&1'
for _ in $(seq 1 30); do
  ws 'curl -fsS -o /dev/null http://127.0.0.1:13337/healthz' 2> /dev/null && break
  sleep 1
done

# playwright is installed inside the container, off the mount, so nothing
# root-owned is left behind in $TMP.
browser_out="$(docker run --rm --network "$NET" -v "$HERE/browser-check.js:/work/browser-check.js:ro" -w /tmp "$PLAYWRIGHT_IMAGE" \
  bash -c "npm i --silent playwright@$PLAYWRIGHT_VERSION > /dev/null 2>&1 && NODE_PATH=/tmp/node_modules node /work/browser-check.js http://ws.test:13337 /home/coder/vm.code-workspace" 2>&1)" || true
result="$(grep '^RESULT ' <<< "$browser_out" | sed 's/^RESULT //' || true)"
if [ -z "$result" ]; then
  fail "browser run completed"
  echo "$browser_out" | tail -n 20
else
  pass "browser run completed"
  check "explorer shows the VM's folder" jq -e '.explorer | index("VM_MARKER.txt")' <<< "$result"
  echo "info  Quick Open results for the VM file: $(jq -c '.quickOpen' <<< "$result")"
fi
check "an edit saved in the editor lands on the VM" vm 'grep -q "edited-in-code-server" ~/project/VM_MARKER.txt'
check "the default terminal runs on the VM, in the folder" vm '[ "$(cat ~/TERMINAL_MARKER.txt)" = "the-vm:/home/ubuntu/project" ]'

# ── Nothing installed on the VM ──────────────────────────────────────────────
vm 'find ~' | LC_ALL=C sort > "$TMP/vm-after.txt"
new_paths="$(LC_ALL=C comm -13 "$TMP/vm-before.txt" "$TMP/vm-after.txt" | grep -v -E '^/home/ubuntu/(TERMINAL_MARKER\.txt|\.cache(/motd\.legal-displayed)?)$' || true)"
if [ -z "$new_paths" ]; then
  pass "nothing was installed on the VM"
else
  fail "nothing was installed on the VM"
  echo "$new_paths"
fi
check "no editor or server process on the VM" bash -c "! docker exec '$VM' pgrep -f 'code-server|vscode|codium|node'"

if [ "$FAILED" -ne 0 ]; then
  echo "--- browser result"
  echo "$result"
  echo "--- browser output"
  echo "$browser_out" | tail -n 20
  echo "--- SSH FS log"
  ws 'cat ~/.local/share/code-server/logs/*/exthost*/output_logging_*/*SSH\ FS.log 2> /dev/null | tail -n 30' || true
  exit 1
fi
echo "all checks passed"
