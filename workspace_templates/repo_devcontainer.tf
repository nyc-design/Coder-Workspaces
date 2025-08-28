terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.0"
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
    "ENVBUILDER_FALLBACK_IMAGE" : "codercom/enterprise-base:ubuntu",
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
  startup_script_behavior = "blocking"
  startup_script = <<-EOT
    set -eu

    log() { printf '[startup] %s\n' "$*"; }

    log "fixing /run and /var/run perms"
    sudo mkdir -p /run /var/run
    # ensure traversal for non-root; this was 0700 before
    sudo chmod 755 /run || true
    sudo chmod 755 /var/run || true

    # deps some base images lack (idempotent)
    if ! command -v iptables >/dev/null 2>&1; then
      log "installing iptables & ca-certificates"
      sudo apt-get update -y
      sudo apt-get install -y --no-install-recommends iptables ca-certificates
    fi

    log "starting dockerd"
    # Start a fresh per-workspace daemon on the unix socket
    sudo nohup dockerd --host=unix:///var/run/docker.sock --storage-driver=overlay2 > /tmp/dockerd.log 2>&1 &

    # Wait for the socket to appear (check as root to avoid permission races)
    for i in $(seq 1 60); do
      if sudo test -S /var/run/docker.sock; then
        break
      fi
      sleep 0.5
    done

    if ! sudo test -S /var/run/docker.sock; then
      log "dockerd socket never appeared; tailing logs"
      sudo tail -n 200 /var/log/docker.log || true
      exit 1
    fi

    # Give immediate access to the current shell without re-login:
    # make coder the owner; keep least-privileged perms (rw for owner, rw for group if you prefer)
    log "setting socket ownership & perms"
    sudo chown coder:coder /var/run/docker.sock
    sudo chmod 660         /var/run/docker.sock

    # Also expose at /run for tools that look there
    [ -S /run/docker.sock ] || sudo ln -sf /var/run/docker.sock /run/docker.sock

    # Optional: also add coder to docker group for future shells (not required for current one)
    sudo groupadd -f docker
    sudo usermod -aG docker coder || true

    # Sanity check without sudo; print logs if it fails
    if ! docker info >/dev/null 2>&1; then
      log "docker info failed; tailing log"
      sudo tail -n 200 /var/log/docker.log || true
      exit 1
    fi
    log "dockerd is ready"

    # add colored prompt once
    if ! grep -q 'custom colored prompt' /home/coder/.bashrc 2>/dev/null; then
      cat >> /home/coder/.bashrc <<'EOF'
    # --- custom colored prompt ---
    force_color_prompt=yes
    PS1='$${debian_chroot:+($${debian_chroot})}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
    # -----------------------------
    EOF
    fi
EOT

  dir = "/workspaces/${data.coder_parameter.repo_name.value}"

  env = {
    GIT_AUTHOR_NAME     = local.git_author_name
    GIT_AUTHOR_EMAIL    = local.git_author_email
    GIT_COMMITTER_NAME  = local.git_author_name
    GIT_COMMITTER_EMAIL = local.git_author_email
    GITHUB_TOKEN = data.google_secret_manager_secret_version.github_pat.secret_data

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
}