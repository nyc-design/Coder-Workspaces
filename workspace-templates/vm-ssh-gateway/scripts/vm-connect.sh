#!/usr/bin/env bash
# Gateway side of the vm-ssh-gateway template.
#
# Runs inside the workspace container on every start. It does what VS Code's
# Remote-SSH does, with code-server instead of the VS Code server:
#
#   1. configure SSH to the VM with the shared key
#   2. install code-server on the VM (same version as this image)
#   3. push this image's editor settings, baked themes, and extension manifest
#   4. start code-server on the VM, listening on a private unix socket
#   5. keep an SSH tunnel from localhost:$VM_TUNNEL_PORT to that socket
#
# The Coder "code-server" app points at the local end of the tunnel, so the
# editor, its terminals, and its extensions all run on the VM. Nothing but
# sshd, bash, and curl is needed there; no Coder agent is installed.
#
# Inputs arrive as environment variables (set on the coder_agent) so no
# user-supplied value is ever spliced into this script's text.

set -euo pipefail

log() { printf '[vm-gateway] %s\n' "$*"; }
die() {
  log "ERROR: $*" >&2
  exit 1
}

: "${VM_HOST:?VM_HOST is required}"
: "${VM_USER:?VM_USER is required}"
VM_PORT="${VM_PORT:-22}"
VM_REMOTE_DIR="${VM_REMOTE_DIR:-}"
VM_SSH_KEY_SOURCE="${VM_SSH_KEY_SOURCE:-/home/coder/secrets/ssh/id_ed25519}"
VM_TUNNEL_PORT="${VM_TUNNEL_PORT:-13337}"

SSH_ALIAS="vm"
# Everything this template puts on the VM lives here, relative to the VM
# user's home, so `rm -rf ~/.coder-vm-gateway` there is the uninstall. (The one
# exception is code-server's own log directory, which it always creates at
# ~/.local/share/code-server/coder-logs.)
REMOTE_ROOT=".coder-vm-gateway"
TUNNEL_LOG="${VM_TUNNEL_LOG:-/tmp/vm-tunnel.log}"

# Editor setup baked into the workspace image (base-dev).
EXTENSIONS_MANIFEST_DIR="${EXTENSIONS_MANIFEST_DIR:-/usr/local/share/workspace-extensions.d}"
SETTINGS_APPLY_SCRIPT="${SETTINGS_APPLY_SCRIPT:-/usr/local/share/workspace-init.d/26-settings-apply.sh}"
THEMES_DIR="${THEMES_DIR:-/usr/local/share/shared-assets/vscode-themes}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ssh forwards the locale, and the VM may not have this container's generated;
# C.UTF-8 exists everywhere and keeps the VM's bash from warning on every call.
unset LANG LANGUAGE
export LC_ALL=C.UTF-8

configure_ssh() {
  [ -f "$VM_SSH_KEY_SOURCE" ] || die "SSH key not found at $VM_SSH_KEY_SOURCE (expected from the host's /home/ubuntu/secrets/ssh mount)."

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  # Copy rather than reference the mount: ssh refuses keys whose mode or owner
  # looks wrong, and the bind mount's ownership is not ours to fix.
  install -m 600 "$VM_SSH_KEY_SOURCE" "$HOME/.ssh/vm_gateway_key"

  # This workspace exists only to reach one VM, so the config is owned
  # wholesale by this script and rewritten on every start.
  cat > "$HOME/.ssh/config" <<CFG
Host $SSH_ALIAS
  HostName $VM_HOST
  User $VM_USER
  Port $VM_PORT
  IdentityFile ~/.ssh/vm_gateway_key
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking accept-new
  ConnectTimeout 10
  ServerAliveInterval 15
  ServerAliveCountMax 3
CFG
  chmod 600 "$HOME/.ssh/config"
}

wait_for_vm() {
  local attempt err
  for attempt in $(seq 1 10); do
    if err="$(ssh "$SSH_ALIAS" true 2>&1 < /dev/null)"; then
      return 0
    fi
    log "cannot reach $VM_USER@$VM_HOST:$VM_PORT (attempt $attempt/10): ${err##*$'\n'}"
    case "$err" in
      *"Permission denied"*)
        die "the VM rejected the key. Add this public key to ~/.ssh/authorized_keys for '$VM_USER' on the VM: $(ssh-keygen -y -f "$HOME/.ssh/vm_gateway_key" 2> /dev/null || echo '<could not derive public key>')"
        ;;
      *"HOST IDENTIFICATION HAS CHANGED"*)
        die "the VM's host key changed (rebuilt VM or reused IP). If that is expected, run in this workspace's terminal: ssh-keygen -R '$VM_HOST' ; then restart the workspace."
        ;;
    esac
    sleep 6
  done
  die "gave up reaching $VM_USER@$VM_HOST:$VM_PORT. Check the IP, the VM's firewall / security list for port $VM_PORT, and that the VM is running."
}

# remote <subcommand> [args...]: run the VM-side helper. Arguments are
# shell-quoted because ssh joins them into a single string for the remote shell.
remote() {
  local args=""
  if [ "$#" -gt 0 ]; then
    printf -v args ' %q' "$@"
  fi
  ssh "$SSH_ALIAS" "bash $REMOTE_ROOT/remote.sh$args" < /dev/null
}

# push <local-file> <remote-path>: remote path is relative to the VM home.
# Plain `cat` over ssh so the VM needs neither rsync nor an sftp subsystem.
push() {
  local dest
  printf -v dest '%q' "$2"
  ssh "$SSH_ALIAS" "mkdir -p \"\$(dirname $dest)\" && cat > $dest" < "$1"
}

write_remote_helper() {
  cat > "$WORK_DIR/remote.sh" <<'REMOTE'
#!/usr/bin/env bash
# VM side of the Coder vm-ssh-gateway template. Uploaded on every workspace
# start by the gateway; do not edit here, edit the template.
set -euo pipefail

ROOT="$HOME/.coder-vm-gateway"
BIN="$ROOT/bin/code-server"
SOCK="$ROOT/code-server.sock"
LOG="$ROOT/code-server.log"

log() { printf '[vm] %s\n' "$*"; }

# --config keeps code-server from reading or creating ~/.config/code-server on
# the VM, so a config the user already has there cannot change this server.
cs() { "$BIN" --config "$ROOT/config.yaml" --user-data-dir "$ROOT/data" --extensions-dir "$ROOT/extensions" "$@"; }

# The socket path is unique to this install, so matching it on the command
# line identifies our server without a pid file that could go stale across a
# VM reboot.
running() { pgrep -u "$(id -u)" -f -- "--socket $SOCK" > /dev/null; }

cmd_install() {
  local version="$1" dir
  dir="$ROOT/lib/code-server-$version"
  if [ ! -x "$dir/bin/code-server" ]; then
    command -v curl > /dev/null || {
      log "curl is required on the VM to download code-server" >&2
      return 1
    }
    log "installing code-server $version ($(uname -m))"
    rm -rf "$dir"
    # Keep the installer's download cache inside ROOT so it can be dropped.
    curl -fsSL https://code-server.dev/install.sh \
      | XDG_CACHE_HOME="$ROOT/cache" sh -s -- --method=standalone --prefix="$ROOT" --version="$version" > "$ROOT/install.log" 2>&1 \
      || {
        tail -n 20 "$ROOT/install.log" >&2
        return 1
      }
    rm -rf "$ROOT/cache"
  fi
  mkdir -p "$ROOT/bin"
  ln -sfn "$dir/bin/code-server" "$BIN"
  # Drop versions left behind by earlier image updates.
  find "$ROOT/lib" -mindepth 1 -maxdepth 1 -name 'code-server-*' ! -name "code-server-$version" -exec rm -rf {} +
  log "code-server $version ready"
}

# Install baked .vsix files the gateway uploaded, then any manifest id that is
# not installed yet. Never uninstalls or downgrades; updates after the first
# install are left to the editor's own extension auto-update.
cmd_extensions() {
  local vsix current installed id args=()
  mkdir -p "$ROOT/vsix/incoming"
  for vsix in "$ROOT"/vsix/incoming/*.vsix; do
    [ -e "$vsix" ] || continue
    current="$ROOT/vsix/$(basename "$vsix")"
    if cmp -s "$vsix" "$current"; then
      rm -f "$vsix"
      continue
    fi
    log "installing $(basename "$vsix")"
    if cs --install-extension "$vsix" --force > /dev/null; then
      mv -f "$vsix" "$current"
    else
      log "warning: failed to install $(basename "$vsix")" >&2
    fi
  done

  installed="$(cs --list-extensions | tr '[:upper:]' '[:lower:]')"
  for id in "$@"; do
    # Manifest entries are `publisher.name` or `publisher.name@version`.
    if ! grep -qxF "$(printf '%s' "${id%%@*}" | tr '[:upper:]' '[:lower:]')" <<< "$installed"; then
      args+=(--install-extension "$id")
    fi
  done
  if [ "${#args[@]}" -gt 0 ]; then
    log "installing $((${#args[@]} / 2)) extension(s) from OpenVSX"
    cs "${args[@]}" > "$ROOT/extensions-install.log" 2>&1 \
      || log "warning: some extensions failed to install; see ~/.coder-vm-gateway/extensions-install.log" >&2
  fi
}

cmd_start() {
  local dir="${1:-}"
  [ -n "$dir" ] || dir="$HOME"
  if running; then
    return 0
  fi
  [ -x "$BIN" ] || {
    log "code-server is not installed" >&2
    return 1
  }
  rm -f "$SOCK"
  # --auth none is safe only because the socket is mode 600 in the user's own
  # home: the sole way in is an SSH session as this user.
  nohup "$BIN" --config "$ROOT/config.yaml" --auth none --socket "$SOCK" --socket-mode 600 \
    --user-data-dir "$ROOT/data" --extensions-dir "$ROOT/extensions" \
    "$dir" > "$LOG" 2>&1 < /dev/null &
  for _ in $(seq 1 60); do
    [ -S "$SOCK" ] && return 0
    sleep 0.5
  done
  log "code-server did not come up; last log lines:" >&2
  tail -n 20 "$LOG" >&2 || true
  return 1
}

cmd_stop() {
  pkill -u "$(id -u)" -f -- "--socket $SOCK" || true
  for _ in $(seq 1 20); do
    running || break
    sleep 0.5
  done
  rm -f "$SOCK"
}

case "${1:-}" in
  install | extensions | start | stop)
    cmd="$1"
    shift
    "cmd_$cmd" "$@"
    ;;
  *)
    echo "usage: remote.sh {install <version>|extensions [id...]|start [dir]|stop}" >&2
    exit 2
    ;;
esac
REMOTE
  push "$WORK_DIR/remote.sh" "$REMOTE_ROOT/remote.sh"
}

install_code_server() {
  local version
  # Match the image's version so the pushed settings and the manifest's
  # extensions behave the same as in every other workspace. A first run also
  # prints a log line about its config file, so pick the version out by shape.
  version="$(code-server --version 2> /dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  [ -n "$version" ] || die "could not determine this image's code-server version"
  remote install "$version" || die "could not install code-server $version on the VM. The VM needs curl and outbound HTTPS to code-server.dev and github.com."
}

# Reuse the image's settings manifests and its merge rules: Machine settings
# are template-managed and rewritten every start; User settings are written
# once and then belong to whoever edits them on the VM.
sync_settings() {
  if [ ! -x "$SETTINGS_APPLY_SCRIPT" ]; then
    log "no settings script at $SETTINGS_APPLY_SCRIPT; skipping settings"
    return 0
  fi
  local stage="$WORK_DIR/settings" data="$REMOTE_ROOT/data"
  mkdir -p "$stage"
  CODE_SERVER_USER_SETTINGS="$stage/user.json" \
    CODE_SERVER_MACHINE_SETTINGS="$stage/machine.json" \
    VSCODE_WEB_MACHINE_SETTINGS="$stage/unused.json" \
    "$SETTINGS_APPLY_SCRIPT" > /dev/null

  if [ -f "$stage/machine.json" ]; then
    push "$stage/machine.json" "$data/Machine/settings.json"
  fi
  if [ -f "$stage/user.json" ] && ! ssh "$SSH_ALIAS" "[ -e $data/User/settings.json ]" < /dev/null; then
    push "$stage/user.json" "$data/User/settings.json"
  fi
}

sync_extensions() {
  local vsix ids=()
  for vsix in "$THEMES_DIR"/*.vsix; do
    [ -e "$vsix" ] || continue
    push "$vsix" "$REMOTE_ROOT/vsix/incoming/$(basename "$vsix")"
  done
  if compgen -G "$EXTENSIONS_MANIFEST_DIR/*.json" > /dev/null; then
    # `shared` is the OpenVSX list; `vscode_web_only` is Marketplace-only and
    # does not apply to code-server.
    mapfile -t ids < <(jq -r '.shared[]?' "$EXTENSIONS_MANIFEST_DIR"/*.json | grep -E '^[A-Za-z0-9._@-]+$' | sort -u)
  fi
  remote extensions "${ids[@]}"
}

tunnel_healthy() { curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${VM_TUNNEL_PORT}/healthz" 2> /dev/null; }

# Runs for the life of the workspace. Each pass makes sure the VM-side server
# is up and then holds the tunnel open. The tunnel alone outlives a dead
# server (ssh stays connected; only the forwarded requests fail), so health is
# probed through it and three misses in a row tear it down for another pass.
# That covers a crashed server, a rebooted VM, and a dropped connection alike.
supervise_tunnel() {
  local remote_sock="$1" tunnel_pid misses
  while :; do
    if remote start "$VM_REMOTE_DIR"; then
      ssh -N -o ExitOnForwardFailure=yes \
        -L "127.0.0.1:${VM_TUNNEL_PORT}:${remote_sock}" "$SSH_ALIAS" < /dev/null &
      tunnel_pid=$!
      misses=0
      while kill -0 "$tunnel_pid" 2> /dev/null && [ "$misses" -lt 3 ]; do
        sleep 5
        if tunnel_healthy; then misses=0; else misses=$((misses + 1)); fi
      done
      kill "$tunnel_pid" 2> /dev/null || true
      wait "$tunnel_pid" 2> /dev/null || true
      echo "[vm-gateway] $(date -u +%FT%TZ) link to the VM lost; reconnecting"
    fi
    sleep 3
  done
}

main() {
  log "connecting to $VM_USER@$VM_HOST:$VM_PORT"
  configure_ssh
  wait_for_vm

  local remote_home
  remote_home="$(ssh "$SSH_ALIAS" 'printf %s "$HOME"' < /dev/null)"
  [ -n "$remote_home" ] || die "could not determine the VM user's home directory"

  write_remote_helper
  # A workspace start always begins from a fresh server so a new code-server
  # version, new settings, and new extensions all take effect.
  remote stop
  install_code_server
  sync_settings
  sync_extensions

  log "starting code-server on the VM and opening the tunnel"
  supervise_tunnel "$remote_home/$REMOTE_ROOT/code-server.sock" > "$TUNNEL_LOG" 2>&1 < /dev/null &

  for _ in $(seq 1 60); do
    if tunnel_healthy; then
      log "connected: code-server on $VM_HOST is available on the code-server app"
      return 0
    fi
    sleep 1
  done
  tail -n 20 "$TUNNEL_LOG" >&2 || true
  die "code-server on the VM did not become reachable through the tunnel; see $TUNNEL_LOG"
}

main "$@"
