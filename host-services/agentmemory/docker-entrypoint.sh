#!/bin/sh
# agentmemory entrypoint.
#
# Two responsibilities:
#
# 1) Install the right iii-engine config so the worker actually reads it.
#
#    The agentmemory CLI's findIiiConfig (src/cli.ts:172-175 upstream) resolves
#    the iii config from __dirname first — i.e. dist/iii-config.yaml inside the
#    @agentmemory/agentmemory npm package. The bundled file ships with
#    host: 127.0.0.1 and a file-based KV adapter, which is why agentmemory's
#    REST API binds to localhost-only and Upstash silently never engages even
#    when UPSTASH_REDIS_URL is set. Writing our customized yaml to that exact
#    path is the only way iii sees our settings.
#
#    UPSTASH_REDIS_URL set + non-empty → Redis (cross-host durable state)
#    unset / empty                     → file-based (local volume)
#
# 2) Start the MCP-over-HTTP bridge alongside the agentmemory worker.
#
#    Upstream only ships stdio MCP + custom REST endpoints under
#    /agentmemory/mcp/*. Coder Agents (chatd) speaks streamable_http MCP, so we
#    background a tiny Node bridge that translates JSON-RPC → those REST
#    endpoints. SIGTERM/INT is trapped so both processes stop together when
#    `docker stop` propagates the signal through tini.

set -eu

CONFIG_DIR="/opt/agentmemory-config"
TARGET="$(npm root -g)/@agentmemory/agentmemory/dist/iii-config.yaml"
mkdir -p "$(dirname "$TARGET")"

if [ -n "${UPSTASH_REDIS_URL:-}" ]; then
  echo "[agentmemory] UPSTASH_REDIS_URL set — using Upstash Redis backend"
  cp "${CONFIG_DIR}/iii-config.upstash.yaml" "${TARGET}"
else
  echo "[agentmemory] UPSTASH_REDIS_URL unset — using local file-based backend at /data"
  cp "${CONFIG_DIR}/iii-config.file-based.yaml" "${TARGET}"
fi

node /usr/local/bin/mcp-http-bridge.mjs &
BRIDGE_PID=$!
trap 'kill -TERM "$BRIDGE_PID" 2>/dev/null || true' EXIT TERM INT

exec "$@"
