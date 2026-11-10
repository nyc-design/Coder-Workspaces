variable "start_count" {
  type = number
}

variable "devcontainer_builder_image" {
  description = "Image the workspace container runs. The name dates from envbuilder; it is kept because template versions still on envbuilder read this module from main."
  type        = string
}

variable "owner_name" {
  type = string
}

variable "owner_id" {
  type = string
}

variable "workspace_id" {
  type = string
}

variable "workspace_name" {
  type = string
}

variable "agent_id" {
  type = string
}

variable "docker_env" {
  type = list(string)
}

variable "github_pat" {
  type = string
}

variable "include_playwright_mcp_browser" {
  type    = bool
  default = false
}

variable "extra_env" {
  type    = list(string)
  default = []
}

variable "extra_mounts" {
  type = list(object({
    container_path = string
    host_path      = string
    read_only      = bool
  }))
  default = []
}

variable "command" {
  description = "Container command. Null keeps the image's own command (envbuilder). Set it when running a prebuilt image that must start the agent itself."
  type        = list(string)
  default     = null
}

variable "entrypoint" {
  description = "Container entrypoint. Null keeps the image's own. Unlike command, it also replaces an image ENTRYPOINT, so it works for images this repo does not build."
  type        = list(string)
  default     = null
}
