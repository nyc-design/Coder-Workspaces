# MCP server configurations for all agent types (Coder TOML, VS Code extensions, Claude Code)
# These locals are consumed by main.tf via local.additional_mcp_toml,
# local.additional_extensions_json, and local.mcp_claude.

locals {
  # ---------------------------------------------------------------------------
  # Pencil — design editor for .pen files (binary from VS Code extension)
  # ---------------------------------------------------------------------------
  pencil_mcp_cmd = "exec $(ls /home/coder/.local/share/code-server/extensions/highagency.pencildev-*/out/mcp-server-linux-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/x64/') 2>/dev/null | head -1) --app code-server"

  pencil_mcp_toml = <<-EOT
    [mcp_servers.pencil]
    command = "bash"
    args = ["-c", "${local.pencil_mcp_cmd}"]
    type = "stdio"
  EOT

  pencil_mcp_extensions_map = {
    pencil = {
      command     = "bash"
      args        = ["-c", local.pencil_mcp_cmd]
      type        = "stdio"
      description = "Pencil design editor for .pen files"
      enabled     = true
      name        = "Pencil"
      timeout     = 3000
    }
  }

  pencil_mcp_claude_map = {
    pencil = {
      command = "bash"
      args    = ["-c", local.pencil_mcp_cmd]
      type    = "stdio"
    }
  }

  # ---------------------------------------------------------------------------
  # Playwright — browser automation
  # ---------------------------------------------------------------------------
  playwright_mcp_toml = <<-EOT
    [mcp_servers.playwright]
    command = "npx"
    args = ["@playwright/mcp@latest", "--browser=chromium", "--no-sandbox", "--headless"]
    type = "stdio"
  EOT

  playwright_mcp_extensions_map = {
    playwright = {
      command     = "npx"
      args        = ["@playwright/mcp@latest", "--browser=chromium", "--no-sandbox", "--headless"]
      type        = "stdio"
      description = "Playwright browser automation"
      enabled     = true
      name        = "Playwright"
      timeout     = 3000
    }
  }

  playwright_mcp_claude_map = {
    playwright = {
      command = "npx"
      args    = ["-y", "@playwright/mcp@latest", "--browser=chromium", "--no-sandbox", "--headless"]
      type    = "stdio"
    }
  }

  # ---------------------------------------------------------------------------
  # Context7 — up-to-date library documentation
  # ---------------------------------------------------------------------------
  context7_mcp_toml_raw = <<-EOT
    [mcp_servers.context7]
    url = "https://mcp.context7.com/mcp"
    http_headers = { "CONTEXT7_API_KEY" = "${local.context7_api_key}" }
  EOT

  context7_mcp_toml = local.context7_api_key != "" ? local.context7_mcp_toml_raw : ""

  context7_mcp_extensions_map = local.context7_api_key != "" ? {
    context7 = {
      httpUrl = "https://mcp.context7.com/mcp"
      headers = {
        CONTEXT7_API_KEY = local.context7_api_key
        Accept           = "application/json, text/event-stream"
      }
    }
  } : {}

  context7_mcp_claude_map = local.context7_api_key != "" ? {
    context7 = {
      type = "http"
      url  = "https://mcp.context7.com/mcp"
      headers = {
        CONTEXT7_API_KEY = local.context7_api_key
      }
    }
  } : {}

  # ---------------------------------------------------------------------------
  # Grep — search public GitHub repos for code examples
  # ---------------------------------------------------------------------------
  grep_mcp_toml = <<-EOT
    [mcp_servers.grep]
    url = "https://mcp.grep.app"
  EOT

  grep_mcp_extensions_map = {
    grep = {
      httpUrl = "https://mcp.grep.app"
    }
  }

  grep_mcp_claude_map = {
    grep = {
      type = "http"
      url  = "https://mcp.grep.app"
    }
  }

  # ---------------------------------------------------------------------------
  # LikeC4 — C4 architecture modeling
  # ---------------------------------------------------------------------------
  likec4_mcp_toml = <<-EOT
    [mcp_servers.likec4]
    command = "likec4"
    args = ["mcp", "--stdio"]
    type = "stdio"
  EOT

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

  likec4_mcp_claude_map = {
    likec4 = {
      command = "likec4"
      args    = ["mcp", "--stdio"]
      type    = "stdio"
    }
  }

  # ---------------------------------------------------------------------------
  # Stitch — Google AI design tools
  # ---------------------------------------------------------------------------
  stitch_mcp_toml = <<-EOT
    [mcp_servers.stitch]
    command = "npx"
    args = ["@_davideast/stitch-mcp", "proxy"]
    type = "stdio"
    [mcp_servers.stitch.env]
    STITCH_USE_SYSTEM_GCLOUD = "1"
    STITCH_PROJECT_ID = "coder-nt"
  EOT

  stitch_mcp_extensions_map = {
    stitch = {
      command     = "npx"
      args        = ["@_davideast/stitch-mcp", "proxy"]
      type        = "stdio"
      env         = { STITCH_USE_SYSTEM_GCLOUD = "1", STITCH_PROJECT_ID = "coder-nt" }
      description = "Google Stitch AI design tools"
      enabled     = true
      name        = "Stitch"
      timeout     = 3000
    }
  }

  stitch_mcp_claude_map = {
    stitch = {
      command = "npx"
      args    = ["-y", "@_davideast/stitch-mcp", "proxy"]
      type    = "stdio"
      env     = { STITCH_USE_SYSTEM_GCLOUD = "1", STITCH_PROJECT_ID = "coder-nt" }
    }
  }

  # ---------------------------------------------------------------------------
  # SigNoz — observability (traces, logs, metrics)
  # ---------------------------------------------------------------------------
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

  # ---------------------------------------------------------------------------
  # Aggregated outputs — consumed by main.tf
  # ---------------------------------------------------------------------------
  additional_mcp_toml = trimspace(join("\n", compact([
    local.pencil_mcp_toml,
    local.playwright_mcp_toml,
    local.context7_mcp_toml,
    local.grep_mcp_toml,
    local.likec4_mcp_toml,
    local.stitch_mcp_toml,
    local.signoz_mcp_toml,
  ])))

  additional_extensions_json = jsonencode(merge(
    local.pencil_mcp_extensions_map,
    local.playwright_mcp_extensions_map,
    local.context7_mcp_extensions_map,
    local.grep_mcp_extensions_map,
    local.likec4_mcp_extensions_map,
    local.stitch_mcp_extensions_map,
    local.signoz_mcp_extensions_map,
  ))

  mcp_claude = jsonencode({
    mcpServers = merge(
      local.pencil_mcp_claude_map,
      local.playwright_mcp_claude_map,
      local.context7_mcp_claude_map,
      local.grep_mcp_claude_map,
      local.likec4_mcp_claude_map,
      local.stitch_mcp_claude_map,
      local.signoz_mcp_claude_map,
    )
  })
}
