#!/usr/bin/env bash
# Build-time installer for the official swift.org Linux toolchain.
#
# Runs as root during `docker build`. Multi-arch (amd64 / arm64) by way of
# `dpkg --print-architecture`, which reflects the *target* platform under
# buildx, so this works unchanged on native amd64 and arm64 runners.
#
# Verification is deliberately belt-and-braces:
#   1. A pinned SHA-256 per arch (hard gate, immune to signing-key expiry).
#   2. The detached GPG signature published alongside the tarball, checked
#      against the Swift release signing key fingerprint.
# Both must pass. See the SIGNING KEY EXPIRY note below for why (1) exists.
set -euo pipefail

SWIFT_VERSION="${SWIFT_VERSION:-6.3.3}"
SWIFT_TAG="swift-${SWIFT_VERSION}-RELEASE"
SWIFT_BRANCH="swift-${SWIFT_VERSION}-release"
SWIFT_PLATFORM="ubuntu24.04"
SWIFT_WEBROOT="${SWIFT_WEBROOT:-https://download.swift.org}"

# Swift 6.x Release Signing Key <swift-infrastructure@forums.swift.org>
#
# SIGNING KEY EXPIRY: this key carries an expiry of 2026-09-16. Once it lapses
# `gpg --verify` reports EXPKEYSIG instead of GOODSIG. An expired key still
# proves the artifact was signed by the Swift project at signing time, so we
# accept EXPKEYSIG but never BADSIG / NO_PUBKEY — and the pinned SHA-256 below
# remains the real integrity gate regardless of key state.
SWIFT_SIGNING_KEY="52BB7E3DE28A71BE22EC05FFEF80A866B47A981F"

# Pinned SHA-256 of the official tarballs (verified by download on 2026-09-12).
SWIFT_SHA256_AMD64="da8272a5fddccd65b1529ed0e52e04526e2eadd4237d58d6220efeb973c6cd19"
SWIFT_SHA256_ARM64="47126395429653fa768d370655876ec1b68f6a95c7884f5e4f179700141c9b7f"

# Self-contained install root. Keeping the toolchain out of /usr means an
# upgrade is a single directory swap and never fights dpkg-owned files.
SWIFT_HOME="${SWIFT_HOME:-/usr/local/swift}"

log() { echo "[install-swift] $*"; }
die() { echo "[install-swift] ERROR: $*" >&2; exit 1; }

arch="$(dpkg --print-architecture)"
case "$arch" in
    amd64)
        os_arch_suffix=""
        expected_sha256="$SWIFT_SHA256_AMD64"
        ;;
    arm64)
        os_arch_suffix="-aarch64"
        expected_sha256="$SWIFT_SHA256_ARM64"
        ;;
    *)
        die "unsupported architecture: '$arch' (swift.org publishes ubuntu24.04 builds for x86_64 and aarch64 only)"
        ;;
esac

webdir="${SWIFT_WEBROOT}/${SWIFT_BRANCH}/$(echo "$SWIFT_PLATFORM" | tr -d .)${os_arch_suffix}"
tarball_name="${SWIFT_TAG}-${SWIFT_PLATFORM}${os_arch_suffix}.tar.gz"
bin_url="${webdir}/${SWIFT_TAG}/${tarball_name}"
sig_url="${bin_url}.sig"

workdir="$(mktemp -d)"
# shellcheck disable=SC2064  # expand workdir now, on purpose
trap "rm -rf '$workdir'" EXIT

log "architecture=$arch swift=$SWIFT_VERSION"
log "downloading $bin_url"
curl -fsSL --retry 3 --retry-delay 5 \
    -o "$workdir/swift.tar.gz" "$bin_url" \
    -o "$workdir/swift.tar.gz.sig" "$sig_url"

# ── Gate 1: pinned checksum ──────────────────────────────────────────────
log "verifying pinned SHA-256"
echo "${expected_sha256}  ${workdir}/swift.tar.gz" | sha256sum -c - \
    || die "SHA-256 mismatch for ${tarball_name} — refusing to install"

# ── Gate 2: detached GPG signature ───────────────────────────────────────
log "verifying detached GPG signature"
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
# swift.org serves all-keys.asc gzip-encoded unconditionally, so --compressed
# is required or gpg receives binary gzip and reports "no valid OpenPGP data".
if ! curl -fsSL --compressed --retry 3 --retry-delay 5 \
        https://www.swift.org/keys/all-keys.asc | gpg --batch --quiet --import; then
    log "swift.org keyring fetch failed; falling back to keyserver.ubuntu.com"
    gpg --batch --quiet --keyserver keyserver.ubuntu.com \
        --recv-keys "$SWIFT_SIGNING_KEY" \
        || die "could not obtain Swift signing key $SWIFT_SIGNING_KEY"
fi

status="$workdir/gpg.status"
gpg --batch --status-file "$status" \
    --verify "$workdir/swift.tar.gz.sig" "$workdir/swift.tar.gz" >/dev/null 2>&1 || true

if grep -q '^\[GNUPG:\] BADSIG' "$status"; then
    die "BADSIG — signature does not match ${tarball_name}"
fi
if grep -q '^\[GNUPG:\] NO_PUBKEY' "$status"; then
    die "NO_PUBKEY — Swift signing key unavailable, cannot verify ${tarball_name}"
fi
if ! grep -qE '^\[GNUPG:\] (GOODSIG|EXPKEYSIG)' "$status"; then
    die "no good signature found for ${tarball_name}; gpg status was: $(tr '\n' '|' < "$status")"
fi
grep -q "^\[GNUPG:\] VALIDSIG ${SWIFT_SIGNING_KEY}" "$status" \
    || die "signature is not from the expected key ${SWIFT_SIGNING_KEY}"

if grep -q '^\[GNUPG:\] EXPKEYSIG' "$status"; then
    log "NOTE: signature is valid but the Swift signing key has expired; pinned SHA-256 already passed"
else
    log "GOODSIG from ${SWIFT_SIGNING_KEY}"
fi
rm -rf "$GNUPGHOME"
unset GNUPGHOME

# ── Install ──────────────────────────────────────────────────────────────
# The tarball root is "<tag>/usr/{bin,lib,share,...}". Stripping two
# components lands a conventional bin/ + lib/ toolchain layout directly in
# $SWIFT_HOME, which is how swiftc locates its resource dir relative to argv[0].
log "extracting to $SWIFT_HOME"
mkdir -p "$SWIFT_HOME"
tar -xzf "$workdir/swift.tar.gz" --directory "$SWIFT_HOME" --strip-components=2

[ -x "$SWIFT_HOME/bin/swift" ] || die "expected $SWIFT_HOME/bin/swift after extraction"

# Runtime libraries must be world-readable; the tarball is packed as root-only
# in places and the workspace runs as the unprivileged `coder` user.
chmod -R o+rX "$SWIFT_HOME/lib"

# Trim documentation that has no use in a headless build image.
rm -rf "$SWIFT_HOME/share/doc"

# PATH for every user and every shell flavour. The Dockerfile also sets ENV
# PATH (covers non-login, non-interactive `docker exec`); this file covers
# login shells and anything that sources /etc/profile.d.
cat > /etc/profile.d/swift.sh <<EOF
export SWIFT_HOME=${SWIFT_HOME}
case ":\$PATH:" in
    *":${SWIFT_HOME}/bin:"*) ;;
    *) export PATH="${SWIFT_HOME}/bin:\$PATH" ;;
esac
EOF
chmod 0644 /etc/profile.d/swift.sh

# Let the dynamic loader find the Swift runtime so binaries produced by
# `swift build` run even when invoked without an rpath-aware wrapper.
echo "${SWIFT_HOME}/lib/swift/linux" > /etc/ld.so.conf.d/swift.conf
ldconfig

log "installed: $("$SWIFT_HOME/bin/swift" --version 2>&1 | head -1)"
log "toolchain size: $(du -sh "$SWIFT_HOME" | cut -f1)"
