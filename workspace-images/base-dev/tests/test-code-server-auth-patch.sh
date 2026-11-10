#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_SCRIPT="$root/init.d/06-code-server-patches.sh" node <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const source = fs.readFileSync(process.env.PATCH_SCRIPT, 'utf8');
const patch = source.match(/EXTENSION_JS="\$extension_js" node <<'NODE'\n([\s\S]*?)\nNODE/)[1];
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'github-auth-patch-'));
try {
  for (const variable of ['r', 'e', 'token', '$t']) {
    const file = path.join(dir, variable + '.js');
    const original = 'async getToken(){try{let X=await this.context.secrets.get(this.serviceId);return X&&X!=="[]"&&this.Logger.trace("Token acquired from secret storage."),X}catch(X){return this.Logger.error(`Getting token failed: ${X}`),Promise.resolve(void 0)}}'.replaceAll('X', variable);
    fs.writeFileSync(file, original);
    const env = {...process.env, EXTENSION_JS: file};
    assert.equal(spawnSync(process.execPath, ['-e', patch], {env}).status, 0);
    const changed = fs.readFileSync(file, 'utf8');
    assert(changed.includes('coder-env-github-'));
    assert.equal(fs.readFileSync(file + '.env-token-patch.bak', 'utf8'), original);
    assert.equal(spawnSync(process.execPath, ['-e', patch], {env}).status, 0);
    assert.equal(fs.readFileSync(file, 'utf8'), changed);
    for (const invalid of [original + original, original.replace('this.serviceId', 'otherService')]) {
      fs.writeFileSync(file, invalid);
      assert.notEqual(spawnSync(process.execPath, ['-e', patch], {env}).status, 0);
      assert.equal(fs.readFileSync(file, 'utf8'), invalid);
    }
  }
  console.log('GitHub auth patch: renamed locals, idempotence, backup and fail-closed checks passed');
} finally {
  fs.rmSync(dir, {recursive: true, force: true});
}
NODE
