#!/usr/bin/env bash
set -eu

log() { printf '[code-server-init] %s\n' "$*"; }

code_server_install_root() {
  if ! command -v code-server >/dev/null 2>&1; then
    return 1
  fi

  local bin real_bin
  bin="$(command -v code-server)"
  real_bin="$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")"
  cd "$(dirname "$real_bin")/.." && pwd -P
}

# --- Server-side GitHub auth for VS Code's GitHub authentication provider ---
# Keep GitHub auth out of code-server's core web bootstrap. Instead, patch only
# the built-in GitHub Authentication extension so its normal SecretStorage-backed
# session loader can fall back to the server-side token already supplied by the
# workspace runtime. The extension verifies the token with GitHub and stores the
# resulting sessions through its existing code path.
patch_code_server_github_auth_extension() {
  local install_root extension_js
  if ! install_root="$(code_server_install_root)"; then
    log "code-server binary not found; skipping GitHub auth extension patch"
    return 0
  fi

  extension_js="$install_root/lib/vscode/extensions/github-authentication/dist/extension.js"
  if [ ! -f "$extension_js" ]; then
    log "GitHub authentication extension not found at $extension_js; skipping patch"
    return 0
  fi

  EXTENSION_JS="$extension_js" node <<'NODE'
const fs = require('fs');

const file = process.env.EXTENSION_JS;
let source = fs.readFileSync(file, 'utf8');
const original = source;

const fallback = String.raw`async getToken(){try{let r=await this.context.secrets.get(this.serviceId);if(r&&r!=="[]")return this.Logger.trace("Token acquired from secret storage."),r;if(this.serviceId==="github.auth"){let t=typeof process<"u"&&process.env?(process.env.GITHUB_OAUTH_TOKEN||process.env.GITHUB_TOKEN||process.env.GITHUB_PAT||process.env.GH_TOKEN):void 0;if(t){this.Logger.info("Using GitHub auth token from environment.");let n=[["user:email"],["repo"],["repo","workflow"],["read:user"],["read:user","user:email","repo"],["read:user","user:email","repo","workflow"]].map((i,o)=>({id:"coder-env-github-"+o,scopes:i,accessToken:t}));return JSON.stringify(n)}}return r}catch(r){return this.Logger.error("Getting token failed: "+r),Promise.resolve(void 0)}}`;

if (source.includes(fallback)) {
  console.log('already patched');
  process.exit(0);
}

const originalGetToken = 'async getToken(){try{let r=await this.context.secrets.get(this.serviceId);return r&&r!=="[]"&&this.Logger.trace("Token acquired from secret storage."),r}catch(r){return this.Logger.error(`Getting token failed: ${r}`),Promise.resolve(void 0)}}';

if (!source.includes(originalGetToken)) {
  console.error(`Could not find expected GitHub authentication getToken() implementation in ${file}`);
  process.exit(1);
}

source = source.replace(originalGetToken, fallback);

if (!fs.existsSync(`${file}.env-token-patch.bak`)) {
  fs.copyFileSync(file, `${file}.env-token-patch.bak`);
}
fs.writeFileSync(file, source);
console.log('patched');
NODE
}

# --- Workbench bundle: trust GitHub auth for additional extensions ---
# The browser-side IProductService reads `trustedExtensionAuthAccess` from a
# bundled productConfiguration literal in the workbench bundles, not from
# product.json at runtime. Patching product.json alone has no effect on the
# grant-access dialog. We locate the bundled array via a regex on the property
# name (no fragile tail anchor on specific extension IDs), parse it as JSON,
# idempotently append our extra trusted IDs, and write it back. Surviving an
# upstream reorder/insertion in that array now only requires the property
# name and surrounding `[...]` literal to remain intact.
patch_code_server_workbench_bundle_auth_trust() {
  local install_root
  if ! install_root="$(code_server_install_root)"; then
    log "code-server binary not found; skipping workbench bundle auth trust patch"
    return 0
  fi

  local bundles=(
    "$install_root/lib/vscode/out/vs/code/browser/workbench/workbench.js"
    "$install_root/lib/vscode/out/vs/workbench/workbench.web.main.internal.js"
  )

  local extra_ids='github.vscode-github-actions eamodio.gitlens'

  for bundle in "${bundles[@]}"; do
    if [ ! -f "$bundle" ]; then
      log "workbench bundle not found, skipping: $bundle"
      continue
    fi

    BUNDLE_JS="$bundle" EXTRA_IDS="$extra_ids" node <<'NODE'
const fs = require('fs');

const file = process.env.BUNDLE_JS;
const extraIds = process.env.EXTRA_IDS.split(/\s+/).filter(Boolean);

let source = fs.readFileSync(file, 'utf8');

const re = /trustedExtensionAuthAccess:(\[[^\]]*\])/;
const m = source.match(re);
if (!m) {
  console.error(`Could not find trustedExtensionAuthAccess array literal in ${file}`);
  process.exit(1);
}

let arr;
try {
  arr = JSON.parse(m[1]);
} catch (e) {
  console.error(`Failed to parse trustedExtensionAuthAccess array in ${file}: ${e.message}`);
  process.exit(1);
}
if (!Array.isArray(arr)) {
  console.error(`trustedExtensionAuthAccess in ${file} is not an array`);
  process.exit(1);
}

const present = new Set(arr.map((s) => String(s).toLowerCase()));
let added = false;
for (const id of extraIds) {
  if (!present.has(id.toLowerCase())) {
    arr.push(id);
    added = true;
  }
}
if (!added) {
  console.log('already patched');
  process.exit(0);
}

const replacement = 'trustedExtensionAuthAccess:' + JSON.stringify(arr);
const patched = source.replace(re, replacement);

if (!fs.existsSync(`${file}.trusted-auth-patch.bak`)) {
  fs.copyFileSync(file, `${file}.trusted-auth-patch.bak`);
}
fs.writeFileSync(file, patched);
console.log('patched');
NODE
  done
}

patch_code_server_github_auth_extension || log "warning: failed to patch GitHub authentication extension"
patch_code_server_workbench_bundle_auth_trust || log "warning: failed to patch workbench bundle auth trust"
