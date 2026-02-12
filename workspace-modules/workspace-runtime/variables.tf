variable "start_count" {
  type = number
}

variable "devcontainer_builder_image" {
  type = string
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
