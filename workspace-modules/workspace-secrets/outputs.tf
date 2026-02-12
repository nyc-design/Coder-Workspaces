output "gcp_projects" {
  value = data.google_projects.gcp_projects.projects
}

output "github_pat" {
  value     = data.google_secret_manager_secret_version.github_pat.secret_data
  sensitive = true
}

output "docker_config" {
  value     = data.google_secret_manager_secret_version.docker_config.secret_data
  sensitive = true
}

output "signoz_url" {
  value     = data.google_secret_manager_secret_version.signoz_url.secret_data
  sensitive = true
}

output "signoz_api_key" {
  value     = data.google_secret_manager_secret_version.signoz_api_key.secret_data
  sensitive = true
}

output "context7_api_key" {
  value     = var.include_context7 ? data.google_secret_manager_secret_version.context7_api_key[0].secret_data : ""
  sensitive = true
}
