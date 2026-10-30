# Autopilot merge lane

## Merge and verification contract

The required PR rows and non-`agent/issue-` branch adoption contract live in the [pipeline merge gate](../../docs/agents/issue-pipeline.md#the-merge-gate). There is no batch, no `merging` state and no custom queue. `scheduler.sh` checks candidates within a bounded per-tick scan (`batch_max`, default 4, now the per-tick merge cap) and rotates by last-checked time so dead PRs cannot permanently starve later ready units.

Merges are pinned to the approved head with `--match-head-commit`, and the first merge of a tick is anchored to the `MAIN_HEAD` the gate observed. Each landed change gets main CI; a landed unit is `merged` at once and release selection stays a green descendant of the deployed revision.

The gate still stops the line: it searches the candidate chain from origin/main HEAD back through the latest non-`[skip ci]` commit for the latest completed, non-cancelled suites run whose `headSha` matches its candidate exactly. While that verdict is red or unknown, pipeline PRs are held (product PRs still merge); a pending run does not close the gate. A completed red verdict uses the `pass / infra / code / unknown` classification. The first completed failure on each SHA reserves one failed-job rerun before requesting it; a later verdict must have the same SHA, workflow and run ID and a strictly higher completed attempt before a repeated code failure can open main-red work. Re-reading the same failed attempt is not a second execution. An unconfirmed CLI response waits for server evidence. Recovery of a red main is owned by the main-red handler (`main_red_attribution` / `revert_squash_merge`, then `open_main_red_unit`); merging never reverts.

Bell S12 deduplicates queued/pending/waiting runs for CI and Pipeline suites, keeping running runs and each workflow's latest waiting run. It proves a strictly older waiting run was superseded, protects active release candidate SHA/run identities from the actual state ledger, and rechecks run status and candidate evidence before an audited cancellation. Missing or invalid candidate evidence defers cancellation with an explicit reason. `--check-only` reports the decision without cancelling runs, restarting processes or writing runtime state.

## Verification

`scheduler.test.sh` runs real ticks against temporary state and fake Git/GitHub/process commands. It covers attempt-bound classification, first-failure retry reservation, repeated observation of an old failure, server reconciliation after an unconfirmed rerun request, repeated network failure, cancellation and unknown evidence, bounded candidate fairness, independent pipeline and product merges and the red-main stop. `scheduler-gates.test.sh` also covers missing attempt identity, legacy retry reservations and mismatched run identity at the gate. It also checks state preservation and the per-dispatch/day token accounting used by the dashboard.

`bell.test.sh` and `bell-drift-sigs.test.sh` isolate runtime state and external effects. They cover check-only mode, active-candidate protection, missing or stale heartbeat, and source/live drift. `pre-push.test.sh` verifies complete changed-file coverage and associated tests from the candidate archive. The existing `land-direct-main` snapshot exemption skips duplicate associated tests while retaining land-gate (LESSONS L46); the exemption does not establish that current fast preflight ran every focused test.

These fixtures verify controller behavior; they do not constitute production build or deployment evidence.

## Activation

Follow the current mechanism lane and controller ownership in `docs/agents/standing-rulings.md`. After acceptance and main delivery, use the runtime paths resolved by `runtime-env.sh` and the existing Mac/WSL controller instance.

1. Run `bash engine/mac-autopilot/start.sh --sync-only` to copy the reviewed mechanism files and any missing default configuration. This mode starts no loop. Preserve existing config, units, workers, release records, budget and alerts; inspect the existing `auto_merge` setting without overwriting it from defaults.
2. Keep the dashboard HTML and `dashboard.data.js` together in the resolved autopi runtime directory. Confirm the expected source/live versions and generator heartbeat there.
3. An existing loop reads installed scripts on its next tick, normally within 120 seconds. Confirm a new `scheduler.log` tick or matching process evidence before claiming the code is loaded. If the controller is stopped, report the completed sync and the stopped state; file synchronization does not call for another Mac/WSL controller instance.
4. After the next authorized merge, inspect the recorded `pre_merge_sha` and `merge_sha`; the unit is `merged` and main CI verifies it.

## Rollback

Stop accepting new merges before a controller rollback. Retain state, history and alerts. Restore a compatible reviewed source revision by atomic replacement while preserving runtime configuration. Units left in `merging` by an older scheduler must be resolved by the head supervisor before landing the ordinary-lane scheduler.

Never delete `units.json` to unblock delivery: it owns the candidate identity and history.
