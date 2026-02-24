#!/usr/bin/env bash
set -eu

log() { printf '[shell-helpers] %s\n' "$*"; }

# --- LazyVim setup (first start only) ---
if [ ! -d "$HOME/.config/nvim" ] && [ -d /opt/lazyvim-starter/config ]; then
  log "copying LazyVim starter config from image"
  mkdir -p "$HOME/.config"
  cp -r /opt/lazyvim-starter/config "$HOME/.config/nvim"
  log "installing LazyVim plugins in background"
  nvim --headless "+Lazy! sync" +qa > /tmp/lazyvim-sync.log 2>&1 &
fi

# --- Git Helper Function ---
log "adding gitquick helper function"

# Remove any previous git helper functions we added
sed -i -e '/^# --- GitHub Helper Function ---$/,/^# --- End GitHub Helper Function ---$/d' ~/.bashrc || true
sed -i -e '/^# --- Git Helper Function ---$/,/^# --- End Git Helper Function ---$/d' ~/.bashrc || true

# Add the gitquick helper function to .bashrc
cat >> ~/.bashrc <<'EOF'

# --- Git Helper Function ---
gitquick() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: gitquick <command> [message]"
    echo "Commands:"
    echo "  push \"message\"  - git add ., git commit -m \"message\", git push"
    echo "  status          - git status"
    echo "  pull            - git pull"
    return 1
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    "push")
      if [[ $# -eq 0 ]]; then
        echo "Error: commit message required"
        echo "Usage: gitquick push \"Your commit message\""
        return 1
      fi
      local message="$*"
      echo "🔄 Adding all changes..."
      git add .
      echo "📝 Committing with message: $message"
      git commit -m "$message"
      echo "🚀 Pushing to remote..."
      git push
      ;;
    "status")
      git status
      ;;
    "pull")
      git pull
      ;;
    "update-from-main")
      echo "🔄 Fetching origin/main and merging into current branch..."
      git fetch origin && git pull --no-rebase origin main
      ;;
    "rebase-onto-main")
      echo "🔄 Fetching origin/main and rebasing current branch..."
      git fetch origin && git pull --rebase origin main
      ;;
    *)
      echo "Unknown command: $cmd"
      echo "Available commands: push, status, pull"
      return 1
      ;;
  esac
}
# --- End Git Helper Function ---
EOF

log "gitquick helper function added to ~/.bashrc"

sed -i -e '/^# --- Template Helper Functions ---$/,/^# --- End Template Helper Functions ---$/d' ~/.bashrc || true
sed -i -e '/^# --- GCP Secrets Refresh Helper ---$/,/^# --- End GCP Secrets Refresh Helper ---$/d' ~/.bashrc || true

cat >> ~/.bashrc <<'EOF'

# --- Template Helper Functions ---
pencil-template() {
  local REPO_URL="https://raw.githubusercontent.com/nyc-design/Coder-Workspaces/main/shared-assets/pencil-templates"
  if [[ $# -eq 0 ]]; then
    echo "Usage: pencil-template <filename>"
    echo "Downloads a Pencil template from the shared library into the current directory."
    echo ""
    echo "Available templates:"
    curl -s "https://api.github.com/repos/nyc-design/Coder-Workspaces/contents/shared-assets/pencil-templates" \
      | grep -Po '"name": "\K[^"]+' | grep -v '.gitkeep' || echo "  (none yet)"
    return 0
  fi
  local file="$1"
  echo "Downloading ${file}..."
  curl -fsSL "${REPO_URL}/${file}" -o "./${file}" && echo "Downloaded ${file} to $(pwd)/" || echo "Failed to download ${file}"
}

excalidraw-template() {
  local REPO_URL="https://raw.githubusercontent.com/nyc-design/Coder-Workspaces/main/shared-assets/excalidraw"
  if [[ $# -eq 0 ]]; then
    echo "Usage: excalidraw-template <filename>"
    echo "Downloads an Excalidraw template from the shared library into the current directory."
    echo ""
    echo "Available templates:"
    curl -s "https://api.github.com/repos/nyc-design/Coder-Workspaces/contents/shared-assets/excalidraw" \
      | grep -Po '"name": "\K[^"]+' | grep -v 'library.excalidrawlib' || echo "  (none yet)"
    return 0
  fi
  local file="$1"
  echo "Downloading ${file}..."
  curl -fsSL "${REPO_URL}/${file}" -o "./${file}" && echo "Downloaded ${file} to $(pwd)/" || echo "Failed to download ${file}"
}
# --- End Template Helper Functions ---

# --- GCP Secrets Refresh Helper ---
# Function shadows the script and refreshes secrets in current + future shells
gcp-refresh-secrets() {
  local script="/usr/local/bin/gcp-refresh-secrets"
  if [[ ! -x "$script" ]]; then
    echo "gcp-refresh-secrets script not found at $script"
    return 1
  fi
  # Run script with --emit: updates .bashrc (future shells) and outputs export statements
  # Stderr goes to terminal (user sees warnings), only stdout captured for eval
  local output
  output=$("$script" --emit) || {
    echo "Failed to refresh secrets."
    return 1
  }
  # Eval the export statements to load secrets into current shell
  eval "$output"
  echo "GCP secrets refreshed (current shell + future shells)."
}
# --- End GCP Secrets Refresh Helper ---

# --- LikeC4 Dev Helper ---
likec4-dev() {
  local port="${1:-4010}"
  echo "Starting LikeC4 dev server on port ${port}..."
  likec4 dev --listen 0.0.0.0 --port "$port"
}
# --- End LikeC4 Dev Helper ---

# --- Skills Helper ---
# Shortcut to install skills globally (available across all projects)
skill-add() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: skill-add <repo> [--skill <name>] [--agent <agent>]"
    echo "Installs a skill globally for all projects."
    echo ""
    echo "Examples:"
    echo "  skill-add vercel-labs/agent-skills --skill frontend-design"
    echo "  skill-add vercel-labs/agent-skills -a claude-code -a codex"
    echo ""
    echo "Use 'skills list' to see installed skills."
    echo "Use 'skills search <query>' to find skills."
    return 0
  fi
  skills add -g "$@"
}
# --- End Skills Helper ---
EOF

# --- Sync Excalidraw shared library from repo ---
log "syncing excalidraw shared library"
mkdir -p /home/coder/.excalidraw
curl -fsSL "https://raw.githubusercontent.com/nyc-design/Coder-Workspaces/main/shared-assets/excalidraw/library.excalidrawlib" \
  -o /home/coder/.excalidraw/library.excalidrawlib \
  && log "excalidraw library synced" \
  || log "failed to sync excalidraw library (non-fatal)"
