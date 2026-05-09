#!/usr/bin/env bash
set -eu

log() { printf '[code-server-init] %s\n' "$*"; }

# --- Pre-configure code-server workspace trust ---
# Headless browser sessions use ephemeral profiles and trigger trust dialogs,
# which blocks extension activation. Disable workspace trust entirely so
# Pencil (and other extensions) activate without user interaction.
log "pre-configuring code-server workspace trust"
CS_SETTINGS_DIR="/home/coder/.local/share/code-server/User"
mkdir -p "$CS_SETTINGS_DIR"
CS_SETTINGS_FILE="$CS_SETTINGS_DIR/settings.json"
if [ ! -f "$CS_SETTINGS_FILE" ]; then
  echo '{}' > "$CS_SETTINGS_FILE"
fi
# Merge workspace trust setting into existing settings.json
node -e "
  const fs = require('fs');
  const f = '$CS_SETTINGS_FILE';
  const s = JSON.parse(fs.readFileSync(f, 'utf8'));
  s['security.workspace.trust.enabled'] = false;
  fs.writeFileSync(f, JSON.stringify(s, null, 2) + '\n');
"

# --- Server-side GitHub auth for code-server web clients ---
# The upstream VS Code web server can inject an initial GitHub authentication
# session into browser clients from --github-auth, but code-server's released
# bundle currently keeps that behind VS Code's development-build guard:
#   !environmentService.isBuilt && args["github-auth"]
# The Coder Terraform code-server module starts the app for us, so patch the
# installed server bundle at workspace startup instead of trying to replace the
# module's launcher. GITHUB_TOKEN/GITHUB_PAT are still supplied by Terraform.
#
# This enables the central VS Code GitHub auth provider for new browser devices,
# which is what the GitHub Actions extension and Accounts panel use. The GitHub
# Pull Requests extension additionally supports GITHUB_OAUTH_TOKEN directly.
patch_code_server_github_auth() {
  if ! command -v code-server >/dev/null 2>&1; then
    log "code-server binary not found; skipping GitHub auth patch"
    return 0
  fi

  local bin real_bin install_root server_main
  bin="$(command -v code-server)"
  real_bin="$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")"
  install_root="$(cd "$(dirname "$real_bin")/.." && pwd -P)"
  server_main="$install_root/lib/vscode/out/server-main.js"

  if [ ! -f "$server_main" ]; then
    log "server-main.js not found at $server_main; skipping GitHub auth patch"
    return 0
  fi

  SERVER_MAIN="$server_main" node <<'NODE'
const fs = require('fs');

const file = process.env.SERVER_MAIN;
let source = fs.readFileSync(file, 'utf8');
const original = source;

const guardPattern = /!this\._environmentService\.isBuilt&&this\._environmentService\.args\["github-auth"\]/g;
const guardReplacement = 'this._environmentService.args["github-auth"]';
if (guardPattern.test(source)) {
  source = source.replace(guardPattern, guardReplacement);
} else if (!source.includes(guardReplacement)) {
  console.error(`Could not find expected code-server GitHub auth guard in ${file}`);
  process.exit(1);
}

const defaultScopes = 'scopes:[["user:email"],["repo"]]';
const expandedScopes = 'scopes:[["user:email"],["repo"],["repo","workflow"],["read:user","user:email","repo"],["read:user","user:email","repo","workflow"]]';
if (source.includes(defaultScopes)) {
  source = source.replace(defaultScopes, expandedScopes);
} else if (!source.includes(expandedScopes)) {
  console.error(`Could not find expected code-server GitHub auth scopes in ${file}`);
  process.exit(1);
}

if (source === original) {
  console.log('already patched');
  process.exit(0);
}

if (!fs.existsSync(`${file}.github-auth-patch.bak`)) {
  fs.copyFileSync(file, `${file}.github-auth-patch.bak`);
}
fs.writeFileSync(file, source);
console.log('patched');
NODE
}



# VS Code prompts before letting extensions use an existing auth session unless
# the extension is trusted in product.json or has already been allowed in user
# application storage. Patch product.json so preinstalled GitHub extensions can
# reuse the central GitHub auth session on new devices without an extra click.
patch_code_server_trusted_github_extensions() {
  if ! command -v code-server >/dev/null 2>&1; then
    log "code-server binary not found; skipping trusted GitHub extensions patch"
    return 0
  fi

  local bin real_bin install_root product_json
  bin="$(command -v code-server)"
  real_bin="$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")"
  install_root="$(cd "$(dirname "$real_bin")/.." && pwd -P)"
  product_json="$install_root/lib/vscode/product.json"

  if [ ! -f "$product_json" ]; then
    log "product.json not found at $product_json; skipping trusted GitHub extensions patch"
    return 0
  fi

  PRODUCT_JSON="$product_json" node <<'NODE'
const fs = require('fs');

const file = process.env.PRODUCT_JSON;
const trustedIds = [
  'github.vscode-github-actions',
  'eamodio.gitlens',
];
const product = JSON.parse(fs.readFileSync(file, 'utf8'));
const original = JSON.stringify(product);

function addMissing(list) {
  let changed = false;
  for (const id of trustedIds) {
    if (!list.includes(id)) {
      list.push(id);
      changed = true;
    }
  }
  return changed;
}

if (Array.isArray(product.trustedExtensionAuthAccess)) {
  addMissing(product.trustedExtensionAuthAccess);
} else if (product.trustedExtensionAuthAccess && typeof product.trustedExtensionAuthAccess === 'object') {
  const githubTrusted = Array.isArray(product.trustedExtensionAuthAccess.github)
    ? product.trustedExtensionAuthAccess.github
    : [];
  addMissing(githubTrusted);
  product.trustedExtensionAuthAccess.github = githubTrusted;
} else {
  product.trustedExtensionAuthAccess = [...trustedIds];
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

patch_code_server_github_auth || log "warning: failed to patch code-server GitHub auth injection"
patch_code_server_trusted_github_extensions || log "warning: failed to patch code-server trusted GitHub extensions"
