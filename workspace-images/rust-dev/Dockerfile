# Extends YOUR base image
FROM ghcr.io/nyc-design/workspace-images/base-dev:latest

USER root

# Build deps commonly needed by Rust crates (openssl-sys, ring, etc.)
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*

# rustup + stable toolchain installed system-wide, then chowned to coder so
# `cargo install` and `rustup update` work without sudo at runtime.
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable \
            -c clippy -c rustfmt -c rust-src \
 && chown -R coder:coder /usr/local/cargo /usr/local/rustup

# Layered workspace contributions (all optional; source paths exist so COPYs
# stay stable as this image grows).
COPY workspace-images/rust-dev/init.d/                     /usr/local/share/workspace-init.d/
COPY workspace-images/rust-dev/system_prompt_extension.txt /usr/local/share/workspace-prompts/20-rust.txt
COPY workspace-images/rust-dev/extensions.d/               /usr/local/share/workspace-extensions.d/
COPY workspace-images/rust-dev/settings.d/                 /usr/local/share/workspace-settings.d/
COPY workspace-images/rust-dev/skills.d/                   /usr/local/share/workspace-skills.d/
COPY workspace-images/rust-dev/skills-install.d/           /usr/local/share/workspace-skills-install.d/
RUN find /usr/local/share/workspace-init.d -type f -name '*.sh' -exec chmod +x {} +

USER coder

# cargo-binstall lets `cargo binstall <crate>` fetch a prebuilt binary instead
# of compiling from source — much faster for tools like cargo-nextest etc.
RUN curl -L --proto '=https' --tlsv1.2 -sSf \
        https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash

RUN mkdir -p /home/coder/.cache/cargo
