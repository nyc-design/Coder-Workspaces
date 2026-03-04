#!/usr/bin/env bash
set -eu

log() { printf '[docker-init] %s\n' "$*"; }
SOCK_PATH="/var/run/docker.sock"
DOCKER_HOST_LOCAL="unix://${SOCK_PATH}"

is_path_mounted() {
  # mountinfo field 5 is mount point path
  sudo awk -v p="$1" '$5 == p {found=1} END {exit found ? 0 : 1}' /proc/self/mountinfo
}

docker_ready_root() {
  sudo DOCKER_HOST="${DOCKER_HOST_LOCAL}" docker info >/dev/null 2>&1
}

docker_ready_user() {
  DOCKER_HOST="${DOCKER_HOST_LOCAL}" docker info >/dev/null 2>&1
}

# --- Fix /run perms ---
log "fixing /run and /var/run perms"
sudo mkdir -p /run /var/run
sudo chmod 755 /run || true
sudo chmod 755 /var/run || true

# Ensure docker group exists before socket ownership changes.
sudo groupadd -f docker || true
sudo usermod -aG docker coder || true

# If the docker socket path is a mount (host bind mount), unmount it so
# this workspace can run isolated inner dockerd.
if is_path_mounted "${SOCK_PATH}"; then
  log "${SOCK_PATH} is mounted; unmounting to enable isolated workspace docker"
  if ! sudo umount "${SOCK_PATH}"; then
    log "failed to unmount ${SOCK_PATH}; continuing (workspace may use mounted docker socket)"
    sudo awk -v p="${SOCK_PATH}" '$5 == p {print}' /proc/self/mountinfo || true
  fi
fi

# Remove stale socket (not mounted and no responsive daemon).
if sudo test -S "${SOCK_PATH}" && ! docker_ready_root; then
  log "removing stale docker socket at ${SOCK_PATH}"
  sudo rm -f "${SOCK_PATH}" || true
fi

if docker_ready_root; then
  log "dockerd already available on ${DOCKER_HOST_LOCAL}"
else
  # --- Start dockerd ---
  log "starting inner dockerd"
  sudo nohup dockerd \
    --host="${DOCKER_HOST_LOCAL}" \
    --storage-driver=overlay2 \
    --data-root=/var/lib/docker \
    > /tmp/dockerd.log 2>&1 &
fi

# Wait for the socket to appear
for i in $(seq 1 60); do
  if docker_ready_root; then
    break
  fi
  sleep 0.5
done

if ! docker_ready_root; then
  log "dockerd did not become ready on ${DOCKER_HOST_LOCAL}; tailing logs"
  sudo tail -n 200 /tmp/dockerd.log || true
  exit 1
fi

# Set socket perms
log "setting socket ownership & perms"
sudo chown coder:coder "${SOCK_PATH}" || true
sudo chmod 660 "${SOCK_PATH}" || true
[ -S /run/docker.sock ] || sudo ln -sf "${SOCK_PATH}" /run/docker.sock

# Sanity check as workspace user
if ! docker_ready_user; then
  log "docker info failed for workspace user; tailing logs"
  sudo tail -n 200 /tmp/dockerd.log || true
  exit 1
fi
log "dockerd is ready (${DOCKER_HOST_LOCAL})"
