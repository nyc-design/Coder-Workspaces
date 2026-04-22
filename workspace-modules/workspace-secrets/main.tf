terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

data "google_projects" "gcp_projects" {
  filter = "lifecycleState:ACTIVE"
}

data "google_secret_manager_secret_version" "github_pat" {
  secret = "GH_PAT"
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

data "google_secret_manager_secret_version" "context7_api_key" {
  count  = var.include_context7 ? 1 : 0
  secret = "CONTEXT7_API_KEY"
}

data "google_secret_manager_secret_version" "hapi_cli_api_token" {
  count  = var.include_hapi ? 1 : 0
  secret = "HAPI_CLI_API_TOKEN"
}

data "google_secret_manager_secret_version" "claude_code_oauth_token" {
  count  = var.include_claude_code_oauth ? 1 : 0
  secret = "CLAUDE_CODE_OAUTH_TOKEN"
}

data "google_secret_manager_secret_version" "multica_server_url" {
  count  = var.include_multica ? 1 : 0
  secret = "MULTICA_SERVER_URL"
}

data "google_secret_manager_secret_version" "multica_app_url" {
  count  = var.include_multica ? 1 : 0
  secret = "MULTICA_APP_URL"
}

data "google_secret_manager_secret_version" "multica_token" {
  count  = var.include_multica ? 1 : 0
  secret = "MULTICA_TOKEN"
}
