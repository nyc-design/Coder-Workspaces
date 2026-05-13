# Extends YOUR base image
FROM ghcr.io/nyc-design/workspace-images/base-dev:latest

USER root

# Core C++ toolchain + build systems. Project-specific libraries (boost,
# fmt, spdlog, gtest, etc.) belong in each project's vcpkg.json or
# CMakeLists.txt FetchContent, not the base image.
RUN apt-get update -y && apt-get install -y --no-install-recommends \
        build-essential gcc g++ \
        clang clang-format clang-tidy clangd lldb \
        gdb valgrind \
        cmake ninja-build make pkg-config \
        libssl-dev \
        ccache \
 && rm -rf /var/lib/apt/lists/*

# vcpkg (C++ package manager) installed system-wide. Projects opt in by
# adding a vcpkg.json and setting CMAKE_TOOLCHAIN_FILE to $VCPKG_ROOT.
RUN git clone --depth 1 https://github.com/Microsoft/vcpkg.git /opt/vcpkg \
 && /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics \
 && ln -s /opt/vcpkg/vcpkg /usr/local/bin/vcpkg \
 && chown -R coder:coder /opt/vcpkg

# Tier 2 (cpp) extension manifest, merged with the inherited Tier 1 manifest
# at workspace start by 25-extensions-install.sh and 26-settings-apply.sh.
COPY workspace-images/cpp-dev/extensions.d/ /usr/local/share/workspace-extensions.d/

# Tier 2 (cpp) settings manifest
COPY workspace-images/cpp-dev/settings.d/ /usr/local/share/workspace-settings.d/

# C++ environment. ccache is on PATH so CMake picks it up as the compiler
# launcher automatically; CMAKE_GENERATOR=Ninja matches the cmake-tools
# default we set in the Tier 2 settings manifest.
ENV CC=gcc \
    CXX=g++ \
    CMAKE_GENERATOR=Ninja \
    CMAKE_EXPORT_COMPILE_COMMANDS=ON \
    VCPKG_ROOT=/opt/vcpkg \
    PATH=/usr/lib/ccache:/opt/vcpkg:$PATH

USER coder

RUN mkdir -p /home/coder/.cache/ccache
