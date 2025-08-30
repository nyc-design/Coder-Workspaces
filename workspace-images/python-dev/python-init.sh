#!/usr/bin/env bash
set -eu

log() { printf '[python-init] %s\n' "$*"; }

log "Setting up Python development environment"

# Configure Poetry and microservices workflow
log "Setting up Poetry for microservices workflow"

# Create Poetry cache directory
mkdir -p /home/coder/.cache/pypoetry
chown -R coder:coder /home/coder/.cache/pypoetry

# Configure Poetry settings for local venvs
su -c "poetry config virtualenvs.in-project true" coder 2>/dev/null || true
su -c "poetry config virtualenvs.prefer-active-python true" coder 2>/dev/null || true

# Create default virtual environment for general use
DEFAULT_VENV="/home/coder/.venv"
if [[ ! -d "$DEFAULT_VENV" ]]; then
    log "Creating default virtual environment at $DEFAULT_VENV"
    su -c "python3 -m venv $DEFAULT_VENV" coder
fi

# Add Poetry and microservices helper functions to bashrc (idempotent)
if ! grep -q "# --- Poetry microservices helpers ---" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- Poetry microservices helpers ---
# Auto-detect and activate Poetry venv, fallback to default venv
activate_python_env() {
    if [[ -f "pyproject.toml" ]] && command -v poetry >/dev/null 2>&1; then
        # We're in a Poetry project - activate its venv
        if poetry env info --path >/dev/null 2>&1; then
            source "$(poetry env info --path)/bin/activate" 2>/dev/null || true
        fi
    elif [[ -f "$HOME/.venv/bin/activate" ]]; then
        # Fallback to default venv
        source "$HOME/.venv/bin/activate"
    fi
}

# Helper to work on a microservice
workon() {
    if [[ -n "$1" ]]; then
        if [[ -d "services/$1" ]]; then
            cd "services/$1"
            activate_python_env
        elif [[ -d "$1" ]]; then
            cd "$1"
            activate_python_env
        else
            echo "Directory not found: $1"
        fi
    else
        echo "Usage: workon <service-name>"
        echo "Available services:"
        ls services/ 2>/dev/null || echo "No services/ directory found"
    fi
}

# Auto-activate appropriate Python environment when changing directories
cd() {
    builtin cd "$@" && activate_python_env
}

# Initialize Poetry in current directory
poetry-init() {
    if [[ ! -f "pyproject.toml" ]]; then
        poetry init --no-interaction
        echo "Poetry project initialized. Run 'poetry add <package>' to add dependencies."
    else
        echo "pyproject.toml already exists in this directory."
    fi
}

# Install Poetry project and activate venv
poetry-setup() {
    if [[ -f "pyproject.toml" ]]; then
        poetry install
        activate_python_env
        echo "Poetry project installed and environment activated."
    else
        echo "No pyproject.toml found. Run 'poetry-init' first."
    fi
}

# Activate environment on shell start
activate_python_env
# ---
EOF
fi

# Set up Jupyter configuration directory
log "Setting up Jupyter configuration"
mkdir -p /home/coder/.jupyter
chown -R coder:coder /home/coder/.jupyter

# Create a basic Jupyter config if it doesn't exist
if [[ ! -f /home/coder/.jupyter/jupyter_lab_config.py ]]; then
    cat > /home/coder/.jupyter/jupyter_lab_config.py <<'EOF'
# Jupyter Lab configuration
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.allow_origin = '*'
c.ServerApp.allow_root = True
c.ServerApp.token = ''
c.ServerApp.password = ''
EOF
    chown coder:coder /home/coder/.jupyter/jupyter_lab_config.py
fi

# Create common Python project structure directories
log "Creating Python project directories"
mkdir -p /home/coder/projects
mkdir -p /home/coder/.cache/pip
chown -R coder:coder /home/coder/projects /home/coder/.local /home/coder/.cache /home/coder/.venv

# Set up pre-commit hooks if in a git repository
if [[ -d /workspace/.git ]] && command -v pre-commit >/dev/null 2>&1; then
    log "Setting up pre-commit hooks"
    cd /workspace || true
    su -c "pre-commit install" coder 2>/dev/null || true
fi

# Configure Python environment variables in bashrc (idempotent)
if ! grep -q "PYTHONPATH" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- Python development environment ---
export PYTHONPATH="${PYTHONPATH:-}:/workspace"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PIP_USER=1
export PATH="$HOME/.local/bin:$PATH"
# ---
EOF
fi

# Ensure ownership of all created files
chown -R coder:coder /home/coder/.bashrc /home/coder/.jupyter /home/coder/.local 2>/dev/null || true

# --- Project scaffold deployment ---
if [[ -n "${CODER_NEW_PROJECT:-}" ]] && [[ "${CODER_NEW_PROJECT}" == "true" ]]; then
    PROJECT_NAME="${CODER_PROJECT_NAME:-new-python-project}"
    PROJECT_DIR="/workspaces/${PROJECT_NAME}"
    
    log "Deploying Python project scaffold to ${PROJECT_DIR}"
    
    # Create project directory
    mkdir -p "${PROJECT_DIR}"
    
    # Copy scaffold files
    if [[ -d "/opt/coder-scaffolds" ]]; then
        cp -r /opt/coder-scaffolds/* "${PROJECT_DIR}/"
        chown -R coder:coder "${PROJECT_DIR}"
        log "Python project scaffold deployed successfully"
        
        # Initialize git repository if not exists
        if [[ ! -d "${PROJECT_DIR}/.git" ]]; then
            cd "${PROJECT_DIR}"
            su -c "git init" coder
            su -c "git add ." coder
            su -c "git commit -m 'Initial commit with Python scaffold'" coder
            
            # Add remote origin if GitHub repo URL is provided
            if [[ -n "${CODER_GITHUB_REPO_URL:-}" ]]; then
                su -c "git remote add origin '${CODER_GITHUB_REPO_URL}'" coder
                su -c "git branch -M main" coder
                log "Git remote configured: ${CODER_GITHUB_REPO_URL}"
            fi
            
            log "Git repository initialized with scaffold"
        fi
    else
        log "WARNING: No scaffold directory found at /opt/coder-scaffolds"
    fi
fi

log "Python development environment setup complete"