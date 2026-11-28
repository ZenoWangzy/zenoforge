# Implement-stage review contract

Use the issue as source of truth. Write the machine-readable contract in your
report; the scheduler copies it into the PR. Do not create a contract file or
edit the PR. If optimization numbers fail to reproduce, make
`OBSOLETE: <measured numbers, window, data source>` the report's first line
instead of a contract.

**No change on purpose.** When you judge that the issue has no independently deliverable slice, or a prerequisite is missing, and you change nothing, make the first line of the report `NO-CHANGE: <reason>` with the reason in the same line. Use it only when the worktree has no commit and no edit; if you changed or committed anything, do not use it.

**Do the work yourself; do not start sub-agents.** Use no tool that spawns or messages another agent: a
sub-agent inherits your model and effort; 72 worker sessions in three days spawned 78, each a second worker's cost.

## Method: Matt skills

Implement the way Matt Pocock's `implement` skill does, driving `tdd` one
red-green slice at a time at the seams the ticket names (the line "Matt skill
files for this run" gives their paths). When the ticket is a defect or a red
check, read `diagnosing-bugs` first: a command that already goes red on this
exact failure comes before any fix, and the regression test sits at the seam
that command reaches. Nobody answers questions or confirms seams here, so
decide from the ticket and the code. Do not run `code-review` yourself: an
independent reviewer does.

## Check known failures first

If the repository has `lessons/CATALOG.md`, search it for the subsystem you are
changing before you edit, then read only the rules and write-ups it points to.
Do not read the whole lessons tree.

## Handle flaky tests

Do not skip a flaky test, add a sleep, retry it, or rerun it until it passes.
Find and fix its root cause. If the cause is unknown, keep the test and file
the evidence for diagnosis. Delete a test only if it is obsolete or invalid,
or a named test covers it.

## Verify an optimization premise before implementing

When a ticket quantifies waste, latency, or a race, reproduce its numbers from
existing evidence (issue, runs, ledgers, files, git history) before coding.
Measure after the mechanism's last change (find it with `git log`); a window
crossing it measures the old mechanism. Record the numbers and calculation.

- If numbers do not reproduce, do not implement. Make the report's first line
  exactly `OBSOLETE: <measured numbers, window, data source>` and let the
  pipeline close the issue. Name a file:line, a commit, or a run on current
  main as the data source; otherwise the report goes to review. No data is not
  OBSOLETE.
- If they reproduce, implement and report the measured before-baseline for
  acceptance.
- Name the limiter (step, operation, cost share) and target it. Prefer removing
  unused work, then restructuring, then copying data; justify a copy if the
  first two cannot work.

## Name the full verification command before coding

Before coding, name the command that fully verifies the change. If none
exists, build one, see it fail, then implement. Record its command and exit
code in `## decision-log`; add no report section or schema field.

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

Restate every issue criterion without weakening it. List intended files,
behavior changes, and tests added by this implementation; see each test fail
before its fix. Use empty arrays only for empty categories. Keep entries
specific enough to compare with the issue and diff; the contract does not
authorize behavior that conflicts with the issue.

Every implement report must also include non-empty `## how` and `## why`
sections. `## how` explains how the touched code works today. `## why` explains
why it was written that way and cites relevant commits by SHA (at least seven
hex characters) and linked issues as `#N` where available.

Every implement report must also include a non-empty `## decision-log` section:
what was tried, what failed and why, the final choice, and how it was verified.

For parseable `## Acceptance criteria`, add `## acceptance-criteria coverage`
with exactly columns `Acceptance criterion` and `Production call site (file:line)`,
one row per criterion. Copy each criterion verbatim; cite an existing production
`file:line` in the candidate branch. Omit the table if none parse.

Write no code comments: record a non-obvious decision in an ADR (docs/adr/) and file an issue for a shortcut.

When the incident rule applies, include its exact `## root-cause`,
`## recurrence-guard`, and `## prior-art` sections too. Under `## recurrence-guard`,
put `kind: <architecture|state|script|lint|test>` on its own line; when
`kind: test`, also put `escape-test: <package>/<test>` on its own line and
register it in the candidate head's `.zenoforge/state/escape-suites.json` by
running `node engine/mac-autopilot/scheduler.d/escape-suite-register.mjs --repo <checkout> --package <pkg> --test <path> -- <argv>`. Under
`## prior-art`, cite at least one direct `https://` URL; if it reports an
escalation, add one line exactly `Escalation reference: <https:// URL, #N, PR #N
or issue #N>`. The gate rejects other forms.
