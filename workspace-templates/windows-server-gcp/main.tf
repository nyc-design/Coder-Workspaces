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
      version = ">= 7.0.1"
    }
  }
}

provider "coder" {}
provider "docker" {}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "gcp_project_id" {
  name         = "gcp_project_id"
  display_name = "GCP Project ID"
  type         = "string"
  form_type    = "input"
  default      = "coder-nt"
  order        = 1
}

data "coder_parameter" "gcp_region" {
  name         = "gcp_region"
  display_name = "GCP Region"
  type         = "string"
  form_type    = "input"
  default      = "us-central1"
  order        = 2
}

data "coder_parameter" "gcp_zone" {
  name         = "gcp_zone"
  display_name = "GCP Zone"
  type         = "string"
  form_type    = "input"
  default      = "us-central1-c"
  order        = 3
}

data "coder_parameter" "machine_type" {
  name         = "machine_type"
  display_name = "Windows VM Machine Type"
  type         = "string"
  form_type    = "input"
  default      = "e2-standard-2"
  order        = 4
}

data "coder_parameter" "windows_image" {
  name         = "windows_image"
  display_name = "Windows Image"
  type         = "string"
  form_type    = "input"
  default      = "projects/windows-cloud/global/images/family/windows-2022"
  order        = 5
}

data "coder_parameter" "boot_disk_size_gb" {
  name         = "boot_disk_size_gb"
  display_name = "Boot Disk Size (GB)"
  type         = "number"
  default      = 50
  order        = 6
}

data "coder_parameter" "data_disk_size_gb" {
  name         = "data_disk_size_gb"
  display_name = "Data Disk Size (GB, 0 to disable)"
  type         = "number"
  default      = 0
  order        = 7
}

data "coder_parameter" "disk_type" {
  name         = "disk_type"
  display_name = "Persistent Disk Type"
  type         = "string"
  default      = "pd-standard"
  order        = 7

  option {
    name  = "Standard (cheapest)"
    value = "pd-standard"
  }

  option {
    name  = "Balanced"
    value = "pd-balanced"
  }
}

data "coder_parameter" "rdp_username" {
  name         = "rdp_username"
  display_name = "Windows RDP Username"
  type         = "string"
  form_type    = "input"
  default      = "coder"
  order        = 8
}

data "coder_parameter" "rdp_password" {
  name         = "rdp_password"
  display_name = "Windows RDP Password"
  type         = "string"
  form_type    = "input"
  mutable      = true
  default      = "neil2730!"
  order        = 9
}

data "coder_parameter" "rdp_source_cidrs" {
  name         = "rdp_source_cidrs"
  display_name = "Allowed RDP CIDRs (comma-separated)"
  type         = "string"
  form_type    = "input"
  default      = "0.0.0.0/0"
  order        = 10
}

data "coder_parameter" "reserve_static_ip" {
  name         = "reserve_static_ip"
  display_name = "Reserve Static Public IP"
  type         = "string"
  default      = "false"
  description  = "Keeps the same IP across restarts (small extra cost while VM is stopped)."
  order        = 11

  option {
    name  = "Yes"
    value = "true"
  }

  option {
    name  = "No (ephemeral IP)"
    value = "false"
  }
}

provider "google" {
  project = data.coder_parameter.gcp_project_id.value
  region  = data.coder_parameter.gcp_region.value
  zone    = data.coder_parameter.gcp_zone.value
}

locals {
  workspace_tag      = "coder-win-${data.coder_workspace.me.id}"
  instance_name      = "coder-win-${data.coder_workspace.me.id}"
  boot_disk_name     = "${local.instance_name}-boot"
  data_disk_name     = "${local.instance_name}-data"
  rdp_source_ranges  = [for cidr in split(",", data.coder_parameter.rdp_source_cidrs.value) : trimspace(cidr) if trimspace(cidr) != ""]
  vm_desired_status  = data.coder_workspace.me.transition == "start" ? "RUNNING" : "TERMINATED"
  windows_startup_ps = <<-EOT
    $ErrorActionPreference = "Continue"
    $username = "${data.coder_parameter.rdp_username.value}"
    $password = "${data.coder_parameter.rdp_password.value}"

    # Relax local password policy for this personal-use VM to allow simple passwords.
    try {
      secedit /export /cfg C:\Windows\Temp\secpol.cfg | Out-Null
      (Get-Content C:\Windows\Temp\secpol.cfg) `
        -replace '^PasswordComplexity\\s*=\\s*\\d+', 'PasswordComplexity = 0' `
        -replace '^MinimumPasswordLength\\s*=\\s*\\d+', 'MinimumPasswordLength = 0' `
        | Set-Content C:\Windows\Temp\secpol.cfg
      secedit /configure /db C:\Windows\security\local.sdb /cfg C:\Windows\Temp\secpol.cfg /areas SECURITYPOLICY | Out-Null
    } catch {
      Write-Host "Unable to relax local password policy: $($_.Exception.Message)"
    }

    try {
      $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
      if (Get-LocalUser -Name $username -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name $username -Password $securePassword
      } else {
        New-LocalUser -Name $username -Password $securePassword -PasswordNeverExpires:$true -AccountNeverExpires:$true
        Add-LocalGroupMember -Group "Administrators" -Member $username
      }
    } catch {
      Write-Host "Failed to create/update local user '$username' (likely Windows password complexity). Error: $($_.Exception.Message)"
      Write-Host "Use: gcloud compute reset-windows-password ${local.instance_name} --zone ${data.coder_parameter.gcp_zone.value} --user $username"
    }

    Set-ItemProperty -Path "HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server" -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

    $rawDisk = Get-Disk | Where-Object PartitionStyle -Eq "RAW" | Select-Object -First 1
    if ($null -ne $rawDisk) {
      Initialize-Disk -Number $rawDisk.Number -PartitionStyle GPT -PassThru | New-Partition -UseMaximumSize -AssignDriveLetter | Format-Volume -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false
    }
  EOT
}

resource "google_compute_address" "windows_static_ip" {
  count  = data.coder_parameter.reserve_static_ip.value == "true" ? 1 : 0
  name   = "${local.instance_name}-ip"
  region = data.coder_parameter.gcp_region.value
}

resource "google_compute_disk" "windows_boot" {
  name  = local.boot_disk_name
  type  = data.coder_parameter.disk_type.value
  zone  = data.coder_parameter.gcp_zone.value
  size  = data.coder_parameter.boot_disk_size_gb.value
  image = data.coder_parameter.windows_image.value
}

resource "google_compute_disk" "windows_data" {
  count = data.coder_parameter.data_disk_size_gb.value > 0 ? 1 : 0
  name  = local.data_disk_name
  type  = data.coder_parameter.disk_type.value
  zone  = data.coder_parameter.gcp_zone.value
  size  = data.coder_parameter.data_disk_size_gb.value
}

resource "google_compute_firewall" "allow_rdp" {
  name    = "${local.instance_name}-allow-rdp"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = local.rdp_source_ranges
  target_tags   = [local.workspace_tag]
}

resource "google_compute_instance" "windows" {
  name         = local.instance_name
  machine_type = data.coder_parameter.machine_type.value
  zone         = data.coder_parameter.gcp_zone.value
  tags         = [local.workspace_tag]

  # Important for cost control:
  # Workspace start => RUNNING, workspace stop => TERMINATED.
  desired_status            = local.vm_desired_status
  allow_stopping_for_update = true

  boot_disk {
    auto_delete = false
    source      = google_compute_disk.windows_boot.id
  }

  dynamic "attached_disk" {
    for_each = google_compute_disk.windows_data
    content {
      source = attached_disk.value.id
    }
  }

  network_interface {
    network = "default"

    access_config {
      nat_ip = data.coder_parameter.reserve_static_ip.value == "true" ? google_compute_address.windows_static_ip[0].address : null
    }
  }

  metadata = {
    "windows-startup-script-ps1" = local.windows_startup_ps
  }
}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"
  dir  = "/workspaces"

  startup_script = <<-EOT
    set -euo pipefail

    if ! command -v docker >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends docker.io ca-certificates curl
      rm -rf /var/lib/apt/lists/*
    fi

    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      touch ~/.init_done
    fi

    mkdir -p /workspaces
    cat > ~/WINDOWS_CONNECTION_INFO.txt <<'EOF'
Windows VM Public IP: ${google_compute_instance.windows.network_interface[0].access_config[0].nat_ip}
Windows Username: ${data.coder_parameter.rdp_username.value}
Windows Password: ${data.coder_parameter.rdp_password.value}

Open the "Windows Desktop (Browser)" app in Coder.
If prompted by Guacamole login (rare), use:
  username: coder
  password: coder
EOF

    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      cat > /home/coder/.guacamole/guacamole.properties <<PROP
user-mapping: /config/user-mapping.xml
PROP

      cat > /home/coder/.guacamole/user-mapping.xml <<MAP
<user-mapping>
  <authorize username="coder" password="coder">
    <connection name="Windows Desktop">
      <protocol>rdp</protocol>
      <param name="hostname">${google_compute_instance.windows.network_interface[0].access_config[0].nat_ip}</param>
      <param name="port">3389</param>
      <param name="username">${data.coder_parameter.rdp_username.value}</param>
      <param name="password">${data.coder_parameter.rdp_password.value}</param>
      <param name="security">any</param>
      <param name="ignore-cert">true</param>
      <param name="resize-method">display-update</param>
      <param name="enable-wallpaper">true</param>
      <param name="enable-full-window-drag">true</param>
      <param name="enable-desktop-composition">true</param>
      <param name="clipboard-encoding">UTF-8</param>
    </connection>
  </authorize>
</user-mapping>
MAP

      docker rm -f "$${GUAC_WEB_CONTAINER}" >/dev/null 2>&1 || true

      docker run -d \
        --name "$${GUAC_WEB_CONTAINER}" \
        --restart unless-stopped \
        --network "container:$${HOSTNAME}" \
        --platform linux/arm64/v8 \
        -e GUACAMOLE_HOME=/config \
        -v /home/coder/.guacamole:/config \
        flcontainers/guacamole:latest
    else
      echo "Docker is not available for starting Guacamole sidecar."
    fi
  EOT

  shutdown_script = <<-EOT
    #!/usr/bin/env bash
    docker rm -f "$${GUAC_WEB_CONTAINER}" >/dev/null 2>&1 || true
  EOT

  env = {
    CODER_WORKSPACE_ID = data.coder_workspace.me.id
    GUAC_WEB_CONTAINER = "coder-guac-${data.coder_workspace.me.id}"
  }

  metadata {
    display_name = "Windows VM State"
    key          = "vm_state"
    script       = "echo ${google_compute_instance.windows.current_status}"
    interval     = 30
    timeout      = 5
  }

  metadata {
    display_name = "Windows VM Public IP"
    key          = "vm_public_ip"
    script       = "echo ${google_compute_instance.windows.network_interface[0].access_config[0].nat_ip}"
    interval     = 120
    timeout      = 5
  }
}

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
  lifecycle {
    ignore_changes = all
  }
}

resource "docker_volume" "workspaces_volume" {
  name = "coder-${data.coder_workspace.me.id}-workspaces"
  lifecycle {
    ignore_changes = all
  }
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = "ubuntu:24.04"
  name  = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}-windows"

  command = [
    "bash",
    "-lc",
    "set -euxo pipefail; export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y --no-install-recommends ca-certificates curl bash; rm -rf /var/lib/apt/lists/*; exec ${coder_agent.main.init_script}"
  ]
  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "CODER_WORKSPACE_ID=${data.coder_workspace.me.id}",
    "GUAC_WEB_CONTAINER=coder-guac-${data.coder_workspace.me.id}"
  ]

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
    container_path = "/var/run/docker.sock"
    host_path      = "/var/run/docker.sock"
    read_only      = false
  }
}

resource "coder_app" "windows_desktop" {
  agent_id     = coder_agent.main.id
  slug         = "windows-desktop"
  display_name = "Windows Desktop (Browser)"
  icon         = "/icon/terminal.svg"
  url          = "http://127.0.0.1:8080/guacamole/"
  order        = 1
}

resource "coder_app" "connection_guide" {
  agent_id     = coder_agent.main.id
  slug         = "connection-guide"
  display_name = "Connection Guide"
  icon         = "/icon/terminal.svg"
  command      = "cat ~/WINDOWS_CONNECTION_INFO.txt"
  order        = 2
}
