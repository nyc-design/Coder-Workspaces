set -e

# Fix ownership that envbuilder's chown may have failed to complete.
# envbuilder uses filepath.Walk which aborts on ENOENT if a temp file
# is deleted mid-walk. This find-based approach handles vanishing files.
for path in /home/coder /workspaces; do
  if [ -d "$path" ]; then
    sudo find "$path" -xdev -not -user coder -exec chown coder:coder {} + 2>/dev/null || true
  fi
done

# Prepare user home with default files on first start.
if [ ! -f ~/.init_done ]; then
  cp -rT /etc/skel ~
  touch ~/.init_done
fi

/usr/local/bin/init-workspace.sh >> /tmp/workspace-init.log 2>&1 || true
/usr/local/bin/run-workspace-inits >> /tmp/workspace-init.log 2>&1 || true
