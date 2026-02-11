# Extends YOUR base image
FROM ghcr.io/nyc-design/workspace-images/base-dev:latest

USER root

# Install Node.js and browser dependencies for Playwright
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
 && apt-get install -y --no-install-recommends \
    nodejs \
    # Browser dependencies for Playwright
    libnss3 libatk-bridge2.0-0 libdrm2 libxcomposite1 libxdamage1 libxrandr2 \
    libgbm1 libxss1 libasound2t64 libxshmfence1 xvfb \
 && rm -rf /var/lib/apt/lists/*

# Install global Node.js development tools and package managers
RUN npm install -g \
    # Package managers
    yarn pnpm \
    # Development tools
    create-next-app @next/codemod \
    # Linters and formatters
    eslint prettier @typescript-eslint/parser @typescript-eslint/eslint-plugin \
    # Build tools
    turbo vercel \
    # Testing
    jest @playwright/test \
    # Type checking
    typescript @types/node @types/react @types/react-dom \
    # Development servers
    serve concurrently \
    # CSS and styling
    tailwindcss @tailwindcss/typography @tailwindcss/forms \
    postcss autoprefixer \
    # Popular React ecosystem tools
    storybook @storybook/cli \
    # Code quality
    husky lint-staged \
    # Playwright browser automation for Claude agents
    @playwright/mcp @playwright/cli

# Create Next.js-specific init script
COPY workspace-images/nextjs-dev/nextjs-init.sh /usr/local/share/workspace-init.d/20-nextjs-init.sh
RUN chmod +x /usr/local/share/workspace-init.d/20-nextjs-init.sh

# Set Node.js environment variables
ENV NODE_ENV=development
ENV NEXT_TELEMETRY_DISABLED=1
ENV NPM_CONFIG_UPDATE_NOTIFIER=false
ENV NPM_CONFIG_FUND=false
ENV PNPM_HOME=/home/coder/.local/share/pnpm
ENV PATH=$PNPM_HOME:$PATH
# Playwright browser path
ENV PLAYWRIGHT_BROWSERS_PATH=/home/coder/.cache/ms-playwright
# MCP server configuration for Claude agents
ENV MCP_SERVER_PLAYWRIGHT_PORT=3001
ENV MCP_SERVER_PLAYWRIGHT_HOST=localhost

USER coder

# Create Node.js directories and configure user environment
RUN mkdir -p /home/coder/.npm-global \
 && mkdir -p /home/coder/.local/share/pnpm \
 && mkdir -p /home/coder/.cache/yarn \
 && mkdir -p /home/coder/projects

# Configure npm to use global directory in user space
RUN npm config set prefix '/home/coder/.npm-global' \
 && echo 'export PATH=/home/coder/.npm-global/bin:$PATH' >> /home/coder/.bashrc

# Set up yarn and pnpm for user
RUN yarn config set cache-folder /home/coder/.cache/yarn \
 && pnpm config set store-dir /home/coder/.local/share/pnpm/store
