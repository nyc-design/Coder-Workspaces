#!/usr/bin/env bash
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly script="$repo_root/workspace-images/base-dev/init.d/28-project-customizations.sh"
readonly fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

workspaces="$fixture_root/workspaces"
project="$workspaces/example"
shared="$fixture_root/extensions"
cs_settings="$fixture_root/code-server/Machine/settings.json"
web_settings="$fixture_root/vscode-web/Machine/settings.json"
installer="$fixture_root/bin/code-server"
install_log="$fixture_root/install.log"
mkdir -p "$project/.devcontainer" "$project/.vscode" "$(dirname "$cs_settings")" "$(dirname "$web_settings")" "$(dirname "$installer")"

cat > "$project/.devcontainer/devcontainer.json" <<'JSONC'
{
  // Project settings must layer over image defaults.
  "customizations": {
    "vscode": {
      "extensions": ["publisher.one", "publisher.two",],
      "settings": {
        "python.defaultInterpreterPath": "/usr/local/bin/python",
        "editor": { "nested": { "project": true } },
        "url": "https://example.test/path//literal",
        "pattern": "comma,} remains in a string",
      },
    },
  },
}
JSONC
cat > "$project/.vscode/extensions.json" <<'JSONC'
{"recommendations": ["publisher.three",]}
JSONC
cat > "$cs_settings" <<'JSON'
{"base":true,"editor":{"nested":{"base":true},"fontSize":14}}
JSON
cp "$cs_settings" "$web_settings"
cat > "$installer" <<'EOF_INSTALLER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$INSTALL_LOG"
EOF_INSTALLER
chmod +x "$installer"

run_script() {
  WORKSPACES_ROOT="$workspaces" \
  SHARED_EXTENSIONS_DIR="$shared" \
  CODE_SERVER_BIN="$installer" \
  CODE_SERVER_MACHINE_SETTINGS="$cs_settings" \
  VSCODE_WEB_MACHINE_SETTINGS="$web_settings" \
  INSTALL_LOG="$install_log" \
  "$script"
}

output="$(run_script)"
grep -q 'queued VS Code settings' <<<"$output"
grep -q 'applied project settings' <<<"$output"
[ "$(wc -l < "$install_log")" -eq 3 ]
grep -q -- '--install-extension publisher.one' "$install_log"
grep -q -- '--install-extension publisher.two' "$install_log"
grep -q -- '--install-extension publisher.three' "$install_log"

for settings in "$cs_settings" "$web_settings"; do
  jq -e '
    .base == true and
    .editor.fontSize == 14 and
    .editor.nested.base == true and
    .editor.nested.project == true and
    .["python.defaultInterpreterPath"] == "/usr/local/bin/python" and
    .url == "https://example.test/path//literal" and
    .pattern == "comma,} remains in a string"
  ' "$settings" > /dev/null
done

# Invalid JSONC degrades safely and must not erase existing machine settings.
cp "$cs_settings" "$fixture_root/before.json"
printf '{ invalid' > "$project/.devcontainer/devcontainer.json"
invalid_output="$(run_script 2>&1)"
grep -q 'parse error' <<<"$invalid_output"
cmp -s "$fixture_root/before.json" "$cs_settings"

# Missing project manifests are a no-op.
rm -f "$project/.devcontainer/devcontainer.json" "$project/.vscode/extensions.json"
missing_output="$(run_script)"
grep -q 'no project manifests found' <<<"$missing_output"

printf 'project customization tests passed\n'
