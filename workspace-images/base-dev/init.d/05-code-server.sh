#!/usr/bin/env bash
set -eu

log() { printf '[code-server-init] %s\n' "$*"; }

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
