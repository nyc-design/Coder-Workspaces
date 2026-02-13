#!/usr/bin/env bash
set -eu

log() { printf '[fullstack-init] %s\n' "$*"; }

log "Setting up full-stack development environment"

# Create fullstack-specific directories (Python dirs handled by python-init.sh,
# Node.js dirs handled by nextjs-init.sh — both run before this script)
log "Creating fullstack-specific directories"
mkdir -p /home/coder/projects/fullstack
chown -R coder:coder /home/coder/projects/fullstack

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
    echo "Creating Next.js frontend..."
    npx create-next-app@latest frontend \
        --typescript \
        --tailwind \
        --eslint \
        --app \
        --src-dir \
        --import-alias "@/*" \
        --no-install

    # Create backend (Python FastAPI)
    echo "Creating Python FastAPI backend..."
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

    echo "Full-stack monorepo '$project_name' created successfully!"
    echo "  frontend/     # Next.js TypeScript app"
    echo "  backend/      # Python FastAPI app"
    echo "  package.json  # Monorepo configuration"
    echo ""
    echo "To get started:"
    echo "  1. cd $project_name"
    echo "  2. npm install              # Install frontend dependencies"
    echo "  3. cd backend && poetry install && cd .."
    echo "  4. npm run dev              # Start both services"
}

# Helper to start development servers
dev-all() {
    if [[ -f "package.json" ]] && grep -q "workspaces" package.json; then
        echo "Starting full-stack development servers..."
        npm run dev
    else
        echo "Not in a monorepo project root. Use 'create-monorepo' first."
    fi
}

# Helper to run tests across the stack
test-all() {
    if [[ -f "package.json" ]] && grep -q "workspaces" package.json; then
        echo "Running all tests..."
        npm run test
    else
        echo "Not in a monorepo project root."
    fi
}

# Helper to lint all code
lint-all() {
    if [[ -f "package.json" ]] && grep -q "workspaces" package.json; then
        echo "Linting all code..."
        npm run lint
    else
        echo "Not in a monorepo project root."
    fi
}

# Helper to install all dependencies
install-all() {
    if [[ -f "package.json" ]] && grep -q "workspaces" package.json; then
        echo "Installing all dependencies..."
        npm install
        if [[ -d "backend" ]] && [[ -f "backend/pyproject.toml" ]]; then
            cd backend && poetry install && cd ..
        fi
        echo "All dependencies installed!"
    else
        echo "Not in a monorepo project root."
    fi
}

# Available development tasks
fullstack-tasks() {
    echo "Available full-stack development tasks:"
    echo ""
    echo "Project creation:"
    echo "  create-monorepo [name]    - Create new full-stack monorepo"
    echo "  create-nextjs [name]      - Create Next.js project (from nextjs-dev)"
    echo ""
    echo "Development:"
    echo "  dev-all                   - Start both frontend and backend"
    echo "  test-all                  - Run all tests"
    echo "  lint-all                  - Lint all code"
    echo "  install-all               - Install all dependencies"
    echo ""
    echo "Setup helpers (from nextjs-dev):"
    echo "  setup-storybook           - Add Storybook to current project"
    echo "  setup-testing             - Add Jest and Testing Library"
    echo "  setup-playwright          - Add Playwright for E2E testing"
    echo ""
    echo "Claude Agent Browser Automation (from nextjs-dev):"
    echo "  start-mcp-playwright      - Start MCP server for Claude agents"
    echo "  stop-mcp-playwright       - Stop MCP server"
    echo "  mcp-playwright-status     - Check MCP server status"
}

# Python shortcuts (Python aliases complement the Node.js aliases from nextjs-init.sh)
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

log "Full-stack development environment setup complete"
log "Use 'create-monorepo [project-name]' to create a new full-stack project"
log "Use 'fullstack-tasks' to see available development commands"
