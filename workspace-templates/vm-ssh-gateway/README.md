# vm-ssh-gateway Template

Opens an existing VM in browser-based VS Code (code-server), the way VS Code's
Remote-SSH does from a laptop. Pick the template, enter the VM's IP address,
and click **code-server**: the editor, its terminals, and its extensions all
run on the VM.

Nothing has to be installed on the VM beforehand and no Coder agent runs
there. The VM only needs `sshd`, `bash`, `curl`, and the shared public key in
`~/.ssh/authorized_keys`.

## How it works

```
browser ──► Coder ──► gateway container ══ SSH tunnel ══► VM
                      (Coder agent)                       (code-server)
```

Coder provisions a small gateway container from `base-dev`. On every start,
[`scripts/vm-connect.sh`](scripts/vm-connect.sh) runs in it and:

1. Configures SSH to the VM with the shared key.
2. Installs code-server on the VM, at the same version as the image.
3. Pushes the image's editor setup: settings manifests, baked theme `.vsix`
   files, and the extension manifest (installed on the VM from OpenVSX, so
   each extension gets the build for the VM's own CPU architecture).
4. Starts code-server on the VM, listening on a private unix socket.
5. Holds an SSH tunnel from `localhost:13337` in the container to that socket.

The **code-server** app points at the local end of the tunnel. A watchdog
probes it every few seconds; if code-server dies, the VM reboots, or the
connection drops, it restarts the server and reopens the tunnel on its own.

Stopping the workspace stops code-server on the VM. The install, settings,
and extensions stay there, so later starts take seconds.

This is not Coder's External Workspaces feature, which needs the Coder agent
on the VM and a Premium licence.

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| **VM IP Address** | (required) | IP or DNS name. |
| **SSH User** | `ubuntu` | `opc` on Oracle Linux images. |
| **SSH Port** | `22` | |
| **Folder to Open** | empty | Absolute path on the VM. Empty opens the last folder used on that VM, or the user's home directory the first time. |

All four can be changed on an existing workspace to point it at a different
VM. The presets **watchparty-vm** and **neil-dev** fill in known VMs; add
more in `local.vm_presets` in [`main.tf`](main.tf).

## SSH key

One key is used for every VM: `/home/ubuntu/secrets/ssh/id_ed25519` on the
Coder host, mounted read-only into the gateway. Its public half must be in
`~/.ssh/authorized_keys` for the SSH user on each VM. If the VM rejects the
key, the startup log prints the public key to add.

## Apps

- **code-server**: the editor running on the VM.
- **VM Terminal**: `ssh vm` in a Coder terminal tab.
- **Terminal**: a shell in the gateway container, for troubleshooting.

Ports opened on the VM are reachable from the editor's **Ports** panel, as in
any other workspace.

## What lands on the VM

Everything goes under `~/.coder-vm-gateway/` (code-server, its config, user
data, extensions, and logs). The one exception is code-server's own log
directory, `~/.local/share/code-server/coder-logs`. To remove it all:

```bash
rm -rf ~/.coder-vm-gateway
```

code-server runs with `--auth none`, which is safe here because it listens
only on a mode-600 unix socket in the user's home: the only way in is an SSH
session as that user.

## Differences from a normal workspace

- Extensions are installed once per VM and then updated by the editor's own
  auto-update, not by the shared extension cache. Extensions added to the
  image manifest later are installed on the next start.
- User settings are written on the first connect and then belong to the VM;
  Machine settings are rewritten from the image on every start.
- Sign-ins do not carry over. The GitHub token and the AI CLI credentials
  that workspaces get from the Coder host are deliberately not copied to the
  VM, so sign in to GitHub, Claude, and so on from the editor on each VM.
- The image's code-server patches (`06-code-server-patches.sh`) are not
  applied to the VM's copy.

## Troubleshooting

Progress and errors from each start are in the workspace's startup logs under
**Connect to VM**. From the gateway **Terminal**:

| Check | Command |
|---|---|
| Tunnel and watchdog log | `cat /tmp/vm-tunnel.log` |
| Can the gateway reach the VM? | `ssh vm true` |
| code-server log on the VM | `ssh vm tail -n 50 .coder-vm-gateway/code-server.log` |
| Extension install log | `ssh vm cat .coder-vm-gateway/extensions-install.log` |

- **Host key changed** (VM rebuilt, or the IP was reused): run
  `ssh-keygen -R <ip>` in the gateway terminal, then restart the workspace.
- **Cannot install code-server**: the VM needs outbound HTTPS to
  `code-server.dev` and `github.com`.
- **Tunnel will not open**: the VM's sshd must allow unix socket forwarding
  (`AllowStreamLocalForwarding`, on by default; needs OpenSSH 6.7+).

## Testing

[`tests/test-vm-connect.sh`](tests/test-vm-connect.sh) runs the real script
end to end between two containers: a throwaway "VM" running only sshd, and a
gateway from the workspace image. It needs Docker and outbound internet.

```bash
./tests/test-vm-connect.sh                 # one small extension, about a minute
FULL_MANIFEST=1 ./tests/test-vm-connect.sh # the image's real extension manifest
```
