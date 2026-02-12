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
