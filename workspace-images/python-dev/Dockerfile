# Extends YOUR base image
ARG BASE_IMAGE=us-central1-docker.pkg.dev/coder-nt/workspace-images/base-dev:latest
FROM ${BASE_IMAGE}

USER root

# Python development tools and linters
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    python3-dev python3-setuptools python3-wheel \
    python3-testresources \
 && rm -rf /var/lib/apt/lists/*

# Install common Python packages and linters via pip (break system packages for Docker)
RUN python3 -m pip install --no-cache-dir --break-system-packages \
    # Core development tools (Poetry first for microservices)
    poetry pipenv virtualenv \
    # Linters and formatters
    black isort flake8 pylint mypy bandit \
    # Code quality tools
    pytest pytest-cov coverage pre-commit \
    # Popular libraries
    requests numpy pandas matplotlib seaborn \
    jupyter jupyterlab notebook \
    # Type checking and stub packages
    types-requests types-setuptools

# Install additional development tools (avoid packages that conflict with system packages)
RUN python3 -m pip install --no-cache-dir --break-system-packages \
    # Documentation
    sphinx sphinx-rtd-theme \
    # Testing frameworks
    pytest-xdist pytest-mock pytest-asyncio \
    # Modern testing tools
    respx testcontainers pydantic-factories \
    # Development utilities
    ipython ipdb pdbpp \
    # Package management
    twine build

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
    # User-level tools that might conflict with system packages
    cookiecutter python-dotenv

# Create common Python directories
RUN mkdir -p /home/coder/.cache/pip