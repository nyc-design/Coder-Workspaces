#!/usr/bin/env bash
set -eu

log() { printf '[gcp-init] %s\n' "$*"; }

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
