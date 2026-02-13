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

data "coder_parameter" "workspace_image" {
  name         = "workspace_image"
  display_name = "Workspace Image"
  description  = "Container image where code-server runs."
  type         = "string"
  default      = "codercom/enterprise-base:ubuntu-20250929"
  form_type    = "input"
  order        = 1
}

data "coder_parameter" "workspace_dir" {
  name         = "workspace_dir"
  display_name = "Workspace Directory"
  description  = "Folder opened by code-server."
  type         = "string"
  default      = "/workspaces/vm-gateway"
  form_type    = "input"
  order        = 2
}

data "coder_parameter" "vm_host" {
  name         = "vm_host"
  display_name = "Bare VM Host"
  description  = "IP or DNS name of your bare VM."
  type         = "string"
  default      = ""
  form_type    = "input"
  order        = 3
}

data "coder_parameter" "vm_user" {
  name         = "vm_user"
  display_name = "Bare VM User"
  description  = "SSH username for your bare VM."
  type         = "string"
  default      = "ubuntu"
  form_type    = "input"
  order        = 4
}

data "coder_parameter" "vm_port" {
  name         = "vm_port"
  display_name = "Bare VM SSH Port"
  description  = "SSH port on your bare VM."
  type         = "string"
  default      = "22"
  form_type    = "input"
  order        = 5
}

data "coder_parameter" "remote_path" {
  name         = "remote_path"
  display_name = "Remote Path"
  description  = "Path on bare VM to mount into this workspace via SSHFS."
  type         = "string"
  default      = "/home/ubuntu"
  form_type    = "input"
  order        = 6
}

data "coder_parameter" "auto_mount_remote" {
  name         = "auto_mount_remote"
  display_name = "Auto-mount Remote Files"
  description  = "Mount /workspaces/remote-vm to the bare VM path at startup using SSHFS."
  type         = "bool"
  default      = true
  order        = 7
}

data "coder_parameter" "ssh_key_filename" {
  name         = "ssh_key_filename"
  display_name = "SSH Key Filename"
  description  = "Private key filename under /home/coder/secrets/ssh (e.g., id_ed25519)."
  type         = "string"
  default      = "id_ed25519"
  form_type    = "input"
  order        = 8
}

locals {
  workspace_image     = data.coder_parameter.workspace_image.value
  workspace_dir       = data.coder_parameter.workspace_dir.value
  project_name        = trimprefix(data.coder_parameter.workspace_dir.value, "/workspaces/")
  vm_host             = data.coder_parameter.vm_host.value
  vm_user             = data.coder_parameter.vm_user.value
  vm_port             = data.coder_parameter.vm_port.value
  remote_path         = data.coder_parameter.remote_path.value
  auto_mount_remote   = data.coder_parameter.auto_mount_remote.value
  ssh_key_filename    = data.coder_parameter.ssh_key_filename.value

  vm_presets = {
    vm1 = {
      name          = "watchparty-vm"
      description   = "Preset for watchparty-vm (170.9.232.54)"
      icon          = "/icon/terminal.svg"
      workspace_dir = "/workspaces/vm1-gateway"
      vm_host       = "170.9.232.54"
      vm_user       = "neil"
      vm_port       = "22"
      remote_path   = "/home/neil"
      ssh_key       = "id_ed25519"
    }
    vm2 = {
      name          = "neil-dev"
      description   = "Preset for neil-dev (163.192.217.205)"
      icon          = "/icon/terminal.svg"
      workspace_dir = "/workspaces/vm2-gateway"
      vm_host       = "163.192.217.205"
      vm_user       = "ubuntu"
      vm_port       = "22"
      remote_path   = "/home/ubuntu"
      ssh_key       = "id_ed25519"
    }
  }
}

data "coder_workspace_preset" "bare_vms" {
  for_each = local.vm_presets

  name        = each.value.name
  description = each.value.description
  icon        = each.value.icon

  parameters = {
    workspace_image   = local.workspace_image
    workspace_dir     = each.value.workspace_dir
    vm_host           = each.value.vm_host
    vm_user           = each.value.vm_user
    vm_port           = each.value.vm_port
    remote_path       = each.value.remote_path
    auto_mount_remote = "true"
    ssh_key_filename  = each.value.ssh_key
  }
}

resource "docker_image" "workspace" {
  name         = local.workspace_image
  keep_locally = true
}

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

resource "docker_volume" "workspaces" {
  name = "coder-${data.coder_workspace.me.id}-workspaces"

  lifecycle {
    ignore_changes = all
  }

  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

# ── Workspace Apps (phase 1: metadata only, for coder_agent) ────────────────
module "workspace_apps_metadata" {
  source      = "git::https://github.com/nyc-design/Coder-Workspaces.git//workspace-modules/workspace-apps?ref=main"
  enable_apps = false
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = data.coder_provisioner.me.arch
  dir  = local.workspace_dir

  startup_script_behavior = "blocking"
  startup_script = <<-EOT
    set -eu

    sudo mkdir -p "${local.workspace_dir}" /workspaces/remote-vm ~/.ssh ~/.ssh/config.d
    sudo chown -R coder:coder /workspaces ~/.ssh
    chmod 700 ~/.ssh ~/.ssh/config.d

    if [ -n "${local.vm_host}" ]; then
      SECRETS_KEY="/home/coder/secrets/ssh/${local.ssh_key_filename}"
      LOCAL_KEY="$HOME/.ssh/${local.ssh_key_filename}"
      if [ -f "$SECRETS_KEY" ]; then
        cp "$SECRETS_KEY" "$LOCAL_KEY"
        chmod 600 "$LOCAL_KEY"
        KEY_FILE="$LOCAL_KEY"
      else
        KEY_FILE="$HOME/.ssh/id_ed25519"
      fi

      cat > ~/.ssh/config.d/vm-gateway <<CFG
Host barevm
  HostName ${local.vm_host}
  User ${local.vm_user}
  Port ${local.vm_port}
  IdentityFile $KEY_FILE
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 3
CFG

      touch ~/.ssh/config
      if ! grep -q "config.d/vm-gateway" ~/.ssh/config; then
        printf '\nInclude ~/.ssh/config.d/vm-gateway\n' >> ~/.ssh/config
      fi
      chmod 600 ~/.ssh/config ~/.ssh/config.d/vm-gateway
    else
      echo "[vm-gateway] vm_host is empty; skipping SSH config + auto mount."
    fi

    # Install sshfs if not present
    if ! command -v sshfs >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y sshfs
      fi
    fi

    # Auto-mount remote VM filesystem via SSHFS
    if [ "${local.auto_mount_remote}" = "true" ] && [ -n "${local.vm_host}" ] && command -v sshfs >/dev/null 2>&1; then
      mkdir -p /workspaces/remote-vm
      if mountpoint -q /workspaces/remote-vm; then
        fusermount -u /workspaces/remote-vm || true
      fi
      sshfs barevm:${local.remote_path} /workspaces/remote-vm \
        -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks || true
    fi
  EOT

  display_apps {
    web_terminal           = true
    vscode                 = true
    vscode_insiders        = false
    ssh_helper             = false
    port_forwarding_helper = true
  }

  # Standard workspace metrics (CPU, RAM, disk, etc.)
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

  # VM-gateway-specific metadata
  metadata {
    display_name = "Gateway Target"
    key          = "gateway_target"
    script       = "echo '${local.vm_user}@${local.vm_host}:${local.vm_port}'"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "Remote Mount"
    key          = "remote_mount"
    script       = "mountpoint -q /workspaces/remote-vm && echo mounted || echo not-mounted"
    interval     = 30
    timeout      = 1
  }
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = docker_image.workspace.name
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

  volumes {
    container_path = "/workspaces"
    volume_name    = docker_volume.workspaces.name
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/secrets/ssh"
    host_path      = "/home/ubuntu/secrets/ssh"
    read_only      = true
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

# ── Workspace Apps (phase 2: actual apps — code-server, cursor, vscode-web, etc.) ──
module "workspace_apps" {
  count        = data.coder_workspace.me.start_count
  source       = "git::https://github.com/nyc-design/Coder-Workspaces.git//workspace-modules/workspace-apps?ref=main"
  agent_id     = coder_agent.main.id
  project_name = local.project_name
  enable_apps  = true
}

# ── VM-gateway-specific apps ───────────────────────────────────────────────────
resource "coder_app" "ssh_vm" {
  agent_id     = coder_agent.main.id
  slug         = "ssh-vm"
  display_name = "SSH to VM"
  icon         = "${data.coder_workspace.me.access_url}/icon/terminal.svg"
  command      = "ssh barevm"
}

resource "coder_app" "remote_files_shell" {
  agent_id     = coder_agent.main.id
  slug         = "remote-files-shell"
  display_name = "Remote Files Shell"
  icon         = "${data.coder_workspace.me.access_url}/icon/folder.svg"
  command      = "bash -lc 'cd /workspaces/remote-vm 2>/dev/null || true; exec bash'"
}

resource "coder_app" "remount_remote_files" {
  agent_id     = coder_agent.main.id
  slug         = "remount-remote-files"
  display_name = "Remount Remote Files"
  icon         = "${data.coder_workspace.me.access_url}/icon/folder.svg"
  command      = "bash -lc 'mkdir -p /workspaces/remote-vm; (mountpoint -q /workspaces/remote-vm && (fusermount -u /workspaces/remote-vm || umount /workspaces/remote-vm || true) || true); sshfs barevm:${local.remote_path} /workspaces/remote-vm -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks; echo mounted /workspaces/remote-vm'"
}
