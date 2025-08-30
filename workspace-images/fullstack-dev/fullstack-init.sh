#!/usr/bin/env bash
set -eu

log() { printf '[fullstack-init] %s\n' "$*"; }

log "Setting up full-stack development environment"

# Create necessary directories
log "Creating development directories"
mkdir -p /home/coder/projects/fullstack
mkdir -p /home/coder/.cache/pip
mkdir -p /home/coder/.cache/pypoetry
mkdir -p /home/coder/.cache/node
mkdir -p /home/coder/.local/share/pnpm/store
mkdir -p /home/coder/.venv
chown -R coder:coder /home/coder/projects /home/coder/.cache /home/coder/.local /home/coder/.venv

# Add full-stack development helper functions to bashrc (idempotent)
if ! grep -q "# --- Full-stack development helpers ---" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- Full-stack development helpers ---
# Helper to create a new full-stack monorepo project
create-monorepo() {
    local project_name="${1:-my-fullstack-app}"
    
    echo "Creating full-stack monorepo: $project_name"
    mkdir -p "$project_name"
    cd "$project_name"
    
    # Initialize root package.json for monorepo
    cat > package.json <<PKG_EOF
{
  "name": "$project_name",
  "version": "1.0.0",
  "private": true,
  "workspaces": [
    "frontend",
    "backend"
  ],
  "scripts": {
    "dev": "concurrently \"npm run dev:backend\" \"npm run dev:frontend\"",
    "dev:frontend": "cd frontend && npm run dev",
    "dev:backend": "cd backend && poetry run uvicorn main:app --reload --host 0.0.0.0 --port 8000",
    "build": "npm run build:frontend",
    "build:frontend": "cd frontend && npm run build",
    "test": "npm run test:frontend && npm run test:backend",
    "test:frontend": "cd frontend && npm run test",
    "test:backend": "cd backend && poetry run pytest",
    "lint": "npm run lint:frontend && npm run lint:backend",
    "lint:frontend": "cd frontend && npm run lint",
    "lint:backend": "cd backend && poetry run black . && poetry run isort . && poetry run flake8 ."
  },
  "devDependencies": {
    "concurrently": "^8.2.0"
  }
}
PKG_EOF

    # Create frontend (Next.js)
    echo "🌐 Creating Next.js frontend..."
    npx create-next-app@latest frontend \
        --typescript \
        --tailwind \
        --eslint \
        --app \
        --src-dir \
        --import-alias "@/*" \
        --no-install
    
    # Create backend (Python FastAPI)
    echo "🐍 Creating Python FastAPI backend..."
    mkdir -p backend
    cd backend
    
    # Initialize Poetry project
    poetry init --no-interaction \
        --name "$project_name-backend" \
        --description "Backend API for $project_name" \
        --dependency fastapi \
        --dependency "uvicorn[standard]" \
        --dependency sqlalchemy \
        --dependency alembic \
        --dependency pydantic \
        --dev-dependency pytest \
        --dev-dependency black \
        --dev-dependency isort \
        --dev-dependency flake8
    
    # Create basic FastAPI app
    cat > main.py <<PY_EOF
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(
    title="$project_name API",
    description="Backend API for $project_name",
    version="1.0.0"
)

# Configure CORS for frontend
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000"],  # Next.js default port
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
async def root():
    return {"message": "Hello from $project_name API!"}

@app.get("/api/health")
async def health_check():
    return {"status": "healthy", "service": "$project_name-backend"}

@app.get("/api/items")
async def get_items():
    return {
        "items": [
            {"id": 1, "name": "Item 1", "description": "First item"},
            {"id": 2, "name": "Item 2", "description": "Second item"}
        ]
    }
PY_EOF

    # Create pytest config
    cat > pytest.ini <<TEST_EOF
[tool:pytest]
testpaths = tests
python_files = test_*.py
python_classes = Test*
python_functions = test_*
addopts = -v --tb=short
TEST_EOF

    # Create basic test
    mkdir -p tests
    cat > tests/test_main.py <<TEST_PY_EOF
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)

def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert "message" in response.json()

def test_health_check():
    response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json()["status"] == "healthy"

def test_get_items():
    response = client.get("/api/items")
    assert response.status_code == 200
    assert "items" in response.json()
    assert len(response.json()["items"]) == 2
TEST_PY_EOF

    cd .. # Back to project root
    
    # Create project README
    cat > README.md <<README_EOF
# $project_name

A full-stack application with Next.js frontend and Python FastAPI backend.

## Project Structure

- \`frontend/\` - Next.js TypeScript application with Tailwind CSS
- \`backend/\` - Python FastAPI application with Poetry

## Development

### Start both services:
\`\`\`bash
npm install
npm run dev
\`\`\`

### Frontend only:
\`\`\`bash
cd frontend
npm install
npm run dev
\`\`\`

### Backend only:
\`\`\`bash
cd backend
poetry install
poetry run uvicorn main:app --reload
\`\`\`

## API Endpoints

- \`GET /\` - Root endpoint
- \`GET /api/health\` - Health check
- \`GET /api/items\` - Get items

## Frontend

Next.js app available at http://localhost:3000

## Backend

FastAPI docs available at http://localhost:8000/docs
README_EOF

    # Create .gitignore
    cat > .gitignore <<GIT_EOF
# Dependencies
node_modules/
*/node_modules/

# Next.js
frontend/.next/
frontend/out/

# Python
backend/__pycache__/
backend/.pytest_cache/
backend/venv/
backend/.venv/
*.pyc
*.pyo
*.pyd

# Environment variables
.env
.env.local
.env.development.local
.env.test.local
.env.production.local

# IDE
.vscode/
.idea/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db

# Logs
*.log
npm-debug.log*
yarn-debug.log*
yarn-error.log*
GIT_EOF

    echo "✨ Full-stack monorepo '$project_name' created successfully!"
    echo "📁 Project structure:"
    echo "   ├── frontend/     # Next.js TypeScript app"
    echo "   ├── backend/      # Python FastAPI app"
    echo "   └── package.json  # Monorepo configuration"
    echo ""
    echo "🚀 To get started:"
    echo "   1. cd $project_name"
    echo "   2. npm install              # Install frontend dependencies"
    echo "   3. cd backend && poetry install && cd .."
    echo "   4. npm run dev              # Start both services"
    echo ""
    echo "🌐 Frontend: http://localhost:3000"
    echo "🐍 Backend API: http://localhost:8000"
    echo "📚 API Docs: http://localhost:8000/docs"
}

# Helper to start development servers
dev-all() {
    if [[ -f "package.json" ]] && grep -q "workspaces" package.json; then
        echo "🚀 Starting full-stack development servers..."
        npm run dev
    else
        echo "❌ Not in a monorepo project root. Use 'create-monorepo' first."
    fi
}

# Helper to run tests across the stack
test-all() {
    if [[ -f "package.json" ]] && grep -q "workspaces" package.json; then
        echo "🧪 Running all tests..."
        npm run test
    else
        echo "❌ Not in a monorepo project root."
    fi
}

# Helper to lint all code
lint-all() {
    if [[ -f "package.json" ]] && grep -q "workspaces" package.json; then
        echo "✨ Linting all code..."
        npm run lint
    else
        echo "❌ Not in a monorepo project root."
    fi
}

# Helper to install all dependencies
install-all() {
    if [[ -f "package.json" ]] && grep -q "workspaces" package.json; then
        echo "📦 Installing all dependencies..."
        npm install
        if [[ -d "backend" ]] && [[ -f "backend/pyproject.toml" ]]; then
            cd backend && poetry install && cd ..
        fi
        echo "✅ All dependencies installed!"
    else
        echo "❌ Not in a monorepo project root."
    fi
}

# Available development tasks
fullstack-tasks() {
    echo "Available full-stack development tasks:"
    echo ""
    echo "Project creation:"
    echo "  create-monorepo [name]    - Create new full-stack monorepo"
    echo ""
    echo "Development:"
    echo "  dev-all                   - Start both frontend and backend"
    echo "  test-all                  - Run all tests"
    echo "  lint-all                  - Lint all code"
    echo "  install-all               - Install all dependencies"
    echo ""
    echo "Individual services:"
    echo "  Frontend (Next.js):"
    echo "    cd frontend && npm run dev    - Start frontend only"
    echo "    cd frontend && npm run build  - Build frontend"
    echo "    cd frontend && npm run test   - Test frontend"
    echo ""
    echo "  Backend (FastAPI):"
    echo "    cd backend && poetry run uvicorn main:app --reload"
    echo "    cd backend && poetry run pytest"
    echo "    cd backend && poetry run black . && poetry run isort ."
}

# Python environment helpers (from python-dev)
activate_python_env() {
    if [[ -f "pyproject.toml" ]] && command -v poetry >/dev/null 2>&1; then
        if poetry env info --path >/dev/null 2>&1; then
            source "$(poetry env info --path)/bin/activate" 2>/dev/null || true
        fi
    elif [[ -f "$HOME/.venv/bin/activate" ]]; then
        source "$HOME/.venv/bin/activate"
    fi
}

# Auto-activate appropriate Python environment when changing directories
cd() {
    builtin cd "$@" && activate_python_env
}

# Package manager shortcuts
alias ni='npm install'
alias nr='npm run' 
alias nd='npm run dev'
alias nb='npm run build'
alias nt='npm test'

alias pi='pnpm install'
alias pr='pnpm run'
alias pd='pnpm dev'
alias pb='pnpm build'
alias pt='pnpm test'

alias yi='yarn install'
alias yr='yarn run'
alias yd='yarn dev'
alias yb='yarn build'
alias yt='yarn test'

# Python shortcuts
alias poe='poetry'
alias poe-dev='poetry run uvicorn main:app --reload'
alias poe-test='poetry run pytest'
alias poe-lint='poetry run black . && poetry run isort . && poetry run flake8 .'

# Navigate shortcuts  
alias frontend='cd frontend'
alias backend='cd backend'
alias root='cd ..'
# ---
EOF
fi

# Set up Poetry configuration for Python projects
log "Setting up Poetry for Python development"
mkdir -p /home/coder/.cache/pypoetry
chown -R coder:coder /home/coder/.cache/pypoetry

su -c "poetry config virtualenvs.in-project true" coder 2>/dev/null || true
su -c "poetry config virtualenvs.prefer-active-python true" coder 2>/dev/null || true

# Create default virtual environment for general use
DEFAULT_VENV="/home/coder/.venv"
if [[ ! -d "$DEFAULT_VENV" ]]; then
    log "Creating default virtual environment at $DEFAULT_VENV"
    su -c "python3 -m venv $DEFAULT_VENV" coder
fi

# Configure environment variables in bashrc (idempotent)
if ! grep -q "# --- Full-stack environment ---" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- Full-stack environment ---
# Python
export PYTHONPATH="${PYTHONPATH:-}:/workspace"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PIP_USER=1

# Node.js
export NODE_ENV=development
export NEXT_TELEMETRY_DISABLED=1
export NODE_OPTIONS="--max-old-space-size=4096"
export NPM_CONFIG_UPDATE_NOTIFIER=false
export NPM_CONFIG_FUND=false

# Paths
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.npm-global/bin:$PATH"

# Auto-activate Python environment on shell start
activate_python_env
# ---
EOF
fi

# Set up default prettier config for the user
log "Setting up Prettier configuration"
cat > /home/coder/.prettierrc <<'EOF'
{
  "semi": false,
  "singleQuote": true,
  "tabWidth": 2,
  "trailingComma": "es5",
  "printWidth": 80,
  "plugins": ["prettier-plugin-tailwindcss"]
}
EOF

# Ensure ownership of all created files
chown -R coder:coder /home/coder/.bashrc /home/coder/.local /home/coder/.cache /home/coder/.venv /home/coder/.prettierrc 2>/dev/null || true

log "Full-stack development environment setup complete"
log "Use 'create-monorepo [project-name]' to create a new full-stack project"
log "Use 'fullstack-tasks' to see available development commands"