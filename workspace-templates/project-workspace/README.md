# Project Workspaces

## Modeling workspaces

`modeling-dev` extends `python-dev`. Existing repositories select it through
`.devcontainer/devcontainer.json`; the template runs whatever image that file names.
No modeling new-project scaffold exists (`nyc-design/Project-Scaffolds` has no
`scaffold/modeling` branch), so `new_project_type=modeling` is not offered.

ARM64 Blender uses the user-approved community package from
[`lfdevs/blender-linux-arm64`](https://github.com/lfdevs/blender-linux-arm64),
stable release `v5.1.0`, asset
`blender-5.1.0-git20260325.ae6d847d66fa-aarch64.tar.gz`, SHA-256
`a4927219950566af13572e72f31b5bcb8baf87190ee86a26e2572ce7fd059793`.
This is not an official Blender Foundation ARM64 Linux binary. Updates require
explicit review; no source compilation or automatic updates are configured.
The obsolete source-build workflow and `blender-build/` tooling remain removed.

Native package checks pass for background version `5.1.0`, USD support (`true`),
default-scene USDZ export and archive integrity, and CPU rendering with denoising
disabled. Denoising enabled fails with `SIGILL`. Apple Vision Pro / RealityKit
device compatibility and the full modeling image build remain untested.
See [MODELING_WORKSPACE.md](../../MODELING_WORKSPACE.md) for validation limits and integration prerequisites.

## How the workspace container is built

The workspace container runs the project's devcontainer image directly. There is
no envbuilder step: nothing is built or unpacked at start, and the image is pulled
once per host and reused until its tag moves.

Each start asks the registry for the tag's current digest and runs the image by
that digest: a digest the host already has is reused, a new one is pulled. The
same start then removes the other versions of that image from the host, except
those a running workspace still uses; they go on a later start, once that
workspace has restarted. Nothing needs to be run on the host.

On every start, in this order:

1. **Image.** Terraform reads `.devcontainer/devcontainer.json` from GitHub,
   for its `image` only. No file, or a file without an `image`, means
   `base-dev`. Any other answer from GitHub fails the build rather than starting
   on the wrong image.
2. **Container.** Docker runs that image. Its entrypoint fixes ownership of
   `/home/coder` and `/workspaces` as root, and removes Docker's `/.dockerenv`
   marker so tools that look for it keep their normal defaults (likec4
   otherwise expects a system Graphviz that the images do not ship).
3. **Clone.** Still in the entrypoint, the repository is cloned into
   `/workspaces/<project>` if that folder is empty, using your linked GitHub
   account's token (or the shared PAT). The token is not saved to disk. The
   checked-out `devcontainer.json` is then read for its environment variables
   and lifecycle commands.
4. **Agent.** The Coder agent starts and connects, with the project in place.
5. **Lifecycle commands.** `onCreateCommand`, `updateContentCommand`,
   `postCreateCommand` and `postStartCommand` run from the project folder. A
   failing command is reported and skips the rest; the workspace still starts.
6. **Init pipeline.** The image's `workspace-init.d` scripts.

Steps 5 and 6 are the agent's startup script. Its log begins with the clone's
output, which is otherwise only in the container log.

### What is read from `devcontainer.json`

| Setting | Support |
|---|---|
| `image` | Yes. Must be pullable without credentials. |
| `containerEnv`, `remoteEnv` | Yes, exported before the agent starts. `${containerWorkspaceFolder}`, `${localWorkspaceFolder}`, their `Basename` forms, `${containerEnv:NAME}` and `${localEnv:NAME}` are resolved (both from the container). A value using any other variable, or a `CODER_*` name, is skipped and reported. |
| `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, `postStartCommand` | Yes: string, array and object forms. Object entries run one after another in name order. All four run on every start, because the container is new each time. |
| `customizations.vscode` | Yes, by the init pipeline, from the checkout. |
| `build` / `dockerFile`, `features`, `dockerComposeFile` | No. Publish an image and reference it. |
| `mounts`, `runArgs`, `forwardPorts`, `postAttachCommand`, `initializeCommand` | No. |

Comments and trailing commas are fine. Problems with the file are reported at
the top of the startup log and never stop the workspace.

### Where the file is read from

The image has to be known before the container exists, so `image` alone comes
from GitHub:

- **Existing repository:** the default branch. A changed `image` takes effect
  on the next start after it reaches the default branch.
- **New project:** the `scaffold/<type>` branch of `nyc-design/Project-Scaffolds`,
  for the life of the workspace. Once the project has its own repository, create
  a workspace for that repository to have its own `image` apply.

Everything else comes from the checkout in the workspace, so an edit applies on
the next start without being pushed.

### If the clone fails

The workspace still starts: the agent connects, and the lifecycle commands and
init pipeline run in an empty project folder. Git's message is at the top of the
startup script log. Fix the cause (repository name, GitHub access) and restart;
the clone is retried while the project folder is empty.

The pieces live in [`workspace-modules/workspace-devcontainer`](../../workspace-modules/workspace-devcontainer),
with tests under its `tests/` directory.

## Features

- **Flexible Project Setup**: Choose between existing GitHub repositories or create new projects
- **Multiple Development Stacks**: Support for Python, Vite/React, C++, fullstack, and base development environments
- **Automatic Scaffolding**: Pre-configured project structures with best practices
- **GitHub Integration**: Seamless repository creation and cloning
- **GCP Secrets Integration**: Automatic configuration of secrets from Google Cloud Secret Manager
- **Docker-based Environments**: Containerized development with persistent volumes

## Template Parameters

### Project Type Selection
- **Project Type**: Choose between "Existing Repository" or "New Project"

### For Existing Repositories
1. **GitHub Repository**: Dropdown list of your GitHub repositories
2. **GCP Project (Optional)**: Select a GCP project for automatic secrets configuration

### For New Projects
1. **New Project Type**: Choose from:
   - Base Project (minimal setup)
   - Python Project (uv, ruff, pytest)
   - Vite Project (React, TypeScript, Tailwind, Biome, Vitest, Playwright)
   - C++ Project (CMake, vcpkg, testing tools)
   - Fullstack Project (Vite/React + Python FastAPI)

2. **Project Name**: Name for your new project (default: "my-new-project")
3. **Create GitHub Repository**: Option to create a new GitHub repository

## Workspace Images

The template automatically selects the appropriate Docker image based on project type:

- **base-dev**: Minimal development environment with Git, Node.js, Python, GCP CLI
- **python-dev**: Python-focused with uv, ruff, basedpyright, pytest, ipython
- **vite-dev**: Frontend development with Vite/React, TypeScript, Biome, Vitest, Playwright
- **rust-dev**: Rust development with rustup, cargo, clippy, rustfmt, rust-analyzer, cargo-binstall
- **swift-dev**: Swift development with the swift.org Linux toolchain, SwiftPM, sourcekit-lsp, swift-format, SwiftLint. Linux only — no Xcode, Apple SDKs or simulators, so iOS/visionOS app layers are authored here and built on a Mac. Selected through a repository devcontainer; there is no `swift` new-project scaffold yet.
- **cpp-dev**: C++ development with compilers, CMake, vcpkg, debugging tools
- **fullstack-dev**: Combined Python backend + Vite/React frontend environment

## Project Scaffolding

Each project type includes pre-configured scaffolds with:

### Python Projects
- `pyproject.toml` managed by `uv`
- Basic project structure with `src/` and `tests/`
- Ruff for lint + format, basedpyright for type checking, pytest for tests

### Vite Projects
- TypeScript configuration
- Tailwind CSS setup
- Biome for lint + format, Vitest for unit tests, Playwright for E2E
- Component templates and utilities

### C++ Projects
- CMake build configuration
- vcpkg package manager setup
- Testing framework integration
- Code formatting rules

### Fullstack Projects
- Monorepo structure with `frontend/` and `backend/`
- Vite/React frontend with TypeScript
- Python FastAPI backend managed by `uv`
- Coordinated development scripts

## Environment Variables

The template automatically configures:
- **Git credentials**: Using GitHub PAT or gh CLI
- **Project type**: `NEW_PROJECT_TYPE` for selective scaffold deployment
- **Project metadata**: Name, GitHub URL, GCP project
- **Development tools**: Language-specific environment variables

## Persistent Storage

Each workspace includes:
- **Home volume**: User configuration and dotfiles
- **Workspaces volume**: Project files and repositories
- **Docker-in-Docker**: For containerized development workflows

## GCP Integration

When a GCP project is selected:
- Automatic discovery and loading of secrets from Secret Manager
- Environment variables created from secret names
- Credentials configured for development tools

## GitHub Integration

### For Existing Repositories
- Automatic cloning of selected repository
- Git credentials configuration
- Branch setup and remote configuration

### For New Projects
- Optional GitHub repository creation
- Initial commit with project scaffold
- Remote origin configuration
- Branch setup (main branch)

## Usage

1. **Deploy the template** in your Coder instance
2. **Create a workspace** and select your preferences:
   - Choose existing repo or new project
   - Select appropriate development stack
   - Configure optional integrations
3. **Start coding** with a fully configured environment

## Development Workflow

### For Existing Projects
1. Select your repository from the dropdown
2. Choose optional GCP integration
3. Launch workspace with your existing codebase

### For New Projects
1. Choose your development stack
2. Name your project
3. Optionally create GitHub repository
4. Launch workspace with pre-configured scaffold

## Customization

The template supports customization through:
- **Environment variables**: Configure tools and integrations
- **Init scripts**: Project-type specific setup automation  
- **Scaffold templates**: Modify project structures in `project-scaffolds/`
- **Docker images**: Extend base images for additional tools

## Requirements

- Coder instance with Docker support
- GitHub authentication configured
- Optional: GCP service account for secrets integration
- Optional: Docker registry access for custom images