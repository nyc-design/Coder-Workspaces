# Coder Workspace Images Repository

This repository contains Docker build files and initialization scripts for Coder workspace images. It provides standardized development environments with pre-configured tooling and automated setup scripts.

## Repository Structure

```
.github/workflows/         # GitHub Actions for automated Docker builds
├── build-base-dev.yaml   # Multi-arch build for base development image
├── build-cpp-dev.yaml    # C++ development image build
├── build-fullstack-dev.yaml  # Full-stack development image build
├── build-nextjs-dev.yaml # Next.js development image build
└── build-python-dev.yaml # Python development image build

workspace-images/          # Docker images for different development stacks
├── base-dev/             # Foundation image with core tools (Docker, GCP CLI, Node.js, Claude Code)
├── cpp-dev/              # C++ development environment
├── fullstack-dev/        # Full-stack web development
├── nextjs-dev/           # Next.js specific setup
├── playwright-dev/       # Browser testing with VNC support
└── python-dev/           # Python development environment

workspace-templates/       # Coder workspace template definitions
├── repo-devcontainer/    # Repository-based devcontainer template
└── repo-envbuilder-agent/ # Repository template with AI agent selection

workspace-modules/         # Reusable Terraform modules for workspace templates
├── gemini-cli/           # Google Gemini CLI module
└── codex/                # OpenAI Codex module

scripts/                   # Utility scripts
└── deploy-issue-automation.sh  # Deploy GitHub issue automation to repos
```

## Key Architecture Concepts

### Base Image Pattern
- All specialized images inherit from `base-dev/`
- Base image provides: Docker-in-Docker, GCP CLI, GitHub CLI, Node.js, AI coding tools
- Language-specific images add their own tooling and init scripts

### Initialization System
- Master init script: `workspace-images/base-dev/init-workspace.sh` (copied to `/usr/local/bin/`)
- Language-specific scripts placed in `/usr/local/share/workspace-init.d/`
- Auto-executed by Coder agent on workspace startup
- Handles: Docker daemon, authentication, shell configuration, GCP secrets

### Shell Configuration
- Uses Starship prompt with Lion theme
- Configurations only apply to new shell sessions (not current init context)
- Changes to `.bashrc` require `exec bash` or workspace restart to see effects

## Working with This Repository

### Automated CI/CD Pipeline
- GitHub Actions automatically build and push multi-arch Docker images to GCP Artifact Registry
- Triggers on changes to `workspace-images/*/` directories or workflow files
- Uses native ARM64 and AMD64 runners for optimal performance
- Images pushed to `us-central1-docker.pkg.dev/coder-nt/workspace-images/`
- Tagged with both `:latest` and `:sha-{commit}` for version control

### Modifying Init Scripts
1. Edit the master script in `workspace-images/base-dev/init-workspace.sh`
2. Push changes to trigger automatic Docker build via GitHub Actions
3. New images automatically available in GCP Artifact Registry
4. Test in new workspace to verify changes

### Adding New Language Support
1. Create new directory under `workspace-images/`
2. Write Dockerfile that extends base-dev
3. Add language-specific init script to `/usr/local/share/workspace-init.d/`
4. Copy GitHub Actions workflow from existing image, update IMAGE_NAME
5. Push changes to trigger automated build

### Manual Building (if needed)
- Use standard Docker build commands in each image directory
- Base image must be built first as foundation for others
- GitHub Actions preferred for consistency and multi-arch support

## Environment Variables

### Authentication
- `GH_TOKEN` or `GITHUB_PAT`: GitHub CLI authentication
- `CODER_GCP_PROJECT`: Enables automatic GCP secrets discovery and loading

### GCP Integration
When `CODER_GCP_PROJECT` is set, init scripts automatically:
- Discover all secrets in the GCP project
- Load secret values as environment variables
- Make secrets available in all shell sessions

## Important Implementation Notes

- Init scripts run in non-interactive shell context during workspace creation
- Shell configuration changes only affect future sessions, not current execution
- Docker daemon requires specific permission fixes in `/run` and `/var/run`
- Starship prompt changes won't be visible until new interactive shell starts

## GitHub Actions Workflow Details

### Multi-Architecture Build Strategy
- Builds native on ARM64 (`ubuntu-24.04-arm`) and AMD64 (`ubuntu-latest`) runners
- Uses `push-by-digest` to build each architecture separately
- Merges digests into single multi-arch manifest with `docker buildx imagetools create`
- Automatically cleans up individual digest versions to reduce registry clutter

### Build Triggers
- **Path-based**: Changes to `workspace-images/{image-name}/**` or workflow files
- **Manual**: `workflow_dispatch` for on-demand builds
- **Authentication**: Uses workload identity with `GCP_SA_KEY` secret

### Image Tagging Strategy
- `:latest` - Always points to most recent build
- `:sha-{7-char-commit}` - Specific commit-based tag for reproducibility

## GitHub Issue Automation

This repository includes an automated workflow for dispatching GitHub issues to AI coding agents running in Coder workspaces.

### How It Works

1. Create a GitHub issue describing a bug or feature
2. Label it with `coder-claude`, `coder-codex`, or `coder-gemini`
3. GitHub Actions automatically:
   - Finds or creates a Coder workspace for the repository
   - Dispatches a task to the selected AI agent
   - AI agent reviews the issue, creates a fix branch, and opens a PR
   - PR link is posted back to the issue

### Quick Start

```bash
# Deploy to your repositories
./scripts/deploy-issue-automation.sh my-repo-1 my-repo-2

# Or use the workflow directly
curl -o .github/workflows/coder-issue-automation.yaml \
  https://raw.githubusercontent.com/nyc-design/Coder-Workspaces/main/.github/workflows/coder-issue-automation.yaml
```

**Required Secrets:**
- `CODER_URL`: Your Coder deployment URL
- `CODER_SESSION_TOKEN`: From `coder token create --lifetime 8760h --name "GitHub Actions"`

**Full Documentation:** [CODER_ISSUE_AUTOMATION.md](CODER_ISSUE_AUTOMATION.md)

## Common Tasks

- **Update base tools**: Modify `base-dev/Dockerfile` and `init-workspace.sh`, push to trigger build
- **Add language support**: Create new image directory, copy/modify GitHub Actions workflow
- **Debug build issues**: Check GitHub Actions logs, verify GCP authentication
- **Debug init issues**: Check `/usr/local/bin/init-workspace.sh` exists and is executable
- **Test shell config**: Use `exec bash` or restart workspace to see prompt changes
- **Troubleshoot secrets**: Verify `CODER_GCP_PROJECT` is set and GCP authentication works
- **Monitor builds**: Watch GitHub Actions for build status and multi-arch manifest creation

This repository follows Docker best practices and Coder workspace patterns. All changes should maintain backward compatibility and follow the established initialization flow.