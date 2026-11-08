# Code Factory node health — baselines and criteria

`node_health.py` scores every node against the bounds below on each scheduler tick
(`node-health.txt`, UNHEALTHY lines in `alerts/node-health.md`) and at the end of `health_report.py`.
Between the healthy and the unhealthy bound is WARN. A bound changes only with measured evidence, in
the same landing as this table (`config.template.json` `node_health: {"<metric>": [healthy, unhealthy]}`
sets the versioned threshold for one host; runtime `config.json` is reconciled from this template).

## Node map

```
issue ─ intake ─ implement ─ review ─┬─ approve ─ PR CI ─ merge lane ─ main Postsubmit ─ release train ─ prod ─ close
                                     └─ request-changes ─ repair ─ rereview ─┘   (the review loop)
side nodes: scheduler tick · workers (death/no-output) · supervisor (escalations)
```

## Baselines and criteria

"Human baseline" is what one competent engineer needs for a typical small-to-medium the product change.
Sources are cited where a published figure exists; the rest are engineering estimates and are marked so.
Agent bounds are set from the human baseline (agents must be faster in wall time) and from the
measured distribution on 2026-10-20 (`24h` = window ending 15:55Z).

| Node | Metric (id) | Human baseline | Healthy | Unhealthy | Measured 24h |
|---|---|---|---|---|---|
| implement | run minutes p50, 24 h window (`implement.wall_p50`) | 2–4 h focused work (estimate) | ≤ 30 | ≥ 60 | — |
| implement | runs with no report % (`implement.no_output_pct`) | — | ≤ 5 | ≥ 15 | — |
| review | first review minutes p50 (`review.wall_p50`) | first response < 1 h for small changes, < 4 h overall at Google [1]; one session ≤ 60 min, 200–400 LOC/h [2] | ≤ 10 | ≥ 20 | — |
| review | PR opened → first review verdict minutes p90, rolling 7 d, a PR still in `review-pending` counts its age (`review.open_to_first_review_p90_min`; `review.wall_p50` above is the review run alone, not this wait) | first response < 1 h for small changes, < 4 h overall at Google [1]; measured on the 7 days to 2026-11-07T14:40Z, n = 236 PRs, p50 28.8 min, p90 93.8, max 1783: healthy 60 = 2 x p50, unhealthy 180 = 2 x p90 rounded down to 3 h, inside Google's 4 h. The p90 tail is review runs that died and parked in the supervisor path (7 PRs, one cause, 739–1783 min) and Codex-authored heads waiting for GLM, their only reviewer once the Claude route was off | ≤ 60 | ≥ 180 | — |
| review | approved on first review % (`review.first_pass_pct`) | most changes need 1–2 iterations (estimate; [1] measured iterations, median not verified) | ≥ 50 | ≤ 30 | — |
| repair | run minutes p50, 24 h window (`repair.wall_p50`) | 15–60 min per round (estimate) | ≤ 15 | ≥ 30 | — |
| review loop | request-changes rounds before approve p90 (`loop.rounds_p90`) | 2–3 (estimate) | ≤ 3 | ≥ 5 | — |
| review loop | repair (including pre-review self-fix) + rereview share of tokens % (`loop.rework_token_pct`) | — | ≤ 35 | ≥ 50 | — |
| review loop | fresh tokens of repair runs that left the PR head unchanged, % of classified repair runs, rolling 24 h by event time (`repair.unchanged_head_token_pct`; source: `head_class` and `fresh_tokens` on `repair-delivered` / `repair-no-push` ledger events, written at harvest from the PR head recorded at dispatch against the origin branch head at the end; a run whose head cannot be classified, and every event written before the detector, is left out, and a window with no classified run reads NO-DATA, never 0; a run that is expected to leave the head unchanged counts as classified, not as waste) | measured 2026-11-06 07:10Z to 2026-11-07 20:00Z from the unit ledger and scheduler log: 30 of 195 repair runs left the head unchanged, 16.1% of fresh tokens (11.0% on 11-06, 18.7% on 11-07), before the expected-unchanged rule; bounds are provisional until the head approves them | ≤ 5 | ≥ 15 | not live until the detector is pinned |
| review loop | repairs followed by an incremental rereview % (`loop.incremental_rereview_pct`) | Fagan follow-up: the moderator verifies the rework, not a new inspection [6] | ≥ 60 | ≤ 30 | — |
| workers | no-output events in window (`workers.deaths`) | — | ≤ 2 | ≥ 8 | — |
| CI + merge | approve → merged/landed min p50, waiting units count their age (`ci.approve_to_ship_p50`) | ten-minute build [3]; elite lead time < 1 day [4] | ≤ 60 | ≥ 180 | — |
| CI + merge | last required check completed → merged, max min over merged PRs in 24 h, both lanes; factory and session-owned split in details (`merge.green_to_merge_max_min`; GitHub check-runs read by `merge_wait.py`'s own 24 h query, `required-pr-checks.json` names, `mergedAt`; a failed or truncated read is NO-DATA; a PR without check data is counted in details, not as zero) | factory lane max 13.9 min since 2026-11-05 10:00Z (pr-wait report, 78 PRs); founder ruling 2026-11-07: a PR wait is held to minutes, and hours are a root-cause item (bounds from the pr-wait report, not a new estimate) | ≤ 15 | ≥ 60 | 31.1 min, WARN, session-owned PR (2026-11-07 15:50Z; `gh pr view` + REST check-runs agree); factory max 13.9 |
| CI + merge | approved units that then saw CI red % (`ci.red_after_approve_pct`) | elite change failure ≈ 5 % [4] | ≤ 15 | ≥ 30 | — |
| CI + merge | local prechecks skipped because affected packages could not be selected (`ci.precheck_setup_failures`) | 0; this setup failure can make CI the first test run | 0 | ≥ 1 | — |
| supervisor | escalation → decision min p50 (`supervisor.latency_p50`) | ≤ 60 (estimate, on-call style) | ≤ 60 | ≥ 180 | — |
| supervisor | arbiter dispatches in 24 h (`supervisor.arbiter_dispatches_24h`) | 1,003 arbitrations in the 7 days to 2026-11-06 (≈143/day, 801 on the hard tier, 4.6/merge; 20 units spent 71%); the per-unit lifetime cap `supervisor_arbiter.unit_cap` (default 4) now ends each unit's arbitration itself | ≤ 48 | ≥ 120 | first scorecard sample |
| supervisor | supervisor-cap-default decisions in 24 h (`supervisor.cap_default_24h`; measured, no bound — the sentinel bounds 0/-1 keep any measured count OK) | every default decision ends a capped unit in the same tick with no model run and no founder question; watch the rate to see how often arbitration fails to converge | — | — | first scorecard sample |
| supervisor | repeat-arbitration guard firings in 24 h (`supervisor.repeat_guard_24h`; counts history events whose `result` starts with `supervisor repeat guard:`, the route events themselves, no new stage) | a unit whose next escalation has the same reason as the one its last arbiter run answered (digits and SHAs normalised), with no delivery, approval, ready-to-merge, merge or new PR head in between, takes the spent-budget route in the same tick (one recut when it has no PR, else park) instead of a second requeue-prone run; replay of the 24 h to 2026-11-07: 16 of 85 dispatches on 8 units (provisional bounds, tune after a week of live samples) | ≤ 8 | ≥ 24 | first scorecard sample |
| scheduler | seconds between tick starts p50 (`scheduler.tick_gap_p50`) | — | ≤ 240 | ≥ 420 | — |
| release | current release batch wait in hours, not yet deployed (`release.hours_waiting`; 0 once a `release-retained` deploy came after the batch started) | elite: deploy on demand, lead time < 1 day [4] | ≤ 4 | ≥ 12 | — |
| release | hours since the oldest deploy whose acceptance failed under FIX-FORWARD and still holds tickets no later `release-closer` line closed (`release.hours_acceptance_failed`; 0 when none; PROVISIONAL bounds, maintainer to confirm) | the next release's acceptance should clear the tracker: 24 h is about 6 missed 4 h release cycles (`release.hours_since_release` bound) | ≤ 24 | ≥ 72 | — |
| release | hours since production last changed, formal or hand release (`release.hours_since_release`; source: GitHub production Deployments, the live sha (newest success record via `engine/production-deployment-read.sh`) and its earliest real deployment record, not `release-train.json` `released_at`; ruling `release-overdue-2026-11-07`: two 2 h batch cycles with no formal release is a stop, repeated hourly) | two batch cycles (2 h) per release; 4 h without one is a stalled line | ≤ 2 | ≥ 4 | — |
| release | production hot patches whose PR is not on main (`release.hotpatch_blockers`) | a hotfix is merged the same day | 0 | ≥ 1 | — |
| holds | line holds (a disabled release train or a valid PAUSE) without an owner or expiry, or past expiry (`holds.line_violations`; each violating hold appends one alerts/events.md line and one supervisor inbox line per day, naming owner, reason and hours since expiry) | a line hold is the same decision as an issue hold (`hold_issue` requires holder, release condition, expiry) and owes the same metadata; expiry fails loud and never re-enables the held line | 0 | ≥ 1 | first scorecard sample |
| rulings | rulings rows in the pack's copy that the engine's resolved `state/rulings.json` lacks, matched by date and scope because the engine copy is renamed when it is built; rows only in the engine copy do not count (`rulings.copies_differ`; source: `zf_config_file('state/rulings.json')` against the pack's `scripts/agent/state/rulings.json` under the agent home; NO-DATA when either file is missing or unreadable) | 0: one set of rulings, so the dashboard, lane routing and founder's words read what the maintainer ruled | 0 | ≥ 1 | — |
| pipeline | open agent PRs outside the ledger (`pipeline.orphan_prs`) | — | ≤ 3 | ≥ 10 | — |
| work orders | open work orders past a spend bug bound (`workorders.over_standard`) | — | 0 | ≥ 3 | — |
| work orders | per-ticket worker fresh tokens p90, tickets closed in 7 d (`workorders.ticket_tokens_p90`) | fresh means uncached input + output, and a ticket counts only when every one of its worker runs (review and repair logs found through `unit.pr`) has a usage record, so the row is NO-DATA while GLM and Claude review runs print none; bounds derive only from preceding 30 d of closed tickets with cache splits — healthy p50 x 1.5, unhealthy p90 x 2 (`worker_cost.ticket_bound`); no usable history falls back to the static values here | ≤ 800 k | ≥ 4.8 M | first scorecard sample |
| work orders | per-ticket worker wall minutes p90, tickets closed in 7 d (`workorders.ticket_wall_p90`) | same history-derived bounds (p50 x 1.5 healthy, p90 x 2 unhealthy) | ≤ 38 | ≥ 180 | first scorecard sample |
| CI + merge | CI runner minutes that could not change a verdict % (`ci.waste_runner_pct`, from `ci_spend.py`) | lean: work that cannot change the outcome is waste (muda) | ≤ 20 | ≥ 35 | — |
| CI + merge | ready-to-merge units whose CI is held for hot patches % (`ci.held_ready_pct`) | priority must not become starvation | ≤ 20 | ≥ 50 | — |
| CI + merge | M1 audited cancelled runs/day: ci deferred (`ci.cancel_deferred_per_day`) | frozen M1: 1,029 / 3.94 days | 0 | ≥ 261 | rolling report |
| CI + merge | M1 audited cancelled runs/day: ci wip (`ci.cancel_slot_wait_per_day`) | frozen M1: 838 / 3.94 days | 0 | ≥ 213 | rolling report |
| CI + merge | M1 audited cancelled runs/day: repair dispatched (`ci.cancel_repair_per_day`) | frozen M1: 698 / 3.94 days | ≤ 177 | ≥ 354 | rolling report |
| CI + merge | M1 audited cancelled runs/day: tests already red (`ci.cancel_tests_red_per_day`) | frozen M1: 244 / 3.94 days | ≤ 62 | ≥ 124 | rolling report |
| CI + merge | M1 audited cancelled runs/day: review requested changes (`ci.cancel_review_changes_per_day`) | frozen M1: 237 / 3.94 days | 0 | ≥ 60 | rolling report |
| CI + merge | M1 audited cancelled runs/day: review blocked (`ci.cancel_review_blocked_per_day`) | frozen M1: 8 / 3.94 days | ≤ 2 | ≥ 5 | rolling report |
| CI + merge | M1 audited cancelled runs/day: parked (`ci.cancel_parked_per_day`) | measured 2026-11-07, not frozen M1: 168 hourly rolling-24 h readings over the last 7 days (audit file reaches back 18.9 days, so the 7 days are complete): p50 0, p90 3, max 5; 6 parked runs from 4 units (mean 0.86/day) | ≤ 3 | ≥ 6 | rolling report |
| CI + merge | M1 audited cancelled runs/day: superseded main run (`ci.cancel_superseded_per_day`) | no frozen cause baseline; tracks main merge rate | ≤ 30 | ≥ 60 | rolling report |
| CI + merge | M1 audited cancelled runs/day: other or unclassified (`ci.cancel_other_per_day`) | no frozen cause baseline | 0 | ≥ 1 | rolling report |
| CI + merge | active agent PRs with server label `agent/ci-gated` % (`ci.gated_pr_pct`, M12) | frozen M12: 0 of 87 | ≥ 80 | ≤ 50 | GitHub open-PR census |
| CI + merge | distinct runs held by priority CI gate in last 48 h (`ci.priority_hold_runs_48h`, M13) | retire only after a full 48 h with zero firings | 0 | ≥ 1 | shared cancellation audit |
| CI + merge | shared-append landings whose rebase conflicted on a shared-append file %, rolling 24 h (`ci.shared_append_rebase_conflict_pct`) | first-cut bound (2026-10-30): the ruling trades occasional rebase conflicts for parallel implement on append-registry files; a day of samples above the bound means tighten the list back to mutual exclusion | ≤ 25 | ≥ 50 | first scorecard sample 2026-10-30 |
| CI + merge | merge conflicts that a repair run followed, rolling 24 h (`merge.conflict_repairs_per_day`); replaces `dispatch.collisions_per_day` (2026-11-07): the dispatcher no longer refuses a unit whose predicted files overlap a running one (footprint only orders, `engine/mac-autopilot/scheduler.d/footprint.sh`), so overlapping writers are expected and the cost is measured where it lands. Count of `merge-conflict` history events with a later `write-start` (repair run) in the same unit, from `units.json` plus `units-archive.json`. Baseline: ledger mean 15.6, sd 5.5 over 9 active UTC days (10-28 to 11-06, without the 11-01 pause). Unhealthy at 27 (baseline mean + 2 sd); healthy at 20 (mean + 2 standard errors of a 7-day mean). Revert rule for the footprint change: 7-day mean of the daily value at 20 or more, or two consecutive days at 27 or more. | #4190/#4192/#4193 concurrently edited one hook; first-dispatch file prediction has recall 0.31 and precision 0.67, so a lock on predicted files cost more than the conflicts it avoided | ≤ 20 | ≥ 27 | — |
| review loop | ledger PRs over 800 non-test added lines %, rolling 30 d by ledger activity (`review.large_pr_pct`, from `pr-sizes.json`; active PRs without history are included and missing non-test addition counts report no data; test paths are directories named `test`, `tests`, `__tests__`, `fixture`, `fixtures`, or `__snapshots__`, or directories starting with `eval` and continuing only with lowercase letters, hyphens, or underscores; files containing `.test.` / `.spec.` or ending in `.snap` also count as tests; the all-time share was a metric bug — one-off oversized PRs never aged out and recovery required dilution, #4482) | small batches: review effectiveness drops past 200–400 LOC [2] | ≤ 10 | ≥ 25 | — |
| workers | local test Postgres reachable (`workers.local_test_db`, TCP probe of `PGTEST_URL`) | shift left: run integration tests before review, not after approval | 1 | 0 | — |
| host | host services from `host-prereqs.json` that do not answer (`host.prereqs_missing`; names printed as `host missing:`) | every dependency of a machine is declared and probed (infrastructure as code) | 0 | ≥ 1 | — |
| host | GitHub fetch/API network failures per hour from the user journal (`host.github_net_failures_per_hour`): final `origin fetch failed`, `git fetch: timed out after`, `api.github.com` TLS handshake timeout | every unit that talks to GitHub reaches it (on WSL only through the egress proxy) | ≤ 2 | ≥ 10 | — |
| intake | open `ready-for-agent` issues whose units all ended (`intake.closed_units_open_issues`; ids printed as `closed units under open issues:`) | intake's terminal skip starts no worker for these and logs them only as one aggregated line, so each is a stopped ticket nobody is told about (2026-11-06: 8 rows) | 0 | 10 | — |
| host | worktrees under `~/wt` older than 2 h (`host.stale_worktrees`, age of each worktree's `.git` link) | a finished run removes its workspace on every exit path; removal never waits on the network | ≤ 10 | ≥ 40 | — |
| host | hours the live engine has not followed example `HEAD:scripts` (`engine.follow_lag_hours`, from `engine-versions/.lag-since`) | 10-30 head: an ENGINE landing reaches live through follow-main by itself; a failed export/build/check alerts the inbox and starts this clock | ≤ 0.5 | ≥ 2 | 0 since follow-main; before it ENGINE landings waited for a manual re-pin (node health scoring itself was down 11:59Z–15:45Z on 10-30) |
| review loop | Advisor asks without a ruling % (`loop.advisor_fail_pct`) | maintainer 10-22: advisor decides after 2 rejected rounds | ≤ 10 | ≥ 50 | — |
| review loop | hours since the newest successful advisor answer while needs-advisor > 0 (`advisor.last_answer_age_hours`) | a dead advisor must not stay silent while tickets wait | ≤ 2 | ≥ 6 | — |
| review loop | REQUEST-CHANGES reports without a machine-readable findings block % (`review.findings_missing_pct`, from `review_findings` in `units.json`) | recurrence and per-round history are only as good as the data: a missing block is counted, never read as zero findings | ≤ 5 | ≥ 20 | — |
| delivery | issue created → release accepted p50, rolling 7 d / 30 d hours (`delivery.issue_to_accept_p50_7d_hours`, `delivery.issue_to_accept_p50_30d_hours`); every accepted issue with one acceptance event and a readable createdAt counts, the unit join is not required; a window with no acceptance reads NO-DATA (true while the release line is stopped) | DORA elite lead time < 1 day [4]; same bound as `unit.age_hours` | ≤ 24 | ≥ 72 | first scorecard sample |
| delivery | issue created → release accepted p95, rolling 7 d / 30 d hours (`delivery.issue_to_accept_p95_7d_hours`, `delivery.issue_to_accept_p95_30d_hours`) | engineering estimate: healthy is three days; one week is a stalled delivery | ≤ 72 | ≥ 168 | first scorecard sample |
| delivery | first-parent product commits on `origin/main` after the recorded live SHA (`delivery.merged_not_live`) | the live sha from production's own deployment record (`release_age.production_deploy`), else `$AGENT_HOME/state/live-sha.json` (written on post-deploy success), plus the merge lane's `NONPRODUCT_PATHS_RE`; `release-train.json` and `deployed.json` are not read because a hand release leaves them stale; with no readable record the row is NO-DATA and unhealthy because this signal was silent for 15 days | 0 | ≥ 1 | — |
| delivery | age in hours of the oldest such commit (`delivery.oldest_merged_not_live_hours`) | commit time from the same first-parent product commit range; the 24/72 h bounds match issue-to-accept p50 | ≤ 24 | ≥ 72 | — |
| delivery | fully linked units accepted in the last 30 d that have since been reverted % (`delivery.revert_rate_30d_pct`) | elite change failure rate < 5 % [4]; 10 % is twice that bound | ≤ 5 | ≥ 10 | first scorecard sample |
| delivery | release-accepted issue IDs in the last 30 d named by a production incident, per 100 accepted IDs % (`delivery.incident_rate_30d_pct`) | change-failure proxy [4]; no frozen incident-per-unit baseline yet, so 5 / 10 % are the same initial bands as reverts | ≤ 5 | ≥ 10 | first scorecard sample; unlinked incident records remain separately visible |
| delivery | review rounds through the first approval per merged unit (`delivery.cycles_to_pass_30d`) | Anthropic reported 1.32 reviews-to-pass after its change; the product's pre-pause 112 delivered units averaged 2.28 approvals [alignment §9] | ≤ 1.32 | ≥ 2.28 | first scorecard sample |
| delivery | scheduler approvals per merged unit (`delivery.approvals_per_merge_30d`) | one successful approval is sufficient; the product pre-pause average was 2.28 per delivered unit [alignment §9] | ≤ 1 | ≥ 2.28 | first scorecard sample |
| delivery | release-accepted issue records missing a unique issue → unit → PR → merge → release join (`delivery.unlinked_units_30d`) | exact IDs are required; guessing a missing edge would falsify lead time | 0 | ≥ 1 | first scorecard sample |
| delivery | production incidents and head-watch alert episodes without an explicit accepted-issue link (`delivery.unlinked_incidents_30d`) | exact issue link required; a record naming no issue (`issue` field or "Issue #N" in what_happened) is not linkable, is counted here and is also shown as `incident_unreferenced_30d`; a named issue that was never accepted is unlinked | 0 | ≥ 1 | first scorecard sample |
| flow | merges per hour vs the 6.5 target, rolling 24 h. Population: the factory's unit-ledger PRs only (merged/landed events in `units.json` and `units-archive.json`); human PRs and PRs outside the ledger are not counted. A starved queue (nothing open, nothing entered) reports no value (`flow.merge_rate_per_hour`) | #4355 SLO: ≥ 6.5 merges/h with sufficient backlog; 3.5/h was the pre-upgrade serial merge-lane ceiling | ≥ 6.5 | ≤ 3.5 | first scorecard sample |
| flow | worst per-stage p90 age of open units, hours (`flow.wip_age_stage_p90_hours`; per-stage rows in scorecard `flow.wip_age`) | #4355 SLO: median ticket cycle ≤ 2 h; p90 stage age ≤ 4 h is consistent with it (estimate), half a day in one stage is stalled; `blocked-external` and `parked` rows are listed (`waiting: true`) but never pick the worst stage, they wait by design | ≤ 4 | ≥ 12 | first scorecard sample |
| flow | p90 age of units waiting on a predecessor or a park, hours (`flow.wait_stage_p90_hours`; blocked-external and parked, last ledger event → now) | completed holds on 2026-11-07, 699 samples: 540 blocked-on → unblocked/requeue (p90 55 h), 159 supervisor park → next event (p90 94 h); combined p90 80 h. Bound = that p90 (healthy), 2× it (unhealthy), the bug ≈ 2× p90 convention of the spend standards | ≤ 80 | ≥ 160 | measured 2026-11-07: 94 waiting units, p90 227.6 h |
| flow | units waiting on a predecessor or a park (`flow.wait_stage_units`) | — | measured, no bound (sentinel 0 / -1: any count is OK) | 2026-11-07: 94 |
| flow | hours units queued for a repair/rereview worker while none of that phase ran (`flow.slot_idle_hours`) | idle-with-backlog is a dispatch stall, not a capacity bound (a busy bottleneck is the capacity case); between-tick waits of ~2 min are normal (estimate) | ≤ 0.25 | ≥ 1 | first scorecard sample |
| flow | hours main was red (bisect sessions) in the window (`flow.main_red_hours`) | one clean episode (same-SHA rerun + bisect + revert) at a ~17 min Postsubmit cadence is ≈ 1 h (estimate) | ≤ 1 | ≥ 3 | first scorecard sample |
| flow | \|units entered − units merged/landed\| in the window (`flow.in_out_imbalance`) | conservation: sustained inequality means WIP piling up or units vanishing; bands are ≤ 1 h vs > 2 h of net flow at the 6.5/h rate (estimate) | ≤ 5 | ≥ 15 | first scorecard sample |
| mechanisms | registered mechanisms past their silence bound (`mechanism.silent`) | a mechanism whose code landed but never runs is silent (#4483: f3 landed while `release_train.enabled=false` stopped releases 18 h); zero silent mechanisms | 0 | ≥ 1 | first scorecard sample |

Mechanism heartbeat (#4495 M2, #4498): every mechanism registers its events and its maximum silence in
`engine/state/mechanism-registry.json` — mechanism ID, event match patterns (scheduler log, alert events
log, or `$AGENT_HOME/logs`), silence bound in hours, responsible supervisor, and `expected_idle` (long quiet
periods legitimate, e.g. f1 only acts when main is red). `node_health.py` takes each mechanism's latest matching
line (rotated `.1` generations included), and counts a mechanism as silent when it has no event or is past its
bound, unless `expected_idle`; the scorecard's `mechanisms` block carries each mechanism's last event time. The
f9 footprint mutex has a kill switch (`footprint_mutex.enabled=false` in `config.json`) so the detection itself
can be fault-injected: switch it off, and `mechanism.silent` reports f9 within its registered silence bound.
A target `.zenoforge/state/mechanism-registry.json` holds only the rows and fields it overrides; they merge by id over the engine rows, so an engine edit to anything else reaches the target.
`node_health.py`, the health mail and the incident guard audit read the target `state/incident-guards.json` plus engine records under ids the target lacks. Validators, writers, `generate-lesson-enforcers.mjs` and the recurrence ranking keep the target file, because `lesson_id` is not shared between engine and target.

A `not_operating` reason in the registry marks a mechanism that cannot do its job, so its events prove nothing. Its row shows the reason instead of a heartbeat and is not counted as silent. The f10, f11 and f13 eval rows carry one while the prompt eval gate is parked (#531); remove it when the gate can complete a run.

`release.hours_waiting` measures the current pending release batch. `release_train.sh` tracks first-seen times for
issues the selector confirms are pending, including dispatched batches, active units, capacity and cadence waits,
and release dispatch gates. It preserves known starts across retries and holds, and clears them when the selector
reports no eligible pending work. Stale labels that fail release-state validation do not count. The metric does not
reuse a prior `release-closer` timestamp, which would count idle time before the current batch existed.
`release-retained: deployed=<sha> tracker=#<n|none> held=[ids]` (`run-release.sh`, FIX-FORWARD) means production changed but acceptance
failed: the tickets stay `awaiting-release` and only a later `release-closer` line closes them. It never reuses the `release-closer` prefix, so
`delivery.*`, the f3 heartbeat and `factory_trend.py` do not read it as an acceptance. `release_retained.py` reads it: the founder-requirements
ladder puts a held ticket at 上线 (never 验收), and `release.hours_acceptance_failed` is the age of the oldest held deploy.
`release.hours_waiting` is not time since the last formal release: it is 0 once the batch is released, and it is
None with no batch. The age since the last release is `release.hours_since_release` (`release_age.py`): it reads the
newest success record of the GitHub production Deployments, so a hand release counts. Its time is the earliest real
(non-reconciled) deployment record of the live sha: a later reconciled record of the same sha does not move it, and a
newer sha does. It is NO-DATA when that read fails, never 0. Deployment records missing from the `RELEASED` lines of
`release-train.log` (none after 2026-10-23 while production deployments continued) do count; the night report's
formal-release count reads only those lines. While unhealthy, `RELEASE-STOPPED` repeats at most once an hour (ruling
`release-overdue-2026-11-07`) until a new production record is healthy; each repeat is one events line and one
supervisor inbox line keyed by the hour. The CLI `python3 engine/mac-autopilot/release_age.py` prints the same deploy
time and sha for owner reports. A `PAUSE` file
keeps the value and the overview tile but raises no alert, as `station_health` does; the line hold itself is
`holds.line_violations`.

Delivery metrics use fixed rolling 7-day and 30-day windows. Release acceptance time comes from the batch close
event written by `run-release.sh` as `release-closer: deployed=<sha> closed=[issue IDs]`; lead time starts at GitHub issue `createdAt`, and the
scheduler unit must carry the exact issue, PR and merge-history fields. GitHub `closedAt` is not used as acceptance
time because an issue can close before release acceptance. The unit's `merge_sha` must match GitHub's
`mergeCommit.oid`; the batch event's deployed SHA is its attestation that the merge reached production. A missing,
ambiguous or incomplete edge increments `delivery.unlinked_units_30d` and is excluded from lead-time samples and the
revert-rate sample, which needs the linked merge SHA. Reverts are matched by the Git commit message marker
`This reverts commit <merge_sha>.` on `origin/main`, and only count when the revert commit follows acceptance.
Production incidents are the `incidents` of the owner-mail ledger (`night/founder-health-mail.json`), opened in the window; the
owner mail counts the same ledger under 线上告警. Incident rate is the number of unique accepted issue IDs (release-closer
acceptance events in the same 30-day window) that an incident names, divided by the number of those accepted IDs, so it cannot pass 100 %.
The root-cause lesson records in `incident-guards.json` are factory process findings, not production incidents, and are
not counted. Head-watch `PROD-DB-TIMEOUT` alerts (`logs/head-watch.alerts`, alerts under 30 minutes apart are one episode, as in the owner mail's
线上告警 line) name no issue, so they are not in the rate; each episode counts in `delivery.unlinked_incidents_30d`. That log
starts 2026-11-04, so until it holds 30 days the count is a floor. A 0.0 rate therefore means no linked incident, not no production trouble.
An alert would link only through an issue ID or a release SHA that matches a release-closer event.
Incident linkage compares the record's explicit issue ID with those accepted IDs; missing or unmatched IDs remain
visible in `delivery.unlinked_incidents_30d`. There is no human-action row: the factory is unattended, so a count of
human PR review actions would measure the hand-off the design removes. The PR census reads only each PR's merge time and
merge commit, so a PR with over 100 reviews or commits no longer blanks the window. GitHub census and missing-ID reads
use bounded parallel calls with per-call and batch deadlines; an unavailable issue or PR source stays unknown rather
than becoming a zero sample.

The first delivery bounds use existing measured baselines where available and mark estimates above. The 30-day
review values are intentionally a separate cohort from `--hours`; scorecard JSON carries its accepted, merged,
and unlinked sample counts under `delivery`.

M1 counts distinct run IDs from the shared cancellation audit in the rolling `--hours` window and normalizes them to a 24-hour rate. For causes expected to disappear with gating, zero is healthy and the frozen pre-change rate is the bug bound; other known causes use the frozen rate as the healthy ceiling and twice that rate as the bug bound. The parked cause is the exception: the frozen 3 runs / 3.94 days predates `to_supervisor` cancelling CI runs, so its ceiling is the p90 of 168 hourly rolling-24 h readings over the 7 days to 2026-11-07 13:37Z (p50 0, p90 3, max 5; a thin sample, 6 runs, re-measure when the escalation rate changes) and its bug bound is twice that. New or unclassified causes use 0 / 1 until there is a frozen baseline. Repeated audit attempts for one run count once. M12 reads the provider label on currently open `agent/issue-*` PRs. M13 counts distinct `ci hold` run IDs over 48 hours; zero is the retirement signal, not a measured before/after comparison.

## Where the time goes (`time_sinks`, last 24 h)

Each phase of a work order, split into waiting and working. Source: `units.json` event times plus the
`dispatch` lines in `scheduler.log`. The dashboard shows n, p50, p90 and total hours per phase.

| Phase | Statistic | Healthy (min) | Unhealthy (min) | Baseline |
|---|---|---|---|---|
| repair triggered → repair worker dispatched (`repair_queue`) | p90 | ≤ 30 | ≥ 120 | — |
| repair work (`repair_work`) | p50 | ≤ 15 | ≥ 30 | — |
| repair delivered → rereview dispatched (`rereview_queue`) | p90 | ≤ 10 | ≥ 30 | — |
| rereview work (`rereview_work`) | p50 | ≤ 10 | ≥ 20 | — |
| approve → CI red (`approve_to_ci_red`) | p50 | ≤ 60 | ≥ 180 | — |
| approve → merge issued (`approve_to_merge`) | p50 | ≤ 60 | ≥ 180 | — |

## Stations (`station_health.py`, each scheduler tick)

Each station reports its waiting count, oldest wait, items out in the last 1 h and 24 h, last out time, stall
minutes and a status, written to `station-health.json` and `station-health.txt` in the runtime dir. It is stateless:
every run derives everything from local files (`units.json` and its archive, `~/.zenoforge/state/*.json`, the triage
batch logs, the advisor batch result files, `scheduler.log`, `alerts/events.md`), with no `gh` call.

**Decoupling rule: no station may hold another except through a named buffer.** A station's only input is its buffer
below; it never waits on, polls or blocks another station directly, and a stall is read from its own buffer and its
own out events. A unit waiting for a CI slot (`ci_wip_wait`) counts in the CI buffer, not the merge buffer, so a CI
stall is never charged to merge.

| Station | Named input buffer (waiting) | Out event | Stall bound (min) |
|---|---|---|---|
| intake | `state/N.json` `ready-for-agent` with no unit for that issue | a unit's first ledger event, or a `hold-handoff` event (a re-entry to an existing unit) | 90 |
| triage | `needs-triage` | triage batch log with `applied_count` > 0 (log mtime, count) | 360 |
| advisor | `needs-advisor` | advisor result `outcome: completed` (`applied_count`) | 810 |
| implement | units in `implement-pending` | `write-end` whose `write-start` has `work_type: implement` | 60 |
| review | units in `review-pending` or `rereview-pending` | `review-approve`, `review-request-changes`, `review-block` | 60 |
| repair | units in `repair-pending` | `write-end` whose `write-start` has `work_type: repair` | 90 |
| merge | units in `ready-to-merge` without `ci_wip_wait` | `merged`, `landed` | 150 |
| CI | `ready-to-merge` units with `ci_wip_wait` | `ci-ready`, `ci-wip-start` (a slot after a wait) | 100 |
| release | `awaiting-release` with `deploy_state` not `deployed` | `release-closer` line, one per closed issue; `release-retained` line, one per deploy (production changed, acceptance failed, nothing closed) | 950 |

The CI station is also its own process: `scheduler.sh --ci-admission` runs `ci_admission` every 120 s under its own lock with a
240 s bound (`AUTOPI_CI_ADMISSION_LIMIT_SECONDS`), not as a phase of the full tick, which took 1329-1668 s. Its `ci wip:` log line ends
with `deferred N`: the units the pass left for the next one (slot-sync budget spent, run list unavailable, or the bound reached),
which `0 ready unit(s) wait` alone did not show. The sync budget is the pass's free slots.
The merge lane can rerun a check that admission cancelled before `ci_wip_wait` is set; each such rerun logs one
`ci cancel-rerun unit=<id> head=<sha> run=<id>` line (decided from the cancel audit's latest reason for the run being `ci wip` or
`ci deferred`), so a day's count is one grep.

Status: `STALLED` when the buffer is not empty and the stall exceeds the bound, `PAUSED` while the pipeline pause
file exists (no alert), else `OK`. Stall minutes are `min(now - last out, oldest wait)` while something waits and 0
when nothing waits: a station that sat idle for days is not stalled by a ticket that arrived five minutes ago.
A `STATION-STALLED station=... waiting=... stall-min=... bound-min=...` line is appended to `alerts/node-health.md`
once per station per hour. No human step is involved.

Intake can take nothing on purpose: `register_new_issues` prints `intake held: ...` when startable pending meets the target, the
total ceiling is reached, or upstream has no room. The first such pass writes the time to the runtime file `intake-held-since` and
later held passes keep it (a marker file, so the station reads one small file, not `scheduler.log`); a pass that gets past those
checks removes it. While the marker is younger than 2 x the intake bound (180 min at the default 90) an intake that would be
`STALLED` reports `HELD` and raises no alert; past that it is `STALLED` again, so a hold cannot hide a real stop. The hold is
measured from the marker's content, not its file time. The held check runs before the candidate walk of the full pass; the
`existing_only` pass (`run_issue_intake_phases` runs it first) resumes known units from their ownerless handoffs and is not
bounded by the target (only by the total ceiling), so it still runs on a held tick. The `intake detail candidates secs=277s` of 2026-11-07 was that pass walking
its handoff rows, not the candidate walk (`consumed=24` only exists in that pass).

Bounds are 2 x the p90 gap between consecutive out events, rounded up to 10 minutes, measured on the 7 days to
2026-11-07T06:55Z (CI and release have too few events there, so their whole history is used). Measured p50 / p90 gap in minutes:

| Station | Out events | p50 | p90 |
|---|---|---|---|
| intake | 450 | 5.3 | 41.0 |
| triage | 91 | 32.1 | 176.9 |
| advisor | 59 | 41.0 | 401.2 |
| implement | 550 | 5.8 | 26.8 |
| review | 695 | 0.0 | 25.2 |
| repair | 450 | 11.0 | 42.0 |
| merge | 221 | 19.5 | 71.6 |
| CI | 335 | 13.4 | 47.2 |
| release (3 days, 14 closers) | 14 | 259.1 | 472.5 |

`config.template.json` `station_health.stall_minutes` carries the per-station bound (runtime `config.json` is
reconciled from it); the module holds the same numbers as defaults. A bound changes only with a new measurement, in
the same landing as this table.

Admission gaps in the same files say why a station waits, not only that it does: for implement and repair the gap
from the previous ledger event to `write-start`, for merge/CI the gap before `ci-ready`, and for review the gap from
the latest ledger event before the dispatch line (`type=review` or `type=rereview`) in `scheduler.log`. Review has no
start event in the ledger, so the dispatch line is its only start marker.

## Live CI (`ci_standards`, measured by `gen_dashboard.py` each tick)

| Number | Healthy | Unhealthy | Source |
|---|---|---|---|
| runners online (`runners_online`) | ≥ 15 | ≤ 12 | GitHub API `actions/runners` (cihost 12 + Mac 3) |
| PR runners busy while runs queue % (`pr_runner_busy_pct`) | ≥ 70 | ≤ 40 | `actions/runners` busy flag |
| queued workflow runs (`queued_runs`) | ≤ 40 | ≥ 100 | `actions/runs?status=queued` |
| ready units waiting for a CI slot (`wip_waiting`) | ≤ 30 | ≥ 60 | `units.json` `ci_wip_wait` (L77) |
| runs held for hot patches (`held_runs`) | ≤ 10 | ≥ 50 | `ci-held-runs.json` (L75) |

## Pipeline front (`front.standards`, measured by `gen_dashboard.py` each tick)

The dashboard's top section: issue intake by label, the advisor batch, triage, release wait. Bounds live in
`gen_dashboard.py` (`FRONT_STAGES`, `front_std`) and are emitted in `front.standards`; they are first-cut bounds
(2026-10-22), set from the observed cadence (triage and advisor tick every 5 minutes; release train every 15
minutes), not yet from a month of data. Change the number here and in the code together.

| Number | Healthy | Unhealthy | Source |
|---|---|---|---|
| `stage.needs-triage.count` / `.idle_hours` | ≤ 10 / ≤ 6 h | ≥ 30 / ≥ 24 h | GitHub GraphQL, open issues per label; idle = oldest `updatedAt` |
| `stage.finish-first.count` / `.idle_hours` | ≤ 20 / ≤ 48 h | ≥ 50 / ≥ 120 h | same |
| `stage.needs-info.count` / `.idle_hours` | ≤ 10 / ≤ 72 h | ≥ 30 / ≥ 168 h | same |
| `stage.needs-advisor.count` / `.idle_hours` | ≤ 10 / ≤ 12 h | ≥ 30 / ≥ 48 h | same |
| `stage.needs-recut.count` / `.idle_hours` | ≤ 5 / ≤ 24 h | ≥ 15 / ≥ 72 h | same |
| `stage.ready-for-agent.count` / `.idle_hours` | ≤ 60 / ≤ 168 h | ≥ 150 / ≥ 336 h | same |
| `stage.awaiting-release.count` / `.idle_hours` | ≤ 40 / ≤ 24 h | ≥ 80 / ≥ 72 h | same |
| `stage.awaiting-pipeline-sync.count` / `.idle_hours` | ≤ 3 / ≤ 2 h | ≥ 10 / ≥ 12 h | same |
| `advisor.job_age_min` | ≤ 20 | ≥ 60 | `advisor_batch_job_json` `started_at` (lib.sh) |
| `advisor.failures_today` | ≤ 2 | ≥ 6 | `logs/advisor-batch-*.result.json` outcome |
| `advisor.ruling_lag_hours` (only while `needs-advisor` is non-empty) | ≤ 6 | ≥ 24 | same, `applied_count > 0` |
| `advisor_loop.fail_pct_today` | ≤ 10 | ≥ 50 | `units.json` advisor-unavailable share (same line as `loop.advisor_fail_pct`) |
| advisor route reasons (measured, no bound) | — | — | `grep ' advisor-route ' scheduler.log`: one line per decision, `issue=#N reason=CODE outcome=routed\|fault`. Codes: `maintainer_needs_info`, `notes_not_mailable`, `precut_ladder`, `autonomy_gate`, `model_verdict_human`, `l2_freshness`, `reporter_undelivered` (`run-triage.sh`), `policy_step` (`run-triage-batch.sh`) |
| `triage.last_done_age_min` (only with a backlog) | ≤ 30 | ≥ 120 | `metrics/efficiency-*.jsonl`, `run-triage*.sh` stage-exited `needs-triage` |
| `triage.done_today` (only with a backlog) | ≥ 20 | ≤ 5 | same |
| `release.hold_hours` | ≤ 2 | ≥ 8 | `release-train.json` status + `alerts/release.md` RELEASE-HELD |
| `release.main_ahead_hours` | ≤ 6 | ≥ 24 | deployed SHA vs main head commit time |

Each section fails alone: a GitHub or lib.sh error shows "数据不可用" for that block only. GitHub counts are
cached 5 minutes in `front-cache.json` next to `dashboard.data.js`.

A metric UNHEALTHY for 3 hours files (or comments on) a `pipeline-system`, `priority:top` issue titled
`pipeline health: <metric> unhealthy`, at most every 6 hours (`--file-issues`): the pipeline reports and
repairs its own nodes without waiting for a health check.

Flow metrics (`flow.*`) also cross into the supervisor inbox: each crossing of the unhealthy bound
appends one `flow-metric` event (`--inbox`; the crossing record in `flow-inbox-state.json` clears when
the metric recovers, so the next crossing emits again). Regular flow samples only reach the dashboard.
`flow.main_red_hours` reads the #4356 bisect sessions under `$AGENT_HOME/main-red/` — a session still
in the state machine counts to now unless idle over 6 h (`MAIN_RED_OPEN_IDLE_HOURS`), and flaky/recovered/reverted/unattributed end at their last transition. `recovered` is written by the sweep when a later main run of the same workflow goes green on a descendant of the red SHA.
Rework rounds were already covered by `loop.rounds_p90` and `delivery.cycles_to_pass_30d`.

Reliability alert (#425): when `delivery.revert_rate_30d_pct` or `flow.main_red_hours` goes UNHEALTHY on a scorecard
under 2 h old, the scheduler logs a `reliability breach` line. It changes no limit. A metric clears only when back to OK, so
the WARN band holds it and the line does not flap; a missing, stale or unreadable scorecard logs nothing. The breached set
and its breach-start epoch (`since`) live in `reliability-breach.json`; each change logs once, and the line that clears the
set carries `secs=` (recovery minus `since`), the breach-to-recovery time.

Measured by hand on 2026-10-20 (not yet scored automatically, needs the GitHub API):

| Node | Metric | Healthy | Measured 24h |
|---|---|---|---|
| PR CI | `CI` pull_request wall p50 / p90 | ≤ 15 / 30 min [3] | — |
| PR CI | delivery-policy check (`CI` pull_request_target, a 1–2 min job) wall p50 | ≤ 5 min | — |
| PR CI | runner minutes on failed + cancelled jobs | ≤ 20 % | — |
| tokens | worker tokens per day | `daily_token_budget` 10M | — |

## Why these bounds catch the real failures

- Review-loop bounds: 86 distinct blocking findings across 258 reviews, none repeated. Each round finds
  new defects (one inspection pass removes roughly 50–65 % of defects [5]), so a large change that is
  repaired one finding at a time never converges. First-pass yield and rework share expose it before a
  single unit reaches 20 rounds.
- Workers and scheduler bounds: the 2026-10-20 restart storm (bell restarted every slow tick and the
  restart killed every worker) showed up as 40 deaths in 5 h and a 6–7 min tick period.
- Supervisor latency: escalations wait for the next health check; the median wait is 2.2 h.

## Work-order spend standards (one unit; past the bug bound it is a pipeline defect)

A single work order that costs this much is not "a hard issue": the pipeline wasted it, and the cause gets
found like any other defect. Bounds come from the 94 units delivered by 2026-10-21 (healthy ≈ p90, bug ≈ 2–4× p90);
open units past a bug bound are counted in `workorders.over_standard` and listed on the dashboard.
A held unit (`blocked-external`, `parked`, `supervisor-review`) is exempt from the age bound and counts on the spend bounds only if a worker of that unit ran inside the scorecard window; lifetime spend from before the hold does not age out otherwise.
The M1 `ci.cancel_*_per_day` rows read a rolling 24 h, not the scorecard window scaled to a day.
The same cost rows aggregate per ticket (all units of one issue) in `worker_cost.py`; the per-ticket
p90 metrics above derive their bounds from the last 30 days of closed tickets instead of a frozen table.

| Spend (id) | Delivered p50 / p90 | Healthy | Bug | Human baseline |
|---|---|---|---|---|
| worker fresh tokens, cache reads excluded (`unit.tokens`) | 0.53 M / 2.4 M (10-21, raw basis, superseded); fresh basis 2026-11-07: 165 of 816 delivered units with a complete cache split, p50 109 k, p90 544 k, p99 1.23 M. Footer-only runs excluded. Provisional until usage-capture lands and the basis is re-measured | ≤ 600 k | ≥ 1.2 M | — |
| worker minutes (`unit.worker_minutes`) | 25 / 90 | ≤ 90 | ≥ 240 | 2–4 h focused work for a small change (estimate) |
| request-changes rounds (`unit.rounds`) | 0 / 2 | ≤ 2 | ≥ 5 | most changes need 1–2 iterations [1] |
| hours from entry to merged (`unit.age_hours`; units waiting on a predecessor are exempt, and hours spent blocked or escalated (`blocked-on`/`supervisor-escalated`/park events up to `unblocked`/`supervisor-requeue`) are taken out of the age of a released unit) | 7.4 / 18.5 | ≤ 24 | ≥ 72 | elite lead time < 1 day [4] |

## Station standards (`station_standards.py`, each scheduler tick)

Every station in `station_health.py` `STATIONS` has one time, one tokens and one throughput standard, or a documented
exception. `station_standards.MATRIX` holds the mapping and `station-standards.test.sh` fails a station without one.
Each bound was measured on 2026-11-07 from the live ledger (`units.json` + archive), `scheduler.log`, triage batch logs
and worker cost rows; the window and sample count are on the row. For the new rows, healthy is the measured p75 and
unhealthy the measured p90 for time and tokens (rounded up to a whole minute or 1,000 tokens). Throughput is items out
per 24 h: healthy at the measured p25 and unhealthy at the measured p10 of the seven daily counts. (The p50 was the
first cut; the head chose p75 and p25 so that a normal day does not turn a tile amber by construction. Existing rows
keep their bounds.) Seven days give seven samples, so throughput bounds are a first measurement that a month of
samples should tighten. Time and token values use the same window as the other node metrics: time over 24 h, tokens
over the `--hours` window of worker runs.

| Station | Dimension | Metric (id) | Healthy | Unhealthy | Source (live, window, n) |
|---|---|---|---|---|---|
| merge | time | merge wait, previous event to merged, min p50 (`merge.wait_p50_min`) | ≤ 31 | ≥ 41 | 7 d to 2026-11-07T13:13Z, 221 merged/landed events: p75 30.8, p90 41.0 min |
| ci | time | CI wait, previous event to ci-ready, min p50 (`ci.admission_p50_min`) | ≤ 0 | ≥ 17 | 7 d, 342 ci-ready events: p75 0.0, p90 16.1 min |
| triage | tokens | triage tokens per issue p50 (`triage.tokens_per_issue_p50`) | ≤ 152,000 | ≥ 210,000 | 7 d, 91 batch logs (tokens_used / issue_sample_size): p75 151,725, p90 209,961 |
| implement | tokens | worker tokens per implement run p50 (`implement.tokens_p50`) | ≤ 392,000 | ≥ 555,000 | 7 d, 557 runs with measured tokens: p75 391,729, p90 554,952 |
| review | tokens | worker tokens per review run p50 (`review.tokens_p50`) | ≤ 258,000 | ≥ 324,000 | 7 d, 24 runs with measured tokens (small n): p75 257,372, p90 323,831 |
| repair | tokens | worker tokens per repair run p50 (`repair.tokens_p50`) | ≤ 230,000 | ≥ 307,000 | 7 d, 292 runs with measured tokens: p75 229,149, p90 306,942 |
| intake | throughput | intake items out per 24 h (`intake.out_per_day`) | ≥ 37 | ≤ 25 | 7 daily counts to 2026-11-07T13:13Z: p25 37, p10 25 |
| triage | throughput | triage issues applied per 24 h (`triage.out_per_day`) | ≥ 9 | ≤ 5 | 7 daily counts: p25 9, p10 5 |
| advisor | throughput | advisor rulings applied per 24 h (`advisor.out_per_day`) | ≥ 3 | ≤ 2 | 7 daily counts: p25 3, p10 2 |
| implement | throughput | implement write-ends per 24 h (`implement.out_per_day`) | ≥ 51 | ≤ 12 | 7 daily counts: p25 51, p10 12 |
| review | throughput | review verdicts per 24 h (`review.out_per_day`) | ≥ 48 | ≤ 37 | 7 daily counts: p25 48, p10 37 |
| repair | throughput | repair write-ends per 24 h (`repair.out_per_day`) | ≥ 34 | ≤ 19 | 7 daily counts: p25 34, p10 19 |
| merge | throughput | merges per hour, existing `flow.merge_rate_per_hour` (#4355 SLO) | ≥ 6.5 | ≤ 3.5 | existing row above; not re-measured here |
| ci | throughput | CI slots admitted per 24 h (`ci.out_per_day`) | ≥ 28 | ≤ 13 | 7 daily counts: p25 28, p10 13 |

Pipeline steps outside the stations (the node map), measured the same way:

| Step | Dimension | Metric (id) | Healthy | Unhealthy | Source (live, window, n) |
|---|---|---|---|---|---|
| rereview | time | rereview run minutes p50 (`rereview.wall_p50`) | ≤ 13 | ≥ 17 | 7 d, 364 rereview runs with output: p75 12.3, p90 16.1 |
| rereview | tokens | rereview worker tokens per run p50 (`rereview.tokens_p50`) | ≤ 200,000 | ≥ 200,000 | 7 d, 6 rereview runs with measured tokens of 376 (small n, provisional): p75 199,330, p90 199,330; healthy equals unhealthy, so no WARN band |
| rereview | throughput | rereview worker runs started per 24 h (`rereview.runs_per_day`) | ≥ 35 | ≤ 10 | 7 daily counts from worker cost rows: p25 35, p10 10 |
| approve | throughput | review approvals per 24 h (`approve.out_per_day`) | ≥ 35 | ≤ 30 | 7 daily counts of review-approve events: p25 35, p10 30 |
| approve | time | approve to merged, CI included (`ci.approve_to_ship_p50`) | ≤ 60 | ≥ 180 | existing row above |

Existing standards that cover the other cells (bounds unchanged here, with their rationale in the table above):
`implement.wall_p50`, `review.wall_p50`, `repair.wall_p50` (time, run minutes), `advisor.last_answer_age_hours` (advisor time),
`release.hours_waiting` (release time), `ci.approve_to_ship_p50` (approve to merged, CI included).

Exceptions, with the reason each dimension cannot be measured (no row is faked):

| Station | Dimension | Reason |
|---|---|---|
| intake | time | not measured: `state/N.json` keeps only the current `state_changed_at`, so the time an issue waited as ready-for-agent is lost once it leaves |
| intake | tokens | no model call in `scheduler.d/intake.sh` |
| triage | time | not measured: state files keep only the current state, so an issue's entry time into needs-triage is lost |
| advisor | tokens | not measured: the advisor batch result JSON has no token field |
| merge | tokens | no model call in `merge-prep.sh` or `merge-pr` |
| ci | tokens | no model call in `scheduler.d/ci-admission.sh` (CI runner minutes are `ci.waste_runner_pct`) |
| release | tokens | no model call in `run-release.sh` |
| release | throughput | points at `release.hours_since_release` on the release-age branch (#635, not merged here): release cadence is scored there, so this file carries no separate bound |
| PR CI | time | not measured by node_health: the CI run wall time needs the GitHub Actions run API, a gh call this tick does not make; the only figure is a hand measurement from 2026-10-20 |
| PR CI | throughput | not measured: no local record counts completed CI runs; `ci.out_per_day` counts admissions, not runs |
| PR CI | tokens | no model call in the PR CI workflow |
| Postsubmit | throughput | not measured: no local record counts Postsubmit runs on main; main merges are counted by `flow.merge_rate_per_hour` |
| Postsubmit | tokens | no model call in the Postsubmit workflow |

## Sources

1. Sadowski et al., "Modern Code Review: A Case Study at Google", ICSE-SEIP 2018 — https://research.google/pubs/modern-code-review-a-case-study-at-google/ (latency figures as quoted by https://graphite.com/blog/how-google-does-code-review).
2. SmartBear / Cisco code review study (widely cited: ≤ 400 LOC per session, ≤ 60–90 min).
3. Kent Beck / Martin Fowler, the ten-minute build (Extreme Programming, Continuous Integration).
4. DORA State of DevOps 2024 (elite change failure rate < 5 % per https://rdel.substack.com/p/rdel-68-what-are-the-latest-benchmarks); verify against dora.dev before tightening.
5. Capers Jones, defect removal efficiency of formal inspections (widely cited 50–65 % per pass).
6. M. E. Fagan, "Advances in Software Inspections", IEEE TSE 12(7), 1986 — follow-up verifies that every reported defect was fixed and that no new ones came in with the rework: https://doi.org/10.1109/TSE.1986.6312976

Pre-review self-check (2026-10-24) reuses `review.first_pass_pct` (healthy ≥50%, bug ≤30%) and `loop.rework_token_pct` (healthy ≤35%, bug ≥50%). Native Codex streams use `usage_reader.py` cumulative counters minus the dispatch baseline; unavailable baselines report N/A. Self-fix remains repair spend. Supervisor baseline: 0% first-pass approval, 91% rework plus recheck.
