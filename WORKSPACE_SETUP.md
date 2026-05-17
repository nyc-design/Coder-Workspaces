# Coder Workspace Images and Init Scripts

This repository contains Docker images and initialization scripts for Coder workspaces. It provides a standardized development environment setup with various language-specific configurations.

## Architecture Overview

### Directory Structure

```
workspace-images/
├── base-dev/                    # Base development image (foundation for all others)
│   ├── Dockerfile              # Base Docker image definition
│   └── scripts/                # Helper scripts baked into /usr/local/bin/
│       └── run-workspace-inits             # Init script runner utility
├── cpp-dev/                    # C++ development image
├── fullstack-dev/              # Full-stack development image
├── vite-dev/                   # Vite/React development image
├── playwright-dev/             # Playwright testing image
├── python-dev/                 # Python development image
└── rust-dev/                   # Rust development image

workspace-templates/            # Coder workspace template definitions
└── repo-devcontainer/         # Repository-based devcontainer template
```

### Initialization Script Flow

1. **Docker Build Time**: 
   - `workspace-images/base-dev/init-workspace.sh` is copied to `/usr/local/bin/init-workspace.sh` in the container
   - The script is made executable and ready for execution

2. **Workspace Creation Time**:
   - Coder agent automatically runs `/usr/local/bin/init-workspace.sh` when the workspace starts
   - This happens during the workspace creation/startup process, before user interaction

3. **Script Execution Order**:
   - The init script handles core setup: Docker daemon, authentication, shell configuration
   - Additional language-specific init scripts can be placed in `/usr/local/share/workspace-init.d/`
   - The `run-workspace-inits` utility executes all `.sh` files in the init directory

## Key Components

### Base Development Image (`base-dev/`)

**Features:**
- Ubuntu-based with enterprise Coder base
- Docker-in-Docker support
- Google Cloud CLI with GKE plugins
- GitHub CLI
- Node.js 20 + pnpm
- AI coding tools (@anthropic-ai/claude-code)
- Automated secrets management via GCP Secret Manager

**Init Script Responsibilities:**
- Fix `/run` and `/var/run` permissions
- Start Docker daemon and configure socket permissions
- Configure shell prompt (Starship with Lion theme)
- Set up GitHub authentication (via GH_TOKEN or GITHUB_PAT)
- Auto-discover and load GCP secrets as environment variables

### Shell Configuration (Starship Prompt)

The init script configures a custom Starship prompt with:
- Lion-themed prompt with emojis (🦁, 🌈, etc.)
- Git status indicators
- Command duration timing
- Hostname and directory display
- Custom colors and styling

## Critical Implementation Details

### Script Execution Context

**IMPORTANT**: The init script runs during workspace creation, which means:
- It executes in a non-interactive shell environment
- Changes to `.bashrc` don't affect the current execution context
- Shell prompt changes only take effect in new shell sessions
- The script cannot directly apply shell configuration to itself

### Common Issues

1. **Starship Not Applying**: The init script can install and configure Starship, but the prompt changes won't be visible until:
   - A new interactive shell is started
   - The user manually runs `exec bash` or similar
   - The workspace is restarted

2. **Environment Variables**: Changes made to shell configuration files during init only affect future shell sessions, not the current workspace session.

## Development Workflow

### Project-side: host LSPs vs. devcontainer

The workspace image is the dev environment. Each project should expose its
toolchain via a `.devcontainer/devcontainer.json` that references the
relevant `*-dev:latest` image (see `nyc-design/Project-Scaffolds` for
templates per language). The container handles compilation and runtime;
the **host workspace** (this Coder workspace) handles editor LSPs.

LSPs (basedpyright, biome, tsc) run on the host and want a local
`./.venv` / `./node_modules` alongside the source. There are no
bind-mounts from container back to host — you populate them yourself:

| After editing... | Run on the host (workspace terminal) |
|---|---|
| `pyproject.toml` | `uv sync` |
| `package.json` | `pnpm install` |
| `Cargo.toml` | `cargo fetch` (rust-analyzer reads target/) |

No `pyrightconfig.json` is needed — basedpyright auto-detects `./.venv`.
No `tsconfig` tweaks are needed — tsc and biome auto-detect
`./node_modules`. The container's `postCreateCommand` runs the same
commands inside the container; the host run is just so the editor sees
the deps.

### Making Changes to Init Scripts

1. Edit the master version in `workspace-images/base-dev/init-workspace.sh`
2. Rebuild the Docker image to copy the updated script to `/usr/local/bin/`
3. Test in a new workspace to see changes take effect

### Adding Language-Specific Setup

1. Create language-specific init scripts in respective image directories
2. Copy them to `/usr/local/share/workspace-init.d/` during Docker build
3. They will be automatically executed by `run-workspace-inits`

## Environment Variables

### Authentication
- `GH_TOKEN`: GitHub token for CLI authentication
- `GITHUB_PAT`: Alternative GitHub personal access token
- `CODER_GCP_PROJECT`: GCP project for automatic secrets discovery

### GCP Integration
When `CODER_GCP_PROJECT` is set, the init script will:
- Automatically discover all secrets in the specified GCP project
- Download secret values and make them available as environment variables
- Convert secret names to appropriate environment variable format
- Persist secrets for future shell sessions

## Troubleshooting

### Init Script Not Running
- Check that `/usr/local/bin/init-workspace.sh` exists and is executable in the container
- Verify Coder agent is configured to run init scripts on workspace startup

### Shell Configuration Not Applying
- Remember that shell configuration changes only affect new sessions
- Try starting a new terminal or running `exec bash`
- Check that configuration files like `.bashrc` were actually modified

### Starship Prompt Issues
- Verify starship is installed: `which starship`
- Check configuration exists: `cat ~/.config/starship.toml`
- Ensure `.bashrc` contains starship init: `grep starship ~/.bashrc`