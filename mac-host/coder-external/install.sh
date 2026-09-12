#!/bin/zsh
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 [user/]WORKSPACE" >&2
  exit 2
fi

WORKSPACE="$1"
command -v coder >/dev/null || {
  echo "Coder CLI is required and must already be logged in to your deployment." >&2
  exit 1
}
command -v jq >/dev/null || {
  echo "jq is required (brew install jq)." >&2
  exit 1
}

SAFE_NAME="$(printf '%s' "$WORKSPACE" | tr '/.@ ' '----' | tr -cd '[:alnum:]_-')"
LABEL="com.nyc-design.coder-external.$SAFE_NAME"
INSTALL_ROOT="$HOME/.local/share/coder-mac/coder-external/$SAFE_NAME"
RUN_SCRIPT="$INSTALL_ROOT/run.sh"
LOG_DIR="$HOME/Library/Logs/CoderMac"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

INSTRUCTIONS="$(coder external-workspaces agent-instructions "$WORKSPACE" --output=json)"
INIT_SCRIPT="$(printf '%s' "$INSTRUCTIONS" | jq -r '.init_script')"
if [[ -z "$INIT_SCRIPT" || "$INIT_SCRIPT" == "null" ]]; then
  echo "Coder did not return an external-agent init script for $WORKSPACE." >&2
  exit 1
fi

mkdir -p "$INSTALL_ROOT" "$LOG_DIR" "$HOME/Library/LaunchAgents"
cat > "$RUN_SCRIPT" <<EOF
#!/bin/zsh
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
$INIT_SCRIPT
EOF
chmod 700 "$RUN_SCRIPT"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$RUN_SCRIPT</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/$SAFE_NAME.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/$SAFE_NAME.stderr.log</string>
</dict>
</plist>
EOF
chmod 600 "$PLIST"

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

cat <<EOF
Persistent Coder external agent installed for $WORKSPACE.

LaunchAgent: $LABEL
Run script:  $RUN_SCRIPT

The run script contains the workspace's external-agent token and is mode 700. Re-run this installer if you delete/recreate the external workspace or otherwise rotate its agent token.

Status:
  launchctl print gui/$(id -u)/$LABEL
EOF
