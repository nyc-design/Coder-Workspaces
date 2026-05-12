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
# Targets: the shared OpenVSX dir (read by both editors). Per-project Marketplace-
# only extensions are intentionally out of scope; those should live in Tier 1
# or Tier 2 (Copilot, Gemini) where they are managed centrally.
#
# code-server / vscode-web --install-extension is idempotent, so duplicates with
# Tier 1 / Tier 2 are no-ops at install time.

set -euo pipefail

log() { printf '[project-extensions] %s\n' "$*"; }

WORKSPACES_ROOT="${WORKSPACES_ROOT:-/workspaces}"
SHARED_DIR="${SHARED_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/shared}"
CODE_SERVER="${CODE_SERVER_BIN:-/opt/code-server/bin/code-server}"

if [ ! -d "$WORKSPACES_ROOT" ]; then
  log "no $WORKSPACES_ROOT; skipping"
  exit 0
fi

if ! command -v node > /dev/null 2>&1; then
  log "node not available; cannot parse jsonc manifests"
  exit 0
fi

mkdir -p "$SHARED_DIR"

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
    rc=$?
    log "FAILED $ext (from $source, exit $rc)"
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
      install_one "$ext" "${manifest#$WORKSPACES_ROOT/}"
    done < <(extract_extensions "$manifest")
  done
done

if [ "$found_any" -eq 0 ]; then
  log "no project manifests found under $WORKSPACES_ROOT"
fi

log "done"
