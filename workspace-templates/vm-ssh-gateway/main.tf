terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.13.0"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

provider "coder" {}
provider "docker" {}

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

  validation {
    regex = "^[A-Za-z0-9:][A-Za-z0-9.:-]*$"
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

  # The one shared key, from the host's secrets mount. Its public half must be
  # in ~/.ssh/authorized_keys on every VM this template is pointed at.
  ssh_key_path = "/home/coder/secrets/ssh/id_ed25519"

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
      key          = "2_${metadata.value.key}"
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

data "docker_registry_image" "workspace" {
  name = local.workspace_image
}

resource "docker_image" "workspace" {
  name          = data.docker_registry_image.workspace.name
  pull_triggers = [data.docker_registry_image.workspace.sha256_digest]
  keep_locally  = true
}

# Holds editor state and ~/.ssh (config, known_hosts) for this one VM.
resource "docker_volume" "home" {
  name = "coder-${data.coder_workspace.me.id}-home"

  lifecycle {
    ignore_changes = all
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
}

locals {
  # A subset of workspace-runtime's host mounts: the shared extension cache
  # and the Claude Code login, so the editor and Claude behave as in any
  # other workspace. The host's ssh directory is mounted read-only at a side
  # path, NOT at ~/.ssh as workspace-runtime does: this template rewrites
  # ~/.ssh/config, and that must never touch the directory other workspaces
  # share.
  host_mounts = [
    { container_path = "/home/coder/secrets/ssh", host_path = "/home/ubuntu/secrets/ssh", read_only = true },
    { container_path = "/home/coder/.vscode-extensions/shared", host_path = "/home/ubuntu/secrets/extensions/shared", read_only = false },
    { container_path = "/home/coder/.vscode-extensions/vscode-web", host_path = "/home/ubuntu/secrets/extensions/vscode-web", read_only = false },
    { container_path = "/home/coder/.local/share/code-server/User/globalStorage", host_path = "/home/ubuntu/secrets/code-server-globalstorage", read_only = false },
    { container_path = "/home/coder/.claude", host_path = "/home/ubuntu/secrets/.claude", read_only = false },
    { container_path = "/home/coder/.claude.json", host_path = "/home/ubuntu/secrets/.claude.json", read_only = false },
  ]
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = docker_image.workspace.image_id
  name  = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"

  hostname = data.coder_workspace.me.name
  runtime  = "sysbox-runc"

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "CODER_AGENT_URL=${replace(data.coder_workspace.me.access_url, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")}",
  ]

  command = ["sh", "-c", coder_agent.main.init_script]

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home.name
    read_only      = false
  }

  dynamic "volumes" {
    for_each = local.host_mounts
    content {
      container_path = volumes.value.container_path
      host_path      = volumes.value.host_path
      read_only      = volumes.value.read_only
    }
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
