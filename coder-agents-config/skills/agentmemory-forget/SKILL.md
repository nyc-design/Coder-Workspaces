---
name: agentmemory-forget
description: When a saved memory is now wrong (stale, contradicted, or the user explicitly says forget X), record a corrective observation that overrides the stale one rather than trying to delete. agentmemory has no hard-delete; correctness comes from layering newer + higher-confidence data.
---

# Correcting stale memory

agentmemory has no delete tool. Newer and higher-confidence entries outrank older ones, and unused entries decay. So "forget X" means saving a correction.

Use this when the user says "forget X" or "that's wrong", when a recalled memory is out of date (a renamed file, a tool no longer used), or when a lesson keeps giving wrong guidance.

Do not use it because you disagree with a prior decision on style, or to tidy up; decay handles that. If you are unsure whether an entry is stale, ask the user first.

## Project key

Pass `project` on every call. Its value is fixed by this rule so every agent uses the same key:

- The GitHub repository name exactly as GitHub spells it, capitals and hyphens included, with no owner and no `.git`. Right: `Coder-Workspaces`. Wrong: `nyc-design/Coder-Workspaces`, `coder-workspaces`, the workspace name `Coder-Workspaces-Agents`, a directory name.
- With a workspace attached, take it from `git remote get-url origin`. Without one, take it from the repository the chat is about, checking the spelling with the GitHub tools if you have not seen it written.
- When the chat is not about any repository, use `general`.

1. **Find the stale entry.** Search with `memory_smart_search` or `memory_recall` and read it in full, noting its concepts.

2. **Save the correction** with `memory_save`, using the same concepts as the stale entry so the two are ranked together. State the new truth and say that it supersedes the old one:

   ```
   memory_save({
     content: "CORRECTION (supersedes prior): Headroom is no longer at /headroom; it is root-mounted on llm.tapiavala.com.",
     type: "architecture",
     concepts: "headroom, routing, traefik, llm.tapiavala.com, base_url",
     files: "coder-agents-config/providers.yaml",
     project: "<repo>"
   })
   ```

3. **If the stale entry is a lesson**, also re-save its exact text with `confidence: 0.1`. Identical content is merged and the confidence averaged, which pulls the stale lesson down:

   ```
   memory_lesson_save({
     content: "<exact text of the stale lesson>",
     project: "<repo>",
     confidence: 0.1,
     tags: "corrected,superseded"
   })
   ```

Nothing else is needed; the decay jobs demote whatever is no longer reinforced.
