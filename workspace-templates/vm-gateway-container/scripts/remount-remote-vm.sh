#!/usr/bin/env bash
set -euo pipefail

MOUNT_DIR="${MOUNT_DIR:-/workspaces/remote-vm}"
REMOTE_PATH="${REMOTE_PATH:-}"
HOST_ALIAS="${HOST_ALIAS:-barevm}"

if [[ -z "${REMOTE_PATH}" ]]; then
  echo "Set REMOTE_PATH env var (e.g. /home/ubuntu or /srv/data)." >&2
  echo "Example: REMOTE_PATH=/home/ubuntu $0"
  exit 1
fi

mkdir -p "$MOUNT_DIR"

if mountpoint -q "$MOUNT_DIR"; then
  echo "Unmounting existing mount at $MOUNT_DIR"
  fusermount -u "$MOUNT_DIR" || umount "$MOUNT_DIR" || true
fi

echo "Mounting ${HOST_ALIAS}:${REMOTE_PATH} -> ${MOUNT_DIR}"
sshfs "${HOST_ALIAS}:${REMOTE_PATH}" "$MOUNT_DIR" \
  -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks

echo "Mounted successfully"
