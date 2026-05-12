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

patch_code_server_pencil_session_fallback || log "warning: failed to patch Pencil session fallback"
patch_code_server_pencil_disable_first_run_open || log "warning: failed to patch Pencil first-run welcome"
