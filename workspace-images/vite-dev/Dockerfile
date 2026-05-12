# Extends YOUR base image
FROM ghcr.io/nyc-design/workspace-images/base-dev:latest

USER root

# Browser dependencies for Playwright (Chromium only — ARM Linux, no system Chrome)
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    libnss3 libatk-bridge2.0-0 libdrm2 libxcomposite1 libxdamage1 libxrandr2 \
    libgbm1 libxss1 libasound2t64 libxshmfence1 xvfb \
 && rm -rf /var/lib/apt/lists/*

# Global Node.js tooling baked into the image. pnpm is already in base-dev.
# Tools here are the ones the editor / CLI invoke directly; project-local
# deps (react, vite plugins, etc.) belong in each project's package.json.
RUN npm install -g \
    typescript \
    @biomejs/biome \
    vitest \
    @playwright/test playwright @playwright/mcp @playwright/cli \
    tailwindcss postcss autoprefixer \
 && chown -R coder:coder /usr/local/share/npm-global

# Vite-specific init script
COPY workspace-images/vite-dev/vite-init.sh /usr/local/share/workspace-init.d/20-vite-init.sh
RUN chmod +x /usr/local/share/workspace-init.d/20-vite-init.sh

# Frontend-specific system prompt extension. Concatenated into ~/.coder/AGENTS.md
# by 11-agent-prompts.sh alongside the base prompt.
COPY workspace-images/vite-dev/system_prompt_extension.txt /usr/local/share/workspace-prompts/20-vite.txt

# Tier 2 (frontend) extension + settings manifests, merged with the inherited
# Tier 1 manifests at workspace start. fullstack-dev FROM vite-dev inherits
# both manifests transitively via the image layer.
COPY workspace-images/vite-dev/extensions.d/ /usr/local/share/workspace-extensions.d/
COPY workspace-images/vite-dev/settings.d/   /usr/local/share/workspace-settings.d/

# Default Biome config baked into the image. Settings point at this path so
# any project without its own biome.json picks up the workspace defaults.
COPY workspace-images/vite-dev/biome/biome.json /usr/local/share/biome/biome.json

# Node.js workspace defaults
ENV NPM_CONFIG_UPDATE_NOTIFIER=false
ENV NPM_CONFIG_FUND=false
ENV PNPM_HOME=/home/coder/.local/share/pnpm
ENV PATH=$PNPM_HOME:$PATH
# Playwright browser path and CLI config
ENV PLAYWRIGHT_BROWSERS_PATH=/home/coder/.cache/ms-playwright
ENV PLAYWRIGHT_MCP_CONFIG=/home/coder/.playwright/cli.config.json
ENV PLAYWRIGHT_MCP_OUTPUT_DIR=/home/coder/.playwright-cli
# MCP server configuration for Claude agents
ENV MCP_SERVER_PLAYWRIGHT_PORT=3001
ENV MCP_SERVER_PLAYWRIGHT_HOST=localhost

USER coder

RUN mkdir -p /home/coder/.local/share/pnpm \
 && mkdir -p /home/coder/projects \
 && pnpm config set store-dir /home/coder/.local/share/pnpm/store

# Bake Playwright Chromium into the image so workspaces don't pay the ~150 MB
# download on first start. Runs as coder so the cache lives in $HOME.
RUN npx --yes playwright@latest install chromium
