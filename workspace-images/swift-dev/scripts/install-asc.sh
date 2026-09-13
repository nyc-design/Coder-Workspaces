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

ASC_VERSION="${ASC_VERSION:-5.3.0}"

# Pinned SHA-256 of the official release assets (verified by download on 2026-09-13).
ASC_SHA256_AMD64="213c4c822a6a411a525dd14ac2a4c15e33ac9e32bada8128baf0397bb02c4b05"
ASC_SHA256_ARM64="72ab72a9c2651c2ae030b23dc49504ebca8414ae9e8af797be096c0142e17507"

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
