#!/usr/bin/env bash
set -eu

log() { printf '[init] %s\n' "$*"; }

# --- Fix /run perms ---
log "fixing /run and /var/run perms"
sudo mkdir -p /run /var/run
sudo chmod 755 /run || true
sudo chmod 755 /var/run || true

# --- Start dockerd ---
log "starting dockerd"
sudo nohup dockerd --host=unix:///var/run/docker.sock --storage-driver=overlay2 > /tmp/dockerd.log 2>&1 &

# Wait for the socket to appear
for i in $(seq 1 60); do
  if sudo test -S /var/run/docker.sock; then
    break
  fi
  sleep 0.5
done

if ! sudo test -S /var/run/docker.sock; then
  log "dockerd socket never appeared; tailing logs"
  sudo tail -n 200 /tmp/dockerd.log || true
  exit 1
fi

# Set socket perms
log "setting socket ownership & perms"
sudo chown coder:coder /var/run/docker.sock
sudo chmod 660         /var/run/docker.sock
[ -S /run/docker.sock ] || sudo ln -sf /var/run/docker.sock /run/docker.sock

# Add coder to docker group
sudo groupadd -f docker
sudo usermod -aG docker coder || true

# Sanity check
if ! docker info >/dev/null 2>&1; then
  log "docker info failed; tailing logs"
  sudo tail -n 200 /tmp/dockerd.log || true
  exit 1
fi
log "dockerd is ready"

# --- Colored prompt ---
if ! grep -q 'custom colored prompt' /home/coder/.bashrc 2>/dev/null; then
  cat >> /home/coder/.bashrc <<'EOF'
# --- custom colored prompt ---
force_color_prompt=yes
PS1='$${debian_chroot:+($${debian_chroot})}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
# -----------------------------
EOF
fi

# --- GitHub auth (runner executes as coder) ---
if [[ -n "${GH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  log "configuring GitHub auth via gh + GH_TOKEN"

  # Use gh CLI as the Git credential helper
  git config --global --unset-all credential.helper || true
  git config --global credential.helper '!gh auth git-credential'
  git config --global core.askPass ''

elif [[ -n "${GITHUB_PAT:-}" ]]; then
  log "configuring GitHub auth via stored GITHUB_PAT"

  umask 077
  cat > /home/coder/.git-credentials <<EOF
https://x-access-token:${GITHUB_PAT}@github.com
EOF
  chmod 600 /home/coder/.git-credentials

  git config --global --unset-all credential.helper || true
  git config --global credential.helper 'store --file=/home/coder/.git-credentials'
  git config --global core.askPass ''
else
  log "no GitHub token provided; skipping credential setup"
fi

# Hand off to CMD (e.g., coder agent)
exit 0