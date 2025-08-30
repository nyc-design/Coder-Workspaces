#!/usr/bin/env bash
set -euo pipefail

export DISPLAY=${DISPLAY:-:99}
log(){ printf '[vnc] %s\n' "$*"; }

# 1) X server
if ! pgrep -x Xvfb >/dev/null 2>&1; then
  log "starting Xvfb on ${DISPLAY}"
  nohup Xvfb "${DISPLAY}" -screen 0 1920x1080x24 -nolisten tcp > /tmp/xvfb.log 2>&1 &
  for i in {1..20}; do xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1 && break || sleep 0.3; done
fi

# 2) Window manager as 'coder'
start_as_coder() {
  if command -v runuser >/dev/null 2>&1; then
    runuser -u coder -- env DISPLAY="${DISPLAY}" "$@"
  else
    # Fallback: assume running as coder user
    env DISPLAY="${DISPLAY}" "$@"
  fi
}
if ! pgrep -u coder -x fluxbox >/dev/null 2>&1; then
  log "starting fluxbox"
  nohup start_as_coder fluxbox > /tmp/fluxbox.log 2>&1 &
fi

# 3) VNC server (localhost only)
if ! pgrep -x x11vnc >/dev/null 2>&1; then
  log "starting x11vnc (rfbport 5900, localhost)"
  nohup x11vnc -display "${DISPLAY}" -rfbport 5900 -localhost -forever -shared -nopw -repeat \
    > /tmp/x11vnc.log 2>&1 &
fi

# 4) noVNC (WebSocket bridge → http://localhost:6080)
if ! pgrep -f "websockify.*6080" >/dev/null 2>&1; then
  log "starting noVNC on http://localhost:6080"
  nohup websockify --web=/usr/share/novnc 6080 localhost:5900 > /tmp/novnc.log 2>&1 &
fi

log "ready. forward port 6080 and open it in your browser."