Refs queue row 185

## Summary

A due quarantine canary remains reserved until an advisor provider job actually starts. The provider charges it after the job-start helper succeeds. The advisor wrappers no longer charge reservations on exit, so an unconfigured provider, model-failure backoff, or other pre-job exit leaves the canary count and schedule unchanged. A failed job launch also remains uncharged.

Advisor child and batch launches carry only their reserved advisor scopes. Blocker requeues persist the reserved scope until the scheduler worker-start bridge consumes it.

## Evidence

- The review finding was verified at `85255f6cba5f`: the single advisor EXIT trap charged a reservation on pre-job exits, and the batch trap could charge before its cleanup trap replaced it.
- `engine/run-advisor.test.sh` now expects `.canaries == 0` for the unconfigured-provider skip. This test change is by design: no provider job exists, so no canary is charged.
- `engine/run-advisor-batch.test.sh` exercises the batch-to-provider dispatch path and verifies a started job changes canaries from 0 to 1.
- `engine/lib.test.sh` reserves a due triage scope during advisor child dispatch, making the scope-isolation assertion fail if the child receives all reserved scopes.
- No baseline was raised.

Local receipts at head `e1b02ae842f3f00471f244214c69bfe3fdecb0d4`:

- `engine/run-advisor.test.sh` — `r=0`
- `engine/run-advisor-batch.test.sh` — `r=0`
- `engine/lib.test.sh` — `r=0` (1521 assertions)
- `engine/mac-autopilot/scheduler.d/dispatch-live-cache.test.sh` — `r=0`
- `engine/size-ratchet.test.sh` — `r=0`

`engine/mac-autopilot/scheduler.test.sh`, `engine/mac-autopilot/scheduler-gates.test.sh`, and `node engine/focused-test-paths.mjs` are covered by PR CI; engine-tests runs every suite in eight shards.

## Merge Danger

**Door:** two-way

**Blast Radius:** narrow

## prior-art

no external prior art: this follows the repository's existing provider job-start canary path.
