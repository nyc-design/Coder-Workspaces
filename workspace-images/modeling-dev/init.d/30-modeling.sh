#!/usr/bin/env bash
set -euo pipefail

blender --background --factory-startup --python-exit-code 1 \
    --python /usr/local/share/modeling-tools/modeling-safe-defaults.py

echo '[modeling-dev] Checking headless modeling tools'
modeling-smoke-check
echo '[modeling-dev] Use modeling-smoke-check --render to test Cycles CPU rendering'
