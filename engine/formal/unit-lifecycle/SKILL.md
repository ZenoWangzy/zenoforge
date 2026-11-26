---
name: verify-unit-lifecycle-and-merge-lane
description: Check changes to the unit stage table or the merge lane against their TLA+ models and real-code replay.
---

# Verify unit lifecycle and merge-lane exclusion

The model and replay scope are in `README.md`.

## Covered files

- `engine/state/scheduling-policy.json`
- `engine/mac-autopilot/scheduler.d/units.sh`
- `engine/mac-autopilot/scheduler.d/unit-transition-log.sh`
- `engine/mac-autopilot/scheduler.d/locks-views.sh`
- `engine/mac-autopilot/scheduler.d/merge-lane.sh`
- `engine/mac-autopilot/scheduler.sh`
- `engine/lib.d/dispatch-gates.sh`

## Checks

1. Run `bash engine/formal/unit-lifecycle/verify.test.sh` for real-code replay and table drift.
2. Run `bash engine/formal/unit-lifecycle/verify-model.sh` when TLC is installed.
3. If TLC reports an unexpected result, keep the printed result and trace; do not change the expected result to hide it.
4. If a new runtime caller enters the merge lane, update the model and replay expectations in the same change.
