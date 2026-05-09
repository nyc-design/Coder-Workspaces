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

# VS Code prompts before letting extensions use an existing auth session unless
# the extension is trusted in product.json or has already been allowed in user
# application storage. Patch only product metadata so preinstalled GitHub tools
# can reuse the central GitHub auth provider without an extra allow prompt.
patch_code_server_trusted_github_extensions() {
  local install_root product_json
  if ! install_root="$(code_server_install_root)"; then
    log "code-server binary not found; skipping trusted GitHub extensions patch"
    return 0
  fi

  product_json="$install_root/lib/vscode/product.json"
  if [ ! -f "$product_json" ]; then
    log "product.json not found at $product_json; skipping trusted GitHub extensions patch"
    return 0
  fi

  PRODUCT_JSON="$product_json" node <<'NODE'
const fs = require('fs');

const file = process.env.PRODUCT_JSON;
const trustedIdsByProvider = {
  github: [
    'github.vscode-github-actions',
    'eamodio.gitlens',
  ],
};
const product = JSON.parse(fs.readFileSync(file, 'utf8'));
const original = JSON.stringify(product);

function addMissing(list, ids) {
  for (const id of ids) {
    const normalizedId = id.toLowerCase();
    if (!list.some((existing) => String(existing).toLowerCase() === normalizedId)) {
      list.push(id);
    }
  }
}

if (!product.trustedExtensionAuthAccess || Array.isArray(product.trustedExtensionAuthAccess)) {
  product.trustedExtensionAuthAccess = {
    github: Array.isArray(product.trustedExtensionAuthAccess)
      ? product.trustedExtensionAuthAccess
      : [],
  };
}

for (const [providerId, trustedIds] of Object.entries(trustedIdsByProvider)) {
  const providerTrusted = Array.isArray(product.trustedExtensionAuthAccess[providerId])
    ? product.trustedExtensionAuthAccess[providerId]
    : [];
  addMissing(providerTrusted, trustedIds);
  product.trustedExtensionAuthAccess[providerId] = providerTrusted;
}

if (JSON.stringify(product) === original) {
  console.log('already patched');
  process.exit(0);
}

if (!fs.existsSync(`${file}.trusted-auth-patch.bak`)) {
  fs.copyFileSync(file, `${file}.trusted-auth-patch.bak`);
}
fs.writeFileSync(file, `${JSON.stringify(product, null, 2)}\n`);
console.log('patched');
NODE
}

patch_code_server_github_auth_extension || log "warning: failed to patch GitHub authentication extension"
patch_code_server_trusted_github_extensions || log "warning: failed to patch code-server trusted GitHub extensions"
