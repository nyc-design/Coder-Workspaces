# Headroom for native Coder Agents

The source of truth is this directory plus `coder-agents-config/mcp-servers.yaml`.
Deploy both services from `docker-compose.snippet.yml` on the host Docker network
shared by Coder and OmniRoute. The VM does not build an image or mount source code.

## Image source

Both services pull the **unmodified upstream image** from
[`ghcr.io/chopratejas/headroom`](https://github.com/chopratejas/headroom), pinned to
its multi-architecture digest:

```
sha256:50b85d8e320cfcdf1b38919bb7ae067b93ff7a8de0a93f05b2c1246370200d1c
```

This image contains Headroom 0.27.0 and MCP SDK 1.28.0 for AMD64 and ARM64. There is
no local `headroom-coder` image, source patch, custom Dockerfile, or separate image
publication workflow in this setup. The MCP service's Compose command adapts the
installed MCP SDK to HTTP; it does not install packages or modify the image.
Watchtower is off for these digest-pinned services. Review and test a digest bump
before deployment. If an upstream modification becomes necessary, add a GHCR
build workflow in this repo following `build-cliproxy.yaml` rather than deploying
a VM-only image.

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

The separate `headroom-mcp` service exposes only `headroom_retrieve` over
Streamable HTTP at `http://headroom-mcp:8788/mcp`. It forwards retrieval to
`http://headroom:8787/v1/retrieve`, so it reads the same cache used by compression.
It has no local compression store and no access to workspace files.

The central MCP entry uses slug `headroom`, `enabled: true`, and
`availability: force_on`. Coder prefixes the tool as
`headroom__headroom_retrieve`. Proxy-side synthetic tool injection is disabled
with `--no-ccr-inject-tool`; only Coder's registered tool is advertised.

For `<<ccr:abc123,string,408B>>`, call the tool with `{"hash":"abc123"}`.
An optional `query` searches the original. Missing/expired hashes return a tool
error. The proxy cache is stored at `/data/ccr_store.db` on `headroom-data`; entries
retain the upstream default 30-minute TTL.

The MCP service publishes no host port and has no Traefik route. Coder connects
from the same Docker network, so the central entry uses `auth_type: none`.
Do not expose this unauthenticated retrieval service to the public internet.
Workspace Codex/Claude CLI MCP config files do not configure native Coder Agents.

## Deployment and validation

1. Apply the host Compose snippet and start `headroom` and `headroom-mcp`.
2. Sync the central MCP entry using the existing **Update Coder Agents central
   config** workflow. Manual dispatch with `scope=headroom` applies only this
   server; it does not change providers, models, prompts, or other MCP servers.
3. Refresh the chat's MCP connections or start a new chat if an existing session
   retains its old tool inventory.

Run `bash host-services/headroom/test.sh` from the repo root. It pulls the pinned
upstream image and tests the actual Compose HTTP adapter with a mock model
endpoint. No model API calls are made. The tests cover native tool exclusions,
streaming/nonstreaming reports, ordinary `execute` compression, complete HTTP MCP
retrieval, and preservation of the retrieved result on the next model request.
