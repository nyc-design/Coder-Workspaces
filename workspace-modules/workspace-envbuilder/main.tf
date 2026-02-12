locals {
  envbuilder_env = merge({
    "CODER_AGENT_TOKEN"            = var.agent_token
    "CODER_AGENT_URL"              = replace(var.access_url, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")
    "ENVBUILDER_INIT_SCRIPT"       = replace(var.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")
    "ENVBUILDER_FALLBACK_IMAGE"    = var.fallback_image
    "ENVBUILDER_DOCKER_CONFIG_BASE64" = var.docker_config_base64
    "ENVBUILDER_PUSH_IMAGE"        = "false"
    "ENVBUILDER_GIT_USERNAME"      = var.git_username
    "ENVBUILDER_GIT_URL"           = var.repo_url
    "ENVBUILDER_WORKSPACE_FOLDER"  = "/workspaces/${var.project_name}"
  }, var.is_new_project ? {
    "CODER_NEW_PROJECT" = "true"
    "CODER_PROJECT_NAME" = var.project_name
  } : {})

  docker_env = [for k, v in local.envbuilder_env : "${k}=${v}"]
}

resource "docker_image" "devcontainer_builder_image" {
  name         = var.devcontainer_builder_image
  keep_locally = true
}

resource "envbuilder_cached_image" "cached" {
  count         = 0
  builder_image = var.devcontainer_builder_image
  git_url       = var.repo_url
  cache_repo    = ""
  extra_env     = local.envbuilder_env
}
