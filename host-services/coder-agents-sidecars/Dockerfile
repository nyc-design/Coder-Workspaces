# syntax=docker/dockerfile:1.7
#
# Single-image Coder Agents subscription-auth stack:
#   port 8787 → headroom (compression proxy, only externally-exposed listener)
#   ↳ 127.0.0.1:3456 → claude-sidecar    (Meridian + Claude Code SDK)
#   ↳ 127.0.0.1:8317 → cliproxy-sidecar  (CLIProxyAPI: Codex + Gemini OAuth)
#
# All three processes are supervised by s6-overlay v3. The image is multi-arch
# (linux/amd64 + linux/arm64) and built by .github/workflows/build-coder-agents-sidecars.yaml.

FROM node:22-bookworm-slim

ARG TARGETARCH
ARG TARGETOS=linux

# ── system deps + s6-overlay ──────────────────────────────────────────────────
ARG S6_OVERLAY_VERSION=3.2.0.2
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils tini unzip \
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

# ── Headroom + dispatcher (shared Python venv) ───────────────────────────────
# Local rule-based + ONNX compression. Bundles RTK for shell-output rewriting.
# Same venv hosts the dispatcher (Starlette + httpx + secret-manager).
# No torch/LLMLingua-2 to keep image lean — rebuild with [proxy,ml] if needed.
RUN python3 -m venv /opt/headroom-venv \
 && /opt/headroom-venv/bin/pip install --no-cache-dir 'headroom-ai[proxy]'
COPY host-services/coder-agents-sidecars/dispatcher/requirements.txt \
     /tmp/dispatcher-requirements.txt
RUN /opt/headroom-venv/bin/pip install --no-cache-dir -r /tmp/dispatcher-requirements.txt \
 && rm -f /tmp/dispatcher-requirements.txt
COPY host-services/coder-agents-sidecars/dispatcher/dispatcher.py \
     host-services/coder-agents-sidecars/dispatcher/bootstrap_secrets.py \
     /usr/local/lib/coder-agents-sidecars/

# ── kirocc binary (Kiro Builder ID → Anthropic Messages proxy) ───────────────
ARG KIROCC_VERSION=v0.1.0
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) ARCH=amd64 ;; \
      arm64) ARCH=arm64 ;; \
      *) echo "unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac; \
    VERSION_NO_V="${KIROCC_VERSION#v}"; \
    cd /tmp; \
    curl -fsSLo kirocc.tar.gz \
      "https://github.com/d-kuro/kirocc/releases/download/${KIROCC_VERSION}/kirocc_${VERSION_NO_V}_linux_${ARCH}.tar.gz"; \
    tar -xzf kirocc.tar.gz kirocc; \
    install -m 0755 kirocc /usr/local/bin/kirocc; \
    rm -f /tmp/kirocc.tar.gz /tmp/kirocc

# ── Amazon Q / Kiro CLI binary (writes kirocc's OAuth SQLite via `q login`) ──
# kirocc has no login flow; it reads tokens from a SQLite database that the
# upstream Amazon Q / Kiro CLI writes (same fig_auth schema in both). The
# branded `kiro-cli.deb` is amd64-only as of 2026-05 and drags in
# libayatana-appindicator3-1 / libwebkit2gtk-4.1-0 / libgtk-3-0 for its
# chat/desktop/term sibling binaries — none of which are needed for the
# login flow. The static musl `q` build covers both archs in ~100 MB with
# zero runtime deps. Only `q` is installed (qchat/qterm are stripped).
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) Q_ARCH=x86_64 ;; \
      arm64) Q_ARCH=aarch64 ;; \
      *) echo "unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSLo q.zip \
      "https://desktop-release.q.us-east-1.amazonaws.com/latest/q-${Q_ARCH}-linux-musl.zip"; \
    unzip -q q.zip 'q/bin/q'; \
    install -m 0755 q/bin/q /usr/local/bin/q; \
    rm -rf /tmp/q /tmp/q.zip
COPY host-services/coder-agents-sidecars/kirocc-sidecar/kiro-auth-login \
     /usr/local/bin/kiro-auth-login
RUN chmod +x /usr/local/bin/kiro-auth-login

# ── CLIProxyAPI binary (Codex + Gemini sidecar engine) ───────────────────────
# Asset filename pattern (verified against v6.10.9):
#   CLIProxyAPI_<version>_linux_<arch>.tar.gz
# where <version> is without the leading 'v', and <arch> is amd64 or aarch64.
# Tarball contains a `cli-proxy-api` (lowercase) binary at top level.
ARG CLI_PROXY_API_VERSION=v6.10.9
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) ARCH=amd64 ;; \
      arm64) ARCH=aarch64 ;; \
      *) echo "unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac; \
    VERSION_NO_V="${CLI_PROXY_API_VERSION#v}"; \
    cd /tmp; \
    curl -fsSLo cli-proxy.tar.gz \
      "https://github.com/router-for-me/CLIProxyAPI/releases/download/${CLI_PROXY_API_VERSION}/CLIProxyAPI_${VERSION_NO_V}_linux_${ARCH}.tar.gz"; \
    tar -xzf cli-proxy.tar.gz cli-proxy-api; \
    install -m 0755 cli-proxy-api /usr/local/bin/cli-proxy-api; \
    rm -f /tmp/cli-proxy.tar.gz /tmp/cli-proxy-api

# ── Node tools: Meridian + Claude Code SDK ───────────────────────────────────
# (Bootstrap CLIs for Codex and Gemini are inside cli-proxy-api itself —
# `cli-proxy-api --login codex|gemini` covers both.)
ARG MERIDIAN_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g \
      "@rynfar/meridian@${MERIDIAN_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

# ── configs + s6 service definitions ─────────────────────────────────────────
COPY host-services/coder-agents-sidecars/cliproxy-sidecar/config.yaml \
     /etc/coder-agents-sidecars/cli-proxy.yaml
COPY host-services/coder-agents-sidecars/s6/ /etc/s6-overlay/s6-rc.d/
RUN chmod +x \
      /etc/s6-overlay/s6-rc.d/headroom/run \
      /etc/s6-overlay/s6-rc.d/claude-sidecar/run \
      /etc/s6-overlay/s6-rc.d/cliproxy-sidecar/run \
      /etc/s6-overlay/s6-rc.d/dispatcher/run \
      /etc/s6-overlay/s6-rc.d/kirocc/run

# Pre-create auth subdirs so first-start doesn't trip on missing paths.
RUN mkdir -p /data/auth/cliproxy /data/auth/claude /data/auth/kirocc /run/coder-agents-sidecars

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
    ANTHROPIC_TARGET_API_URL=http://127.0.0.1:8788 \
    OPENAI_TARGET_API_URL=http://127.0.0.1:8317 \
    GEMINI_TARGET_API_URL=http://127.0.0.1:8317 \
    CLOUDCODE_TARGET_API_URL=http://127.0.0.1:8317 \
    \
    DISPATCHER_HOST=127.0.0.1 \
    DISPATCHER_PORT=8788 \
    SIDECAR_GCP_PROJECT=ai-sidecar-nt \
    \
    MERIDIAN_HOST=127.0.0.1 \
    MERIDIAN_PORT=3456 \
    MERIDIAN_PASSTHROUGH=1 \
    CLAUDE_CONFIG_DIR=/data/auth/claude

VOLUME ["/data/auth"]
# 8787 is Headroom (Claude/Codex/Gemini). 8788 is the dispatcher (OpenAI-compat
# direct + Claude fan-out). Both are routed to from Traefik; bind to all
# interfaces inside the container but never publish to the host.
EXPOSE 8787 8788

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:8787/readyz || exit 1

LABEL org.opencontainers.image.title="coder-agents-sidecars" \
      org.opencontainers.image.description="Subscription-auth sidecars (Claude Code via Meridian + Codex/Gemini via CLIProxyAPI) with Headroom compression for Coder Agents." \
      org.opencontainers.image.source="https://github.com/nyc-design/Coder-Workspaces" \
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/init"]
