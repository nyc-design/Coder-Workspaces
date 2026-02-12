terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

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
