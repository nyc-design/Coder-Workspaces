#!/usr/bin/env bash
set -eu

log() { printf '[init] %s\n' "$*"; }

# --- Fix /run perms ---
log "fixing /run and /var/run perms"
sudo mkdir -p /run /var/run
sudo chmod 755 /run || true
sudo chmod 755 /var/run || true

# --- Start dockerd ---
log "starting dockerd"
sudo nohup dockerd --host=unix:///var/run/docker.sock --storage-driver=overlay2 > /tmp/dockerd.log 2>&1 &

# Wait for the socket to appear
for i in $(seq 1 60); do
  if sudo test -S /var/run/docker.sock; then
    break
  fi
  sleep 0.5
done

if ! sudo test -S /var/run/docker.sock; then
  log "dockerd socket never appeared; tailing logs"
  sudo tail -n 200 /tmp/dockerd.log || true
  exit 1
fi

# Set socket perms
log "setting socket ownership & perms"
sudo chown coder:coder /var/run/docker.sock
sudo chmod 660         /var/run/docker.sock
[ -S /run/docker.sock ] || sudo ln -sf /var/run/docker.sock /run/docker.sock

# Add coder to docker group
sudo groupadd -f docker
sudo usermod -aG docker coder || true

# Sanity check
if ! docker info >/dev/null 2>&1; then
  log "docker info failed; tailing logs"
  sudo tail -n 200 /tmp/dockerd.log || true
  exit 1
fi
log "dockerd is ready"

# --- Starship prompt (Lion theme) ---
# Ensure .bashrc exists
touch ~/.bashrc

# Remove any previous prompt blocks we wrote
sed -i -e '/^# --- custom colored prompt ---$/,/^# -----------------------------$/d' ~/.bashrc || true
sed -i -e '/^# --- Starship prompt ---$/,/^# -----------------------------$/d' ~/.bashrc || true

# Install starship if not present
if ! command -v starship &> /dev/null; then
  curl -sS https://starship.rs/install.sh | sh -s -- -y
fi

# Create starship config directory
mkdir -p ~/.config
cat > ~/.config/starship.toml <<'EOF'
format = "$username$hostname$directory$git_branch$git_status$cmd_duration$line_break$character"

[username]
style_user = "bright-red bold"
format = "🦁[$user]($style)"

[hostname]
ssh_only = false
format = "@[$hostname](bright-green bold)"

[directory]
style = "bright-blue bold"
truncation_length = 3
format = ":[$path]($style)"

[git_branch]
format = " 🌿[$branch]($style)"
style = "bright-yellow bold"

[git_status]
format = '[$all_status$ahead_behind]($style)'
style = "bright-magenta bold"
ahead = "🏃‍♂️${count}"
behind = "🐌${count}"
up_to_date = "🌈👑"
conflicted = "⚔️"
untracked = "🔍"
stashed = "📦"
modified = "🦁"
staged = "🎯"
renamed = "🔄"
deleted = "💀"

[cmd_duration]
min_time = 500
format = " ⏱️[$duration](bright-cyan bold)"

[character]
success_symbol = "[🦁🌈➤](bright-green bold)"
error_symbol = "[😡🔥➤](bright-red bold)"
EOF

# Set starship as prompt (only add if not already present)
# Use a more robust check and add debugging
if ! grep -q "starship.*init.*bash" ~/.bashrc; then
  log "adding starship init to ~/.bashrc"
  echo 'eval "$(starship init bash)"' >> ~/.bashrc
else
  log "starship init already present in ~/.bashrc"
fi

# Verify the addition worked
if grep -q "starship.*init.*bash" ~/.bashrc; then
  log "starship init confirmed in ~/.bashrc"
else
  log "ERROR: starship init missing from ~/.bashrc, force adding..."
  echo 'eval "$(starship init bash)"' >> ~/.bashrc
fi

# Apply the starship config to current shell
eval "$(starship init bash)"

# -----------------------------

# --- GitHub auth ---
if [[ -n "${GH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  log "configuring GitHub auth via gh + GH_TOKEN"

  # Use gh CLI as the Git credential helper
  git config --global --unset-all credential.helper || true
  git config --global credential.helper '!gh auth git-credential'
  git config --global core.askPass ''

elif [[ -n "${GITHUB_PAT:-}" ]]; then
  log "configuring GitHub auth via stored GITHUB_PAT"

  umask 077
  cat > /home/coder/.git-credentials <<EOF
https://x-access-token:${GITHUB_PAT}@github.com
EOF
  chmod 600 /home/coder/.git-credentials

  git config --global --unset-all credential.helper || true
  git config --global credential.helper 'store --file=/home/coder/.git-credentials'
  git config --global core.askPass ''
else
  log "no GitHub token provided; skipping credential setup"
fi

log "configuring git defaults (pull uses merge)"
git config --global pull.rebase false || true
# optional: keep history simple when fast-forward is possible
git config --global pull.ff only || true

# Global gitignore — keeps .vscode/ and other editor dirs out of repos
log "configuring global gitignore"
cat > /home/coder/.gitignore_global <<'EOF'
.DS_Store
.idea/
*.pid
*.pid.lock
EOF
git config --global core.excludesfile /home/coder/.gitignore_global

# --- Default GCP project when none provided (no secrets) ---
if command -v gcloud >/dev/null 2>&1; then
  if [[ -z "${CODER_GCP_PROJECT:-}" ]]; then
    DEFAULT_GCP_PROJECT="coder-nt"
    log "no CODER_GCP_PROJECT specified; using default GCP project ${DEFAULT_GCP_PROJECT}"

    # Set gcloud project
    gcloud config set project "${DEFAULT_GCP_PROJECT}"

    # Make it visible to tools (Gemini, SDKs, etc.)
    export GOOGLE_CLOUD_PROJECT="${DEFAULT_GCP_PROJECT}"
    if ! grep -q "GOOGLE_CLOUD_PROJECT" /home/coder/.bashrc; then
      echo "export GOOGLE_CLOUD_PROJECT=\"${DEFAULT_GCP_PROJECT}\"" >> /home/coder/.bashrc
    fi
  fi
fi

# --- GCP Secrets Integration ---
sudo tee /usr/local/bin/gcp-refresh-secrets >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

emit_mode=false
if [ "${1:-}" = "--emit" ]; then
  emit_mode=true
  # Suppress all stderr in emit mode - only clean export statements on stdout
  exec 2>/dev/null
fi

if [ -z "${GOOGLE_CLOUD_PROJECT:-}" ]; then
  echo "GOOGLE_CLOUD_PROJECT is not set." >&2
  exit 1
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud is not available." >&2
  exit 1
fi

gcloud config set project "${GOOGLE_CLOUD_PROJECT}" >/dev/null 2>&1

secrets_dir="$HOME/.secrets"
bashrc="$HOME/.bashrc"
start_marker="# --- GCP Secrets Auto-Generated ---"
end_marker="# --- End GCP Secrets ---"

mkdir -p "$secrets_dir"
chmod 700 "$secrets_dir"

secret_list=$(gcloud secrets list --format="value(name)" --quiet 2>/dev/null || true)
if [ -z "$secret_list" ]; then
  $emit_mode || echo "No secrets found in ${GOOGLE_CLOUD_PROJECT}."
  exit 0
fi

awk -v start="$start_marker" -v end="$end_marker" '
  $0 == start { skip=1; next }
  $0 == end { skip=0; next }
  skip == 0 { print }
' "$bashrc" > "${bashrc}.tmp" && mv "${bashrc}.tmp" "$bashrc"

{
  echo "$start_marker"
  echo "# Dynamically loaded secrets from GCP Secret Manager"
} >> "$bashrc"

env_file="$secrets_dir/.env"
: > "$env_file"

while IFS= read -r secret_name; do
  [ -z "$secret_name" ] && continue

  if secret_value=$(gcloud secrets versions access latest --secret="$secret_name" --quiet 2>/dev/null); then
    if echo "$secret_name" | grep -Eq '^[A-Z][A-Z0-9_]*$'; then
      env_var_name="$secret_name"
    else
      env_var_name=$(echo "$secret_name" | sed 's/-/_/g' | tr '[:lower:]' '[:upper:]')
    fi

    secret_file="$secrets_dir/$secret_name"
    echo -n "$secret_value" > "$secret_file"
    chmod 600 "$secret_file"

    echo "export ${env_var_name}=\"\$(cat $secret_file 2>/dev/null || echo '')\"" >> "$bashrc"
    printf 'export %s=%q\n' "$env_var_name" "$secret_value" >> "$env_file"
  fi
done <<< "$secret_list"

echo "$end_marker" >> "$bashrc"

if $emit_mode; then
  cat "$env_file"
else
  echo "Refreshed GCP secrets for ${GOOGLE_CLOUD_PROJECT}."
fi
EOF

sudo chmod +x /usr/local/bin/gcp-refresh-secrets

if [[ -n "${CODER_GCP_PROJECT:-}" ]]; then
  log "configuring GCP secrets for project: ${CODER_GCP_PROJECT}"
  export GOOGLE_CLOUD_PROJECT="${CODER_GCP_PROJECT}"
  if ! grep -q "GOOGLE_CLOUD_PROJECT" /home/coder/.bashrc; then
    echo "export GOOGLE_CLOUD_PROJECT=\"${CODER_GCP_PROJECT}\"" >> /home/coder/.bashrc
  fi
  eval "$(/usr/local/bin/gcp-refresh-secrets --emit)"
else
  log "no GCP project specified; skipping secrets setup"
fi

# --- Pencil MCP readiness helper ---
log "installing pencil-ready helper"
sudo tee /usr/local/bin/pencil-ready >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TIMEOUT_SECS="${PENCIL_READY_TIMEOUT_SECS:-180}"
TARGET="${1:-}"

CODE_SERVER_BIN="/tmp/code-server/bin/code-server"
if [ ! -x "$CODE_SERVER_BIN" ]; then
  CODE_SERVER_BIN="$(command -v code-server || true)"
fi

if [ -z "$CODE_SERVER_BIN" ] || [ ! -x "$CODE_SERVER_BIN" ]; then
  echo "[pencil-ready] code-server binary not found" >&2
  exit 1
fi

find_pen_file() {
  local target="${1:-}"
  local project_name="${CODER_PROJECT_NAME:-}"

  if [ -n "$target" ]; then
    if [ -f "$target" ] && [[ "$target" == *.pen ]]; then
      echo "$target"
      return 0
    fi
    if [ -d "$target" ]; then
      find "$target" -maxdepth 6 -type f -name "*.pen" 2>/dev/null | head -1
      return 0
    fi
  fi

  if [ -n "$project_name" ] && [ -d "/workspaces/$project_name/.pencil" ]; then
    find "/workspaces/$project_name/.pencil" -maxdepth 4 -type f -name "*.pen" 2>/dev/null | head -1
    return 0
  fi

  if [ -d "$PWD/.pencil" ]; then
    find "$PWD/.pencil" -maxdepth 4 -type f -name "*.pen" 2>/dev/null | head -1
    return 0
  fi

  find /workspaces -maxdepth 6 -type f -name "*.pen" 2>/dev/null | head -1
}

PEN_FILE="$(find_pen_file "$TARGET" || true)"
if [ -z "$PEN_FILE" ]; then
  echo "[pencil-ready] no .pen file found (pass one explicitly: pencil-ready /path/file.pen)" >&2
  exit 1
fi

for _ in $(seq 1 "$TIMEOUT_SECS"); do
  has_pencil_ext="false"
  if ls -d /home/coder/.local/share/code-server/extensions/highagency.pencildev-* >/dev/null 2>&1; then
    has_pencil_ext="true"
  elif ls -d /home/coder/.vscode-server/extensions/highagency.pencildev-* >/dev/null 2>&1; then
    has_pencil_ext="true"
  fi

  if [ "$has_pencil_ext" = "true" ] \
    && curl -fsS "http://127.0.0.1:13337/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "http://127.0.0.1:13337/" >/dev/null 2>&1; then
  echo "[pencil-ready] code-server app on 127.0.0.1:13337 is not ready" >&2
  exit 1
fi

"$CODE_SERVER_BIN" --reuse-window "$PEN_FILE" >/tmp/code-server-open-pen.log 2>&1 || true
echo "[pencil-ready] active .pen editor prepared: $PEN_FILE"
EOF
sudo chmod +x /usr/local/bin/pencil-ready

# --- HAPI Runner ---
if [[ -n "${HAPI_HUB_URL:-}" && -n "${HAPI_CLI_API_TOKEN:-}" ]]; then
  log "configuring HAPI runner"
  mkdir -p /home/coder/.hapi
  # Write settings directly — hapi reads apiUrl + cliApiToken from settings.json
  if [ ! -f /home/coder/.hapi/settings.json ]; then
    echo '{}' > /home/coder/.hapi/settings.json
  fi
  # Use node to merge apiUrl and cliApiToken into existing settings
  node -e "
    const fs = require('fs');
    const f = '/home/coder/.hapi/settings.json';
    const s = JSON.parse(fs.readFileSync(f, 'utf8'));
    s.apiUrl = process.env.HAPI_HUB_URL;
    s.cliApiToken = process.env.HAPI_CLI_API_TOKEN;
    fs.writeFileSync(f, JSON.stringify(s, null, 2) + '\n');
  "
  # Set HAPI_HOSTNAME so the hub dashboard shows the workspace name
  export HAPI_HOSTNAME="${CODER_WORKSPACE_NAME:-$(hostname)}"
  nohup hapi runner start > /tmp/hapi-runner.log 2>&1 &
  log "HAPI runner started (hub: $HAPI_HUB_URL)"

  # Auto-start a HAPI session for the workspace's coding agent so it
  # appears in the hub dashboard immediately (like agentapi does for Coder).
  HAPI_PROJECT_DIR="${ARG_WORKDIR:-$PWD}"
  HAPI_AGENT_CMD="${HAPI_AGENT:-claude}"
  if [[ -n "$HAPI_PROJECT_DIR" && "$HAPI_PROJECT_DIR" != "/" ]]; then
    (
      # Wait for runner to register with the hub
      sleep 5
      log "starting HAPI $HAPI_AGENT_CMD session in $HAPI_PROJECT_DIR"
      cd "$HAPI_PROJECT_DIR"
      # Launch hapi with the agent subcommand; --started-by runner makes
      # the session show up as remotely-managed in the hub dashboard.
      # --yolo bypasses permission prompts (matches Coder workspace config).
      nohup hapi "$HAPI_AGENT_CMD" \
        --hapi-starting-mode remote \
        --started-by runner \
        --yolo \
        > /tmp/hapi-session.log 2>&1 &
      log "HAPI $HAPI_AGENT_CMD session started (pid $!)"
    ) &
  fi
fi

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

# Hand off to CMD (e.g., coder agent)
exit 0
