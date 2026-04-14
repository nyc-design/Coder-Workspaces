#!/usr/bin/env bash
set -eu

log() { printf '[vscode-themes-init] %s\n' "$*"; }

THEMES_DIR="/usr/local/share/shared-assets/vscode-themes"
CS_EXT_DIR="$HOME/.local/share/code-server/extensions"
VSCODE_EXT_DIR="$HOME/.vscode-server/extensions"

install_into_vscode_server() {
  local vsix_path="$1"
  local tmp_dir manifest name publisher version ext_key target_dir

  tmp_dir="$(mktemp -d)"
  unzip -qq "$vsix_path" "extension/package.json" -d "$tmp_dir"
  manifest="${tmp_dir}/extension/package.json"

  if [ ! -f "$manifest" ]; then
    log "skipping $(basename "$vsix_path"): missing extension/package.json"
    rm -rf "$tmp_dir"
    return 0
  fi

  name="$(node -p "require(process.argv[1]).name" "$manifest")"
  publisher="$(node -p "require(process.argv[1]).publisher" "$manifest")"
  version="$(node -p "require(process.argv[1]).version" "$manifest")"
  ext_key="${publisher}.${name}"
  target_dir="${VSCODE_EXT_DIR}/${ext_key}-${version}"

  if [ -d "$target_dir" ]; then
    log "VS Code Web already has ${ext_key}@${version}"
    rm -rf "$tmp_dir"
    return 0
  fi

  log "installing ${ext_key}@${version} into VS Code Web extension dir"
  rm -rf "${VSCODE_EXT_DIR:?}/${ext_key}-"*
  unzip -qq "$vsix_path" -d "$tmp_dir"
  mv "${tmp_dir}/extension" "$target_dir"
  rm -rf "$tmp_dir"
}

if [ ! -d "$THEMES_DIR" ]; then
  log "no baked theme directory found at $THEMES_DIR"
  exit 0
fi

mkdir -p "$CS_EXT_DIR" "$VSCODE_EXT_DIR"

found_any=0
for vsix_path in "$THEMES_DIR"/*.vsix; do
  if [ ! -f "$vsix_path" ]; then
    continue
  fi
  found_any=1
  log "installing $(basename "$vsix_path") into code-server"
  code-server --install-extension "$vsix_path" --force >/tmp/code-server-theme-install.log 2>&1 \
    || { log "code-server install failed for $(basename "$vsix_path"); tailing log"; tail -n 50 /tmp/code-server-theme-install.log || true; exit 1; }
  install_into_vscode_server "$vsix_path"
done

if [ "$found_any" -eq 0 ]; then
  log "no .vsix files found under $THEMES_DIR"
fi
