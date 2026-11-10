# Run from the module directory: terraform init && terraform test
#
# Providers are mocked, so nothing is fetched, pulled or created. The GitHub
# response is injected per run, which is what these tests are about: how a
# devcontainer.json turns into an image, container env and lifecycle commands.

mock_provider "http" {}
mock_provider "coder" {}
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
  agent_id         = "agent-id"
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
    condition     = length(coder_script.without_repo) == 0
    error_message = "with a repo, git-clone's post_clone_script runs the init pipeline; it must not run twice"
  }

  assert {
    condition     = output.image_id == "sha256:2222222222222222222222222222222222222222222222222222222222222222"
    error_message = "the container should run the pulled image id"
  }
  assert {
    condition     = output.lifecycle_commands == [{ hook = "postCreateCommand", command = "cd services/frontend && npm install" }]
    error_message = "a string command runs as written, and an empty one is dropped: ${jsonencode(output.lifecycle_commands)}"
  }
  assert {
    condition = local.devcontainer_env == {
      STATE_DIR    = "/home/coder/.local/share/app"
      PROJECT_ROOT = "/workspaces/app/src"
      PROJECT_NAME = "app"
      SHARED       = "from-remote-env"
    }
    error_message = "containerEnv/remoteEnv resolution is wrong: ${jsonencode(local.devcontainer_env)}"
  }
  assert {
    condition     = local.devcontainer_env_skipped == tolist(["EDITOR_HOME", "PATH"])
    error_message = "variables needing containerEnv:/localEnv: must be skipped, never passed through: ${jsonencode(local.devcontainer_env_skipped)}"
  }
  assert {
    condition     = local.container_env["SHARED"] == "from-agent-env" && local.container_env["CODER_AGENT_URL"] == "http://host.docker.internal:3000" && local.container_env["CODER_AGENT_TOKEN"] == "agent-token"
    error_message = "the template's agent env and the agent credentials must win over the devcontainer's variables"
  }
  assert {
    condition     = length(output.notices) == 1 && strcontains(output.notices[0], "EDITOR_HOME, PATH")
    error_message = "skipped variables should be reported: ${jsonencode(output.notices)}"
  }
  assert {
    condition     = output.entrypoint[0] == "sh" && output.entrypoint[1] == "-c" && strcontains(output.entrypoint[2], "chown coder:coder") && strcontains(output.entrypoint[2], "curl http://host.docker.internal:3000/bin/coder && exec ./coder agent")
    error_message = "the entrypoint fixes ownership, then runs the init script with localhost rewritten"
  }
  assert {
    condition     = endswith(local.post_clone_script, "run_lifecycle_command postCreateCommand ${base64encode("cd services/frontend && npm install")}\necho init-pipeline")
    error_message = "post_clone_script must end with the lifecycle commands followed by the init pipeline"
  }
  assert {
    condition     = module.git_clone[0].clone_url == "https://github.com/octo/app.git" && module.git_clone[0].repo_dir == "/workspaces/app" && module.git_clone[0].branch_name == ""
    error_message = "clone target is wrong: ${module.git_clone[0].clone_url} -> ${module.git_clone[0].repo_dir}"
  }
  assert {
    condition     = data.http.devcontainer[0].url == "https://api.github.com/repos/octo/app/contents/.devcontainer/devcontainer.json"
    error_message = "default-branch lookups carry no ref: ${data.http.devcontainer[0].url}"
  }
}

run "comments_trailing_commas_and_every_command_form" {
  override_data {
    target = data.http.devcontainer
    values = {
      status_code   = 200
      response_body = file("./tests/fixtures/jsonc.json")
    }
  }

  assert {
    condition     = output.image == "example/fullstack-dev:latest" && length(output.notices) == 0
    error_message = "full-line comments and trailing commas must parse cleanly: ${output.image} ${jsonencode(output.notices)}"
  }
  assert {
    condition = output.lifecycle_commands == [
      { hook = "onCreateCommand", command = "'echo' 'it'\\''s created' 'a b'" },
      { hook = "updateContentCommand", command = "git submodule update --init" },
      { hook = "postCreateCommand", command = "'uv' 'sync'" },
      { hook = "postCreateCommand", command = "cd frontend && pnpm install" },
      { hook = "postStartCommand", command = "/usr/local/bin/start-gateway" },
    ]
    error_message = "hook order, argv quoting or object-form ordering is wrong: ${jsonencode(output.lifecycle_commands)}"
  }
  assert {
    condition     = local.devcontainer.customizations.vscode.settings["docs.url"] == "https://example.com/a//b" && local.devcontainer.customizations.vscode.settings["files.exclude"]["**/*.pyc"] == true
    error_message = "comment stripping must not touch // or /* inside strings"
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
      response_body = "{\"image\": \"example/python-dev:latest\", \"postCreateCommand\": \"uv sync\"}"
    }
  }

  assert {
    condition     = data.http.devcontainer[0].url == "https://api.github.com/repos/nyc-design/Project-Scaffolds/contents/.devcontainer/devcontainer.json?ref=scaffold%2Fpython"
    error_message = "the ref must be URL-encoded: ${data.http.devcontainer[0].url}"
  }
  assert {
    condition     = module.git_clone[0].branch_name == "scaffold/python" && module.git_clone[0].clone_url == "https://github.com/nyc-design/Project-Scaffolds.git"
    error_message = "the scaffold branch must be what gets cloned"
  }
}

run "unparsable_file_still_gets_its_image" {
  override_data {
    target = data.http.devcontainer
    values = {
      status_code   = 200
      response_body = file("./tests/fixtures/eol-comment.json")
    }
  }

  assert {
    condition     = output.image == "example/rust-dev:latest"
    error_message = "an unparsable file should still yield its image: ${output.image}"
  }
  assert {
    condition     = output.lifecycle_commands == [] && length(output.notices) == 1 && strcontains(output.notices[0], "not valid JSON")
    error_message = "skipped lifecycle commands must be reported: ${jsonencode(output.notices)}"
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
  assert {
    condition     = length(output.notices) == 1 && strcontains(output.notices[0], "has no \"image\"")
    error_message = "the fallback must be reported: ${jsonencode(output.notices)}"
  }
  assert {
    condition     = output.lifecycle_commands == [{ hook = "postCreateCommand", command = "make setup" }]
    error_message = "lifecycle commands still run on the fallback image"
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
    condition     = output.image == "example/base-dev:latest" && output.lifecycle_commands == []
    error_message = "404 means no devcontainer.json: ${output.image}"
  }
  assert {
    condition     = output.notices == tolist(["No .devcontainer/devcontainer.json in octo/app; using example/base-dev:latest."])
    error_message = "the fallback must be reported: ${jsonencode(output.notices)}"
  }
  assert {
    condition     = endswith(local.post_clone_script, "\necho init-pipeline")
    error_message = "the init pipeline runs whether or not there is a devcontainer.json"
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
    condition     = length(data.http.devcontainer) == 0 && length(data.docker_registry_image.workspace) == 0 && length(docker_image.workspace) == 0 && length(module.git_clone) == 0
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
    condition     = length(data.http.devcontainer) == 0 && output.image == "example/base-dev:latest" && length(output.notices) == 0
    error_message = "an empty repo must not reach GitHub"
  }

  assert {
    condition     = length(coder_script.without_repo) == 1 && endswith(coder_script.without_repo[0].script, var.startup_script)
    error_message = "with no repo to clone, the init pipeline must still run"
  }
}
