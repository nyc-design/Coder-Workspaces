# Replaces envbuilder for templates whose projects declare a prebuilt image in
# .devcontainer/devcontainer.json. Instead of running an envbuilder container
# that unpacks the image over itself on every start, the image is resolved at
# plan time and run directly:
#
#   1. read devcontainer.json from GitHub            -> image, env, lifecycle commands
#   2. container entrypoint: ownership fix, clone    -> then the agent init script
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

# ── devcontainer.json ────────────────────────────────────────────────────────
# The image has to be known before the container exists, so the file comes
# from GitHub rather than from the checkout.

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
  devcontainer_status = one(data.http.devcontainer[*].status_code)
  devcontainer_raw    = local.devcontainer_status == 200 ? data.http.devcontainer[0].response_body : ""

  # JSONC -> JSON: full-line // comments and trailing commas. Block comments
  # are left alone, because "/*" and "*/" also occur inside glob strings such
  # as "**/*.ts".
  devcontainer_json = replace(replace(local.devcontainer_raw, "/(?m)^\\s*//.*$/", ""), "/,(\\s*[}\\]])/", "$1")
  devcontainer      = try(jsondecode(local.devcontainer_json), null)
  devcontainer_ok   = can(keys(local.devcontainer))

  devcontainer_image = try(trimspace(tostring(local.devcontainer.image)), "")
  # Only for a file that does not parse (e.g. end-of-line comments): take the
  # first "image" key so the workspace still gets the right toolchain.
  devcontainer_image_guess = local.devcontainer_ok ? "" : try(regex("\"image\"\\s*:\\s*\"([^\"]+)\"", local.devcontainer_raw)[0], "")

  image = coalesce(local.devcontainer_image, local.devcontainer_image_guess, var.fallback_image)

  # containerEnv and remoteEnv both ended up on the agent process under
  # envbuilder; remoteEnv wins on conflict, as it did there.
  devcontainer_env_declared = merge(
    try({ for k, v in local.devcontainer.containerEnv : k => tostring(v) if v != null }, {}),
    try({ for k, v in local.devcontainer.remoteEnv : k => tostring(v) if v != null }, {}),
  )
  workspace_folder_name = basename(var.workspace_folder)
  devcontainer_env_resolved = {
    for k, v in local.devcontainer_env_declared : k => replace(replace(replace(replace(v,
      "$${containerWorkspaceFolderBasename}", local.workspace_folder_name),
      "$${localWorkspaceFolderBasename}", local.workspace_folder_name),
      "$${containerWorkspaceFolder}", var.workspace_folder),
    "$${localWorkspaceFolder}", var.workspace_folder)
  }
  # References to containerEnv:X and localEnv:X need a running container or a
  # local machine, and neither exists at plan time. Passing them through
  # literally would be worse than leaving the variable unset (think PATH).
  devcontainer_env         = { for k, v in local.devcontainer_env_resolved : k => v if !strcontains(v, "$${") }
  devcontainer_env_skipped = sort([for k, v in local.devcontainer_env_resolved : k if strcontains(v, "$${")])

  # A lifecycle command is a string (run by sh), an array (argv), or an object
  # of named strings/arrays. Each becomes one or more sh command lines; object
  # entries run in name order rather than in parallel.
  lifecycle_hooks = ["onCreateCommand", "updateContentCommand", "postCreateCommand", "postStartCommand"]
  lifecycle_commands = flatten([
    for hook in local.lifecycle_hooks : [
      for command in try(
        [tostring(local.devcontainer[hook])],
        [join(" ", [for arg in tolist(local.devcontainer[hook]) : "'${replace(arg, "'", "'\\''")}'"])],
        [
          for name in sort(keys(local.devcontainer[hook])) : try(
            tostring(local.devcontainer[hook][name]),
            join(" ", [for arg in tolist(local.devcontainer[hook][name]) : "'${replace(arg, "'", "'\\''")}'"]),
          )
        ],
        [],
      ) : { hook = hook, command = command } if try(trimspace(command), "") != ""
    ]
  ])

  # Shown at the top of the clone script's log in the Coder UI.
  notices = compact([
    local.devcontainer_status == 404 ? "No .devcontainer/devcontainer.json in ${var.repo}${var.repo_ref != "" ? " at ${var.repo_ref}" : ""}; using ${var.fallback_image}." : "",
    local.devcontainer_status == 200 && !local.devcontainer_ok ? "devcontainer.json in ${var.repo} is not valid JSON (only full-line // comments and trailing commas are tolerated). Its lifecycle commands and containerEnv were skipped." : "",
    local.devcontainer_status == 200 && local.devcontainer_image == "" && local.devcontainer_image_guess == "" ? "devcontainer.json in ${var.repo} has no \"image\" (Dockerfile builds and features are not supported); using ${var.fallback_image}." : "",
    length(local.devcontainer_env_skipped) > 0 ? "Skipped devcontainer environment variables that reference $${containerEnv:...} or $${localEnv:...}: ${join(", ", local.devcontainer_env_skipped)}." : "",
  ])
}

# ── Image ────────────────────────────────────────────────────────────────────
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
# order envbuilder did it: ownership, clone, then the agent init script.

locals {
  entrypoint_script = join("\n", [
    file("${path.module}/scripts/fix-ownership.sh"),
    file("${path.module}/scripts/clone.sh"),
    replace(var.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal"),
  ])

  # Read by clone.sh, which unsets them before the agent starts. Passed as env
  # rather than written into the entrypoint so the token is not in the
  # container's command line.
  clone_env = var.repo == "" ? {} : {
    "WORKSPACE_CLONE_URL"   = "https://github.com/${var.repo}.git"
    "WORKSPACE_CLONE_REF"   = var.repo_ref
    "WORKSPACE_CLONE_DIR"   = var.workspace_folder
    "WORKSPACE_CLONE_TOKEN" = var.github_token
  }

  # The devcontainer's own variables first, so the template's agent env and
  # the agent credentials win on conflict.
  container_env = merge(local.devcontainer_env, var.agent_env, local.clone_env, {
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
  startup_script = join("\n", concat(
    [file("${path.module}/scripts/lifecycle.sh")],
    ["devcontainer_enter ${base64encode(var.workspace_folder)}"],
    [for notice in local.notices : "devcontainer_notice ${base64encode(notice)}"],
    [for c in local.lifecycle_commands : "run_lifecycle_command ${c.hook} ${base64encode(c.command)}"],
    [var.startup_script],
  ))
}
