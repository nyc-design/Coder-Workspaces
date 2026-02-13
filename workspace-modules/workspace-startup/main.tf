locals {
  startup_script = <<-EOT
    set -e

    # Fix ownership that envbuilder's chown may have failed to complete.
    # envbuilder uses filepath.Walk which aborts on ENOENT if a temp file
    # is deleted mid-walk. This find-based approach handles vanishing files.
    for path in /home/coder /workspaces; do
      if [ -d "$path" ]; then
        sudo find "$path" -xdev -not -user coder -exec chown coder:coder {} + 2>/dev/null || true
      fi
    done

    # Prepare user home with default files on first start.
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      touch ~/.init_done
    fi

    /usr/local/bin/init-workspace.sh >> /tmp/workspace-init.log 2>&1 || true
    /usr/local/bin/run-workspace-inits >> /tmp/workspace-init.log 2>&1 || true

    # Prewarm code-server for Pencil MCP.
    # Wait for Pencil extension install to finish before starting the prewarm
    # code-server instance, so startup order doesn't race against extension install.
    (
      for _ in $(seq 1 180); do
        has_pencil_ext="false"
        if ls -d /home/coder/.local/share/code-server/extensions/highagency.pencildev-* >/dev/null 2>&1; then
          has_pencil_ext="true"
        elif ls -d /home/coder/.vscode-server/extensions/highagency.pencildev-* >/dev/null 2>&1; then
          has_pencil_ext="true"
        fi

        if [ "$has_pencil_ext" = "true" ] && [ -x /tmp/code-server/bin/code-server ]; then
          if pgrep -f "/tmp/code-server/bin/code-server serve-local.*--port 13337" >/dev/null 2>&1; then
            exit 0
          fi
          nohup /tmp/code-server/bin/code-server serve-local \
            --port 13337 \
            --host 127.0.0.1 \
            --accept-server-license-terms \
            --without-connection-token \
            --telemetry-level error \
            >/tmp/code-server-prewarm.log 2>&1 &
          exit 0
        fi
        sleep 1
      done
    ) >/tmp/code-server-prewarm-bootstrap.log 2>&1 &

    # Improve autonomous Pencil MCP reliability:
    # ensure a .pen file is opened in code-server even without a human browser tab.
    # This makes the active editor available for Pencil MCP tool calls.
    (
      CODE_SERVER_BIN="/tmp/code-server/bin/code-server"

      for _ in $(seq 1 180); do
        if [ -x "$CODE_SERVER_BIN" ] && curl -fsS "http://127.0.0.1:13337/" >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done

      if [ ! -x "$CODE_SERVER_BIN" ]; then
        exit 0
      fi

      PEN_FILE=""

      # Prefer a .pen file in the active project's .pencil directory.
      if [ -n "$${CODER_PROJECT_NAME:-}" ]; then
        PEN_FILE=$(find "/workspaces/$${CODER_PROJECT_NAME}/.pencil" -maxdepth 2 -type f -name "*.pen" 2>/dev/null | head -1 || true)
      fi

      # Fallback: first .pen file anywhere in /workspaces.
      if [ -z "$PEN_FILE" ]; then
        PEN_FILE=$(find /workspaces -maxdepth 6 -type f -name "*.pen" 2>/dev/null | head -1 || true)
      fi

      if [ -n "$PEN_FILE" ]; then
        "$CODE_SERVER_BIN" --reuse-window "$PEN_FILE" >/tmp/code-server-open-pen.log 2>&1 || true
      fi
    ) >/tmp/code-server-pencil-bootstrap.log 2>&1 &
  EOT
}

output "startup_script" {
  value = local.startup_script
}
