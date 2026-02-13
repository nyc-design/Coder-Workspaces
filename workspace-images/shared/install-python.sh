#!/usr/bin/env bash
# Shared Python installation script — used by both python-dev and fullstack-dev.
# Run as root inside a Dockerfile: COPY + RUN chmod +x + RUN ./install-python.sh
set -eu

echo "[install-python] Installing Python development tools and libraries"

# Python development headers and build dependencies
apt-get update -y && apt-get install -y --no-install-recommends \
  python3-dev python3-setuptools python3-wheel \
  python3-testresources \
&& rm -rf /var/lib/apt/lists/*

# Essential development tools
python3 -m pip install --no-cache-dir --break-system-packages \
    pipenv virtualenv

# Linters and formatters
python3 -m pip install --no-cache-dir --break-system-packages \
    black isort flake8 pylint mypy bandit

# Testing tools
python3 -m pip install --no-cache-dir --break-system-packages \
    pytest pytest-cov coverage pre-commit \
    pytest-xdist pytest-mock

# Scientific libraries and data tools
python3 -m pip install --no-cache-dir --break-system-packages \
    requests numpy pandas matplotlib seaborn \
    types-requests types-setuptools

# Jupyter and development utilities
python3 -m pip install --no-cache-dir --break-system-packages \
    jupyter jupyterlab notebook \
    ipython ipdb pdbpp

# Documentation and packaging tools
python3 -m pip install --no-cache-dir --break-system-packages \
    sphinx sphinx-rtd-theme \
    twine build

# Poetry (--ignore-installed to avoid platformdirs conflict)
python3 -m pip install --no-cache-dir --break-system-packages --ignore-installed poetry

echo "[install-python] Python installation complete"
