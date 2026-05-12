#!/usr/bin/env bash
set -eu

log() { printf '[fullstack-init] %s\n' "$*"; }

log "Setting up full-stack development environment"

# Frontend (Vite) and Python dirs are handled by the inherited 20-vite-init.sh
# and 20-python-init.sh which both run before this script. Only fullstack-only
# concerns belong here.
mkdir -p /home/coder/projects/fullstack
chown -R coder:coder /home/coder/projects/fullstack

if ! grep -q "# --- Full-stack development helpers ---" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- Full-stack development helpers ---
# Scaffold a frontend/backend monorepo: Vite/React frontend + FastAPI backend.
create-fullstack() {
    local project_name="${1:-my-fullstack-app}"

    mkdir -p "$project_name" && cd "$project_name"

    echo "Creating Vite/React frontend..."
    pnpm create vite@latest frontend --template react-ts
    (cd frontend && pnpm install)

    echo "Creating FastAPI backend..."
    mkdir -p backend && cd backend
    uv init --no-readme
    uv add fastapi 'uvicorn[standard]' sqlalchemy alembic pydantic
    uv add --dev pytest

    cat > main.py <<'PY_EOF'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/api/health")
async def health_check():
    return {"status": "healthy"}
PY_EOF

    mkdir -p tests
    cat > tests/test_main.py <<'TEST_PY_EOF'
from fastapi.testclient import TestClient
from main import app

def test_health_check():
    response = TestClient(app).get("/api/health")
    assert response.status_code == 200
    assert response.json()["status"] == "healthy"
TEST_PY_EOF

    cd ..
    echo "Fullstack project ready."
    echo "  Frontend: cd frontend && pnpm dev          (http://localhost:5173)"
    echo "  Backend:  cd backend && uv run uvicorn main:app --reload --host 0.0.0.0 --port 8000"
}
# ---
EOF
fi

chown -R coder:coder /home/coder/.bashrc 2>/dev/null || true

log "Full-stack development environment setup complete"
