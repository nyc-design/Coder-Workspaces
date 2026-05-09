FROM node:22-slim

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends ca-certificates curl tini \
 && rm -rf /var/lib/apt/lists/*

ARG MERIDIAN_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g \
      "@rynfar/meridian@${MERIDIAN_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

RUN useradd --create-home --shell /bin/bash --uid 1000 sidecar
USER sidecar
WORKDIR /home/sidecar

ENV MERIDIAN_HOST=0.0.0.0 \
    MERIDIAN_PORT=3456 \
    MERIDIAN_PASSTHROUGH=1 \
    CLAUDE_CONFIG_DIR=/home/sidecar/.claude

EXPOSE 3456

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:3456/health || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["meridian"]
