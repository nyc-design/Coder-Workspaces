# Container entrypoint prelude: runs as the image user, before the agent init
# script that main.tf appends.
#
# Docker creates a new /workspaces volume, and the parents of nested bind
# mounts such as ~/.local/share/code-server/User, owned by root. The agent runs
# cli/gitauth.OverrideVSCodeConfigs very early during boot, which does
# MkdirAll(/home/coder/.local/share/code-server/Machine); if that parent is
# still root-owned the mkdir fails and the workspace's git credentials never
# reach VS Code's git auth provider for the first session. The clone needs a
# writable /workspaces for the same reason. Doing this before the agent process
# exists leaves no window for either to lose the race.
for path in /home/coder /workspaces; do
  if [ -d "$path" ]; then
    sudo -n find "$path" -xdev -not -user coder -exec chown coder:coder {} + 2> /dev/null || true
  fi
done
