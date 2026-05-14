# agentmemory

Persistent memory backend for AI coding agents — REST API, viewer, and iii
function bridge. Built from upstream
[`rohitg00/agentmemory`](https://github.com/rohitg00/agentmemory) (the
TypeScript engine) plus the [`iii`](https://github.com/iii-hq/iii) runtime
binary, baked into one image so deployment is a single `docker pull`.

Published to GHCR by `.github/workflows/build-agentmemory.yaml`:

```
ghcr.io/nyc-design/agentmemory:latest
ghcr.io/nyc-design/agentmemory:sha-<commit>
```

Multi-arch (`linux/amd64` + `linux/arm64`).

## Why bundle?

Upstream's `docker-compose.yml` only ships the iii engine image and assumes
you've cloned the repo and run `npm run build` so `dist/index.mjs` exists for
`iii-exec` to spawn. That works for local dev, but breaks the
"watchtower-pulls-an-image" deployment model. Bundling iii + agentmemory into
one image solves it: watchtower swaps the image, the named volume preserves
state, no host-side build step.

## Project scoping (no adapter required)

Memory is keyed by an arbitrary `project` parameter on each `memory_*` MCP
tool call. Agents derive a stable key per repo so memory survives Coder
workspace recreate. Recommended pattern:

```bash
project="$(basename $(git remote get-url origin) .git)"
# → "Coder-Workspaces"
```

System prompt instruction (or per-skill default) tells each agent to always
include this `project` arg. No Coder-Agents-side header forwarding, no
adapter container, no UUID resolution.

## Ports

| Port  | Purpose                                            |
|-------|----------------------------------------------------|
| 3111  | REST API + `/agentmemory/health`                   |
| 3112  | WebSocket stream (live observation feed)           |
| 3113  | Real-time viewer (web UI)                          |
| 49134 | iii bridge (WebSocket — programmatic SDK access)   |

Only 3111 is routed publicly via Traefik (`/agentmemory/*`). The viewer is
reachable through the same path at `/agentmemory/viewer` since agentmemory
proxies it internally.

## Volumes

| Volume             | Mount  | Contents                                       |
|--------------------|--------|------------------------------------------------|
| `agentmemory-data` | /data  | kv store, stream offsets, embeddings, history  |

`HOME=/data` so the npm CLI's `~/.agentmemory` cache also lands on the volume.

### Why volume and not external Postgres?

Verified against iii-engine source: there is no Postgres adapter. iii
ships exactly three state adapters — `kv` (file/memory), `redis`, and
`bridge` (forwards to remote iii). The `iii-database` worker the
agentmemory README hints at does not exist upstream.

**Realistic options if the named volume isn't enough:**

1. **Volume + GCS backups** (current path). Cron `docker exec ... tar` the
   volume to a GCS bucket nightly. Recovers point-in-time state.
2. **Redis adapter** (Upstash, Redis Cloud, or self-hosted). Swap the
   `iii-state`/`iii-stream`/`iii-cron` adapter stanzas in iii-config to
   `redis` and supply a connection string. Fully supported; ~10 lines
   of config. Trades local fs latency for managed-service durability.
3. **Custom Postgres adapter for iii** (Rust, against the trait
   `kv.rs:195-215` implements). Real work; agentmemory itself needs zero
   changes once it exists. Even then, embeddings would land as a base64
   JSON blob in one row — no pgvector for free.

Option 1 is what we ship; option 2 is the realistic upgrade path.

## Versions

Pinned in the Dockerfile via build args (override at build-time, not deploy-time):

| Build arg              | Default     | Notes |
|------------------------|-------------|-------|
| `III_VERSION`          | `v0.11.2`   | agentmemory pins to v0.11.x; v0.11.6+ requires upstream refactor |
| `AGENTMEMORY_VERSION`  | `latest`    | Floats to npm `latest`; rebuild to pick up |

## Bootstrap

Nothing to do. Container starts the iii engine + agentmemory worker on first
run. State accumulates in the volume as agents call memory tools.

Optional smoke test from another container on the same network:

```bash
docker exec -it agentmemory curl -fsS http://127.0.0.1:3111/agentmemory/health
# → {"status":"ok",...}
```

## Wiring agents

Per-agent MCP config (`~/.cursor/mcp.json`, `~/.claude/mcp.json`,
`~/.codex/config.toml`, etc.):

```json
{
  "mcpServers": {
    "agentmemory": {
      "command": "npx",
      "args": ["-y", "@agentmemory/mcp"],
      "env": {
        "AGENTMEMORY_URL": "https://llm.tapiavala.com/agentmemory"
      }
    }
  }
}
```

Each call to `memory_save`, `memory_smart_search`, etc. should include
`project` derived from the workspace's git remote.
