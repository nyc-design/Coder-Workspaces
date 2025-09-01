terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">=2.4.0"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
    envbuilder = {
      source = "coder/envbuilder"
    }
    google = {
      source = "hashicorp/google"
      version = "7.0.1"
    }
    github = {
      source = "integrations/github"
      version = "6.6.0"
    }
  }
}

provider "coder" {}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

provider "docker" {}

provider "envbuilder" {}

provider "google" {
  project = "coder-nt"
  region  = "us-central1"
  zone    = "us-central1-c"
}

data "google_projects" "gcp_projects" {
  filter = "lifecycleState:ACTIVE"
}

data "google_secret_manager_secret_version" "github_pat" {
  secret = "GH_PAT"
}

data "google_secret_manager_secret_version" "docker_config" {
  secret = "DOCKER_CONFIG"
}

data "coder_external_auth" "github" {
   id = "github-auth"
}

provider "github" {
  token = data.google_secret_manager_secret_version.github_pat.secret_data
}

locals{
  github_username = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
}

data "github_repositories" "user_repositories" {
  query = "user:nyc-design"
  include_repo_id = true
}

data "coder_parameter" "repo_name" {
  name         = "repo_name"
  display_name = "GitHub Repository"
  type = "string"

  form_type = "dropdown"

  dynamic "option" {
    for_each = data.github_repositories.user_repositories.names
    content {
      name  = option.value
      value = option.value
    }
  }
}

data "coder_parameter" "project_name" {
  name         = "project_name"
  display_name = "Select your GCP Project"
  type         = "string"
  form_type    = "dropdown"

  dynamic "option" {
    for_each = { for p in data.google_projects.gcp_projects.projects : p.project_id => p }
    content {
      name  = coalesce(option.value.name, option.value.project_id)
      value = option.value.project_id
    }
  }
}

locals {
  repo_url = "https://github.com/${local.github_username}/${data.coder_parameter.repo_name.value}.git"
  cache_repo = "us-central1-docker.pkg.dev/coder-nt/envbuilder-cache/envbuilder"
}

locals {
  container_name             = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  devcontainer_builder_image = "ghcr.io/coder/envbuilder:latest"
  git_author_name            = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
  git_author_email           = data.coder_workspace_owner.me.email
  # The envbuilder provider requires a key-value map of environment variables.
  envbuilder_env = {
    "CODER_AGENT_TOKEN" : coder_agent.main.token,
    # Use the docker gateway if the access URL is 127.0.0.1
    "CODER_AGENT_URL" : replace(data.coder_workspace.me.access_url, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal"),
    # Use the docker gateway if the access URL is 127.0.0.1
    "ENVBUILDER_INIT_SCRIPT" : replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal"),
    "ENVBUILDER_FALLBACK_IMAGE" : "us-central1-docker.pkg.dev/coder-nt/workspace-images/base-dev:latest",
    "ENVBUILDER_DOCKER_CONFIG_BASE64" : data.google_secret_manager_secret_version.docker_config.secret_data,
    "ENVBUILDER_PUSH_IMAGE" : "true",
    "ENVBUILDER_GIT_USERNAME" : data.coder_external_auth.github.access_token,
  }
  # Convert the above map to the format expected by the docker provider.
  docker_env = [
    for k, v in local.envbuilder_env : "${k}=${v}"
  ]
}

resource "docker_image" "devcontainer_builder_image" {
  name         = local.devcontainer_builder_image
  keep_locally = true
}

resource "envbuilder_cached_image" "cached" {
  count         = 1
  builder_image = local.devcontainer_builder_image
  git_url       = local.repo_url
  cache_repo    = local.cache_repo
  extra_env     = local.envbuilder_env
}

resource "coder_agent" "main" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
  startup_script = <<-EOT
    set -e
    
    /usr/local/bin/init-workspace.sh >> /tmp/workspace-init.log 2>&1 || true
    /usr/local/bin/run-workspace-inits >> /tmp/workspace-init.log 2>&1 || true

    # Prepare user home with default files on first start.
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      touch ~/.init_done
    fi

    # Add any commands that should be executed at workspace startup (e.g install requirements, start a program, etc) here
  EOT

  dir = "/workspaces/${data.coder_parameter.repo_name.value}"

  env = {
    GIT_AUTHOR_NAME     = local.git_author_name
    GIT_AUTHOR_EMAIL    = local.git_author_email
    GIT_COMMITTER_NAME  = local.git_author_name
    GIT_COMMITTER_EMAIL = local.git_author_email
  }

    metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    # get load avg scaled by number of cores
    script   = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval = 60
    timeout  = 1
  }

  metadata {
    display_name = "Swap Usage (Host)"
    key          = "7_swap_host"
    script       = <<EOT
      free -b | awk '/^Swap/ { printf("%.1f/%.1f", $3/1024.0/1024.0/1024.0, $2/1024.0/1024.0/1024.0) }'
    EOT
    interval     = 10
    timeout      = 1
  }
}

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
  # Protect the volume from being deleted due to changes in attributes.
  lifecycle {
    ignore_changes = all
  }
  # Add labels in Docker to keep track of orphan resources.
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  # This field becomes outdated if the workspace is renamed but can
  # be useful for debugging or cleaning out dangling volumes.
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

resource "docker_volume" "workspaces_volume" {
  name = "coder-${data.coder_workspace.me.id}-workspaces"
  lifecycle { ignore_changes = all }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_volume" "dind_data" {
  name = "coder-${data.coder_workspace.me.id}-dind"
  lifecycle { ignore_changes = all }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = envbuilder_cached_image.cached.0.image
  # Uses lower() to avoid Docker restriction on container names.
  name = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  # Hostname makes the shell more user friendly: coder@my-workspace:~$
  hostname = data.coder_workspace.me.name

  runtime = "sysbox-runc"

  env = concat(
    envbuilder_cached_image.cached[0].env,
    [
      "GH_TOKEN=${data.google_secret_manager_secret_version.github_pat.secret_data}",
      "GITHUB_TOKEN=${data.google_secret_manager_secret_version.github_pat.secret_data}",
      "GITHUB_PAT=${data.google_secret_manager_secret_version.github_pat.secret_data}",
    ]
  )

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
    container_path = "/home/coder/.ssh"
    host_path      = "/home/ubuntu/secrets/ssh"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.config/gcloud"
    host_path      = "/home/ubuntu/secrets/gcloud"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.claude"
    host_path      = "/home/ubuntu/secrets/.claude"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.claude.json"
    host_path      = "/home/ubuntu/secrets/.claude.json"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.codex"
    host_path      = "/home/ubuntu/secrets/.codex"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.local/share/code-server"
    host_path      = "/home/ubuntu/secrets/code-server"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.cache/google-vscode-extension"
    host_path      = "/home/ubuntu/secrets/google-vscode-extension"
    read_only      = false
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}

module "cursor" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/cursor/coder"
  version  = "1.2.1"
  agent_id = coder_agent.main.id
  folder = "/workspaces/${data.coder_parameter.repo_name.value}"
}

# See https://registry.coder.com/modules/coder/code-server
module "code-server" {
  count  = data.coder_workspace.me.start_count
  source = "registry.coder.com/coder/code-server/coder"
  folder = "/workspaces/${data.coder_parameter.repo_name.value}"

  agent_id = coder_agent.main.id
  order    = 1

  settings = {
    "workbench.colorTheme" = "Default Dark Modern",
    "git.useIntegratedAskPass": "false"
  }

  extensions = [
    "GitHub.vscode-github-actions",
    "Anthropic.claude-code",
    "mongodb.mongodb-vscode"
  ]
}