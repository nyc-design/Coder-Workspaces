
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
    { container_path = "/home/coder/.local/share/code-server", host_path = "/home/ubuntu/secrets/code-server", read_only = false },
    { container_path = "/home/coder/.excalidraw", host_path = "/home/ubuntu/secrets/.excalidraw", read_only = false },
    { container_path = "/home/coder/.claude", host_path = "/home/ubuntu/secrets/.claude", read_only = false },
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

  volumes {
    container_path = "/var/run/docker.sock"
    host_path      = "/var/run/docker.sock"
    read_only      = false
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
