# code-server (OpenVSX) — thin wrapper around the binary baked into base-dev.
# Binary is installed at /opt/code-server/bin/code-server by the image build;
# the launcher script just configures and launches it. Replaces the
# registry.coder.com/coder/code-server module so we avoid a download on each
# workspace start. Extension installation is handled by the workspace-init.d
# manifest framework, which installs versions into a host-bound shared cache
# and symlinks the active manifest set into a per-editor dir at workspace
# start; persisted versions survive across restarts via the shared mount.

locals {
  code_server_port              = 13337
  code_server_install_prefix    = "/opt/code-server"
  code_server_extensions_dir    = "/home/coder/.vscode-extensions/code-server"
  code_server_log_path          = "/tmp/code-server.log"
}

resource "coder_script" "code_server" {
  count        = var.enable_apps && var.enable_code_server ? 1 : 0
  agent_id     = var.agent_id
  display_name = "code-server"
  icon         = "/icon/code.svg"
  run_on_start = true

  script = templatefile("${path.module}/scripts/code-server-launch.sh", {
    INSTALL_PREFIX        = local.code_server_install_prefix
    EXTENSIONS_DIR        = local.code_server_extensions_dir
    LOG_PATH              = local.code_server_log_path
    PORT                  = local.code_server_port
    APP_NAME              = "code-server"
  })
}

resource "coder_app" "code_server" {
  count        = var.enable_apps && var.enable_code_server ? 1 : 0
  agent_id     = var.agent_id
  slug         = "code-server"
  display_name = "code-server"
  url          = "http://localhost:${local.code_server_port}/?folder=${urlencode("/workspaces/${var.project_name}")}"
  icon         = "/icon/code.svg"
  subdomain    = false
  share        = "owner"
  order        = 0
  open_in      = "tab"

  healthcheck {
    url       = "http://localhost:${local.code_server_port}/healthz"
    interval  = 5
    threshold = 6
  }
}
