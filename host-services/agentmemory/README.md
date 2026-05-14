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

agentmemory is **internal-only**: workspaces reach it directly over the
docker network at `http://agentmemory:3111`. No Traefik labels, nothing
public on the internet — the memory store doesn't need to be reachable
from outside the host VM. The viewer (3113) is reachable from a laptop
via SSH port-forward (`ssh -L 3113:agentmemory:3113 vm`) when needed.

## Storage backend (file-based vs Upstash)

Backend is chosen at startup by the bundled `docker-entrypoint.sh` based
on the `UPSTASH_REDIS_URL` env var:

| Mode | When | Where state lives |
|---|---|---|
| **file-based** (default) | `UPSTASH_REDIS_URL` unset | `/data/state_store.db`, `/data/stream_store/`, all on the named volume |
| **Upstash Redis**        | `UPSTASH_REDIS_URL` set   | iii state + stream + cron all on Upstash; only embeddings index + viewer cache stay on `/data` |

Both `iii-config.file-based.yaml` and `iii-config.upstash.yaml` ship in the
image — flipping is a `.env` change + `docker restart agentmemory`, no
image rebuild.

### When to consider Upstash

- Memory should survive losing the named volume (multi-host, disaster recovery)
- You want to back state with a managed service rather than VM disk
- Single-user free-tier sizing fits: ~10k commands/day, 256MB. Each typical 30-min coding session burns ~215 commands → ~45 sessions/day before paid tier (multi-agent fan-out via subagents multiplies; bump to paid if you regularly hit the cap)

### Upstash setup

1. Create a Redis database in your [Upstash console](https://console.upstash.com/), pinned to the same region as the Coder VM (cross-region adds 50-200ms to every state op).
2. Copy the **TLS** connection URL — starts with `rediss://default:PASSWORD@HOST:6379`.
3. Add to GCP Secret Manager (`coder-nt/UPSTASH_REDIS_URL`), then to the host `.env`.
4. `docker restart agentmemory`. Logs show `[agentmemory] UPSTASH_REDIS_URL set — using Upstash Redis backend`.

### Verified constraints

Probed against iii v0.11.2 source:

- TLS works out of the box. The published iii binary is built with `rustls`
  (pulled in transitively by OpenTelemetry exporters even though
  `engine/Cargo.toml` doesn't advertise the redis-rs TLS feature).
- All three workers (state, stream, cron) accept exactly one config key:
  `redis_url`. No pool/timeout/db-number knobs.
- iii-stream holds a persistent SUBSCRIBE connection — counts against
  Upstash's concurrent-connection budget (>=100 on free tier; not a real cap).
- iii-cron uses `SET NX PX 30000` + `EVAL` for distributed locks.
  Hardcoded 30s lock TTL — fine for agentmemory's lightweight consolidation jobs.

### Why not Postgres / Neon?

Verified against iii-engine source: there is no Postgres adapter. iii ships
exactly three state adapters — `kv` (file/memory), `redis`, `bridge`
(forwards to remote iii). The `iii-database` worker the agentmemory README
hints at does not exist upstream.

A Postgres adapter would mean writing one in Rust against the trait
`kv.rs:195-215` implements (~6 state functions + 2 lock primitives). Even
then, embeddings would land as a base64 JSON blob in one row — no pgvector
for free.

## Volumes

| Volume             | Mount  | Always written? | Contents |
|--------------------|--------|-----------------|----------|
| `agentmemory-data` | /data  | yes             | embeddings index, viewer cache, npm CLI cache. **Plus** state_store.db + stream_store/ when in file-based mode. |

`HOME=/data` so the npm CLI's `~/.agentmemory` cache also lands here.

## Versions

Pinned in the Dockerfile via build args (override at build-time, not deploy-time):

| Build arg              | Default     | Notes |
|------------------------|-------------|-------|
| `III_VERSION`          | `v0.11.2`   | agentmemory pins to v0.11.x; v0.11.6+ requires upstream refactor |
| `AGENTMEMORY_VERSION`  | `latest`    | Floats to npm `latest`; rebuild to pick up |

## Bootstrap

Nothing to do. Container starts the iii engine + agentmemory worker on first
run. State accumulates in the volume (or Upstash) as agents call memory tools.

Optional smoke test from another container on the same network:

```bash
docker exec -it agentmemory curl -fsS http://127.0.0.1:3111/agentmemory/health
# → {"status":"ok",...}
```

## Wiring agents

Per-agent MCP config (`~/.cursor/mcp.json`, `~/.claude/mcp.json`,
`~/.codex/config.toml`, etc.) — pointed at the **internal** docker
network endpoint, since the agent runs on the same VM:

```json
{
  "mcpServers": {
    "agentmemory": {
      "command": "npx",
      "args": ["-y", "@agentmemory/mcp"],
      "env": {
        "AGENTMEMORY_URL": "http://agentmemory:3111"
      }
    }
  }
}
```

Each call to `memory_save`, `memory_smart_search`, etc. should include
`project` derived from the workspace's git remote.
