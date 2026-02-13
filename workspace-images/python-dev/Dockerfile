# Extends YOUR base image
FROM ghcr.io/nyc-design/workspace-images/base-dev:latest

USER root

# Python development tools (shared script — single source of truth)
COPY workspace-images/shared/install-python.sh /tmp/install-python.sh
RUN chmod +x /tmp/install-python.sh && /tmp/install-python.sh && rm /tmp/install-python.sh

# Create Python-specific init script
COPY workspace-images/python-dev/python-init.sh /usr/local/share/workspace-init.d/20-python-init.sh
RUN chmod +x /usr/local/share/workspace-init.d/20-python-init.sh

# Set Python environment variables
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
# Configure Poetry for microservices workflow
ENV POETRY_VENV_IN_PROJECT=1
ENV POETRY_CACHE_DIR=/home/coder/.cache/pypoetry

USER coder

# Configure Python user environment
RUN python3 -m pip install --user --no-cache-dir --break-system-packages \
    cookiecutter python-dotenv

# Create common Python directories
RUN mkdir -p /home/coder/.cache/pip
