# Agent tools and diagram skills

## Installed tools

The base image uses Node 22 (approved upgrade from Node 20) and includes:

- Qwen Code `0.24.3` (`qwen`), via the existing npm-global prefix.
- Bailian CLI `2.0.0` (`bl`, also `bailian`), the official `modelstudioai/cli` npm package. Its tarball is checksum-verified; lifecycle hooks are disabled to avoid downloading mutable wiki/skills content into root's home during image build. Registry dependency ranges remain upstream-managed.
- CodexBar CLI `0.64.0` (`codexbar`), checksum-verified static-musl Linux amd64/arm64 release. The executable, resource bundle and VERSION stay together under `/usr/local/lib/codexbar`.

No login, usage polling or inference request runs during build/startup. Secrets are not in the image. Qwen is the coding harness; Bailian is a management/usage companion, not its replacement.

## Persistence and first login

The runtime module mounts host `/home/ubuntu/secrets/.qwen` and `.bailian` into the matching `/home/coder/` paths, like the existing Codex/Claude mounts. These are shared read/write across workspaces on the host: configuration, login/logout, and token refresh affect other workspaces. Avoid simultaneous login/config changes. Restrict host directories to the workspace user (mode 0700) and credential files to 0600; never commit or log their contents.

Before deploying the template, provision the two host directories with the same UID/GID as the existing `.codex`/`.claude` directories. Docker-created root-owned directories can prevent first login. Do not replace populated directories or existing credentials.

### Qwen: international Alibaba Token Plan

Run `qwen`, then `/auth` → Alibaba ModelStudio → Token Plan → Singapore (International). Enter the key privately in that flow and select models available to your subscription. Run `/doctor` and `/model` inside Qwen to inspect setup. No model is preselected or guessed by workspace init.

The Token Plan endpoint is:

```text
https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1
```

Configuration lives in `~/.qwen/settings.json`. For noninteractive setup, follow the upstream authentication guide's `modelProviders.openai` entry with this `baseUrl`, the chosen model ID and `envKey: BAILIAN_TOKEN_PLAN_API_KEY`; store its secret in Qwen's own configuration, not global `OPENAI_*` shell variables. Those generic variables could reroute other clients. Do not substitute mainland China, Coding Plan, or standard pay-as-you-go endpoints.

`~/.qwen/QWEN.md` links to our canonical prompt, and `~/.qwen/skills` receives canonical per-skill links. Existing regular user files/directories are preserved. No credentials means Qwen needs first-run setup, not that workspace startup should fail.

### Bailian: international console session

Bailian persists auth/profiles in `~/.bailian/config.json` (`BAILIAN_CONFIG_DIR` can override the directory). For usage access, sign in yourself:

```sh
bl auth login --console --console-site international
bl auth status --output json
bl usage token-plan --console-region ap-southeast-1 --console-site international --output json
```

The pinned Bailian 2.0.0 usage command queries Personal/Solo rolling-window usage only; it does not fetch Team credit pools. Team subscriptions need CodexBar's supported console-cookie path (or a separately verified future CLI implementation). Do not treat a successful personal response as Team usage.

Run browser login from an interactive session and follow the CLI's instructions. Console login may create an ordinary API key if needed; it does not configure your subscription inference endpoint. We do not run it automatically. Qwen's Token Plan inference key and Bailian's console usage session are separate credentials. Missing auth is reported noninteractively by `bl auth status`; successful status alone does not prove Token Plan usage authorization. Avoid `--verbose` for credential-bearing calls.

### CodexBar usage

CodexBar reads native Codex/Claude credentials from their existing mounts. Renew Claude login normally; no new Claude credential store is added. Test deliberately after login:

```sh
codexbar usage --provider codex --source oauth
codexbar usage --provider claude --source oauth
codexbar usage --provider alibaba-token-plan
```

Alibaba usage requires console authentication, not just a model API key. In CodexBar provider configuration select the matching international variant: `intl-personal` (the plan in use is Personal/Solo) or `intl` for Team. Init never writes account-specific config. Use `codexbar config --help` and the upstream configuration reference for provider settings. Configuration normally lives in `~/.config/codexbar/config.json` (per-workspace home persistence, unlike the host-shared native CLI credentials).

The host runs the same providers as a dashboard (`host-services/codexbar/`, linked as the "AI Usage" workspace app); in-workspace `codexbar usage` is for deliberate checks.

CodexBar auto tries signed-in `bl` first, then supported cookies. For Team subscriptions, explicitly configure the cookie usage source rather than relying on an incompatible successful personal CLI response. Live session validity, account tier compatibility, browser-login access and endpoint permissions must be verified after user login. No background poller is installed. Qwen Cloud is a separate provider; do not select it merely because the coding harness is Qwen Code.

## Diagram skills

`skills-install.d/10-base.json` targets only upstream `likec4-dsl` and `archify` directories. Startup installs them using the existing skills CLI into `~/.agents/skills`, then publishes provider links. Upstream skill sources track main, like other existing CLI-managed skills; they are not pinned image snapshots and startup needs network access. Installer failures warn rather than fail workspace startup—check the init log if a skill is absent.

- `likec4-modeling`: our workflow/checklist conventions, referring to upstream `likec4-dsl` for syntax.
- `archify`: diagrams explaining changes, delivered as self-contained HTML plus editable source when appropriate. Attach HTML to chat for users in separate workspaces; do not replace maintained LikeC4 architecture models or require diagrams for trivial changes.

Coder Agents discovers the canonical catalog through the existing `CODER_AGENT_EXP_SKILLS_DIRS` template environment. Skills become available after workspace attachment/startup, not in workspace-less central chats. Full skill bodies are loaded on demand rather than copied into the central system prompt. `ARCHIFY_UPDATE_CHECK_DISABLED=1` disables the optional update reminder network call. Core render/validation uses Node; browser-based visual checking is optional and is not preinstalled into base-dev by this change.

## Checks and rollout

```sh
bash workspace-images/base-dev/tests/test-agent-tools-init.sh
bash workspace-images/base-dev/tests/test-bailian-install.sh
bash workspace-images/base-dev/tests/test-codexbar-install.sh
```

Installer tests mock downloads/platforms and test checksum rejection, not real cross-architecture execution. Native ARM64 Qwen/Bailian/CodexBar version checks and an Archify showcase delivery passed in scratch environments; full base/child image builds, AMD64 execution and authenticated provider calls were not run locally. The agent-tools CI workflow runs native architecture smoke tests without publishing images or using provider secrets.

Merge/build base-dev and inherited images; deploy the updated project-workspace template/runtime module for the new mounts; rebuild/restart workspaces. Restarting an old image alone will not install these CLIs. Existing regular CLI prompt files remain untouched. Node 22 changes the default inherited runtime; project-specific Node pins remain the project's responsibility.

## Upstream references

- https://qwenlm.github.io/qwen-code-docs/en/users/configuration/auth/
- https://github.com/modelstudioai/cli
- https://github.com/steipete/CodexBar/blob/v0.64.0/docs/alibaba-token-plan.md
- https://github.com/steipete/CodexBar/blob/v0.64.0/docs/configuration.md
- https://github.com/likec4/likec4/tree/main/skills/likec4-dsl
- https://github.com/tt-a1i/archify/tree/main/archify
