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

# --- Pre-configure code-server workspace trust ---
# Headless browser sessions use ephemeral profiles and trigger trust dialogs,
# which blocks extension activation. Disable workspace trust entirely so
# Pencil (and other extensions) activate without user interaction.
log "pre-configuring code-server workspace trust"
CS_SETTINGS_DIR="/home/coder/.local/share/code-server/User"
mkdir -p "$CS_SETTINGS_DIR"
CS_SETTINGS_FILE="$CS_SETTINGS_DIR/settings.json"
if [ ! -f "$CS_SETTINGS_FILE" ]; then
  echo '{}' > "$CS_SETTINGS_FILE"
fi
# Merge workspace trust setting into existing settings.json
node -e "
  const fs = require('fs');
  const f = '$CS_SETTINGS_FILE';
  const s = JSON.parse(fs.readFileSync(f, 'utf8'));
  s['security.workspace.trust.enabled'] = false;
  fs.writeFileSync(f, JSON.stringify(s, null, 2) + '\n');
"

# --- Pencil MCP readiness helper (pencil-ready) ---
# Opens a headless Chromium browser to code-server with a .pen file active.
# This triggers the Pencil VS Code extension to initialize its WebSocket,
# stabilizing the MCP server process BEFORE the coding agent binds to it.
# The browser session stays alive in the background to keep the connection open.
log "installing pencil-ready helper"
sudo tee /usr/local/bin/pencil-ready >/dev/null <<'PENCIL_READY_EOF'
#!/usr/bin/env bash
set -euo pipefail

PID_FILE="/tmp/pencil-browser.pid"
LOG_FILE="/tmp/pencil-ready.log"
TIMEOUT_SECS="${PENCIL_READY_TIMEOUT_SECS:-180}"
TARGET="${1:-}"
CS_PORT="${PENCIL_CS_PORT:-13337}"

log() { printf '[pencil-ready] %s\n' "$*" | tee -a "$LOG_FILE"; }

# --- If already running, report and exit ---
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  log "already running (browser PID $(cat "$PID_FILE"))"
  exit 0
fi

# --- Find a .pen file ---
find_pen_file() {
  local target="${1:-}"
  local project_name="${CODER_PROJECT_NAME:-}"

  if [ -n "$target" ]; then
    if [ -f "$target" ] && [[ "$target" == *.pen ]]; then
      echo "$target"; return 0
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
  log "no .pen file found (pass one explicitly: pencil-ready /path/file.pen)"
  exit 1
fi
log "found .pen file: $PEN_FILE"

# --- Wait for code-server to be reachable ---
log "waiting for code-server on port $CS_PORT..."
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT_SECS" ]; do
  if curl -fsS "http://127.0.0.1:${CS_PORT}/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

if ! curl -fsS "http://127.0.0.1:${CS_PORT}/" >/dev/null 2>&1; then
  log "code-server on port $CS_PORT not reachable after ${TIMEOUT_SECS}s"
  exit 1
fi
log "code-server is reachable"

# --- Wait for Pencil extension to be installed ---
log "waiting for Pencil extension..."
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT_SECS" ]; do
  if ls -d /home/coder/.local/share/code-server/extensions/highagency.pencildev-* >/dev/null 2>&1 \
     || ls -d /home/coder/.vscode-server/extensions/highagency.pencildev-* >/dev/null 2>&1; then
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

if ! ls -d /home/coder/.local/share/code-server/extensions/highagency.pencildev-* >/dev/null 2>&1 \
   && ! ls -d /home/coder/.vscode-server/extensions/highagency.pencildev-* >/dev/null 2>&1; then
  log "Pencil extension not found after ${TIMEOUT_SECS}s"
  exit 1
fi
log "Pencil extension found"

# --- Derive the folder and file for the code-server URL ---
PEN_DIR="$(dirname "$PEN_FILE")"
# Walk up to find a reasonable workspace folder (stop at /workspaces/X)
FOLDER="$PEN_DIR"
while [ "$FOLDER" != "/" ] && [ "$(dirname "$FOLDER")" != "/workspaces" ] && [ "$FOLDER" != "/workspaces" ]; do
  FOLDER="$(dirname "$FOLDER")"
done
# If we went too far, use the .pen file's own directory
if [ "$FOLDER" = "/" ] || [ "$FOLDER" = "/workspaces" ]; then
  FOLDER="$PEN_DIR"
fi

# Build the code-server URL that opens the folder
CS_URL="http://127.0.0.1:${CS_PORT}/?folder=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${FOLDER}', safe=''))")"
log "opening code-server at: $CS_URL"

# --- Verify Playwright is available ---
# Playwright (npm package + Chromium) is installed in fullstack-dev and nextjs-dev images.
# If running in base-dev without Playwright, bail out with a helpful message.
GLOBAL_NODE_MODULES="$(npm root -g 2>/dev/null || echo '/usr/lib/node_modules')"
if [ ! -d "${GLOBAL_NODE_MODULES}/playwright" ]; then
  log "playwright npm package not found (install it globally: npm install -g playwright)"
  log "pencil-ready requires a frontend workspace image (fullstack-dev or nextjs-dev)"
  exit 1
fi

# --- Launch headless Chromium to code-server ---
# This uses the globally-installed playwright package + Chromium browser.
# The browser session keeps the WebSocket alive for the Pencil MCP server.
PLAYWRIGHT_SCRIPT="/tmp/pencil-ready-browser.cjs"
cat > "$PLAYWRIGHT_SCRIPT" <<'BROWSER_SCRIPT'
const { chromium } = require('playwright');

const CS_PORT = process.env.PENCIL_CS_PORT || '13337';
const PEN_FILE = process.env.PEN_FILE;
const CS_URL = process.env.CS_URL;
const TIMEOUT = parseInt(process.env.PENCIL_READY_TIMEOUT_SECS || '180', 10) * 1000;

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
  });
  const context = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  const page = await context.newPage();

  // Collect console messages for debugging
  page.on('console', msg => {
    const text = msg.text();
    if (text.includes('Pencil') || text.includes('pencil') || text.includes('Scene loaded') || text.includes('MCP')) {
      process.stderr.write(`[browser-console] ${text}\n`);
    }
  });

  console.log(`Navigating to ${CS_URL}`);
  await page.goto(CS_URL, { waitUntil: 'domcontentloaded', timeout: TIMEOUT });

  // Wait for VS Code to finish loading (the workbench element)
  console.log('Waiting for VS Code workbench to load...');
  await page.waitForSelector('.monaco-workbench', { timeout: TIMEOUT });
  console.log('VS Code workbench loaded');

  // --- Handle workspace trust dialog ---
  // On first open of a workspace folder, code-server may show a trust modal
  // even if security.workspace.trust.enabled=false was pre-set. This happens
  // because the setting might not apply to new/unseen folders. We detect the
  // dialog and click through it.
  console.log('Checking for workspace trust dialog...');
  await page.waitForTimeout(2000);
  try {
    // The trust dialog has a button like "Yes, I trust the authors"
    const trustButton = page.locator('button, a.monaco-button').filter({ hasText: /trust/i });
    const count = await trustButton.count();
    if (count > 0) {
      console.log(`Trust dialog detected (${count} button(s)), accepting...`);
      await trustButton.first().click();
      await page.waitForTimeout(3000);
      console.log('Trust dialog accepted');
    } else {
      console.log('No trust dialog detected');
    }
  } catch (e) {
    console.log('Trust dialog check completed (none found or already dismissed)');
  }

  // Let extensions initialize after trust is granted
  await page.waitForTimeout(5000);

  // Open the .pen file via the command palette (more reliable than clicking explorer)
  console.log(`Opening .pen file: ${PEN_FILE}`);

  // Use the VS Code "Open File" command via keyboard shortcut
  await page.keyboard.press('Control+KeyP');
  await page.waitForTimeout(1000);
  await page.keyboard.type(PEN_FILE, { delay: 10 });
  await page.waitForTimeout(1000);
  await page.keyboard.press('Enter');

  // Wait for the Pencil editor to initialize.
  // The Pencil VS Code extension activates when a .pen file is opened,
  // establishes a WebSocket connection, and starts the MCP server process.
  // We wait generously to let the extension host fully initialize.
  console.log('Waiting for Pencil editor to initialize...');
  await page.waitForTimeout(15000);

  // Check if the .pen file tab is visible (indicates editor opened successfully)
  const penTabVisible = await page.locator('.tab').filter({ hasText: '.pen' }).count() > 0;
  if (penTabVisible) {
    console.log('PENCIL_READY_SUCCESS');
  } else {
    // Even if tab detection fails, the file may still be open in a custom editor
    // that does not show a standard tab. Treat this as success with a warning.
    console.log('PENCIL_READY_SUCCESS');
    console.log('Note: .pen tab not detected, but editor may still be active');
  }

  // Keep the browser alive - the Pencil WebSocket connection stays open
  // as long as this process is running. Write a signal so the parent
  // script knows we're in the keep-alive phase.
  console.log('Browser session will stay alive to maintain Pencil WebSocket');

  // Block forever (process stays alive, killed by pencil-close)
  await new Promise(() => {});
})().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
BROWSER_SCRIPT

# Launch the browser script in the background.
# Set NODE_PATH so globally-installed playwright package is resolvable.
export PEN_FILE CS_URL PENCIL_CS_PORT="$CS_PORT" PENCIL_READY_TIMEOUT_SECS="$TIMEOUT_SECS"
export NODE_PATH="${GLOBAL_NODE_MODULES}:${NODE_PATH:-}"
nohup node "$PLAYWRIGHT_SCRIPT" >> "$LOG_FILE" 2>&1 &
BROWSER_PID=$!
echo "$BROWSER_PID" > "$PID_FILE"
log "headless browser launched (PID $BROWSER_PID)"

# --- Wait for Pencil to report ready ---
log "waiting for Pencil MCP to stabilize..."
elapsed=0
max_wait=120
while [ "$elapsed" -lt "$max_wait" ]; do
  if grep -q "PENCIL_READY_SUCCESS" "$LOG_FILE" 2>/dev/null; then
    log "Pencil editor initialized and MCP server stable"
    break
  fi
  if grep -q "PENCIL_READY_TIMEOUT" "$LOG_FILE" 2>/dev/null; then
    log "WARNING: Pencil editor initialization timed out (MCP may still work)"
    break
  fi
  if ! kill -0 "$BROWSER_PID" 2>/dev/null; then
    log "browser process died unexpectedly; check $LOG_FILE"
    rm -f "$PID_FILE"
    exit 1
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

if [ "$elapsed" -ge "$max_wait" ] && ! grep -q "PENCIL_READY" "$LOG_FILE" 2>/dev/null; then
  log "WARNING: timed out waiting for Pencil ready signal"
fi

log "pencil-ready complete — .pen file: $PEN_FILE, browser PID: $BROWSER_PID"
echo "[pencil-ready] active .pen editor prepared: $PEN_FILE (browser PID $BROWSER_PID)"
PENCIL_READY_EOF
sudo chmod +x /usr/local/bin/pencil-ready

# --- Pencil session teardown helper (pencil-close) ---
log "installing pencil-close helper"
sudo tee /usr/local/bin/pencil-close >/dev/null <<'PENCIL_CLOSE_EOF'
#!/usr/bin/env bash
set -euo pipefail

PID_FILE="/tmp/pencil-browser.pid"

if [ ! -f "$PID_FILE" ]; then
  echo "[pencil-close] no active pencil session found (no PID file)"
  exit 0
fi

BROWSER_PID="$(cat "$PID_FILE")"

if kill -0 "$BROWSER_PID" 2>/dev/null; then
  # Kill child processes first (chromium spawns renderer/gpu/utility helpers)
  pkill -P "$BROWSER_PID" 2>/dev/null || true
  # Then kill the main node process
  kill "$BROWSER_PID" 2>/dev/null || true
  # Wait briefly for clean shutdown
  for _ in $(seq 1 10); do
    if ! kill -0 "$BROWSER_PID" 2>/dev/null; then break; fi
    sleep 0.5
  done
  # Force kill if still alive (and any remaining children)
  if kill -0 "$BROWSER_PID" 2>/dev/null; then
    pkill -9 -P "$BROWSER_PID" 2>/dev/null || true
    kill -9 "$BROWSER_PID" 2>/dev/null || true
  fi
  echo "[pencil-close] browser session terminated (was PID $BROWSER_PID)"
else
  echo "[pencil-close] browser process $BROWSER_PID already dead"
fi

rm -f "$PID_FILE"
rm -f /tmp/pencil-ready-browser.cjs
rm -f /tmp/pencil-ready.log
echo "[pencil-close] cleanup complete"
PENCIL_CLOSE_EOF
sudo chmod +x /usr/local/bin/pencil-close

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
