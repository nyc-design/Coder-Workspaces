# syntax=docker/dockerfile:1.7
#
# Single-image Coder Agents subscription-auth stack:
#   port 8787 → headroom (compression proxy, only externally-exposed listener)
#   ↳ 127.0.0.1:3456 → claude-sidecar (Meridian + Claude Code SDK)
#   ↳ 127.0.0.1:8080 → codex-sidecar  (codex-bridge)
#   ↳ 127.0.0.1:8317 → gemini-sidecar (CLIProxyAPI, Gemini-only)
#
# All four processes are supervised by s6-overlay v3. The image is multi-arch
# (linux/amd64 + linux/arm64) and built by .github/workflows/build-coder-agents-sidecars.yaml.

FROM node:22-bookworm-slim

ARG TARGETARCH
ARG TARGETOS=linux

# ── system deps + s6-overlay ──────────────────────────────────────────────────
ARG S6_OVERLAY_VERSION=3.2.0.2
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils tini git \
      python3 python3-pip python3-venv \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    case "$TARGETARCH" in \
      amd64) S6_ARCH=x86_64 ;; \
      arm64) S6_ARCH=aarch64 ;; \
      *) echo "unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/s6-noarch.tar.xz \
      "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz"; \
    tar -C / -Jxpf /tmp/s6-noarch.tar.xz; \
    curl -fsSLo /tmp/s6-arch.tar.xz \
      "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz"; \
    tar -C / -Jxpf /tmp/s6-arch.tar.xz; \
    rm -f /tmp/s6-*.tar.xz

# ── Headroom (Python venv) ────────────────────────────────────────────────────
# Local rule-based + ONNX compression. No torch/LLMLingua to keep image lean.
RUN python3 -m venv /opt/headroom-venv \
 && /opt/headroom-venv/bin/pip install --no-cache-dir 'headroom-ai[proxy]'

# ── CLIProxyAPI binary (Gemini sidecar engine) ───────────────────────────────
ARG CLI_PROXY_API_VERSION=v6.10.9
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) ARCH=amd64 ;; \
      arm64) ARCH=arm64 ;; \
      *) echo "unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac; \
    cd /tmp; \
    # Try both common asset name patterns; CLIProxyAPI has switched between them.
    (curl -fsSLo cli-proxy.tar.gz "https://github.com/router-for-me/CLIProxyAPI/releases/download/${CLI_PROXY_API_VERSION}/CLIProxyAPI_${TARGETOS}_${ARCH}.tar.gz" \
      || curl -fsSLo cli-proxy.tar.gz "https://github.com/router-for-me/CLIProxyAPI/releases/download/${CLI_PROXY_API_VERSION}/CLIProxyAPI-${TARGETOS}-${ARCH}.tar.gz"); \
    tar -xzf cli-proxy.tar.gz; \
    install -m 0755 CLIProxyAPI /usr/local/bin/cli-proxy-api; \
    rm -rf /tmp/cli-proxy.tar.gz /tmp/CLIProxyAPI

# ── Node tools: Meridian, Claude Code SDK, Codex CLI (for bootstrap) ─────────
ARG MERIDIAN_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest
ARG OPENAI_CODEX_VERSION=latest
RUN npm install -g \
      "@rynfar/meridian@${MERIDIAN_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@openai/codex@${OPENAI_CODEX_VERSION}" \
 && npm cache clean --force

# ── codex-bridge (single-file Node script) ───────────────────────────────────
ARG CODEX_BRIDGE_REF=main
RUN git clone --depth=1 --branch "${CODEX_BRIDGE_REF}" \
      https://github.com/satriapamudji/codex-bridge.git /opt/codex-bridge \
 && rm -rf /opt/codex-bridge/.git

# ── configs + s6 service definitions ─────────────────────────────────────────
COPY host-services/coder-agents-sidecars/gemini-sidecar/config.yaml \
     /etc/coder-agents-sidecars/cli-proxy.yaml
COPY host-services/coder-agents-sidecars/s6/ /etc/s6-overlay/s6-rc.d/
RUN chmod +x \
      /etc/s6-overlay/s6-rc.d/headroom/run \
      /etc/s6-overlay/s6-rc.d/claude-sidecar/run \
      /etc/s6-overlay/s6-rc.d/codex-sidecar/run \
      /etc/s6-overlay/s6-rc.d/gemini-sidecar/run

# Pre-create per-CLI auth subdirs so first-start doesn't trip on missing paths.
RUN mkdir -p /data/auth/codex /data/auth/gemini /data/auth/claude /run/coder-agents-sidecars

# ── runtime defaults ─────────────────────────────────────────────────────────
ENV S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_VERBOSITY=1 \
    \
    HEADROOM_HOST=0.0.0.0 \
    HEADROOM_PORT=8787 \
    HEADROOM_MODE=token \
    HEADROOM_STATELESS=true \
    HEADROOM_TELEMETRY=off \
    ANTHROPIC_TARGET_API_URL=http://127.0.0.1:3456 \
    OPENAI_TARGET_API_URL=http://127.0.0.1:8080 \
    GEMINI_TARGET_API_URL=http://127.0.0.1:8317 \
    CLOUDCODE_TARGET_API_URL=http://127.0.0.1:8317 \
    \
    MERIDIAN_HOST=127.0.0.1 \
    MERIDIAN_PORT=3456 \
    MERIDIAN_PASSTHROUGH=1 \
    CLAUDE_CONFIG_DIR=/data/auth/claude \
    \
    CODEX_BRIDGE_HOST=127.0.0.1 \
    CODEX_BRIDGE_PORT=8080 \
    CODEX_HOME=/data/auth/codex

VOLUME ["/data/auth"]
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:8787/readyz || exit 1

LABEL org.opencontainers.image.title="coder-agents-sidecars" \
      org.opencontainers.image.description="Subscription-auth sidecars (Claude Code / Codex / Gemini) + Headroom compression for Coder Agents." \
      org.opencontainers.image.source="https://github.com/nyc-design/Coder-Workspaces" \
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/init"]
