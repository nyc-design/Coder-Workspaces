# syntax=docker/dockerfile:1.7
#
# codexbar — CodexBar CLI `serve` as a lean host service. Codex/Claude usage is
# read straight from their mounted credential files (no CLIs); Alibaba Token
# Plan monthly usage is bridged through the pinned `bl` CLI and stock LLM Proxy
# provider, using the existing Node runtime. Login stays in the workspaces.
#
# Multi-arch: linux/amd64 + linux/arm64. Build context is the repo root so the
# pinned, checksum-verified installer shared with base-dev is reused.

# Stage 1: the installer needs dpkg/curl/sha256sum, which Alpine lacks.
FROM debian:bookworm-slim AS fetch
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY workspace-images/base-dev/scripts/install-codexbar.sh /tmp/install-codexbar.sh
RUN CODEXBAR_INSTALL_PREFIX=/opt/codexbar bash /tmp/install-codexbar.sh

# Stage 2: pinned, checksum-verified Bailian CLI into a relocatable npm prefix
# (Debian: the installer needs GNU sha256sum --check).
FROM node:22-bookworm-slim AS bl
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY workspace-images/base-dev/scripts/install-bailian.sh /tmp/install-bailian.sh
RUN NPM_CONFIG_PREFIX=/opt/bl bash /tmp/install-bailian.sh

# Stage 3: static-musl CodexBar + Node runtime for `bl` (ca-certificates-bundle
# is in the base image and FoundationNetworking needs it for every fetch).
FROM node:22-alpine
ARG CODEXBAR_UID=1000
# CodexBar resolves the Codex/config home from /etc/passwd before $HOME, so the
# service user must have a real passwd entry; UID matches the host secrets
# owner (replaces the image's default `node` user at the same UID).
RUN deluser --remove-home node \
 && adduser -D -u "${CODEXBAR_UID}" -h /home/codexbar codexbar \
 && apk add --no-cache tzdata
COPY --from=fetch /opt/codexbar/lib/codexbar /usr/local/lib/codexbar
COPY --from=bl /opt/bl /usr/local/share/bl
RUN ln -s /usr/local/lib/codexbar/codexbar /usr/local/bin/codexbar \
 && ln -s /usr/local/share/bl/bin/bl /usr/local/bin/bl
COPY host-services/codexbar/*.mjs host-services/codexbar/*.cjs /usr/local/lib/codexbar-bridge/
COPY host-services/codexbar/config.json /etc/codexbar/config.template.json
COPY host-services/codexbar/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

USER codexbar
# The bridge launches `bl` with HOME so it reuses the mounted console session.
ENV HOME=/home/codexbar \
    CODEXBAR_CONFIG=/home/codexbar/.config/codexbar/config.json \
    CODEX_HOME=/home/codexbar/.codex \
    CLAUDE_CONFIG_DIR=/home/codexbar/.claude
VOLUME ["/home/codexbar/.cache"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health >/dev/null && wget -qO- http://127.0.0.1:8081/health >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

LABEL org.opencontainers.image.title="codexbar" \
      org.opencontainers.image.description="CodexBar CLI serve: unified Codex / Claude / Alibaba Token Plan usage dashboard." \
      org.opencontainers.image.source="https://github.com/nyc-design/Coder-Workspaces" \
      org.opencontainers.image.licenses="MIT"
