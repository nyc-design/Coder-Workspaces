terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.13.0"
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
  }
}
#rebuild

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

data "coder_external_auth" "github" {
   id = "github-auth"
}

module "workspace_secrets" {
  source = "git::https://github.com/nyc-design/Coder-Workspaces.git//workspace-modules/workspace-secrets?ref=main"
}

locals{
  github_username = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
}

data "coder_parameter" "is_existing_project" {
  name         = "is_existing_project"
  display_name = "Project Type"
  type         = "string"
  default      = "existing"
  description  = "Use an existing GitHub repository or create a new project?"
  order        = 0

  option {
    name  = "Existing Repository"
    value = "existing"
  }
  option {
    name  = "New Project"
    value = "new"
  }
}

data "coder_parameter" "repo_name" {
  count        = data.coder_parameter.is_existing_project.value == "existing" ? 1 : 0
  name         = "repo_name"
  display_name = "GitHub Repository"
  description  = "Enter just the repo name (e.g., shadowscout, stellarscout, etc)."
  type         = "string"
  form_type    = "input"
  order        = 1
}

data "coder_parameter" "gcp_project_name" {
  count        = data.coder_parameter.is_existing_project.value == "existing" ? 1 : 0
  name         = "gcp_project_name"
  display_name = "GCP Project (Optional)"
  default      = ""
  description  = "Enter a GCP Project to automatically configure secrets and credentials"
  type         = "string"
  form_type    = "input"
  order        = 2
}

data "coder_parameter" "new_project_type" {
  count        = data.coder_parameter.is_existing_project.value == "new" ? 1 : 0
  name         = "new_project_type"
  display_name = "New Project Type"
  type         = "string"
  default      = "base"
  order        = 1

  option {
    name  = "Base Project"
    value = "base"
  }
  option {
    name  = "Python Project"
    value = "python"
  }
  option {
    name  = "Next.js Project"
    value = "nextjs"
  }
  option {
    name  = "C++ Project"
    value = "cpp"
  }
  option {
    name  = "Fullstack Project"
    value = "fullstack"
  }
}

data "coder_parameter" "new_project_name" {
  count        = data.coder_parameter.is_existing_project.value == "new" ? 1 : 0
  name         = "project_name"
  display_name = "Project Name"
  type         = "string"
  default      = "my-new-project"
  order        = 2
}

# Step 1: Existing vs New Project
locals {
  # Determine if this is a new project
  is_new_project = data.coder_parameter.is_existing_project.value == "new"
  
  # Project name logic
  project_name = local.is_new_project ? data.coder_parameter.new_project_name[0].value : data.coder_parameter.repo_name[0].value
  
  # Project type for workspace image selection
  project_type = local.is_new_project ? data.coder_parameter.new_project_type[0].value : "base"
  
  # GCP project (optional)
  gcp_project = local.is_new_project == false && data.coder_parameter.gcp_project_name[0].value != "" ? data.coder_parameter.gcp_project_name[0].value : ""
  
  # Container and builder configuration
  git_author_name            = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
  git_author_email           = data.coder_workspace_owner.me.email
  startup_script             = <<-EOT
    set -e

    # Fix ownership that envbuilder's chown may have failed to complete.
    # envbuilder uses filepath.Walk which aborts on ENOENT if a temp file
    # is deleted mid-walk. This find-based approach handles vanishing files.
    for path in /home/coder /workspaces; do
      if [ -d "$path" ]; then
        sudo find "$path" -xdev -not -user coder -exec chown coder:coder {} + 2>/dev/null || true
      fi
    done

    # Prepare user home with default files on first start.
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      touch ~/.init_done
    fi

    /usr/local/bin/init-workspace.sh >> /tmp/workspace-init.log 2>&1 || true
    /usr/local/bin/run-workspace-inits >> /tmp/workspace-init.log 2>&1 || true
  EOT
}


locals {
  new_repo_url = local.is_new_project ? "https://github.com/nyc-design/Project-Scaffolds.git#scaffold/${local.project_type}" : ""

  existing_repo_url = local.is_new_project ? "" : "https://github.com/${local.github_username}/${data.coder_parameter.repo_name[0].value}.git"
   
  repo_url = local.is_new_project ? local.new_repo_url : local.existing_repo_url

}

module "workspace_envbuilder" {
  source                     = "git::https://github.com/nyc-design/Coder-Workspaces.git//workspace-modules/workspace-envbuilder?ref=main"
  agent_token                = coder_agent.main.token
  access_url                 = data.coder_workspace.me.access_url
  init_script                = coder_agent.main.init_script
  docker_config_base64       = module.workspace_secrets.docker_config
  git_username               = data.coder_external_auth.github.access_token
  repo_url                   = local.repo_url
  project_name               = local.project_name
  is_new_project             = local.is_new_project
  fallback_image             = "ghcr.io/nyc-design/workspace-images/base-dev:latest"
  devcontainer_builder_image = "ghcr.io/coder/envbuilder:latest"
}

module "workspace_apps_metadata" {
  source      = "git::https://github.com/nyc-design/Coder-Workspaces.git//workspace-modules/workspace-apps?ref=main"
  enable_apps = false
}

resource "coder_agent" "main" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
  startup_script = local.startup_script

  dir = "/workspaces/${local.project_name}"

  env = {
    GIT_AUTHOR_NAME     = local.git_author_name
    GIT_AUTHOR_EMAIL    = local.git_author_email
    GIT_COMMITTER_NAME  = local.git_author_name
    GIT_COMMITTER_EMAIL = local.git_author_email
  }

  dynamic "metadata" {
    for_each = module.workspace_apps_metadata.agent_metadata_items
    content {
      display_name = metadata.value.display_name
      key          = metadata.value.key
      script       = metadata.value.script
      interval     = metadata.value.interval
      timeout      = metadata.value.timeout
    }
  }






}



module "workspace_runtime" {
  source                     = "git::https://github.com/nyc-design/Coder-Workspaces.git//workspace-modules/workspace-runtime?ref=main"
  start_count                = data.coder_workspace.me.start_count
  devcontainer_builder_image = module.workspace_envbuilder.devcontainer_builder_image
  owner_name                 = data.coder_workspace_owner.me.name
  owner_id                   = data.coder_workspace_owner.me.id
  workspace_id               = data.coder_workspace.me.id
  workspace_name             = data.coder_workspace.me.name
  agent_id                   = coder_agent.main.id
  docker_env                 = module.workspace_envbuilder.docker_env
  github_pat                 = module.workspace_secrets.github_pat
  extra_env = concat(
    [
      "SIGNOZ_URL=${module.workspace_secrets.signoz_url}",
      "SIGNOZ_API_KEY=${module.workspace_secrets.signoz_api_key}",
    ],
    local.is_new_project ? [
      "CODER_NEW_PROJECT=true",
      "NEW_PROJECT_TYPE=${local.project_type}",
      "CODER_PROJECT_NAME=${local.project_name}",
      "CODER_GITHUB_REPO_URL=${local.repo_url}",
    ] : [],
    local.gcp_project != "" ? [
      "CODER_GCP_PROJECT=${local.gcp_project}",
    ] : []
  )

  extra_mounts = [
    { container_path = "/home/coder/.claude", host_path = "/home/ubuntu/secrets/.claude", read_only = false },
    { container_path = "/home/coder/.claude.json", host_path = "/home/ubuntu/secrets/.claude.json", read_only = false },
    { container_path = "/home/coder/.cache/google-vscode-extension", host_path = "/home/ubuntu/secrets/google-vscode-extension", read_only = false },
  ]
}

module "workspace_apps" {
  count        = data.coder_workspace.me.start_count
  source       = "git::https://github.com/nyc-design/Coder-Workspaces.git//workspace-modules/workspace-apps?ref=main"
  agent_id     = coder_agent.main.id
  project_name = local.project_name
  enable_apps  = true
}
