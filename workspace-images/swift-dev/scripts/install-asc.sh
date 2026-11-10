#!/usr/bin/env bash
# Build-time installer for a pinned `asc` release (root, docker build).
#
# asc is the third-party App Store Connect CLI (rorkai/App-Store-Connect-CLI,
# MIT). It matters here because it is the only way a Linux workspace can drive
# Xcode Cloud: Apple ships no Xcode Cloud CLI for Linux, only the App Store
# Connect REST API, and asc wraps that API with `xcode-cloud run/status/doctor`,
# products, workflows, build-runs, actions and artifacts.
#
# Upstream's documented install is `curl https://asccli.sh/install | bash`.
# We deliberately don't use it: it resolves "latest" at build time and pipes a
# remote script into a shell, so image builds would be non-reproducible. The
# release assets are plain, self-contained Go binaries, so we fetch the pinned
# one directly and check its SHA-256 instead.
set -euo pipefail

ASC_VERSION="${ASC_VERSION:-6.6.0}"

# Pinned SHA-256 of the official release assets (verified by download on 2026-11-10).
ASC_SHA256_AMD64="68fddb0e02be25f9ac5c0f53d07533ceb31ddda2265575090b8eb6a133605785"
ASC_SHA256_ARM64="d2619fd94102ba67b1a9dcf7e760e0ad81bc57292ae4a07bd39c790aa6d5a8c7"

log() { echo "[install-asc] $*"; }
die() { echo "[install-asc] ERROR: $*" >&2; exit 1; }

arch="$(dpkg --print-architecture)"
case "$arch" in
    amd64) asset="asc_${ASC_VERSION}_linux_amd64"; expected_sha256="$ASC_SHA256_AMD64" ;;
    arm64) asset="asc_${ASC_VERSION}_linux_arm64"; expected_sha256="$ASC_SHA256_ARM64" ;;
    *)     die "unsupported architecture: '$arch'" ;;
esac

url="https://github.com/rorkai/App-Store-Connect-CLI/releases/download/${ASC_VERSION}/${asset}"

workdir="$(mktemp -d)"
# shellcheck disable=SC2064  # expand workdir now, on purpose
trap "rm -rf '$workdir'" EXIT

log "architecture=$arch asc=$ASC_VERSION"
log "downloading $url"
curl -fsSL --retry 3 --retry-delay 5 -o "$workdir/$asset" "$url"

log "verifying pinned SHA-256"
echo "${expected_sha256}  ${workdir}/${asset}" | sha256sum -c - \
    || die "SHA-256 mismatch for ${asset} — refusing to install"

install -m 0755 "$workdir/$asset" /usr/local/bin/asc

log "installed: asc $(/usr/local/bin/asc version)"
