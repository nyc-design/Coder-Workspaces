# vm-ssh-gateway Template

This template runs **code-server in a Coder workspace container** and connects to your bare VM over SSH.

Use this when you want:
- Browser-only IDE (no local VS Code on Mac)
- SSH terminal to VM
- Optional remote file navigation via SSHFS mount inside code-server

## Architecture

- Coder provisions a normal container workspace.
- code-server runs in that container.
- Container uses SSH to reach your bare VM.
- Optional SSHFS mount maps remote VM path to:
  - `/workspaces/remote-vm`

This is **not** External Workspace mode.

## Template parameters

- **Workspace Image**: container image for the workspace.
  - Default is `codercom/enterprise-base:ubuntu-20250929` for a minimal gateway workspace.
- **Workspace Directory**: default folder for code-server.
- **Bare VM Host / User / SSH Port**: SSH target.
- **Remote Path**: VM path to mount via SSHFS.
- **Auto-mount Remote Files**: mount remote path at startup.
- **SSH Key Filename**: key file name from mounted secrets path `/home/coder/secrets/ssh` (default `id_ed25519`).
- **code-server Port**: local code-server port in container.

## Apps exposed in Coder

- **Code Server**: browser IDE in container.
- **SSH to VM**: terminal app runs `ssh barevm`.
- **Remote Files Shell**: terminal app opens in `/workspaces/remote-vm`.
- **Remount Remote Files**: re-runs SSHFS mount command.

## Usage

1. Import template from `workspace-templates/vm-ssh-gateway/main.tf`.
2. Create workspace:
   - choose preset **watchparty-vm** or **neil-dev**, or
   - use manual form for a new VM.
3. Open **Code Server** app.
4. Browse remote files at `/workspaces/remote-vm` (if auto-mount enabled).
5. Use **SSH to VM** app for shell access.

## SSH keys with your existing setup

This template uses your existing mounted key directory:

- host path: `/home/ubuntu/secrets/ssh`
- workspace path: `/home/coder/secrets/ssh`

Set **SSH Key Filename** to the private key file in that folder (for example `id_ed25519`).

## Manual remount helper

If mount drops, use the **Remount Remote Files** app, or run:

```bash
mkdir -p /workspaces/remote-vm
mountpoint -q /workspaces/remote-vm && (fusermount -u /workspaces/remote-vm || true)
sshfs barevm:/home/ubuntu /workspaces/remote-vm -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks
```

## Notes

- SSHFS requires FUSE support in workspace runtime. If unavailable, SSH terminal still works.
- For best security, use dedicated deploy keys and least-privilege VM user.
- Keep VM firewall restricted to Coder workspace egress where possible.
