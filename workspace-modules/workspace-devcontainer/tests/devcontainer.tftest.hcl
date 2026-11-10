# Run from the module directory: terraform init && terraform test
#
# Providers are mocked, so nothing is fetched, pulled or created. The GitHub
# response is injected per run. These tests cover what Terraform decides: which
# image runs, and what the container and agent are handed. What happens inside
# the container is covered by test-scripts.sh.

mock_provider "http" {}
mock_provider "docker" {
  mock_data "docker_registry_image" {
    defaults = {
      sha256_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    }
  }
  mock_resource "docker_image" {
    defaults = {
      image_id = "sha256:2222222222222222222222222222222222222222222222222222222222222222"
    }
  }
}

variables {
  start_count      = 1
  agent_token      = "agent-token"
  access_url       = "http://localhost:3000"
  init_script      = "curl http://127.0.0.1:3000/bin/coder && exec ./coder agent"
  agent_env        = { CODER_AGENT_EXP_SKILLS_DIRS = "~/.agents/skills", SHARED = "from-agent-env" }
  repo             = "octo/app"
  github_token     = "gh-token"
  workspace_folder = "/workspaces/app"
  fallback_image   = "example/base-dev:latest"
  startup_script   = "echo init-pipeline"
}

run "strict_json" {
  override_data {
    target = data.http.devcontainer
    values = {
      status_code   = 200
      response_body = file("./tests/fixtures/basic.json")
    }
  }

  assert {
    condition     = output.image == "example/python-dev:latest"
    error_message = "image should come from devcontainer.json, got ${output.image}"
  }
  assert {
    condition     = output.image_id == "sha256:2222222222222222222222222222222222222222222222222222222222222222"
    error_message = "the container should run the pulled image id"
  }
  assert {
    condition     = docker_image.workspace[0].name == "example/python-dev@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "the image is pulled by the registry's current digest, not by tag (a tag already on the host is never pulled again): ${docker_image.workspace[0].name}"
  }
  assert {
    condition     = length(terraform_data.prune_images) == 1
    error_message = "superseded versions of the image are pruned on start"
  }
  assert {
    condition     = data.http.devcontainer[0].url == "https://api.github.com/repos/octo/app/contents/.devcontainer/devcontainer.json"
    error_message = "default-branch lookups carry no ref: ${data.http.devcontainer[0].url}"
  }
  assert {
    condition     = output.entrypoint[0] == "sh" && output.entrypoint[1] == "-c" && strcontains(output.entrypoint[2], "chown coder:coder") && strcontains(output.entrypoint[2], " clone ") && strcontains(output.entrypoint[2], "DEVCONTAINER_PY") && endswith(output.entrypoint[2], "curl http://host.docker.internal:3000/bin/coder && exec ./coder agent")
    error_message = "the entrypoint fixes ownership, clones, applies devcontainer.json, then runs the init script with localhost rewritten"
  }
  assert {
    condition     = local.clone_env["WORKSPACE_CLONE_URL"] == "https://github.com/octo/app.git" && local.clone_env["WORKSPACE_CLONE_REF"] == "" && local.clone_env["WORKSPACE_CLONE_DIR"] == "/workspaces/app" && nonsensitive(local.clone_env["WORKSPACE_CLONE_TOKEN"]) == "gh-token"
    error_message = "clone settings are wrong"
  }
  assert {
    condition     = local.container_env["SHARED"] == "from-agent-env" && local.container_env["CODER_AGENT_URL"] == "http://host.docker.internal:3000" && local.container_env["CODER_AGENT_TOKEN"] == "agent-token"
    error_message = "the container gets the template's agent env and the agent credentials"
  }
  assert {
    condition     = endswith(output.startup_script, "\ndevcontainer_lifecycle ${base64encode("/workspaces/app")}\necho init-pipeline")
    error_message = "startup_script runs the lifecycle commands from the project folder, then the init pipeline"
  }
}

run "comments_and_trailing_commas" {
  override_data {
    target = data.http.devcontainer
    values = {
      status_code   = 200
      response_body = file("./tests/fixtures/jsonc.json")
    }
  }

  assert {
    condition     = output.image == "example/fullstack-dev:latest"
    error_message = "a file Terraform cannot parse as JSON should still yield its image: ${output.image}"
  }
}

run "end_of_line_comment" {
  override_data {
    target = data.http.devcontainer
    values = {
      status_code   = 200
      response_body = file("./tests/fixtures/eol-comment.json")
    }
  }

  assert {
    condition     = output.image == "example/rust-dev:latest"
    error_message = "a file Terraform cannot parse as JSON should still yield its image: ${output.image}"
  }
}

run "no_image_falls_back" {
  override_data {
    target = data.http.devcontainer
    values = {
      status_code   = 200
      response_body = file("./tests/fixtures/build.json")
    }
  }

  assert {
    condition     = output.image == "example/base-dev:latest"
    error_message = "a nested \"image\" key must not be mistaken for the devcontainer image: ${output.image}"
  }
}

run "scaffold_branch" {
  variables {
    repo     = "nyc-design/Project-Scaffolds"
    repo_ref = "scaffold/python"
  }
  override_data {
    target = data.http.devcontainer
    values = {
      status_code   = 200
      response_body = "{\"image\": \"example/python-dev:latest\"}"
    }
  }

  assert {
    condition     = data.http.devcontainer[0].url == "https://api.github.com/repos/nyc-design/Project-Scaffolds/contents/.devcontainer/devcontainer.json?ref=scaffold%2Fpython"
    error_message = "the ref must be URL-encoded: ${data.http.devcontainer[0].url}"
  }
  assert {
    condition     = local.clone_env["WORKSPACE_CLONE_REF"] == "scaffold/python" && local.clone_env["WORKSPACE_CLONE_URL"] == "https://github.com/nyc-design/Project-Scaffolds.git"
    error_message = "the scaffold branch must be what gets cloned"
  }
}

run "missing_file_falls_back" {
  override_data {
    target = data.http.devcontainer
    values = {
      status_code   = 404
      response_body = "{\"message\":\"Not Found\",\"status\":\"404\"}"
    }
  }

  assert {
    condition     = output.image == "example/base-dev:latest"
    error_message = "404 means no devcontainer.json: ${output.image}"
  }
}

run "github_error_stops_the_build" {
  command = plan

  override_data {
    target = data.http.devcontainer
    values = {
      status_code   = 503
      response_body = "upstream unavailable"
    }
  }

  expect_failures = [data.http.devcontainer]
}

run "stopped_workspace_touches_nothing" {
  variables {
    start_count = 0
  }

  assert {
    condition     = length(data.http.devcontainer) == 0 && length(data.docker_registry_image.workspace) == 0 && length(docker_image.workspace) == 0 && length(terraform_data.prune_images) == 0
    error_message = "stopping a workspace must not depend on GitHub or the registry"
  }
  assert {
    condition     = output.image_id == "example/base-dev:latest"
    error_message = "image_id needs a value while stopped, got ${output.image_id}"
  }
}

# Coder plans with empty parameters when a template version is imported.
run "template_import_with_empty_parameters" {
  variables {
    repo             = ""
    github_token     = ""
    workspace_folder = "/workspaces/"
  }

  assert {
    condition     = length(data.http.devcontainer) == 0 && output.image == "example/base-dev:latest"
    error_message = "an empty repo must not reach GitHub"
  }
  assert {
    condition     = length(local.clone_env) == 0 && endswith(output.startup_script, var.startup_script)
    error_message = "with no repo there is nothing to clone, and the init pipeline must still run"
  }
}
