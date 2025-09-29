#!/usr/bin/env bash
set -eu

log() { printf '[fullstack-init] %s\n' "$*"; }

log "Setting up full-stack development environment"

# Create additional directories for fullstack development (Python dirs already created by python-init.sh)
log "Creating Node.js and fullstack-specific directories"
mkdir -p /home/coder/projects/fullstack  # Specific to fullstack projects
mkdir -p /home/coder/.cache/node
mkdir -p /home/coder/.local/share/pnpm/store
chown -R coder:coder /home/coder/.cache/node /home/coder/.local/share/pnpm

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

# Next.js helper functions (from nextjs-dev)
create-nextjs() {
    local project_name="${1:-my-app}"
    local use_typescript="${2:-yes}"
    local use_tailwind="${3:-yes}"

    if [[ "$use_typescript" == "yes" ]]; then
        TYPESCRIPT_FLAG="--typescript"
    else
        TYPESCRIPT_FLAG="--javascript"
    fi

    if [[ "$use_tailwind" == "yes" ]]; then
        TAILWIND_FLAG="--tailwind"
    else
        TAILWIND_FLAG=""
    fi

    echo "Creating Next.js project: $project_name"
    echo "TypeScript: $use_typescript, Tailwind: $use_tailwind"

    npx create-next-app@latest "$project_name" \
        $TYPESCRIPT_FLAG \
        $TAILWIND_FLAG \
        --eslint \
        --app \
        --src-dir \
        --import-alias "@/*"

    if [[ -d "$project_name" ]]; then
        cd "$project_name"
        echo "✨ Project created! Installing additional dev dependencies..."

        # Add common dev dependencies
        if [[ "$use_typescript" == "yes" ]]; then
            npm install --save-dev @types/node @types/react @types/react-dom
        fi

        # Add useful packages
        npm install --save-dev \
            husky lint-staged \
            @headlessui/react @heroicons/react \
            clsx tailwind-merge \
            prettier prettier-plugin-tailwindcss

        echo "🚀 Project setup complete! Run 'npm run dev' to start development server."
    fi
}

# Helper to quickly set up Storybook
setup-storybook() {
    if [[ -f "package.json" ]]; then
        echo "Setting up Storybook..."
        npx storybook@latest init
        echo "📚 Storybook setup complete! Run 'npm run storybook' to start."
    else
        echo "❌ No package.json found. Run this command from a Next.js project root."
    fi
}

# Helper to set up testing with Jest and Testing Library
setup-testing() {
    if [[ -f "package.json" ]]; then
        echo "Setting up Jest and Testing Library..."
        npm install --save-dev \
            jest jest-environment-jsdom \
            @testing-library/react @testing-library/jest-dom \
            @testing-library/user-event

        # Create basic Jest config
        cat > jest.config.js <<'JEST_EOF'
const nextJest = require('next/jest')

const createJestConfig = nextJest({
  dir: './',
})

const customJestConfig = {
  setupFilesAfterEnv: ['<rootDir>/jest.setup.js'],
  testEnvironment: 'jest-environment-jsdom',
}

module.exports = createJestConfig(customJestConfig)
JEST_EOF

        # Create Jest setup file
        cat > jest.setup.js <<'SETUP_EOF'
import '@testing-library/jest-dom'
SETUP_EOF

        echo "🧪 Testing setup complete! Create tests in __tests__ or *.test.js files."
    else
        echo "❌ No package.json found. Run this command from a Next.js project root."
    fi
}

# Helper to set up Playwright for E2E testing
setup-playwright() {
    if [[ -f "package.json" ]]; then
        echo "Setting up Playwright for E2E testing..."

        # Install Playwright if not already installed
        if ! npm list @playwright/test >/dev/null 2>&1; then
            npm install --save-dev @playwright/test
        fi

        # Install browsers globally for workspace sharing
        export PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright-browsers
        mkdir -p $PLAYWRIGHT_BROWSERS_PATH

        # Only install browsers if they're not already installed
        if [[ ! -f "$PLAYWRIGHT_BROWSERS_PATH/chromium-*/chrome-linux/chrome" ]] 2>/dev/null; then
            echo "Installing Playwright browsers..."
            npx playwright install chromium firefox webkit
        else
            echo "Playwright browsers already installed"
        fi

        # Create basic Playwright config
        cat > playwright.config.ts <<'PW_EOF'
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: 'html',
  use: {
    baseURL: 'http://localhost:3000',
    trace: 'on-first-retry',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'firefox',
      use: { ...devices['Desktop Firefox'] },
    },
    {
      name: 'webkit',
      use: { ...devices['Desktop Safari'] },
    },
  ],
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:3000',
    reuseExistingServer: !process.env.CI,
  },
});
PW_EOF

        # Create E2E test directory and example test
        mkdir -p e2e
        cat > e2e/example.spec.ts <<'E2E_EOF'
import { test, expect } from '@playwright/test';

test('homepage has title and loads correctly', async ({ page }) => {
  await page.goto('/');

  // Expect a title "to contain" a substring.
  await expect(page).toHaveTitle(/Next.js/);
});

test('navigation works', async ({ page }) => {
  await page.goto('/');

  // Click any link and verify navigation
  // Add your specific navigation tests here
});
E2E_EOF

        echo "🎭 Playwright setup complete!"
        echo "  - Run 'npx playwright test' to run E2E tests"
        echo "  - Run 'npx playwright test --ui' for interactive mode"
        echo "  - Run 'npx playwright show-report' to view results"
    else
        echo "❌ No package.json found. Run this command from a Next.js project root."
    fi
}

# Helper to start MCP Playwright server for Claude agent browser automation
start-mcp-playwright() {
    echo "Starting MCP Playwright server for Claude agent browser automation..."

    # Check if browsers are installed
    if [[ ! -f "$PLAYWRIGHT_BROWSERS_PATH/chromium-*/chrome-linux/chrome" ]] 2>/dev/null; then
        echo "Installing Playwright browsers..."
        export PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright-browsers
        mkdir -p $PLAYWRIGHT_BROWSERS_PATH
        npx playwright install chromium firefox webkit
    else
        echo "Playwright browsers already installed"
    fi

    # Start MCP server in background
    nohup mcp-server-playwright \
        --port ${MCP_SERVER_PLAYWRIGHT_PORT:-3001} \
        --host ${MCP_SERVER_PLAYWRIGHT_HOST:-localhost} \
        --browsers-path $PLAYWRIGHT_BROWSERS_PATH \
        > /tmp/mcp-playwright.log 2>&1 &

    echo "🤖 MCP Playwright server started!"
    echo "  - Port: ${MCP_SERVER_PLAYWRIGHT_PORT:-3001}"
    echo "  - Host: ${MCP_SERVER_PLAYWRIGHT_HOST:-localhost}"
    echo "  - Log: /tmp/mcp-playwright.log"
    echo "  - Claude agents can now use browser automation"
}

# Helper to stop MCP Playwright server
stop-mcp-playwright() {
    pkill -f "mcp-server-playwright" && echo "🛑 MCP Playwright server stopped" || echo "❌ No MCP Playwright server found running"
}

# Helper to check MCP Playwright server status
mcp-playwright-status() {
    if pgrep -f "mcp-server-playwright" > /dev/null; then
        echo "✅ MCP Playwright server is running"
        echo "  - Port: ${MCP_SERVER_PLAYWRIGHT_PORT:-3001}"
        echo "  - PID: $(pgrep -f 'mcp-server-playwright')"
    else
        echo "❌ MCP Playwright server is not running"
    fi
}

# Available development tasks
fullstack-tasks() {
    echo "Available full-stack development tasks:"
    echo ""
    echo "Project creation:"
    echo "  create-monorepo [name]    - Create new full-stack monorepo"
    echo "  create-nextjs [name] [typescript] [tailwind] - Create Next.js project"
    echo ""
    echo "Development:"
    echo "  dev-all                   - Start both frontend and backend"
    echo "  test-all                  - Run all tests"
    echo "  lint-all                  - Lint all code"
    echo "  install-all               - Install all dependencies"
    echo ""
    echo "Setup helpers:"
    echo "  setup-storybook           - Add Storybook to current project"
    echo "  setup-testing             - Add Jest and Testing Library"
    echo "  setup-playwright          - Add Playwright for E2E testing"
    echo ""
    echo "Claude Agent Browser Automation:"
    echo "  start-mcp-playwright      - Start MCP server for Claude agents"
    echo "  stop-mcp-playwright       - Stop MCP server"
    echo "  mcp-playwright-status     - Check MCP server status"
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

# Note: Python environment helpers are already provided by python-init.sh

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
alias proj='cd ~/projects'

# Next.js project creation aliases (from nextjs-dev)
alias next-app='create-nextjs'
alias nx-app='create-nextjs'

# Frontend dev shortcuts
alias dev='npm run dev'
alias build='npm run build'
alias start='npm run start'

# Package management shortcuts
alias deps='npm list --depth=0'
alias outdated='npm outdated'
alias audit='npm audit'

# Tailwind utilities
alias tw-play='npx tailwindcss-cli@latest --watch'
alias tw-build='npx tailwindcss -o ./dist/output.css --watch'
# ---
EOF
fi

# Note: Poetry configuration and virtual environment setup handled by python-init.sh

# Configure Node.js and Playwright environment variables in bashrc (idempotent)
# Note: Python environment variables are already set by python-init.sh
if ! grep -q "# --- Fullstack Node.js environment ---" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- Fullstack Node.js environment ---
# Node.js
export NODE_ENV=development
export NEXT_TELEMETRY_DISABLED=1
export NODE_OPTIONS="--max-old-space-size=4096"
export NPM_CONFIG_UPDATE_NOTIFIER=false
export NPM_CONFIG_FUND=false

# Playwright browser automation (from nextjs-dev)
export PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright-browsers
export MCP_SERVER_PLAYWRIGHT_PORT=3001
export MCP_SERVER_PLAYWRIGHT_HOST=localhost

# Node.js paths
export PATH="$HOME/.npm-global/bin:$PATH"
# ---
EOF
fi

# Set up common project templates directory (from nextjs-dev)
log "Setting up project templates"
TEMPLATES_DIR="/home/coder/.local/share/nextjs-templates"
mkdir -p "$TEMPLATES_DIR"

# Create a basic component template
cat > "$TEMPLATES_DIR/component.tsx.template" <<'EOF'
import React from 'react'
import { cn } from '@/lib/utils'

interface {{ComponentName}}Props {
  className?: string
  children?: React.ReactNode
}

export const {{ComponentName}}: React.FC<{{ComponentName}}Props> = ({
  className,
  children,
  ...props
}) => {
  return (
    <div className={cn("", className)} {...props}>
      {children}
    </div>
  )
}

export default {{ComponentName}}
EOF

# Create Tailwind utilities template
cat > "$TEMPLATES_DIR/utils.ts.template" <<'EOF'
import { type ClassValue, clsx } from 'clsx'
import { twMerge } from 'tailwind-merge'

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}
EOF

# Set up default ESLint config template
cat > "$TEMPLATES_DIR/.eslintrc.json.template" <<'EOF'
{
  "extends": [
    "next/core-web-vitals",
    "prettier"
  ],
  "rules": {
    "prefer-const": "error",
    "no-var": "error"
  }
}
EOF

chown -R coder:coder "$TEMPLATES_DIR"

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

# Ensure ownership of fullstack-specific files (Python files already handled by python-init.sh)
chown -R coder:coder /home/coder/.prettierrc /home/coder/.local/share/nextjs-templates 2>/dev/null || true

log "Full-stack development environment setup complete"
log "Use 'create-monorepo [project-name]' to create a new full-stack project"
log "Use 'fullstack-tasks' to see available development commands"