FROM node:22-slim

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends ca-certificates curl tini git \
 && rm -rf /var/lib/apt/lists/*

# codex-bridge is a single-file Node script; we clone a pinned ref for reproducibility.
# Bump CODEX_BRIDGE_REF to upgrade.
ARG CODEX_BRIDGE_REPO=https://github.com/satriapamudji/codex-bridge.git
ARG CODEX_BRIDGE_REF=main
RUN git clone --depth=1 --branch "${CODEX_BRIDGE_REF}" "${CODEX_BRIDGE_REPO}" /opt/codex-bridge \
 && rm -rf /opt/codex-bridge/.git

RUN useradd --create-home --shell /bin/bash --uid 1000 sidecar \
 && chown -R sidecar:sidecar /opt/codex-bridge
USER sidecar
WORKDIR /opt/codex-bridge

ENV CODEX_BRIDGE_HOST=0.0.0.0 \
    CODEX_BRIDGE_PORT=8080 \
    CODEX_HOME=/home/sidecar/.codex

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "bridge.mjs"]
