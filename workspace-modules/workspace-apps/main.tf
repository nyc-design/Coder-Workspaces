terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
  }
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  # The launchers below are intentionally thin: they assume the binaries are
  # already on disk (baked into base-dev) and that anything else editor-related
  # — extension installs, User/Machine settings.json files, in-place patches
  # — is the responsibility of workspace-init.d scripts in base-dev. Keep
  # Terraform locals limited to ports, paths, and CLI flags.

  # ---- code-server (OpenVSX) ----
  code_server_port           = 13337
  code_server_install_prefix = "/opt/code-server"
  code_server_extensions_dir = "/home/coder/.vscode-extensions/shared"
  code_server_log_path       = "/tmp/code-server.log"

  # ---- vscode-web (Microsoft) ----
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


module "vscode-desktop" {
  count   = var.enable_apps && var.enable_vscode_desktop ? 1 : 0
  source  = "registry.coder.com/coder/vscode-desktop-core/coder"
  version = "1.0.2"

  agent_id = var.agent_id

  coder_app_icon         = "/icon/desktop.svg"
  coder_app_slug         = "vscode"
  coder_app_display_name = "VS Code Desktop"
  coder_app_order        = 5

  folder   = "/workspaces/${var.project_name}"
  protocol = "vscode"
}

module "cursor" {
  count    = var.enable_apps && var.enable_cursor ? 1 : 0
  source   = "registry.coder.com/coder/cursor/coder"
  version  = "1.2.1"
  agent_id = var.agent_id
  folder   = "/workspaces/${var.project_name}"
  order    = 6
}


# code-server (OpenVSX) — thin wrapper around the binary baked into base-dev.
# Binary is installed at /opt/code-server/bin/code-server by the image build;
# this resource just configures and launches it. Replaces the
# registry.coder.com/coder/code-server module so we avoid a download on each
# workspace start. Extension installation is intentionally not handled here
# anymore — the manifest framework introduced in the next PR populates the
# shared extensions dir at image build / first boot, and persisted extensions
# survive across restarts via the host-bound shared mount.
resource "coder_script" "code_server" {
  count        = var.enable_apps && var.enable_code_server ? 1 : 0
  agent_id     = var.agent_id
  display_name = "code-server"
  icon         = "/icon/code.svg"
  run_on_start = true

  script = templatefile("${path.module}/scripts/code-server-launch.sh", {
    INSTALL_PREFIX = local.code_server_install_prefix
    EXTENSIONS_DIR = local.code_server_extensions_dir
    LOG_PATH       = local.code_server_log_path
    PORT           = local.code_server_port
    APP_NAME       = "code-server"
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

# vscode-web (Microsoft) — thin wrapper around the binary baked into base-dev.
# Binary is installed at /opt/vscode-web/bin/code-server by the image build.
# The launcher symlinks every subdir of the shared OpenVSX extensions dir into
# vscode-web's own extensions dir on each start so vscode-web sees a merged
# view (shared + Marketplace-only) with zero on-disk duplication.
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


resource "coder_app" "neovim" {
  count        = var.enable_apps && var.enable_neovim ? 1 : 0
  agent_id     = var.agent_id
  slug         = "neovim"
  display_name = "Neovim"
  icon         = "/icon/terminal.svg"
  command      = "nvim"
  order        = 7
}


module "filebrowser" {
  count         = var.enable_apps && var.enable_filebrowser ? 1 : 0
  source        = "registry.coder.com/coder/filebrowser/coder"
  version       = "1.0.23"
  agent_id      = var.agent_id
  folder        = "/workspaces/${var.project_name}"
  database_path = "/tmp/filebrowser.db"
  order         = 4
}


resource "coder_app" "claude_usage" {
  count        = var.enable_apps && var.enable_claude_usage ? 1 : 0
  agent_id     = var.agent_id
  slug         = "claude-usage"
  display_name = "Claude Usage"
  icon         = "/icon/claude.svg"
  url          = "https://claude.ai/settings/usage"
  external     = true
  order        = 1
}


resource "coder_app" "codex_usage" {
  count        = var.enable_apps && var.enable_codex_usage ? 1 : 0
  agent_id     = var.agent_id
  slug         = "codex-usage"
  display_name = "Codex Usage"
  icon         = "/icon/openai.svg"
  url          = "https://chatgpt.com/codex/cloud/settings/analytics#usage"
  external     = true
  order        = 2
}
