# Base: Coder’s enterprise Ubuntu workspace image
FROM codercom/enterprise-base:ubuntu

ARG DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------
# Core packages + Python + build essentials
# --------------------------------------------------
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git openssh-client \
    python3 python3-pip python3-venv build-essential iptables \
    && rm -rf /var/lib/apt/lists/*

# --------------------------------------------------
# Google Cloud CLI
# --------------------------------------------------
RUN install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      -o /etc/apt/keyrings/google-cloud.gpg && \
    chmod 0644 /etc/apt/keyrings/google-cloud.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/google-cloud.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-sdk.list && \
    apt-get update -y && apt-get install -y --no-install-recommends google-cloud-cli && \
    rm -rf /var/lib/apt/lists/*

# --------------------------------------------------
# GitHub CLI
# --------------------------------------------------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update -y && apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# --------------------------------------------------
# Node.js 20 (NodeSource) + npm + pnpm
# --------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get update -y && apt-get install -y --no-install-recommends nodejs && \
    npm install -g pnpm && \
    rm -rf /var/lib/apt/lists/*

# --------------------------------------------------
# AI coding CLIs: Codex & Claude Code
# --------------------------------------------------
RUN npm install -g @openai/codex @anthropic-ai/claude-code

# --------------------------------------------------
# Workspace user config (coder user exists in base image)
# --------------------------------------------------
RUN install -d -o coder -g coder -m 700 /home/coder/.ssh && \
    ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> /home/coder/.ssh/known_hosts && \
    chown coder:coder /home/coder/.ssh/known_hosts && chmod 644 /home/coder/.ssh/known_hosts

USER coder
ENV HOME=/home/coder
RUN git config --global credential.helper "store --file=/home/coder/.git-credentials" && \
    gh config set git_protocol https || true

USER root

# --------------------------------------------------
# Init script to bootstrap dockerd, PAT persistence, etc.
# --------------------------------------------------
COPY init_workspace.sh /usr/local/bin/init_workspace.sh
RUN chmod +x /usr/local/bin/init_workspace.sh

ENTRYPOINT ["/usr/local/bin/init-workspace.sh"]
CMD ["bash"]