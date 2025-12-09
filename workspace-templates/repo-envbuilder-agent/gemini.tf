#############################
# Local Gemini wiring (no forced API key)
#############################

locals {
  # Enable Gemini only when selected
  gemini_enabled = local.coding_agent == "gemini"

  gemini_app_slug        = "gemini"
  gemini_folder          = "/workspaces/${local.project_name}"
  gemini_module_dir_name = ".gemini-module"

  # Base MCP extension config for Coder
  gemini_base_extensions = <<-EOT
  {
    "coder": {
      "args": [
        "exp",
        "mcp",
        "server"
      ],
      "command": "coder",
      "description": "Report ALL tasks and statuses (in progress, done, failed) you are working on.",
      "enabled": true,
      "env": {
        "CODER_MCP_APP_STATUS_SLUG": "gemini",
        "CODER_MCP_AI_AGENTAPI_URL": "http://localhost:3284"
      },
      "name": "Coder",
      "timeout": 3000,
      "type": "stdio",
      "trust": true
    }
  }
  EOT

  # Load our local scripts from the template root
  gemini_install_script = file("${path.module}/gemini_install.sh")
  gemini_start_script   = file("${path.module}/gemini_start.sh")
}

#############################
# Environment vars (conditional on ai_api_key)
#############################

resource "coder_env" "gemini_api_key" {
  count    = local.gemini_enabled && local.ai_api_key != "" ? 1 : 0
  agent_id = coder_agent.main.id
  name     = "GEMINI_API_KEY"
  value    = local.ai_api_key
}

resource "coder_env" "google_api_key" {
  count    = local.gemini_enabled && local.ai_api_key != "" ? 1 : 0
  agent_id = coder_agent.main.id
  name     = "GOOGLE_API_KEY"
  value    = local.ai_api_key
}

#############################
# AgentAPI app for Gemini
#############################

module "gemini_agentapi" {
  count   = local.gemini_enabled ? 1 : 0
  source  = "registry.coder.com/coder/agentapi/coder"
  version = "1.2.0"

  agent_id             = coder_agent.main.id
  folder               = local.gemini_folder
  web_app_slug         = local.gemini_app_slug
  web_app_order        = 999
  web_app_group        = null
  web_app_icon         = "/icon/gemini.svg"
  web_app_display_name = "Gemini"
  cli_app_slug         = "${local.gemini_app_slug}-cli"
  cli_app_display_name = "Gemini CLI"
  module_dir_name      = local.gemini_module_dir_name

  # Same defaults as upstream module
  install_agentapi = true
  agentapi_version = "v0.10.0"

  pre_install_script  = null
  post_install_script = null

  #########################################
  # Install script: configure settings.json + MCP
  #########################################
  install_script = <<-EOT
    #!/bin/bash
    set -o errexit
    set -o pipefail

    echo -n '${base64encode(local.gemini_install_script)}' | base64 -d > /tmp/gemini_install.sh
    chmod +x /tmp/gemini_install.sh
    ARG_INSTALL='false' \
    ARG_GEMINI_VERSION='' \
    ARG_GEMINI_CONFIG='' \
    BASE_EXTENSIONS='${base64encode(replace(local.gemini_base_extensions, "'", "'\\''"))}' \
    ADDITIONAL_EXTENSIONS='' \
    GEMINI_START_DIRECTORY='${local.gemini_folder}' \
    GEMINI_SYSTEM_PROMPT='${base64encode(data.coder_parameter.system_prompt.value)}' \
    /tmp/gemini_install.sh
  EOT

  #########################################
  # Start script: launch Gemini via AgentAPI
  #########################################
  start_script = <<-EOT
    #!/bin/bash
    set -o errexit
    set -o pipefail

    echo -n '${base64encode(local.gemini_start_script)}' | base64 -d > /tmp/gemini_start.sh
    chmod +x /tmp/gemini_start.sh
    GEMINI_YOLO_MODE='true' \
    GEMINI_MODEL='' \
    GEMINI_START_DIRECTORY='${local.gemini_folder}' \
    GEMINI_TASK_PROMPT='${data.coder_parameter.ai_prompt.value}' \
    /tmp/gemini_start.sh
  EOT
}