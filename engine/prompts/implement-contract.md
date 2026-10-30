# Implement-stage review contract

The current issue and its acceptance criteria are the source of truth. Before
handing off the implementation, write one machine-readable contract for the
reviewer. The scheduler copies this block from your report into the PR body;
do not create a contract file in the repository or try to edit the PR yourself.
A ticket closed under the optimization-premise rule below delivers the
`OBSOLETE:` first line instead of a contract block.

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
by this implementation. Use empty arrays only when that category has no items.
Keep each entry specific enough for a reviewer to compare with the issue and
diff. The contract describes intended work; it does not authorize behavior that
conflicts with the issue.
