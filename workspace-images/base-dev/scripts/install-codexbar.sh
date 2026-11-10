#!/usr/bin/env bash
# Build-time installer for the pinned static-musl Linux CLI (root, docker build).
set -euo pipefail

readonly version="0.84.0"
# Verified against both downloaded release archives and upstream .sha256 assets.
readonly sha256_amd64="d0ea804c567e3b5855823da2ed3a8c98dd422ab958a9684a3d77d1c9cf25dcd1"
readonly sha256_arm64="fbacb436af95ce16bea45dd9b393e9df8e47f0abefa5dc236df5b2b01532d079"
readonly prefix="${CODEXBAR_INSTALL_PREFIX:-/usr/local}"

arch="$(dpkg --print-architecture)"
case "$arch" in
    amd64) platform="x86_64"; expected_sha256="$sha256_amd64" ;;
    arm64) platform="aarch64"; expected_sha256="$sha256_arm64" ;;
    *) echo "[install-codexbar] ERROR: unsupported architecture: '$arch'" >&2; exit 1 ;;
esac

asset="CodexBarCLI-v${version}-linux-musl-${platform}.tar.gz"
url="https://github.com/steipete/CodexBar/releases/download/v${version}/${asset}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

printf '[install-codexbar] downloading %s\n' "$url"
curl -fsSL --retry 3 --retry-delay 5 -o "$workdir/$asset" "$url"
printf '%s  %s\n' "$expected_sha256" "$workdir/$asset" | sha256sum -c - || {
    echo "[install-codexbar] ERROR: SHA-256 mismatch for $asset — refusing to install" >&2
    exit 1
}

mkdir "$workdir/unpacked"
tar -xzf "$workdir/$asset" -C "$workdir/unpacked"
test -x "$workdir/unpacked/CodexBarCLI"
test -L "$workdir/unpacked/codexbar"
test "$(readlink "$workdir/unpacked/codexbar")" = "CodexBarCLI"
test "$(cat "$workdir/unpacked/VERSION")" = "$version"
test -d "$workdir/unpacked/CodexBar_CodexBarCore.bundle"

# Swift resolves resources beside the real executable. Keep the entire release
# together, including VERSION, rather than copying just the binary onto PATH.
install -d "$prefix/lib/codexbar" "$prefix/bin"
cp -a "$workdir/unpacked/." "$prefix/lib/codexbar/"
ln -sfn "$prefix/lib/codexbar/codexbar" "$prefix/bin/codexbar"
installed_version="$("$prefix/bin/codexbar" --version)"
printf '[install-codexbar] installed: %s\n' "$installed_version"
