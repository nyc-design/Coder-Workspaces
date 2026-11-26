---
name: agentmemory-remember
description: Save a durable observation, lesson, or correction to persistent memory (agentmemory MCP) when the user corrects you, validates a non-obvious approach, or shares a project fact that future agents would otherwise rediscover. Always per-repo scoped via `project`.
---

# Remembering insights across sessions

The agentmemory MCP server is the durable per-repo memory store. Saving
here makes the next agent in this repo pick up where you left off instead
of rediscovering the same thing.

## When to invoke

Save when you see one of these signals — they tend to indicate a real,
durable signal worth keeping:

- **User correction.** "No, do X not Y." / "Stop doing Z." / "We don't
  use that approach here." → save as a `preference` or `pattern` lesson.
- **User validation of a non-obvious choice.** "Yes, single PR was the
  right call." / "Good catch on the rerank bypass." → save with rationale.
- **A non-obvious project fact.** Something not derivable from
  `git log` or reading the code: who owns what, why a constraint exists,
  external system pointers, deadlines.
- **A bug fix where the *why* is non-obvious.** The fix itself goes in
  the commit; save what made the bug hard to find / the false trail you
  ruled out.

## When NOT to invoke

- Code patterns derivable from reading the repo.
- Git history, recent diffs, who-changed-what.
- Ephemeral state: in-progress task notes, current conversation context.
- The user asks you to remember "the PR I just opened" — recommend they
  rely on `gh pr view` instead; memory is for non-obvious signal.

## How

Two tools, different purposes:

### `memory_save` — observations, facts, decisions

```
memory_save({
  content: "Headroom is root-mounted on llm.tapiavala.com; the /headroom path prefix is no longer in use. providers.yaml and CLAUDE.md were updated to match.",
  type: "architecture",
  concepts: "headroom, routing, traefik, llm.tapiavala.com",
  files: "host-services/headroom/docker-compose.snippet.yml,coder-agents-config/providers.yaml",
  project: "<repo-basename>"
})
```

Valid `type` values: `pattern`, `preference`, `architecture`, `bug`,
`workflow`, `fact`.

### `memory_lesson_save` — confidence-weighted rules

Use this when the user is teaching you a *rule* that should strengthen
on reinforcement and decay if not used.

```
memory_lesson_save({
  content: "When agentmemory's @xenova/transformers download stalls on first start, do NOT delete the volume — it's a one-time 30s download, just wait.",
  context: "agentmemory container restart on Oracle VM",
  project: "<repo-basename>",
  confidence: 0.7,
  tags: "agentmemory,startup,gotcha"
})
```

Confidence auto-strengthens when the same lesson content is saved again,
and decays over time if unused.

## Project scoping (required)

ALWAYS include `project` so memory is keyed per-repo:

```bash
project="$(basename "$(git remote get-url origin)" .git)"
```

Without `project`, memory lands in an unscoped pool and is unreliable to
recall.

## Pair with

- `agentmemory-recall` — search before you build up new observations to
  avoid duplicating prior insights.
- `agentmemory-forget` — when an old saved memory is now wrong.
