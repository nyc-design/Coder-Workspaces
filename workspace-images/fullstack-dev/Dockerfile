# Extends YOUR base image
ARG BASE_IMAGE=us-central1-docker.pkg.dev/coder-nt/workspace-images/base-dev:latest
FROM ${BASE_IMAGE}

USER root

# Install Node.js (using NodeSource repository for latest LTS)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
 && apt-get install -y --no-install-recommends \
    nodejs \
 && rm -rf /var/lib/apt/lists/*

# Install Python development tools
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    python3-dev python3-setuptools python3-wheel \
    python3-testresources \
 && rm -rf /var/lib/apt/lists/*

# Install Python packages in smaller groups to avoid conflicts
RUN python3 -m pip install --no-cache-dir --break-system-packages \
    pipenv virtualenv

# Install Python linters and formatters
RUN python3 -m pip install --no-cache-dir --break-system-packages \
    black isort flake8 pylint mypy bandit

# Install Python testing tools and web frameworks
RUN python3 -m pip install --no-cache-dir --break-system-packages \
    pytest pytest-cov coverage pre-commit \
    fastapi uvicorn sqlalchemy alembic \
    requests numpy pandas types-requests

# Install Poetry using official installer to avoid conflicts
RUN curl -sSL https://install.python-poetry.org | python3 - && \
    ln -s /root/.local/bin/poetry /usr/local/bin/poetry

# Install global Node.js development tools
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
    # Code quality
    husky lint-staged

# Create fullstack-specific init script
COPY workspace-images/fullstack-dev/fullstack-init.sh /usr/local/share/workspace-init.d/20-fullstack-init.sh
RUN chmod +x /usr/local/share/workspace-init.d/20-fullstack-init.sh

# Set environment variables for both Python and Node.js
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV POETRY_VENV_IN_PROJECT=1
ENV POETRY_CACHE_DIR=/home/coder/.cache/pypoetry

ENV NODE_ENV=development
ENV NEXT_TELEMETRY_DISABLED=1
ENV NPM_CONFIG_UPDATE_NOTIFIER=false
ENV NPM_CONFIG_FUND=false
ENV PNPM_HOME=/home/coder/.local/share/pnpm
ENV PATH=$PNPM_HOME:$PATH

USER coder

# Create development directories for fullstack projects
RUN mkdir -p /home/coder/projects/fullstack \
 && mkdir -p /home/coder/.cache/pip \
 && mkdir -p /home/coder/.cache/pypoetry \
 && mkdir -p /home/coder/.npm-global \
 && mkdir -p /home/coder/.local/share/pnpm \
 && mkdir -p /home/coder/.cache/yarn \
 && mkdir -p /home/coder/.venv

# Configure npm to use global directory in user space
RUN npm config set prefix '/home/coder/.npm-global' \
 && echo 'export PATH=/home/coder/.npm-global/bin:$PATH' >> /home/coder/.bashrc

# Set up yarn and pnpm for user
RUN yarn config set cache-folder /home/coder/.cache/yarn \
 && pnpm config set store-dir /home/coder/.local/share/pnpm/store