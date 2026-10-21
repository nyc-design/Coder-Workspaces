terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.13.0"
    }
  }
}

provider "coder" {}

data "coder_workspace" "me" {}

data "coder_parameter" "working_directory" {
  name         = "working_directory"
  display_name = "Working Directory"
  description  = "Default directory for terminals and Coder Agent shell work on the attached Mac. Create this directory before attaching the external agent."
  type         = "string"
  default      = "/Users/Shared/Coder"
  mutable      = true
  order        = 1
}

resource "coder_agent" "main" {
  os   = "darwin"
  arch = "arm64"
  dir  = data.coder_parameter.working_directory.value

  env = {
    CODER_AGENT_EXP_SKILLS_DIRS = "~/.agents/skills,.agents/skills"
  }

  display_apps {
    vscode          = false
    vscode_insiders = false
    web_terminal    = true
  }

  metadata {
    display_name = "macOS"
    key          = "0_macos"
    script       = "sw_vers -productVersion"
    interval     = 300
    timeout      = 5
  }

  metadata {
    display_name = "Xcode"
    key          = "1_xcode"
    script       = "xcodebuild -version | tr '\\n' ' ' || true"
    interval     = 300
    timeout      = 10
  }
}

resource "coder_external_agent" "main" {
  agent_id = coder_agent.main.id
}
