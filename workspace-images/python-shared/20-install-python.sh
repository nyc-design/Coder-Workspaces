#!/usr/bin/env bash
# Shared Python installation script — used by both python-dev and fullstack-dev.
# Run as root inside a Dockerfile: COPY + RUN chmod +x + RUN ./20-install-python.sh
set -eu

echo "[install-python] Installing Python development tools and libraries"

# Python development headers and build dependencies
apt-get update -y && apt-get install -y --no-install-recommends \
  python3-dev python3-setuptools python3-wheel \
  python3-testresources \
&& rm -rf /var/lib/apt/lists/*

# Curated Python tooling — package manager (uv), lint+format (ruff),
# type checker / LSP (basedpyright), unit tests (pytest), interactive REPL.
# Project-specific libraries (numpy, pandas, fastapi, etc.) belong in each
# project's pyproject.toml, not the base image.
python3 -m pip install --no-cache-dir --break-system-packages --ignore-installed \
    uv ruff basedpyright pytest ipython

echo "[install-python] Python installation complete"
