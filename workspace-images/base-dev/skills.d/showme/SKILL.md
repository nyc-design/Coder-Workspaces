---
name: showme
description: Walk the user through code they did not understand by drawing on their open editor window with ShowMe (comment bubbles on the exact lines, files side by side, diagrams and notes) while explaining it in chat. Use only when the user invokes this skill by name or asks you to use ShowMe, typically after they have reviewed a walkthrough and want something clarified.
---

# ShowMe

The user invokes this skill when an explanation did not land, usually after they have played a walkthrough of your changes. Your job is to take them through the part they are stuck on, one point at a time, and to use their editor so their eyes are always on the code the point is about.

ShowMe gives you several ways to show something. Pick the one that gets the current point across; do not use a feature because it exists.

## Before you start

The `showme` command drives the ShowMe extension in an editor window. It reaches a window only in the workspace where the command runs, so the user attaches the workspace they are working in to this chat before invoking the skill.

1. Run `showme list_workspaces` from the repository root. It tells you which window you reached and what the user's settings allow.
2. If it reports that no window was found, ask the user to open the editor on this workspace. If it reports that ShowMe is off, ask them to click "ShowMe: Off" in the status bar so it reads "ShowMe: On". Only the user can turn it on; do not try to work around it.
3. Check that this checkout has the code you are about to explain: compare `git rev-parse HEAD` and the branch with the commits you have in mind. If the checkout is on different code, tell the user and agree what to do before going on.
4. Read every file again in this workspace before you point at it.

## Calling ShowMe

```sh
showme tools                 # the tools, one line each
showme tools annotate        # full description and argument schema of one tool
showme annotate '{"items":[...],"reveal":true}'
showme show_html - < /tmp/diagram-arguments.json     # "-" reads the JSON arguments from stdin
```

Arguments are one JSON object. Read `showme tools <tool>` before the first use of a tool in a chat; it is the authority on arguments and limits, and this skill does not repeat them.

Paths are relative to the repository root. Locate code by `text` (a literal string from the line) or `symbol` in preference to `lines`, so the mark lands in the right place even if the file has shifted.

## What each tool is for

| When the point needs | Use |
|---|---|
| The user's eyes on specific lines, with a sentence beside each | `annotate` with `reveal: true`. This is the main tool. Up to 20 bubbles per call, each with a required plain-text comment and a colour. |
| A file opened and scrolled to a place, with nothing drawn on it | `show_code` |
| Two places seen together, such as a caller and the function it calls, or a type and its use | `show_code` with `layout: "split"`, then `annotate` both |
| To find where a name the user asked about is defined or used | `find_definition`, `find_references`, then show the result |
| A relationship that code alone does not show: a flow, a sequence, a before-and-after table | `show_html` with a small diagram or table |
| A written recap the user can keep or edit | `show_note` |
| To know what the user is looking at, what they selected, or which bubbles they marked resolved | `get_editor_state` |
| The file's place in the project made visible, or the Comments panel listing your bubbles | `show_view` |
| The screen tidied when you are done, or columns arranged for a comparison | `arrange_editors` |

How to use them well:

- **Bubbles.** The comment in a bubble is a short label for the line: what this line does, in a sentence. The full explanation goes in chat. Bubble text is plain text, not Markdown.
- **Colours.** Give colours a meaning and keep it for the whole explanation, then tell the user what it is. For example: yellow for the line under discussion, blue for where a value comes from, green for where it ends up, red for the line that fails or is risky.
- **Modes.** `annotate` takes `mode`: `replace` clears your earlier bubbles and shows the new ones, `add` keeps them, `clear` removes them. Use `replace` when moving to a new point so the screen shows only that point. Use `add` when the point builds on the last and both should stay visible.
- **Diagrams.** Use `show_html` when the user is lost about how pieces connect, not for something a bubble can say. Keep it small: a few boxes and arrows, or a table of a few rows. Scripts do not run in the panel.
- **The user's tabs.** Open what the point needs and no more. Close only what you opened (`arrange_editors` with `close-own`). Do not close, move or rearrange the user's own tabs unless they ask.

## How to run the explanation

1. Find out what is unclear. If the user has not said, ask. If they say "this part" or "here", call `get_editor_state` and read their selection and active file.
2. Break the unclear part into the smallest points that each make sense alone, in the order the code runs. Tell the user how many points there are.
3. For each point:
   - Put the code on screen and mark exactly the lines the point is about. Mark as little as carries the point.
   - Explain the point in chat in plain language: what these lines do, why they are there, and what would go wrong without them. Use the names on screen, and refer to your marks ("the yellow line", "the blue bubble") so the user can match your words to the code.
   - Stop and wait for the user. Show one point per turn.
4. When the user replies, call `get_editor_state` if it helps: a selection shows what they are asking about, and a bubble they marked resolved is a point they have understood. If they follow, move on. If they do not, explain the same lines a different way: trace a concrete value through them, put the code it depends on beside it, or draw the flow.
5. If a point depends on code elsewhere, say you are going there, show it beside the current code where that helps, and come back.
6. When the user has what they need, clear your bubbles (`annotate` with `mode: "clear"`) and close what you opened (`arrange_editors` with `close-own`). If they would like a record, offer a recap with `show_note`.

Do not go on to the next point in the same turn, and do not put the whole explanation on screen at once.

## Limits

- ShowMe hides files that look like secrets, such as `.env` and key files, and refuses to open them. Do not try to get around that.
- It points at files inside the workspace only, unless the user has turned on access outside it.
- If a call is refused, the message says why and often names the user setting involved. Tell the user what was refused; do not retry with a different tool to get the same effect.
