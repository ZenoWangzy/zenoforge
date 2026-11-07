# Owner report: causes of material changes

The founder reads one daily report. Some figures moved a lot against yesterday. `material.json` lists them: `line` (the key you must echo), `label`, `now`, `yesterday`, `change`, and `scorecard_rows` (scorecard metric ids that relate to the line). For each one, find out from local records why it moved, and write the cause in plain Chinese with the evidence you read. If you cannot trace it, write no row for it: the report then says 未查明, which is correct.

## Hard limits

- Read only: the copied snapshots, the files named below, and `git log` / `git show` / `git grep` on the repos in "This run". No network, no `gh`, no production access, no writes outside the output file, nothing that starts a service.
- Allowed local records, under the runtime directory named in "This run": `scheduler.log`, `alerts/events.md`, `alerts/node-health.md`, `units.json`, `units-archive.json`, `station-health.json`, `node-health.json`. Under the agent home: `logs/triage-triage-batch-*.log`, `logs/advisor-batch-*.result.json`, `logs/head-watch.alerts`, and `spend/*.log`.
- Never open `notify.log`, `recipients.json`, `mails/`, `engine.env`, anything named like a key, token, secret or credential, `~/.config`, `~/.ssh`, or any other file. They hold addresses and secrets. If a line you read contains an address or a token, leave it out of everything you write.
- Budget: at most 6 commands per change. Use `grep -c`, `grep -m`, `tail -n`, `head -n`. Never read a log whole.

## What counts as a cause

- A cause is something the records show, not something that happened at about the same time. "A change landed that day" is not a cause. "The scheduler log shows 41 merge lines yesterday and 12 today, and the merge queue was paused for 9 hours" is a cause, with the numbers.
- If the only link you have is timing, write no row.
- The cause text is one sentence in plain Chinese a non-technical owner can read: at most 60 characters, no Latin letters, no `#` number, no file name, no commit id, no address. Say what happened in the factory in words (for example: 合并队列停了九个小时，所以合入变少).
- The evidence is one line for the head, not for the owner. It names what you read and the numbers it showed: a file path (with `~` or an absolute path), or a scorecard metric id, or a line count, plus at least one number from that source (clock times and dates do not count as numbers). Example: `scheduler.log: 41 merged lines on the day before, 12 today; PAUSE marker 9 h`. No address, no `#` number in the evidence either.

## Output

For each change you could trace, append one JSON line to the output file:

`{"line": "<line from material.json>", "cause": "<one plain Chinese sentence>", "evidence": "<what you read and the numbers>", "basis": "read"}`

Write `"basis": "read"` only when a record you read shows the cause. Never write a row with basis anything else. At most one row per line. The caller keeps only rows that pass its own check (evidence with a source and a number, a plain-Chinese cause, no wording of mere timing) and drops the rest.

When done, reply with the single word `done`.
