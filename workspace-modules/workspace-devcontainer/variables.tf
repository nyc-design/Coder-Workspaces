variable "start_count" {
  description = "data.coder_workspace.me.start_count. Nothing is fetched, pulled or cloned while the workspace is stopped."
  type        = number
}

variable "agent_token" {
  type = string
}

variable "access_url" {
  type = string
}

variable "init_script" {
  type = string
}

# Map of environment variables declared on coder_agent.main.env. Forwarded
# into the container so they land on the workspace's `coder agent` process.
# This matters for any agent config the agent reads from its own os.Getenv at
# startup (e.g. CODER_AGENT_EXP_SKILLS_DIRS, CODER_AGENT_EXP_INSTRUCTIONS_DIRS):
# those are NOT delivered via the manifest's EnvironmentVariables, which the
# agent only applies to child processes (SSH sessions, scripts), not to itself.
variable "agent_env" {
  type    = map(string)
  default = {}
}

variable "repo" {
  description = "GitHub repository as owner/name. Cloned into workspace_folder and searched for .devcontainer/devcontainer.json. Empty skips both (template import plans with empty parameters)."
  type        = string
}

variable "repo_ref" {
  description = "Branch to clone and to read devcontainer.json from. Empty means the repository's default branch."
  type        = string
  default     = ""
}

variable "github_token" {
  description = "Token for reading devcontainer.json through the GitHub API and for the clone. Empty means anonymous access (public repositories only). It is not written to disk by the clone."
  type        = string
  sensitive   = true
  default     = ""
}

variable "workspace_folder" {
  description = "Absolute path of the project folder, e.g. /workspaces/my-repo."
  type        = string
}

variable "fallback_image" {
  description = "Image used when the repository has no devcontainer.json, or one without an image."
  type        = string
}

variable "startup_script" {
  description = "Workspace init script. Returned in output startup_script after the devcontainer lifecycle commands."
  type        = string
  default     = ""
}
