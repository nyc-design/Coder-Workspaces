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

## Topology

The LLM stack has one publicly-routed entrypoint and three layers behind it:

```
client / Coder Agents / workspace CLIs
         │
         ▼
    Traefik :443
   /headroom/*     ← single public entry for all LLM traffic
         │
         ▼
   headroom :8787  ← centralized compression layer (Headroom)
         │
         ▼
  omniroute :20128 ← centralized provider router (OmniRoute)
         │
         ├─► meridian :3456    (Claude Pro/Max subscription)
         ├─► cliproxy :8317    (Codex + Gemini subscriptions)
         ├─► Kiro adapter      (built-in to OmniRoute)
         └─► Groq, Cerebras, Mistral, etc.  (direct API keys)

   agentmemory :3111  ← workspaces talk to it directly over docker network
                        (no Traefik exposure; project-scoped via per-call arg)
```

**Two roles, never blurred:**

- **Headroom = compression.** ContentRouter pipeline + tool-result
  interceptors. The single source of compression in the stack — OmniRoute's
  own RTK+Caveman compression is left **disabled** because stacking
  compressors corrupts Anthropic prompt-cache markers. See the headroom
  and omniroute READMEs for the verification trail.
- **OmniRoute = routing.** Picks meridian, cliproxy, Kiro, or a direct-key
  provider per-request based on requested model and dashboard-configured
  routing combos.

This split means meridian and cliproxy can stay **internal-only** (no
Traefik labels) — defense-in-depth for their long-lived OAuth credentials.
Only OmniRoute reaches them, only Headroom reaches OmniRoute.

agentmemory is on a separate path entirely — workspaces hit it directly
at `http://agentmemory:3111` over the docker network. It doesn't need
compression (small JSON payloads) and doesn't need centralized routing
(single backend).

## Current services

| Service        | Type       | Image                                  | Public via Traefik?            | Purpose                                              |
|----------------|------------|----------------------------------------|--------------------------------|------------------------------------------------------|
| `headroom`     | compose    | `ghcr.io/chopratejas/headroom`         | Yes — `/headroom/*`            | Centralized compression for all LLM traffic          |
| `omniroute`    | compose    | `diegosouzapw/omniroute`               | Yes — `/omniroute/*` (dashboard) | Centralized provider routing                       |
| `meridian`     | compose    | `ghcr.io/rynfar/meridian`              | No — internal only             | Claude Pro/Max subscription proxy                    |
| `cliproxy`     | built      | `ghcr.io/nyc-design/cliproxy`          | No — internal only             | Codex + Gemini OAuth proxy                           |
| `agentmemory`  | built      | `ghcr.io/nyc-design/agentmemory`       | No — internal only             | Persistent memory backend (iii-engine + agentmemory) |

All services opt into Watchtower auto-updates via the
`com.centurylinklabs.watchtower.enable=true` label. Built images get
rebuilt and pushed by their per-service workflow on push to `main`.

## Public URLs (what clients actually use)

- **LLM traffic**: `https://llm.tapiavala.com/headroom/v1/messages` (and
  `/v1/responses`, `/v1/chat/completions`, `/v1beta/models/.../generateContent`,
  `/v1internal:streamGenerateContent`). All four protocol shapes work
  through this single base URL.
- **OmniRoute dashboard**: `https://llm.tapiavala.com/omniroute/` — for
  configuring providers, OAuth flows, and routing combos.

Workspaces, Coder Agents, laptop CLIs — they all use the same base URL.

## Auth model

Three independent API keys, one per boundary in the chain:

```
client ──[LLM_GATEWAY_API_KEY]──► headroom (transparent) ──► omniroute
                                                              │
                                          [MERIDIAN_API_KEY] ──┼──► meridian
                                          [CLIPROXY_API_KEY] ──┴──► cliproxy
```

| Key                    | Where it lives          | Validated by                        | Presented by                                       |
|------------------------|-------------------------|-------------------------------------|----------------------------------------------------|
| `LLM_GATEWAY_API_KEY`  | host `.env` + OmniRoute dashboard | OmniRoute (Client API Keys config)  | client (laptop, Coder Agent, workspace CLI)        |
| `CLIPROXY_API_KEY`     | host `.env` + OmniRoute dashboard | cliproxy env-gated middleware       | OmniRoute (per-provider config in dashboard)       |
| `MERIDIAN_API_KEY`     | host `.env` + OmniRoute dashboard | meridian `src/proxy/auth.ts` middleware | OmniRoute (per-provider config in dashboard)   |

Generate each with `openssl rand -hex 32`. Same `.env` value goes into
the matching OmniRoute dashboard config; the upstream service reads it
from env at startup. Headroom doesn't see or care about any of these —
it's transparent at this layer.

Why three keys, not one: bounded blast radius. A leaked
`LLM_GATEWAY_API_KEY` can hit the gateway but can't reach meridian or
cliproxy directly (different docker network names, different keys);
a leaked upstream key can't impersonate the gateway. Rotate any single
key without disturbing the others.

## Adding a new service

1. Create `host-services/<name>/`
2. If compose-only: add `docker-compose.snippet.yml` + `README.md`
3. If we build the image: add `Dockerfile` + config files +
   `docker-compose.snippet.yml` + `README.md`, then add
   `.github/workflows/build-<name>.yaml` (copy an existing per-service
   workflow as a template)
4. Append the snippet to the host VM's `docker-compose.yml`
5. Decide public-or-internal:
   - Public — add Traefik labels in the snippet
   - Internal — only watchtower label; document the consumer
6. Update this README's service table and topology diagram if the role
   is non-obvious
