# omniroute

[OmniRoute](https://github.com/diegosouzapw/OmniRoute) — multi-provider AI
gateway with smart routing, automatic fallback, and Kiro support
(AWS Builder ID + IDC + social OAuth). Compose-only service that pulls
the upstream image directly from Docker Hub
(`diegosouzapw/omniroute:latest`).

## Why OmniRoute?

Picked over the upstream's predecessor (9router) on the basis of:

- 12× test coverage (4,690+ tests across 517 files vs 368)
- TypeScript core with zero `any` (vs JavaScript)
- Release branches + CodeQL + SonarCloud + Dependabot (vs direct-to-master)
- 160+ providers (vs 40+)
- Avoids the v0.4.36/v0.4.37 broken-Docker-image incidents 9router shipped
- Production-grade Kiro impl with claimed savings via stacked compression

User explicitly never points real Claude Code at this gateway, so 9router's
dynamic-forwarding-on-claude-cli-UA advantage doesn't apply.

## Configuration

Everything is configured via the dashboard at
`https://llm.tapiavala.com/omniroute`. There is no compose-side env or
config file.

Settings persist on the `omniroute-data` named volume:

| Path inside container | Contents                                          |
|-----------------------|---------------------------------------------------|
| `/data/`              | Provider configs, OAuth tokens, routing policies  |

Watchtower upgrades preserve everything via the volume.

## Bootstrap

1. Visit `https://llm.tapiavala.com/omniroute` and complete dashboard setup
2. Add upstream providers (Kiro, OpenRouter, Groq, Cerebras, etc.) via UI
3. Configure routing policies; OAuth/login flows happen in the browser

## Endpoints

OmniRoute exposes the standard OpenAI-compatible API at the root path:

- `POST /v1/chat/completions`
- `POST /v1/messages` (Anthropic-shape, when configured)
- `GET  /v1/models`
- `GET  /` — dashboard
