#!/usr/bin/env bash
# End-to-end test for scripts/vm-connect.sh.
#
# Stands up a throwaway "VM" (a container running only sshd) and a gateway
# container from the workspace image, runs the real script between them, and
# checks the whole chain: install, settings, extensions, tunnel, self-heal,
# and stop. Needs Docker and outbound internet (the VM downloads code-server).
#
#   ./test-vm-connect.sh                 # one small extension, fast
#   FULL_MANIFEST=1 ./test-vm-connect.sh # the image's real extension manifest
#
# GATEWAY_IMAGE overrides the workspace image under test.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/vm-connect.sh"
GATEWAY_IMAGE="${GATEWAY_IMAGE:-ghcr.io/nyc-design/workspace-images/base-dev:latest}"
ID="vmgw-test-$$"
NET="$ID-net"
VM="$ID-vm"
GW="$ID-gw"
TMP="$(mktemp -d)"
FAILED=0

cleanup() {
  docker rm -f "$VM" "$GW" > /dev/null 2>&1 || true
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
gw() { docker exec "$GW" bash -c "$1"; }
# code-server on the VM, addressed the way the template addresses it.
# shellcheck disable=SC2088 # expanded by the VM's shell, not this one
VM_CS='~/.coder-vm-gateway/bin/code-server --config ~/.coder-vm-gateway/config.yaml --user-data-dir ~/.coder-vm-gateway/data --extensions-dir ~/.coder-vm-gateway/extensions'
healthy() { gw 'curl -fsS -m 2 -o /dev/null http://127.0.0.1:13337/healthz'; }
wait_healthy() {
  for _ in $(seq 1 60); do
    healthy 2> /dev/null && return 0
    sleep 1
  done
  return 1
}

# ── Fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$TMP/key" "$TMP/manifest"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/key/id_ed25519"
chmod 644 "$TMP/key/id_ed25519" # readable by whatever uid `coder` is in the image
echo '{"shared": ["usernamehw.errorlens"]}' > "$TMP/manifest/10-test.json"

docker build -q -t "$ID-vm-image" - > /dev/null <<'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends openssh-server curl ca-certificates procps > /dev/null \
 && mkdir -p /run/sshd /home/ubuntu/.ssh /home/ubuntu/project \
 && chown -R ubuntu:ubuntu /home/ubuntu
CMD ["/usr/sbin/sshd", "-D", "-e"]
DOCKERFILE

docker network create "$NET" > /dev/null
docker run -d --name "$VM" --network "$NET" --network-alias vm.test "$ID-vm-image" > /dev/null
docker cp "$TMP/key/id_ed25519.pub" "$VM:/home/ubuntu/.ssh/authorized_keys"
docker exec "$VM" sh -c 'chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys && chmod 600 /home/ubuntu/.ssh/authorized_keys'

manifest_args=()
if [ "${FULL_MANIFEST:-0}" != "1" ]; then
  manifest_args=(-v "$TMP/manifest:/test-manifest:ro" -e EXTENSIONS_MANIFEST_DIR=/test-manifest)
fi

docker run -d --name "$GW" --network "$NET" \
  -v "$TMP/key:/home/coder/secrets/ssh:ro" \
  -v "$SCRIPT:/vm-connect.sh:ro" \
  -e VM_HOST=vm.test -e VM_USER=ubuntu -e VM_PORT=22 -e VM_REMOTE_DIR=/home/ubuntu/project \
  "${manifest_args[@]}" \
  --entrypoint sleep "$GATEWAY_IMAGE" infinity > /dev/null

# ── A rejected key is reported at once, not retried ──────────────────────────
if out="$(docker exec -e VM_USER=nobody-here "$GW" bash /vm-connect.sh 2>&1)"; then
  fail "wrong user is rejected"
else
  if grep -q 'rejected the key' <<< "$out"; then pass "wrong user is rejected with the public key hint"; else fail "wrong user is rejected with the public key hint"; fi
fi

# ── First connect ────────────────────────────────────────────────────────────
echo "--- first connect"
if docker exec "$GW" bash /vm-connect.sh; then pass "vm-connect.sh succeeds"; else fail "vm-connect.sh succeeds"; fi

check "code-server reachable through the tunnel" healthy
check "workbench page served through the tunnel" gw 'curl -fsSL -m 10 "http://127.0.0.1:13337/?folder=/home/ubuntu/project" | grep -qi "<html"'
if [ "${FULL_MANIFEST:-0}" = "1" ]; then
  echo "--- extensions on the VM after a full-manifest install"
  vm "$VM_CS --list-extensions --show-versions" || true
  vm 'grep -iE "fail|error|not found" ~/.coder-vm-gateway/extensions-install.log' || true
fi
check "code-server process runs on the VM" vm 'pgrep -u ubuntu -f -- "--socket /home/ubuntu/.coder-vm-gateway/code-server.sock"'
# code-server always creates its own ~/.local/share/code-server/coder-logs;
# config, user data, and download cache must stay inside ~/.coder-vm-gateway.
check "config, data and cache stay inside ~/.coder-vm-gateway" vm '[ ! -e ~/.config/code-server ] && [ ! -e ~/.local/share/code-server/User ] && [ ! -e ~/.cache/code-server ]'
check "no code-server process in the gateway" bash -c "! docker exec '$GW' pgrep -f 'code-server.*--socket'"
check "socket is private (mode 600)" vm '[ "$(stat -c %a ~/.coder-vm-gateway/code-server.sock)" = 600 ]'
check "VM version matches the image" bash -c "v() { grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -n 1; }; g=\"\$(docker exec '$GW' code-server --version | v)\"; [ -n \"\$g\" ] && [ \"\$g\" = \"\$(docker exec -u ubuntu '$VM' bash -c '$VM_CS --version' | v)\" ]"
check "server opened in the requested folder" vm 'pgrep -u ubuntu -af -- "--socket" | grep -q " /home/ubuntu/project$"'
check "Machine settings pushed" vm 'grep -q "git.useIntegratedAskPass" ~/.coder-vm-gateway/data/Machine/settings.json'
check "User settings pushed" vm 'grep -q "workbench.colorTheme" ~/.coder-vm-gateway/data/User/settings.json'
check "baked theme .vsix installed" vm "$VM_CS --list-extensions | grep -qi neils-themes"
check "manifest extension installed" vm "$VM_CS --list-extensions | grep -qi usernamehw.errorlens"

# ── Self-heal: server dies on the VM ─────────────────────────────────────────
vm 'pkill -u ubuntu -f -- "--socket /home/ubuntu/.coder-vm-gateway/code-server.sock"' || true
check "killing code-server on the VM breaks the link" bash -c "! docker exec '$GW' curl -fsS -m 2 -o /dev/null http://127.0.0.1:13337/healthz"
check "tunnel recovers after code-server dies on the VM" wait_healthy

# ── Second start keeps user edits, reinstalls nothing ────────────────────────
echo "--- second connect"
vm 'echo "{\"user.edited\": true}" > ~/.coder-vm-gateway/data/User/settings.json'
docker exec "$GW" pkill -f vm-connect.sh || true
docker exec "$GW" pkill -f 'ssh -N' || true
if out="$(docker exec "$GW" bash /vm-connect.sh 2>&1)"; then pass "second connect succeeds"; else fail "second connect succeeds"; fi
if grep -q 'installing' <<< "$out"; then fail "second connect reinstalls nothing"; else pass "second connect reinstalls nothing"; fi
check "User settings edits survive a restart" vm 'grep -q "user.edited" ~/.coder-vm-gateway/data/User/settings.json'
check "reachable after second connect" healthy

# ── Stop (the template's run_on_stop command) ────────────────────────────────
docker exec "$GW" pkill -f vm-connect.sh || true
docker exec "$GW" pkill -f 'ssh -N' || true
gw "ssh -o ConnectTimeout=5 vm 'bash .coder-vm-gateway/remote.sh stop' < /dev/null"
check "stop leaves no code-server on the VM" bash -c "! docker exec -u ubuntu '$VM' pgrep -u ubuntu -f -- '--socket /home/ubuntu/.coder-vm-gateway'"

if [ "$FAILED" -ne 0 ]; then
  echo "--- tunnel log"
  gw 'cat /tmp/vm-tunnel.log' || true
  echo "--- VM code-server log"
  vm 'tail -n 30 ~/.coder-vm-gateway/code-server.log' || true
  exit 1
fi
echo "all checks passed"
