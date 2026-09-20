# Codex-informed prompt review

Reviewed September 19, 2026. This is maintenance documentation, not injected prompt content.

## Sources and limits

Official `openai/codex` sources were fetched through GitHub's API at commit
`78245b47af2a7aafcabe025828ceecca69db4df1` (the resolved `main` at review time):

- `codex-rs/models-manager/prompt.md`: Task execution, Validating your work, Ambition vs. precision, AGENTS.md spec.
- `codex-rs/models-manager/models.json`: `models[].model_messages.instructions_template`; compared GPT-5.5 Engineering judgment, GPT-5.4 Editing constraints, GPT-5.6 scope/autonomy guidance, and GPT-6 Astra verification/delegation guidance. Model templates differ; the baseline is not the complete effective prompt for every model.
- `codex-rs/core/src/agents_md.rs`: instruction discovery, ordering, trust checks, and byte budget.
- `codex-rs/core/src/context/world_state/agents_md.rs`: replacement/removal of changed instruction context.
- `codex-rs/skills/src/assets/samples/openai-docs/references/prompting-guide.md`: model-specific harness recommendations, not a universal system prompt.

OpenAI's “Unlocking the Codex harness: how we built the App Server” describes
shared harness infrastructure across CLI, IDE, and macOS surfaces:
https://openai.com/index/unlocking-the-codex-harness/

This is a comparison against public shared-harness/model instructions, NOT a
claim to have extracted the complete Mac app system prompt. App-specific,
server-provided, user-configured, and runtime instructions may differ. No Mac
app installation or private app prompt was inspected. Upstream wording was
synthesized, not copied wholesale.

## Effective local stack

- Coder built-in instructions remain enabled by `include_default_system_prompt: true`.
- Central prompt: workspace provisioning, communication, durable memory. Plan-mode instructions are a separate resource and remain unchanged.
- Image prompt: base plus sorted specialized fragments, assembled by `11-agent-prompts.sh` into `~/.coder/AGENTS.md`.
- CLI paths are linked to the canonical file only when missing or already symlinks; existing regular user files are preserved and can diverge. This workspace has such regular files. Repository source changes do not update the currently injected prompt.
- Project/nested instructions, skills, tool schemas, and runtime context still apply. They are not counted as savings here. Duplicate GitNexus material in this repo's AGENTS.md/CLAUDE.md is outside this change.

## Decisions

| Area | Comparison and decision |
|---|---|
| Lean/DRY | Expand the previous slogan into reuse of suitable helpers, existing patterns, focused root-cause fixes, and no speculative abstractions. DRY is not an instruction to abstract every repetition. |
| Scope/autonomy | Complete authorized work, but questions/reviews do not authorize edits. Resolve uncertainty from context; ask about material scope, permissions, and consequential choices. Delegates inherit scope and permissions. |
| Validation | Add/update focused behavioral tests, run required project checks, expand with risk, review the diff, and disclose failures/gaps and execution environment. Do not import model-specific prohibitions on tests. |
| Comments | Explain non-obvious intent rather than narrating code. Preserve our explicit checklist-as-comments convention; do not import the baseline's blanket inline-comment prohibition. |
| Tooling | Preserve project tooling; describe image tools as defaults rather than mandates. Non-mutating checks precede scoped autofixes. |
| Architecture | Preserve the architecture-first phases, LikeC4 skill, contracts, and checklist rules; resume the current phase rather than restarting it for every small fix. |
| Git/review | Replace periodic unconditional push/pull pressure with scope-aware Git safety. Always push after committing because the user typically works in a separate workspace; report push blockers. One PR per implementation request, after validation/review; explicitly include inline review threads, not only conversation comments. |
| Context efficiency | Reuse supplied context, shorten tool inventories and repeated explanations, retain distill's exact-content exemptions and fallback. Keep specialized instructions in image layers. |
| Provisioning | Preserve naming, account, template, modes, and parameter mapping. Resolve scaffold choices from the template instead of maintaining a stale enum (`nextjs` was not supported). Require confirmed project-secret scope before setting the GCP project. |
| Memory | Preserve recall/save/history intent and skill pointers. Use `project` only where exposed by tool schemas; qualify queries and verify returned scope otherwise. |
| Specialized images | Shorten Vite, fullstack, Python telemetry, and Swift wording while retaining commands, contracts, remote Mac workflow, credentials, and cost/validation boundaries. Leave modeling's nuanced runtime safety constraints and empty language fragments unchanged. |

Not imported: model personas, tool syntax from another harness, fixed progress
cadences, compulsory delegation, aggressive permission assumptions, or an entire
Codex prompt. No runtime scripts, model settings, skills, or template behavior
were changed. Existing built-in protected-branch confirmation rules remain in
force; the shorter shared rule also protects standalone workspace CLIs.

## Token measurements

Measured with `tiktoken`'s `o200k_base` on UTF-8 prompt text, compared to parent
commit `35626b3`. Central YAML frontmatter is excluded using standalone delimiter
lines (not substring splitting: comments can contain `---`). Counts below sum
individual fragment bodies; separators/runtime wrapping can change exact totals.
This is a reproducible size proxy, not a claim about all providers' tokenizers,
prompt caching, total context size, or billed savings.

| Prompt | Before | After | Reduction |
|---|---:|---:|---:|
| Central body | 553 | 318 | 235 |
| Base | 639 | 595 | 44 |
| Vite | 298 | 171 | 127 |
| Fullstack | 128 | 61 | 67 |
| Python shared | 105 | 40 | 65 |
| Swift | 624 | 309 | 315 |
| Modeling (unchanged) | 390 | 390 | 0 |

Representative Coder custom stacks (central + relevant image fragments):

- Base: 1,192 → 913 (~23% smaller).
- Fullstack: 1,723 → 1,185 (~31% smaller).
- Swift: 1,816 → 1,222 (~33% smaller).
- Modeling: 1,687 → 1,343 (~20% smaller).

Standalone CLIs do not automatically receive the central prompt. Their savings
are the image-fragment reductions only, and only once their instruction paths
actually resolve to the updated canonical content.

## Validation and rollout

- Check whitespace and inspect every prompt diff.
- Exercise the actual central sync parser with mocked HTTP calls: nonempty body, frontmatter excluded, built-in prompt toggle remains true. Never run a live sync just to validate text.
- Assemble representative image fragment sequences in scratch space and check order/content; leave live workspace instructions untouched.
- Independent review checks preserved intent, executable commands, and parser correctness. Token size is measured; behavioral quality is not established by a model evaluation suite.
- Central text deploys via its existing config workflow after merge. Image text requires image rebuilds and workspace startup. Existing CLI regular files remain untouched; reconcile them deliberately if shared behavior is desired. This PR does not deploy or rewrite those files.
