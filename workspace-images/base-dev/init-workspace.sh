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

# --- LazyVim setup (first start only) ---
if [ ! -d "$HOME/.config/nvim" ] && [ -d /opt/lazyvim-starter ]; then
  log "copying pre-installed LazyVim from image"
  mkdir -p "$HOME/.config" "$HOME/.local/share" "$HOME/.local/state"
  cp -r /opt/lazyvim-starter/config "$HOME/.config/nvim"
  cp -r /opt/lazyvim-starter/data   "$HOME/.local/share/nvim"
  [ -d /opt/lazyvim-starter/state ] && cp -r /opt/lazyvim-starter/state "$HOME/.local/state/nvim"
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
EOF

# Hand off to CMD (e.g., coder agent)
exit 0
