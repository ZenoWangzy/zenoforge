# Memory note check

You keep agent memory notes correct. The notes are short Markdown files with frontmatter (`name`, `description`, `metadata.type`). Most are lessons from failures. Each note below was copied for you; you work only on the copies.

## Hard limits

- Change nothing outside the paths named in "This run". Repos and transcripts are read-only: use only `git show`, `git grep`, `git log`, `grep`, `cat`, `head`, `ls`, and read-only `systemctl --user is-active|is-enabled|cat|status`. No `git checkout`, no `git fetch`, no writes, no network, nothing that starts a service.
- Never change a `**Why:**` line, a founder quote (text in 「」 or quoted as a founder ruling), or the frontmatter `name:`.
- This job only corrects a false token: a path, flag, function name or number. Do not reword, shorten, merge, reorder or reinterpret anything. The caller refuses a rewrite that changes more than 3 lines, any line that differs much from its original, and any change to `description:`, `name:`, a `**Why:**` block or a `**How to apply:**` block (the refused diff is only recorded as a proposal for a human). Put a fix you cannot make that way in the report as `"action": "ok"` with the finding in `evidence`.
- Do not delete a note that has a `**Why:**` or `**How to apply:**` block or a founder quote; the caller refuses it. Delete only a note without those whose claim is false and that has no reason left.
- Authority for rulings and policy is the live file `~/.vecta-agent/founder-policy.json`, never the copy in a repo (`.zenoforge/supervisor/founder-policy.json` can be stale and inactive). A note that agrees with the live file is right even if a repo copy says otherwise.
- A claim about a running service, timer or unit is checked on this host with `systemctl --user is-active <unit>` or `systemctl --user cat <unit>`, not only in git.
- Absence from a repo is not proof that a note is wrong: notes also describe the host, the founder's rulings and sessions. Only a positive finding that a token is wrong justifies a change.
- Do not point a note at a different file or source than it names; correct the token inside it.
- Do not touch `MEMORY.md`; the caller maintains it.

## For each note

1. Find the claims that can be checked: a file path, a flag, a function or script name, a number, a PR or issue number.
2. Check each against current `origin/main` in the repos (`git -C <repo> show origin/main:<path>`, `git -C <repo> grep -n <term> origin/main`) and against recent transcripts (`find ~/.claude/projects -name '*.jsonl' -mtime -3`, then `grep -l` / `grep -m5`; transcripts are large, never `cat` one whole).
3. Decide:
   - Claim true: leave the note as is.
   - Claim wrong (renamed path, removed flag, changed number): replace only that token in the copy, in a line outside the protected parts.
   - Claim false, no `**Why:**`, `**How to apply:**` or founder quote, and no lesson left: delete the copy (`rm`). When unsure, keep.
   - Two notes say the same thing: report it in `evidence`; do not merge or delete.
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
