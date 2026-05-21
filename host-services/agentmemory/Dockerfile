# syntax=docker/dockerfile:1.7
#
# agentmemory — persistent memory backend for Coder workspaces.
#
# Bundles two pieces of upstream into one image:
#   1. iii-engine binary (https://github.com/iii-hq/iii) — the function/state/
#      pubsub runtime that agentmemory's workers register against
#   2. @agentmemory/agentmemory npm package — the memory engine itself
#      (REST on :3111, viewer on :3113, streams on :3112, iii bridge on :49134)
#
# Why bundle: agentmemory's own docker-compose.yml only ships the iii engine
# image (iiidev/iii) and assumes you've cloned the repo and run `npm run
# build` so dist/index.mjs exists for iii-exec to spawn. We need a single
# self-contained image so watchtower can update it like every other backend.
#
# Storage backend is chosen at startup by docker-entrypoint.sh based on
# whether UPSTASH_REDIS_URL is set. Both iii-config variants ship in
# /opt/agentmemory-config/ — no image rebuild to flip backends.
#
# Multi-arch: linux/amd64 + linux/arm64 (matches Coder VM targets).

FROM node:20-bookworm-slim

ARG TARGETARCH

# Pinned to the version agentmemory currently supports. Per upstream README,
# v0.11.6+ requires agentmemory to refactor for the sandbox-everything model
# and is not compatible yet. Bump only after agentmemory upstream lifts the pin.
ARG III_VERSION=v0.11.2
ARG AGENTMEMORY_VERSION=0.9.21

# stunnel4 terminates TLS for `rediss://` Upstash endpoints. iii's vendored
# redis crate (v1.0.1) is built without `tls-rustls` / `tls-native-tls`, so
# it cannot dial `rediss://` directly. The entrypoint starts stunnel
# listening on 127.0.0.1:6379 and rewrites UPSTASH_REDIS_URL to a plain
# `redis://...@127.0.0.1:6379` before iii reads its config.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates tini stunnel4 \
 && rm -rf /var/lib/apt/lists/*

# ── iii-engine binary (Rust, statically linked, includes rustls for TLS) ─────
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) IIIBIN=iii-x86_64-unknown-linux-gnu ;; \
      arm64) IIIBIN=iii-aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/iii-hq/iii/releases/download/iii/${III_VERSION}/${IIIBIN}.tar.gz" \
      | tar -xz -C /usr/local/bin; \
    chmod +x /usr/local/bin/iii; \
    iii --version

# ── agentmemory CLI + worker (Node, ships its own dist/index.mjs for iii-exec) ──
# @xenova/transformers is an optional peer dep that powers local semantic
# embeddings (all-MiniLM-L6-v2), the second-stage reranker
# (ms-marco-MiniLM-L-6-v2), and CLIP-based image embeddings. Installing it
# alongside agentmemory in the global node_modules tree lets the dynamic
# `await import("@xenova/transformers")` calls in upstream/src/embeddings/*.ts
# resolve at runtime. Model weights (~300 MB across the three models) download
# lazily on first use into HF_HOME (pinned to /data below so they survive
# image swaps via the named volume).
RUN npm install -g \
      "@agentmemory/agentmemory@${AGENTMEMORY_VERSION}" \
      @xenova/transformers \
 && npm cache clean --force

# Both iii-config variants live in /opt/agentmemory-config/. The entrypoint
# copies the right one to the npm package's dist/iii-config.yaml at startup,
# because that is the path findIiiConfig (src/cli.ts:172-175 upstream)
# resolves first — writing anywhere else is silently ignored.
COPY iii-config.file-based.yaml iii-config.upstash.yaml /opt/agentmemory-config/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY mcp-http-bridge.mjs /usr/local/bin/mcp-http-bridge.mjs
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/mcp-http-bridge.mjs

# Persistent state lives on the named volume mounted at /data:
#   /data/state_store.db   — kv (sessions, memories, lifecycle timers)
#   /data/stream_store/    — pubsub stream offsets
#   /data/.agentmemory/    — embeddings index, viewer assets cache
# (When UPSTASH_REDIS_URL is set, state/stream/cron live in Redis instead;
# only the embeddings index + viewer cache stay on /data.)
# HF_HOME / TRANSFORMERS_CACHE point @xenova/transformers at the persistent
# /data volume so HuggingFace model weights download once and survive image
# swaps. (Defaults derived from HOME=/data would land under /data/.cache
# anyway, but pinning them explicitly makes the contract loud — see
# host-services/agentmemory/README.md "Features enabled".)
ENV HOME=/data \
    AGENTMEMORY_HOST=0.0.0.0 \
    AGENTMEMORY_VIEWER_HOST=0.0.0.0 \
    HF_HOME=/data/.cache/huggingface \
    TRANSFORMERS_CACHE=/data/.cache/huggingface
VOLUME ["/data"]

# 3111 REST API · 3112 streams (WS) · 3113 viewer · 3114 MCP streamable_http bridge · 49134 iii bridge (WS)
EXPOSE 3111 3112 3113 3114 49134

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:3111/agentmemory/health || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["agentmemory"]

LABEL org.opencontainers.image.title="agentmemory" \
      org.opencontainers.image.description="Persistent memory backend (iii-engine + @agentmemory/agentmemory) baked into one image for Coder workspaces." \
      org.opencontainers.image.source="https://github.com/nyc-design/Coder-Workspaces" \
      org.opencontainers.image.licenses="Apache-2.0"
