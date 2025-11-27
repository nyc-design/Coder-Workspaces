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

# --- Run modular init scripts ---
log "running workspace-init.d scripts"
if command -v run-workspace-inits >/dev/null 2>&1; then
  run-workspace-inits
else
  log "run-workspace-inits not found, skipping modular scripts"
fi

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

# --- GCP Secrets Integration ---
if [[ -n "${CODER_GCP_PROJECT:-}" ]] && command -v gcloud >/dev/null 2>&1; then
  log "configuring GCP secrets for project: ${CODER_GCP_PROJECT}"
  
  # Set the active GCP project
  gcloud config set project "${CODER_GCP_PROJECT}"
  
  # Create secrets directory
  mkdir -p /home/coder/.secrets
  chmod 700 /home/coder/.secrets
  
  # Get list of all secrets in the project
  log "discovering secrets in GCP project..."
  SECRET_LIST=$(gcloud secrets list --format="value(name)" --quiet 2>/dev/null || echo "")
  
  if [[ -n "$SECRET_LIST" ]]; then
    # Prepare bashrc section for secrets
    if ! grep -q "# --- GCP Secrets Auto-Generated ---" /home/coder/.bashrc; then
      cat >> /home/coder/.bashrc <<'EOF'

# --- GCP Secrets Auto-Generated ---
# Dynamically loaded secrets from GCP Secret Manager
EOF
    fi
    
    secret_count=0
    while IFS= read -r secret_name; do
      [[ -z "$secret_name" ]] && continue
      
      log "fetching secret: ${secret_name}"
      
      # Fetch the secret value
      if secret_value=$(gcloud secrets versions access latest --secret="${secret_name}" --quiet 2>/dev/null); then
        # Convert secret name to environment variable name
        # Smart conversion: handle various naming conventions
        env_var_name="$secret_name"
        
        # If it's already in UPPER_CASE format, keep it as is
        if [[ "$secret_name" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
          env_var_name="$secret_name"
        else
          # Convert kebab-case or lowercase to UPPER_CASE
          env_var_name=$(echo "$secret_name" | sed 's/-/_/g' | tr '[:lower:]' '[:upper:]')
        fi
        
        # Save to file for persistence
        secret_file="/home/coder/.secrets/${secret_name}"
        echo -n "$secret_value" > "$secret_file"
        chmod 600 "$secret_file"
        
        # Export for current session
        export "$env_var_name"="$secret_value"
        
        # Add to bashrc for future sessions
        echo "export ${env_var_name}=\"\$(cat /home/coder/.secrets/${secret_name} 2>/dev/null || echo '')\"" >> /home/coder/.bashrc
        
        log "configured secret: ${secret_name} -> ${env_var_name}"
        secret_count=$((secret_count + 1))
      else
        log "warning: could not fetch secret '${secret_name}' (no permissions or doesn't exist)"
      fi
    done <<< "$SECRET_LIST"
    
    # Complete the bashrc section
    echo "# --- End GCP Secrets ---" >> /home/coder/.bashrc
    
    log "GCP secrets configuration complete (configured ${secret_count} secrets)"
  else
    log "no secrets found in GCP project ${CODER_GCP_PROJECT}"
  fi
else
  if [[ -n "${CODER_GCP_PROJECT:-}" ]]; then
    log "warning: CODER_GCP_PROJECT set but gcloud not available"
  else
    log "no GCP project specified; skipping secrets setup"
  fi
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

# Hand off to CMD (e.g., coder agent)
exit 0