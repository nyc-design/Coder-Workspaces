# Extends YOUR base image
ARG BASE_IMAGE=us-central1-docker.pkg.dev/coder-nt/workspace-images/base-dev:latest
FROM ${BASE_IMAGE}

USER root

# Python development tools and linters
RUN apt-get update -y && apt-get install -y --no-install-recommends \
  python3-dev python3-setuptools python3-wheel \
  python3-testresources \
&& rm -rf /var/lib/apt/lists/*

# Install Python development tools and linters
RUN python3 -m pip install --no-cache-dir --break-system-packages \
  # Core development tools
  poetry pipenv virtualenv \
  # Linters and formatters
  black isort flake8 pylint mypy bandit \
  # Testing tools
  pytest pytest-cov coverage pre-commit \
  # Scientific libraries
  requests numpy pandas matplotlib seaborn \
  # Jupyter and notebooks
  jupyter jupyterlab notebook \
  # Type stubs
  types-requests types-setuptools \
  # Documentation
  sphinx sphinx-rtd-theme \
  # Additional testing frameworks
  pytest-xdist pytest-mock \
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
