terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.13.0"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
    google = {
      source  = "hashicorp/google"
      version = "7.0.1"
    }
  }
}

provider "coder" {}
provider "docker" {}

provider "google" {
  project = "coder-nt"
  region  = "us-central1"
  zone    = "us-central1-c"
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# ── Parameters ───────────────────────────────────────────────────────────────
# Only the address is required. Every value below ends up in an SSH config and
# on command lines, so each one is validated against a strict pattern.

data "coder_parameter" "vm_host" {
  name         = "vm_host"
  display_name = "VM IP Address"
  description  = "IP address or DNS name of the VM to open in code-server."
  type         = "string"
  form_type    = "input"
  mutable      = true
  order        = 1

  # The empty alternative is only for template import, which plans with no
  # parameter values. The parameter has no default, so the create form still
  # requires one, and vm-gateway.sh refuses to run with an empty host.
  validation {
    regex = "^$|^[A-Za-z0-9:][A-Za-z0-9.:-]*$"
    error = "Enter an IP address or hostname (letters, digits, '.', ':' and '-' only)."
  }
}

data "coder_parameter" "vm_user" {
  name         = "vm_user"
  display_name = "SSH User"
  description  = "Login user on the VM. Oracle's Ubuntu images use 'ubuntu'; Oracle Linux uses 'opc'."
  type         = "string"
  default      = "ubuntu"
  form_type    = "input"
  mutable      = true
  order        = 2

  validation {
    regex = "^[a-z_][a-z0-9_.-]*$"
    error = "Enter a valid Linux username."
  }
}

data "coder_parameter" "vm_port" {
  name         = "vm_port"
  display_name = "SSH Port"
  type         = "number"
  default      = 22
  mutable      = true
  order        = 3

  validation {
    min = 1
    max = 65535
  }
}

data "coder_parameter" "remote_dir" {
  name         = "remote_dir"
  display_name = "Folder to Open"
  description  = "Absolute path on the VM to open, e.g. /home/ubuntu or /home/neil/myproject. Leave empty for the SSH user's home directory."
  type         = "string"
  default      = ""
  form_type    = "input"
  mutable      = true
  order        = 4

  validation {
    regex = "^$|^/[A-Za-z0-9._/-]*$"
    error = "Enter an absolute path starting with '/' (letters, digits, '.', '_', '-' and '/' only), or leave empty."
  }
}

locals {
  # base-dev supplies code-server, the extension/settings init pipeline, and
  # the AI CLIs. Everything runs here; nothing is installed on the VM.
  workspace_image = "ghcr.io/nyc-design/workspace-images/base-dev:latest"

  # This template's own key ("Coder Workspace SSH"), from the host's secrets
  # mount. Its public half must be in ~/.ssh/authorized_keys on every VM this
  # template is pointed at.
  ssh_key_path = "/home/coder/secrets/ssh/coder_workspace_ssh"

  git_author_name = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)

  # Written by scripts/vm-gateway.sh; holds the VM's ssh:// folder.
  workspace_file = "/home/coder/vm.code-workspace"

  # "/home/neil/" and "/home/neil" mean the same folder.
  remote_dir = data.coder_parameter.remote_dir.value == "/" ? "/" : trimsuffix(data.coder_parameter.remote_dir.value, "/")

  vm_presets = {
    watchparty-vm = { vm_host = "170.9.232.54", vm_user = "neil", remote_dir = "/home/neil" }
    neil-dev      = { vm_host = "163.192.217.205", vm_user = "ubuntu", remote_dir = "/home/ubuntu" }
  }

  # vm-gateway.sh feeds the image's init pipeline, so `configure` has to run
  # before workspace-startup's run-workspace-inits. `check` runs last and may
  # fail the startup script (VM unreachable, key rejected) without stopping
  # the editor from coming up.
  startup_script = join("\n", [
    "cat > /tmp/vm-gateway.sh <<'VM_GATEWAY_SCRIPT_EOF'",
    file("${path.module}/scripts/vm-gateway.sh"),
    "VM_GATEWAY_SCRIPT_EOF",
    "bash /tmp/vm-gateway.sh configure || true",
    module.workspace_startup.startup_script,
    "bash /tmp/vm-gateway.sh check",
  ])
}

data "coder_workspace_preset" "vms" {
  for_each = local.vm_presets

  name        = each.key
  description = "${each.value.vm_user}@${each.value.vm_host}:${each.value.remote_dir}"
  icon        = "/icon/terminal.svg"

  parameters = {
    vm_host    = each.value.vm_host
    vm_user    = each.value.vm_user
    remote_dir = each.value.remote_dir
  }
}

module "workspace_secrets" {
  source = "git::https://github.com/nyc-design/Coder-Workspaces.git//workspace-modules/workspace-secrets?ref=main"
}

module "workspace_startup" {
  source = "git::https://github.com/nyc-design/Coder-Workspaces.git//workspace-modules/workspace-startup?ref=main"
}

module "workspace_apps_metadata" {
  source      = "git::https://github.com/nyc-design/Coder-Workspaces.git//workspace-modules/workspace-apps?ref=main"
  enable_apps = false
}

# ── Agent ────────────────────────────────────────────────────────────────────
# Parameters reach the scripts as environment variables rather than being
# templated into them.

resource "coder_agent" "main" {
  os             = "linux"
  arch           = data.coder_provisioner.me.arch
  dir            = "/home/coder"
  startup_script = local.startup_script

  env = {
    VM_HOST           = data.coder_parameter.vm_host.value
    VM_USER           = data.coder_parameter.vm_user.value
    VM_PORT           = tostring(data.coder_parameter.vm_port.value)
    VM_REMOTE_DIR     = local.remote_dir
    VM_SSH_KEY_SOURCE = local.ssh_key_path
    VM_WORKSPACE_FILE = local.workspace_file

    GIT_AUTHOR_NAME     = local.git_author_name
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = local.git_author_name
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email

    CODER_AGENT_EXP_SKILLS_DIRS = "~/.agents/skills,.agents/skills"
  }

  display_apps {
    web_terminal    = true
    vscode          = false
    vscode_insiders = false
    ssh_helper      = false
  }

  metadata {
    display_name = "VM"
    key          = "0_vm_target"
    script       = "echo \"$VM_USER@$VM_HOST:$VM_PORT\""
    interval     = 600
    timeout      = 1
  }

  metadata {
    display_name = "VM Link"
    key          = "1_vm_link"
    script       = "ssh -o ConnectTimeout=3 vm true < /dev/null > /dev/null 2>&1 && echo connected || echo unreachable"
    interval     = 30
    timeout      = 5
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

# ── Apps ─────────────────────────────────────────────────────────────────────
# The shared code-server launcher and app, pointed at the VM's ssh:// folder
# instead of a /workspaces project. The other editors are off: only
# code-server has been set up and tested against an ssh:// folder.

module "workspace_apps" {
  count                 = data.coder_workspace.me.start_count
  source                = "git::https://github.com/nyc-design/Coder-Workspaces.git//workspace-modules/workspace-apps?ref=main"
  agent_id              = coder_agent.main.id
  enable_apps           = true
  code_server_query     = "workspace=${urlencode(local.workspace_file)}"
  enable_vscode_web     = false
  enable_vscode_desktop = false
  enable_filebrowser    = false
  enable_neovim         = false
}

resource "coder_app" "vm_terminal" {
  agent_id     = coder_agent.main.id
  slug         = "vm-terminal"
  display_name = "VM Terminal"
  icon         = "/icon/terminal.svg"
  command      = "ssh vm"
  order        = 2
}

# ── Workspace container ──────────────────────────────────────────────────────
# The shared runtime module, running base-dev directly instead of envbuilder.
#
# Only the image half of workspace-devcontainer is used: it resolves the tag to
# its current digest on every start, pulls that digest if the host lacks it, and
# removes the versions it supersedes. There is no repository to clone here, so
# `repo` is empty and the module's entrypoint, env and startup-script outputs
# (and the inputs that only feed them) are unused.

module "workspace_image" {
  source           = "git::https://github.com/nyc-design/Coder-Workspaces.git//workspace-modules/workspace-devcontainer?ref=main"
  start_count      = data.coder_workspace.me.start_count
  repo             = ""
  fallback_image   = local.workspace_image
  agent_token      = ""
  access_url       = ""
  init_script      = ""
  workspace_folder = ""
}

module "workspace_runtime" {
  source                     = "git::https://github.com/nyc-design/Coder-Workspaces.git//workspace-modules/workspace-runtime?ref=main"
  start_count                = data.coder_workspace.me.start_count
  devcontainer_builder_image = module.workspace_image.image_id
  owner_name                 = data.coder_workspace_owner.me.name
  owner_id                   = data.coder_workspace_owner.me.id
  workspace_id               = data.coder_workspace.me.id
  workspace_name             = data.coder_workspace.me.name
  agent_id                   = coder_agent.main.id
  github_pat                 = module.workspace_secrets.github_pat
  command                    = ["sh", "-c", coder_agent.main.init_script]

  docker_env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "CODER_AGENT_URL=${replace(data.coder_workspace.me.access_url, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")}",
  ]

  extra_mounts = [
    { container_path = "/home/coder/.claude.json", host_path = "/home/ubuntu/secrets/.claude.json", read_only = false }
  ]
}
