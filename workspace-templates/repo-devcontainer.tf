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
  project = "coder-nt"  # Default project, will be overridden by resources if needed
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

locals {
  # Basic user info (only variables that don't reference parameters)
  github_username = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
}

data "github_repositories" "user_repositories" {
  query = "user:nyc-design"
  include_repo_id = true
}

# Step 1: Existing vs New Project
data "coder_parameter" "is_existing_project" {
  name         = "is_existing_project"
  display_name = "Project Type"
  type         = "bool"
  default      = true
  description  = "Use an existing GitHub repository or create a new project?"
  
  option {
    name  = "Existing Repository"
    value = true
  }
  option {
    name  = "New Project"
    value = false
  }
}

# Step 2a: For existing projects - select repository (required)
data "coder_parameter" "repo_name" {
  name         = "repo_name"
  display_name = "GitHub Repository"
  type         = "string"
  condition    = data.coder_parameter.is_existing_project.value == true

  form_type = "dropdown"

  dynamic "option" {
    for_each = data.github_repositories.user_repositories.names
    content {
      name  = option.value
      value = option.value
    }
  }
}

# Step 2b: For new projects - select project type
data "coder_parameter" "new_project_type" {
  name         = "new_project_type"
  display_name = "New Project Type"
  type         = "string"
  default      = "base"
  condition    = data.coder_parameter.is_existing_project.value == false
  
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

# Step 3: For new projects - project name and GitHub repo creation
data "coder_parameter" "project_name" {
  name         = "project_name"
  display_name = "Project Name"
  type         = "string"
  default      = "my-new-project"
  condition    = data.coder_parameter.is_existing_project.value == false
}

data "coder_parameter" "create_github_repo" {
  name         = "create_github_repo"
  display_name = "Create GitHub Repository"
  type         = "bool"
  default      = true
  condition    = data.coder_parameter.is_existing_project.value == false
  description  = "Create a new GitHub repository for this project?"
}

# Step 4: Optional GCP Project Selection  
data "coder_parameter" "gcp_project_name" {
  name         = "gcp_project_name"
  display_name = "GCP Project (Optional)"
  type         = "string"
  default      = ""
  form_type    = "dropdown"
  description  = "Select a GCP project to automatically configure secrets and credentials"

  option {
    name  = "None (Skip GCP integration)"
    value = ""
  }

  dynamic "option" {
    for_each = { for p in data.google_projects.gcp_projects.projects : p.project_id => p }
    content {
      name  = coalesce(option.value.name, option.value.project_id)
      value = option.value.project_id
    }
  }
}

# Main locals block - defined after all parameters
locals {
  # Determine if this is a new project
  is_new_project = !data.coder_parameter.is_existing_project.value
  
  # Project name logic
  project_name = local.is_new_project ? data.coder_parameter.project_name.value : data.coder_parameter.repo_name.value
  
  # Project type for workspace image selection
  project_type = local.is_new_project ? data.coder_parameter.new_project_type.value : "base"
  
  # Repository URL (only used for existing projects)  
  repo_url = local.is_new_project ? "" : "https://github.com/${local.github_username}/${data.coder_parameter.repo_name.value}.git"
  
  # GCP project (optional)
  gcp_project = data.coder_parameter.gcp_project_name.value != "" ? data.coder_parameter.gcp_project_name.value : "coder-nt"
  
  # Workspace image mapping
  workspace_image_map = {
    "base"        = "us-central1-docker.pkg.dev/coder-nt/workspace-images/base-dev:latest"
    "python"      = "us-central1-docker.pkg.dev/coder-nt/workspace-images/python-dev:latest"
    "nextjs"      = "us-central1-docker.pkg.dev/coder-nt/workspace-images/nextjs-dev:latest"
    "cpp"         = "us-central1-docker.pkg.dev/coder-nt/workspace-images/cpp-dev:latest"
    "fullstack"   = "us-central1-docker.pkg.dev/coder-nt/workspace-images/fullstack-dev:latest"
  }
  
  cache_repo = "us-central1-docker.pkg.dev/coder-nt/envbuilder-cache/envbuilder"
    
  # Container and builder configuration
  container_name             = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  devcontainer_builder_image = "ghcr.io/coder/envbuilder:latest"
  git_author_name            = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
  git_author_email           = data.coder_workspace_owner.me.email
}

# Create GitHub repository for new projects (if requested)
resource "github_repository" "new_repo" {
  count       = local.is_new_project && data.coder_parameter.create_github_repo.value ? 1 : 0
  name        = local.project_name
  description = "Created with Coder workspace template"
  
  visibility = "private"
  
  # Initialize with README
  auto_init = true
  
  # Add .gitignore based on project type
  gitignore_template = local.project_type == "python" ? "Python" : (
    local.project_type == "nextjs" ? "Node" : (
      local.project_type == "cpp" ? "C++" : "Global"
    )
  )
  
  # Default branch
  default_branch = "main"
  
  # Repository settings
  has_issues    = true
  has_projects  = true
  has_wiki      = false
  
  # Security settings
  vulnerability_alerts   = true
  delete_branch_on_merge = true
  
  lifecycle {
    ignore_changes = [
      # Ignore changes to these after creation to allow manual management
      description,
      has_issues,
      has_projects,
      has_wiki,
    ]
  }
}

# Output the created repository URL for reference
# final_repo_url is now defined in the main locals block to avoid forward references

resource "docker_image" "devcontainer_builder_image" {
  name         = local.devcontainer_builder_image
  keep_locally = true
}

resource "envbuilder_cached_image" "cached" {
  count         = !local.is_new_project ? 1 : 0
  builder_image = local.devcontainer_builder_image
  git_url       = local.final_repo_url
  cache_repo    = local.cache_repo
  extra_env     = local.envbuilder_env
}

# For new projects, use the workspace image directly
resource "docker_image" "new_project_image" {
  count        = local.is_new_project ? 1 : 0
  name         = local.workspace_image_map[data.coder_parameter.project_type.value]
  keep_locally = true
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

  dir = "/workspaces/${local.project_name}"

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

# Additional locals that depend on coder_agent resource
locals {
  # Update repo_url for new projects with GitHub repo creation
  final_repo_url = local.is_new_project && data.coder_parameter.create_github_repo.value ? 
    github_repository.new_repo[0].clone_url : local.repo_url
    
  # The envbuilder provider requires a key-value map of environment variables.
  envbuilder_env = merge({
    "CODER_AGENT_TOKEN" : coder_agent.main.token,
    # Use the docker gateway if the access URL is 127.0.0.1
    "CODER_AGENT_URL" : replace(data.coder_workspace.me.access_url, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal"),
    # Use the docker gateway if the access URL is 127.0.0.1
    "ENVBUILDER_INIT_SCRIPT" : replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal"),
    "ENVBUILDER_FALLBACK_IMAGE" : local.workspace_image_map[local.project_type],
    "ENVBUILDER_DOCKER_CONFIG_BASE64" : data.google_secret_manager_secret_version.docker_config.secret_data,
    "ENVBUILDER_PUSH_IMAGE" : "true",
    "ENVBUILDER_GIT_USERNAME" : data.coder_external_auth.github.access_token,
  }, local.is_new_project ? {
    # New project environment variables
    "CODER_NEW_PROJECT" : "true",
    "CODER_PROJECT_NAME" : local.project_name,
  } : {})
  
  # Convert the above map to the format expected by the docker provider.
  docker_env = [
    for k, v in local.envbuilder_env : "${k}=${v}"
  ]
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
  image = local.is_new_project ? local.workspace_image_map[local.project_type] : envbuilder_cached_image.cached.0.image
  # Uses lower() to avoid Docker restriction on container names.
  name = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  # Hostname makes the shell more user friendly: coder@my-workspace:~$
  hostname = data.coder_workspace.me.name

  runtime = "sysbox-runc"

  env = concat(
    local.is_new_project ? [] : envbuilder_cached_image.cached[0].env,
    [
      "GH_TOKEN=${data.google_secret_manager_secret_version.github_pat.secret_data}",
      "GITHUB_TOKEN=${data.google_secret_manager_secret_version.github_pat.secret_data}",
      "GITHUB_PAT=${data.google_secret_manager_secret_version.github_pat.secret_data}",
    ],
    local.is_new_project ? [
      "CODER_NEW_PROJECT=true",
      "CODER_PROJECT_NAME=${local.project_name}",
      "CODER_GITHUB_REPO_URL=${local.final_repo_url}",
    ] : [],
    data.coder_parameter.gcp_project_name.value != "" ? [
      "CODER_GCP_PROJECT=${data.coder_parameter.gcp_project_name.value}",
    ] : []
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
  folder = "/workspaces/${local.project_name}"
}

# See https://registry.coder.com/modules/coder/code-server
module "code-server" {
  count  = data.coder_workspace.me.start_count
  source = "registry.coder.com/coder/code-server/coder"
  folder = "/workspaces/${local.project_name}"

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