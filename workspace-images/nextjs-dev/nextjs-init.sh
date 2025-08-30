#!/usr/bin/env bash
set -eu

log() { printf '[nextjs-init] %s\n' "$*"; }

log "Setting up Next.js development environment"

# Create necessary directories
log "Creating development directories"
mkdir -p /home/coder/projects
mkdir -p /home/coder/.cache/node
mkdir -p /home/coder/.local/share/pnpm/store
chown -R coder:coder /home/coder/projects /home/coder/.cache /home/coder/.local

# Add Next.js and React helper functions to bashrc (idempotent)
if ! grep -q "# --- Next.js development helpers ---" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- Next.js development helpers ---
# Helper to create a new Next.js project with common setup
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

# Helper to run common development tasks
dev-tasks() {
    echo "Available development tasks:"
    echo "  npm run dev      - Start development server"
    echo "  npm run build    - Build for production"  
    echo "  npm run start    - Start production server"
    echo "  npm run lint     - Run ESLint"
    echo "  npm run test     - Run tests (if set up)"
    echo ""
    echo "Helper commands:"
    echo "  create-nextjs [name] [typescript] [tailwind] - Create new Next.js project"
    echo "  setup-storybook  - Add Storybook to current project"
    echo "  setup-testing    - Add Jest and Testing Library"
}

# Alias for quick project creation
alias next-app='create-nextjs'
alias nx-app='create-nextjs'

# Package manager shortcuts
alias ni='npm install'
alias nid='npm install --save-dev'
alias nr='npm run'
alias ns='npm start'
alias nt='npm test'
alias nb='npm run build'
alias nd='npm run dev'

# Yarn shortcuts
alias yi='yarn install'
alias ya='yarn add'
alias yad='yarn add --dev'
alias yr='yarn run'
alias ys='yarn start'
alias yt='yarn test'
alias yb='yarn build'
alias yd='yarn dev'

# pnpm shortcuts
alias pi='pnpm install'
alias pa='pnpm add'
alias pad='pnpm add --save-dev'
alias pr='pnpm run'
alias ps='pnpm start'
alias pt='pnpm test'
alias pb='pnpm build'
alias pd='pnpm dev'
# ---
EOF
fi

# Set up common project templates directory
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

chown -R coder:coder "$TEMPLATES_DIR"

# Configure Node.js environment variables in bashrc (idempotent)
if ! grep -q "NODE_OPTIONS" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- Next.js development environment ---
export NODE_ENV=development
export NEXT_TELEMETRY_DISABLED=1
export NODE_OPTIONS="--max-old-space-size=4096"
export NPM_CONFIG_UPDATE_NOTIFIER=false
export NPM_CONFIG_FUND=false
export PATH="$HOME/.npm-global/bin:$PATH"
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

chown -R coder:coder /home/coder/.prettierrc "$TEMPLATES_DIR"

# Create useful aliases and shortcuts in bashrc (idempotent)
if ! grep -q "# --- Frontend shortcuts ---" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- Frontend shortcuts ---
# Quick project navigation
alias proj='cd ~/projects'

# Development server shortcuts
alias dev='npm run dev'
alias build='npm run build'
alias start='npm run start'

# Package management
alias deps='npm list --depth=0'
alias outdated='npm outdated'
alias audit='npm audit'

# Tailwind utilities
alias tw-play='npx tailwindcss-cli@latest --watch'
alias tw-build='npx tailwindcss -o ./dist/output.css --watch'
# ---
EOF
fi

# Ensure ownership of all created files
chown -R coder:coder /home/coder/.bashrc /home/coder/.local /home/coder/.cache /home/coder/.npm-global 2>/dev/null || true

# --- Project scaffold deployment ---
if [[ -n "${CODER_NEW_PROJECT:-}" ]] && [[ "${CODER_NEW_PROJECT}" == "true" ]]; then
    PROJECT_NAME="${CODER_PROJECT_NAME:-new-nextjs-project}"
    PROJECT_DIR="/workspaces/${PROJECT_NAME}"
    
    log "Deploying Next.js project scaffold to ${PROJECT_DIR}"
    
    # Create project directory
    mkdir -p "${PROJECT_DIR}"
    
    # Copy scaffold files
    if [[ -d "/opt/coder-scaffolds" ]]; then
        cp -r /opt/coder-scaffolds/* "${PROJECT_DIR}/"
        chown -R coder:coder "${PROJECT_DIR}"
        log "Next.js project scaffold deployed successfully"
        
        # Initialize git repository if not exists
        if [[ ! -d "${PROJECT_DIR}/.git" ]]; then
            cd "${PROJECT_DIR}"
            su -c "git init" coder
            su -c "git add ." coder
            su -c "git commit -m 'Initial commit with Next.js scaffold'" coder
            
            # Add remote origin if GitHub repo URL is provided
            if [[ -n "${CODER_GITHUB_REPO_URL:-}" ]]; then
                su -c "git remote add origin '${CODER_GITHUB_REPO_URL}'" coder
                su -c "git branch -M main" coder
                log "Git remote configured: ${CODER_GITHUB_REPO_URL}"
            fi
            
            log "Git repository initialized with scaffold"
        fi
        
        # Install dependencies
        cd "${PROJECT_DIR}"
        log "Installing Next.js project dependencies..."
        su -c "npm install" coder
        log "Dependencies installed successfully"
    else
        log "WARNING: No scaffold directory found at /opt/coder-scaffolds"
    fi
fi

log "Next.js development environment setup complete"
log "Use 'create-nextjs [project-name]' to create a new Next.js project"
log "Use 'dev-tasks' to see available development commands"