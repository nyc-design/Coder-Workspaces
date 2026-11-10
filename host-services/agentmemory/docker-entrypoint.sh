#!/bin/sh
# agentmemory entrypoint.
#
# Four responsibilities:
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
# 2) Terminate TLS for Upstash via in-container stunnel.
#
#    iii's vendored redis-rs (v1.0.1, resolved to 1.2.0) is built without
#    `tls-rustls`/`tls-native-tls` features (verified in iii-hq/iii's
#    engine/Cargo.toml across every tagged release including v0.11.7-next.2),
#    so it physically cannot dial `rediss://`. Upstash only offers TLS for
#    the redis wire protocol. We parse the user's `rediss://` URL, point
#    stunnel at the upstream host, listen plain TCP on 127.0.0.1:6379, and
#    hand iii a rewritten `redis://...@127.0.0.1:6379` URL. The AUTH
#    password flows verbatim inside the TLS tunnel.
#
# 3) Start the MCP-over-HTTP bridge alongside the agentmemory worker.
#
#    Upstream only ships stdio MCP + custom REST endpoints under
#    /agentmemory/mcp/*. Coder Agents (chatd) speaks streamable_http MCP, so we
#    background a tiny Node bridge that translates JSON-RPC → those REST
#    endpoints. SIGTERM/INT is trapped so all background processes stop
#    together when `docker stop` propagates the signal through tini.

set -eu

CONFIG_DIR="/opt/agentmemory-config"
TARGET="$(npm root -g)/@agentmemory/agentmemory/dist/iii-config.yaml"
mkdir -p "$(dirname "$TARGET")"

STUNNEL_PID=""

if [ -n "${UPSTASH_REDIS_URL:-}" ]; then
  echo "[agentmemory] UPSTASH_REDIS_URL set — using Upstash Redis backend"
  cp "${CONFIG_DIR}/iii-config.upstash.yaml" "${TARGET}"

  # Parse rediss://user:pass@host:port — strip scheme, split on @ for creds,
  # split host:port. POSIX-compatible parameter expansion; works in dash.
  url_no_scheme="${UPSTASH_REDIS_URL#*://}"
  case "$url_no_scheme" in
    *@*)
      creds="${url_no_scheme%@*}"
      hostport="${url_no_scheme##*@}"
      ;;
    *)
      creds=""
      hostport="$url_no_scheme"
      ;;
  esac
  upstream_host="${hostport%:*}"
  upstream_port="${hostport##*:}"
  case "$hostport" in *:*) ;; *) upstream_port=6379 ;; esac

  cat > /etc/stunnel/upstash.conf <<EOF
foreground = yes
output = /dev/stderr
pid =
[redis]
client = yes
accept = 127.0.0.1:6379
connect = ${upstream_host}:${upstream_port}
verify = 2
CAfile = /etc/ssl/certs/ca-certificates.crt
sni = ${upstream_host}
EOF

  stunnel /etc/stunnel/upstash.conf &
  STUNNEL_PID=$!
  echo "[agentmemory] stunnel → ${upstream_host}:${upstream_port} (pid $STUNNEL_PID)"

  if [ -n "$creds" ]; then
    UPSTASH_REDIS_URL="redis://${creds}@127.0.0.1:6379"
  else
    UPSTASH_REDIS_URL="redis://127.0.0.1:6379"
  fi
  export UPSTASH_REDIS_URL
else
  echo "[agentmemory] UPSTASH_REDIS_URL unset — using local file-based backend at /data"
  cp "${CONFIG_DIR}/iii-config.file-based.yaml" "${TARGET}"
fi

node /usr/local/bin/mcp-http-bridge.mjs &
BRIDGE_PID=$!

# Anything other than the default start command (status, doctor, demo, ...)
# is a one-shot CLI invocation: run it and let the container exit with it.
case "${1:-}:${2:-}" in
  agentmemory:|agentmemory:-*) ;;
  *)
    trap 'kill -TERM "$BRIDGE_PID" "$STUNNEL_PID" 2>/dev/null || true' EXIT TERM INT
    exec "$@"
    ;;
esac

# 4) Supervise the Worker Compose daemon.
#
#    Since agentmemory 0.9.31 the default command spawns `iii compose --up`
#    detached, waits for REST to come up, then process.exit(0)s
#    (dist/cli.mjs, end of the start path). `exec`ing it made PID 1 exit 0
#    seconds after boot, so the container restart-looped and Traefik served
#    404 for the MCP endpoint. Instead we run the CLI to completion (tini, as
#    PID 1, adopts the orphaned daemon), then stay in the foreground polling
#    REST health; sustained failure exits non-zero so the restart policy
#    recovers it. On SIGTERM we stop the compose project gracefully.
HEALTH_URL="${AGENTMEMORY_HEALTH_URL:-http://127.0.0.1:3111/agentmemory/health}"
HEALTH_INTERVAL="${AGENTMEMORY_HEALTH_INTERVAL:-10}"
HEALTH_MAX_FAILURES="${AGENTMEMORY_HEALTH_MAX_FAILURES:-3}"

cleanup() {
  kill -TERM "$BRIDGE_PID" "$STUNNEL_PID" 2>/dev/null || true
}
shutdown() {
  trap - TERM INT
  echo "[agentmemory] stopping Worker Compose project"
  timeout 8 agentmemory stop >/dev/null 2>&1 || true
  exit 0
}
trap cleanup EXIT
trap shutdown TERM INT

"$@"
echo "[agentmemory] supervising Worker Compose (health: ${HEALTH_URL})"

failures=0
while :; do
  # Background sleep + wait so TERM interrupts immediately.
  sleep "$HEALTH_INTERVAL" &
  wait $! || true
  # /agentmemory/health sits behind api-auth: use the configured secret, or
  # the one the CLI generates into ~/.agentmemory/secret when none is set.
  secret="${AGENTMEMORY_SECRET:-$(cat "$HOME/.agentmemory/secret" 2>/dev/null || true)}"
  if curl -fsS -o /dev/null --max-time 5 -H "Authorization: Bearer ${secret}" "$HEALTH_URL"; then
    failures=0
  else
    failures=$((failures + 1))
    echo "[agentmemory] health check failed (${failures}/${HEALTH_MAX_FAILURES})" >&2
    if [ "$failures" -ge "$HEALTH_MAX_FAILURES" ]; then
      echo "[agentmemory] REST unhealthy; exiting so the container restarts" >&2
      exit 1
    fi
  fi
done
