# Extends YOUR base image
FROM ghcr.io/nyc-design/workspace-images/base-dev:latest

USER root

# Python development tools (shared script — single source of truth)
COPY workspace-images/shared/install-python.sh /tmp/install-python.sh
RUN chmod +x /tmp/install-python.sh && /tmp/install-python.sh && rm /tmp/install-python.sh

# Tier 2 (python) extension manifest, merged with the inherited Tier 1 manifest
# at workspace start by 25-extensions-install.sh and 26-settings-apply.sh.
COPY workspace-images/python-dev/extensions.d/ /usr/local/share/workspace-extensions.d/

# Tier 2 (python) settings manifest
COPY workspace-images/python-dev/settings.d/ /usr/local/share/workspace-settings.d/

# Set Python environment variables
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV UV_CACHE_DIR=/home/coder/.cache/uv

USER coder

# Common cache directories
RUN mkdir -p /home/coder/.cache/pip /home/coder/.cache/uv
