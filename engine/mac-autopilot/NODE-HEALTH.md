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
| implement | run minutes p50 (`implement.wall_p50`) | 2–4 h focused work (estimate) | ≤ 30 | ≥ 60 | — |
| implement | runs with no report % (`implement.no_output_pct`) | — | ≤ 5 | ≥ 15 | — |
| implement | overlapping writer unit pairs in a rolling 24h (`dispatch.collisions_per_day`) | #4190/#4192/#4193 concurrently edited the same 8000+ line hook; write-start/end record predicted + actual paths, waits do not count; since the 2026-10-29 zf-ab ruling a pair whose only overlap is a `footprint_mutex.shared_append` registry file is the legalized parallelism, not a collision (those conflicts move to the rebase metric below) | 0 | ≥ 1 | — |
| review | first review minutes p50 (`review.wall_p50`) | first response < 1 h for small changes, < 4 h overall at Google [1]; one session ≤ 60 min, 200–400 LOC/h [2] | ≤ 10 | ≥ 20 | — |
| review | approved on first review % (`review.first_pass_pct`) | most changes need 1–2 iterations (estimate; [1] measured iterations, median not verified) | ≥ 50 | ≤ 30 | — |
| repair | run minutes p50 (`repair.wall_p50`) | 15–60 min per round (estimate) | ≤ 15 | ≥ 30 | — |
| review loop | request-changes rounds before approve p90 (`loop.rounds_p90`) | 2–3 (estimate) | ≤ 3 | ≥ 5 | — |
| review loop | repair (including pre-review self-fix) + rereview share of tokens % (`loop.rework_token_pct`) | — | ≤ 35 | ≥ 50 | — |
| review loop | repairs followed by an incremental rereview % (`loop.incremental_rereview_pct`) | Fagan follow-up: the moderator verifies the rework, not a new inspection [6] | ≥ 60 | ≤ 30 | — |
| workers | no-output events in window (`workers.deaths`) | — | ≤ 2 | ≥ 8 | — |
| CI + merge | approve → merged/landed min p50, waiting units count their age (`ci.approve_to_ship_p50`) | ten-minute build [3]; elite lead time < 1 day [4] | ≤ 60 | ≥ 180 | — |
| CI + merge | approved units that then saw CI red % (`ci.red_after_approve_pct`) | elite change failure ≈ 5 % [4] | ≤ 15 | ≥ 30 | — |
| CI + merge | local prechecks skipped because affected packages could not be selected (`ci.precheck_setup_failures`) | 0; this setup failure can make CI the first test run | 0 | ≥ 1 | — |
| supervisor | escalation → decision min p50 (`supervisor.latency_p50`) | ≤ 60 (estimate, on-call style) | ≤ 60 | ≥ 180 | — |
| scheduler | seconds between tick starts p50 (`scheduler.tick_gap_p50`) | — | ≤ 240 | ≥ 420 | — |
| release | current release batch wait in hours (`release.hours_waiting`) | elite: deploy on demand, lead time < 1 day [4] | ≤ 4 | ≥ 12 | — |
| release | production hot patches whose PR is not on main (`release.hotpatch_blockers`) | a hotfix is merged the same day | 0 | ≥ 1 | — |
| pipeline | open agent PRs outside the ledger (`pipeline.orphan_prs`) | — | ≤ 3 | ≥ 10 | — |
| work orders | open work orders past a spend bug bound (`workorders.over_standard`) | — | 0 | ≥ 3 | — |
| work orders | per-ticket worker tokens p90, tickets closed in 7 d (`workorders.ticket_tokens_p90`) | thresholds derive per tick from the preceding 30 d of closed tickets — healthy p50 x 1.5, unhealthy p90 x 2 (`worker_cost.ticket_bound`); the columns here are the 2026-10-21 frozen fallback | ≤ 800 k | ≥ 4.8 M | first scorecard sample |
| work orders | per-ticket worker wall minutes p90, tickets closed in 7 d (`workorders.ticket_wall_p90`) | same history-derived bounds (p50 x 1.5 healthy, p90 x 2 unhealthy) | ≤ 38 | ≥ 180 | first scorecard sample |
| CI + merge | CI runner minutes that could not change a verdict % (`ci.waste_runner_pct`, from `ci_spend.py`) | lean: work that cannot change the outcome is waste (muda) | ≤ 20 | ≥ 35 | — |
| CI + merge | ready-to-merge units whose CI is held for hot patches % (`ci.held_ready_pct`) | priority must not become starvation | ≤ 20 | ≥ 50 | — |
| CI + merge | M1 audited cancelled runs/day: ci deferred (`ci.cancel_deferred_per_day`) | frozen M1: 1,029 / 3.94 days | 0 | ≥ 261 | rolling report |
| CI + merge | M1 audited cancelled runs/day: ci wip (`ci.cancel_slot_wait_per_day`) | frozen M1: 838 / 3.94 days | 0 | ≥ 213 | rolling report |
| CI + merge | M1 audited cancelled runs/day: repair dispatched (`ci.cancel_repair_per_day`) | frozen M1: 698 / 3.94 days | ≤ 177 | ≥ 354 | rolling report |
| CI + merge | M1 audited cancelled runs/day: tests already red (`ci.cancel_tests_red_per_day`) | frozen M1: 244 / 3.94 days | ≤ 62 | ≥ 124 | rolling report |
| CI + merge | M1 audited cancelled runs/day: review requested changes (`ci.cancel_review_changes_per_day`) | frozen M1: 237 / 3.94 days | 0 | ≥ 60 | rolling report |
| CI + merge | M1 audited cancelled runs/day: review blocked (`ci.cancel_review_blocked_per_day`) | frozen M1: 8 / 3.94 days | ≤ 2 | ≥ 5 | rolling report |
| CI + merge | M1 audited cancelled runs/day: parked (`ci.cancel_parked_per_day`) | frozen M1: 3 / 3.94 days | ≤ 1 | ≥ 2 | rolling report |
| CI + merge | M1 audited cancelled runs/day: other or unclassified (`ci.cancel_other_per_day`) | no frozen cause baseline | 0 | ≥ 1 | rolling report |
| CI + merge | active agent PRs with server label `agent/ci-gated` % (`ci.gated_pr_pct`, M12) | frozen M12: 0 of 87 | ≥ 80 | ≤ 50 | GitHub open-PR census |
| CI + merge | distinct runs held by priority CI gate in last 48 h (`ci.priority_hold_runs_48h`, M13) | retire only after a full 48 h with zero firings | 0 | ≥ 1 | shared cancellation audit |
| CI + merge | shared-append landings whose rebase conflicted on a shared-append file %, rolling 24 h (`ci.shared_append_rebase_conflict_pct`) | first-cut bound (2026-10-30): the ruling trades occasional rebase conflicts for parallel implement on append-registry files; a day of samples above the bound means tighten the list back to mutual exclusion | ≤ 25 | ≥ 50 | first scorecard sample 2026-10-30 |
| review loop | ledger PRs over 800 changed lines %, rolling 30 d by ledger activity (`review.large_pr_pct`, from `pr-sizes.json`; active PRs without history are included and missing sizes report no data; the all-time share was a metric bug — one-off oversized PRs never aged out and recovery required dilution, #4482) | small batches: review effectiveness drops past 200–400 LOC [2] | ≤ 10 | ≥ 25 | — |
| workers | local test Postgres reachable (`workers.local_test_db`, TCP probe of `PGTEST_URL`) | shift left: run integration tests before review, not after approval | 1 | 0 | — |
| host | host services from `host-prereqs.json` that do not answer (`host.prereqs_missing`; names printed as `host missing:`) | every dependency of a machine is declared and probed (infrastructure as code) | 0 | ≥ 1 | — |
| host | GitHub fetch/API network failures per hour from the user journal (`host.github_net_failures_per_hour`): final `origin fetch failed`, `git fetch: timed out after`, `api.github.com` TLS handshake timeout | every unit that talks to GitHub reaches it (on WSL only through the egress proxy) | ≤ 2 | ≥ 10 | — |
| host | worktrees under `~/wt` older than 2 h (`host.stale_worktrees`, age of each worktree's `.git` link) | a finished run removes its workspace on every exit path; removal never waits on the network | ≤ 10 | ≥ 40 | — |
| review loop | Advisor asks without a ruling % (`loop.advisor_fail_pct`) | maintainer 10-22: advisor decides after 2 rejected rounds | ≤ 10 | ≥ 50 | — |
| review loop | REQUEST-CHANGES reports without a machine-readable findings block % (`review.findings_missing_pct`, from `review_findings` in `units.json`) | recurrence and per-round history are only as good as the data: a missing block is counted, never read as zero findings | ≤ 5 | ≥ 20 | — |
| delivery | issue created → release accepted p50, rolling 7 d / 30 d hours (`delivery.issue_to_accept_p50_7d_hours`, `delivery.issue_to_accept_p50_30d_hours`) | DORA elite lead time < 1 day [4]; same bound as `unit.age_hours` | ≤ 24 | ≥ 72 | first scorecard sample |
| delivery | issue created → release accepted p95, rolling 7 d / 30 d hours (`delivery.issue_to_accept_p95_7d_hours`, `delivery.issue_to_accept_p95_30d_hours`) | engineering estimate: healthy is three days; one week is a stalled delivery | ≤ 72 | ≥ 168 | first scorecard sample |
| delivery | fully linked units accepted in the last 30 d that have since been reverted % (`delivery.revert_rate_30d_pct`) | elite change failure rate < 5 % [4]; 10 % is twice that bound | ≤ 5 | ≥ 10 | first scorecard sample |
| delivery | dated root-cause incident records per 100 release-accepted issue IDs % (`delivery.incident_rate_30d_pct`) | change-failure proxy [4]; no frozen incident-per-unit baseline yet, so 5 / 10 % are the same initial bands as reverts | ≤ 5 | ≥ 10 | first scorecard sample; unlinked incident records remain separately visible |
| delivery | review rounds through the first approval per merged unit (`delivery.cycles_to_pass_30d`) | Anthropic reported 1.32 reviews-to-pass after its change; the product's pre-pause 112 delivered units averaged 2.28 approvals [alignment §9] | ≤ 1.32 | ≥ 2.28 | first scorecard sample |
| delivery | scheduler approvals per merged unit (`delivery.approvals_per_merge_30d`) | one successful approval is sufficient; the product pre-pause average was 2.28 per delivered unit [alignment §9] | ≤ 1 | ≥ 2.28 | first scorecard sample |
| delivery | human GitHub PR review actions per merged PR (`delivery.human_actions_per_merge_30d`) | one real review action is an exception; two or more indicate repeated manual handling (estimate) | ≤ 1 | ≥ 2 | first scorecard sample; excludes the required user-path acceptance |
| delivery | release-accepted issue records missing a unique issue → unit → PR → merge → release join (`delivery.unlinked_units_30d`) | exact IDs are required; guessing a missing edge would falsify lead time | 0 | ≥ 1 | first scorecard sample |
| delivery | root-cause incident records without an explicit accepted-issue link (`delivery.unlinked_incidents_30d`) | exact issue link required; a record naming no issue (`issue` field or "Issue #N" in what_happened) is not linkable and is reported as `incident_unreferenced_30d`; a named issue that was never accepted is unlinked | 0 | ≥ 1 | first scorecard sample |
| delivery | maintainer-login PR review actions without reliable human/agent attribution (`delivery.human_actions_unattributed_30d`) | unknown attribution is not counted as human | 0 | ≥ 1 | first scorecard sample |
| flow | merges per hour vs the 6.5 target; a starved queue (nothing open, nothing entered) reports no value (`flow.merge_rate_per_hour`) | #4355 SLO: ≥ 6.5 merges/h with sufficient backlog; 3.5/h was the pre-upgrade serial merge-lane ceiling | ≥ 6.5 | ≤ 3.5 | first scorecard sample |
| flow | worst per-stage p90 age of open units, hours (`flow.wip_age_stage_p90_hours`; per-stage rows in scorecard `flow.wip_age`) | #4355 SLO: median ticket cycle ≤ 2 h; p90 stage age ≤ 4 h is consistent with it (estimate), half a day in one stage is stalled | ≤ 4 | ≥ 12 | first scorecard sample |
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

`release.hours_waiting` measures the current pending release batch. `release_train.sh` tracks first-seen times for
issues the selector confirms are pending, including dispatched batches, active units, capacity and cadence waits,
and release dispatch gates. It preserves known starts across retries and holds, and clears them when the selector
reports no eligible pending work. Stale labels that fail release-state validation do not count. The metric does not
reuse a prior `release-closer` timestamp, which would count idle time before the current batch existed.

Delivery metrics use fixed rolling 7-day and 30-day windows. Release acceptance time comes from the batch close
event written by `run-release.sh` as `release-closer: deployed=<sha> closed=[issue IDs]`; lead time starts at GitHub issue `createdAt`, and the
scheduler unit must carry the exact issue, PR and merge-history fields. GitHub `closedAt` is not used as acceptance
time because an issue can close before release acceptance. The unit's `merge_sha` must match GitHub's
`mergeCommit.oid`; the batch event's deployed SHA is its attestation that the merge reached production. A missing,
ambiguous or incomplete edge increments `delivery.unlinked_units_30d` and is excluded from lead-time samples and the
revert-rate sample, which needs the linked merge SHA. Reverts are matched by the Git commit message marker
`This reverts commit <merge_sha>.` on `origin/main`, and only count when the revert commit follows acceptance.
Incident rate is the number of dated root-cause records divided by the number of unique issue IDs in release-closer
acceptance events in the same 30-day window; the issue → unit → PR → merge join is not required for this denominator.
Incident linkage compares the record's explicit issue ID with those accepted IDs; missing or unmatched IDs remain
visible in `delivery.unlinked_incidents_30d`. Human actions count GitHub PR review records:
bot logins and explicit bot markers are excluded, scheduler review timestamps identify agent decisions made under
the maintainer login, and PR bot markers / Codex or ZCode commit trailers leave unmatched maintainer-login actions
unattributed instead of counting them as human. This is a review-action measure; the real user-path acceptance
performed with a real user remains separate. GitHub census and missing-ID reads use bounded parallel calls with per-call
and batch deadlines; an unavailable issue or PR source stays unknown rather than becoming a zero sample.

The first delivery bounds use existing measured baselines where available and mark estimates above. The 30-day
review values are intentionally a separate cohort from `--hours`; scorecard JSON carries its accepted, merged,
unlinked and unattributed sample counts under `delivery`.

M1 counts distinct run IDs from the shared cancellation audit in the rolling `--hours` window and normalizes them to a 24-hour rate. For causes expected to disappear with gating, zero is healthy and the frozen pre-change rate is the bug bound; other known causes use the frozen rate as the healthy ceiling and twice that rate as the bug bound. New or unclassified causes use 0 / 1 until there is a frozen baseline. Repeated audit attempts for one run count once. M12 reads the provider label on currently open `agent/issue-*` PRs. M13 counts distinct `ci hold` run IDs over 48 hours; zero is the retirement signal, not a measured before/after comparison.

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
in the state machine counts to now, flaky/reverted/unattributed end at their last transition.
Rework rounds were already covered by `loop.rounds_p90` and `delivery.cycles_to_pass_30d`.

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
The same cost rows aggregate per ticket (all units of one issue) in `worker_cost.py`; the per-ticket
p90 metrics above derive their bounds from the last 30 days of closed tickets instead of a frozen table.

| Spend (id) | Delivered p50 / p90 | Healthy | Bug | Human baseline |
|---|---|---|---|---|
| worker tokens (`unit.tokens`) | 0.53 M / 2.4 M (10-21); per-ticket p90 13.9 M (7 d to 10-29) | ≤ 14 M | ≥ 28 M | — |
| worker minutes (`unit.worker_minutes`) | 25 / 90 | ≤ 90 | ≥ 240 | 2–4 h focused work for a small change (estimate) |
| request-changes rounds (`unit.rounds`) | 0 / 2 | ≤ 2 | ≥ 5 | most changes need 1–2 iterations [1] |
| hours from entry to merged (`unit.age_hours`; units waiting on a predecessor are exempt) | 7.4 / 18.5 | ≤ 24 | ≥ 72 | elite lead time < 1 day [4] |

## Sources

1. Sadowski et al., "Modern Code Review: A Case Study at Google", ICSE-SEIP 2018 — https://research.google/pubs/modern-code-review-a-case-study-at-google/ (latency figures as quoted by https://graphite.com/blog/how-google-does-code-review).
2. SmartBear / Cisco code review study (widely cited: ≤ 400 LOC per session, ≤ 60–90 min).
3. Kent Beck / Martin Fowler, the ten-minute build (Extreme Programming, Continuous Integration).
4. DORA State of DevOps 2024 (elite change failure rate < 5 % per https://rdel.substack.com/p/rdel-68-what-are-the-latest-benchmarks); verify against dora.dev before tightening.
5. Capers Jones, defect removal efficiency of formal inspections (widely cited 50–65 % per pass).
6. M. E. Fagan, "Advances in Software Inspections", IEEE TSE 12(7), 1986 — follow-up verifies that every reported defect was fixed and that no new ones came in with the rework: https://doi.org/10.1109/TSE.1986.6312976

Pre-review self-check (2026-10-24) reuses `review.first_pass_pct` (healthy ≥50%, bug ≤30%) and `loop.rework_token_pct` (healthy ≤35%, bug ≥50%). Native Codex streams use `usage_reader.py` cumulative counters minus the dispatch baseline; unavailable baselines report N/A. Self-fix remains repair spend. Supervisor baseline: 0% first-pass approval, 91% rework plus recheck.
