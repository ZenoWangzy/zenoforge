---
name: verify-dispatch-claim
description: Check a change to the scheduler's implement dispatch claim (coord.sh claims, dispatch(), refill dispatch, worker harvest and orphan recovery) against the TLA+ model and the real-code replay. Use when a diff touches the covered files listed below.
---

# Verify the dispatch claim

Property: one ticket never has two implement units at once. Background, install and results: `README.md` in this directory.

## Covered files

- `engine/coord.sh`
- `engine/mac-autopilot/scheduler.d/dispatch.sh`
- `engine/mac-autopilot/scheduler.d/harvest-workers.sh` (`harvest_workers`, `recover_orphans`, `coord_scheduler_live_worker`)
- `engine/mac-autopilot/scheduler.d/dispatch-queue.sh` (`dispatch_pending`, refill flag)
- `engine/mac-autopilot/scheduler.sh` (`refill_tick`)

All of them sit under the `^engine/` control-surface rule in `engine/state/risk-paths.json` already; no separate entry is needed.

Sync commit: c6a585513b317c5aa0b5902bc145703486923316 (verify.test.sh and replay.test.sh matched the covered code there). `git diff c6a585513b31 -- <covered files>` shows what changed since.

## Steps

1. If the diff touches no covered file, stop: not affected.
2. Run `engine/formal/dispatch-claim/verify.test.sh`. Exit 2 means TLC is missing: install per README, or report blocked.
3. Exit 0: the result equals the recorded expectations (this includes the open finding F1, `refill-pr-guard: LAUNCHED`). If the diff changed what the model describes (new check, new claim step, new requeue path) but results still match, update `DispatchClaim.tla` and `replay.test.sh` first, then re-run.
4. Exit 1: read the printed line.
   - `TLC ...: FAIL (expected PASS)` or a `REPLAY ... CHANGED` line where a guard went HELD to LAUNCHED: the code now breaks the property. That is a bug: report it with the replay output as the reproduction. Do not edit the expectations to make it pass.
   - A guard went LAUNCHED to HELD, or `refill-gap` became PASS: the code was fixed or hardened. Confirm with `VERIFY_TRACE=1` and the replay, then update `EXPECTED_TLC` / `EXPECTED_REPLAY` in `verify.test.sh` and the README table in the same change.
   - Replay prints `setup failed`: the stubs in `replay.test.sh` no longer match `dispatch()`; fix the replay.
5. Report one of: in sync (no relevant change, checks pass), updated (model/replay changed with the code, checks pass), bug (code violates the property), blocked (TLC missing or model cannot be synced).
6. Move the sync commit above to the commit you verified only after step 3 or 4 confirms the model describes that code.

Read each TLC counterexample with the vendored `statechart` skill (`pstack_skill_md statechart` in `engine/matt-skills.sh`); copy none of its commands here.

## Break check

Copy `coord.sh` and `mac-autopilot/scheduler.d/` to a scratch dir, remove the guard (for example prefix the `jqf -e --arg issue` condition in `dispatch.sh` with `false &&`), then run `FORMAL_AGENT_DIR=<scratch> verify.test.sh`. It must exit 1 with `slow-pr-guard: LAUNCHED`. Nothing is edited in the repo.
