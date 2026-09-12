# Extends YOUR base image
FROM ghcr.io/nyc-design/workspace-images/base-dev:latest

USER root

# Runtime + build dependencies for the swift.org Ubuntu 24.04 toolchain.
# This list is taken verbatim from the official swiftlang/swift-docker
# 6.3/ubuntu/24.04/Dockerfile rather than guessed.
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
 && apt-get -q update \
 && apt-get -q install -y --no-install-recommends \
    binutils \
    git \
    unzip \
    gnupg2 \
    libc6-dev \
    libcurl4-openssl-dev \
    libedit2 \
    libgcc-13-dev \
    libpython3-dev \
    libsqlite3-0 \
    libstdc++-13-dev \
    libxml2-dev \
    libncurses-dev \
    libz3-dev \
    pkg-config \
    tzdata \
    zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# Pinned Swift toolchain from official swift.org tarballs, installed
# system-wide. Multi-arch: the script resolves amd64 / arm64 itself and
# enforces a pinned SHA-256 plus the detached GPG signature.
ENV SWIFT_HOME=/usr/local/swift
ENV PATH=/usr/local/swift/bin:$PATH
COPY workspace-images/swift-dev/scripts/install-swift.sh /tmp/install-swift.sh
RUN chmod +x /tmp/install-swift.sh \
 && SWIFT_VERSION=6.3.3 /tmp/install-swift.sh \
 && rm -f /tmp/install-swift.sh

# SwiftLint, pinned per-arch (statically linked build so it survives toolchain
# bumps). swift-format and sourcekit-lsp already ship inside the toolchain.
COPY workspace-images/swift-dev/scripts/install-swiftlint.sh /tmp/install-swiftlint.sh
RUN chmod +x /tmp/install-swiftlint.sh \
 && SWIFTLINT_VERSION=0.65.1 /tmp/install-swiftlint.sh \
 && rm -f /tmp/install-swiftlint.sh

# Build-time smoke gate: compile + test a throwaway SwiftPM package and assert
# swiftlint / swift-format actually run. Fails the build if the toolchain is
# broken. Entirely offline (no package dependencies), so it stays installed as
# `swift-smoke-check` for on-demand re-runs, mirroring modeling-dev.
# Caches created here are removed in the same layer.
COPY workspace-images/swift-dev/scripts/swift-build-smoke.sh /usr/local/bin/swift-smoke-check
RUN chmod +x /usr/local/bin/swift-smoke-check \
 && swift-smoke-check \
 && rm -rf /root/.cache /root/.swiftpm /tmp/* /var/tmp/*

# Layered workspace contributions (all optional; source paths exist so COPYs
# stay stable as this image grows).
COPY workspace-images/swift-dev/init.d/                     /usr/local/share/workspace-init.d/
COPY workspace-images/swift-dev/system_prompt_extension.txt /usr/local/share/workspace-prompts/20-swift.txt
COPY workspace-images/swift-dev/extensions.d/               /usr/local/share/workspace-extensions.d/
COPY workspace-images/swift-dev/settings.d/                 /usr/local/share/workspace-settings.d/
COPY workspace-images/swift-dev/skills.d/                   /usr/local/share/workspace-skills.d/
COPY workspace-images/swift-dev/skills-install.d/           /usr/local/share/workspace-skills-install.d/
RUN find /usr/local/share/workspace-init.d -type f -name '*.sh' -exec chmod +x {} +

USER coder

# SwiftPM writes its module cache, build artifacts and resolved-dependency
# clones here; pre-creating them avoids a first-build permission surprise.
RUN mkdir -p /home/coder/.cache/org.swift.swiftpm /home/coder/.swiftpm
