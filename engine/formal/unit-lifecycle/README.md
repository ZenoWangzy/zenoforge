# Unit lifecycle and merge-lane model

The lifecycle model checks that each ledger row has one declared stage and that every non-terminal stage can reach a terminal stage. The merge-lane model checks that the full tick, refill and station callers never run overlapping passes.

Run `bash engine/formal/unit-lifecycle/verify.test.sh` in CI for the real-code replay and table drift check. Run `bash engine/formal/unit-lifecycle/verify-model.sh` for TLC plus replay; it exits 2 with `BLOCKED` when TLC is unavailable. Set `VERIFY_TRACE=1` to print TLC counterexample traces.

To run TLC, set `TLA_HOME` to a directory containing `jre/bin/java` and `tla2tools.jar`.

## Model to code

| Model | Code |
|---|---|
| `Stages`, `Initial`, `Escalation`, and `Edges` | `engine/state/scheduling-policy.json` `state_machine`; `gen-edges.sh` generates the TLA+ edge block and `table-drift.test.sh` checks it. |
| `Terminal` | `SCHEDULER_UNIT_TERMINAL_STAGES` in `engine/lib.d/dispatch-gates.sh`. |
| `ExactlyOneStage` | Ledger row shape and unique ids checked by `state_schema_ok` in `engine/mac-autopilot/scheduler.d/locks-views.sh`. |
| `Move` and `LegalEdge` | Stage table with escalation allowed from non-legacy stages. |
| `Try`, `Take`, `Skip`, `Release` | `run_merge_lane` flock and its tick, refill and station callers in `engine/mac-autopilot/scheduler.sh` and `engine/mac-autopilot/scheduler.d/merge-lane.sh`. `Release` covers both normal completion and process exit, which both release the flock. |
| `OnePass` | `run_merge_lane_pass` is called only inside the held lane lock. |

## Configurations and results

| Config | World | Expected TLC result |
|---|---|---|
| `lifecycle` | Current scheduling policy, two units | PASS |
| `merge-no-lock` | Three callers with the lane lock disabled | FAIL: two callers can enter a pass together |
| `merge-flock` | Three callers with the lane flock enabled | PASS |

The lifecycle result reflects the current policy: #1053 made the four active worker stages non-legacy, so each has an allowed escalation path to a terminal stage. The older #1055 guide's expected `WayOut` finding no longer reproduces. The `merge-no-lock` failure is the model's intentional control case; the real callers use the lock.

## Scope

The replay covers the three `run_merge_lane` callers and the one call to `run_merge_lane_pass`. `engine_batch_land` runs after the station lane and is outside this model. The merge command's second lock is also outside scope.
