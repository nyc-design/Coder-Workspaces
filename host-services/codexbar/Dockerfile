# syntax=docker/dockerfile:1.7
#
# codexbar — CodexBar CLI `serve` as a lean host service: one static binary,
# no Node, no codex/claude CLIs. Usage is read from the mounted native
# credential dirs (read-only); refresh/login stays in the workspaces.
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

# Stage 2: static-musl binary on Alpine (ca-certificates-bundle is in the base
# image and FoundationNetworking needs it for every provider fetch).
FROM alpine:3.20
ARG CODEXBAR_UID=1000
# CodexBar resolves the Codex/config home from /etc/passwd before $HOME, so the
# service user must have a real passwd entry; UID matches the host secrets owner.
RUN adduser -D -u "${CODEXBAR_UID}" -h /home/codexbar codexbar \
 && apk add --no-cache tzdata
COPY --from=fetch /opt/codexbar/lib/codexbar /usr/local/lib/codexbar
RUN ln -s /usr/local/lib/codexbar/codexbar /usr/local/bin/codexbar
COPY host-services/codexbar/config.json /etc/codexbar/config.template.json
COPY host-services/codexbar/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

USER codexbar
ENV HOME=/home/codexbar \
    CODEXBAR_CONFIG=/home/codexbar/.config/codexbar/config.json \
    CODEX_HOME=/home/codexbar/.codex \
    CLAUDE_CONFIG_DIR=/home/codexbar/.claude \
    CODEXBAR_ALIBABA_REGION=intl-personal
VOLUME ["/home/codexbar/.cache"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

LABEL org.opencontainers.image.title="codexbar" \
      org.opencontainers.image.description="CodexBar CLI serve: unified Codex / Claude / Alibaba Token Plan usage dashboard." \
      org.opencontainers.image.source="https://github.com/nyc-design/Coder-Workspaces" \
      org.opencontainers.image.licenses="MIT"
