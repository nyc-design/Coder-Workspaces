---
name: agentmemory-forget
description: When a saved memory is now wrong (stale, contradicted, or the user explicitly says forget X), record a corrective observation that overrides the stale one rather than trying to delete. agentmemory has no hard-delete; correctness comes from layering newer + higher-confidence data.
---

# Correcting / overriding stale memory

agentmemory does **not** expose a hard-delete MCP tool. The system is
designed around lifecycle: observations decay if unused, lessons lose
confidence when not reinforced, and newer / higher-confidence data
outranks older entries in search results.

So "forget X" is implemented by **saving a correction**, not by trying
to erase the prior record.

## When to invoke

- The user explicitly says "forget X" / "that's wrong" / "don't remember
  that anymore".
- You discover via `agentmemory-recall` that a saved memory is now
  outdated (e.g. cited a file path that has since been renamed or
  removed, or a tool that no longer exists in the project).
- A prior lesson is being repeatedly cited in cases where it gives wrong
  guidance.

## How

### Step 1: surface the offending memory

Use `agentmemory-recall` (`memory_smart_search` or `memory_recall`) to
locate the stale observation(s) and read them in full so you can write
a correction that mentions the same concepts. Concept overlap is what
lets the retrieval layer co-rank old and new together.

### Step 2: save the correction

Use `memory_save` with the *same* concept tags as the stale entry, but
phrase the content as the new truth and explicitly note that it
supersedes the prior view:

```
memory_save({
  content: "CORRECTION (supersedes prior): Headroom is no longer at /headroom — it is root-mounted on llm.tapiavala.com. providers.yaml uses base_url=https://llm.tapiavala.com (and /v1 for the OpenAI provider).",
  type: "architecture",
  concepts: "headroom, routing, traefik, llm.tapiavala.com, base_url",
  files: "host-services/headroom/docker-compose.snippet.yml,coder-agents-config/providers.yaml",
  project: "<repo>"
})
```

### Step 3 (lessons only): re-save with low confidence

If the stale item is a **lesson** (`memory_lesson_save`), re-save the
*same content* with `confidence: 0.1`. Duplicate-content detection
auto-merges; the merge averages confidence, dragging the stale lesson
toward neutral. Combined with the corrective `memory_save` above, the
new view dominates retrieval.

```
memory_lesson_save({
  content: "<exact text of the stale lesson>",
  project: "<repo>",
  confidence: 0.1,
  tags: "corrected,superseded"
})
```

### Step 4 (optional): let lifecycle do the rest

Agentmemory's `auto-forget` sweep + `lesson-decay` job will gradually
demote anything no longer being reinforced. No further action needed.

## When NOT to invoke

- The "stale" memory is actually still correct; you just disagree
  stylistically. Don't overwrite the team's prior decision.
- You want to remove an entry purely for tidiness. Lifecycle handles
  that.
- You're unsure whether something is stale. Surface it to the user and
  ask before correcting.

## Pair with

- `agentmemory-recall` — locate the stale entry before correcting.
- `agentmemory-remember` — the corrective save itself uses the same
  tools described there; this skill just frames *when* to use them as a
  correction.
