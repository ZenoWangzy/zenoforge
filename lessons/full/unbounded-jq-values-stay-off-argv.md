# V1269: Keep unbounded jq values off argv

Rule: [V1269](../RULES.md#v1269).

## Incident

Issue #157 cached candidate rows containing issue bodies and passed the full serialized value to jq through `--arg`. With about 100 large bodies, process creation failed with `Argument list too long`. Commit `e4a748c` changed the cache write to stream rows through stdin and added a large-row regression case.

## Root cause

`--arg` places its value in a single argument string. Linux limits each argument string as well as the total argument and environment size, so a list that grows with fetched issue bodies can exceed the per-string limit.

## Chosen mechanism

The cache writer streams the serialized rows to jq with `-Rs`. The `engine/jq-arg-safety.test.sh` lint now treats `rows` as an unbounded data name and proves that `--arg rows "$rows"` is caught. `engine/mac-autopilot/scheduler.test.sh` retains the #159 regression with more than 2 MiB of fixture rows.

## Options considered

- Truncate bodies before building the cache. This loses source data and can still overflow as row counts grow.
- Split the list into smaller argv values. This adds batching and reassembly without removing the argument-size hazard.
- Stream the value to jq and keep a name-based lint for unbounded payload variables. This avoids argv limits and fits the repository's existing lint style, so it was selected.

## Enforcer

- `engine/jq-arg-safety.test.sh`
- `engine/mac-autopilot/scheduler.test.sh`

## Research

- [Linux `execve(2)` argument limits](https://man7.org/linux/man-pages/man2/execve.2.html)
- [jq command-line arguments](https://jqlang.org/manual/#invoking-jq)
