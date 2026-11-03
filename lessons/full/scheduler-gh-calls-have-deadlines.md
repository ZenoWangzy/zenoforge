# V1271: Give scheduler GitHub calls a deadline

Rule: [V1271](../RULES.md#v1271).

## Incident

A scheduler `gh pr list` call hung for 44 minutes. The tick remained stuck until `TICK-TIMEOUT`, and refill stayed locked out for 28 minutes. The scheduler wrapper called `command gh` directly without a timeout. The bounded-wrapper fix is tracked on branch `fix/scheduler-gh-timeout`.

## Root cause

The scheduler had its own `gh()` wrapper, separate from the engine's timed GitHub transport wrapper. It counted and logged calls but invoked the CLI directly, so a stalled network request could hold the scheduler lock until the much longer tick timeout.

## Chosen mechanism

The scheduler wrapper now invokes `gh_timeout` with a validated per-call limit and logs timeout events. `engine/mac-autopilot/scheduler.test.sh` proves a stalled CLI is killed and the timeout is logged. `engine/scheduler-gh-timeout-safety.mjs` scans scheduler and library shell sources for direct `command gh` calls; its test plants a bypass and requires rejection.

## Options considered

- Increase the whole tick timeout. This would extend the lockout window.
- Retry a hung call. Retrying without a deadline preserves the same unbounded wait.
- Put a bounded timeout in the shared scheduler wrapper and reject direct binary calls. This bounds each wait and prevents a new callsite from bypassing the wrapper, so it was selected.

## Enforcer

- `engine/scheduler-gh-timeout-safety.mjs`
- `engine/scheduler-gh-timeout-safety.test.sh`
- `engine/mac-autopilot/scheduler.test.sh`

## Research

- [GNU Coreutils `timeout`](https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html)
