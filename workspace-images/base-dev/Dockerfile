FROM codercom/enterprise-base:ubuntu-20250929
ARG DEBIAN_FRONTEND=noninteractive

USER root

# Core deps + Python + build tools
# bubblewrap + uidmap are required by Codex's sandboxed exec (newuidmap/newgidmap).
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    ca-certificates curl git bash-completion \
    python3 python3-pip python3-venv build-essential \
    tree ripgrep fd-find \
    bubblewrap uidmap \
    pre-commit httpie direnv \
 && rm -rf /var/lib/apt/lists/*

# Google Cloud CLI (modern method + single RUN per Google's Docker tip)
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list \
 && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
 && apt-get update -y \
 && apt-get install -y --no-install-recommends google-cloud-cli \
     google-cloud-cli-gke-gcloud-auth-plugin kubectl \
     google-cloud-cli-skaffold google-cloud-cli-minikube \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update -y && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Node.js 20 + pnpm
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update -y && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# Shared global npm install location (single path for image + runtime installs)
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=/usr/local/share/npm-global/bin:$PATH
RUN install -d -m 0775 -o coder -g coder /usr/local/share/npm-global

# AI coding CLIs + docs/tooling ecosystem
RUN npm install -g pnpm @openai/codex @anthropic-ai/claude-code @google/gemini-cli @twsxtd/hapi likec4 skills tree-sitter-cli @pencil.dev/cli @_davideast/stitch-mcp gitnexus @samuelfaj/distill ctx7 \
 && chown -R coder:coder /usr/local/share/npm-global

# RTK (Reducer ToolKit) — LLM context optimizer via command output reduction
# Install to /usr/local/bin for system-wide availability across all agents
RUN ARCH=$(uname -m) \
 && if [ "$ARCH" = "x86_64" ]; then \
      RTK_ASSETS="rtk-x86_64-unknown-linux-musl.tar.gz rtk-x86_64-unknown-linux-gnu.tar.gz"; \
    elif [ "$ARCH" = "aarch64" ]; then \
      RTK_ASSETS="rtk-aarch64-unknown-linux-gnu.tar.gz rtk-aarch64-unknown-linux-musl.tar.gz"; \
    else \
      echo "Unsupported architecture for RTK: $ARCH" >&2; \
      exit 1; \
    fi \
 && for asset in $RTK_ASSETS; do \
      url="https://github.com/rtk-ai/rtk/releases/latest/download/${asset}"; \
      if curl -fsI "$url" >/dev/null; then \
        RTK_URL="$url"; \
        break; \
      fi; \
    done \
 && test -n "${RTK_URL:-}" \
 && curl -fsSL "$RTK_URL" | tar xz -C /usr/local/bin/ \
 && chmod +x /usr/local/bin/rtk

# just (command runner) + just-lsp (language server for VS Code)
RUN JUST_VERSION=$(curl -s "https://api.github.com/repos/casey/just/releases/latest" | grep -Po '"tag_name": "\K[^"]*') \
 && ARCH=$(uname -m) \
 && curl -Lo just.tar.gz "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-${ARCH}-unknown-linux-musl.tar.gz" \
 && tar xf just.tar.gz just \
 && install just -D -t /usr/local/bin/ \
 && rm just just.tar.gz \
 && JUSTLSP_VERSION=$(curl -s "https://api.github.com/repos/terror/just-lsp/releases/latest" | grep -Po '"tag_name": "\K[^"]*') \
 && curl -Lo just-lsp.tar.gz "https://github.com/terror/just-lsp/releases/download/${JUSTLSP_VERSION}/just-lsp-${JUSTLSP_VERSION}-${ARCH}-unknown-linux-musl.tar.gz" \
 && tar xf just-lsp.tar.gz ./just-lsp \
 && install just-lsp -D -t /usr/local/bin/ \
 && rm just-lsp just-lsp.tar.gz

# signoz-mcp-server (observability MCP for traces, logs, metrics)
# Version pinned to avoid anonymous GitHub API rate limits on CI runners — bump manually.
RUN SIGNOZ_VERSION=0.2.1 \
 && ARCH=$(uname -m) && [ "$ARCH" = "x86_64" ] && ARCH="amd64" || ARCH="arm64" \
 && curl -fLo signoz-mcp.tar.gz "https://github.com/SigNoz/signoz-mcp-server/releases/download/v${SIGNOZ_VERSION}/signoz-mcp-server_linux_${ARCH}.tar.gz" \
 && tar xf signoz-mcp.tar.gz "signoz-mcp-server_linux_${ARCH}/bin/signoz-mcp-server" \
 && install "signoz-mcp-server_linux_${ARCH}/bin/signoz-mcp-server" -D -t /usr/local/bin/ \
 && rm -rf signoz-mcp.tar.gz "signoz-mcp-server_linux_${ARCH}"

# code-server — OpenVSX-based browser editor served on the code-server Coder app.
ENV CODE_SERVER_VERSION=4.117.0
ENV CODE_SERVER_PREFIX=/opt/code-server
RUN curl -fsSL https://code-server.dev/install.sh \
      | sh -s -- --method=standalone --prefix="${CODE_SERVER_PREFIX}" --version="${CODE_SERVER_VERSION}" \
 && ln -sf "${CODE_SERVER_PREFIX}/bin/code-server" /usr/local/bin/code-server \
 && chown -R coder:coder "${CODE_SERVER_PREFIX}"

# vscode-web — Microsoft VS Code server bundle, used by the vscode-web Coder app.
ENV VSCODE_WEB_PREFIX=/opt/vscode-web
RUN ARCH=$(uname -m) \
 && case "$ARCH" in x86_64) ARCH=x64 ;; aarch64) ARCH=arm64 ;; *) echo "Unsupported arch $ARCH" >&2; exit 1 ;; esac \
 && HASH=$(curl -fsSL "https://update.code.visualstudio.com/api/commits/stable/server-linux-${ARCH}-web" | cut -d '"' -f 2) \
 && test -n "$HASH" \
 && mkdir -p "${VSCODE_WEB_PREFIX}" \
 && curl -fsSL "https://vscode.download.prss.microsoft.com/dbazure/download/stable/${HASH}/vscode-server-linux-${ARCH}-web.tar.gz" \
      | tar -xz -C "${VSCODE_WEB_PREFIX}" --strip-components 1 \
 && ln -sf "${VSCODE_WEB_PREFIX}/bin/code-server" /usr/local/bin/vscode-web \
 && chown -R coder:coder "${VSCODE_WEB_PREFIX}"

USER coder
RUN git config --global credential.helper "store --file=/home/coder/.git-credentials" \
 && gh config set git_protocol https || true

USER root
RUN install -d -m 0755 /usr/local/share/workspace-init.d /usr/local/share/workspace-prompts /usr/local/share/workspace-extensions.d /usr/local/share/workspace-settings.d

# Base workspace system prompt. Child images add their own extensions to
# /usr/local/share/workspace-prompts/ — 11-agent-prompts.sh concatenates
# them in sorted order and writes the result to ~/.coder/AGENTS.md (with
# symlinks for Claude/Codex/Gemini provider-specific files).
COPY workspace-images/base-dev/system_prompt.txt /usr/local/share/workspace-prompts/00-base.txt
COPY shared-assets/vscode-themes/ /usr/local/share/shared-assets/vscode-themes/

COPY workspace-images/base-dev/init.d/ /usr/local/share/workspace-init.d/
RUN chmod +x /usr/local/share/workspace-init.d/*.sh

# Tier 1 (global) extension/settings manifests consumed by
# 25-extensions-install.sh and 26-settings-apply.sh. Child images add Tier 2
# manifests to the same directory; per-repo Tier 3 sources are read directly
# from the project tree by the init scripts.
COPY workspace-images/base-dev/extensions.d/ /usr/local/share/workspace-extensions.d/
COPY workspace-images/base-dev/settings.d/ /usr/local/share/workspace-settings.d/

COPY workspace-images/base-dev/run-workspace-inits /usr/local/bin/run-workspace-inits
RUN chmod +x /usr/local/bin/run-workspace-inits

USER coder
