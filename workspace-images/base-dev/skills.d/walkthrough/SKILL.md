---
name: walkthrough
description: Write a step-by-step walkthrough of a code change to .walkthrough/, played back in the Agent Walkthrough editor extension and kept in the repository as a record of what was built and why. Use only when the user asks for a walkthrough, or asks to apply walkthrough feedback or review comments from a .feedback.yaml file. Also use when the user asks why something was built a certain way and the repository has a .walkthrough/ folder to search.
---

# Walkthrough

A walkthrough is a YAML file in `.walkthrough/` at the repository root. The user plays it back in the editor with the Agent Walkthrough extension, one step at a time, and can leave comments on it.

Walkthroughs are committed. They are the record the user comes back to months later to find out why something was built the way it was, so each one has to be easy to find and has to make sense to someone who has forgotten the conversation that produced it.

Write one only when the user asks. Do not write one at the end of a session on your own initiative.

This skill has three jobs: write a walkthrough, apply the user's feedback on one, and find an old one.

## Write a walkthrough

1. Find the changes. Run `git diff <base>`, where `<base>` is the commit the work started from. For work on a branch that is usually `git merge-base HEAD origin/<default branch>`. Include untracked files you created (`git status --porcelain`). If the user asked for a walkthrough of something narrower or older, such as one commit or one pull request, use that range instead.
2. Commit the code first if it is not committed, so the walkthrough can name the commits it describes.
3. Group the changes into steps. One step covers one logical unit, such as a route, a function, a query or a type. Do not make a step per line or per hunk. Imports and formatting do not need a step of their own unless they matter.
4. Order the steps by execution flow. Follow the path a request or call takes: entry point, then handler, then domain logic, then data access, then helpers. Put a type or a piece of configuration just before the first step that uses it.
5. Write `.walkthrough/<session>.yaml` in the format below.
6. Add a row for it to `.walkthrough/README.md` (see "The index").
7. Commit the walkthrough and the index together in one commit of their own, after the code they describe, and push. Use a message such as `docs(walkthrough): order cancellation`.
8. Tell the user the file path and that they open it with the command "Walkthrough: Open…" in the editor.

### File name

`<session>` is `YYYY-MM-DD-<slug>`, using today's date.

The slug names the feature or the behaviour that changed, in words the user would search for later: `order-cancellation`, `extension-install-lock`, `playlist-import-dedupe`. Do not use a slug that only describes the activity, such as `fixes`, `refactor`, `review-changes` or `session-2`.

Never overwrite another walkthrough. If the name is taken, add `-2`.

### Format

```yaml
version: 1
title: <one line: what was built or changed, naming the feature>
summary: |
  <see "Summary" below>
base_commit: "<SHA of <base>>"       # quoted, so YAML keeps it a string
head_commit: "<SHA of the last commit this walkthrough describes>"
steps:
  - title: <one-line name of the step>
    file: <path relative to the repository root, forward slashes>
    lines: [<start>, <end>]          # 1-based, inclusive, current file contents
    anchor: "<the first line of the range, copied verbatim>"
    why: |
      <1 to 4 sentences: what this code does and why it was written this way.>
```

Use only these fields. The extension reads this format; lookup information goes in the title, the summary and the index, not in new fields.

### Summary

The summary is shown before step 1, and it is what a reader finds when they search the folder later. Markdown is allowed. Write it for someone who has no memory of the session, in this order:

- **What changed and why.** Two to five sentences: the problem or request that led to the change, and how the pieces of the change fit together.
- **Decisions.** Each choice that was not obvious, with the alternative that was rejected and the reason. This is the part the user comes back for, so do not leave it out or shorten it to a label.
- **Where it lives.** The branch, the pull request number or issue if there is one, and the main files or areas touched.
- **Not done.** Anything left untested, unfinished or deliberately out of scope.

Use the names the user knows from the product and the codebase, and spell out anything you abbreviated while working. A reader searching for a feature name or a file name should find it in the summary.

### Rules for steps

- `lines` must match the file as it is on disk now. Read the file again to get them. Do not work them out from the diff.
- `anchor` is copied character for character from the first line of `lines`, or from the first two or three lines if the first is not distinctive. Start the range on a distinctive line such as a signature or a route string, not on `}` or `return x;`.
- Every changed hunk should fall inside a step. The extension lists changed lines that no step covers.
- Use at most 15 steps. If the change needs more, write two walkthroughs split along a natural boundary and say so in both summaries.
- `why` explains intent, not syntax; the code is on screen. Name the alternative you rejected when the choice is not obvious.
- If something is a workaround, untested or a guess, say so in `why`.
- Refer to another step as `[#3]` or `[label][#3]`. Only `https://` links are shown as links.

### The index

`.walkthrough/README.md` lists every walkthrough, newest first, so the right one can be found without opening each file. Create it if it does not exist:

```markdown
# Walkthroughs

Step-by-step records of changes, played back with the Agent Walkthrough extension ("Walkthrough: Open…").

| Date | Walkthrough | What changed | Areas | PR |
|---|---|---|---|---|
| 2026-09-27 | [order-cancellation](2026-09-27-order-cancellation.yaml) | Customers can cancel a pending order; paid orders are refunded first | `src/orders/`, `src/payments/refund.ts` | #212 |
```

Add the new row directly under the header row. "What changed" is one plain sentence. "Areas" lists the main folders or files. Leave "PR" empty if there is none yet, and fill it in when the pull request exists.

## Apply feedback

Each walkthrough has a feedback file beside it: `.walkthrough/2026-09-27-order-cancellation.yaml` has `.walkthrough/2026-09-27-order-cancellation.feedback.yaml`. The user's comments from the editor are saved there.

When the user asks you to apply walkthrough feedback or review comments:

1. Pick the walkthrough. Use the one the user names. If they name none, use the newest walkthrough whose feedback file has `status: open` entries, and tell the user which one you picked. Read and change only that walkthrough's feedback file.
2. Read the feedback file:

   ```yaml
   version: 1
   entries:
     - id: fb-...
       step: 3
       file: src/orders/service.ts
       lines: [28, 30]
       anchor: 'if (order.status !== "pending") {'
       comment: <the user's request>
       status: open
       created: 2026-09-27T14:15:02Z
   ```

3. For each entry with `status: open`, in order: open `file` around `lines`, make the requested change, or explain why you did not. The lines may have moved; search for the entry's `anchor`, or the step's `anchor` in the walkthrough, to find them again.
4. Set each handled entry's `status` to `applied`. Change only that field. Do not delete entries, edit other fields or rewrite the file; the user's editor may be adding comments to it at the same time.
5. If the changes were substantial, ask the user whether they want a new walkthrough for them.
6. Commit the feedback file with the changes it led to, so the record keeps the comment next to its outcome.
7. Reply with one line per entry: what you changed, or why you left it.

## Find an old walkthrough

When the user asks why something was built a certain way, or asks for the walkthrough of some past work:

1. Read `.walkthrough/README.md` and pick the rows whose description or areas match.
2. If the index does not settle it, search the folder for the feature name, file path or symbol: `grep -ril "<term>" .walkthrough/`. Step entries name the files they cover, so a file path finds every walkthrough that touched it.
3. Read the matching file's summary and the relevant steps, and answer from them. Say which walkthrough you used.
4. Line numbers in an old walkthrough describe the code as it was at `head_commit` and may no longer match. Use `git show <head_commit>:<file>` to see the code the step describes, and say so if the code has changed since.

## Credit

The file format and the feedback flow come from the upstream skill at `github.com/mepolabs/agent-walkthrough` (MIT). This copy changes when a walkthrough is written and adds the naming, summary and index rules.
