#!/usr/bin/env bash
set -euo pipefail

: "${TARGETARCH:=$(dpkg --print-architecture)}"
: "${BLENDER_RELEASE_REPOSITORY:=nyc-design/Coder-Workspaces}"
# CI resolves once before its architecture matrix. Manual builds can resolve here.
if [[ -z "${BLENDER_VERSION:-}" ]]; then
    release=$(python3 /tmp/modeling-scripts/resolve-blender.py --repository "$BLENDER_RELEASE_REPOSITORY")
    BLENDER_VERSION=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' <<<"$release")
fi
[[ "$BLENDER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid Blender version' >&2; exit 1; }
[[ "$BLENDER_RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 1
version_series=${BLENDER_VERSION%.*}
case "$TARGETARCH" in
    amd64)
        archive="blender-${BLENDER_VERSION}-linux-x64.tar.xz"
        base="https://download.blender.org/release/Blender${version_series}"
        checksum_url="$base/blender-${BLENDER_VERSION}.sha256"
        ;;
    arm64)
        archive="blender-${BLENDER_VERSION}-linux-arm64.tar.xz"
        base="https://github.com/${BLENDER_RELEASE_REPOSITORY}/releases/download/blender-${BLENDER_VERSION}"
        checksum_url="$base/$archive.sha256"
        ;;
    *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --fail --location --retry 5 "$base/$archive" --output "$work/$archive"
curl --fail --location --retry 5 "$checksum_url" --output "$work/checksums"
# Check exactly the expected archive; reject missing/duplicate/malformed entries.
python3 - "$work/checksums" "$archive" > "$work/selected.sha256" <<'PY'
import pathlib, re, sys
entries = []
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    fields = line.split()
    if len(fields) == 2 and fields[1].lstrip('*') == sys.argv[2] and re.fullmatch(r'[a-fA-F0-9]{64}', fields[0]):
        entries.append(fields[0])
if len(entries) != 1:
    raise SystemExit('Expected exactly one valid SHA256 entry for ' + sys.argv[2])
print(entries[0] + '  ' + sys.argv[2])
PY
(cd "$work" && sha256sum --check selected.sha256)
mkdir -p /opt/blender
# Both release workflows package one top-level directory.
tar -xJf "$work/$archive" --strip-components=1 -C /opt/blender
ln -sf /opt/blender/blender /usr/local/bin/blender
printf '%s\n' "$BLENDER_VERSION" > /opt/blender/VERSION
blender --background --factory-startup --python-exit-code 1 --python-expr \
    "import bpy; assert bpy.app.version_string == '${BLENDER_VERSION}', bpy.app.version_string; assert bpy.app.build_options.cycles, 'Cycles CPU support is required'"
