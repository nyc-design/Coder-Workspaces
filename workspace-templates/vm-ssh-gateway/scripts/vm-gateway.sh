#!/usr/bin/env bash
# vm-ssh-gateway: point this workspace's code-server at a VM over SSH.
#
# code-server runs here, in the workspace container, and nothing is installed
# on the VM. This script only prepares inputs for the image's normal init
# pipeline (run-workspace-inits), which then installs extensions, applies
# settings, and assembles the agent prompt as it does in every workspace:
#
#   configure  write the SSH config, plus an extension manifest (SSH FS), a
#              settings manifest (the VM as an ssh:// folder, terminals that
#              open on the VM), an agent prompt fragment, and the workspace
#              file the code-server app opens. Run BEFORE run-workspace-inits.
#   check      verify the VM is reachable with the shared key and explain how
#              to fix it if not. Run AFTER run-workspace-inits so the editor
#              still comes up when the VM is down.
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
VM_SSH_KEY_SOURCE="${VM_SSH_KEY_SOURCE:-/home/coder/secrets/ssh/coder_workspace_ssh}"

SSH_ALIAS="vm"
SSH_KEY="$HOME/.ssh/vm_gateway_key"
WORKSPACE_FILE="${VM_WORKSPACE_FILE:-$HOME/vm.code-workspace}"

# Drop-in dirs read by the image's init scripts (25-extensions-install,
# 26-settings-apply, 11-agent-prompts). The 90- prefix sorts after the image's
# own manifests, so these win on key collisions.
EXTENSIONS_MANIFEST_DIR="${EXTENSIONS_MANIFEST_DIR:-/usr/local/share/workspace-extensions.d}"
SETTINGS_MANIFEST_DIR="${SETTINGS_MANIFEST_DIR:-/usr/local/share/workspace-settings.d}"
PROMPTS_DIR="${PROMPTS_DIR:-/usr/local/share/workspace-prompts}"

# The template validates these too; re-check here because they end up in an
# SSH config and on command lines.
validate() {
  [[ "$VM_HOST" =~ ^[A-Za-z0-9:][A-Za-z0-9.:-]*$ ]] || die "invalid VM_HOST"
  [[ "$VM_USER" =~ ^[a-z_][a-z0-9_.-]*$ ]] || die "invalid VM_USER"
  [[ "$VM_PORT" =~ ^[0-9]+$ ]] || die "invalid VM_PORT"
  [[ "$VM_REMOTE_DIR" =~ ^$|^/[A-Za-z0-9._/-]*$ ]] || die "invalid VM_REMOTE_DIR"
}

# write_root <path>: stdin -> a root-owned, world-readable file.
write_root() {
  sudo mkdir -p "$(dirname "$1")"
  sudo tee "$1" > /dev/null
  sudo chmod 644 "$1"
}

configure_ssh() {
  [ -f "$VM_SSH_KEY_SOURCE" ] || die "SSH key not found at $VM_SSH_KEY_SOURCE (expected from the host's /home/ubuntu/secrets/ssh mount)."

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  # Copy rather than reference the mount: ssh refuses keys whose mode or owner
  # looks wrong, and the bind mount's ownership is not ours to fix.
  install -m 600 "$VM_SSH_KEY_SOURCE" "$SSH_KEY"

  # This workspace exists only to reach one VM, and ~/.ssh is its own volume
  # (not the host's shared ~/.ssh), so the config is rewritten on every start.
  # ControlMaster lets repeated `ssh vm <command>` calls (terminals, AI agents)
  # reuse one connection instead of paying for a handshake each time.
  cat > "$HOME/.ssh/config" <<CFG
Host $SSH_ALIAS
  HostName $VM_HOST
  User $VM_USER
  Port $VM_PORT
  IdentityFile $SSH_KEY
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking accept-new
  ConnectTimeout 10
  ServerAliveInterval 15
  ServerAliveCountMax 3
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m
  # Do not forward this container's locale; the VM may not have it generated.
  SetEnv LC_ALL=C.UTF-8
CFG
  chmod 600 "$HOME/.ssh/config"
}

# The folder to open. SSH FS addresses folders by absolute path, so an empty
# VM_REMOTE_DIR is resolved to the VM user's home; if the VM is unreachable
# right now, fall back to the conventional location.
remote_root() {
  local home
  if [ -n "$VM_REMOTE_DIR" ]; then
    printf '%s' "$VM_REMOTE_DIR"
  elif home="$(ssh "$SSH_ALIAS" 'printf %s "$HOME"' 2> /dev/null < /dev/null)" && [[ "$home" =~ ^/[A-Za-z0-9._/-]*$ ]]; then
    printf '%s' "$home"
  elif [ "$VM_USER" = root ]; then
    printf /root
  else
    printf '/home/%s' "$VM_USER"
  fi
}

configure_editor() {
  local root term_args quoted_dir
  root="$(remote_root)"

  # Integrated terminals open on the VM, in the opened folder.
  if [ -n "$VM_REMOTE_DIR" ]; then
    printf -v quoted_dir '%q' "$VM_REMOTE_DIR"
    term_args="$(jq -cn --arg a "$SSH_ALIAS" --arg c "cd $quoted_dir && exec \"\${SHELL:-bash}\" -l" '["-t", $a, $c]')"
  else
    term_args="$(jq -cn --arg a "$SSH_ALIAS" '[$a]')"
  fi

  jq -n '{shared: ["Kelvin.vscode-sshfs"]}' | write_root "$EXTENSIONS_MANIFEST_DIR/90-vm-gateway.json"

  # Machine settings are rewritten on every start, so changing the template
  # parameters repoints an existing workspace. User settings are written once.
  jq -n \
    --arg alias "$SSH_ALIAS" --arg host "$VM_HOST" --arg user "$VM_USER" \
    --argjson port "$VM_PORT" --arg key "$SSH_KEY" --arg root "$root" \
    --argjson term_args "$term_args" --arg home "$HOME" '
    {
      user: {
        # The ssh:// folder would otherwise open in Restricted Mode, which
        # disables the extension that provides it.
        "security.workspace.trust.enabled": false
      },
      machine: {
        "sshfs.configs": [{
          name: $alias, host: $host, port: $port, username: $user,
          privateKeyPath: $key, root: $root
        }],
        "terminal.integrated.profiles.linux": {
          "VM": { path: "ssh", args: $term_args, icon: "remote" },
          "Workspace (bash)": { path: "bash", icon: "terminal-bash" }
        },
        "terminal.integrated.defaultProfile.linux": "VM",
        # Terminals are local processes (ssh, or bash). Without this, VS Code
        # starts them in the workspace folder path, which only exists on the
        # VM, and the terminal fails to launch.
        "terminal.integrated.cwd": $home
      }
    }' | write_root "$SETTINGS_MANIFEST_DIR/90-vm-gateway.json"

  write_root "$PROMPTS_DIR/90-vm-gateway.txt" <<PROMPT
-- VM gateway workspace --
This workspace is a gateway to a remote VM: $VM_USER@$VM_HOST (SSH alias \`$SSH_ALIAS\`). The project lives on the VM at \`$root\`, not in this container. The editor shows it as an ssh:// folder; it is NOT mounted on this container's filesystem, so local file tools cannot see it.
- Run commands on the VM with \`ssh $SSH_ALIAS '<command>'\`, e.g. \`ssh $SSH_ALIAS 'cd $root && git status'\`. Connections are multiplexed, so repeated calls are fast.
- Read and edit VM files over SSH too: \`ssh $SSH_ALIAS 'cat <path>'\`, \`scp\`, or \`rsync\` to and from \`$SSH_ALIAS:\`.
- A bare shell command runs in this container, not on the VM. Do not install project tooling here.
PROMPT

  jq -n --arg uri "ssh://$SSH_ALIAS$root" --arg name "$VM_HOST" \
    '{folders: [{uri: $uri, name: $name}]}' > "$WORKSPACE_FILE"
}

check() {
  local attempt err
  for attempt in $(seq 1 5); do
    if err="$(ssh "$SSH_ALIAS" true 2>&1 < /dev/null)"; then
      log "connected to $VM_USER@$VM_HOST:$VM_PORT"
      return 0
    fi
    log "cannot reach $VM_USER@$VM_HOST:$VM_PORT (attempt $attempt/5): ${err##*$'\n'}"
    case "$err" in
      *"Permission denied"*)
        die "the VM rejected the key. Add this public key to ~/.ssh/authorized_keys for '$VM_USER' on the VM, then restart the workspace: $(ssh-keygen -y -f "$SSH_KEY" 2> /dev/null || echo '<could not derive public key>')"
        ;;
      *"HOST IDENTIFICATION HAS CHANGED"*)
        die "the VM's host key changed (rebuilt VM or reused IP). If that is expected, run in a workspace terminal: ssh-keygen -R '$VM_HOST' ; then reload the editor."
        ;;
    esac
    sleep 5
  done
  die "gave up reaching $VM_USER@$VM_HOST:$VM_PORT. Check the IP, the VM's firewall / security list for port $VM_PORT, and that the VM is running. The editor is up and will connect once the VM is reachable."
}

validate
case "${1:-}" in
  configure)
    configure_ssh
    configure_editor
    log "configured for $VM_USER@$VM_HOST:$VM_PORT (folder: ${VM_REMOTE_DIR:-home directory})"
    ;;
  check) check ;;
  *)
    echo "usage: vm-gateway.sh {configure|check}" >&2
    exit 2
    ;;
esac
