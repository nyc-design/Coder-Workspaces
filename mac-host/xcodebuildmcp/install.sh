#!/bin/zsh
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_ROOT="$HOME/.local/share/coder-mac/xcodebuildmcp"
CONFIG_DIR="$HOME/.config/coder-mac"
CONFIG_FILE="$CONFIG_DIR/xcodebuildmcp.env"
LOG_DIR="$HOME/Library/Logs/CoderMac"
PLIST="$HOME/Library/LaunchAgents/com.nyc-design.xcodebuildmcp.plist"
PORT="${XCODE_MCP_PORT:-8765}"

if ! command -v brew >/dev/null; then
  echo "Homebrew is required. Install it first from https://brew.sh" >&2
  exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode must be installed and selected before installing XcodeBuildMCP." >&2
  exit 1
fi

if ! command -v xcodebuildmcp >/dev/null; then
  brew tap getsentry/xcodebuildmcp
  brew install xcodebuildmcp
fi

if ! command -v node >/dev/null; then
  brew install node
fi

if ! command -v mcp-proxy >/dev/null; then
  npm install -g mcp-proxy@latest
fi

mkdir -p "$INSTALL_ROOT" "$CONFIG_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"
cp "$SCRIPT_DIR/run.sh" "$INSTALL_ROOT/run.sh"
chmod 700 "$INSTALL_ROOT/run.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
  API_KEY="$(openssl rand -hex 32)"
  cat > "$CONFIG_FILE" <<EOF
XCODE_MCP_API_KEY=$API_KEY
XCODE_MCP_PORT=$PORT
EOF
  chmod 600 "$CONFIG_FILE"
else
  chmod 600 "$CONFIG_FILE"
  API_KEY="$(sed -n 's/^XCODE_MCP_API_KEY=//p' "$CONFIG_FILE" | head -n1)"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.nyc-design.xcodebuildmcp</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$INSTALL_ROOT/run.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/xcodebuildmcp.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/xcodebuildmcp.stderr.log</string>
</dict>
</plist>
EOF
chmod 600 "$PLIST"

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/com.nyc-design.xcodebuildmcp"

cat <<EOF
XcodeBuildMCP service installed.

Local MCP endpoint:
  http://127.0.0.1:$PORT/mcp

Coder MCP auth header:
  X-API-Key: $API_KEY

The proxy itself uses API-key authentication. Put the endpoint behind an encrypted/private transport (for example Tailscale Serve) before registering it with a remote Coder deployment.

Useful commands:
  launchctl print gui/$(id -u)/com.nyc-design.xcodebuildmcp
  tail -f "$LOG_DIR/xcodebuildmcp.stderr.log"
EOF
