#!/usr/bin/env bash
set -eu

log() { printf '[python-init] %s\n' "$*"; }

log "Setting up Python development environment"

mkdir -p /home/coder/projects /home/coder/.cache/pip /home/coder/.cache/uv
chown -R coder:coder /home/coder/projects /home/coder/.cache /home/coder/.local 2>/dev/null || true

# Helpers + env exports for the user shell (idempotent)
if ! grep -q "# --- Python development helpers ---" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- Python development environment ---
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PATH="$HOME/.local/bin:$PATH"
export UV_CACHE_DIR="$HOME/.cache/uv"

# --- Python development helpers ---
# Auto-activate a project's .venv when entering its directory.
activate_python_env() {
    if [[ -f ".venv/bin/activate" ]]; then
        # shellcheck disable=SC1091
        source ".venv/bin/activate"
    fi
}

cd() {
    builtin cd "$@" && activate_python_env
}

# Initialize a uv project in the current directory.
uv-init() {
    if [[ ! -f "pyproject.toml" ]]; then
        uv init --no-readme
        echo "uv project initialized. Run 'uv add <package>' to add dependencies."
    else
        echo "pyproject.toml already exists."
    fi
}

# Install / sync project deps into a local .venv.
uv-sync() {
    if [[ -f "pyproject.toml" ]]; then
        uv sync
        activate_python_env
    else
        echo "No pyproject.toml found. Run 'uv-init' first."
    fi
}

activate_python_env
# ---
EOF
fi

chown -R coder:coder /home/coder/.bashrc 2>/dev/null || true

log "Python development environment setup complete"
