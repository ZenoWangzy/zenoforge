# engine-tests main cancellations after #1335

The first 50 completed `engine-tests` runs with `event=push` and `headBranch=main`, created after PR #1335 merged at 2026-11-21 15:06:23 UTC, span 2026-11-21 15:06:26–23:52:11 UTC.

| Conclusion | Runs |
| --- | ---: |
| Cancelled | 26 |
| Failure | 18 |
| Success | 6 |
| Total | 50 |

The cancellation rate is 26/50 = 52%, above the ticket's 10% threshold.

## Cause

PR #1335 separated concurrency groups by event and only enables `cancel-in-progress` for pull requests. The `main` push group still holds one running run and the newest waiting run. A newer main push replaces an older waiting push before it starts.

All 26 cancelled runs had zero jobs. Sample runs [44918044701](https://github.com/ZenoWangzy/zenoforge/actions/runs/44918044701), [44920366195](https://github.com/ZenoWangzy/zenoforge/actions/runs/44920366195), and [44923322172](https://github.com/ZenoWangzy/zenoforge/actions/runs/44923322172) had no jobs; the inspected run log for 44918044701 was empty. Run 44920366195 was cancelled immediately before the next main push run, [44920456501](https://github.com/ZenoWangzy/zenoforge/actions/runs/44920456501), started. This matches the main group's one-running-plus-one-pending concurrency behavior in `.github/workflows/engine-tests.yml`.

## Method

Read up to 1,000 runs for `engine-tests.yml` with `event=push`, selected completed runs whose branch was `main` and whose `createdAt` was at or after the #1335 merge time, sorted them by creation time, and counted the first 50. The #1335 merge push run is included.
