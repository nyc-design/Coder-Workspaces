# Replaces envbuilder for templates whose projects declare a prebuilt image in
# .devcontainer/devcontainer.json. Instead of running an envbuilder container
# that unpacks the image over itself on every start, the image is resolved at
# plan time and run directly:
#
#   1. read devcontainer.json's "image" from GitHub  -> the image to run
#   2. container entrypoint: ownership fix, clone,
#      devcontainer.json env from the checkout       -> then the agent init script
#   3. output startup_script (for coder_agent)       -> lifecycle commands, then var.startup_script
#
# Dockerfile builds and devcontainer features are not supported; a
# devcontainer.json without an "image" falls back to var.fallback_image.

terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
    }
    http = {
      source = "hashicorp/http"
    }
  }
}

# ── Image ────────────────────────────────────────────────────────────────────
# The image has to be known before the container exists, so this one field is
# read from GitHub. Everything else in devcontainer.json is read from the
# checkout, inside the container (scripts/devcontainer.sh).

data "http" "devcontainer" {
  count = var.start_count > 0 && var.repo != "" ? 1 : 0

  url = "https://api.github.com/repos/${var.repo}/contents/.devcontainer/devcontainer.json${var.repo_ref != "" ? "?ref=${urlencode(var.repo_ref)}" : ""}"

  request_headers = merge(
    {
      Accept                 = "application/vnd.github.raw+json"
      "X-GitHub-Api-Version" = "2022-11-28"
    },
    var.github_token != "" ? { Authorization = "Bearer ${var.github_token}" } : {},
  )

  retry {
    attempts     = 2
    min_delay_ms = 1000
  }

  lifecycle {
    # 404 is a normal answer (no devcontainer.json). Anything else means the
    # image is unknown, and starting on the fallback would be a silent
    # downgrade, so the build stops instead.
    postcondition {
      condition     = contains([200, 404], self.status_code)
      error_message = "GitHub answered HTTP ${self.status_code} for .devcontainer/devcontainer.json in ${var.repo}, so the workspace image could not be determined. Check GitHub's status and your linked GitHub account, then start the workspace again."
    }
  }
}

locals {
  devcontainer_raw = one(data.http.devcontainer[*].status_code) == 200 ? data.http.devcontainer[0].response_body : ""
  devcontainer     = try(jsondecode(local.devcontainer_raw), null)

  # A file with comments or trailing commas is not JSON to Terraform. For
  # those, take the first "image" key that starts a line.
  devcontainer_image_guess = can(keys(local.devcontainer)) ? "" : try(regex("(?m)^\\s*\"image\"\\s*:\\s*\"([^\"]+)\"", local.devcontainer_raw)[0], "")

  image = coalesce(try(trimspace(tostring(local.devcontainer.image)), ""), local.devcontainer_image_guess, var.fallback_image)
}

# The registry lookup makes a moved tag (":latest") pull again on the next
# start. keep_locally: other workspaces run containers from the same image.

data "docker_registry_image" "workspace" {
  count = var.start_count
  name  = local.image
}

resource "docker_image" "workspace" {
  count         = var.start_count
  name          = data.docker_registry_image.workspace[0].name
  pull_triggers = [data.docker_registry_image.workspace[0].sha256_digest]
  keep_locally  = true
}

# ── Container ────────────────────────────────────────────────────────────────
# The entrypoint does what has to be finished before the agent exists, in the
# order envbuilder did it: ownership, clone, devcontainer.json environment,
# then the agent init script.

locals {
  entrypoint_script = join("\n", [
    file("${path.module}/scripts/fix-ownership.sh"),
    file("${path.module}/scripts/clone.sh"),
    file("${path.module}/scripts/devcontainer.sh"),
    replace(var.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal"),
  ])

  # Read by clone.sh and devcontainer.sh, which unset them before the agent starts. Passed as env
  # rather than written into the entrypoint so the token is not in the
  # container's command line.
  clone_env = var.repo == "" ? {} : {
    "WORKSPACE_CLONE_URL"   = "https://github.com/${var.repo}.git"
    "WORKSPACE_CLONE_REF"   = var.repo_ref
    "WORKSPACE_CLONE_DIR"   = var.workspace_folder
    "WORKSPACE_CLONE_TOKEN" = var.github_token
  }

  container_env = merge(var.agent_env, local.clone_env, {
    "CODER_AGENT_TOKEN" = var.agent_token
    "CODER_AGENT_URL"   = replace(var.access_url, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")
  })
}

# ── Agent startup script ─────────────────────────────────────────────────────
# The repository is in place before the agent connects, so this is an ordinary
# coder_agent.startup_script: the lifecycle commands, then var.startup_script.
# It must not depend on anything derived from the agent, or the template's
# agent and this module would form a cycle.

locals {
  startup_script = join("\n", [
    file("${path.module}/scripts/lifecycle.sh"),
    "devcontainer_lifecycle ${base64encode(var.workspace_folder)}",
    var.startup_script,
  ])
}
