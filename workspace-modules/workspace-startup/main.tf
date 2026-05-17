locals {
  startup_script = <<-EOT
    set -e

    rm -f /tmp/workspace-init.done

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

    /usr/local/bin/run-workspace-inits >> /tmp/workspace-init.log 2>&1 || true
    # Sentinel for editor launchers: 30-extensions-activate.sh populates the
    # per-editor symlink farms used by code-server / vscode-web --extensions-dir,
    # but the launchers race with this script. Touch the sentinel after the
    # init pipeline finishes so the launchers can wait on it before exec.
    touch /tmp/workspace-init.done
  EOT
}

output "startup_script" {
  value = local.startup_script
}
