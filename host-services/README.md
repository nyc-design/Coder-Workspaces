# host-services

Docker-Compose snippets and image build context for services that run on
the bare Coder VM (not in workspaces).

## Convention

The bare VM holds **only** the assembled `docker-compose.yml` and `.env` —
everything else lives here and ships as a GHCR image. Each service gets
its own folder:

| Layout pattern         | When                                         | Folder contents                                     |
|------------------------|----------------------------------------------|-----------------------------------------------------|
| **Compose-only**       | Service uses an upstream image as-is         | `docker-compose.snippet.yml` + `README.md`          |
| **Built image**        | We bundle binaries / config into our own image | `Dockerfile` + config files + `docker-compose.snippet.yml` + `README.md` |

Built images are published to GHCR by per-service workflows in
`.github/workflows/build-<service>.yaml` — one workflow per image, never a
combined "build everything" workflow.

## Current services

| Service        | Type       | Image                                  | Purpose                                              |
|----------------|------------|----------------------------------------|------------------------------------------------------|
| `agentmemory`  | built      | `ghcr.io/nyc-design/agentmemory`       | Persistent memory backend (iii-engine + agentmemory) |
| `cliproxy`     | built      | `ghcr.io/nyc-design/cliproxy`          | Codex + Gemini OAuth proxy                           |
| `headroom`     | compose    | `ghcr.io/chopratejas/headroom`         | Local prompt compression proxy                       |
| `meridian`     | compose    | `ghcr.io/rynfar/meridian`              | Claude Pro/Max subscription proxy                    |
| `omniroute`    | compose    | `diegosouzapw/omniroute`               | Multi-provider AI gateway (incl. Kiro)               |

All services route public traffic through Traefik on
`https://llm.tapiavala.com/<service>/*` (Traefik strips the prefix). All
services opt into Watchtower auto-updates via the
`com.centurylinklabs.watchtower.enable=true` label.

## Adding a new service

1. Create `host-services/<name>/`
2. If compose-only: add `docker-compose.snippet.yml` + `README.md`
3. If we build the image: add `Dockerfile` + config files +
   `docker-compose.snippet.yml` + `README.md`, then add
   `.github/workflows/build-<name>.yaml` (copy an existing per-service
   workflow as a template)
4. Append the snippet to the host VM's `docker-compose.yml`
5. Update this README's service table
