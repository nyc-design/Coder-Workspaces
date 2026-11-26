---
name: agentmemory-recall
description: At the start of a task in a known repo, search persistent memory (agentmemory MCP) for prior observations, lessons, decisions, and session history before doing fresh discovery. Saves rediscovery work; surfaces user-validated approaches and prior failures.
---

# Recalling prior memory

Search agentmemory (the `memory_*` MCP tools) before fresh discovery when:

- starting a task or sub-task in a repository that already exists;
- the user refers to earlier work ("the issue from last week", "what you broke yesterday");
- about to make a non-trivial architecture, dependency, or config decision that may already have been discussed.

Skip it for a brand-new repository, for a trivial single-step task, or when the user said to ignore memory.

Always pass `project`: the repository name, which is the basename of the origin URL without `.git` (for example `Coder-Workspaces`). Unscoped memory is unreliable to recall.

| Tool | Use for |
|---|---|
| `memory_smart_search` | The default. Hybrid semantic and keyword search. Pass `query` and `project`. |
| `memory_recall` | Full raw observations rather than ranked snippets. |
| `memory_sessions` | Chronological session list; see the agentmemory-session-history skill. |

Results can be large. Set `limit` on searches, and on `memory_recall` use `format: "compact"` (or `"narrative"`) with a `token_budget`:

```
memory_smart_search(query="rerank latency on Oracle VM", project="<repo>", limit=8)
memory_recall(query="rerank latency", project="<repo>", format="compact", token_budget=2000)
```

Results contain:

- **Observations**: saved insights with a type (`pattern`, `bug`, `architecture`, `preference`, ...), concepts, and an importance score.
- **Lessons**: confidence-weighted rules ("when X, do Y") that strengthen on reuse and decay when unused.
- **Sentinels and sketches**: lifecycle markers; skim past them unless directly relevant.

If a result is wrong or out of date, follow the agentmemory-forget skill.
