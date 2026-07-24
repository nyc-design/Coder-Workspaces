#!/usr/bin/env bash
set -eu

log() { printf '[code-server-init] %s\n' "$*"; }

# --- Pencil extension session fallback to CLI session file ---
# code-server stores extension globalState in browser IndexedDB rather than on
# disk, so the Pencil extension's session is per-browser. Pencil's CLI keeps a
# server-side session at ~/.pencil/session-cli.json with the same shape the
# extension's getSession() returns. Patch the extension's getSession() so it
# falls back to that file only when both globalState entries are empty. All
# other extension paths (setSession, signOut, lastOnlineAt, etc.) are
# unaffected. "pencil logout" remains the way to globally sign out.
#
# Lives in 27- (after 25-extensions-install.sh) because it patches the
# extension on disk and therefore requires the extension to be installed first.
patch_code_server_pencil_session_fallback() {
  local extension_dir bundle_js
  extension_dir="$(ls -1d /home/coder/.vscode-extensions/shared/highagency.pencildev-*-universal 2>/dev/null | sort | tail -1 || true)"
  if [ -z "$extension_dir" ] || [ ! -d "$extension_dir" ]; then
    log "Pencil extension not installed; skipping session fallback patch"
    return 0
  fi

  bundle_js="$(ls -1 "$extension_dir"/out/main-*.js 2>/dev/null | grep -v '\.map$' | head -1 || true)"
  if [ -z "$bundle_js" ] || [ ! -f "$bundle_js" ]; then
    log "Pencil extension main bundle not found under $extension_dir/out; skipping patch"
    return 0
  fi

  BUNDLE_JS="$bundle_js" node <<'NODE'
const fs = require('fs');

const file = process.env.BUNDLE_JS;
let source = fs.readFileSync(file, 'utf8');

const originalGetSession = 'getSession(){const e=this.context.globalState.get(this.sessionKey);if(e!=null&&e.email&&(e!=null&&e.token))return{email:e.email,token:e.token};const r=this.context.globalState.get(this.legacySessionKey);if(r!=null&&r.email&&(r!=null&&r.licenseToken))return{email:r.email,token:r.licenseToken}}';

const patchedGetSession = 'getSession(){const e=this.context.globalState.get(this.sessionKey);if(e!=null&&e.email&&(e!=null&&e.token))return{email:e.email,token:e.token};const r=this.context.globalState.get(this.legacySessionKey);if(r!=null&&r.email&&(r!=null&&r.licenseToken))return{email:r.email,token:r.licenseToken};try{const _p=require("path"),_o=require("os"),_f=require("fs");const _s=JSON.parse(_f.readFileSync(_p.join(_o.homedir(),".pencil","session-cli.json"),"utf8"));if(_s&&_s.email&&_s.token)return{email:_s.email,token:_s.token}}catch{}}';

if (source.includes(patchedGetSession)) {
  console.log('already patched');
  process.exit(0);
}

if (!source.includes(originalGetSession)) {
  console.error(`Could not find expected Pencil getSession() implementation in ${file}`);
  process.exit(1);
}

source = source.replace(originalGetSession, patchedGetSession);

if (!fs.existsSync(`${file}.cli-session-fallback.bak`)) {
  fs.copyFileSync(file, `${file}.cli-session-fallback.bak`);
}
fs.writeFileSync(file, source);
console.log('patched');
NODE
}

# --- Pencil first-run welcome auto-open disable ---
# Pencil's activate() checks globalState `firstRunDone` and, when unset, focuses
# the Pencil sidebar and opens the bundled welcome.pen. code-server stores
# extension globalState in browser IndexedDB, so every fresh browser/PWA
# session counts as a first run, causing welcome.pen to open on every load.
# Short-circuit the check so the auto-open never fires; the manual command
# `pencil.openWelcomeDocument` and the regular `.pen` editor are unaffected.
patch_code_server_pencil_disable_first_run_open() {
  local extension_dir bundle_js
  extension_dir="$(ls -1d /home/coder/.vscode-extensions/shared/highagency.pencildev-*-universal 2>/dev/null | sort | tail -1 || true)"
  if [ -z "$extension_dir" ] || [ ! -d "$extension_dir" ]; then
    log "Pencil extension not installed; skipping first-run open patch"
    return 0
  fi

  bundle_js="$(ls -1 "$extension_dir"/out/main-*.js 2>/dev/null | grep -v '\.map$' | head -1 || true)"
  if [ -z "$bundle_js" ] || [ ! -f "$bundle_js" ]; then
    log "Pencil extension main bundle not found under $extension_dir/out; skipping first-run open patch"
    return 0
  fi

  BUNDLE_JS="$bundle_js" node <<'NODE'
const fs = require('fs');

const file = process.env.BUNDLE_JS;
let source = fs.readFileSync(file, 'utf8');

const original = 'if(!t.globalState.get("firstRunDone"))if(we.window.state.focused)';
const patched  = 'if(!1)if(we.window.state.focused)';

if (source.includes(patched) && !source.includes(original)) {
  console.log('already patched');
  process.exit(0);
}

if (!source.includes(original)) {
  console.error(`Could not find expected Pencil first-run check in ${file}`);
  process.exit(1);
}

source = source.replace(original, patched);

if (!fs.existsSync(`${file}.first-run-disable.bak`)) {
  fs.copyFileSync(file, `${file}.first-run-disable.bak`);
}
fs.writeFileSync(file, source);
console.log('patched');
NODE
}

# --- Continue extension: neutralize programmatic clipboard reads ---
# Continue reads the browser clipboard from two code paths that fire without a
# user gesture:
#   1. Autocomplete's "clipboard snippet" (getClipboardSnippets ->
#      IDE.getClipboardContent), pulled on essentially every keystroke.
#   2. IDE.getTerminalContents(), which copies the terminal selection via the
#      clipboard when terminal context is gathered.
# Both resolve to vscode.env.clipboard.readText(), which in code-server becomes
# navigator.clipboard.readText() in the browser. Safari (and any browser without
# a fresh user gesture) rejects that call, so code-server surfaces "Unable to
# read from the browser's clipboard" -- on autocomplete, once per keystroke.
#
# There is no Continue config flag to disable these reads, so we rewrite the
# bundled extension. Rather than match a specific (and frequently changing)
# minified method signature, we neutralize the clipboard read at the API-call
# level: every `<alias>.env.clipboard.readText()` is replaced with an inert
# expression that resolves to "". This is stable across Continue versions and
# per-arch bundles. Clipboard WRITES and all editor copy/paste (which run inside
# a real keydown gesture through separate code paths) are left untouched.
patch_code_server_continue_clipboard() {
  local extension_dir
  # Continue ships a per-target VSIX (linux-x64, darwin-arm64, etc.) plus a
  # platform-independent fallback. Take the most recent matching dir.
  extension_dir="$(ls -1d /home/coder/.vscode-extensions/shared/Continue.continue-*/ /home/coder/.vscode-extensions/shared/continue.continue-*/ 2>/dev/null | sort | tail -1 || true)"
  if [ -z "$extension_dir" ] || [ ! -d "$extension_dir" ]; then
    log "Continue extension not installed; skipping clipboard patch"
    return 0
  fi
  extension_dir="${extension_dir%/}"

  # Continue's VS Code extension entry point varies by version: older builds
  # bundle to dist/extension.js, newer builds (>=1.3.x) bundle to
  # out/extension.js. Probe both.
  local bundle_js=""
  for candidate in "$extension_dir/out/extension.js" "$extension_dir/dist/extension.js"; do
    if [ -f "$candidate" ]; then
      bundle_js="$candidate"
      break
    fi
  done
  if [ -z "$bundle_js" ]; then
    log "Continue extension bundle not found under $extension_dir (looked for out/extension.js and dist/extension.js); skipping clipboard patch"
    return 0
  fi

  BUNDLE_JS="$bundle_js" node <<'NODE'
const fs = require('fs');

const file = process.env.BUNDLE_JS;
let source = fs.readFileSync(file, 'utf8');

// Marker string that survives the patch so re-runs are no-ops.
const marker = '/*coder-clipboard-stub*/';
if (source.includes(marker)) {
  console.log('already patched');
  process.exit(0);
}

// Neutralize every programmatic clipboard read. The module alias for the
// `vscode` import is minified per build (e.g. `vscode34`), so match it loosely.
// Each `<alias>.env.clipboard.readText()` becomes a marked async IIFE that
// resolves to "" without touching the browser clipboard. Awaiting it keeps the
// surrounding `await` valid, and the empty string is the same value the reads
// would yield when the clipboard is empty -- so callers degrade gracefully
// (autocomplete drops the clipboard snippet; getTerminalContents returns "").
const re = /([A-Za-z_$][\w$]*)\.env\.clipboard\.readText\(\)/g;
const matches = source.match(re);
if (!matches) {
  console.error(`No vscode clipboard.readText() calls found in ${file}; skipping`);
  process.exit(1);
}

source = source.replace(re, `(async()=>${marker}"")()`);

if (!fs.existsSync(`${file}.clipboard-stub.bak`)) {
  fs.copyFileSync(file, `${file}.clipboard-stub.bak`);
}
fs.writeFileSync(file, source);
console.log(`patched ${matches.length} clipboard.readText() call(s)`);
NODE
}

# Each patch logs its own status. We deliberately do NOT swallow non-zero exits
# with `|| log warning` here — silent failure is what caused the Continue
# clipboard patch to regress against Continue 1.3.x (dist/ -> out/ bundle move).
# If a patch's preconditions aren't met it should `return 0` itself; a non-zero
# exit means an unexpected bundle shape that we want surfaced in init logs.
patch_code_server_pencil_session_fallback
patch_code_server_pencil_disable_first_run_open
patch_code_server_continue_clipboard
