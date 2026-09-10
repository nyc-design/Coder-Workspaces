# Headroom for native Coder Agents

The source of truth is this directory plus `coder-agents-config/mcp-servers.yaml`.
Deploy the single `headroom` service from `docker-compose.snippet.yml` on the host
Docker network shared by Coder and OmniRoute. The VM only pulls the published
image: it does not build images or mount source code.

## Image source and rebuild policy

**`ghcr.io/nyc-design/headroom:latest`** follows agentmemory's packaging pattern:
one derived image, one container, a proxy and a private HTTP MCP bridge. The
Dockerfile extends `ghcr.io/chopratejas/headroom:latest` and copies three small
runtime files. It does not fork, patch, reinstall, or vendor upstream Headroom.
The validated upstream baseline is Headroom 0.27.0, whose retrieval MCP server
has no native HTTP transport; `mcp-http-bridge.py` adapts its installed FastMCP
SDK to Streamable HTTP and delegates retrieval to the proxy.

`.github/workflows/build-headroom.yaml` builds and tests on native AMD64 and
ARM64 runners, publishes per-architecture digests, and merges GHCR `latest` and
`sha-<7-char-commit>` tags. It runs on relevant main-branch changes, manual
dispatch, and weekly (Monday 05:23 UTC) to pick up upstream changes. Pull requests and feature-branch manual dispatches run tests
without publishing; registry login, image pushes, and manifest/retention jobs are
restricted to `main`. Each native
job pulls upstream, tests the built image, and pins its publication build to the
same upstream digest. Tests must pass on both architectures before `latest` is
updated. Scheduled rebuilds can update a SHA tag without a source commit because
the upstream base is floating; use a registry digest for immutable deployment.
Watchtower updates the single service after publication. Roll back by selecting
a retained image digest; retention follows the agentmemory workflow and is short.

`docker-entrypoint.py` starts the upstream `headroom proxy` and bridge as child
process groups. SIGTERM/SIGINT stop both, with a 10-second cleanup deadline and
SIGKILL fallback. Any unexpected child exit (including exit code zero) stops its
sibling and exits nonzero so Compose can restart the whole unit. The Docker
healthcheck probes both proxy `/readyz` and bridge `/healthz`; a running but
unresponsive child makes the container unhealthy. Docker restart policies act on
exit, not health status, so persistent hangs require operational intervention.
The Compose stop grace period is 20 seconds.

## Compression and delegation

The LLM route remains:

```
Coder Agents → llm.tapiavala.com → Headroom :8787 → OmniRoute :20128
```

The Anthropic, OpenAI, Gemini, and Cloud Code upstream environment variables all
point to OmniRoute. Headroom forwards provider credentials; OmniRoute validates
and replaces them for upstream providers. OmniRoute's own compression stays off.

General Headroom compression is enabled. `HEADROOM_EXCLUDE_TOOLS` protects the
native chatd tools `spawn_agent`, `wait_agent`, `message_agent`, `interrupt_agent`,
`list_agents`, `list_subagent_models`, the historical `close_agent` alias, and
Headroom retrieval results. Ordinary `execute` output remains compressible.
These names come from Coder's `coderd/x/chatd/subagent.go` and
`subagent_catalog.go`; chatd uses named function tools, which the upstream
Headroom exclusion path already supports.

`HEADROOM_SMART_CRUSHER_COMPACTION=false` disables the 0.27.0 document compactor.
That path emits opaque string references whose originals are absent from its CCR
store. SmartCrusher sampling still compresses output and stores originals under
working retrieval hashes. Other compression strategies remain enabled.
Experimental tool-result interception is left off.

Use the supported `--no-optimize` CLI flag for a deliberate temporary global
bypass. Do not rely on the old `HEADROOM_DEFAULT_MODE` or `HEADROOM_OPTIMIZE`
settings: the installed proxy CLI does not read them.

## Actual retrieval in Coder Agents

The packaged MCP bridge exposes only `headroom_retrieve` over
Streamable HTTP at `http://headroom:8788/mcp`. It forwards retrieval to
`http://127.0.0.1:8787/v1/retrieve`, so it reads the same cache used by compression.
It has no local compression store and no access to workspace files.

The central MCP entry uses slug `headroom`, `enabled: true`, and
`availability: force_on`. Coder prefixes the tool as
`headroom__headroom_retrieve`. Proxy-side synthetic tool injection is disabled
with `--no-ccr-inject-tool`; only Coder's registered tool is advertised.

For `<<ccr:abc123,string,408B>>`, call the tool with `{"hash":"abc123"}`.
An optional `query` searches the original. Missing/expired hashes return a tool
error. The proxy cache is stored at `/data/ccr_store.db` on `headroom-data`; entries
retain the upstream default 30-minute TTL.

Neither port is published on the host. Traefik routes only proxy port 8787;
MCP port 8788 has no public ingress. Coder connects
from the same Docker network, so the central entry uses `auth_type: none`.
Do not expose this unauthenticated retrieval service to the public internet.
Workspace Codex/Claude CLI MCP config files do not configure native Coder Agents.

## Deployment and validation

1. Publish the derived image through **Build & Push headroom** before deployment.
2. Apply the one-service Compose snippet and recreate `headroom`. Remove the old
   `headroom-mcp` service/container from the previous deployment (for example,
   `docker compose up -d --remove-orphans headroom` with the complete host config).
   Keep the existing `headroom-data` volume.
3. Sync the central MCP entry using the existing **Update Coder Agents central
   config** workflow and its normal configuration sync.
4. Refresh the chat's MCP connections or start a new chat if an existing session
   retains its old tool inventory.

Run `bash host-services/headroom/test.sh` from the repo root. It builds the derived
image from an explicitly pulled upstream digest and tests the packaged supervisor
and adapter with a mock
model endpoint. No real model API calls are made. Set `HEADROOM_SKIP_BUILD=1`
and optionally `HEADROOM_TEST_IMAGE=<tag>` to retest an already built image.
Tests cover all ten native tool exclusions, streaming/nonstreaming reports,
ordinary `execute` compression, HTTP MCP retrieval/query/missing-hash errors,
invalid arguments, and preservation of retrieved results on the next request.
Container tests exercise the real image PID 1 and healthcheck: SIGTERM, SIGINT,
either child killed, and either HTTP process suspended. Test containers are
removed automatically; local tests do not publish images or change deployment.

Local validation covers the host's native architecture. The workflow provides
the other architecture's native tests; GHCR publication, host networking,
Watchtower, and a real Coder chat still require deployment validation.

### Recorded local result

On September 10, 2026, the native ARM64 derived image passed the full suite with
Headroom 0.27.0 and MCP SDK 1.28.0. Ordinary output shrank from 84,290 to 2,569
bytes and recovered exactly through MCP. All six lifecycle cases passed.
AMD64 execution and GitHub Actions publication were not run locally.
