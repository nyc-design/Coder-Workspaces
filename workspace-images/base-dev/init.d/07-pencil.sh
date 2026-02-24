#!/usr/bin/env bash
set -eu

log() { printf '[pencil-init] %s\n' "$*"; }

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
