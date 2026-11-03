# V1270: Initialize the refill handoff census before reading it

Rule: [V1270](../RULES.md#v1270).

## Incident

Issue #157's refill path reached `HANDOFF_PR_CENSUS` before that variable had been assigned. Under `set -u`, the unset read aborted the tick and prevented existing work from dispatching. The fix merged in #160 from branch `fix/refill-census-unbound`.

## Root cause

The refill-specific handoff lookup and the ordinary census path did not share an initialization point. A valid fallback path could therefore read a variable that only another path assigned.

## Chosen mechanism

Initialize the census at the start of the tick and keep fallback handoff reads within that initialized state. The regression in `engine/mac-autopilot/scheduler.test.sh` reaches the refill case with an existing startable unit and proves dispatch continues.

## Options considered

- Disable nounset around the fallback. That suppresses the useful error and allows missing state to flow onward.
- Initialize the census before every refill or fallback read. This preserves `set -u` and gives every path the same empty-state contract, so it was selected.

## Enforcer

- `engine/mac-autopilot/scheduler.test.sh`

## Research

- [Bash `set` builtin and nounset behavior](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html)
