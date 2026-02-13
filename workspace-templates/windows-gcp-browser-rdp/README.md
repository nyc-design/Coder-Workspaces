# Windows VM on GCP + Browser RDP (Coder Template)

This template provisions a persistent Windows VM in Google Cloud and adds a browser-based desktop app inside Coder using Remmina Web.

## What this template optimizes for

- **Native-feeling browser desktop**: `Windows Desktop (Browser)` app in Coder.
- **Persistence**:
  - Windows boot disk is persistent (`auto_delete = false`)
  - Separate persistent data disk is attached and initialized as `Data`
- **Cost control + quick resume**:
  - Workspace **start** sets VM to `RUNNING`
  - Workspace **stop** sets VM to `TERMINATED`
  - This shuts off compute billing quickly while keeping disks intact.
- **Low-cost defaults** for occasional use:
  - `e2-standard-2`
  - 50 GB boot disk
  - no extra data disk
  - no static IP reservation

## Important billing notes

When stopped, you still pay for:
- Persistent disks (boot + data)
- Static external IP (if `Reserve Static Public IP = Yes`)

You do **not** pay for VM CPU/RAM while it is `TERMINATED`.

## Security notes

- Tighten `Allowed RDP CIDRs` to your trusted IP ranges (avoid `0.0.0.0/0` in production).
- Change both passwords immediately after first successful login:
  - `Windows RDP Password`
  - `Browser Desktop Portal Password`

## Recommended Coder auto-stop setup

For fastest cost savings, set template/workspace inactivity auto-stop to something like **15–30 minutes** in Coder.

That ensures workspaces transition to stop quickly, which in turn sets VM status to `TERMINATED`.

## First connection flow

1. Create workspace from this template.
2. Open **Connection Guide** app to see current VM IP + credentials reference.
3. Open **Windows Desktop (Browser)** app.
4. Log into the browser portal:
   - Username: `coder`
   - Password: your `Browser Desktop Portal Password`
5. In Remmina, create an **RDP** connection to the VM public IP shown in the guide.
   - Username: `Windows RDP Username`
   - Password: `Windows RDP Password`

## Persistence behavior summary

- Stop/start workspace: VM power cycles, disks persist, apps/files remain.
- Rebuild workspace: VM and disks remain unless explicitly destroyed.
- Delete workspace/template resources: Terraform may delete VM/disks unless protected externally.
