#!/usr/bin/env bash
set -eu

log() { printf '[init] %s\n' "$*"; }

# --- Fix /run perms ---
log "fixing /run and /var/run perms"
mkdir -p /run /var/run
chmod 755 /run || true
chmod 755 /var/run || true

# --- Start dockerd ---
log "starting dockerd"
nohup dockerd --host=unix:///var/run/docker.sock --storage-driver=overlay2 > /tmp/dockerd.log 2>&1 &

# Wait for the socket to appear
for i in $(seq 1 60); do
  if test -S /var/run/docker.sock; then
    break
  fi
  sleep 0.5
done

if ! test -S /var/run/docker.sock; then
  log "dockerd socket never appeared; tailing logs"
  tail -n 200 /tmp/dockerd.log || true
  exit 1
fi

# Set socket perms
log "setting socket ownership & perms"
chown coder:coder /var/run/docker.sock
chmod 660         /var/run/docker.sock
[ -S /run/docker.sock ] || ln -sf /var/run/docker.sock /run/docker.sock

# Add coder to docker group
groupadd -f docker
usermod -aG docker coder || true

# Sanity check
if ! docker info >/dev/null 2>&1; then
  log "docker info failed; tailing logs"
  tail -n 200 /tmp/dockerd.log || true
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

# Hand off to CMD (e.g., coder agent)
exit 0