#!/bin/zsh
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CONFIG_FILE="${XCODEBUILDMCP_SERVICE_ENV:-$HOME/.config/coder-mac/xcodebuildmcp.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "missing config: $CONFIG_FILE" >&2
  exit 1
fi

set -a
source "$CONFIG_FILE"
set +a

: "${XCODE_MCP_API_KEY:?XCODE_MCP_API_KEY must be set in $CONFIG_FILE}"
XCODE_MCP_PORT="${XCODE_MCP_PORT:-8765}"

command -v xcodebuildmcp >/dev/null || {
  echo "xcodebuildmcp not found in PATH" >&2
  exit 1
}
command -v mcp-proxy >/dev/null || {
  echo "mcp-proxy not found in PATH" >&2
  exit 1
}

exec mcp-proxy \
  --server stream \
  --port "$XCODE_MCP_PORT" \
  --apiKey "$XCODE_MCP_API_KEY" \
  -- \
  xcodebuildmcp mcp
