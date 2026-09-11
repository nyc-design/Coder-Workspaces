# esp32-dev — microcontroller firmware development (ESP32 family).
#
# Extends cpp-dev (gcc/clang, cmake, ninja, gdb, ccache, vcpkg) because
# embedded work is C/C++ first. Adds the ESP-IDF toolchain, esptool, and
# espflash on top.
#
# Flashing/monitoring a board: workspaces run as sysbox containers on a
# remote host, while your board is plugged into your *local* PC. There is
# no host USB to pass through. The supported path is network serial over
# RFC2217 — run esptool's `esp_rfc2217_server.py` on the machine the board
# is attached to, then flash/monitor here against rfc2217://HOST:PORT.
# See the baked skill (skills.d/esp32-remote-flash) and the wrapper at
# /usr/local/bin/esp-remote for the full flow.
FROM ghcr.io/nyc-design/workspace-images/cpp-dev:latest

USER root

# Host packages required by the ESP-IDF installer and serial tooling.
# - python3 venv/pip: ESP-IDF manages its own Python env under IDF_TOOLS_PATH
# - libusb-1.0 / libudev: esptool & espflash USB/serial backends
# - dfu-util: alternative flashing for ESP32-S2/S3 over USB-DFU (when bridged)
RUN apt-get update -y && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-pip \
        libusb-1.0-0 libudev1 \
        dfu-util \
        flex bison gperf \
        ncurses-dev libffi-dev \
 && rm -rf /var/lib/apt/lists/*

# ESP-IDF — Espressif's official SDK (CMake build, esptool, monitor, menuconfig).
# Cloned to /opt/esp-idf and installed for the esp32 family. IDF_TOOLS_PATH
# holds the cross toolchains; both are chowned to coder so `idf.py` and tool
# updates work without sudo at runtime.
ENV IDF_PATH=/opt/esp-idf \
    IDF_TOOLS_PATH=/opt/esp-idf-tools
ARG IDF_VERSION=v5.3.1
RUN git clone --depth 1 --branch "${IDF_VERSION}" --recursive \
        https://github.com/espressif/esp-idf.git "${IDF_PATH}" \
 && "${IDF_PATH}/install.sh" esp32,esp32s2,esp32s3,esp32c3,esp32c6 \
 && rm -rf "${IDF_TOOLS_PATH}/dist" \
 && chown -R coder:coder "${IDF_PATH}" "${IDF_TOOLS_PATH}"

# Source the ESP-IDF export script for every interactive shell so `idf.py`,
# the cross compilers, and esptool are on PATH. `idf.py` itself stays usable
# in agent/non-interactive shells via the wrapper baked below.
RUN printf '\n# ESP-IDF environment\nif [ -f "%s/export.sh" ]; then . "%s/export.sh" >/dev/null 2>&1 || true; fi\n' \
        "${IDF_PATH}" "${IDF_PATH}" >> /etc/bash.bashrc

# Layered workspace contributions (all optional; source paths exist so COPYs
# stay stable as this image grows).
COPY workspace-images/esp32-dev/init.d/                     /usr/local/share/workspace-init.d/
COPY workspace-images/esp32-dev/system_prompt_extension.txt /usr/local/share/workspace-prompts/25-esp32.txt
COPY workspace-images/esp32-dev/extensions.d/               /usr/local/share/workspace-extensions.d/
COPY workspace-images/esp32-dev/settings.d/                 /usr/local/share/workspace-settings.d/
COPY workspace-images/esp32-dev/skills.d/                   /usr/local/share/workspace-skills.d/
COPY workspace-images/esp32-dev/skills-install.d/           /usr/local/share/workspace-skills-install.d/
COPY workspace-images/esp32-dev/bin/esp-remote             /usr/local/bin/esp-remote
RUN find /usr/local/share/workspace-init.d -type f -name '*.sh' -exec chmod +x {} + \
 && chmod +x /usr/local/bin/esp-remote

USER coder

# espflash — Rust-based flasher/monitor (rust-dev is not in this lineage, but
# cpp-dev's parent base-dev does not carry cargo; install the prebuilt binary).
# Pinned release tarball keeps the layer reproducible and avoids a source build.
RUN mkdir -p /home/coder/.local/bin /home/coder/.cache/esp
ARG ESPFLASH_VERSION=v3.3.0
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64)  triple="x86_64-unknown-linux-gnu" ;; \
      aarch64) triple="aarch64-unknown-linux-gnu" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/esp-rs/espflash/releases/download/${ESPFLASH_VERSION}/espflash-${triple}.zip"; \
    curl -fsSL "$url" -o /tmp/espflash.zip; \
    unzip -o /tmp/espflash.zip -d /tmp/espflash; \
    install -m 0755 "$(find /tmp/espflash -name espflash -type f | head -1)" /home/coder/.local/bin/espflash; \
    rm -rf /tmp/espflash /tmp/espflash.zip

ENV PATH=/home/coder/.local/bin:$PATH
