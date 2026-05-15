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
| 3114  | MCP streamable_http bridge (`/mcp`)                |
| 49134 | iii bridge (WebSocket — programmatic SDK access)   |

## Features enabled

This image runs with the full agentmemory feature surface on. Set in
`docker-compose.snippet.yml`; verified flags in upstream
`rohitg00/agentmemory` source.

### Local embeddings + reranking + image embeddings (free)

| Flag | What it enables |
|---|---|
| `EMBEDDING_PROVIDER=local` | Semantic search via `all-MiniLM-L6-v2` (no API key, no network egress per call). |
| `RERANK_ENABLED=true` | Second-stage local reranker (`ms-marco-MiniLM-L-6-v2`). Big jump in result quality. |
| `AGENTMEMORY_IMAGE_EMBEDDINGS=true` | CLIP-based image embeddings for screenshots saved alongside text observations. |

Powered by `@xenova/transformers` baked into the image. Model weights
(~300 MB total) download lazily on first use into
`/data/.cache/huggingface` and survive image swaps via the named volume.

**Resource footprint on a 4-vCPU / 24-GB Oracle VM** (shared with Coder,
Headroom, OmniRoute, agentmemory, and active workspaces):

- Idle RAM: +300-500 MB resident (models held in memory).
- Recall spike: +100-200 MB transient.
- CPU: ~0% idle; ~50-100 ms on one vCPU per `memory_save` embed;
  ~1-2 s on one vCPU per `memory_recall` with reranking enabled.
- Disk: +~350 MB image (transformers + onnxruntime). One-time ~300 MB
  model download into `/data` on first MCP call after a fresh volume.

### LLM-bound phase (routed through Headroom → OmniRoute)

| Flag | What it enables |
|---|---|
| `AGENTMEMORY_AUTO_COMPRESS=true` | Each `memory_save` summarized by the LLM before indexing. |
| `CONSOLIDATION_ENABLED=true` | Periodic 4-tier pipeline: working → episodic → semantic → procedural. Also runs skill extraction (`src/skill-extract.ts`) as a free byproduct. |
| `GRAPH_EXTRACTION_ENABLED=true` | Entities + relationships extracted from each compressed observation into a knowledge graph. |
| `AGENTMEMORY_SLOTS=true` | High-importance / curated memory partitioning. Prereq for reflection. |
| `AGENTMEMORY_REFLECT=true` | Periodic LLM synthesis of cross-cutting insights across clusters of related memories. Only meaningful once memory volume builds up. |

All five share one provider config:

```yaml
ANTHROPIC_API_KEY: ${LLM_GATEWAY_API_KEY}     # same key chatd uses
ANTHROPIC_BASE_URL: https://llm.tapiavala.com  # root-mounted Headroom
ANTHROPIC_MODEL: meridian/claude-haiku-4-5
```

The Anthropic SDK posts to `${ANTHROPIC_BASE_URL}/v1/messages`. Headroom
is root-mounted on `llm.tapiavala.com`, so agentmemory's traffic flows
through the same compression → routing → metering pipeline as user-
facing chatd traffic. Haiku 4.5 is the right tier for these calls —
short fixed-shape summarize / extract / cluster-synthesize prompts —
resolved via OmniRoute's `meridian/` alias to the Claude Code SDK
(Pro/Max OAuth-backed). No new secret to provision.

### Already on by default (no config needed)

Lessons, sentinels, sketches, crystallize, facets, auto-forget,
lesson-decay sweep — visible in startup logs, configured upstream.

## Public MCP endpoint

The MCP streamable_http bridge (3114) is exposed publicly at
`https://memory.tapiavala.com/mcp` via Traefik, gated by Bearer auth.
All clients — including chatd inside workspaces — use this URL with
`Authorization: Bearer ${AGENTMEMORY_SECRET}`. One auth boundary, one
threat model. The raw REST API (3111), stream WS (3112), viewer (3113),
and iii bridge (49134) stay docker-network-only since no off-the-shelf
client speaks those shapes. Viewer is reachable from a laptop via SSH
port-forward (`ssh -L 3113:agentmemory:3113 vm`) when needed.

### Bind quirk (and why our entrypoint writes where it does)

The `@agentmemory/agentmemory` CLI's `findIiiConfig` (`src/cli.ts:172-175`
upstream) resolves the iii-engine config from `__dirname` first — i.e.
`dist/iii-config.yaml` inside the installed npm package. The bundled
default has `host: 127.0.0.1` and a file-based KV adapter, which is why
out-of-the-box installs bind localhost-only and silently ignore
`UPSTASH_REDIS_URL`. Our `docker-entrypoint.sh` writes the selected
config (`iii-config.upstash.yaml` or `iii-config.file-based.yaml`) to
*that* path at startup. Writing to `${HOME}/.agentmemory/iii-config.yaml`
or anywhere else has no effect.

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

Probed against iii source (v0.11.2 → v0.11.7-next.2 — all current releases):

- **TLS does NOT work out of the box.** iii's vendored `redis = "1.0.1"`
  is declared with features `["tokio-comp", "connection-manager"]` — no
  `tls-rustls` or `tls-native-tls`. The release binary physically cannot
  dial `rediss://`. (My earlier note that the binary was built with
  rustls was wrong: rustls symbols come from `reqwest` + `opentelemetry`,
  not from the redis crate.) Upstash is TLS-only, so this image runs
  `stunnel4` internally to bridge the gap (entrypoint listens on
  `127.0.0.1:6379` and forwards to Upstash with TLS, then rewrites
  `UPSTASH_REDIS_URL` to the plain-tcp local endpoint before iii starts).
  No host-side change required — just set `UPSTASH_REDIS_URL` to the
  `rediss://` URL from your Upstash console.
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

Every MCP client — chatd, Claude Desktop, Cursor, in-workspace CLIs —
uses the same public URL with the same Bearer token.

### Authentication

`AGENTMEMORY_SECRET` (set on the agentmemory container via host `.env`,
pulled from GCP Secret Manager) gates every REST and MCP endpoint with
`Authorization: Bearer <secret>`. Validated upstream via timing-safe
HMAC comparison (`src/auth.ts`). The bridge on 3114 forwards inbound
Authorization headers verbatim to the upstream REST calls, so the same
secret protects both transports.

Generate:

```bash
openssl rand -hex 32
```

Store in GCP Secret Manager (`coder-nt/AGENTMEMORY_SECRET`), reference
from the host `.env`, and distribute the same value to every MCP client
config that needs to call it.

### Coder Agents (chatd) — streamable_http MCP

Wired via `coder-agents-config/mcp-servers.yaml`:

```yaml
- slug: agentmemory
  transport: streamable_http
  url: https://memory.tapiavala.com/mcp
  auth_type: custom_headers
  custom_headers:
    Authorization: Bearer ${AGENTMEMORY_SECRET}
```

The `${AGENTMEMORY_SECRET}` placeholder is substituted at sync time by
`coder-agents-config/sync.sh`, reading from the workflow env populated
from GCP Secret Manager.

### Streamable-http MCP clients (any conforming client)

Point at `https://memory.tapiavala.com/mcp`, add the Bearer header.
Example for an MCP client that supports custom headers:

```json
{
  "mcpServers": {
    "agentmemory": {
      "transport": "streamable_http",
      "url": "https://memory.tapiavala.com/mcp",
      "headers": {
        "Authorization": "Bearer <AGENTMEMORY_SECRET>"
      }
    }
  }
}
```

### Stdio MCP clients (Claude Desktop, Cursor, Codex)

The upstream stdio shim (`@agentmemory/mcp`) calls the raw REST API on
port 3111, which is **not** exposed publicly (only the streamable_http
bridge on 3114 is). Two options:

1. **Switch to streamable_http** (recommended) if the client supports
   it — use the example above pointing at `https://memory.tapiavala.com/mcp`.
2. **SSH tunnel** to port 3111 if you must use the stdio shim:

   ```bash
   ssh -L 3111:agentmemory:3111 vm
   ```

   then run the shim with `AGENTMEMORY_URL=http://127.0.0.1:3111` and
   `AGENTMEMORY_SECRET=<secret>`.

Either way, every `memory_*` call should include `project` derived from
the workspace's git remote so memory is scoped per repo and survives
workspace recreate.
