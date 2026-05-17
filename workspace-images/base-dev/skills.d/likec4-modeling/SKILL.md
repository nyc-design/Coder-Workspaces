---
name: likec4-modeling
description: Author and maintain LikeC4 architecture models — system context, container, component, and dynamic (sequence) views. Invoke when adding/renaming/removing functions, endpoints, or services so the corresponding `.likec4/` files stay in sync with the code, or when authoring a new C4 view from scratch.
---

# Authoring & maintaining LikeC4 models

LikeC4 models live under `.likec4/` in the project repo and back the
architecture diagrams referenced by `CLAUDE.md`. They are the source of
truth for the C4 structural/component/sequence views, and they must stay
in sync with the code.

## When to invoke

- Adding, renaming, or removing a function, endpoint, service, scanner,
  or router that's represented as an `fn` element.
- Authoring a new C4 view (context, container, component, sequence).
- Reviewing a PR that touches files referenced by `.likec4/` elements.

After any change, run the LikeC4 MCP (or `likec4 validate`) to verify
the model parses.

## C4 view layers

- **Structural** — system context (what exists and what it talks to)
  plus container view (what's inside the system). Establish boundaries
  before designing internals.
- **Component** — break containers into internal components. At the
  lowest level, individual functions are modeled as `fn` elements
  nested inside their parent service/router/scanner. Each element with
  children gets a `view of` for drill-down.
- **Sequence (dynamic)** — one per major user flow, as an
  overview + detail pair. The overview references service-level
  elements for readability; the detail view references `fn`-level
  elements for precision. Detail views use `navigateTo` from the
  overview for drill-down.

## `fn` element naming conventions

Titles must reflect the actual code structure exactly:

- Module-level Python function: `'file_name.function_name()'`
  (e.g. `'media_pipeline.process_new_media()'`)
- Class method: `'file_name.ClassName.method_name()'`
  (e.g. `'rd_scanner.RDScanner._process_added()'`)
- External API endpoint: `'ServicePrefix: HTTP_METHOD /path'`
  (e.g. `'RD: GET /torrents'`)
- Frontend page: descriptive name (e.g. `'Library Page'`)

## Relationship aggregation

Always define relationships at the deepest `fn` level — LikeC4
automatically aggregates them upward through every parent zoom level.
Do NOT duplicate the same relationship at multiple levels.

## View title prefixes (dropdown organization)

Use category prefixes so the views dropdown stays organized:

- `1.` / `2.` / `3.` — hierarchy levels (context → container → component)
- `API:`, `Scanner:`, `Service:`, `DB:`, `Client:`, `Ext:`, `WebDAV:`, …
  — component drill-downs
- `Flow:` — dynamic sequence views

## Implementation-checklist coupling

LikeC4 sequence detail views drive per-component implementation
checklists. When implementing:

- Preserve checklists in docstrings.
- Check items off `[ ] → [x]` — NEVER modify the checklist text.
- Copy each checklist item as a comment with the implementing code
  directly below it.
- Once a checklist is fully complete, you may rename its title to
  `Procedure`.
