#!/usr/bin/env bash
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly helper="$repo_root/workspace-images/base-dev/scripts/continue-patch"
readonly fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

extension_dir="$fixture_root/continue.continue-2.1.0-linux-x64"
mkdir -p "$extension_dir/out"
cat > "$extension_dir/package.json" <<'JSON'
{"version":"2.1.0","main":"./out/extension.js"}
JSON
cat > "$extension_dir/out/extension.js" <<'JS'
const vscode34 = { env: { clipboard: { readText: async () => "secret", writeText: async () => {} } } };
class IdeUtils {
  async getTerminalContents(commands = -1) {
    const old = await vscode34.env.clipboard.readText();
    const value = (await vscode34.env.clipboard.readText()).trim();
    await vscode34.env.clipboard.writeText(old);
    return value;
  }
}
class VsCodeIde {
  async getClipboardContent() {
    return { text: await vscode34.env.clipboard.readText(), copiedAt: new Date().toISOString() };
  }
  async getTerminalContents() {
    return await this.ideUtils.getTerminalContents(1);
  }
}
async function otherProgrammaticRead() {
  return await vscode34.env.clipboard.readText();
}
JS

run_patch() {
  CONTINUE_EXTENSION_ROOT="$fixture_root" "$helper"
}

first_output="$(run_patch)"
grep -q 'patched 1 clipboard method(s), 2 terminal method(s), and 1 remaining direct clipboard read(s)' <<<"$first_output"
grep -q 'Reload the editor window' <<<"$first_output"
node --check "$extension_dir/out/extension.js"
! grep -q 'env.clipboard.readText()' "$extension_dir/out/extension.js"
grep -q '/\*coder-continue-browser-patch:v2\*/' "$extension_dir/out/extension.js"
test -f "$extension_dir/out/extension.js.coder-continue-original.bak"

first_hash="$(sha256sum "$extension_dir/out/extension.js" | cut -d' ' -f1)"
second_output="$(run_patch)"
second_hash="$(sha256sum "$extension_dir/out/extension.js" | cut -d' ' -f1)"
test "$first_hash" = "$second_hash"
grep -q 'already patched' <<<"$second_output"

# An old partial marker is not accepted as proof: reruns must evaluate the
# postconditions and upgrade the bundle to the current versioned marker.
perl -0pi -e 's|/\*coder-continue-browser-patch:v2\*/return\{text:"",copiedAt:new Date\(\)\.toISOString\(\)\}|/\*coder-clipboard-stub\*/return{text:"",copiedAt:new Date().toISOString()}|' "$extension_dir/out/extension.js"
perl -0pi -e 's|async otherProgrammaticRead\(\) \{\n  return await \(Promise\.resolve\(/\*coder-continue-browser-patch:v2\*/""\)\);\n\}|async otherProgrammaticRead() { return await vscode34.env.clipboard.readText(); }|' "$extension_dir/out/extension.js"
upgrade_output="$(run_patch)"
grep -q '^patched ' <<<"$upgrade_output"
! grep -q 'coder-clipboard-stub' "$extension_dir/out/extension.js"
! grep -q 'env.clipboard.readText()' "$extension_dir/out/extension.js"
node --check "$extension_dir/out/extension.js"

printf 'Continue patch tests passed.\n'
