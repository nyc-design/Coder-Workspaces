# vm-ssh-gateway Template

Opens an existing VM in browser-based VS Code (code-server). Pick the
template, enter the VM's IP address, and click **code-server**: the VM's
folder is the workspace, and terminals open on the VM.

code-server runs in the Coder workspace, never on the VM. Nothing is
installed on the VM and no Coder agent runs there; it only needs `sshd` (with
the standard SFTP subsystem) and the shared public key in
`~/.ssh/authorized_keys`.

## How it works

```
browser ──► Coder ──► workspace container ── SSH / SFTP ──► VM
                      code-server, extensions,              files, shells
                      Claude Code
```

The workspace is a `base-dev` container. On every start,
[`scripts/vm-gateway.sh`](scripts/vm-gateway.sh) prepares inputs for the
image's normal init pipeline, so the editor is set up exactly as in any other
workspace, plus:

- **SSH config**: a `vm` host alias using the shared key, with connection
  multiplexing so repeated `ssh vm <command>` calls are fast.
- **SSH FS extension** (`Kelvin.vscode-sshfs`), installed through the usual
  extension manifest. The code-server app opens a workspace file whose only
  folder is `ssh://vm/<path>`, so the explorer and editor work on the VM's
  files directly.
- **Terminals**: the default integrated terminal profile is `VM`, an SSH
  session in the opened folder. A `Workspace (bash)` profile opens a shell in
  the container instead.
- **AI agents**: a prompt fragment tells Claude Code and the other agents that
  the project lives on the VM and to run commands there with
  `ssh vm '<command>'`.

This is not Coder's External Workspaces feature, which needs the Coder agent
on the VM and a Premium licence.

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| **VM IP Address** | (required) | IP or DNS name. |
| **SSH User** | `ubuntu` | `opc` on Oracle Linux images. Cannot be inferred from the key. |
| **SSH Port** | `22` | |
| **Folder to Open** | empty | Absolute path on the VM, e.g. `/home/neil/myproject`. Empty opens the SSH user's home directory, looked up on the VM at start. |

All four can be changed on an existing workspace to point it at a different
VM or folder. The presets **watchparty-vm** and **neil-dev** fill in known
VMs; add more in `local.vm_presets` in [`main.tf`](main.tf).

## SSH key

One key is used for every VM: `/home/ubuntu/secrets/ssh/id_ed25519` on the
Coder host, mounted read-only into the workspace. Its public half must be in
`~/.ssh/authorized_keys` for the SSH user on each VM. If the VM rejects the
key, the startup log prints the public key to add.

The workspace keeps its own `~/.ssh` (config and `known_hosts`) in its home
volume and rewrites `~/.ssh/config` on every start. The shared key directory
is mounted beside it at `~/secrets/ssh`, as in every workspace.

To authorise the key on a VM, print the public half from any workspace
(`cat ~/secrets/ssh/id_ed25519.pub`) and append that line to
`~/.ssh/authorized_keys` for the SSH user on the VM. On Oracle Cloud you can
also paste it into the instance's SSH keys at creation. Check it from a
normal workspace with
`ssh -o IdentitiesOnly=yes -i ~/secrets/ssh/id_ed25519 <user>@<ip> true`.

## Apps

- **code-server**: the editor, opened on the VM's folder.
- **VM Terminal**: `ssh vm` in a Coder terminal tab.
- **Terminal**: a shell in the workspace container.

## Limits of an SSH folder

The VM's files are a virtual `ssh://` folder, not a path on the workspace's
disk. Editing, saving, the explorer, and terminals work. These do not, or
only partly:

- **Quick Open (Ctrl+P) and search across files** did not find files in the
  SSH folder in testing. Use the explorer, or `grep` / `find` in the VM
  terminal.
- **Extensions that need files on local disk**: language servers, the Git
  panel, linters and formatters run in the workspace and cannot see the VM's
  files. Use `git` in the VM terminal.
- **Claude Code and other agents** run in the workspace. They reach the VM by
  running `ssh vm '...'`; their built-in file tools only see the container.
- **Ports** opened on the VM are not auto-forwarded. Use
  `ssh -L <port>:localhost:<port> vm` from the workspace when needed.

## Troubleshooting

Startup progress and errors are in the workspace's startup logs
(`[vm-gateway]` lines). From a workspace terminal:

| Check | Command |
|---|---|
| Can the workspace reach the VM? | `ssh vm true` |
| What the editor was configured with | `cat ~/vm.code-workspace` |
| SSH FS log | Output panel, **SSH FS** channel |

- **Key rejected**: add the public key printed in the startup log to the VM,
  then restart the workspace.
- **Host key changed** (VM rebuilt, or the IP was reused): run
  `ssh-keygen -R <ip>` in a workspace terminal, then reload the editor.
- **Explorer is empty**: the VM was unreachable when the editor loaded. Fix
  the connection and reload the browser tab.

## Testing

[`tests/test-vm-gateway.sh`](tests/test-vm-gateway.sh) runs the real script
and the image's init scripts between two containers (a throwaway "VM" running
only sshd, and a workspace from the real image), then drives code-server with
a headless browser: it checks the explorer, saves an edit, and runs a command
in the default terminal. It needs Docker and outbound internet.

```bash
./tests/test-vm-gateway.sh              # only this template's extension, about a minute
FULL_INITS=1 ./tests/test-vm-gateway.sh # the image's whole init pipeline
```
