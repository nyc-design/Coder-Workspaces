#!/usr/bin/env bash
# Apply Tier 3 (per-project) VS Code customizations declared in the project tree:
#   <project>/.devcontainer/devcontainer.json -> .customizations.vscode.{extensions,settings}
#   <project>/.vscode/extensions.json         -> .recommendations
#
# Devcontainer settings are merged over the machine defaults written by
# 26-settings-apply.sh. User settings remain untouched.

set -euo pipefail

log() { printf '[project-customizations] %s\n' "$*"; }

WORKSPACES_ROOT="${WORKSPACES_ROOT:-/workspaces}"
SHARED_DIR="${SHARED_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/shared}"
CODE_SERVER="${CODE_SERVER_BIN:-/opt/code-server/bin/code-server}"
MACHINE_FILE_CS="${CODE_SERVER_MACHINE_SETTINGS:-$HOME/.local/share/code-server/Machine/settings.json}"
MACHINE_FILE_WEB="${VSCODE_WEB_MACHINE_SETTINGS:-$HOME/.vscode-server/data/Machine/settings.json}"

if [ ! -d "$WORKSPACES_ROOT" ]; then
  log "no $WORKSPACES_ROOT; skipping"
  exit 0
fi

if ! command -v node > /dev/null 2>&1; then
  log "node not available; cannot parse JSONC manifests"
  exit 0
fi

mkdir -p "$SHARED_DIR"

# Parse JSONC without corrupting comment-like text inside strings. MODE is
# "extensions" or "settings"; FILE is the manifest path.
extract_manifest() {
  local mode="$1" file="$2"
  [ -f "$file" ] || return 0
  MODE="$mode" FILE="$file" node <<'NODE'
const fs = require('fs');
const path = require('path');

const file = process.env.FILE;
const mode = process.env.MODE;

function stripJsonc(text) {
  let withoutComments = '';
  let inString = false;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;

  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];
    if (lineComment) {
      if (ch === '\n') { lineComment = false; withoutComments += ch; }
      continue;
    }
    if (blockComment) {
      if (ch === '*' && next === '/') { blockComment = false; i += 1; }
      else if (ch === '\n') withoutComments += ch;
      continue;
    }
    if (inString) {
      withoutComments += ch;
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') { inString = true; withoutComments += ch; continue; }
    if (ch === '/' && next === '/') { lineComment = true; i += 1; continue; }
    if (ch === '/' && next === '*') { blockComment = true; i += 1; continue; }
    withoutComments += ch;
  }

  let withoutTrailingCommas = '';
  inString = false;
  escaped = false;
  for (let i = 0; i < withoutComments.length; i += 1) {
    const ch = withoutComments[i];
    if (inString) {
      withoutTrailingCommas += ch;
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') { inString = true; withoutTrailingCommas += ch; continue; }
    if (ch === ',') {
      let next = i + 1;
      while (/\s/.test(withoutComments[next] ?? '')) next += 1;
      if (withoutComments[next] === '}' || withoutComments[next] === ']') continue;
    }
    withoutTrailingCommas += ch;
  }
  return withoutTrailingCommas;
}

let data;
try {
  data = JSON.parse(stripJsonc(fs.readFileSync(file, 'utf8')));
} catch (error) {
  console.error(`[project-customizations] parse error in ${file}: ${error.message}`);
  process.exit(0);
}

if (mode === 'settings') {
  const settings = data?.customizations?.vscode?.settings;
  if (settings && typeof settings === 'object' && !Array.isArray(settings)) {
    process.stdout.write(JSON.stringify(settings));
  }
  process.exit(0);
}

let ids = [];
if (path.basename(file) === 'devcontainer.json') {
  ids = data?.customizations?.vscode?.extensions ?? [];
} else if (path.basename(file) === 'extensions.json') {
  ids = data?.recommendations ?? [];
}
for (const id of ids) {
  if (typeof id === 'string' && id.trim()) process.stdout.write(`${id.trim()}\n`);
}
NODE
}

install_one() {
  local ext="$1" source="$2"
  [ -z "$ext" ] && return 0
  if [ ! -x "$CODE_SERVER" ]; then
    log "skip $ext (binary $CODE_SERVER not present)"
    return 0
  fi
  if "$CODE_SERVER" --extensions-dir="$SHARED_DIR" --install-extension "$ext" > /tmp/ext-install.log 2>&1; then
    log "ok $ext (from $source)"
  else
    local rc=$?
    log "FAILED $ext (from $source, exit $rc)"
    sed 's/^/    /' /tmp/ext-install.log
  fi
}

settings_dir="$(mktemp -d)"
trap 'rm -rf "$settings_dir"' EXIT
settings_count=0
found_any=0

shopt -s nullglob
for project in "$WORKSPACES_ROOT"/*/; do
  project="${project%/}"
  name="$(basename "$project")"
  case "$name" in .*) continue ;; esac

  devcontainer="$project/.devcontainer/devcontainer.json"
  recommendations="$project/.vscode/extensions.json"

  if [ -f "$devcontainer" ]; then
    found_any=1
    relative="${devcontainer#$WORKSPACES_ROOT/}"
    log "reading $relative"
    while IFS= read -r ext; do install_one "$ext" "$relative"; done < <(extract_manifest extensions "$devcontainer")

    settings="$(extract_manifest settings "$devcontainer")"
    if [ -n "$settings" ]; then
      printf '%s\n' "$settings" > "$settings_dir/$(printf '%06d' "$settings_count").json"
      settings_count=$((settings_count + 1))
      log "queued VS Code settings from $relative"
    fi
  fi

  if [ -f "$recommendations" ]; then
    found_any=1
    relative="${recommendations#$WORKSPACES_ROOT/}"
    log "reading $relative"
    while IFS= read -r ext; do install_one "$ext" "$relative"; done < <(extract_manifest extensions "$recommendations")
  fi
done

if [ "$settings_count" -gt 0 ]; then
  if ! command -v jq > /dev/null 2>&1; then
    log "jq not available; cannot merge project settings" >&2
  else
    settings_files=("$settings_dir"/*.json)
    for target in "$MACHINE_FILE_CS" "$MACHINE_FILE_WEB"; do
      mkdir -p "$(dirname "$target")"
      base="$settings_dir/base.json"
      if [ -f "$target" ] && jq empty "$target" > /dev/null 2>&1; then
        cp "$target" "$base"
      else
        printf '{}\n' > "$base"
      fi
      tmp="${target}.tmp.$$"
      jq -s 'reduce .[] as $settings ({}; . * $settings)' "$base" "${settings_files[@]}" > "$tmp"
      mv "$tmp" "$target"
      log "applied project settings to $target"
    done
  fi
fi

if [ "$found_any" -eq 0 ]; then
  log "no project manifests found under $WORKSPACES_ROOT"
fi
log "done"
