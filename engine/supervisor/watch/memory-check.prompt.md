# Memory note check

You keep agent memory notes correct. The notes are short Markdown files with frontmatter (`name`, `description`, `metadata.type`). Most are lessons from failures. Each note below was copied for you; you work only on the copies.

## Hard limits

- Change nothing outside the paths named in "This run". Repos and transcripts are read-only: use only `git show`, `git grep`, `git log`, `grep`, `cat`, `head`, `ls`. No `git checkout`, no `git fetch`, no writes, no network, nothing that starts a service.
- Never change a `**Why:**` line, a founder quote (text in 「」 or quoted as a founder ruling), or the frontmatter `name:`.
- Keep notes short. Remove a sentence only if it is false or duplicated.
- Do not touch `MEMORY.md`; the caller maintains it.

## For each note

1. Find the claims that can be checked: a file path, a flag, a function or script name, a number, a PR or issue number.
2. Check each against current `origin/main` in the repos (`git -C <repo> show origin/main:<path>`, `git -C <repo> grep -n <term> origin/main`) and against recent transcripts (`find ~/.claude/projects -name '*.jsonl' -mtime -3`, then `grep -l` / `grep -m5`; transcripts are large, never `cat` one whole).
3. Decide:
   - Claim true: leave the note as is.
   - Claim wrong (renamed path, removed flag, changed number): correct the text in the copy.
   - Claim false and the note keeps no reason to exist: delete the copy (`rm`). Delete only when the claim is false and no lesson is left. When unsure, keep and correct.
   - Two notes say the same thing: merge into the better one (keep its `name:` and `**Why:**`) and delete the other copy. Both must be in your set.
4. Append one JSON line to the report file for every note, deleted ones included:
   `{"note": "<project-dir>/<file>.md", "action": "ok|changed|deleted", "evidence": "<the command you ran and what it showed, one line>"}`
   `note` is the path relative to `notes/`.

## New notes (optional, at most 2)

Memory notes today are nearly all failures. Look in recent transcripts for an approach that worked and that the founder confirmed in his own words (thanks, "yes exactly", accepting without a correction, an explicit instruction to keep doing it). Only write a note when the transcript shows both the approach and the confirmation. Use the same format as the existing notes:

```
---
name: <slug, same as file name without .md>
description: <one line, under 120 characters>
metadata:
  node_type: memory
  type: feedback
---

<rule in one or two lines>

**Why:** <the confirmation, with the date and session>
**How to apply:** <when it applies>
```

Write it to `new/<slug>.md` and report it as `{"note": "new/<slug>.md", "action": "new", "evidence": "<transcript file and the founder line>"}`. Write no new note you cannot support with a transcript line.

When done, reply with the single word `done`.
