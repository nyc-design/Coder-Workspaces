# vscode-web (Microsoft) — thin wrapper around the binary baked into base-dev.
# Binary is installed at /opt/vscode-web/bin/code-server by the image build.
# The launcher symlinks every subdir of the shared OpenVSX extensions dir
# into vscode-web's own extensions dir on each start so vscode-web sees a
# merged view (shared + Marketplace-only) with zero on-disk duplication.

locals {
  vscode_web_port              = 13338
  vscode_web_install_prefix    = "/opt/vscode-web"
  vscode_web_extensions_dir    = "/home/coder/.vscode-extensions/vscode-web"
  vscode_web_shared_extensions = "/home/coder/.vscode-extensions/shared"
  vscode_web_log_path          = "/tmp/vscode-web.log"
  vscode_web_telemetry_level   = "error"
  vscode_web_subdomain         = true
  vscode_web_server_base_path = (
    local.vscode_web_subdomain
    ? ""
    : format("/@%s/%s/apps/vscode-web/", data.coder_workspace_owner.me.name, data.coder_workspace.me.name)
  )
}

resource "coder_script" "vscode_web" {
  count        = var.enable_apps && var.enable_vscode_web ? 1 : 0
  agent_id     = var.agent_id
  display_name = "VS Code Web"
  icon         = "/icon/code.svg"
  run_on_start = true

  script = templatefile("${path.module}/scripts/vscode-web-launch.sh", {
    INSTALL_PREFIX        = local.vscode_web_install_prefix
    EXTENSIONS_DIR        = local.vscode_web_extensions_dir
    SHARED_EXTENSIONS_DIR = local.vscode_web_shared_extensions
    LOG_PATH              = local.vscode_web_log_path
    PORT                  = local.vscode_web_port
    TELEMETRY_LEVEL       = local.vscode_web_telemetry_level
    SERVER_BASE_PATH      = local.vscode_web_server_base_path
  })
}

resource "coder_app" "vscode_web" {
  count        = var.enable_apps && var.enable_vscode_web ? 1 : 0
  agent_id     = var.agent_id
  slug         = "vscode-web"
  display_name = "VS Code Web"
  url          = "http://localhost:${local.vscode_web_port}${local.vscode_web_server_base_path}?folder=${urlencode("/workspaces/${var.project_name}")}"
  icon         = "/icon/code.svg"
  subdomain    = local.vscode_web_subdomain
  share        = "owner"
  order        = 2

  healthcheck {
    url       = local.vscode_web_subdomain ? "http://localhost:${local.vscode_web_port}/healthz" : "http://localhost:${local.vscode_web_port}${local.vscode_web_server_base_path}healthz"
    interval  = 5
    threshold = 6
  }
}
