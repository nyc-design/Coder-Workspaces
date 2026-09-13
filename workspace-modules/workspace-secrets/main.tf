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

data "google_secret_manager_secret_version" "codestral_api_key" {
  project = "ai-sidecar-nt"
  secret  = "CODESTRAL_API_KEY"
}

# App Store Connect API key, used by the `asc` CLI in swift-dev to drive Xcode
# Cloud, TestFlight and App Store Connect from Linux. Dev-environment
# credentials, so they come from here rather than the workspace's own GCP
# project. asc reads all three straight from the environment.
data "google_secret_manager_secret_version" "asc_key_id" {
  secret = "ASC_KEY_ID"
}

data "google_secret_manager_secret_version" "asc_issuer_id" {
  secret = "ASC_ISSUER_ID"
}

data "google_secret_manager_secret_version" "asc_private_key" {
  secret = "ASC_PRIVATE_KEY"
}
