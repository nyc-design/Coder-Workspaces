#!/usr/bin/env bash
set -eu

log() { printf '[keyring-init] %s\n' "$*"; }

log "Initializing keyring daemon for VS Code"

# Check if keyring daemon is available
if ! command -v gnome-keyring-daemon >/dev/null 2>&1; then
  log "gnome-keyring-daemon not installed, skipping"
  exit 0
fi

# Start D-Bus if not running
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  log "Starting D-Bus session"
  eval $(dbus-launch --sh-syntax)
fi

# Start gnome-keyring-daemon (will read from mounted /home/coder/.local/share/keyrings)
log "Starting gnome-keyring-daemon"
eval $(gnome-keyring-daemon --start --daemonize --components=secrets,ssh,pkcs11 2>/dev/null)

# Export the variables for current session
export DBUS_SESSION_BUS_ADDRESS
export GNOME_KEYRING_CONTROL
export SSH_AUTH_SOCK
export GNOME_KEYRING_PID

# Save to .bashrc for shell sessions (idempotent)
if ! grep -q "# --- Keyring environment ---" /home/coder/.bashrc; then
  cat >> /home/coder/.bashrc <<'EOF'

# --- Keyring environment ---
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  export DBUS_SESSION_BUS_ADDRESS
fi
if [ -n "${GNOME_KEYRING_CONTROL:-}" ]; then
  export GNOME_KEYRING_CONTROL
fi
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
  export SSH_AUTH_SOCK
fi
# ---
EOF
fi

log "Keyring daemon started (using mounted keyring at /home/coder/.local/share/keyrings)"
