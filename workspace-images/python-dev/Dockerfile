# Extends YOUR base image
FROM ghcr.io/nyc-design/workspace-images/base-dev:latest

USER root

# Python development tools (shared script — single source of truth)
COPY workspace-images/python-shared/scripts/install-python.sh /tmp/install-python.sh
RUN chmod +x /tmp/install-python.sh && /tmp/install-python.sh && rm /tmp/install-python.sh

# Shared Python contributions. Keep Python-specific scripts/manifests here so
# python-dev and fullstack-dev both consume the same source without relying on
# Docker inheritance (fullstack extends vite-dev, then adds Python).
COPY workspace-images/python-shared/init.d/                     /usr/local/share/workspace-init.d/
COPY workspace-images/python-shared/system_prompt_extension.txt /usr/local/share/workspace-prompts/20-python.txt
COPY workspace-images/python-shared/extensions.d/               /usr/local/share/workspace-extensions.d/
COPY workspace-images/python-shared/settings.d/                 /usr/local/share/workspace-settings.d/
COPY workspace-images/python-shared/skills.d/                   /usr/local/share/workspace-skills.d/
COPY workspace-images/python-shared/skills-install.d/           /usr/local/share/workspace-skills-install.d/

# Layered workspace contributions (all optional; source paths exist so COPYs
# stay stable as this image grows).
COPY workspace-images/python-dev/init.d/                     /usr/local/share/workspace-init.d/
COPY workspace-images/python-dev/system_prompt_extension.txt /usr/local/share/workspace-prompts/21-python-dev.txt
COPY workspace-images/python-dev/extensions.d/               /usr/local/share/workspace-extensions.d/
COPY workspace-images/python-dev/settings.d/                 /usr/local/share/workspace-settings.d/
COPY workspace-images/python-dev/skills.d/                   /usr/local/share/workspace-skills.d/
COPY workspace-images/python-dev/skills-install.d/           /usr/local/share/workspace-skills-install.d/
RUN find /usr/local/share/workspace-init.d -type f -name '*.sh' -exec chmod +x {} +

# Set Python environment variables
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV UV_CACHE_DIR=/home/coder/.cache/uv

USER coder

# Common cache directories
RUN mkdir -p /home/coder/.cache/pip /home/coder/.cache/uv
