---
name: highlight
description: Walk the user through code they did not understand by highlighting one line or block at a time in their open editor window and explaining it in chat. Use only when the user invokes this skill by name or asks you to highlight code for them while explaining it, typically after they have reviewed a walkthrough and want something clarified.
---

# Highlight

The user invokes this skill when an explanation did not land, usually after they have played a walkthrough of your changes. Your job is to take them through the part they are stuck on, one point at a time, and to put a highlight on the exact line or block each point is about so they never have to hunt for it.

The highlight shows where to look. The explanation goes in chat.

## Before you start

The `highlight` command drives the Code Walkthrough extension in an editor window. It reaches a window only in the workspace where the command runs, so the user attaches the workspace they are working in to this chat before invoking the skill.

1. Run `highlight where`. If it reports that there is no Code Walkthrough server, ask the user to open the editor on this workspace and check that the status bar shows "Walkthrough MCP". Do not try to work around it.
2. Check that this checkout has the code you are about to explain: compare `git rev-parse HEAD` and the branch with the commits you have in mind. If the checkout is on different code, tell the user and agree what to do before going on.
3. Read every file again in this workspace before you point at it. Line numbers remembered from another workspace or from earlier in the chat may be wrong here.

The user should have one editor window open on the workspace. With two, the highlight can land in the one they are not looking at; if they say nothing appeared, ask about a second window or tab.

## Commands

| Command | What it does |
|---|---|
| `highlight <file> <start> [end] [--note TEXT] [--status TEXT]` | Opens the file, scrolls to the lines and highlights them. `end` defaults to `start`. |
| `highlight clear` | Removes the highlight and the status text. |
| `highlight where` | Prints the active file, the user's selection and the current highlight. |
| `highlight symbols <file>` | Prints the file's functions and classes with their line ranges. |

- Line numbers are 1-based and the range includes both ends.
- There is one highlight at a time. A new one replaces the last.
- A call occasionally times out. Run it once more before telling the user.
- `highlight symbols` returns an empty list for languages the editor has no language extension for, such as shell scripts. Read the file for line numbers instead.
- `--note` attaches a short label to the highlight, and `--status` sets a short text in the status bar. Keep both to a few words, such as "2 of 5: the retry loop". They are labels, not the explanation.

## How to run the explanation

1. Find out what is unclear. If the user has not said, ask. If they say "this part", run `highlight where` and read their selection or the active file.
2. Break the unclear part into the smallest points that each make sense alone, in the order the code runs. Tell the user how many points there are.
3. For each point:
   - Highlight only the lines the point is about. Prefer three lines to thirty. If a whole function matters, highlight its signature first and then go through its body in further points.
   - Explain that point in chat in plain language: what these lines do, why they are there, and what would go wrong without them. Use the names on screen so the user can match your words to the code.
   - Stop and wait for the user. Make one highlight per turn.
4. When the user replies, do what the reply calls for. If they follow, move to the next point. If they do not, explain the same lines a different way, for example with a concrete value traced through them, or by highlighting the place the value comes from and returning.
5. If a point depends on code elsewhere, such as a caller, a helper or a type, say you are going there, highlight it, explain it, and come back to where you were.
6. When the user has what they need, run `highlight clear`.

Do not go on to the next point in the same turn, and do not highlight several places in a row before explaining any of them.

## When this is the wrong tool

Highlight shows one range and no text beside the code. If the user needs several places marked at once, a comment next to each line, or two files side by side, tell them the showme skill does that and let them choose. Do not switch on your own.
