output "image" {
  description = "Image reference the workspace runs: the devcontainer.json image, or the fallback."
  value       = local.image
}

output "image_id" {
  description = "Pulled image ID for docker_container.image. Falls back to the reference while the workspace is stopped and nothing is pulled."
  value       = try(docker_image.workspace[0].image_id, local.image)
}

output "entrypoint" {
  description = "Container entrypoint: ownership fix, then the agent init script. Set as the entrypoint, not the command, so an image ENTRYPOINT cannot wrap it."
  value       = ["sh", "-c", local.entrypoint_script]
}

output "docker_env" {
  value     = [for k, v in local.container_env : "${k}=${v}"]
  sensitive = true
}

output "lifecycle_commands" {
  description = "Devcontainer lifecycle commands in run order, as { hook, command } with command being an sh command line."
  value       = local.lifecycle_commands
}

output "notices" {
  description = "Human-readable notes about how devcontainer.json was interpreted (fallbacks, skipped settings)."
  value       = local.notices
}
