module "cursor" {
  source   = "registry.coder.com/coder/cursor/coder"
  version  = "1.2.1"
  agent_id = var.agent_id
  folder   = "/workspaces/${var.project_name}"
}

module "code-server" {
  source = "registry.coder.com/coder/code-server/coder"
  folder = "/workspaces/${var.project_name}"

  agent_id = var.agent_id
  order    = 1

  settings = {
    "workbench.colorTheme"                      = "Default Dark Modern",
    "git.useIntegratedAskPass"                  = "false",
    "likec4.mcp.enabled"                        = "true",
    "vscode-neovim.neovimExecutablePaths.linux" = "/usr/local/bin/nvim",
    "extensions.experimental.affinity"          = { "asvetliakov.vscode-neovim" = 1 },
    "todo-tree.tree.showBadges"                 = "true",
    "todo-tree.tree.disableCompactFolders"      = "false",
    "todo-tree.tree.showCountsInTree"           = "true",
    "todo-tree.tree.scanMode"                   = "current file",
    "excalidraw.workspaceLibraryPath"           = "/home/coder/.excalidraw/library.excalidrawlib"
  }

  machine-settings = {
    "extensions.experimental.affinity" = { "asvetliakov.vscode-neovim" = 1 }
  }

  extensions = [
    "GitHub.vscode-github-actions",
    "GitHub.vscode-pull-request-github",
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
    "asvetliakov.vscode-neovim",
    "bradlc.vscode-tailwindcss",
    "Gruntfuggly.todo-tree",
    "usernamehw.errorlens",
    "hediet.vscode-drawio",
    "joshbolduc.story-explorer",
    "bruno-api-client.bruno",
    "pomdtr.excalidraw-editor"
  ]
}

module "vscode-web" {
  source = "registry.coder.com/coder/vscode-web/coder"
  folder = "/workspaces/${var.project_name}"

  agent_id       = var.agent_id
  order          = 2
  accept_license = true

  settings = {
    "workbench.colorTheme"                      = "Default Dark Modern",
    "git.useIntegratedAskPass"                  = "false",
    "likec4.mcp.enabled"                        = "true",
    "vscode-neovim.neovimExecutablePaths.linux" = "/usr/local/bin/nvim",
    "extensions.experimental.affinity"          = { "asvetliakov.vscode-neovim" = 1 },
    "todo-tree.tree.showBadges"                 = "true",
    "todo-tree.tree.disableCompactFolders"      = "false",
    "todo-tree.tree.showCountsInTree"           = "true",
    "todo-tree.tree.scanMode"                   = "current file",
    "excalidraw.workspaceLibraryPath"           = "/home/coder/.excalidraw/library.excalidrawlib"
  }

  extensions = [
    "GitHub.vscode-github-actions",
    "GitHub.vscode-pull-request-github",
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
    "asvetliakov.vscode-neovim",
    "bradlc.vscode-tailwindcss",
    "Gruntfuggly.todo-tree",
    "usernamehw.errorlens",
    "hediet.vscode-drawio",
    "joshbolduc.story-explorer",
    "bruno-api-client.bruno",
    "pomdtr.excalidraw-editor"
  ]
}

resource "coder_app" "neovim" {
  agent_id     = var.agent_id
  slug         = "neovim"
  display_name = "Neovim"
  icon         = "/icon/terminal.svg"
  command      = "nvim"
  order        = 3
}

module "filebrowser" {
  source        = "registry.coder.com/coder/filebrowser/coder"
  version       = "1.0.23"
  agent_id      = var.agent_id
  folder        = "/workspaces/${var.project_name}"
  database_path = "/tmp/filebrowser.db"
  order         = 4
}
