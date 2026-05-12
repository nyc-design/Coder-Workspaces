terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
  }
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


module "code-server" {
  count           = var.enable_apps && var.enable_code_server ? 1 : 0
  source          = "registry.coder.com/coder/code-server/coder"
  install_version = "4.117.0" # Pin: 4.118.0 broke WebKit (transferable streams in webview detach ArrayBuffers)
  folder          = "/workspaces/${var.project_name}"

  agent_id       = var.agent_id
  order          = 0
  open_in        = "tab"
  extensions_dir = "/home/coder/.vscode-extensions/shared"

  settings = {
    "workbench.colorTheme"                 = "Solarized Moon",
    "git.useIntegratedAskPass"             = false,
    "likec4.mcp.enabled"                   = true,
    "todo-tree.tree.showBadges"            = true,
    "todo-tree.tree.disableCompactFolders" = false,
    "todo-tree.tree.showCountsInTree"      = true,
    "todo-tree.tree.scanMode"              = "current file",
    "mdb.showOverviewPageAfterInstall"     = false
  }

  extensions = [
    "GitHub.vscode-github-actions",
    "GitHub.vscode-pull-request-github",
    "eamodio.gitlens",
    "Anthropic.claude-code",
    "highagency.pencildev",
    "mongodb.mongodb-vscode",
    "openai.chatgpt",
    "ms-python.python",
    "detachhead.basedpyright",
    "Supermaven.supermaven",
    "ms-azuretools.vscode-docker",
    "likec4.likec4-vscode",
    "nefrob.vscode-just-syntax",
    "bradlc.vscode-tailwindcss",
    "Gruntfuggly.todo-tree",
    "usernamehw.errorlens",
    "joshbolduc.story-explorer",
    "bruno-api-client.bruno",
    "pomdtr.excalidraw-editor",
    "abridge.file-explorer-tools",
    "hashicorp.terraform",
    "rhalaly.scope-to-this",
    "jakobhoeg.vscode-pokemon",
    "d9once.pokechi",
    "octohash.powermode-plus",
  ]
}


module "vscode-web" {
  count  = var.enable_apps && var.enable_vscode_web ? 1 : 0
  source = "registry.coder.com/coder/vscode-web/coder"
  folder = "/workspaces/${var.project_name}"

  agent_id       = var.agent_id
  order          = 2
  accept_license = true
  # vscode-web reads a merged extensions dir (shared OpenVSX extensions plus
  # MS-marketplace-only ones). The base-dev init script symlinks the shared
  # dir into the vscode-web dir on workspace start.
  extensions_dir = "/home/coder/.vscode-extensions/vscode-web"

  settings = {
    "workbench.colorTheme"                 = "Default Dark Modern",
    "git.useIntegratedAskPass"             = false,
    "likec4.mcp.enabled"                   = true,
    "todo-tree.tree.showBadges"            = true,
    "todo-tree.tree.disableCompactFolders" = false,
    "todo-tree.tree.showCountsInTree"      = true,
    "todo-tree.tree.scanMode"              = "current file",
    "mdb.showOverviewPageAfterInstall"     = false
  }

  extensions = [
    "GitHub.vscode-github-actions",
    "GitHub.vscode-pull-request-github",
    "eamodio.gitlens",
    "Github.copilot",
    "Anthropic.claude-code",
    "highagency.pencildev",
    "mongodb.mongodb-vscode",
    "openai.chatgpt",
    "ms-python.python",
    "ms-azuretools.vscode-docker",
    "Google.geminicodeassist",
    "likec4.likec4-vscode",
    "nefrob.vscode-just-syntax",
    "bradlc.vscode-tailwindcss",
    "Gruntfuggly.todo-tree",
    "usernamehw.errorlens",
    "joshbolduc.story-explorer",
    "bruno-api-client.bruno",
    "pomdtr.excalidraw-editor",
    "abridge.file-explorer-tools",
    "hashicorp.terraform",
    "rhalaly.scope-to-this",
    "jakobhoeg.vscode-pokemon",
    "d9once.pokechi",
    "octohash.powermode-plus",
  ]
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
