#!/bin/sh
# Substitute CLIPROXY_API_KEY into the baked config at startup so the key
# can rotate without rebuilding the image. Then exec the upstream binary.
set -eu

if [ -z "${CLIPROXY_API_KEY:-}" ]; then
  echo "[cliproxy] CLIPROXY_API_KEY env var must be set" >&2
  exit 1
fi

mkdir -p /run/cliproxy /data/auth/cliproxy
sed "s|__CLIPROXY_API_KEY__|${CLIPROXY_API_KEY}|g" \
  /etc/cliproxy/config.yaml > /run/cliproxy/config.yaml

if [ -z "$(ls -A /data/auth/cliproxy 2>/dev/null)" ]; then
  echo "[cliproxy] no credential files in /data/auth/cliproxy" >&2
  echo "[cliproxy] bootstrap with one or both of:" >&2
  echo "  docker exec -it cliproxy cli-proxy-api --auth-dir /data/auth/cliproxy --login codex" >&2
  echo "  docker exec -it cliproxy cli-proxy-api --auth-dir /data/auth/cliproxy --login gemini" >&2
fi

exec cli-proxy-api --config /run/cliproxy/config.yaml
