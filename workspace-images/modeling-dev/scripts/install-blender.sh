#!/usr/bin/env bash
set -euo pipefail

: "${TARGETARCH:=$(dpkg --print-architecture)}"
# Pin both architectures together. Never resolve a moving release at build time.
BLENDER_VERSION=5.1.0
case "$TARGETARCH" in
    amd64)
        url=https://download.blender.org/release/Blender5.1/blender-5.1.0-linux-x64.tar.xz
        sha256=7f2475990613c8d4c7ac5697803fcf40d09541c1fd8c23936f4b07a169a920c7
        ;;
    arm64)
        url=https://github.com/lfdevs/blender-linux-arm64/releases/download/v5.1.0/blender-5.1.0-git20260325.ae6d847d66fa-aarch64.tar.gz
        sha256=a4927219950566af13572e72f31b5bcb8baf87190ee86a26e2572ce7fd059793
        ;;
    *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --fail --location --retry 5 "$url" --output "$work/blender.archive"
printf '%s  %s\n' "$sha256" "$work/blender.archive" | sha256sum --check -
mkdir -p /opt/blender
if [[ "$TARGETARCH" == arm64 ]]; then
    tar -xzf "$work/blender.archive" --strip-components=1 -C /opt/blender
else
    tar -xJf "$work/blender.archive" --strip-components=1 -C /opt/blender
fi
ln -sf /opt/blender/blender /usr/local/bin/blender
# Used at workspace startup to create a user's initial safe startup.blend.
install -Dm 0644 "$(dirname "$0")/modeling-safe-defaults.py" \
    /usr/local/share/modeling-tools/modeling-safe-defaults.py

printf '%s\n' "$BLENDER_VERSION" > /opt/blender/VERSION
blender --background --factory-startup --python-exit-code 1 --python-expr \
    "import bpy; assert bpy.app.version_string == '${BLENDER_VERSION}', bpy.app.version_string; assert bpy.app.build_options.cycles, 'Cycles CPU support is required'"
