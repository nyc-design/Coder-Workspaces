#!/usr/bin/env bash
# Standalone, release-pinned native build. Run as an ordinary user on Ubuntu 24.04 ARM64.
set -euo pipefail

phase=${1:?Usage: build.sh prepare|dependencies|blender|package}
: "${BLENDER_VERSION:?Set BLENDER_VERSION}"
: "${BLENDER_SOURCE_SHA:?Set BLENDER_SOURCE_SHA}"
: "${BLENDER_WORK_DIR:?Set BLENDER_WORK_DIR to an absolute scratch directory}"
[[ $BLENDER_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ $BLENDER_SOURCE_SHA =~ ^[0-9a-f]{40}$ ]]
[[ $BLENDER_WORK_DIR = /* && $BLENDER_WORK_DIR != / ]]
[[ $(uname -m) == aarch64 ]] || { echo 'A native AArch64 host is required' >&2; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || { echo 'Ubuntu 24.04 is required' >&2; exit 1; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir=$BLENDER_WORK_DIR/source
library_dir=$BLENDER_WORK_DIR/lib/linux_arm64
deps_dir=$BLENDER_WORK_DIR/dependencies
build_dir=$BLENDER_WORK_DIR/build
package_name=blender-${BLENDER_VERSION}-linux-arm64
install_dir=$BLENDER_WORK_DIR/install/$package_name
output_dir=$BLENDER_WORK_DIR/dist
# Each compiler process (particularly LLVM/Blender C++) can consume several GiB.
mem_gib=$(awk '/MemTotal:/ {print int($2 / 1024 / 1024)}' /proc/meminfo)
jobs=$((mem_gib / 4))
(( jobs > 0 )) || jobs=1
(( jobs <= $(nproc) )) || jobs=$(nproc)
export CC=gcc-14 CXX=g++-14
# No -march=native: use Blender's upstream ARMv8.2-A + dotprod/fp16/LSE baseline.
export CFLAGS='-O2 -march=armv8.2-a+dotprod+fp16+lse'
export CXXFLAGS=$CFLAGS
export MAKEFLAGS=-j${jobs}
export CMAKE_BUILD_PARALLEL_LEVEL=$jobs
export CMAKE_BUILD_TYPE=Release
export DEBIAN_FRONTEND=noninteractive
mkdir -p "$BLENDER_WORK_DIR"

case "$phase" in
  prepare)
    sudo apt-get update
    mapfile -t packages < "$script_dir/ubuntu-packages.txt"
    sudo apt-get install --no-install-recommends -y "${packages[@]}"
    # A tag is resolved during discovery and rechecked here, so it cannot move silently.
    git init "$source_dir"
    git -C "$source_dir" remote add origin https://github.com/blender/blender.git
    git -C "$source_dir" fetch --depth 1 origin "refs/tags/v${BLENDER_VERSION}"
    git -C "$source_dir" checkout --detach FETCH_HEAD
    [[ $(git -C "$source_dir" rev-parse HEAD) == "$BLENDER_SOURCE_SHA" ]] || {
      echo 'Upstream tag no longer matches the discovered commit' >&2; exit 1;
    }
    # Do not run make update: that updates source and downloads x86 prebuilt libraries.
    git -C "$source_dir" show -s --format=%ct HEAD > "$BLENDER_WORK_DIR/source-date-epoch"
    ;;
  dependencies)
    # Equivalent to upstream `make deps`, with explicit paths and bounded parallelism.
    # Upstream versions.cmake supplies source versions/hashes and ARM architecture gates.
    # Linux ARM has no release-pinned precompiled library submodule (checked at v5.2.1).
    export SOURCE_DATE_EPOCH
    SOURCE_DATE_EPOCH=$(cat "$BLENDER_WORK_DIR/source-date-epoch")
    cmake -S "$source_dir/build_files/build_environment" -B "$deps_dir" -G 'Unix Makefiles' \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_MODE=Release \
      -DMAKE_THREADS="$jobs" -DHARVEST_TARGET="$library_dir" \
      -DPACKAGE_DIR="$BLENDER_WORK_DIR/dependency-sources" \
      -DPACKAGE_USE_UPSTREAM_SOURCES=ON
    # Outer -j1 avoids several large ExternalProjects each spawning MAKE_THREADS jobs.
    cmake --build "$deps_dir" --parallel 1
    cmake --install "$deps_dir"
    test -d "$library_dir/python"
    test -d "$library_dir/llvm"
    mkdir -p "$BLENDER_WORK_DIR/transfer"
    # One archive preserves permissions/symlinks across Actions artifact transport.
    tar -C "$BLENDER_WORK_DIR" -I 'zstd -T2 -3' -cf "$BLENDER_WORK_DIR/transfer/dependencies.tar.zst" \
      lib dependency-sources source-date-epoch
    ;;
  blender)
    export SOURCE_DATE_EPOCH
    SOURCE_DATE_EPOCH=$(cat "$BLENDER_WORK_DIR/source-date-epoch")
    cmake -S "$source_dir" -B "$build_dir" -G Ninja \
      -C "$source_dir/build_files/cmake/config/blender_release.cmake" \
      -DCMAKE_BUILD_TYPE=Release -DLIBDIR="$library_dir" \
      -DCMAKE_INSTALL_PREFIX="$install_dir" \
      -DWITH_LIBS_PRECOMPILED=ON -DWITH_STRICT_BUILD_OPTIONS=ON \
      -DWITH_INSTALL_PORTABLE=ON -DWITH_PYTHON_INSTALL=ON \
      -DWITH_CYCLES_NATIVE_ONLY=OFF \
      -DWITH_CYCLES_DEVICE_CUDA=OFF -DWITH_CYCLES_DEVICE_OPTIX=OFF \
      -DWITH_CYCLES_DEVICE_HIP=OFF -DWITH_CYCLES_DEVICE_HIPRT=OFF \
      -DWITH_CYCLES_DEVICE_ONEAPI=OFF -DWITH_CYCLES_DEVICE_METAL=OFF \
      -DWITH_CYCLES_CUDA_BINARIES=OFF -DWITH_CYCLES_HIP_BINARIES=OFF \
      -DWITH_CYCLES_ONEAPI_BINARIES=OFF
    cmake --build "$build_dir" --parallel "$jobs"
    cmake --install "$build_dir"
    "$install_dir/blender" --version
    # Background mode + CPU Cycles needs no display server or GPU device.
    "$install_dir/blender" --background --factory-startup --python-exit-code 1 \
      --python "$script_dir/smoke_test.py"
    ;;
  package)
    export SOURCE_DATE_EPOCH
    SOURCE_DATE_EPOCH=$(cat "$BLENDER_WORK_DIR/source-date-epoch")
    mkdir -p "$output_dir" "$install_dir/build-info" "$BLENDER_WORK_DIR/corresponding-source"
    cp "$build_dir/CMakeCache.txt" "$install_dir/build-info/"
    cp -a "$script_dir" "$install_dir/build-info/recipe"
    dpkg-query -W > "$install_dir/build-info/ubuntu-packages.txt"
    {
      printf 'Blender version: %s\nSource commit: %s\n' "$BLENDER_VERSION" "$BLENDER_SOURCE_SHA"
      printf 'Source: https://github.com/blender/blender/tree/%s\n' "$BLENDER_SOURCE_SHA"
      printf 'CPU baseline: ARMv8.2-A + dotprod + fp16 + LSE (not -march=native)\n'
      printf 'Host ABI: Ubuntu 24.04 ARM64; glibc 2.39 or newer\n'
      printf 'Workflow commit: %s\n' "${GITHUB_SHA:-local}"
      "$CC" --version
      cmake --version
      ldd --version
    } > "$install_dir/build-info/BUILD-INFO.txt"
    # Verify every ELF in the relocated payload, not only the main executable.
    python3 "$script_dir/check_runtime.py" "$install_dir"
    # Prove the installation is relocatable and does not rely on the dependency tree.
    relocation_dir=$BLENDER_WORK_DIR/relocated/$package_name
    mkdir -p "$(dirname "$relocation_dir")"
    mv "$install_dir" "$relocation_dir"
    mv "$library_dir" "$library_dir.hidden"
    trap 'mv "$library_dir.hidden" "$library_dir"; mv "$relocation_dir" "$install_dir"' EXIT
    python3 "$script_dir/check_runtime.py" "$relocation_dir"
    "$relocation_dir/blender" --background --factory-startup --python-exit-code 1 \
      --python "$script_dir/smoke_test.py"
    mv "$library_dir.hidden" "$library_dir"
    mv "$relocation_dir" "$install_dir"
    trap - EXIT
    tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
      -C "$BLENDER_WORK_DIR/install" -I 'xz -T2 -6' -cf "$output_dir/$package_name.tar.xz" "$package_name"
    # Ship corresponding source, including the dependency archives, upstream patches,
    # and this build recipe. GitHub's auto-generated source archive is THIS repository,
    # not Blender, and therefore is not a substitute for these assets.
    git -C "$source_dir" archive --format=tar HEAD | tar -xf - -C "$BLENDER_WORK_DIR/corresponding-source"
    cp -a "$script_dir" "$BLENDER_WORK_DIR/corresponding-source/arm64-build-recipe"
    cp "$install_dir/build-info/BUILD-INFO.txt" "$output_dir/BUILD-INFO.txt"
    cp "$install_dir/build-info/BUILD-INFO.txt" "$BLENDER_WORK_DIR/corresponding-source/ARM64-BUILD-INFO.txt"
    tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
      -C "$BLENDER_WORK_DIR" -I 'zstd -T2 -9' -cf - corresponding-source dependency-sources \
      | split -b 1900M -d -a 3 - "$output_dir/$package_name-sources.tar.zst.part-"
    # GitHub Release assets must each be smaller than 2 GiB.
    find "$output_dir" -type f -size +2047M -print -quit | grep . && {
      echo 'A release asset exceeds the GitHub size limit' >&2; exit 1;
    }
    (cd "$output_dir"; sha256sum "$package_name.tar.xz" > "$package_name.tar.xz.sha256";
      sha256sum ./*.tar.xz ./*.part-* BUILD-INFO.txt > SHA256SUMS)
    ;;
  *) echo "Unknown phase: $phase" >&2; exit 2 ;;
esac
