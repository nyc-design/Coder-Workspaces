#!/usr/bin/env bash
# Build-time installer for a pinned SwiftLint release (root, docker build).
#
# realm/SwiftLint publishes per-arch Linux zips. Each contains both a
# dynamically linked `swiftlint` (couples to a specific Swift runtime) and a
# statically linked `swiftlint-static`. We install the static one so SwiftLint
# keeps working across Swift toolchain bumps.
set -euo pipefail

SWIFTLINT_VERSION="${SWIFTLINT_VERSION:-0.65.1}"

# Pinned SHA-256 of the official release assets (verified by download on 2026-09-12).
SWIFTLINT_SHA256_AMD64="caeed6f4a679c35539ffaf124f6c4ab4a8416917f7d8796279dc52b74026059d"
SWIFTLINT_SHA256_ARM64="9ffa52f478e6d8eb485d37d14715ffac90abc81c58f3370d598bf75be05605f8"

log() { echo "[install-swiftlint] $*"; }
die() { echo "[install-swiftlint] ERROR: $*" >&2; exit 1; }

arch="$(dpkg --print-architecture)"
case "$arch" in
    amd64) asset="swiftlint_linux_amd64.zip"; expected_sha256="$SWIFTLINT_SHA256_AMD64" ;;
    arm64) asset="swiftlint_linux_arm64.zip"; expected_sha256="$SWIFTLINT_SHA256_ARM64" ;;
    *)     die "unsupported architecture: '$arch'" ;;
esac

url="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/${asset}"

workdir="$(mktemp -d)"
# shellcheck disable=SC2064  # expand workdir now, on purpose
trap "rm -rf '$workdir'" EXIT

log "architecture=$arch swiftlint=$SWIFTLINT_VERSION"
log "downloading $url"
curl -fsSL --retry 3 --retry-delay 5 -o "$workdir/$asset" "$url"

log "verifying pinned SHA-256"
echo "${expected_sha256}  ${workdir}/${asset}" | sha256sum -c - \
    || die "SHA-256 mismatch for ${asset} — refusing to install"

unzip -q -o "$workdir/$asset" -d "$workdir/extracted"

[ -f "$workdir/extracted/swiftlint-static" ] \
    || die "swiftlint-static missing from ${asset}"

install -m 0755 "$workdir/extracted/swiftlint-static" /usr/local/bin/swiftlint
install -d /usr/local/share/licenses/swiftlint
install -m 0644 "$workdir/extracted/LICENSE" /usr/local/share/licenses/swiftlint/LICENSE

log "installed: swiftlint $(/usr/local/bin/swiftlint version)"
