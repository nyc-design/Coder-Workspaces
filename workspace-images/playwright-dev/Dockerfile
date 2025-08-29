# Extends YOUR base image
ARG BASE_IMAGE=us-central1-docker.pkg.dev/coder-nt/workspace-images/base-dev:latest
FROM ${BASE_IMAGE}

USER root

# --- Real Google Chrome (stable) + desktop stack ---
RUN install -d -m 0755 -o root -g root /usr/share/keyrings && \
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/google-linux-signing-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/google-linux-signing-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update -y && apt-get install -y --no-install-recommends \
      google-chrome-stable \
      xvfb x11vnc novnc websockify fluxbox xterm dbus-x11 xdg-utils \
      x11-utils procps \
      fonts-liberation libnss3 libxss1 libatk-bridge2.0-0 libgtk-3-0 libgbm1 libdrm2 libasound2 \
    && rm -rf /var/lib/apt/lists/*

# --- Playwright (Node + Python), use system Chrome (no bundled downloads) ---
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    CHROME_BIN=/usr/bin/google-chrome-stable \
    CHROME_PATH=/usr/bin/google-chrome-stable

# Node side
RUN npm -g i npm@latest && \
    npm -g i playwright @playwright/test && \
    npx playwright install-deps

# Python side
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel && \
    pip3 install --no-cache-dir playwright pytest && \
    python3 -m playwright install-deps

# Make DISPLAY available in all shells
RUN printf 'export DISPLAY=:99\n' > /etc/profile.d/10-display.sh

# Drop your init script directly into the init.d folder so it runs every start.
# (Base image should already include /usr/local/share/workspace-init.d and the run-workspace-inits runner.)
COPY start-vnc.sh /usr/local/share/workspace-init.d/20-start-vnc.every.sh
RUN chmod +x /usr/local/share/workspace-init.d/20-start-vnc.every.sh

USER coder