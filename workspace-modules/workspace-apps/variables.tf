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
  description = "Whether to create workspace app resources (master switch; false disables all apps regardless of per-app flags)"
  type        = bool
  default     = true
}

variable "enable_cursor" {
  description = "Whether to create the Cursor app"
  type        = bool
  default     = true
}

variable "enable_vscode_desktop" {
  description = "Whether to create the VS Code Desktop app"
  type        = bool
  default     = true
}

variable "enable_code_server" {
  description = "Whether to create the code-server app"
  type        = bool
  default     = true
}

variable "enable_vscode_web" {
  description = "Whether to create the VS Code Web app"
  type        = bool
  default     = true
}

variable "enable_neovim" {
  description = "Whether to create the Neovim terminal app"
  type        = bool
  default     = true
}

variable "enable_filebrowser" {
  description = "Whether to create the FileBrowser app"
  type        = bool
  default     = true
}

variable "enable_claude_usage" {
  description = "Whether to create the Claude usage link app"
  type        = bool
  default     = true
}

variable "enable_codex_usage" {
  description = "Whether to create the Codex usage link app"
  type        = bool
  default     = true
}
