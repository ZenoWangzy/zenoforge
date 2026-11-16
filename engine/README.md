# engine/

The Zenoforge pipeline engine. Start with the repository docs:

Any agent session that sees a problem must file it through `bash engine/pipeline-issue-upsert.sh --class stable-problem-slug --title "Short problem title" --body-file evidence.md --lane pipeline-system --label incident`; include the observed evidence in the body and reuse the same class for follow-up evidence so it updates the open incident issue handled by the pstack root-cause rules.

`engine/engine-stall-issue.sh` (run by `bell.sh` each beat) files the same kind of issue by itself, class `engine-stall-<kind>`, when a stall kind in the supervisor alert log repeats; it sends counters only, never log content, and is rate limited by a per-class cooldown and a global minimum gap.

- [Architecture](../docs/architecture.md)
- [Installing on one host](../docs/install.md)
- [Security](../SECURITY.md)

## For supervisors

Change an issue's stage labels only through `bash engine/bin/zf-issue-transition [--dry-run] <issue> <to-state> <reason>`; a raw `gh issue edit` leaves the engine's state cache stale, and later transitions refuse.
