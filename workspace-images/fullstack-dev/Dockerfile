# Extends nextjs-dev — inherits all Node.js, npm globals, Playwright, browser deps, ENV vars
FROM ghcr.io/nyc-design/workspace-images/nextjs-dev:latest

USER root

# Add Python (same script used by python-dev — single source of truth)
COPY workspace-images/shared/install-python.sh /tmp/install-python.sh
RUN chmod +x /tmp/install-python.sh && /tmp/install-python.sh && rm /tmp/install-python.sh

# Fullstack-specific Python web packages (not in python-dev)
RUN python3 -m pip install --no-cache-dir --break-system-packages \
    fastapi uvicorn sqlalchemy alembic

# Python ENV vars (same as python-dev)
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV POETRY_VENV_IN_PROJECT=1
ENV POETRY_CACHE_DIR=/home/coder/.cache/pypoetry

# Init scripts: nextjs (20-nextjs-init.sh) already in image from nextjs-dev.
# Add python init + fullstack-only init.
COPY workspace-images/python-dev/python-init.sh /usr/local/share/workspace-init.d/20-python-init.sh
RUN chmod +x /usr/local/share/workspace-init.d/20-python-init.sh
COPY workspace-images/fullstack-dev/fullstack-init.sh /usr/local/share/workspace-init.d/30-fullstack-init.sh
RUN chmod +x /usr/local/share/workspace-init.d/30-fullstack-init.sh

USER coder

# User-level Python tools (same as python-dev)
RUN python3 -m pip install --user --no-cache-dir --break-system-packages \
    cookiecutter python-dotenv

# Create fullstack-specific directories
RUN mkdir -p /home/coder/projects/fullstack \
 && mkdir -p /home/coder/.cache/pip \
 && mkdir -p /home/coder/.cache/pypoetry
