# Row 493: blocked units behind dead dependency roots

PR number: none; the brief says to open no PR.

## Causes

- **Closed roots:** before the fix, `release_dependency_blocks_pass` called `dead_blocker_resolve` only when `real_wait` was false (`engine/mac-autopilot/scheduler.d/dependencies.sh:445-446`), and `dep_dead_sweep` selected only waits whose delivery marker was already set (`:584`). Latched waits missed child repointing; first-time waits missed dead-root proof.
- **Open issue with no unit:** intake skips labels including `needs-owner` and `opt-lane` (`engine/mac-autopilot/scheduler.d/intake.sh:33-35`). The old proof accepted a missing unit only for a tracker (`dependencies.sh`, former `dep_predecessor_dead` predicate). `needs-owner` has no active route for the measured root; `opt-lane` does have one: the factory feeder queues pipeline-system issues and marks them `opt-lane` (`engine/factory/feeder.sh:10-28`).
- **Parked roots:** the old proof required every root row to be `closed`, so a parked root failed it (`dependencies.sh`, former `dep_predecessor_dead` predicate). The blocked unit stayed in `blocked-external` even though the existing dep-dead arbiter could handle it.
- **Live roots:** active labels, live workers, open PRs, and open children remain evidence that a root can deliver (`dependencies.sh:540-559`). Those waits remain blocked. In particular, `needs-recut` has a dispatch queue (`engine/issue-pipeline.sh:2915-2938`), and holds can expire and restore their issue (`engine/lib.d/holds.sh:448-535`).

## Change

The release pass now checks latched waits too. A closed or parked root with an open recut child records the existing `blocker-repointed` history event and updates both `blocked_on` and a matching `dep_wait_delivery` marker (`dependencies.sh:219-232`). With no open child and no active route, it falls through to the existing `dep_dead_proved` and supervisor owner path (`:568-584`); no stage was added. The sweep considers unmarked waits as well, but first filters to roots with no unit or only closed/parked rows in one ledger query. It still sends at most one proven dead waiter to the arbiter per sweep.

For a missing unit, the proof accepts only no-route labels (`needs-owner` and `ready-for-human`) when no active route label is present. It preserves tracker children, opt-lane work, recut, hold, advisor, and other active routes. A parked root can use the dep-dead path, while open children, workers, and PRs still fail the proof.

## Measured chains and next-tick behavior

The supplied TSV has 86 rows. The listed groups contain **24 closed-root + 14 no-unit + 10 parked-root = 48 rows**, not 51: the closed-root multiplicities in the prompt sum to 24. I list all 48 rows present in the TSV; there are no three additional rows to account for. `direct` means the waiter points at the root. `→` shows an intermediate blocked unit. A direct dead waiter reaches the existing proof path only if the root has no open child and the worker, PR, and child checks pass. The sweep handles one eligible dead waiter per tick, highest issue number first. Downstream waiters stay blocked on intermediates that may still deliver.

| Root | Waiters in the TSV | Next-tick behavior from the code |
|---|---|---|
| 6577 (closed tracker) | direct: issue-6578, issue-6684; issue-6579 → 6578; issue-1168, issue-5302 → 6579 | Direct waiters repoint to an open recut child. With no open child, one eligible direct waiter enters dep-dead proof; downstream waiters continue waiting on their intermediate. |
| 2520 (closed tracker) | direct: issue-2522; issue-2523, issue-2524 → 2522 | Same tracker-child handling; descendants remain on their intermediate until it can deliver or is ruled. |
| 4592 (closed, needs-recut) | direct: issue-4595; issue-4596 → 4595; issue-4597 → 4596 | The needs-recut route can still deliver, so the chain stays blocked unless an open recut child is available to follow. |
| 2628 (closed, needs-triage) | direct: issue-1271; issue-1202 → 1271; issue-1206 → 1202 | Keep the chain blocked on the active triage route. |
| 1151 (closed tracker) | direct: issue-1152; issue-1163 → 1152 | Direct waiter follows an open recut child, or enters dep-dead proof if no child can deliver. |
| 6351 (closed, ready-for-agent) | direct: issue-6353, issue-6354 | Keep blocked while the ready-for-agent route can create work. |
| 5374 (closed, on-hold) | direct: issue-5375 | Keep blocked while the hold can lift. |
| 5033 (closed tracker) | direct: issue-5035 | Follow an open recut child, or enter dep-dead proof if none can deliver. |
| 5437 (closed tracker) | direct: issue-5438 | Follow an open recut child, or enter dep-dead proof if none can deliver. |
| 5024 (closed, on-hold / size-recut pending) | direct: issue-5025 | Preserve the active hold/size-recut route. |
| 4822 (closed tracker) | direct: issue-4823 | Follow an open recut child, or enter dep-dead proof if none can deliver. |
| 5010 (closed tracker) | direct: issue-5011 | Follow an open recut child, or enter dep-dead proof if none can deliver. |
| 2500 (no unit, roadmap tracker) | direct: issue-2514; issue-2515, issue-2517 → 2514; issue-5978 → 2515 | The direct waiter stays blocked while tracker children can deliver; with no live child it enters dep-dead proof. Descendants remain on their intermediates. |
| 2911 (no unit, needs-recut) | direct: issue-2941, issue-4388, issue-4397 | Keep blocked while the needs-recut queue can deliver. |
| 4622 (no unit, opt-lane / pipeline-system) | direct: issue-4926, issue-4929; issue-4925 → 4926 | Keep blocked for the factory feeder route. |
| 6133 (no unit, on-hold) | direct: issue-6130, issue-6749; issue-6131 → 6130 | Keep blocked while the hold can lift; the downstream waiter stays on issue-6130. |
| 2727 (no unit, needs-owner) | direct: issue-2308 | With no active route, it enters the existing dep-dead proof and supervisor owner path. |
| 6274 (parked) | direct: issue-5993; issue-5994 → 5993 | The direct waiter follows an open recut child if present; otherwise it enters dep-dead proof. The downstream waiter remains on issue-5993. |
| 5732 (parked) | direct: issue-5733 | Enter dep-dead proof if no open child, worker, or PR can deliver. |
| 1136 (parked) | direct: issue-1137 | Same parked-root dep-dead checks. |
| 6539 (parked) | direct: issue-6540 | Same parked-root dep-dead checks. |
| 6534 (parked) | direct: issue-6535 | Same parked-root dep-dead checks. |
| 6531 (parked) | direct: issue-6558 | Same parked-root dep-dead checks. |
| 6123 (parked, on-hold) | direct: issue-6124 | The parked ledger root uses dep-dead proof; the on-hold issue label does not strand the waiter in `blocked-external`. |
| 6121 (parked, supervisor-budget) | direct: issue-6168 | Enter dep-dead proof if no open child, worker, or PR can deliver. |
| 5793 (parked, state-reconcile) | direct: issue-3163 | Same parked-root dep-dead checks. |

## Tests and HEAD

- `bash engine/mac-autopilot/dependencies-onepass.test.sh`: **rc 1** at test-only commit `459ba51a9d27b33b61d86cfefccee2cca339c7e7`, whose parent is `origin/main` `a243a23321172697106475583523a0d8cccf752b`.
- `bash engine/mac-autopilot/dependencies-onepass.test.sh`: **rc 0** at implementation/test HEAD `e4053688ae1b9fffb7c7280c5b602ab7b3d626cd`, recorded by `tools/test-receipt.sh`.
- An earlier run at `6511e941fea16b8f04767f5ec1ae84b8194fc969` was rc 1 because jq work grew with open blocked units. The final one-pass candidate filter restores constant OPEN-case ledger reads and jq runs in the test.

## PR body draft

Merge: review-hold

## Tests

- `bash engine/mac-autopilot/dependencies-onepass.test.sh` — rc 0 at `e4053688ae1b9fffb7c7280c5b602ab7b3d626cd`
- `engine/mac-autopilot/scheduler.test.sh` and `scheduler-gates.test.sh` — covered by PR CI

## prior-art

no external prior art: extends the existing `dead_blocker_resolve`, `dep_dead_sweep`, and `dep_dead_proved` scheduler paths.
