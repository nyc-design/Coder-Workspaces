FROM codercom/enterprise-base:ubuntu
ARG DEBIAN_FRONTEND=noninteractive

USER root

# Core deps + Python + build tools
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    ca-certificates curl git bash-completion \
    python3 python3-pip python3-venv build-essential \
 && rm -rf /var/lib/apt/lists/*

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

# Node.js 20 + pnpm
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update -y && apt-get install -y --no-install-recommends nodejs \
 && npm install -g pnpm \
 && rm -rf /var/lib/apt/lists/*

# AI coding CLIs
RUN npm install -g @openai/codex @anthropic-ai/claude-code

# Minimal user config
RUN install -d -o coder -g coder -m 700 /home/coder/.ssh \
 && ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> /home/coder/.ssh/known_hosts \
 && chown coder:coder /home/coder/.ssh/known_hosts \
 && chmod 644 /home/coder/.ssh/known_hosts

USER coder
RUN git config --global credential.helper "store --file=/home/coder/.git-credentials" \
 && gh config set git_protocol https || true

USER root
COPY workspace-images/base-dev/init-workspace.sh /usr/local/bin/init-workspace.sh
RUN chmod +x /usr/local/bin/init-workspace.sh

RUN install -d -m 0755 /usr/local/share/workspace-init.d

COPY workspace-images/base-dev/run-workspace-inits /usr/local/bin/run-workspace-inits
RUN chmod +x /usr/local/bin/run-workspace-inits

# Copy base project scaffolds
COPY project-scaffolds/base /opt/coder-scaffolds/

USER coder