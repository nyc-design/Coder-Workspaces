#!/usr/bin/env bash
# Offline regression tests: no package installation, credentials, or provider calls.
set -euo pipefail
installer="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/install-bailian.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/prefix/bin" "$tmp/home"
export TEST_LOG="$tmp/log" TEST_ARCH=x86_64 TEST_BAD_CHECKSUM=0
export NPM_CONFIG_PREFIX="$tmp/prefix" HOME="$tmp/home"
cat > "$tmp/bin/uname" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == -s ]]; then echo Linux; else echo "$TEST_ARCH"; fi
MOCK
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$TEST_LOG"
[[ "$*" == *'https://registry.npmjs.org/bailian-cli/-/bailian-cli-2.0.0.tgz'* ]]
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --output ]]; then touch "$2"; break; fi
  shift
done
MOCK
cat > "$tmp/bin/sha256sum" <<'MOCK'
#!/usr/bin/env bash
read -r checksum archive
[[ "$checksum" == d6b236ebb66a6ce4c48f064dd73814256732bbc84fcbca704d1c6d93a7a34912 ]]
[[ -f "$archive" ]]
printf 'checksum\n' >> "$TEST_LOG"
exit "$TEST_BAD_CHECKSUM"
MOCK
cat > "$tmp/bin/npm" <<'MOCK'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >> "$TEST_LOG"
[[ "$*" == *'--global --prefix '* ]]
[[ "$*" == *'--ignore-scripts --no-audit --no-fund'* ]]
MOCK
cat > "$tmp/prefix/bin/bl" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == --version ]]
printf 'version\n' >> "$TEST_LOG"
MOCK
chmod +x "$tmp/bin/"* "$tmp/prefix/bin/bl"
export PATH="$tmp/bin:$PATH"
for TEST_ARCH in x86_64 aarch64 arm64; do
  export TEST_ARCH
  : > "$TEST_LOG"
  bash "$installer"
  [[ $(wc -l < "$TEST_LOG") == 4 ]]
  [[ $(tail -1 "$TEST_LOG") == version ]]
done
TEST_BAD_CHECKSUM=1
export TEST_BAD_CHECKSUM
: > "$TEST_LOG"
if bash "$installer"; then echo 'Checksum mismatch accepted' >&2; exit 1; fi
! grep -q '^npm ' "$TEST_LOG"
TEST_ARCH=ppc64le
export TEST_ARCH
: > "$TEST_LOG"
if bash "$installer" 2>/dev/null; then echo 'Unsupported architecture accepted' >&2; exit 1; fi
[[ ! -s "$TEST_LOG" ]]
[[ ! -e "$HOME/.bailian" ]]
echo 'Bailian installer tests passed (three architecture aliases, checksum failure, unsupported architecture).'
