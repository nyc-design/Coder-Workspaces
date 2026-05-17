variable "agent_token" {
  type = string
}

variable "access_url" {
  type = string
}

variable "init_script" {
  type = string
}

variable "docker_config_base64" {
  type = string
}

variable "git_username" {
  type = string
}

variable "repo_url" {
  type = string
}

variable "project_name" {
  type = string
}

variable "is_new_project" {
  type = bool
}

variable "fallback_image" {
  type = string
}

variable "devcontainer_builder_image" {
  type    = string
  default = "ghcr.io/coder/envbuilder:latest"
}

# Map of environment variables declared on coder_agent.main.env. Forwarded
# into the envbuilder-built container so they land on the workspace's
# `coder agent` process at exec time. This matters for any agent config
# the agent reads from its own os.Getenv at startup (e.g.
# CODER_AGENT_EXP_SKILLS_DIRS, CODER_AGENT_EXP_INSTRUCTIONS_DIRS) —
# those are NOT delivered via the manifest's EnvironmentVariables, which
# the agent only applies to child processes (SSH sessions, scripts),
# not to itself.
variable "agent_env" {
  type    = map(string)
  default = {}
}
