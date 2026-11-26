---
name: agentmemory-remember
description: Save a durable observation, lesson, or correction to persistent memory (agentmemory MCP) when the user corrects you, validates a non-obvious approach, or shares a project fact that future agents would otherwise rediscover. Always per-repo scoped via `project`.
---

# Saving to memory

Save when one of these happens:

- **The user corrects you** ("no, do X not Y", "we don't use that here"): save as a `preference` or `pattern`.
- **The user confirms a non-obvious choice** ("yes, a single PR was the right call"): save it with the reason.
- **A project fact that code and `git log` do not show**: who owns what, why a constraint exists, pointers to external systems, deadlines.
- **A bug whose cause was hard to find**: the fix goes in the commit; save what made it hard to find and the false trails you ruled out.

Do not save code patterns visible in the repository, git history, or in-progress task state. If the user asks you to remember something a command already answers (for example "the PR I just opened"), point them to that command instead.

Search first (agentmemory-recall) so you do not duplicate an existing entry.

## Project key

Pass `project` on every call. Its value is fixed by this rule so every agent uses the same key:

- The GitHub repository name exactly as GitHub spells it, capitals and hyphens included, with no owner and no `.git`. Right: `Coder-Workspaces`. Wrong: `nyc-design/Coder-Workspaces`, `coder-workspaces`, the workspace name `Coder-Workspaces-Agents`, a directory name.
- With a workspace attached, take it from `git remote get-url origin`. Without one, take it from the repository the chat is about, checking the spelling with the GitHub tools if you have not seen it written.
- When the chat is not about any repository, use `general`.

## `memory_save`: observations, facts, decisions

```
memory_save({
  content: "Headroom is root-mounted on llm.tapiavala.com; the /headroom path prefix is no longer in use.",
  type: "architecture",
  concepts: "headroom, routing, traefik, llm.tapiavala.com",
  files: "host-services/headroom/docker-compose.snippet.yml,coder-agents-config/providers.yaml",
  project: "<repo>"
})
```

`type` is one of `pattern`, `preference`, `architecture`, `bug`, `workflow`, `fact`.

## `memory_lesson_save`: rules

Use this for a rule the user is teaching you. Its confidence rises each time the same content is saved again and decays when unused.

```
memory_lesson_save({
  content: "When agentmemory's model download stalls on first start, do not delete the volume; it is a one-time 30s download.",
  context: "agentmemory container restart on Oracle VM",
  project: "<repo>",
  confidence: 0.7,
  tags: "agentmemory,startup,gotcha"
})
```
