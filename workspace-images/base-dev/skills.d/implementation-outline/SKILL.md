---
name: implementation-outline
description: Outline a non-trivial function or endpoint as step comments in its body and agree that outline with the user before writing the code. Use before implementing or substantially rewriting a function, endpoint, or handler, and when the user asks for an outline, steps, or a procedure first.
---

# Implementation outline

A non-trivial function or endpoint gets its steps written as comment lines in the function body, and the user agrees those steps before any of the code is written. The comments stay in the finished code, each one sitting directly above the code that carries it out.

## When to use

Use this for a function or endpoint with several distinct steps, branches, or side effects, whether it is new or being substantially rewritten.

Skip it for trivial code: single-expression helpers, accessors, pass-through wrappers, and mechanical edits such as renames or moved code.

## Process

1. Find the steps. If the project has a LikeC4 sequence detail view covering this function, take the steps from it (see the likec4-modeling skill). Otherwise derive them from the requirements and the surrounding code.
2. Write the outline in place: the signature, the docstring, and the steps as comment lines in the body. Write no implementation yet, beyond whatever placeholder the language needs for the file to parse.
3. Show the outline to the user and settle it with them. Do not write the implementation until they agree.
4. Implement each step directly under its comment. Leave the comment where it is.
5. Report what was implemented against the agreed outline, including any step that changed along the way.

When several functions belong to one task, outline all of them and settle them together rather than one round per function.

If the run is unattended and nobody can answer (for example a task dispatched from a GitHub issue), write the outline, implement it, and include the outline in the PR description so it can be reviewed there.

## Outline format

- One comment per step.
- Steps are unnumbered.
- Each step is a single line, however long it needs to be. Do not wrap it.
- Leave a blank line between steps.

## Writing a step

The user settles the design by reading the outline, so each step has to be understandable on its own, without reading the code or guessing what a short label stands for.

- Write each step as a full sentence in plain, simple language.
- Give the detail a reader needs to judge the step: what it acts on, where that comes from, any condition or rule it applies, and what happens when it fails or finds nothing.
- Do not shorten a step to save space. A terse label such as "Validate input" or "Dedupe" leaves the reader to guess what is checked and what happens next. A long line is fine.
- Use the names the user knows from the product and the codebase. Avoid abbreviations and labels you made up while working.
- Describe what happens at that point in the function and why it matters there. Do not restate the line of code below it.

Too terse:

```python
    # Dedupe tracks
```

Clear:

```python
    # Remove every track the user already has in their library, comparing by track ID, so the import never creates duplicates
```

## Docstrings

A docstring describes what the function does and nothing else. It holds no step list and no checklist; the steps live in the body.

Do not hard-wrap docstrings or comments. Write each paragraph as one line and let the editor wrap it.

## Changing an agreed outline

Once the user has agreed an outline, its wording is theirs. Do not reword a step without saying so.

If the implementation shows that a step is wrong, missing, or in the wrong order, say what needs to change and why, then change it. The same applies later when editing a function that already has an outline: keep its step comments, and name any step you add, remove, or reword.

## Example

The outline, as shown to the user:

```python
async def import_playlist(user_id: str, source_url: str) -> ImportResult:
    """Import a playlist from an external service into the user's library, skipping tracks the user already has."""

    # Fetch the playlist's title and full track list from the external service the URL points to, and stop with a clear error if the playlist is private or no longer exists

    # Remove every track the user already has in their library, comparing by track ID, so the import never creates duplicates

    # Look up each remaining track in our own catalog, keeping the tracks we could not find in a separate list instead of dropping them

    # Save the tracks we found as a new playlist owned by the user, named after the original playlist

    # Return the new playlist together with the list of tracks we could not find, so the caller can show the user what was left out
```

The same function once the outline is agreed and implemented:

```python
async def import_playlist(user_id: str, source_url: str) -> ImportResult:
    """Import a playlist from an external service into the user's library, skipping tracks the user already has."""

    # Fetch the playlist's title and full track list from the external service the URL points to, and stop with a clear error if the playlist is private or no longer exists
    source = await source_client.fetch_playlist(source_url)

    # Remove every track the user already has in their library, comparing by track ID, so the import never creates duplicates
    owned = await library.track_ids(user_id)
    candidates = [track for track in source.tracks if track.id not in owned]

    # Look up each remaining track in our own catalog, keeping the tracks we could not find in a separate list instead of dropping them
    matches = await catalog.match_tracks(candidates)

    # Save the tracks we found as a new playlist owned by the user, named after the original playlist
    playlist = await library.create_playlist(user_id, source.title, matches.found)

    # Return the new playlist together with the list of tracks we could not find, so the caller can show the user what was left out
    return ImportResult(playlist=playlist, unmatched=matches.missing)
```
