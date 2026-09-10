# syntax=docker/dockerfile:1
FROM ghcr.io/nyc-design/workspace-images/python-dev:latest

USER root
ARG TARGETARCH
ARG DEBIAN_FRONTEND=noninteractive
ARG OPENUSD_BUILD_JOBS=2

# Runtime dependencies are required even with --background (official Blender
# binaries and CAD wheels link graphics libraries; no display/GPU is required).
# ARM64 Blender uses the pinned lfdevs package with its bundled libraries.
# Compiler dependencies support OpenUSD's missing Linux ARM64 wheel.
RUN apt-get update && apt-get install -y --no-install-recommends \
    assimp-utils ca-certificates curl xz-utils \
    libgl1 libglu1-mesa libegl1 libx11-6 libxext6 libxi6 libxrender1 \
    libxfixes3 libxkbcommon0 libsm6 libice6 libxxf86vm1 libxcursor1 \
    libxrandr2 libxinerama1 libwayland-client0 libwayland-cursor0 libwayland-egl1 \
    libdbus-1-3 libgomp1 libfontconfig1 libfreetype6 libasound2t64 \
    && if [ "$TARGETARCH" = arm64 ]; then \
        apt-get install -y --no-install-recommends \
            cmake ninja-build python3-jinja2 libtbb-dev libboost-dev \
            libtbb12 libtbbmalloc2 libgoogle-glog0v6 libgflags2.2 libmetis5 \
            libpng16-16t64 libshaderc1 libjpeg-turbo8 libwebp7 libvulkan1 \
            libspnav0 libosdcpu3.5.0t64 libosdgpu3.5.0t64 \
            libavcodec60 libavdevice60 libavformat60 libavutil58 libswscale7 \
            libpotrace0 libopenexr-3-1-30 libimath-3-1-29t64 libpugixml1v5 \
            libepoxy0 libfftw3-single3 libfftw3-double3 libraw23t64 \
            libwebpdemux2 libblosc1 libboost-iostreams1.83.0 libpystring0 \
            libyaml-cpp0.8 libgif7 libheif1; \
    fi \
    && rm -rf /var/lib/apt/lists/*

COPY workspace-images/modeling-dev/requirements.txt /tmp/modeling-requirements.txt
RUN python3 -m pip install --no-cache-dir --break-system-packages --only-binary=:all: \
    -r /tmp/modeling-requirements.txt && rm /tmp/modeling-requirements.txt

# ARM64 source bindings are registered with system Python through a .pth file;
# avoid globally exporting PYTHONPATH into Blender's bundled interpreter.
COPY workspace-images/modeling-dev/scripts/ /tmp/modeling-scripts/
RUN bash /tmp/modeling-scripts/install-openusd.sh
RUN bash /tmp/modeling-scripts/install-blender.sh

COPY workspace-images/modeling-dev/package.json workspace-images/modeling-dev/package-lock.json /opt/modeling-tools/
RUN npm ci --prefix /opt/modeling-tools --omit=dev --ignore-scripts \
    && install -m 0755 /tmp/modeling-scripts/gltf-validate.cjs /usr/local/bin/gltf-validate \
    && install -m 0755 /tmp/modeling-scripts/modeling-smoke-check.sh /usr/local/bin/modeling-smoke-check \
    && install -Dm 0644 /tmp/modeling-scripts/blender-smoke.py /usr/local/share/modeling-tools/blender-smoke.py \
    && rm -rf /tmp/modeling-scripts

COPY workspace-images/modeling-dev/init.d/ /usr/local/share/workspace-init.d/
COPY workspace-images/modeling-dev/system_prompt_extension.txt /usr/local/share/workspace-prompts/30-modeling.txt
COPY workspace-images/modeling-dev/extensions.d/ /usr/local/share/workspace-extensions.d/
COPY workspace-images/modeling-dev/settings.d/ /usr/local/share/workspace-settings.d/
COPY workspace-images/modeling-dev/skills.d/ /usr/local/share/workspace-skills.d/
COPY workspace-images/modeling-dev/skills-install.d/ /usr/local/share/workspace-skills-install.d/
RUN chmod +x /usr/local/share/workspace-init.d/30-modeling.sh

USER coder
# Gate image publication on native dependency import, CAD/PDF/glTF operations,
# and an actual Cycles CPU render using Blender's bundled Python.
RUN modeling-smoke-check --render
