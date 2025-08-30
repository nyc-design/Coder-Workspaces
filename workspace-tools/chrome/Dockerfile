# Chrome + Xpra + Caddy + Supervisor (Cloud Run, amd64)
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:100 \
    XPRA_PORT=8081 \
    CDP_PORT=9222 \
    PORT=8080

# Base deps
RUN set -eux; \
  apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg procps \
    xvfb xterm fluxbox dbus-x11 xdg-utils x11-utils \
    fonts-liberation libnss3 libxss1 libatk-bridge2.0-0 libgtk-3-0 libgbm1 libdrm2 libasound2 \
    python3 python3-pip \
    caddy supervisor; \
  rm -rf /var/lib/apt/lists/*

# Google Chrome (amd64)
RUN set -eux; \
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /usr/share/keyrings/google-linux.gpg; \
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-linux.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
    > /etc/apt/sources.list.d/google-chrome.list; \
  apt-get update && apt-get install -y --no-install-recommends google-chrome-stable; \
  rm -rf /var/lib/apt/lists/*

# Xpra (HTML5 server included)
RUN set -eux; \
  apt-get update && apt-get install -y --no-install-recommends xpra; \
  rm -rf /var/lib/apt/lists/*

# Workspace dirs
RUN install -d -m 0755 /opt/chrome-profile

# Caddy config + Supervisor config
COPY Caddyfile /etc/caddy/Caddyfile
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Cloud Run listens on $PORT
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD curl -fsS http://127.0.0.1:${PORT}/health || exit 1

CMD ["bash", "-lc", "exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf"]