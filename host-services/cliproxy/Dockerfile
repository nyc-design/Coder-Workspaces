# syntax=docker/dockerfile:1.7
#
# cliproxy — CLIProxyAPI baked with our config so the bare VM only needs
# the compose snippet (no host-side config.yaml to maintain).
#
# Wraps the upstream Go binary
# (https://github.com/router-for-me/CLIProxyAPI). Single process serves
# Codex (ChatGPT Plus/Pro OAuth), Gemini (personal Google OAuth), and
# Claude Code (Anthropic OAuth) from the same auth-dir; the upstream
# auto-detects which credentials are
# present and serves whichever endpoints have valid auth.
#
# Multi-arch: linux/amd64 + linux/arm64.

FROM debian:bookworm-slim

ARG TARGETARCH

# Pin the upstream release. Bump in PRs and let watchtower roll the new
# image out — no runtime version drift on the VM.
ARG CLI_PROXY_API_VERSION=v7.1.54

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

# Asset filename pattern (verified against v6.10.9):
#   CLIProxyAPI_<version-no-v>_linux_<arch>.tar.gz
# where <arch> is `amd64` or `aarch64`. Tarball contains a `cli-proxy-api`
# binary at top level.
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) ARCH=amd64 ;; \
      arm64) ARCH=aarch64 ;; \
      *) echo "unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac; \
    VERSION_NO_V="${CLI_PROXY_API_VERSION#v}"; \
    cd /tmp; \
    curl -fsSL -o cli-proxy.tar.gz \
      "https://github.com/router-for-me/CLIProxyAPI/releases/download/${CLI_PROXY_API_VERSION}/CLIProxyAPI_${VERSION_NO_V}_linux_${ARCH}.tar.gz"; \
    tar -xzf cli-proxy.tar.gz cli-proxy-api; \
    install -m 0755 cli-proxy-api /usr/local/bin/cli-proxy-api; \
    rm -f /tmp/cli-proxy.tar.gz /tmp/cli-proxy-api

# Bake the config so the VM doesn't need to mount one. OAuth credentials are
# still on the named volume (mounted at /data/auth/cliproxy by compose). The
# entrypoint substitutes the API key from env at startup so it can rotate
# without rebuilding the image.
COPY config.yaml /etc/cliproxy/config.yaml
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

VOLUME ["/data/auth"]

EXPOSE 8317

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl --fail --silent -o /dev/null http://127.0.0.1:8317/health || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]

LABEL org.opencontainers.image.title="cliproxy" \
      org.opencontainers.image.description="CLIProxyAPI built from upstream release with config baked in. Codex (ChatGPT Plus/Pro) + Gemini (personal Google) + Claude Code OAuth in one process." \
      org.opencontainers.image.source="https://github.com/nyc-design/Coder-Workspaces" \
      org.opencontainers.image.licenses="MIT"
