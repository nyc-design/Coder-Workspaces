# Claude Code module
module "claude-code" {
  count                   = local.coding_agent == "claude" ? 1 : 0
  source                  = "registry.coder.com/coder/claude-code/coder"
  version                 = "4.7.5"
  agent_id                = coder_agent.main.id
  claude_code_oauth_token = "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"
  workdir                 = "/workspaces/${local.project_name}"
  model                   = "opus"
  install_claude_code     = false
  continue                = true
  order                   = 999
  system_prompt           = data.coder_parameter.system_prompt.value
  ai_prompt               = data.coder_task.me.prompt
  mcp                     = local.mcp_claude
  permission_mode         = "bypassPermissions"
}

# Gemini CLI module
module "gemini" {
  count  = local.coding_agent == "gemini" ? 1 : 0
  source = "github.com/nyc-design/Coder-Workspaces//workspace-modules/gemini"

  agent_id              = coder_agent.main.id
  folder                = "/workspaces/${local.project_name}"
  order                 = 999
  icon                  = "/icon/gemini.svg"
  install_gemini        = false # Already installed in base image
  gemini_api_key        = local.ai_api_key
  use_vertexai          = false
  install_agentapi      = true
  agentapi_version      = "v0.10.0"
  gemini_system_prompt  = data.coder_parameter.system_prompt.value
  enable_yolo_mode      = true
  task_prompt           = data.coder_task.me.prompt
  additional_extensions = local.additional_extensions_json
}

# Codex module
module "codex" {
  count  = local.coding_agent == "codex" ? 1 : 0
  source = "github.com/nyc-design/Coder-Workspaces//workspace-modules/codex"

  agent_id               = coder_agent.main.id
  workdir                = "/workspaces/${local.project_name}"
  order                  = 999
  icon                   = "/icon/openai.svg"
  web_app_display_name   = "Codex"
  install_codex          = false
  openai_api_key         = local.ai_api_key
  install_agentapi       = true
  agentapi_version       = "v0.10.0"
  report_tasks           = true
  codex_system_prompt    = data.coder_parameter.system_prompt.value
  ai_prompt              = data.coder_task.me.prompt
  continue               = false
  additional_mcp_servers = local.additional_mcp_toml
}

# Coder AI Task - dynamically set app_id based on selected agent
resource "coder_ai_task" "task" {
  app_id = (
    local.coding_agent == "claude" && length(module.claude-code) > 0 ? module.claude-code[0].task_app_id :
    local.coding_agent == "gemini" && length(module.gemini) > 0 ? module.gemini[0].task_app_id :
    local.coding_agent == "codex" && length(module.codex) > 0 ? module.codex[0].task_app_id :
    ""
  )
}

