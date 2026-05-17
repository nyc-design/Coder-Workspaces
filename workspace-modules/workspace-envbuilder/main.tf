
terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
    }
    envbuilder = {
      source = "coder/envbuilder"
    }
  }
}

locals {
  # Runs as root in the built container after envbuilder's build phase and
  # before the init script (which launches `coder agent`). Closes the race
  # between envbuilder's own chown and the agent's own init code: the agent
  # runs cli/gitauth.OverrideVSCodeConfigs very early during boot, which does
  # MkdirAll(/home/coder/.local/share/code-server/Machine). If /home/coder is
  # still root-owned at that moment, the mkdir fails and the workspace's git
  # credentials never make it into VS Code's git auth provider for the first
  # session. Doing the chown here guarantees ownership is correct before the
  # agent process exists, eliminating the race entirely.
  envbuilder_setup_script = <<-EOT
    for path in /home/coder /workspaces; do
      if [ -d "$path" ]; then
        find "$path" -xdev -not -user coder -exec chown coder:coder {} + 2>/dev/null || true
      fi
    done
    exit 0
  EOT

  # Order: agent_env first so envbuilder/coder-token keys (which the
  # module owns) win on conflict, then the is_new_project flags last
  # so they're authoritative for that workspace lifecycle state.
  envbuilder_env = merge(var.agent_env, {
    "CODER_AGENT_TOKEN"               = var.agent_token
    "CODER_AGENT_URL"                 = replace(var.access_url, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")
    "ENVBUILDER_SETUP_SCRIPT"         = local.envbuilder_setup_script
    "ENVBUILDER_INIT_SCRIPT"          = replace(var.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")
    "ENVBUILDER_FALLBACK_IMAGE"       = var.fallback_image
    "ENVBUILDER_DOCKER_CONFIG_BASE64" = var.docker_config_base64
    "ENVBUILDER_PUSH_IMAGE"           = "false"
    "ENVBUILDER_GIT_USERNAME"         = var.git_username
    "ENVBUILDER_GIT_URL"              = var.repo_url
    "ENVBUILDER_WORKSPACE_FOLDER"     = "/workspaces/${var.project_name}"
    }, var.is_new_project ? {
    "CODER_NEW_PROJECT"  = "true"
    "CODER_PROJECT_NAME" = var.project_name
  } : {})

  docker_env = [for k, v in local.envbuilder_env : "${k}=${v}"]
}

resource "docker_image" "devcontainer_builder_image" {
  name         = var.devcontainer_builder_image
  keep_locally = true
}

resource "envbuilder_cached_image" "cached" {
  count         = 0
  builder_image = var.devcontainer_builder_image
  git_url       = var.repo_url
  cache_repo    = ""
  extra_env     = local.envbuilder_env
}
