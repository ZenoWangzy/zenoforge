# Dispatch-claim formal model (#4785)

Property: one ticket never has two implement units at once (a live worker, or an open PR from an earlier one).
Harm: duplicate PRs and wasted workers. Real incident: 2026-10-24, ledger behind GitHub, one ticket dispatched three times (3 duplicate PRs).

CI runs `bash engine/formal/dispatch-claim/verify.test.sh`, which checks the real-code replay and needs no TLC. For the full TLA+ model and replay check, run `bash engine/formal/dispatch-claim/verify-model.sh` (about 12 s); exit 0 means every result matches, 1 means a result changed, and 2 means TLC is not installed. `VERIFY_TRACE=1` prints each counterexample's action list. Read counterexamples with the vendored `statechart` skill (`pstack_skill_md statechart`). How to use the result: `SKILL.md`.

## TLC install (user-local, no sudo, no system packages)

```sh
mkdir -p ~/.local/opt/tla && cd ~/.local/opt/tla
curl -sSL -o jre.tgz "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jre/hotspot/normal/eclipse"
mkdir jre && tar -xzf jre.tgz -C jre --strip-components=1 && rm jre.tgz
curl -sSL -o tla2tools.jar https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar
```

Used on 2026-10-30: Temurin JRE 21.0.13+9, tla2tools.jar v1.8.0 (sha256 011267fca25d0752cf18894dd585cd28b96960c112ea8a20b823ea770e7e10cd, TLC 2026.10.30.154139). `TLA_HOME` overrides the install path.

## Model to code

| Model | Real code |
|---|---|
| `Snap(slow)` | `tick_prs` open-PR census, once per slow tick (`scheduler.d/ci-status.sh`). The refill tick takes none (`refill_tick`, `scheduler.sh`). |
| `CheckStep` | open-PR guard, `coord_scheduler_live_worker`, pending unit read, in `dispatch()` (`scheduler.d/dispatch.sh`, `harvest-workers.sh`) |
| `ClaimStep` | `coord_acquire` / `coord_assert_owned` (`engine/coord.sh`, flock + rename) |
| `Launch` | worker spawn, `coord_renew`, workers.json write in `dispatch()` |
| `Finish` | `harvest_workers` with a report, claim released |
| `Crash` | worker dies without a report (provider limit, no output): `harvest_workers` + `recover_orphans` put the unit back to `implement-pending`, claim released |
| `OpenPR` | the worker pushes and opens a PR on GitHub before it dies |

## Configs and results

| Config | World | TLC | Real code |
|---|---|---|---|
| `no-claim` | no claim, no PR guard | violated: two ticks launch together | n/a (claim exists) |
| `ledger-lag-1024` | claim, nothing compares ledger with GitHub (10-24) | violated: w1 opens PR and dies, ledger says pending, w2 launches | n/a (slow tick has the guard) |
| `refill-gap` | code today: PR guard on the slow tick only | violated, same shape | `replay.test.sh`: refill dispatch LAUNCHES a second worker with PR #501 open (`refill-pr-guard: LAUNCHED`) |
| `fixed` | claim first, then a fresh PR check on every tick | passes (248 states) | not implemented |

`replay.test.sh` runs the real `dispatch()` from `dispatch.sh`, the real `coord.sh`, the real `coord_scheduler_live_worker` and `jqf`/`unit_field`; only the worker command, the GitHub census and state writes are stubbed. Its steps are the `refill-gap` trace: refill launches w1; a second tick is held by the live worker; w1 opens a PR and dies, harvest releases the claim; the slow tick is held by the open PR; the refill tick is not.

## Finding F1 (open, product code untouched)

`dispatch()` skips the open-PR guard when `TICK_DISPATCH_LOCAL_REFILL=true` (refill, #4628: no GitHub calls). A worker that opens a PR and then dies without a report is requeued to `implement-pending` by `recover_orphans` in the refill tick, and the same refill tick dispatches it again with no PR comparison. That is the 10-24 shape, in the path added after it. Same unit id reuses its branch, so the result may be one PR pushed twice or a second PR from another unit; the invariant counts both as a duplicate.

Fix the model passes with: take the claim, then read the open-PR census at dispatch time on every tick (`CheckAfterClaim`, `FreshCheck`). Cost: refill makes one `gh pr list` call per dispatch, which #4628 removed on purpose. The maintainer decides; when the code changes, set `refill-gap` to PASS in `verify-model.sh` and update `replay.test.sh` expectations.

## Scope

Verified: one ticket, two ticks (slow, refill), two workers, claim never expires. Not verified: lease expiry and renewal, the issue-pipeline.sh feeder path (`pipeline_claim_begin`, triage/advisor/recut stages, not implement), batch claims, unit creation in intake, PR-lane (non-direct-main) implement dispatch, slow-tick census staleness inside one tick (a stale `Snap` also violates the invariant; not tied to a replay).
