# Implement-stage review contract

The current issue and its acceptance criteria are the source of truth. Before
handing off the implementation, write one machine-readable contract for the
reviewer. The scheduler copies this block from your report into the PR body;
do not create a contract file in the repository or try to edit the PR yourself.
A ticket closed under the optimization-premise rule below delivers the
`OBSOLETE:` first line instead of a contract block.

**Do the work yourself; do not start sub-agents.** Whatever tools you have for spawning or messaging
another agent, don't use them: a sub-agent inherits your model and effort, and 72 worker sessions in three days
spawned 78 of them, paying a second worker's tokens and CPU for one ticket.

## Method: Matt skills

Implement the way Matt Pocock's `implement` skill does, driving `tdd` one
red-green slice at a time at the seams the ticket names (the line "Matt skill
files for this run" gives their paths). When the ticket is a defect or a red
check, read `diagnosing-bugs` first: a command that already goes red on this
exact failure comes before any fix, and the regression test sits at the seam
that command reaches. Nobody answers questions or confirms seams here, so
decide from the ticket and the code. Do not run `code-review` yourself: an
independent reviewer does.

## Verify an optimization premise before implementing

When the ticket claims waste, latency or a race with quantified numbers, the
first step is to reproduce those numbers from data that already exists — the
issue's own evidence, recorded runs, ledgers, files and git history in this
checkout — before writing any code. The measurement window starts after the
last change to the mechanism the ticket measures (locate it with git log); a
window that crosses that change measures the old mechanism. Record the
measured numbers and how you computed them.

- The numbers do not reproduce: do not implement. Close the ticket with the
  measurement as evidence: the first line of the report is exactly
  `OBSOLETE: <measured numbers, window, data source>` and the pipeline closes
  the issue with that evidence.
- The numbers reproduce: implement, and carry the measured numbers in the
  report as the before-baseline that acceptance will compare against.

## Blast-radius proof on risk-class paths

Run `node engine/risk-class.mjs --json origin/main...HEAD`: `[]` means no
risk-class path and nothing below applies. Any hit means the report carries a
`## blast-radius` section, written the way
`engine/vendor/pstack/skills/blast-radius/SKILL.md` describes:

- **The one fact**: the single fact this change's safety depends on.
- **Affected surfaces**: the callers and surfaces the change reaches, each with
  the command that listed it and that command's real output.
- **Level-4 proof**: a small script that imports and calls the real function
  (not a copy, not a mock) and fails loud if the fact is wrong. Give the script
  path, the command, and its real output. A line reference or a walkthrough is
  level 2-3 and does not count; if you cannot reach level 4, write `unproven`
  and why.
- **Cheapest pre-merge repro**: the one command that would catch the bug.

Put the block first in the report so the scheduler can carry it into the PR
body. Use this exact JSON shape and the `contract` fence:

```contract
{
  "acceptance_criteria": ["..."],
  "intended_files": ["path/from/repo/root"],
  "behavior_changes": ["..."],
  "tests_added": ["path/from/repo/root: test or case"]
}
```

Restate every issue acceptance criterion without weakening it. List the files
you intend the diff to change, the observable behavior changes, and tests added
by this implementation, each one seen failing before the fix that makes it pass. Use empty arrays only when
that category has no items.
Keep each entry specific enough for a reviewer to compare with the issue and
diff. The contract describes intended work; it does not authorize behavior that
conflicts with the issue.
