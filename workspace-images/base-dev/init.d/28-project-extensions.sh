#!/usr/bin/env bash
# Install Tier 3 (per-project) extensions declared in the project tree:
#   <project>/.devcontainer/devcontainer.json -> .customizations.vscode.extensions
#   <project>/.vscode/extensions.json         -> .recommendations
#
# Both files are typically JSONC (line/block comments + trailing commas), so
# parsing goes through a small node helper (node 20 is installed in base-dev).
#
# Project location: envbuilder clones into /workspaces/<project_name>/. The
# project name is not reliably available as an env var inside the workspace
# agent, so this script enumerates every non-hidden subdir under /workspaces/
# and reads the two files if they exist. In practice there is one such dir.
#
# Targets: both per-editor extension dirs (code-server reads OpenVSX, vscode-web
# reads Marketplace). Per-project Marketplace-only extensions are intentionally
# out of scope; those should live in Tier 1 or Tier 2 (Copilot, Gemini) where
# they are managed centrally.
#
# Project manifests don't pin versions, so we use the same "don't downgrade,
# install if missing" semantics as 25-extensions-install.sh: if the editor
# already has any version of the id on disk (including UI-installed updates),
# this script is a no-op for that id.

set -euo pipefail

log() { printf '[project-extensions] %s\n' "$*"; }

WORKSPACES_ROOT="${WORKSPACES_ROOT:-/workspaces}"
CODE_SERVER_DIR="${CODE_SERVER_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/code-server}"
VSCODE_WEB_DIR="${VSCODE_WEB_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/vscode-web}"
CODE_SERVER="${CODE_SERVER_BIN:-/opt/code-server/bin/code-server}"
VSCODE_WEB="${VSCODE_WEB_BIN:-/opt/vscode-web/bin/code-server}"

if [ ! -d "$WORKSPACES_ROOT" ]; then
  log "no $WORKSPACES_ROOT; skipping"
  exit 0
fi

if ! command -v node > /dev/null 2>&1; then
  log "node not available; cannot parse jsonc manifests"
  exit 0
fi

mkdir -p "$CODE_SERVER_DIR" "$VSCODE_WEB_DIR"

# Node helper: strip JSONC comments + trailing commas, then emit one extension
# id per line for the relevant manifest type (devcontainer.json or
# extensions.json). Stdin: file path as $1.
extract_extensions() {
  local file="$1"
  [ -f "$file" ] || return 0
  FILE="$file" node <<'NODE'
const fs = require('fs');
const path = require('path');

const file = process.env.FILE;
let text;
try {
  text = fs.readFileSync(file, 'utf8');
} catch (e) {
  process.exit(0);
}

// Strip JSONC: block /* */ comments, // line comments, and trailing commas.
// Naive (doesn't honor `//` inside JSON strings); fine for these manifests.
text = text
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/^([^"\n]*?)\/\/.*$/gm, '$1')
  .replace(/,(\s*[}\]])/g, '$1');

let data;
try {
  data = JSON.parse(text);
} catch (e) {
  console.error(`[project-extensions] parse error in ${file}: ${e.message}`);
  process.exit(0);
}

const base = path.basename(file);
let ids = [];
if (base === 'devcontainer.json') {
  ids = data?.customizations?.vscode?.extensions ?? [];
} else if (base === 'extensions.json') {
  ids = data?.recommendations ?? [];
}

for (const id of ids) {
  if (typeof id === 'string' && id.trim()) {
    process.stdout.write(id.trim() + '\n');
  }
}
NODE
}

# True iff any directory named "<id-lowercase>-*" exists under $2.
has_any_version() {
  local id_lc; id_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  shopt -s nullglob
  local entries=("$2"/${id_lc}-*/)
  [ "${#entries[@]}" -gt 0 ]
}

install_one() {
  local bin="$1" dir="$2" ext="$3" label="$4" source="$5"
  [ -z "$ext" ] && return 0
  if [ ! -x "$bin" ]; then
    log "[$label] skip $ext (binary $bin not present)"
    return 0
  fi
  # Strip any @version on project specs — Tier 3 floats latest by design.
  ext="${ext%@*}"
  if has_any_version "$ext" "$dir"; then
    log "[$label] $ext already installed (from $source); leaving in place"
    return 0
  fi
  if "$bin" --extensions-dir="$dir" --install-extension "$ext" > /tmp/ext-install.log 2>&1; then
    log "[$label] ok $ext (from $source)"
  else
    rc=$?
    log "[$label] FAILED $ext (from $source, exit $rc)"
    sed 's/^/    /' /tmp/ext-install.log
  fi
}

shopt -s nullglob
found_any=0
for project in "$WORKSPACES_ROOT"/*/; do
  project="${project%/}"
  name="$(basename "$project")"
  case "$name" in
    .*) continue ;;
  esac

  for manifest in "$project/.devcontainer/devcontainer.json" "$project/.vscode/extensions.json"; do
    [ -f "$manifest" ] || continue
    found_any=1
    log "reading ${manifest#$WORKSPACES_ROOT/}"
    while IFS= read -r ext; do
      install_one "$CODE_SERVER" "$CODE_SERVER_DIR" "$ext" "code-server" "${manifest#$WORKSPACES_ROOT/}"
      install_one "$VSCODE_WEB"  "$VSCODE_WEB_DIR"  "$ext" "vscode-web"  "${manifest#$WORKSPACES_ROOT/}"
    done < <(extract_extensions "$manifest")
  done
done

if [ "$found_any" -eq 0 ]; then
  log "no project manifests found under $WORKSPACES_ROOT"
fi

log "done"
