# coder-agents-config

Git-tracked admin config for Coder Agents (chatd). Synced to a running Coder
deployment by the
[`update-coder-agents-config.yaml`](../.github/workflows/update-coder-agents-config.yaml)
GitHub Actions workflow on every commit that touches this directory.

## Files

| File | Synced to | Stable identity (matched on POST/PATCH) |
|---|---|---|
| `providers.yaml` | `/api/v2/ai/providers` | `name` field |
| `models.yaml` | `/api/v2/organizations/{org}/chats/models` | `(provider, model)` tuple |
| `model-overrides.yaml` | `/api/v2/organizations/{org}/chats/model-overrides/{context}` | `context` (PUT); model resolved by `(provider, model)` |
| `mcp-servers.yaml` | `/api/v2/organizations/{org}/mcp-servers` | `slug` field |
| `skills/<name>/SKILL.md`, `skills-install.json` | `/api/experimental/organizations/{org}/skills` | frontmatter `name` (must equal the directory name) |
| `system-prompt.txt` | `/api/v2/chats/config/system-prompt` | (singleton, PUT) |
| `organization-system-prompt.txt` | `/api/v2/organizations/{org}/chats/config/system-prompt` | (one per organization, PUT) |
| `plan-mode-instructions.txt` | `/api/v2/chats/config/plan-mode-instructions` | (singleton, PUT) |
| `template-allowlist.yaml` | `/api/v2/templates/{id}` (`agents_allowed`) | template slug (`name`); every template not listed is set to `false` |
| `sync.sh` | — (the script the workflow runs) | — |

## Sync semantics

Per resource type:

| Resource | Mode | Behavior |
|---|---|---|
| Providers | **Additive** | POST if missing, PATCH if exists; never delete. Manual UI additions are preserved. |
| **Models** | **Declarative** | POST/PATCH desired; **DELETE any model in Coder not listed in `models.yaml`**. The YAML is source of truth. |
| Model overrides | **Declared contexts only** | PUT each declared context, then GET to verify. Missing file, empty list, and unlisted contexts leave existing overrides untouched. |
| MCP Servers | **Additive** | Same as providers. |
| Skills | **Additive** | POST if missing, PATCH the content if it exists; never delete. Not exported by `pull`. |
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
- **Order**: providers → models (POST/PATCH) → models (delete unmatched) → model
  overrides → MCP servers → skills → system prompts. Coder rejects model creation if the provider isn't
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


## Model overrides

`model-overrides.yaml` selects organization-level models for specific chat
contexts without changing a model's normal-chat defaults:

```yaml
overrides:
  - context: title_generation
    provider: anthropic
    model: cliproxy-claude/claude-haiku-5-5
    reasoning_effort: low
```

The tracked configuration only sets title generation. Haiku's normal-chat
reasoning default remains `high` in `models.yaml`; compaction and subagent
settings are untouched. The sync resolves the provider name to its UUID, then
matches the model by `(ai_provider_id, model)` in the selected organization.
Missing, ambiguous, or disabled models fail sync before any override PUT.
Duplicate contexts and malformed entries also fail rather than being ignored.
A GET after the PUTs must match every declared model and reasoning effort.

`reasoning_effort` is optional; omit it or set it to `null` to inherit the
selected model's default. Other contexts supported by Coder (such as `general`,
`explore`, and `compaction`) can be declared using the same schema. Unknown
contexts are rejected by the server. Omitting a context does **not** clear its
saved override; clear unwanted overrides in Coder admin.

Pull writes `model-overrides.yaml.new`, resolving stored model/provider UUIDs
back to readable names and preserving explicit reasoning efforts. It fails if
a referenced model or provider cannot be resolved. Review the `.new` file
before replacing the tracked configuration; pull never overwrites it.

The API requires Coder v2.39.0 or a compatible version. As with other resources,
`CODER_ORGANIZATION` selects the organization (default: `default`).

## Skills

Organization skills are available in every chat in the organization, including
chats with no workspace attached. Like the workspace images, there are two
inputs:

- `skills/<name>/SKILL.md`: skills maintained here.
- `skills-install.json`: a JSON array of URLs to upstream skills. A GitHub
  directory URL (`https://github.com/<owner>/<repo>/tree/<ref>/<path>`) is read
  as `<path>/SKILL.md`; any other URL must point at a `SKILL.md` directly.
  Upstream content is fetched again on every sync, so it tracks the ref.

Rules, checked before any request is sent:

- The frontmatter `name` is lowercase kebab-case and, for local skills, equals
  the directory name. A name may appear only once across both inputs.
- A skill is one file of at most 64 KB. Coder stores only `SKILL.md`, so files
  next to it are not uploaded (sync warns), and an upstream skill that relies on
  supporting files or scripts belongs in a workspace image instead.

Sync sends only the content. A skill disabled in Coder admin stays disabled, and
whether the model may load a skill on its own follows the frontmatter on
creation (`disable-model-invocation: true` turns that off). To remove a skill,
delete it here and in Coder admin. The endpoint is under `/api/experimental` and
may change between Coder releases; this was written against v2.39.5.

### Skill levels

| Level | Where it lives | Available | Use for |
|---|---|---|---|
| Coder Agents central | `coder-agents-config/skills/`, `skills-install.json` | Every chat, with or without a workspace; not the in-workspace CLIs | Skills about central MCP servers or about getting a workspace |
| Base workspace image | `workspace-images/base-dev/skills.d/`, `skills-install.d/` | Every workspace, for Coder Agents and the CLIs | Process and tooling common to all projects |
| Runtime-specific image | `workspace-images/<image>/skills.d/`, `skills-install.d/` | Workspaces on that image and its children | Language or framework specifics |
| Workspace / repo | `.agents/skills/` in the repository | That repository | Project conventions |

A skill with the same name at two levels is not overridden: Coder lists both
under source-qualified names. Keep each skill at one level.

## Tests

Offline regression tests exercise the actual sync script against a local mock
Coder API; no deployment credentials are needed. They require Python 3 plus the
script's normal tools (`bash`, `curl`, `jq`, mikefarah `yq` v4+, `envsubst`):

```bash
bash -n coder-agents-config/sync.sh
python3 -m unittest discover -s coder-agents-config/tests -v
```

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

- Coder Agents has three instruction slots, and each file here feeds one:

  | File | Slot in Coder admin | Reaches | Put here |
  |---|---|---|---|
  | `system-prompt.txt` | Deployment instructions | Every chat in every organization, after Coder's built-in prompt | Rules that hold whatever the organization has configured (communication style) |
  | `organization-system-prompt.txt` | Organization instructions | Chats in `CODER_ORGANIZATION`, as a second system message | Anything that names this organization's MCP servers or skills (agentmemory, Headroom retrieval, workspace creation) |
  | `plan-mode-instructions.txt` | Plan instructions | Any chat, only on plan-mode turns | Plan format rules |

  The first two are stored in a chat when it is created, so an edit reaches new
  chats only. Plan instructions are read on every plan-mode turn.
- MCP tool schemas are deferred behind `find_tools` (the `mcp-tool-search`
  experiment), `force_on` servers included. A prompt or skill that wants a
  tool used without a search must give its exact name and arguments.
- These prompts sit on top of any per-workspace `~/.coder/AGENTS.md` and
  project-level `AGENTS.md`.
- The per-workspace prompt is generated by `11-agent-prompts.sh` and lives in
  the workspace image — see `workspace-images/base-dev/system_prompt.txt` and
  per-image `system_prompt_extension.txt` files.
- Don't put workspace-image guidance in either system prompt file; put it in the
  workspace prompts instead. The prompts here are for what the central
  loop should know and do *before* it has a workspace context.
