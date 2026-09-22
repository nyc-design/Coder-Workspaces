#!/usr/bin/env bash
# Offline contract tests; fixture checksums are mocked only for successful installs.
set -euo pipefail
readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly installer="$repo_root/workspace-images/base-dev/scripts/install-codexbar.sh"
readonly fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
export fixture_root
export REAL_SHA256SUM="$(command -v sha256sum)"
mkdir -p "$fixture_root/mock-bin" "$fixture_root/release/CodexBar_CodexBarCore.bundle" "$fixture_root/tmp"
cat > "$fixture_root/release/CodexBarCLI" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root="$(dirname "$(readlink -f "$0")")"
test "$(cat "$root/VERSION")" = 0.64.0
test "$(cat "$root/CodexBar_CodexBarCore.bundle/provider.js")" = resource
printf 'CodexBar 0.64.0\n'
SH
chmod +x "$fixture_root/release/CodexBarCLI"
ln -s CodexBarCLI "$fixture_root/release/codexbar"
printf '0.64.0\n' > "$fixture_root/release/VERSION"
printf 'resource\n' > "$fixture_root/release/CodexBar_CodexBarCore.bundle/provider.js"
tar -czf "$fixture_root/release.tar.gz" -C "$fixture_root/release" .
cat > "$fixture_root/mock-bin/dpkg" <<'SH'
#!/usr/bin/env bash
[[ "$*" = --print-architecture ]]
printf '%s\n' "$TEST_ARCH"
SH
cat > "$fixture_root/mock-bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$fixture_root/downloads"
[[ "$*" = *"https://github.com/steipete/CodexBar/releases/download/v0.64.0/CodexBarCLI-v0.64.0-linux-musl-${TEST_PLATFORM}.tar.gz" ]]
while [[ "$1" != -o ]]; do shift; done
cp "$fixture_root/release.tar.gz" "$2"
SH
cat > "$fixture_root/mock-bin/sha256sum" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${TEST_REAL_HASH:-0}" = 1 ]]; then exec "$REAL_SHA256SUM" "$@"; fi
[[ "$*" = '-c -' ]]
read -r hash path
[[ "$hash" = "$TEST_HASH" ]]
[[ -f "$path" ]]
SH
chmod +x "$fixture_root/mock-bin/"*
export PATH="$fixture_root/mock-bin:$PATH"
export TMPDIR="$fixture_root/tmp"

for TEST_ARCH in amd64 arm64; do
    export TEST_ARCH
    case "$TEST_ARCH" in
        amd64) export TEST_PLATFORM=x86_64 TEST_HASH=5af5fe878ab2f15617acd4db04a84784d63cd96efae9150699aa265910bc4f90 ;;
        arm64) export TEST_PLATFORM=aarch64 TEST_HASH=c7c9814fc275656ed7cc42cafcd0c57571792e9de73c734704ab875119c14f76 ;;
    esac
    export CODEXBAR_INSTALL_PREFIX="$fixture_root/$TEST_ARCH"
    bash "$installer" > "$fixture_root/output" 2>&1
    grep -q 'installed: CodexBar 0.64.0' "$fixture_root/output"
    test -L "$CODEXBAR_INSTALL_PREFIX/bin/codexbar"
    test -L "$CODEXBAR_INSTALL_PREFIX/lib/codexbar/codexbar"
    diff -r "$fixture_root/release" "$CODEXBAR_INSTALL_PREFIX/lib/codexbar"
    # Reinstallation must not nest directories or replace the bundled symlink.
    bash "$installer" > "$fixture_root/output" 2>&1
    diff -r "$fixture_root/release" "$CODEXBAR_INSTALL_PREFIX/lib/codexbar"
done

# A real checksum failure must leave the existing installation untouched.
export TEST_REAL_HASH=1
printf 'sentinel\n' > "$CODEXBAR_INSTALL_PREFIX/lib/codexbar/VERSION"
if bash "$installer" > "$fixture_root/output" 2>&1; then
    echo 'FAIL: mismatched checksum accepted' >&2; exit 1
fi
grep -q 'SHA-256 mismatch' "$fixture_root/output"
test "$(cat "$CODEXBAR_INSTALL_PREFIX/lib/codexbar/VERSION")" = sentinel
export CODEXBAR_INSTALL_PREFIX="$fixture_root/rejected"
if bash "$installer" > "$fixture_root/output" 2>&1; then exit 1; fi
test ! -e "$CODEXBAR_INSTALL_PREFIX"

# Unsupported platforms must fail before downloading or creating an install.
rm "$fixture_root/downloads"
export TEST_ARCH=riscv64
if bash "$installer" > "$fixture_root/output" 2>&1; then exit 1; fi
grep -q 'unsupported architecture' "$fixture_root/output"
test ! -e "$fixture_root/downloads"
test ! -e "$CODEXBAR_INSTALL_PREFIX"
test -z "$(ls -A "$TMPDIR")"
printf 'CodexBar installer tests passed.\n'
