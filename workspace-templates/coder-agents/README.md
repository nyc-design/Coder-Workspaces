# Repository Dev Container Template

This Coder workspace template creates development environments with project scaffolding and GitHub integration.

## Features

- **Flexible Project Setup**: Choose between existing GitHub repositories or create new projects
- **Multiple Development Stacks**: Support for Python, Next.js, C++, fullstack, and base development environments
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
   - Python Project (Poetry, pytest, Jupyter)
   - Next.js Project (TypeScript, Tailwind CSS, ESLint)
   - C++ Project (CMake, vcpkg, testing tools)
   - Fullstack Project (Next.js + Python FastAPI)

2. **Project Name**: Name for your new project (default: "my-new-project")
3. **Create GitHub Repository**: Option to create a new GitHub repository

## Workspace Images

The template automatically selects the appropriate Docker image based on project type:

- **base-dev**: Minimal development environment with Git, Node.js, Python, GCP CLI
- **python-dev**: Python-focused with Poetry, Jupyter, testing tools, linters
- **nextjs-dev**: Frontend development with Next.js, TypeScript, build tools
- **cpp-dev**: C++ development with compilers, CMake, vcpkg, debugging tools
- **fullstack-dev**: Combined Python backend + Next.js frontend environment

## Project Scaffolding

Each project type includes pre-configured scaffolds with:

### Python Projects
- `pyproject.toml` with Poetry configuration
- Basic project structure with `src/` and `tests/`
- Pre-commit hooks setup
- Jupyter notebook configuration

### Next.js Projects
- TypeScript configuration
- Tailwind CSS setup
- ESLint and Prettier configuration
- Component templates and utilities

### C++ Projects
- CMake build configuration
- vcpkg package manager setup
- Testing framework integration
- Code formatting rules

### Fullstack Projects
- Monorepo structure with `frontend/` and `backend/`
- Next.js frontend with TypeScript
- Python FastAPI backend with Poetry
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