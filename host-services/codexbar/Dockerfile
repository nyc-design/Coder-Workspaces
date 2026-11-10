# syntax=docker/dockerfile:1.7
#
# codexbar — CodexBar CLI `serve` as a lean host service. Codex/Claude usage is
# read from their mounted credential files; Alibaba Token Plan (Personal,
# monthly) is read natively by CodexBar through the pinned `bl` CLI. Login
# stays in the workspaces.
#
# Multi-arch: linux/amd64 + linux/arm64. Build context is the repo root so the
# pinned Bailian installer shared with base-dev is reused.

# Stage 1: pinned, checksum-verified CodexBar release.
# Pinned separately from base-dev (0.84): CodexBar >= 0.72 reads Claude usage
# with `?cedar_ember=1`, which Anthropic rate limits about half the time even at
# one request per five minutes; the plain call 0.71.1 makes is not affected.
# Re-test Claude polling before raising this. Checksums match upstream .sha256.
FROM debian:bookworm-slim AS fetch
ARG TARGETARCH
ARG CODEXBAR_VERSION=0.71.1
ARG CODEXBAR_SHA256_AMD64=030d17d1b6b59937462067518106970778b02ab74d619e09980c03b9e4a44d9f
ARG CODEXBAR_SHA256_ARM64=8562a028b9e304bc934b831d194bf84e528d9eb5ee59f700800a837ae5d7d9ed
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    case "$TARGETARCH" in \
      amd64) platform=x86_64; sha="$CODEXBAR_SHA256_AMD64" ;; \
      arm64) platform=aarch64; sha="$CODEXBAR_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    asset="CodexBarCLI-v${CODEXBAR_VERSION}-linux-musl-${platform}.tar.gz"; \
    curl -fsSL --retry 3 --retry-delay 5 -o "/tmp/$asset" \
      "https://github.com/steipete/CodexBar/releases/download/v${CODEXBAR_VERSION}/${asset}"; \
    echo "$sha  /tmp/$asset" | sha256sum -c -; \
    # Swift resolves resources beside the executable: keep the release together.
    mkdir -p /opt/codexbar/lib/codexbar; \
    tar -xzf "/tmp/$asset" -C /opt/codexbar/lib/codexbar; \
    test "$(cat /opt/codexbar/lib/codexbar/VERSION)" = "$CODEXBAR_VERSION"; \
    rm "/tmp/$asset"

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
 && apk add --no-cache tzdata libgcc libstdc++ \
 && npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force
COPY --from=fetch /opt/codexbar/lib/codexbar /usr/local/lib/codexbar
COPY --from=bl /opt/bl /usr/local/share/bl
RUN ln -s /usr/local/lib/codexbar/codexbar /usr/local/bin/codexbar \
 && ln -s /usr/local/share/bl/bin/bl /usr/local/bin/bl
COPY host-services/codexbar/*.mjs /usr/local/lib/codexbar-bridge/
COPY host-services/codexbar/config.json /etc/codexbar/config.template.json
COPY host-services/codexbar/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

USER codexbar
# Create the cache dir as the service user before VOLUME, so new volumes (and
# empty existing ones) are writable: newer CodexBar releases keep their URL cache here.
RUN mkdir -p /home/codexbar/.cache
# CodexBar launches `bl` with HOME so it reuses the mounted console session.
ENV HOME=/home/codexbar \
    CODEXBAR_CONFIG=/home/codexbar/.config/codexbar/config.json \
    CODEX_HOME=/home/codexbar/.codex \
    CLAUDE_CONFIG_DIR=/home/codexbar/.claude
VOLUME ["/home/codexbar/.cache"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

LABEL org.opencontainers.image.title="codexbar" \
      org.opencontainers.image.description="CodexBar CLI serve: unified Codex / Claude / Alibaba Token Plan usage dashboard." \
      org.opencontainers.image.source="https://github.com/nyc-design/Coder-Workspaces" \
      org.opencontainers.image.licenses="MIT"
