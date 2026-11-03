# V1268: Compile literal jq patterns before relying on fixtures

Rule: [V1268](../RULES.md#v1268).

## Incident

Issue #156 used an unbalanced regular expression in a jq `test()` call. The existing fixtures reached that filter only when a particular history entry existed, so the malformed pattern escaped ordinary coverage. The expression was corrected in commit `22e253d` and a regression case was added to `engine/mac-autopilot/scheduler.test.sh`.

## Root cause

The suite tested the data path that happened to use the expression, but never asked jq to compile every literal regex in the shell sources. A branch-specific fixture therefore controlled whether jq parsed the bad pattern.

## Chosen mechanism

`engine/jq-regex-safety.mjs` extracts literal patterns passed to jq's `test()`, `match()`, `capture()`, `sub()` and `gsub()` filters in every engine shell file, then compiles each with jq. `engine/jq-regex-safety.test.sh` plants an unbalanced expression and requires the checker to reject it. The regular test discovery in `tools/run-engine-tests.sh` runs the check.

## Options considered

- Add a fixture for the specific history row. This covers the known branch but leaves other literals dependent on test data.
- Compile every literal pattern with jq. This checks syntax regardless of which fixture branch runs, so it was selected.

## Enforcer

- `engine/jq-regex-safety.mjs`
- `engine/jq-regex-safety.test.sh`
- `engine/mac-autopilot/scheduler.test.sh`

## Research

- [jq regular-expression filters](https://jqlang.org/manual/#regular-expressions)
