#!/usr/bin/env bash
set -eu

log() { printf '[starship-init] %s\n' "$*"; }

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
