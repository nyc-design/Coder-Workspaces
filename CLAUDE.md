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
├── base-dev/             # Foundation image with core tools (Docker, GCP CLI, Node.js, Claude Code, RTK)
│   └── init.d/           # Modular init scripts (01-docker, 02-starship, ..., 05-rtk, ..., 10-mcp-cleanup)
├── shared/               # Shared install scripts used by multiple images
│   └── install-python.sh # Python tools + libs (used by python-dev and fullstack-dev)
├── cpp-dev/              # C++ development environment
├── fullstack-dev/        # Full-stack web development (extends nextjs-dev + shared Python)
├── nextjs-dev/           # Next.js specific setup (Node.js, Playwright, npm globals)
├── playwright-dev/       # Browser testing with VNC support
└── python-dev/           # Python development environment (uses shared/install-python.sh)

workspace-templates/       # Coder workspace template definitions
├── windows-server-gcp/    # Windows VM on GCP with browser-based RDP access
├── vm-ssh-gateway/        # Container workspace template with code-server + SSH/SSHFS gateway to bare VMs
├── repo-devcontainer/    # Repository-based devcontainer template
└── repo-envbuilder-agent/ # Repository template with AI agent selection

workspace-modules/         # Reusable Terraform modules for workspace templates
├── gemini/               # Google Gemini CLI module
└── codex/                # OpenAI Codex module

scripts/                   # Utility scripts
└── deploy-issue-automation.sh  # Deploy GitHub issue automation to repos
```

## Key Architecture Concepts

### Docker Image Hierarchy
```
base-dev (core tools, Docker, Git, GCP, AI CLIs)
├── python-dev (uses shared/install-python.sh)
├── nextjs-dev (Node.js, npm globals, Playwright)
│   └── fullstack-dev (uses shared/install-python.sh + fastapi/uvicorn)
├── cpp-dev
└── playwright-dev
```

### Initialization System
- Modular init scripts in `workspace-images/base-dev/init.d/` are COPY'd to `/usr/local/share/workspace-init.d/`
- `run-workspace-inits` runner iterates `workspace-init.d/*.sh` in sorted order
- Numbering convention: `01-10` base-dev core, `20-29` language-specific, `30-39` composite
- Language-specific scripts placed in `/usr/local/share/workspace-init.d/` by child Dockerfiles
- Auto-executed by Coder agent on workspace startup

#### Base-dev Init Scripts (01-10)
| Script | Purpose |
|--------|---------|
| `01-docker.sh` | Docker daemon startup, socket permissions |
| `02-starship.sh` | Starship prompt + Lion theme |
| `03-git.sh` | GitHub auth, git pull defaults, global gitignore |
| `04-gcp.sh` | GCP project setup, secrets discovery + loading |
| `05-rtk.sh` | RTK context optimizer hook configuration for all AI agents |
| `06-code-server.sh` | Workspace trust pre-configuration |
| `07-pencil.sh` | pencil-ready + pencil-close helpers |
| `08-hapi.sh` | HAPI runner + agent session |
| `09-shell-helpers.sh` | LazyVim, gitquick, template helpers, excalidraw |
| `10-mcp-cleanup.sh` | Periodic orphaned MCP process reaper (safety net) |

### MCP Server Lifecycle Management
Stdio-based MCP servers (likec4, stitch, signoz, playwright, pencil) can become orphans when a Claude/HAPI session restarts or crashes. Two mechanisms prevent accumulation:

1. **`mcp-wrap`** (`/usr/local/bin/mcp-wrap`) — Python wrapper that sets `PR_SET_PDEATHSIG(SIGTERM)` before `exec`'ing the real MCP server. The kernel automatically sends SIGTERM when the parent agent process dies. All stdio MCP commands in `mcp.tf` are wrapped: `command = "mcp-wrap"`, `args = ["original-cmd", ...]`. This is the primary defense.

2. **`mcp-cleanup`** (`/usr/local/bin/mcp-cleanup`) — Bash script that finds and kills MCP processes whose PPID is 1 (reparented to init = orphaned). Runs as a background watcher every 5 minutes via `09-mcp-cleanup.sh` init script, and once during workspace shutdown. This is the safety net for edge cases (grandchild processes, npx wrappers).

- HTTP-type MCP servers (context7, grep) are remote and unaffected
- VS Code extension MCP configs (Gemini) are not wrapped — VS Code manages those lifecycles
- The Coder MCP server is managed by the Coder agent itself

### RTK (Reducer ToolKit) — LLM Context Optimization
RTK automatically optimizes command output to reduce token costs across all AI agents.

**How it works:**
- **Auto-active via PreToolUse hook** — All Bash commands from Claude Code are transparently rewritten to use `rtk` prefix
- **Cross-agent support** — Shell integration via `~/.rtkrc` works for Codex, Gemini, and other agents
- **Intelligent summarization** — Recognizes and optimizes output from git, ls, tree, find, ps, docker, kubectl, npm, pip, cargo, and more
- **Token savings tracking** — Run `rtk gain` to see cumulative token reduction

**Key files:**
- `~/.claude/hooks/rtk-rewrite.sh` — PreToolUse hook script (auto-configured by init)
- `~/.claude/settings.json` — Hook registration (backed up before modification)
- `~/.claude/RTK.md` — Minimal reference documentation (reduces inline token cost)
- `~/.rtkrc` — Shell integration config for non-Claude agents

**Manual usage:**
```bash
rtk git log --oneline -20  # Explicitly wrap any command
rtk gain                    # Check token savings
```

**Installation:**
- Binary installed to `/usr/local/bin/rtk` during Docker build (multi-arch support)
- Hook configuration runs automatically via `05-rtk.sh` on workspace startup
- Requires restart of Claude Code after first init to activate hooks

### Shared Install Scripts
- `workspace-images/shared/install-python.sh` — Python apt + pip packages used by both python-dev and fullstack-dev
- Eliminates duplication: both images COPY and RUN the same script

### Pencil MCP (Design Editor)
- `pencil-ready [path]` — Opens a headless Chromium browser to code-server, activates the Pencil VS Code extension, and opens a `.pen` file. The browser session stays alive in the background to maintain the WebSocket connection that the Pencil MCP server needs. Must run before the coding agent's MCP client binds to the Pencil MCP server.
- `pencil-close` — Terminates the headless browser session started by `pencil-ready`, releasing the Pencil WebSocket connection.
- **Requires a frontend workspace image** (fullstack-dev or nextjs-dev) — these include Playwright + Chromium. The helper scripts are installed in all workspaces but will exit with an error in base-dev.
- Workspace trust is pre-disabled in code-server settings to prevent trust dialogs from blocking headless extension activation.
- PID file: `/tmp/pencil-browser.pid`, Log file: `/tmp/pencil-ready.log`
- Playwright MCP uses its own `mcp-chromium-*` browser build (separate from standard `chromium-*`). Both are installed during workspace init in fullstack/nextjs images.

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
1. Edit the relevant script in `workspace-images/base-dev/init.d/` (01-10 for base concerns)
2. For language-specific init, edit `workspace-images/{image}/` init scripts
3. Push changes to trigger automatic Docker build via GitHub Actions
4. New images automatically available in the container registry
5. Test in new workspace to verify changes

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

### Build Chain
```
base-dev → python-dev
base-dev → nextjs-dev → fullstack-dev
base-dev → cpp-dev
```

### Build Triggers
- **Path-based**: Changes to `workspace-images/{image-name}/**`, `workspace-images/shared/**`, or workflow files
- **Cascade**: Parent image builds trigger child image rebuilds via `workflow_run`
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

- **Update base tools**: Modify `base-dev/Dockerfile` or specific `init.d/*.sh` script, push to trigger build
- **Update Python packages**: Edit `workspace-images/shared/install-python.sh` (rebuilds both python-dev and fullstack-dev)
- **Add language support**: Create new image directory, copy/modify GitHub Actions workflow
- **Debug build issues**: Check GitHub Actions logs, verify GCP authentication
- **Debug init issues**: Check `/tmp/workspace-init.log` for script execution output
- **Test shell config**: Use `exec bash` or restart workspace to see prompt changes
- **Troubleshoot secrets**: Verify `CODER_GCP_PROJECT` is set and GCP authentication works
- **Monitor builds**: Watch GitHub Actions for build status and multi-arch manifest creation

This repository follows Docker best practices and Coder workspace patterns. All changes should maintain backward compatibility and follow the established initialization flow.
