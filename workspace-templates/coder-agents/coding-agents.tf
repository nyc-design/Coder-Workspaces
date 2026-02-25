# Claude Code module
# HAPI mode: always installed (count=1)
# Task mode: installed only when selected (count based on coding_agent)
module "claude-code" {
  count                   = local.install_agentapi ? (local.coding_agent == "claude" ? 1 : 0) : 1
  source                  = "registry.coder.com/coder/claude-code/coder"
  version                 = "4.7.5"
  agent_id                = coder_agent.main.id
  claude_code_oauth_token = "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"
  workdir                 = "/workspaces/${local.project_name}"
  model                   = "opus"
  install_claude_code     = false
  install_agentapi        = local.install_agentapi  # false in HAPI mode, true in task mode
  agentapi_version        = "v0.10.0"
  report_tasks            = local.install_agentapi  # false in HAPI mode, true in task mode
  continue                = true
  order                   = 999
  system_prompt           = data.coder_parameter.system_prompt.value
  ai_prompt               = data.coder_task.me.prompt
  mcp                     = local.mcp_claude
  permission_mode         = "bypassPermissions"
}

# Gemini CLI module
# HAPI mode: always installed with install_agentapi=false
# Task mode: installed only when selected with install_agentapi=true
module "gemini" {
  count  = local.install_agentapi ? (local.coding_agent == "gemini" ? 1 : 0) : 1
  source = "github.com/nyc-design/Coder-Workspaces//workspace-modules/gemini"

  agent_id              = coder_agent.main.id
  folder                = "/workspaces/${local.project_name}"
  order                 = 999
  icon                  = "/icon/gemini.svg"
  install_gemini        = false # Already installed in base image
  gemini_api_key        = local.ai_api_key
  install_agentapi      = local.install_agentapi  # false in HAPI mode, true in task mode
  agentapi_version      = "v0.10.0"
  gemini_system_prompt  = data.coder_parameter.system_prompt.value
  enable_yolo_mode      = true
  task_prompt           = data.coder_task.me.prompt
  additional_extensions = local.additional_extensions_json
}

# Codex module
# HAPI mode: always installed with install_agentapi=false, report_tasks=false
# Task mode: installed only when selected with install_agentapi=true, report_tasks=true
module "codex" {
  count  = local.install_agentapi ? (local.coding_agent == "codex" ? 1 : 0) : 1
  source = "github.com/nyc-design/Coder-Workspaces//workspace-modules/codex"

  agent_id               = coder_agent.main.id
  workdir                = "/workspaces/${local.project_name}"
  order                  = 999
  icon                   = "/icon/openai.svg"
  web_app_display_name   = "Codex"
  install_codex          = false
  openai_api_key         = local.ai_api_key
  install_agentapi       = local.install_agentapi  # false in HAPI mode, true in task mode
  agentapi_version       = "v0.10.0"
  report_tasks           = local.install_agentapi  # false in HAPI mode, true in task mode
  codex_system_prompt    = data.coder_parameter.system_prompt.value
  ai_prompt              = data.coder_task.me.prompt
  continue               = true
  additional_mcp_servers = local.additional_mcp_toml
}

# Coder AI Task - only created in task automation mode
resource "coder_ai_task" "task" {
  count = local.install_agentapi ? 1 : 0

  app_id = (
    local.coding_agent == "claude" && length(module.claude-code) > 0 ? module.claude-code[0].task_app_id :
    local.coding_agent == "gemini" && length(module.gemini) > 0 ? module.gemini[0].task_app_id :
    local.coding_agent == "codex" && length(module.codex) > 0 ? module.codex[0].task_app_id :
    ""
  )
}

