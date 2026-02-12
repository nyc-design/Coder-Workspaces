FROM codercom/enterprise-base:ubuntu-20250929
ARG DEBIAN_FRONTEND=noninteractive

USER root

# Core deps + Python + build tools
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    ca-certificates curl git bash-completion \
    python3 python3-pip python3-venv build-essential \
    tree ripgrep fd-find \
 && rm -rf /var/lib/apt/lists/*

# Neovim (0.10+ from GitHub — apt only has 0.9.x on Ubuntu 24.04)
RUN ARCH=$(uname -m) && [ "$ARCH" = "x86_64" ] && ARCH="x86_64" || ARCH="arm64" \
 && curl -Lo nvim.tar.gz "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${ARCH}.tar.gz" \
 && tar xf nvim.tar.gz \
 && cp -r nvim-linux-${ARCH}/* /usr/local/ \
 && rm -rf nvim.tar.gz nvim-linux-${ARCH}

# Google Cloud CLI (modern method + single RUN per Google’s Docker tip)
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

# Install keyring daemon support for VS Code credential persistence
RUN apt-get update -y && apt-get install -y --no-install-recommends \
      gnome-keyring \
      dbus \
      dbus-x11 \
      libsecret-tools \
      python3-secretstorage \
 && rm -rf /var/lib/apt/lists/*

# Node.js 20 + pnpm
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update -y && apt-get install -y --no-install-recommends nodejs \
 && npm install -g pnpm \
 && rm -rf /var/lib/apt/lists/*

# AI coding CLIs + architecture tooling + skills ecosystem
RUN npm install -g @openai/codex @anthropic-ai/claude-code @google/gemini-cli likec4 skills \
 && chmod -R a+w /usr/lib/node_modules/likec4/

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
RUN SIGNOZ_VERSION=$(curl -s "https://api.github.com/repos/SigNoz/signoz-mcp-server/releases/latest" | grep -Po '"tag_name": "v\K[^"]*') \
 && ARCH=$(uname -m) && [ "$ARCH" = "x86_64" ] && ARCH="amd64" || ARCH="arm64" \
 && curl -Lo signoz-mcp.tar.gz "https://github.com/SigNoz/signoz-mcp-server/releases/download/v${SIGNOZ_VERSION}/signoz-mcp-server_linux_${ARCH}.tar.gz" \
 && tar xf signoz-mcp.tar.gz "signoz-mcp-server_linux_${ARCH}/bin/signoz-mcp-server" \
 && install "signoz-mcp-server_linux_${ARCH}/bin/signoz-mcp-server" -D -t /usr/local/bin/ \
 && rm -rf signoz-mcp.tar.gz "signoz-mcp-server_linux_${ARCH}"

# lazygit (terminal UI for git) — apt only has it for Ubuntu 25.10+, use binary release
RUN LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*') \
 && ARCH=$(uname -m) && [ "$ARCH" = "aarch64" ] && ARCH="arm64" || true \
 && curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_linux_${ARCH}.tar.gz" \
 && tar xf lazygit.tar.gz lazygit \
 && install lazygit -D -t /usr/local/bin/ \
 && rm lazygit lazygit.tar.gz

# lazydocker (terminal UI for docker) — same binary release pattern
RUN LAZYDOCKER_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazydocker/releases/latest" | grep -Po '"tag_name": "v\K[^"]*') \
 && ARCH=$(uname -m) && [ "$ARCH" = "aarch64" ] && ARCH="arm64" || true \
 && curl -Lo lazydocker.tar.gz "https://github.com/jesseduffield/lazydocker/releases/download/v${LAZYDOCKER_VERSION}/lazydocker_${LAZYDOCKER_VERSION}_Linux_${ARCH}.tar.gz" \
 && tar xf lazydocker.tar.gz lazydocker \
 && install lazydocker -D -t /usr/local/bin/ \
 && rm lazydocker lazydocker.tar.gz

# Minimal user onfig
RUN install -d -o coder -g coder -m 700 /home/coder/.ssh \
 && ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> /home/coder/.ssh/known_hosts \
 && chown coder:coder /home/coder/.ssh/known_hosts \
 && chmod 644 /home/coder/.ssh/known_hosts

USER coder
RUN git config --global credential.helper "store --file=/home/coder/.git-credentials" \
 && gh config set git_protocol https || true

# LazyVim — clone starter, install all plugins headlessly, stage for init-time copy
# (volume mount hides /home/coder build layer, so we stage under /opt/)
RUN git clone --depth 1 https://github.com/LazyVim/starter /home/coder/.config/nvim \
 && rm -rf /home/coder/.config/nvim/.git \
 && nvim --headless "+Lazy! sync" +qa \
 && mkdir -p /opt/lazyvim-starter \
 && cp -r /home/coder/.config/nvim       /opt/lazyvim-starter/config \
 && cp -r /home/coder/.local/share/nvim  /opt/lazyvim-starter/data \
 && cp -r /home/coder/.local/state/nvim  /opt/lazyvim-starter/state 2>/dev/null; true \
 && rm -rf /home/coder/.config/nvim /home/coder/.local/share/nvim \
           /home/coder/.local/state/nvim /home/coder/.cache/nvim

USER root
COPY workspace-images/base-dev/init-workspace.sh /usr/local/bin/init-workspace.sh
RUN chmod +x /usr/local/bin/init-workspace.sh

RUN install -d -m 0755 /usr/local/share/workspace-init.d

COPY workspace-images/base-dev/run-workspace-inits /usr/local/bin/run-workspace-inits
RUN chmod +x /usr/local/bin/run-workspace-inits

USER coder
