
terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

locals {
  common_env = concat(
    [
      "GH_TOKEN=${var.github_pat}",
      "GITHUB_TOKEN=${var.github_pat}",
      "GITHUB_PAT=${var.github_pat}",
      "GITHUB_OAUTH_TOKEN=${var.github_pat}",
      # Pin the "opus" model alias to Opus 4.5 for Claude Code
      #"ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-5-20251101",
    ],
    var.include_playwright_mcp_browser ? ["PLAYWRIGHT_MCP_BROWSER=chromium"] : []
  )

  common_mounts = [
    { container_path = "/home/coder/.ssh", host_path = "/home/ubuntu/secrets/ssh", read_only = false },
    { container_path = "/home/coder/.config/gcloud", host_path = "/home/ubuntu/secrets/gcloud", read_only = false },
    { container_path = "/home/coder/.pencil", host_path = "/home/ubuntu/secrets/.pencil", read_only = false },
    { container_path = "/home/coder/.gemini", host_path = "/home/ubuntu/secrets/.gemini", read_only = false },
    { container_path = "/home/coder/.codex", host_path = "/home/ubuntu/secrets/.codex", read_only = false },
    { container_path = "/home/coder/.agents", host_path = "/home/ubuntu/secrets/.agents", read_only = false },
    { container_path = "/home/coder/.supermaven", host_path = "/home/ubuntu/secrets/.supermaven", read_only = false },
    # VS Code / code-server extensions are persisted globally across workspaces.
    # Two dirs: "shared" is installed via OpenVSX (code-server + vscode-web both read);
    # "vscode-web" holds MS-marketplace-only extensions (Copilot, Gemini, etc.) that
    # cannot run under code-server. vscode-web sees a merged view (shared + vscode-web).
    { container_path = "/home/coder/.vscode-extensions/shared", host_path = "/home/ubuntu/secrets/extensions/shared", read_only = false },
    { container_path = "/home/coder/.vscode-extensions/vscode-web", host_path = "/home/ubuntu/secrets/extensions/vscode-web", read_only = false },
    # Extension state (auth tokens, saved DB connections, etc.) is persisted
    # globally so AI/DB extensions don't need re-auth in every new workspace.
    # User settings, keybindings, and workspaceStorage stay per-workspace in
    # the home Docker volume so each new workspace starts with image defaults.
    { container_path = "/home/coder/.local/share/code-server/User/globalStorage", host_path = "/home/ubuntu/secrets/code-server-globalstorage", read_only = false },
    { container_path = "/home/coder/.excalidraw", host_path = "/home/ubuntu/secrets/.excalidraw", read_only = false },
    { container_path = "/home/coder/.claude", host_path = "/home/ubuntu/secrets/.claude", read_only = false },
    { container_path = "/home/coder/.context7", host_path = "/home/ubuntu/secrets/.context7", read_only = false },
  ]
}

resource "docker_volume" "home_volume" {
  name = "coder-${var.workspace_id}-home"

  lifecycle {
    ignore_changes = all
  }

  labels {
    label = "coder.owner"
    value = var.owner_name
  }
  labels {
    label = "coder.owner_id"
    value = var.owner_id
  }
  labels {
    label = "coder.workspace_id"
    value = var.workspace_id
  }
  labels {
    label = "coder.workspace_name_at_creation"
    value = var.workspace_name
  }
}

resource "docker_volume" "workspaces_volume" {
  name = "coder-${var.workspace_id}-workspaces"

  lifecycle {
    ignore_changes = all
  }

  labels {
    label = "coder.workspace_id"
    value = var.workspace_id
  }
}

resource "docker_volume" "dind_data" {
  name = "coder-${var.workspace_id}-dind"

  lifecycle {
    ignore_changes = all
  }

  labels {
    label = "coder.workspace_id"
    value = var.workspace_id
  }
}

resource "docker_container" "workspace" {
  count = var.start_count
  image = var.devcontainer_builder_image
  name  = "coder-${var.owner_name}-${lower(var.workspace_name)}"

  hostname = var.workspace_name
  runtime  = "sysbox-runc"

  env = concat(var.docker_env, local.common_env, var.extra_env)

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
  }

  volumes {
    container_path = "/workspaces"
    volume_name    = docker_volume.workspaces_volume.name
    read_only      = false
  }

  volumes {
    container_path = "/var/lib/docker"
    volume_name    = docker_volume.dind_data.name
  }

  dynamic "volumes" {
    for_each = concat(local.common_mounts, var.extra_mounts)
    content {
      container_path = volumes.value.container_path
      host_path      = volumes.value.host_path
      read_only      = volumes.value.read_only
    }
  }

  labels {
    label = "coder.owner"
    value = var.owner_name
  }
  labels {
    label = "coder.owner_id"
    value = var.owner_id
  }
  labels {
    label = "coder.workspace_id"
    value = var.workspace_id
  }
  labels {
    label = "coder.workspace_name"
    value = var.workspace_name
  }
}
