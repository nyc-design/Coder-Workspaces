data "coder_parameter" "is_existing_project" {
  name         = "is_existing_project"
  display_name = "Project Type"
  type         = "string"
  default      = "existing"
  description  = "Use an existing GitHub repository or create a new project?"
  order        = 0

  option {
    name  = "Existing Repository"
    value = "existing"
  }
  option {
    name  = "New Project"
    value = "new"
  }
}

data "coder_parameter" "repo_name" {
  count        = data.coder_parameter.is_existing_project.value == "existing" ? 1 : 0
  name         = "repo_name"
  display_name = "GitHub Repository"
  description  = "Enter just the repo name (e.g., shadowscout, stellarscout, etc)."
  type         = "string"
  form_type    = "input"
  order        = 1
}

data "coder_parameter" "gcp_project_name" {
  count        = data.coder_parameter.is_existing_project.value == "existing" ? 1 : 0
  name         = "gcp_project_name"
  display_name = "GCP Project (Optional)"
  default      = ""
  description  = "Enter a GCP Project to automatically configure secrets and credentials"
  type         = "string"
  form_type    = "input"
  order        = 2
}

data "coder_parameter" "new_project_type" {
  count        = data.coder_parameter.is_existing_project.value == "new" ? 1 : 0
  name         = "new_project_type"
  display_name = "New Project Type"
  type         = "string"
  default      = "base"
  order        = 1

  option {
    name  = "Base Project"
    value = "base"
  }
  option {
    name  = "Python Project"
    value = "python"
  }
  option {
    name  = "Next.js Project"
    value = "nextjs"
  }
  option {
    name  = "C++ Project"
    value = "cpp"
  }
  option {
    name  = "Fullstack Project"
    value = "fullstack"
  }
}

data "coder_parameter" "new_project_name" {
  count        = data.coder_parameter.is_existing_project.value == "new" ? 1 : 0
  name         = "project_name"
  display_name = "Project Name"
  type         = "string"
  default      = "my-new-project"
  order        = 2
}
