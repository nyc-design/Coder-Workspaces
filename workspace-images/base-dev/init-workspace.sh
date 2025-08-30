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
if ! grep -q "starship init bash" ~/.bashrc; then
  echo 'eval "$(starship init bash)"' >> ~/.bashrc
fi
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

# --- Project scaffold deployment ---
if [[ -n "${CODER_NEW_PROJECT:-}" ]] && [[ "${CODER_NEW_PROJECT}" == "true" ]] && [[ "${NEW_PROJECT_TYPE:-base}" == "base" ]]; then
    PROJECT_NAME="${CODER_PROJECT_NAME:-new-base-project}"
    PROJECT_DIR="/workspaces/${PROJECT_NAME}"
    
    log "Deploying base project scaffold to ${PROJECT_DIR}"
    
    # Create project directory
    mkdir -p "${PROJECT_DIR}"
    
    # Copy scaffold files
    if [[ -d "/opt/coder-scaffolds" ]] && [[ -n "$(ls -A /opt/coder-scaffolds 2>/dev/null)" ]]; then
        cp -r /opt/coder-scaffolds/. "${PROJECT_DIR}/"
        chown -R coder:coder "${PROJECT_DIR}"
        log "Base project scaffold deployed successfully"
        
        # Initialize git repository if not exists
        if [[ ! -d "${PROJECT_DIR}/.git" ]]; then
            cd "${PROJECT_DIR}"
            git init
            git add .
            git commit -m 'Initial commit with base scaffold'
            
            # Add remote origin if GitHub repo URL is provided
            if [[ -n "${CODER_GITHUB_REPO_URL:-}" ]]; then
                git remote add origin "${CODER_GITHUB_REPO_URL}"
                git branch -M main
                log "Git remote configured: ${CODER_GITHUB_REPO_URL}"
            fi
            
            log "Git repository initialized with scaffold"
        fi
    else
        log "WARNING: No scaffold directory found at /opt/coder-scaffolds or directory is empty"
        # Create a minimal scaffold
        echo "# ${PROJECT_NAME}" > "${PROJECT_DIR}/README.md"
        echo "A base development project created with Coder." >> "${PROJECT_DIR}/README.md"
        chown -R coder:coder "${PROJECT_DIR}"
        log "Created minimal README.md scaffold"
    fi
fi

# Hand off to CMD (e.g., coder agent)
exit 0