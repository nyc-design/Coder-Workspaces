#!/usr/bin/env bash
set -euo pipefail

# PyPI usd-core 26.5 has Linux x86_64 wheels but no Linux ARM64 wheels.
# Build the same upstream version's non-imaging Python bindings on ARM64.
case "${TARGETARCH:=$(dpkg --print-architecture)}" in
    amd64)
        python3 -m pip install --no-cache-dir --break-system-packages --only-binary=:all: 'usd-core==26.5'
        ;;
    arm64)
        work=$(mktemp -d)
        trap 'rm -rf "$work"' EXIT
        curl --fail --location --retry 5 \
            https://codeload.github.com/PixarAnimationStudios/OpenUSD/tar.gz/refs/tags/v26.05 \
            --output "$work/openusd.tar.gz"
        echo 'bf514f62ac9508d3c5b121dc1107f3b29bf3c954473b9b0bf8324b7cf04c64c1  '"$work/openusd.tar.gz" | sha256sum --check -
        tar -xzf "$work/openusd.tar.gz" -C "$work"
        cmake -S "$work/OpenUSD-26.05" -B "$work/build" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/openusd \
            -DPython3_EXECUTABLE=/usr/bin/python3 \
            -DPXR_ENABLE_PYTHON_SUPPORT=ON \
            -DPXR_BUILD_IMAGING=OFF -DPXR_BUILD_USD_IMAGING=OFF \
            -DPXR_BUILD_USDVIEW=OFF -DPXR_ENABLE_MATERIALX_SUPPORT=OFF \
            -DPXR_BUILD_TESTS=OFF -DPXR_BUILD_EXAMPLES=OFF \
            -DPXR_BUILD_TUTORIALS=OFF -DPXR_BUILD_USD_TOOLS=OFF
        # Native ARM runners have limited RAM; do not default to all CPUs.
        cmake --build "$work/build" --parallel "${OPENUSD_BUILD_JOBS:-2}"
        cmake --install "$work/build"
        echo /opt/openusd/lib > /etc/ld.so.conf.d/openusd.conf
        ldconfig
        python3 - <<'PY'
import pathlib, site
path = pathlib.Path(site.getsitepackages()[0]) / 'modeling-openusd.pth'
path.write_text('/opt/openusd/lib/python\n')
PY
        ;;
    *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;;
esac
python3 -c 'from pxr import Usd; assert Usd.GetVersion() == (0, 26, 5); assert Usd.Stage.CreateInMemory()'
