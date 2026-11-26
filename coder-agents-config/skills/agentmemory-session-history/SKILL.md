---
name: agentmemory-session-history
description: Inspect prior agent sessions in this repo via agentmemory MCP — list recent sessions chronologically, see what was worked on, find a specific past task. Use when the user asks "what did we do?" / "have we worked on X before?" / "show recent activity".
---

# Reviewing past sessions

agentmemory groups observations into sessions (one per chat / agent run).
Each session has a timestamp, status, observation count, and the concepts
that were touched. Listing them is the cleanest way to answer questions
about "what happened before" in this repo.

## When to invoke

- User asks an explicitly historical question: "what were we working on
  last week?", "have we touched the rerank code before?", "remind me
  where we left off."
- You arrive in a repo and need a quick overview before starting fresh
  work (often more useful than a single `memory_smart_search` because
  it shows clusters of related activity).
- Investigating whether something was *already attempted* before
  re-attempting it.

## How

Always pass `project` (basename of the git remote, `.git` stripped):

```bash
project="$(basename "$(git remote get-url origin)" .git)"
```

### List recent sessions

```
memory_sessions({ project: "<repo>" })
```

Returns recent sessions with status (`active` / `completed` / `aborted`)
and observation counts. Use this as the index page.

### Drill into a specific topic across sessions

If `memory_sessions` shows a relevant session, use `memory_smart_search`
or `memory_recall` to pull the actual observations:

```
memory_smart_search({ query: "rerank latency Oracle VM", project: "<repo>", limit: 8 })
```

### Higher-order patterns

For cross-session synthesis ("what's the recurring failure mode in this
module?"), `memory_reflect` traverses the graph and groups clusters:

```
memory_reflect({ project: "<repo>", maxClusters: 8 })
```

Reflection is more expensive (LLM-backed). Reserve for genuinely
synthetic questions, not basic lookup.

## Token discipline

Session lists can be long in active repos. If the response is unwieldy,
ask `memory_recall` for `format: "narrative"` or `"compact"` and pass
a `token_budget`.

## Pair with

- `agentmemory-recall` — when you want content-search rather than
  chronological listing.
- `agentmemory-remember` — once you've reviewed history, mark the
  current session's new insights so the chain continues.
