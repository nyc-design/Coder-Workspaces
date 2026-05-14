#!/bin/sh
# agentmemory entrypoint: pick file-based or Upstash iii config at startup.
#
# Why a runtime picker rather than separate images: deploy can flip storage
# backends with one env var change and `docker restart agentmemory`, no
# image rebuild. Both configs ship in /opt/agentmemory-config/ so the
# choice is trivial.
#
# UPSTASH_REDIS_URL set + non-empty → Redis (cross-host durable state)
# unset / empty                     → file-based (local volume)
set -eu

CONFIG_DIR="/opt/agentmemory-config"
TARGET="${HOME}/.agentmemory/iii-config.yaml"
mkdir -p "$(dirname "$TARGET")"

if [ -n "${UPSTASH_REDIS_URL:-}" ]; then
  echo "[agentmemory] UPSTASH_REDIS_URL set — using Upstash Redis backend"
  cp "${CONFIG_DIR}/iii-config.upstash.yaml" "${TARGET}"
else
  echo "[agentmemory] UPSTASH_REDIS_URL unset — using local file-based backend at /data"
  cp "${CONFIG_DIR}/iii-config.file-based.yaml" "${TARGET}"
fi

exec "$@"
