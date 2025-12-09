#############################
# Local Codex wiring (no forced API key)
#############################

locals {
  codex_enabled        = local.coding_agent == "codex"
  codex_workdir        = "/workspaces/${local.project_name}"
  codex_app_slug       = "codex"
  codex_module_dirname = ".codex-module"

  codex_install_script = file("${path.module}/codex_install.sh")
  codex_start_script   = file("${path.module}/codex_start.sh")

  # Your custom base config, same as you were passing into the module
  codex_base_config_toml = <<-EOT
    sandbox_mode = "workspace-write"
    approval_policy = "never"

    [sandbox_workspace_write]
    network_access = true
  EOT
}

#############################
# Environment vars (conditional on ai_api_key)
#############################

resource "coder_env" "openai_api_key" {
  count    = local.codex_enabled && local.ai_api_key != "" ? 1 : 0
  agent_id = coder_agent.main.id
  name     = "OPENAI_API_KEY"
  value    = local.ai_api_key
}

#############################
# AgentAPI app for Codex
#############################

module "codex_agentapi" {
  count   = local.codex_enabled ? 1 : 0
  source  = "registry.coder.com/coder/agentapi/coder"
  version = "1.2.0"

  agent_id             = coder_agent.main.id
  folder               = local.codex_workdir
  web_app_slug         = local.codex_app_slug
  web_app_order        = 999
  web_app_group        = null
  web_app_icon         = "/icon/openai.svg"
  web_app_display_name = "Codex"

  # No CLI-only app in your setup; can flip to true later if you want
  cli_app              = false
  cli_app_slug         = null
  cli_app_display_name = null

  module_dir_name    = local.codex_module_dirname
  install_agentapi   = true
  agentapi_subdomain = false
  agentapi_version   = "v0.10.0"

  pre_install_script  = null
  post_install_script = null

  #########################################
  # Start script: launch Codex via AgentAPI
  #########################################
  start_script = <<-EOT
    #!/bin/bash
    set -o errexit
    set -o pipefail

    echo -n '${base64encode(local.codex_start_script)}' | base64 -d > /tmp/codex_start.sh
    chmod +x /tmp/codex_start.sh
    ARG_OPENAI_API_KEY='${local.ai_api_key}' \
    ARG_REPORT_TASKS='true' \
    ARG_CODEX_MODEL='' \
    ARG_CODEX_START_DIRECTORY='${local.codex_workdir}' \
    ARG_CODEX_TASK_PROMPT='${base64encode(data.coder_parameter.ai_prompt.value)}' \
    ARG_CONTINUE='false' \
    /tmp/codex_start.sh
  EOT

  #########################################
  # Install script: install (optional) + config
  #########################################
  install_script = <<-EOT
    #!/bin/bash
    set -o errexit
    set -o pipefail

    echo -n '${base64encode(local.codex_install_script)}' | base64 -d > /tmp/codex_install.sh
    chmod +x /tmp/codex_install.sh
    ARG_OPENAI_API_KEY='${local.ai_api_key}' \
    ARG_REPORT_TASKS='true' \
    ARG_INSTALL='false' \
    ARG_CODEX_VERSION='' \
    ARG_BASE_CONFIG_TOML='${base64encode(local.codex_base_config_toml)}' \
    ARG_ADDITIONAL_MCP_SERVERS='' \
    ARG_CODER_MCP_APP_STATUS_SLUG='${local.codex_app_slug}' \
    ARG_CODEX_START_DIRECTORY='${local.codex_workdir}' \
    ARG_CODEX_INSTRUCTION_PROMPT='${base64encode(data.coder_parameter.system_prompt.value)}' \
    /tmp/codex_install.sh
  EOT
}