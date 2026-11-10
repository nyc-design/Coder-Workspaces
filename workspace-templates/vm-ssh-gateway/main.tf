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
# on a remote command line, so each one is validated against a strict pattern.

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
  description  = "Absolute path on the VM to open. Leave empty for the SSH user's home directory."
  type         = "string"
  default      = ""
  form_type    = "input"
  mutable      = true
  order        = 4

  validation {
    regex = "^$|^/[A-Za-z0-9._/-]*$"
    error = "Enter an absolute path using letters, digits, '.', '_', '-' and '/', or leave empty."
  }
}

locals {
  # base-dev supplies the editor setup that is pushed to the VM: the
  # code-server version, settings manifests, extension manifest, and themes.
  workspace_image = "ghcr.io/nyc-design/workspace-images/base-dev:latest"

  vm_host    = data.coder_parameter.vm_host.value
  vm_user    = data.coder_parameter.vm_user.value
  vm_port    = data.coder_parameter.vm_port.value
  remote_dir = data.coder_parameter.remote_dir.value

  # The one shared key, from the host's secrets mount. Its public half must be
  # in ~/.ssh/authorized_keys on every VM this template is pointed at.
  ssh_key_path = "/home/coder/secrets/ssh/id_ed25519"

  # Local end of the SSH tunnel to code-server on the VM.
  tunnel_port = 13337

  # With no folder in the URL, code-server falls back to the last folder
  # opened on that VM, then to the directory it was started in (the VM home).
  folder_query = local.remote_dir != "" ? "?folder=${urlencode(local.remote_dir)}" : ""

  vm_presets = {
    watchparty-vm = { vm_host = "170.9.232.54", vm_user = "neil" }
    neil-dev      = { vm_host = "163.192.217.205", vm_user = "ubuntu" }
  }
}

data "coder_workspace_preset" "vms" {
  for_each = local.vm_presets

  name        = each.key
  description = "${each.value.vm_user}@${each.value.vm_host}"
  icon        = "/icon/terminal.svg"

  parameters = {
    vm_host = each.value.vm_host
    vm_user = each.value.vm_user
  }
}

# ── Agent ────────────────────────────────────────────────────────────────────
# The agent runs in a thin gateway container, not on the VM. Parameters reach
# the scripts as environment variables rather than being templated into them.

resource "coder_agent" "main" {
  os   = "linux"
  arch = data.coder_provisioner.me.arch
  dir  = "/home/coder"

  env = {
    VM_HOST           = local.vm_host
    VM_USER           = local.vm_user
    VM_PORT           = tostring(local.vm_port)
    VM_REMOTE_DIR     = local.remote_dir
    VM_SSH_KEY_SOURCE = local.ssh_key_path
    VM_TUNNEL_PORT    = tostring(local.tunnel_port)
  }

  display_apps {
    web_terminal           = true
    vscode                 = false
    vscode_insiders        = false
    ssh_helper             = false
    port_forwarding_helper = false
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
    script       = "curl -fsS -m 2 -o /dev/null \"http://127.0.0.1:$VM_TUNNEL_PORT/healthz\" && echo connected || echo disconnected"
    interval     = 15
    timeout      = 3
  }
}

# Installs code-server on the VM over SSH, pushes the editor setup, starts it,
# and keeps the tunnel open. Progress and errors show in the workspace's
# startup logs.
resource "coder_script" "vm_connect" {
  agent_id     = coder_agent.main.id
  display_name = "Connect to VM"
  icon         = "/icon/terminal.svg"
  run_on_start = true
  script       = file("${path.module}/scripts/vm-connect.sh")
}

# Stopping the workspace stops code-server on the VM so nothing is left
# running there. The install, settings, and extensions stay for the next start.
resource "coder_script" "vm_disconnect" {
  agent_id     = coder_agent.main.id
  display_name = "Stop code-server on VM"
  icon         = "/icon/terminal.svg"
  run_on_stop  = true
  script       = "ssh -o ConnectTimeout=5 vm 'bash .coder-vm-gateway/remote.sh stop' < /dev/null || true"
}

# ── Apps ─────────────────────────────────────────────────────────────────────

resource "coder_app" "code_server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  url          = "http://localhost:${local.tunnel_port}/${local.folder_query}"
  icon         = "/icon/code.svg"
  subdomain    = false
  share        = "owner"
  order        = 0
  open_in      = "tab"

  healthcheck {
    url       = "http://localhost:${local.tunnel_port}/healthz"
    interval  = 5
    threshold = 6
  }
}

resource "coder_app" "vm_terminal" {
  agent_id     = coder_agent.main.id
  slug         = "vm-terminal"
  display_name = "VM Terminal"
  icon         = "/icon/terminal.svg"
  command      = "ssh vm"
  order        = 1
}

# ── Gateway container ────────────────────────────────────────────────────────

data "docker_registry_image" "workspace" {
  name = local.workspace_image
}

resource "docker_image" "workspace" {
  name          = data.docker_registry_image.workspace.name
  pull_triggers = [data.docker_registry_image.workspace.sha256_digest]
  keep_locally  = true
}

# Persists known_hosts, so a VM whose host key changes is noticed.
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
