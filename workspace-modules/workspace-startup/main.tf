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
  EOT
}

output "startup_script" {
  value = local.startup_script
}
