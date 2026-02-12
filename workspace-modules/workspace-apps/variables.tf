variable "agent_id" {
  description = "Coder agent ID used by workspace apps"
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Workspace project folder name"
  type        = string
  default     = ""
}

variable "enable_apps" {
  description = "Whether to create workspace app resources"
  type        = bool
  default     = true
}
