terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.13.0"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
    envbuilder = {
      source = "coder/envbuilder"
    }
    google = {
      source = "hashicorp/google"
      version = ">=7.0.1"
    }
    github = {
      source = "integrations/github"
      version = ">=6.6.0"
    }
  }
}
#rebuild

provider "coder" {}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
data "coder_task" "me" {}

provider "docker" {}

provider "envbuilder" {}

provider "google" {
  project = "coder-nt"
  region  = "us-central1"
  zone    = "us-central1-c"
}

data "google_projects" "gcp_projects" {
  filter = "lifecycleState:ACTIVE"
}

data "google_secret_manager_secret_version" "github_pat" {
  secret = "GH_PAT"
}

data "google_secret_manager_secret_version" "context7_api_key" {
  secret = "CONTEXT7_API_KEY"
}

data "google_secret_manager_secret_version" "docker_config" {
  secret = "DOCKER_CONFIG"
}

data "google_secret_manager_secret_version" "signoz_url" {
  secret = "SIGNOZ_URL"
}

data "google_secret_manager_secret_version" "signoz_api_key" {
  secret = "SIGNOZ_API_KEY"
}

data "coder_external_auth" "github" {
   id = "github-auth"
}

provider "github" {
  token = data.google_secret_manager_secret_version.github_pat.secret_data
}

locals{
  github_username = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)

  # Safely get the full task prompt (empty string if no task, e.g. manual workspace)
  task_prompt = try(data.coder_task.me.prompt, "")

  # Try to extract GH_REPO=owner/repo from the prompt.
  gh_repo_match = can(regex("(?m)^GH_REPO=([^\\r\\n]+)", local.task_prompt)) ? regex("(?m)^GH_REPO=([^\\r\\n]+)", local.task_prompt) : []

  # "" if not found, otherwise "owner/repo"
  gh_repo = length(local.gh_repo_match) > 0 ? local.gh_repo_match[0] : ""

  gh_project_name = local.gh_repo != "" ? (length(split("/", local.gh_repo)) > 1 ? element(split("/", local.gh_repo), 1) : local.gh_repo) : ""
  
  main_system_prompt = <<-EOT
    -- Framing --
    You are a helpful assistant that can help with code. You are running inside a Coder Workspace (that is different from the workspace of the user, so make sure to git push/pull to stay synced with them, especially when starting a new task or periodically) and provide status updates to the user via Coder MCP.

    -- Tool Selection --
    The following tools are available in every workspace, but look to CLAUDE.md for workspace-specific additional tools available:
    - Global tools: file operations, git commands, builds & installs, docker, one-off shell commands, GitHub CLI (gh), Google Cloud CLI (gcloud), Python, Node.js, Context7 MCP (to get latest docs for third-party dependencies)
    - Platform-specific tools: Storybook, Playwright CLI (preferred — use the playwright-cli skill for browser automation; more token-efficient than MCP), Playwright MCP (available as fallback when working with frontend or fullstack code)
    - Architecture tools: LikeC4 CLI & MCP (query and update C4 architecture models via *.likec4 files)

    -- Application Development Process --
    - Project follows a phased architecture-first workflow. You may be brought in at any phase — check the current state of artifacts (CLAUDE.md, .likec4 files, contracts, checklists) to understand where the project stands before proceeding.
    - UX Ideation — Wireframes and rough UI mockups establish what the user sees and does. These guide all downstream architecture decisions.
    - Architecture Document (CLAUDE.md) — A living markdown document describing the system's purpose, components, integrations, data flow, and key technical decisions. Updated as the architecture evolves through later phases.
    - C4 Structural Views — LikeC4 models defining system context (what exists and what it talks to) and container views (what's inside the system). Establishes boundaries before any internals are designed.
    - C4 Component Views — LikeC4 models breaking containers into their internal components. At the lowest level, individual functions are modeled as `fn` elements nested inside their parent service/router/scanner. Relationships are always defined at the deepest fn level — LikeC4 automatically aggregates them upward through all parent zoom levels. Each element with children gets a `view of` for drill-down navigation.
    - C4 Sequence Views — LikeC4 dynamic views for each major user flow, using an overview + detail pair: the overview references service-level elements for readability, the detail view references fn-level elements for precision. Detail views use `navigateTo` from the overview for drill-down.
    - LikeC4 fn Naming Conventions — fn element titles must reflect the actual code structure:
        - Module-level Python functions: `'file_name.function_name()'` (e.g., `'media_pipeline.process_new_media()'`)
        - Class methods: `'file_name.ClassName.method_name()'` (e.g., `'rd_scanner.RDScanner._process_added()'`)
        - External API endpoints: `'ServicePrefix: HTTP_METHOD /path'` (e.g., `'RD: GET /torrents'`)
        - Frontend pages: descriptive names (e.g., `'Library Page'`)
    - LikeC4 View Title Prefixes — View titles use category prefixes for organized dropdown navigation: `1.`/`2.`/`3.` for hierarchy levels, `API:`, `Scanner:`, `Service:`, `DB:`, `Client:`, `Ext:`, `WebDAV:`, etc. for component drill-downs, `Flow:` for dynamic sequence views.
    - LikeC4 Maintenance — When modifying code (adding, renaming, or removing functions, endpoints, or services), update the corresponding `.likec4/` model files to keep architecture diagrams in sync. Use the LikeC4 MCP to validate changes parse correctly.
    - API Contracts — For FastAPI backends, Pydantic request/response models for every endpoint — written as stubs before implementation. These contracts are the single source of truth between frontend and backend. TypeScript types are generated from the FastAPI OpenAPI spec via openapi-typescript.
    - Design System Foundation — Component library selection, design tokens (colors, spacing, typography), and a small set of core UI components built in Storybook. Establishes the visual vocabulary used throughout frontend implementation.
    - Data Model / Schema Design — Formal collection or table schemas, indexes, constraints, and migration strategy. The C4 views imply data shapes; this phase makes them explicit and implementation-ready.
    - Implementation Checklists — Per-component or per-function task lists derived from the sequence views and contracts. Each item should be small enough to implement and test in one pass.
    - Backend Implementation — Build each checklist item with its corresponding tests. Do not defer testing to a separate phase. Each endpoint should validate against its Pydantic contract and return correct responses before moving on. Preserve implementation checklists in docstrings. May check off items: [ ] → [x], but NEVER modify checklist text. Copy each checklist item as a comment and place relevant code directly below it. Once an implementation checklist is completed, feel free to change the title of the checklist to 'Procedure'.
    - Frontend Implementation — Build pages and features by composing from the Storybook design system and calling the contracted API endpoints. Types are generated from the backend's OpenAPI spec — do not hand-write API response types.
    - Integration Testing + UX Iteration — End-to-end testing of complete user flows. Iterate on the experience with the user, adjusting both frontend behavior and backend responses as needed.
    - Polish + Deploy — Final design refinements, responsive behavior, loading/error states, accessibility, then ship.

    -- Context --
    Please read the CLAUDE.md, if present in workspace base directory, for project-specific context. Also, please keep CLAUDE.md up to date as repo / project changes or when major tasks are done.

    -- Code Review Workflow --
    User has GitHub Pull Requests extension in VS Code. Unless otherwise instructed, create individual PRs per work request: 'gh pr create'. Test your code in the PR, and then review the PR. User reviews line-by-line in VS Code, you read feedback: `gh pr view [PR#] --comments`

    EOT
}

data "coder_workspace_preset" "issue_automation_claude" {
  name        = "Issue Automation - Claude"
  description = "Preset for GitHub Issues automation."
  icon        = "/icon/claude.svg"
  parameters = {
    is_existing_project = "existing"
    ai_api_key     = ""
    system_prompt  = local.main_system_prompt
    repo_name      = "Coder-Workspaces"
    gcp_project_name = ""
    coding_agent = "claude"
  }
}

data "coder_workspace_preset" "issue_automation_gemini" {
  name        = "Issue Automation - Gemini"
  description = "Preset for GitHub Issues automation."
  icon        = "/icon/gemini.svg"
  parameters = {
    is_existing_project = "existing"
    ai_api_key     = ""
    system_prompt  = local.main_system_prompt
    repo_name      = "Coder-Workspaces"
    gcp_project_name = ""
    coding_agent = "gemini"
  }
}

data "coder_workspace_preset" "issue_automation_codex" {
  name        = "Issue Automation - Codex"
  description = "Preset for GitHub Issues automation."
  icon        = "/icon/openai.svg"
  parameters = {
    is_existing_project = "existing"
    ai_api_key     = ""
    system_prompt  = local.main_system_prompt
    repo_name      = "Coder-Workspaces"
    gcp_project_name = ""
    coding_agent = "codex"
  }
}

data "coder_workspace_preset" "agent-workspace" {
  name        = "Agent Workspace"
  description = "Preset for launching a workspace with an AI agent."
  icon        = "/icon/github.svg"
  parameters = {
    is_existing_project = "existing"
    ai_api_key     = ""
    system_prompt  = local.main_system_prompt
  }
}

data "coder_parameter" "is_existing_project" {
  name         = "is_existing_project"
  display_name = "Project Type"
  type         = "string"
  default      = "existing"
  description  = "Use an existing GitHub repository or create a new project?"
  order = 0
  
  option {
    name  = "Existing Repository"
    value = "existing"
  }
  option {
    name  = "New Project"
    value = "new"
  }
}

data "coder_parameter" "coding_agent" {
  name         = "coding_agent"
  display_name = "Coding Agent"
  type         = "string"
  default      = "claude"
  description  = "Which coding agent should be used?"
  order = 0
  
  option {
    name  = "Claude Code"
    value = "claude"
  }
  option {
    name  = "OpenAI Codex"
    value = "codex"
  }
  option {
    name  = "Google Gemini"
    value = "gemini"
  }  
}

data "coder_parameter" "ai_api_key" {
  name         = "ai_api_key"
  display_name = "API key for AI Agent"
  type         = "string"
  form_type    = "input"
  default      = ""
  description  = "If set, selected AI agent will use this API key. If left blank, agent will use workspace's added authorization."
}

data "github_repositories" "user_repositories" {
  query = "user:nyc-design"
  include_repo_id = true
}

data "coder_parameter" "repo_name" {
  count = data.coder_parameter.is_existing_project.value == "existing" ? 1 : 0
  name         = "repo_name"
  display_name = "GitHub Repository"
  description  = "Enter just the repo name (e.g., shadowscout, stellarscout, etc)."
  type         = "string"
  form_type    = "input"
  order        = 1
}

data "coder_parameter" "gcp_project_name" {
  count = data.coder_parameter.is_existing_project.value == "existing" ? 1 : 0
  name         = "gcp_project_name"
  display_name = "GCP Project (Optional)"
  default      = ""
  description  = "Enter a GCP Project to automatically configure secrets and credentials"
  type         = "string"
  form_type    = "input"
  order        = 2
}

data "coder_parameter" "new_project_type" {
  count = data.coder_parameter.is_existing_project.value == "new" ? 1 : 0
  name         = "new_project_type"
  display_name = "New Project Type"
  type         = "string"
  default      = "base"
  order = 1
  
  option {
    name  = "Base Project"
    value = "base"
  }
  option {
    name  = "Python Project"
    value = "python"
  }
  option {
    name  = "Next.js Project"
    value = "nextjs"
  }
  option {
    name  = "C++ Project"
    value = "cpp"
  }
  option {
    name  = "Fullstack Project"
    value = "fullstack"
  }
}

data "coder_parameter" "new_project_name" {
  count = data.coder_parameter.is_existing_project.value == "new" ? 1 : 0
  name         = "project_name"
  display_name = "Project Name"
  type         = "string"
  default      = "my-new-project"
  order = 2
}

locals {
  # Determine if this is a new project
  is_new_project = data.coder_parameter.is_existing_project.value == "new"

  coding_agent = data.coder_parameter.coding_agent.value

  ai_api_key = data.coder_parameter.ai_api_key.value
  context7_api_key = data.google_secret_manager_secret_version.context7_api_key.secret_data
  signoz_url = data.google_secret_manager_secret_version.signoz_url.secret_data
  signoz_api_key = data.google_secret_manager_secret_version.signoz_api_key.secret_data
  
  # Project name logic
  project_name = local.gh_project_name != "" ? local.gh_project_name : (local.is_new_project ? data.coder_parameter.new_project_name[0].value : data.coder_parameter.repo_name[0].value)
  
  # Project type for workspace image selection
  project_type = local.is_new_project ? data.coder_parameter.new_project_type[0].value : "base"
  
  # GCP project (optional)
  gcp_project = local.is_new_project == false && data.coder_parameter.gcp_project_name[0].value != "" ? data.coder_parameter.gcp_project_name[0].value : ""
  
  cache_repo = "us-central1-docker.pkg.dev/coder-nt/envbuilder-cache/envbuilder"
    
  # Container and builder configuration
  container_name             = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  devcontainer_builder_image = "ghcr.io/coder/envbuilder:latest"
  git_author_name            = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
  git_author_email           = data.coder_workspace_owner.me.email
}


locals {
  new_repo_url = local.is_new_project ? "https://github.com/nyc-design/Project-Scaffolds.git#scaffold/${local.project_type}" : ""

  existing_repo_url = local.is_new_project ? "" : "https://github.com/${local.github_username}/${data.coder_parameter.repo_name[0].value}.git"

  task_repo_url = local.gh_repo != "" ? "https://github.com/${local.gh_repo}.git" : ""

  repo_url = local.task_repo_url != "" ? local.task_repo_url : (local.is_new_project ? local.new_repo_url : local.existing_repo_url)

  playwright_mcp_toml = <<-EOT
    [mcp_servers.playwright]
    command = "npx"
    args = ["@playwright/mcp@latest", "--browser=chromium", "--no-sandbox", "--headless"]
    type = "stdio"
  EOT

  context7_mcp_toml_raw = <<-EOT
    [mcp_servers.context7]
    url = "https://mcp.context7.com/mcp"
    http_headers = { "CONTEXT7_API_KEY" = "${local.context7_api_key}" }
  EOT

  context7_mcp_toml = local.context7_api_key != "" ? local.context7_mcp_toml_raw : ""

  grep_mcp_toml = <<-EOT
    [mcp_servers.grep]
    url = "https://mcp.grep.app"
  EOT

  likec4_mcp_toml = <<-EOT
    [mcp_servers.likec4]
    command = "likec4"
    args = ["mcp", "--stdio"]
    type = "stdio"
  EOT

  stitch_mcp_toml = <<-EOT
    [mcp_servers.stitch]
    command = "npx"
    args = ["@_davideast/stitch-mcp", "proxy"]
    type = "stdio"
    [mcp_servers.stitch.env]
    STITCH_USE_SYSTEM_GCLOUD = "1"
  EOT

  signoz_mcp_toml = <<-EOT
    [mcp_servers.signoz]
    command = "signoz-mcp-server"
    args = []
    type = "stdio"
    [mcp_servers.signoz.env]
    SIGNOZ_URL = "${local.signoz_url}"
    SIGNOZ_API_KEY = "${local.signoz_api_key}"
    LOG_LEVEL = "info"
  EOT

  additional_mcp_toml = trimspace(join("\n", compact([
    local.playwright_mcp_toml,
    local.context7_mcp_toml,
    local.grep_mcp_toml,
    local.likec4_mcp_toml,
    local.stitch_mcp_toml,
    local.signoz_mcp_toml,
  ])))

  playwright_mcp_extensions_map = {
    playwright = {
      command = "npx"
      args = ["@playwright/mcp@latest", "--browser=chromium", "--no-sandbox", "--headless"]
      type = "stdio"
      description = "Playwright browser automation"
      enabled = true
      name = "Playwright"
      timeout = 3000
    }
  }

  context7_mcp_extensions_map = local.context7_api_key != "" ? {
    context7 = {
      httpUrl = "https://mcp.context7.com/mcp"
      headers = {
        CONTEXT7_API_KEY = local.context7_api_key
        Accept = "application/json, text/event-stream"
      }
    }
  } : {}

  grep_mcp_extensions_map = {
    grep = {
      httpUrl = "https://mcp.grep.app"
    }
  }

  likec4_mcp_extensions_map = {
    likec4 = {
      command     = "likec4"
      args        = ["mcp", "--stdio"]
      type        = "stdio"
      description = "LikeC4 architecture modeling"
      enabled     = true
      name        = "LikeC4"
      timeout     = 3000
    }
  }

  stitch_mcp_extensions_map = {
    stitch = {
      command     = "npx"
      args        = ["@_davideast/stitch-mcp", "proxy"]
      type        = "stdio"
      env         = { STITCH_USE_SYSTEM_GCLOUD = "1" }
      description = "Google Stitch AI design tools"
      enabled     = true
      name        = "Stitch"
      timeout     = 3000
    }
  }

  signoz_mcp_extensions_map = {
    signoz = {
      command     = "signoz-mcp-server"
      args        = []
      type        = "stdio"
      env         = {
        SIGNOZ_URL     = local.signoz_url
        SIGNOZ_API_KEY = local.signoz_api_key
        LOG_LEVEL      = "info"
      }
      description = "SigNoz observability (traces, logs, metrics)"
      enabled     = true
      name        = "SigNoz"
      timeout     = 3000
    }
  }

  additional_extensions_json = jsonencode(merge(
    local.playwright_mcp_extensions_map,
    local.context7_mcp_extensions_map,
    local.grep_mcp_extensions_map,
    local.likec4_mcp_extensions_map,
    local.stitch_mcp_extensions_map,
    local.signoz_mcp_extensions_map,
  ))

  playwright_mcp_claude_map = {
    playwright = {
      command = "npx"
      args = ["-y", "@playwright/mcp@latest", "--browser=chromium", "--no-sandbox", "--headless"]
      type = "stdio"
    }
  }

  context7_mcp_claude_map = local.context7_api_key != "" ? {
    context7 = {
      type = "http"
      url = "https://mcp.context7.com/mcp"
      headers = {
        CONTEXT7_API_KEY = local.context7_api_key
      }
    }
  } : {}

  grep_mcp_claude_map = {
    grep = {
      type = "http"
      url = "https://mcp.grep.app"
    }
  }

  likec4_mcp_claude_map = {
    likec4 = {
      command = "likec4"
      args    = ["mcp", "--stdio"]
      type    = "stdio"
    }
  }

  stitch_mcp_claude_map = {
    stitch = {
      command = "npx"
      args    = ["-y", "@_davideast/stitch-mcp", "proxy"]
      type    = "stdio"
      env     = { STITCH_USE_SYSTEM_GCLOUD = "1" }
    }
  }

  signoz_mcp_claude_map = {
    signoz = {
      command = "signoz-mcp-server"
      args    = []
      type    = "stdio"
      env     = {
        SIGNOZ_URL     = local.signoz_url
        SIGNOZ_API_KEY = local.signoz_api_key
        LOG_LEVEL      = "info"
      }
    }
  }

  mcp_claude = jsonencode({
    mcpServers = merge(
      local.playwright_mcp_claude_map,
      local.context7_mcp_claude_map,
      local.grep_mcp_claude_map,
      local.likec4_mcp_claude_map,
      local.stitch_mcp_claude_map,
      local.signoz_mcp_claude_map,
    )
  })

  # The envbuilder provider requires a key-value map of environment variables.
  envbuilder_env = merge({
    "CODER_AGENT_TOKEN" : coder_agent.main.token,
    # Use the docker gateway if the access URL is 127.0.0.1
    "CODER_AGENT_URL" : replace(data.coder_workspace.me.access_url, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal"),
    # Use the docker gateway if the access URL is 127.0.0.1
    "ENVBUILDER_INIT_SCRIPT" : replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal"),
    "ENVBUILDER_FALLBACK_IMAGE" : "us-central1-docker.pkg.dev/coder-nt/workspace-images/base-dev:latest",
    "ENVBUILDER_DOCKER_CONFIG_BASE64" : data.google_secret_manager_secret_version.docker_config.secret_data,
    "ENVBUILDER_PUSH_IMAGE" : "false",
    "ENVBUILDER_GIT_USERNAME" : data.coder_external_auth.github.access_token,
    "ENVBUILDER_GIT_URL" : local.repo_url,
    "ENVBUILDER_WORKSPACE_FOLDER" : "/workspaces/${local.project_name}",
  }, local.is_new_project ? {
    # New project environment variables
    "CODER_NEW_PROJECT" : "true",
    "CODER_PROJECT_NAME" : local.project_name,
  } : {})
  
  # Convert the above map to the format expected by the docker provider.
  docker_env = [
    for k, v in local.envbuilder_env : "${k}=${v}"
  ]
}

resource "docker_image" "devcontainer_builder_image" {
  name         = local.devcontainer_builder_image
  keep_locally = true
}

resource "envbuilder_cached_image" "cached" {
  count         = 0
  builder_image = local.devcontainer_builder_image
  git_url       = local.repo_url
  cache_repo    = ""
  extra_env     = local.envbuilder_env
}


data "coder_parameter" "system_prompt" {
  name         = "system_prompt"
  display_name = "System Prompt"
  type         = "string"
  form_type    = "textarea"
  description  = "System prompt for the agent with generalized instructions"
  mutable      = false
  default     = local.main_system_prompt
}

# Claude Code module
module "claude-code" {
  count               = local.coding_agent == "claude" ? 1 : 0
  source              = "registry.coder.com/coder/claude-code/coder"
  version             = "4.7.5"
  agent_id            = coder_agent.main.id
  claude_code_oauth_token = "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"
  workdir             = "/workspaces/${local.project_name}"
  model               = "opus"
  install_claude_code = false
  continue            = true
  order               = 999
  ai_prompt           = data.coder_task.me.prompt
  mcp                 = local.mcp_claude
  permission_mode     = "bypassPermissions"
}

# Gemini CLI module
module "gemini" {
  count   = local.coding_agent == "gemini" ? 1 : 0
  source  = "github.com/nyc-design/Coder-Workspaces//workspace-modules/gemini"

  agent_id             = coder_agent.main.id
  folder               = "/workspaces/${local.project_name}"
  order                = 999
  icon                 = "/icon/gemini.svg"
  install_gemini       = false  # Already installed in base image
  gemini_api_key       = local.ai_api_key
  use_vertexai         = false
  install_agentapi     = true
  agentapi_version     = "v0.10.0"
  gemini_system_prompt = data.coder_parameter.system_prompt.value
  enable_yolo_mode     = true
  task_prompt          = data.coder_task.me.prompt
  additional_extensions = local.additional_extensions_json
}

# Codex module
module "codex" {
  count   = local.coding_agent == "codex" ? 1 : 0
  source  = "github.com/nyc-design/Coder-Workspaces//workspace-modules/codex"

  agent_id             = coder_agent.main.id
  workdir              = "/workspaces/${local.project_name}"
  order                = 999
  icon                 = "/icon/openai.svg"
  web_app_display_name = "Codex"
  install_codex        = false
  openai_api_key       = local.ai_api_key
  install_agentapi     = true
  agentapi_version     = "v0.10.0"
  report_tasks         = true
  codex_system_prompt  = data.coder_parameter.system_prompt.value
  ai_prompt            = data.coder_task.me.prompt
  continue             = false
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


resource "coder_agent" "main" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
  startup_script = <<-EOT
    set -e

    # Fix ownership that envbuilder's chown may have failed to complete.
    # envbuilder uses filepath.Walk which aborts on ENOENT if a temp file
    # (e.g. .codex/tmp, ms-playwright) is deleted mid-walk. This find-based
    # approach handles vanishing files gracefully.
    sudo find /home/coder -xdev -not -user coder -exec chown coder:coder {} + 2>/dev/null || true

    # Prepare user home with default files on first start.
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      touch ~/.init_done
    fi

    /usr/local/bin/init-workspace.sh >> /tmp/workspace-init.log 2>&1 || true
    /usr/local/bin/run-workspace-inits >> /tmp/workspace-init.log 2>&1 || true

    # Add any commands that should be executed at workspace startup (e.g install requirements, start a program, etc) here
  EOT

  dir = "/workspaces/${local.project_name}"

  env = {
    GIT_AUTHOR_NAME     = local.git_author_name
    GIT_AUTHOR_EMAIL    = local.git_author_email
    GIT_COMMITTER_NAME  = local.git_author_name
    GIT_COMMITTER_EMAIL = local.git_author_email
  }

    metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    # get load avg scaled by number of cores
    script   = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval = 60
    timeout  = 1
  }

  metadata {
    display_name = "Swap Usage (Host)"
    key          = "7_swap_host"
    script       = <<EOT
      free -b | awk '/^Swap/ { printf("%.1f/%.1f", $3/1024.0/1024.0/1024.0, $2/1024.0/1024.0/1024.0) }'
    EOT
    interval     = 10
    timeout      = 1
  }
}

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
  # Protect the volume from being deleted due to changes in attributes.
  lifecycle {
    ignore_changes = all
  }
  # Add labels in Docker to keep track of orphan resources.
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  # This field becomes outdated if the workspace is renamed but can
  # be useful for debugging or cleaning out dangling volumes.
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

resource "docker_volume" "workspaces_volume" {
  name = "coder-${data.coder_workspace.me.id}-workspaces"
  lifecycle { ignore_changes = all }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_volume" "dind_data" {
  name = "coder-${data.coder_workspace.me.id}-dind"
  lifecycle { ignore_changes = all }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = local.devcontainer_builder_image
  # Uses lower() to avoid Docker restriction on container names.
  name = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  # Hostname makes the shell more user friendly: coder@my-workspace:~$
  hostname = data.coder_workspace.me.name

  runtime = "sysbox-runc"

  env = concat(
    local.docker_env,
    [
      "GH_TOKEN=${data.google_secret_manager_secret_version.github_pat.secret_data}",
      "GITHUB_TOKEN=${data.google_secret_manager_secret_version.github_pat.secret_data}",
      "GITHUB_PAT=${data.google_secret_manager_secret_version.github_pat.secret_data}",
      "PLAYWRIGHT_MCP_BROWSER=chromium",
      "SIGNOZ_URL=${local.signoz_url}",
      "SIGNOZ_API_KEY=${local.signoz_api_key}",
    ],
    local.is_new_project ? [
      "CODER_NEW_PROJECT=true",
      "NEW_PROJECT_TYPE=${local.project_type}",
      "CODER_PROJECT_NAME=${local.project_name}",
      "CODER_GITHUB_REPO_URL=${local.repo_url}",
    ] : [],
    local.gcp_project != "" ? [
      "CODER_GCP_PROJECT=${local.gcp_project}",
      "GOOGLE_CLOUD_PROJECT=${local.gcp_project}",
    ] : [
      "GOOGLE_CLOUD_PROJECT=coder-nt",
    ]
  )

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
  
  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
  }

  volumes {
    container_path = "/workspaces"
    volume_name    = docker_volume.workspaces_volume.name
    read_only      = false
  }

  volumes {
    container_path = "/var/lib/docker"
    volume_name    = docker_volume.dind_data.name
  }

  volumes {
    container_path = "/home/coder/.ssh"
    host_path      = "/home/ubuntu/secrets/ssh"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.config/gcloud"
    host_path      = "/home/ubuntu/secrets/gcloud"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.pencil"
    host_path      = "/home/ubuntu/secrets/.pencil"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.gemini"
    host_path      = "/home/ubuntu/secrets/.gemini"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.codex"
    host_path      = "/home/ubuntu/secrets/.codex"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.claude/agents"
    host_path      = "/home/ubuntu/secrets/.claude/agents"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.claude/skills"
    host_path      = "/home/ubuntu/secrets/.claude/skills"
    read_only      = false
  }
  
  volumes {
    container_path = "/home/coder/.supermaven"
    host_path      = "/home/ubuntu/secrets/.supermaven"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.local/share/code-server"
    host_path      = "/home/ubuntu/secrets/code-server"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.vscode-server"
    host_path      = "/home/ubuntu/secrets/.vscode-server"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.local/share/keyrings"
    host_path      = "/home/ubuntu/secrets/keyrings"
    read_only      = false
  }

  volumes {
    container_path = "/home/coder/.excalidraw"
    host_path      = "/home/ubuntu/secrets/.excalidraw"
    read_only      = false
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}

module "cursor" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/cursor/coder"
  version  = "1.2.1"
  agent_id = coder_agent.main.id
  folder = "/workspaces/${local.project_name}"
}

# See https://registry.coder.com/modules/coder/code-server
module "code-server" {
  count  = data.coder_workspace.me.start_count
  source = "registry.coder.com/coder/code-server/coder"
  folder = "/workspaces/${local.project_name}"

  agent_id = coder_agent.main.id
  order    = 1

  settings = {
    "workbench.colorTheme"                       = "Default Dark Modern",
    "git.useIntegratedAskPass"                   = "false",
    "likec4.mcp.enabled"                         = "true",
    "vscode-neovim.neovimExecutablePaths.linux"  = "/usr/local/bin/nvim",
    "extensions.experimental.affinity"           = { "asvetliakov.vscode-neovim" = 1 },
    "todo-tree.tree.showBadges"                  = "true",
    "todo-tree.tree.disableCompactFolders"       = "false",
    "todo-tree.tree.showCountsInTree"            = "true",
    "todo-tree.tree.scanMode"                    = "current file",
    "excalidraw.workspaceLibraryPath"            = "/home/coder/.excalidraw/libraries/library.excalidrawlib"
  }

  machine-settings = {
    "extensions.experimental.affinity" = { "asvetliakov.vscode-neovim" = 1 }
  }

  extensions = [
    "GitHub.vscode-github-actions",
    "GitHub.vscode-pull-request-github",
    "Anthropic.claude-code",
    "highagency.pencildev",
    "mongodb.mongodb-vscode",
    "openai.chatgpt",
    "ms-python.python",
    "detachhead.basedpyright",
    "Supermaven.supermaven",
    "ms-azuretools.vscode-docker",
    "likec4.likec4-vscode",
    "nefrob.vscode-just-syntax",
    "asvetliakov.vscode-neovim",
    "bradlc.vscode-tailwindcss",
    "Gruntfuggly.todo-tree",
    "usernamehw.errorlens",
    "hediet.vscode-drawio",
    "joshbolduc.story-explorer",
    "bruno-api-client.bruno",
    "pomdtr.excalidraw-editor"
  ]
}

module "vscode-web" {
  count          = data.coder_workspace.me.start_count
  source         = "registry.coder.com/coder/vscode-web/coder"
  folder = "/workspaces/${local.project_name}"

  agent_id       = coder_agent.main.id
  order          = 2
  accept_license = true

  settings = {
    "workbench.colorTheme"                       = "Default Dark Modern",
    "git.useIntegratedAskPass"                   = "false",
    "likec4.mcp.enabled"                         = "true",
    "vscode-neovim.neovimExecutablePaths.linux"  = "/usr/local/bin/nvim",
    "extensions.experimental.affinity"           = { "asvetliakov.vscode-neovim" = 1 },
    "todo-tree.tree.showBadges"                  = "true",
    "todo-tree.tree.disableCompactFolders"       = "false",
    "todo-tree.tree.showCountsInTree"            = "true",
    "todo-tree.tree.scanMode"                    = "current file",
    "excalidraw.workspaceLibraryPath"            = "/home/coder/.excalidraw/libraries/library.excalidrawlib"
  }

  machine-settings = {
    "extensions.experimental.affinity" = { "asvetliakov.vscode-neovim" = 1 }
  }

  extensions = [
    "GitHub.vscode-github-actions",
    "GitHub.vscode-pull-request-github",
    "Github.copilot",
    "Anthropic.claude-code",
    "highagency.pencildev",
    "mongodb.mongodb-vscode",
    "openai.chatgpt",
    "ms-python.python",
    "ms-azuretools.vscode-docker",
    "Google.geminicodeassist",
    "likec4.likec4-vscode",
    "nefrob.vscode-just-syntax",
    "asvetliakov.vscode-neovim",
    "bradlc.vscode-tailwindcss",
    "Gruntfuggly.todo-tree",
    "usernamehw.errorlens",
    "hediet.vscode-drawio",
    "joshbolduc.story-explorer",
    "bruno-api-client.bruno",
    "pomdtr.excalidraw-editor"
  ]
}

resource "coder_app" "neovim" {
  agent_id     = coder_agent.main.id
  slug         = "neovim"
  display_name = "Neovim"
  icon         = "/icon/terminal.svg"
  command      = "nvim"
  order        = 3
}
