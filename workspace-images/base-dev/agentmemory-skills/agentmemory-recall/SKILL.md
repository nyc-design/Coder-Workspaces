---
name: agentmemory-recall
description: At the start of a task in a known repo, search persistent memory (agentmemory MCP) for prior observations, lessons, decisions, and session history before doing fresh discovery. Saves rediscovery work; surfaces user-validated approaches and prior failures.
---

# Recalling prior memory before a task

This workspace has the **agentmemory** MCP server attached (`memory_*` tools).
It holds per-repo durable memory across workspace recreate: observations
saved by past agent runs, lessons learned, sessions, embeddings.

## When to invoke

- Starting a new task or sub-task in a repo that already exists (i.e. not
  a brand-new project you just scaffolded).
- The user references something they / a prior agent worked on
  ("the issue from last week", "the rerank changes", "what you broke
  yesterday").
- About to make a non-trivial architectural / dependency / config decision
  in this repo. Check whether the team has already discussed it.

## How

Always pass `project` so memory stays scoped per-repo and survives
workspace recreate. Derive once at the start of the session:

```bash
project="$(basename "$(git remote get-url origin)" .git)"
# e.g. "Coder-Workspaces"
```

Then call the agentmemory MCP tools:

| Tool | Use for |
|---|---|
| `memory_smart_search` | Best default. Hybrid semantic + keyword search with progressive disclosure. Pass `query` + `project`. |
| `memory_recall` | When you need full raw observations rather than ranked snippets. |
| `memory_sessions` | Listing recent sessions chronologically; see `agentmemory-session-history` skill for that flow specifically. |

### Token discipline

Prefer `format: "compact"` (or `"narrative"`) when calling `memory_recall`
and apply a `token_budget` if you expect many hits. Memory results can be
large; budget them like any other tool result.

```
memory_smart_search(query="rerank latency on Oracle VM", limit=8)
memory_recall(query="rerank latency", format="compact", token_budget=2000, project="<repo>")
```

## What you'll get back

- **Observations** — raw saved insights with type (`pattern`, `bug`,
  `architecture`, `preference`, etc.), concepts, importance score.
- **Lessons** — confidence-weighted rules ("when X, do Y") that strengthen
  on reuse and decay if unused.
- **Sentinels / sketches** — passive lifecycle markers; usually safe to
  skim past unless directly relevant.

## When NOT to invoke

- Brand-new repo with no prior sessions (waste of a tool call).
- Trivial single-step task where rediscovery costs less than the lookup.
- The user has explicitly told you to ignore memory for this turn.

## Pair with

- `agentmemory-remember` — save the new insights this task produces.
- `agentmemory-session-history` — when the user asks "what did we do?".
- `agentmemory-forget` — when prior memory is wrong and needs to be
  overridden.
