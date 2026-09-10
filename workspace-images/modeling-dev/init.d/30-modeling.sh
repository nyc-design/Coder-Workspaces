#!/usr/bin/env bash
set -euo pipefail

echo '[modeling-dev] Checking headless modeling tools'
modeling-smoke-check
echo '[modeling-dev] Use modeling-smoke-check --render to test Cycles CPU rendering'
