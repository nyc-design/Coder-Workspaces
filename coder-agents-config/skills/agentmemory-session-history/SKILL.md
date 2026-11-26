---
name: agentmemory-session-history
description: Inspect prior agent sessions in this repo via agentmemory MCP — list recent sessions chronologically, see what was worked on, find a specific past task. Use when the user asks "what did we do?" / "have we worked on X before?" / "show recent activity".
---

# Reviewing past sessions

agentmemory groups observations into sessions, one per chat or agent run, each with a timestamp, status, observation count, and concepts. Use the session list for historical questions ("what were we working on last week?", "where did we leave off?"), for an overview of a repository before starting work, and to check whether something was already attempted.

## Project key

Pass `project` on every call. Its value is fixed by this rule so every agent uses the same key:

- The GitHub repository name exactly as GitHub spells it, capitals and hyphens included, with no owner and no `.git`. Right: `Coder-Workspaces`. Wrong: `nyc-design/Coder-Workspaces`, `coder-workspaces`, the workspace name `Coder-Workspaces-Agents`, a directory name.
- With a workspace attached, take it from `git remote get-url origin`. Without one, take it from the repository the chat is about, checking the spelling with the GitHub tools if you have not seen it written.
- When the chat is not about any repository, use `general`.

**List recent sessions.** Returns status (`active`, `completed`, `aborted`) and observation counts:

```
memory_sessions({ project: "<repo>" })
```

**Read what a session covered.** Search for its topic:

```
memory_smart_search({ query: "rerank latency Oracle VM", project: "<repo>", limit: 8 })
```

**Find patterns across sessions** ("what keeps failing in this module?"). `memory_reflect` is LLM-backed and costs more, so keep it for questions that need synthesis, not plain lookup:

```
memory_reflect({ project: "<repo>", maxClusters: 8 })
```

If output is too long, use `memory_recall` with `format: "compact"` or `"narrative"` and a `token_budget`.
