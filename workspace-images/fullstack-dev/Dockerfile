# Extends vite-dev — inherits all Node.js, npm globals, Playwright, browser deps, ENV vars
FROM ghcr.io/nyc-design/workspace-images/vite-dev:latest

USER root

# Add Python (same script used by python-dev — single source of truth)
COPY workspace-images/shared/install-python.sh /tmp/install-python.sh
RUN chmod +x /tmp/install-python.sh && /tmp/install-python.sh && rm /tmp/install-python.sh

# Python ENV vars (same as python-dev)
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV UV_CACHE_DIR=/home/coder/.cache/uv

# Python Tier 2 manifests. The frontend Tier 2 manifests are already inherited
# from the vite-dev image layer; only the python ones need an explicit COPY
# here because fullstack-dev does not derive from python-dev.
COPY workspace-images/python-dev/extensions.d/ /usr/local/share/workspace-extensions.d/
COPY workspace-images/python-dev/settings.d/   /usr/local/share/workspace-settings.d/

# Fullstack-specific system prompt extension. Stacks on top of the inherited
# vite-dev prompt extension (already at 20-vite.txt from the parent image).
COPY workspace-images/fullstack-dev/system_prompt_extension.txt /usr/local/share/workspace-prompts/30-fullstack.txt

USER coder

# Create fullstack-specific directories
RUN mkdir -p /home/coder/projects/fullstack \
 && mkdir -p /home/coder/.cache/pip \
 && mkdir -p /home/coder/.cache/uv
