output "envbuilder_env" {
  value     = local.envbuilder_env
  sensitive = true
}

output "docker_env" {
  value     = local.docker_env
  sensitive = true
}

output "devcontainer_builder_image" {
  value = var.devcontainer_builder_image
}
