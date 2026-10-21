#!/bin/zsh
set -euo pipefail

CONTROL_BIN="$HOME/.local/bin/coder-mac-control"
APP_DIR="$HOME/Applications/Coder Mac Controls"

[[ -x "$CONTROL_BIN" ]] || {
  echo "$CONTROL_BIN is not installed yet." >&2
  echo "Install XcodeBuildMCP or a GitHub Actions runner first." >&2
  exit 1
}

mkdir -p "$APP_DIR"

make_toggle_app() {
  local name="$1" target="$2" icon="$3"
  local source_file
  source_file="$(mktemp -t coder-mac-toggle).applescript"

  cat > "$source_file" <<EOF
use scripting additions

on run
  try
    set resultText to do shell script "${CONTROL_BIN} ${target} toggle"
    display notification resultText with title "Coder Mac" subtitle "${name}"
  on error errorMessage number errorNumber
    display dialog errorMessage with title "${name}" buttons {"OK"} default button "OK" with icon stop
  end try
end run
EOF

  rm -rf "$APP_DIR/$name.app"
  osacompile -o "$APP_DIR/$name.app" "$source_file"
  rm -f "$source_file"

  # Give the applet a stable display name; icon remains the standard Script
  # Editor applet icon so this stays entirely native and requires no bundled
  # binary/image assets.
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $name" "$APP_DIR/$name.app/Contents/Info.plist" >/dev/null 2>&1 || true
}

make_toggle_app "Toggle XcodeBuildMCP" "xcode" "hammer"
make_toggle_app "Toggle GitHub Runners" "github" "play"

cat <<EOF
Installed one-click controls:

  $APP_DIR/Toggle XcodeBuildMCP.app
  $APP_DIR/Toggle GitHub Runners.app

Drag both apps into your Dock. Each click toggles the corresponding service(s)
and posts a macOS notification with the resulting ON/OFF state.

You can also run the same controls from Terminal:
  $CONTROL_BIN xcode status
  $CONTROL_BIN github status
EOF
