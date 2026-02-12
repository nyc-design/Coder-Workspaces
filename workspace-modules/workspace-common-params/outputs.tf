output "is_existing_project" {
  value = data.coder_parameter.is_existing_project.value
}

output "is_new_project" {
  value = data.coder_parameter.is_existing_project.value == "new"
}

output "repo_name" {
  value = try(data.coder_parameter.repo_name[0].value, "")
}

output "gcp_project_name" {
  value = try(data.coder_parameter.gcp_project_name[0].value, "")
}

output "new_project_type" {
  value = try(data.coder_parameter.new_project_type[0].value, "base")
}

output "new_project_name" {
  value = try(data.coder_parameter.new_project_name[0].value, "my-new-project")
}

output "agent_metadata_items" {
  value = [
    {
      display_name = "CPU Usage"
      key          = "0_cpu_usage"
      script       = "coder stat cpu"
      interval     = 10
      timeout      = 1
    },
    {
      display_name = "RAM Usage"
      key          = "1_ram_usage"
      script       = "coder stat mem"
      interval     = 10
      timeout      = 1
    },
    {
      display_name = "Home Disk"
      key          = "3_home_disk"
      script       = "coder stat disk --path $${HOME}"
      interval     = 60
      timeout      = 1
    },
    {
      display_name = "CPU Usage (Host)"
      key          = "4_cpu_usage_host"
      script       = "coder stat cpu --host"
      interval     = 10
      timeout      = 1
    },
    {
      display_name = "Memory Usage (Host)"
      key          = "5_mem_usage_host"
      script       = "coder stat mem --host"
      interval     = 10
      timeout      = 1
    },
    {
      display_name = "Load Average (Host)"
      key          = "6_load_host"
      script       = "echo \"`cat /proc/loadavg | awk '{ print $1 }'` `nproc`\" | awk '{ printf \"%0.2f\", $1/$2 }'"
      interval     = 60
      timeout      = 1
    },
    {
      display_name = "Swap Usage (Host)"
      key          = "7_swap_host"
      script       = "free -b | awk '/^Swap/ { printf(\"%.1f/%.1f\", $3/1024.0/1024.0/1024.0, $2/1024.0/1024.0/1024.0) }'"
      interval     = 10
      timeout      = 1
    },
  ]
}
