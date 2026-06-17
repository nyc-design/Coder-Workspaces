# coder-agents-config

Git-tracked admin config for Coder Agents (chatd). Synced to a running Coder
deployment by the
[`update-coder-agents-config.yaml`](../.github/workflows/update-coder-agents-config.yaml)
GitHub Actions workflow on every commit that touches this directory.

## Files

| File | Synced to | Stable identity (matched on POST/PATCH) |
|---|---|---|
| `providers.yaml` | `/api/v2/ai/providers` | `name` field |
| `models.yaml` | `/api/experimental/chats/model-configs` | `(provider, model)` tuple |
| `mcp-servers.yaml` | `/api/experimental/mcp/servers` | `slug` field |
| `system-prompt.txt` | `/api/experimental/chats/config/system-prompt` | (singleton, PUT) |
| `plan-mode-instructions.txt` | `/api/experimental/chats/config/plan-mode-instructions` | (singleton, PUT) |
| `template-allowlist.yaml` | `/api/experimental/chats/config/template-allowlist` | (singleton, PUT) — slugs resolved to template UUIDs at sync time |
| `sync.sh` | — (the script the workflow runs) | — |

## Sync semantics

Per resource type:

| Resource | Mode | Behavior |
|---|---|---|
| Providers | **Additive** | POST if missing, PATCH if exists; never delete. Manual UI additions are preserved. |
| **Models** | **Declarative** | POST/PATCH desired; **DELETE any model in Coder not listed in `models.yaml`**. The YAML is source of truth. |
| MCP Servers | **Additive** | Same as providers. |
| System prompt | PUT singleton | Always overwritten. |
| Plan mode instructions | PUT singleton | Always overwritten. |
| Template allowlist | PUT singleton | Always overwritten. Empty list / missing file = all templates allowed. |

Why models are declarative: cost tracking, context limits, and reasoning
budgets are easy to drift between repo and admin if you only add. Forcing
parity catches accidental UI edits. Providers and MCPs stay additive because
losing a manually-added Bedrock provider or a workspace-scoped MCP to a git
deploy would be far more disruptive than a stale model entry.

Other notes:

- **Idempotent**: re-running sync produces the same admin state. Safe to spam.
- **Order**: providers → models (POST/PATCH) → models (delete unmatched) → MCP
  servers → system prompt. Coder rejects model creation if the provider isn't
  already configured. Model deletes happen last so a new default is in place
  before the old default gets removed.
- **Secrets**: YAML values may contain `${VAR}` placeholders, which `envsubst`
  expands at sync time from the workflow's env. The workflow pulls those env
  values from GitHub repository secrets.
- **Failure mode**: any HTTP 4xx/5xx fails sync loudly with the error body.

## Modes

`sync.sh` supports two modes:

```bash
./sync.sh push    # default — apply YAML → Coder
./sync.sh pull    # inverse — dump Coder admin state → *.new files for diff/commit
```

**Pull** is for bootstrapping: run it once locally with admin creds to dump
your existing admin state into `*.new` files alongside the YAML, then `diff`
and rename. After pulling, manually restore any `${VAR}` placeholders for
secrets — the API only returns `has_api_key: true|false`, never the value,
so secrets come out as opaque placeholders.


## OmniRoute model aliases

Coder Agents sees three provider entries (`anthropic`, `openai`, and disabled
`google`) that all point at the Headroom → OmniRoute gateway. Distinct backends
are selected by OmniRoute model aliases, not by separate Coder providers.

Create matching OmniRoute models / combos for every alias in `models.yaml`:

| Coder provider | Coder model alias | Intended OmniRoute route |
|---|---|---|
| `anthropic` | `claude-sonnet-4.5-omniroute-direct` | OmniRoute Claude Code OAuth provider directly |
| `anthropic` | `claude-opus-4.5-omniroute-direct` | OmniRoute Claude Code OAuth provider directly |
| `anthropic` | `claude-sonnet-4.5-meridian` | `anthropic-compatible-cc-meridian` → `http://meridian:3456/v1` |
| `anthropic` | `claude-opus-4.5-meridian` | `anthropic-compatible-cc-meridian` → `http://meridian:3456/v1` |
| `anthropic` | `claude-sonnet-4.5-cliproxy` | `anthropic-compatible-cc-cliproxy-claude` → `http://cliproxy:8317/v1` |
| `anthropic` | `claude-opus-4.5-cliproxy` | `anthropic-compatible-cc-cliproxy-claude` → `http://cliproxy:8317/v1` |
| `openai` | `gpt-5.1-codex-cliproxy` | `openai-compatible-cliproxy-resp` → `http://cliproxy:8317/v1`, `apiType=responses` |
| `openai` | `gpt-5.1-codex-omniroute-direct` | OmniRoute Codex OAuth provider directly |
| `anthropic` | `kiro-sonnet-free` | OmniRoute Kiro / AWS Builder ID route |
| `openai` | `cerebras-qwen3-coder-free` | OmniRoute Cerebras route |
| `openai` | `groq-qwen3-coder-free` | OmniRoute Groq route |
| `openai` | `codestral-free` | OmniRoute Codestral/Mistral route |
| `openai` | `opencode-zen-free` | OmniRoute OpenCode Zen route |

Coder provider base URLs (Headroom is root-mounted on `llm.tapiavala.com`):

- Anthropic/Google: `https://llm.tapiavala.com`
- OpenAI: `https://llm.tapiavala.com/v1` — Coder's OpenAI provider treats
  the base URL as the full API root and appends `/responses` directly.

## Workflow secrets

All five secrets live in **GCP Secret Manager** (project `coder-nt`) and are
fetched at workflow runtime via Workload Identity Federation. See
[`.github/SECRETS.md`](../.github/SECRETS.md) for the one-time WIF setup
(zero secrets stored in GitHub Actions).

| GCP secret | Used for |
|---|---|
| `CODER_URL` | Base URL of the Coder deployment |
| `CODER_SESSION_TOKEN` | Admin session token (Owner role) |
| `LLM_GATEWAY_API_KEY` | Substituted into `providers.yaml` for OmniRoute/Headroom gateway providers |
| `CONTEXT7_API_KEY` | Substituted into `mcp-servers.yaml` (Context7 header) |
| `GH_PAT_FOR_MCP` | Substituted into `mcp-servers.yaml` (GitHub MCP bearer; mapped to env `GITHUB_PAT` to match the YAML placeholder) |

GitHub Actions only stores two non-secret repo Variables (`GCP_WIF_PROVIDER`
and `GCP_WIF_SERVICE_ACCOUNT`) for the WIF auth path.

## Caveats

- All endpoints are **experimental** — Coder may break the API shape on
  upgrades. Pin a Coder version in production.
- Secrets are **write-only** in Coder's API: GETs return only
  `has_api_key: true|false` flags, never the value. So sync always re-PATCHes
  the secret value on every run; you can't detect drift on secret content
  alone. Idempotent and harmless.
- **No deletion** in sync.sh. To remove an item, delete it manually in the
  Coder admin UI. (Adding a deletion mode would be a separate small change.)
- Provider deletion in Coder cascades — soft-deletes all model configs for
  that provider — which is another reason sync.sh deliberately doesn't
  delete.

## Running locally

```bash
export CODER_URL=https://coder.tapiavala.com
export CODER_SESSION_TOKEN=$(coder token create --scope all 2>/dev/null | tail -1)
export LLM_GATEWAY_API_KEY=...       # client-facing OmniRoute/Headroom gateway key
export CONTEXT7_API_KEY=...
export GITHUB_PAT=...

./coder-agents-config/sync.sh coder-agents-config
```

## Notes

- This system prompt applies to every Coder Agents chat in the deployment, on
  top of any per-workspace `~/.coder/AGENTS.md` and project-level `AGENTS.md`.
- The per-workspace prompt is generated by `11-agent-prompts.sh` and lives in
  the workspace image — see `workspace-images/base-dev/system_prompt.txt` and
  per-image `system_prompt_extension.txt` files.
- Don't put workspace-image guidance in `system-prompt.txt`; put it in the
  workspace prompts instead. The system prompt here is for what the central
  loop should know and do *before* it has a workspace context.
