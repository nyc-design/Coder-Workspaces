terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
  }
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# Per-editor resources (code-server, vscode-web) and their locals live in
# their own .tf files alongside this one — Terraform merges all .tf files
# in this directory into the same module. The remaining apps below are
# short enough (one module call or one coder_app block each) that keeping
# them together here stays readable.

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
