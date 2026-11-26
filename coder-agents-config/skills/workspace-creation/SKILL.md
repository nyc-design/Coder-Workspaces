---
name: workspace-creation
description: Naming, template, and parameter rules for finding or creating a Coder workspace for a repository or a new project. Read before calling create_workspace, and when deciding whether an existing workspace should be reused.
---

# Finding or creating a workspace

Reuse the workspace attached to the chat. Create one only when the task needs
workspace files or command execution and none is attached.

## 1. Identify the repository

The primary GitHub account is `nyc-design`. Find the repository with the GitHub
MCP tools. Ask only when the request matches more than one repository.

## 2. Work out the workspace name

- Take the repository name in PascalCase, with spaces replaced by `-`.
- Agent mode (the default): append `-Agents`, for example `Coder-Workspaces-Agents`.
- Self mode: no suffix, for example `Coder-Workspaces`.

If a workspace with that name already exists, use it instead of creating another.

## 3. Create it

Use the `project-workspace` template, following the template discovery
instructions from `list_templates`. Use another template only when the user asks
for it.

Always set `workspace_mode` to `"agent"` or `"self"` explicitly.

| Case | Parameters |
|---|---|
| Existing repository | `is_existing_project="existing"`, `repo_name` without the owner |
| New project | `is_existing_project="new"`, `project_name`, and a `new_project_type` from the options the template lists |

Leave `gcp_project_name` empty unless the task needs the project's secrets and
the user has confirmed the GCP project ID.

## 4. Wait

Wait for the workspace to finish starting before running anything in it.
