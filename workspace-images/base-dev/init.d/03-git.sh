#!/usr/bin/env bash
set -eu

log() { printf '[git-init] %s\n' "$*"; }

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
