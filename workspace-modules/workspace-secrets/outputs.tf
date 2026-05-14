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

output "codestral_api_key" {
  value     = data.google_secret_manager_secret_version.codestral_api_key.secret_data
  sensitive = true
}

output "hapi_cli_api_token" {
  value     = var.include_hapi ? data.google_secret_manager_secret_version.hapi_cli_api_token[0].secret_data : ""
  sensitive = true
}
