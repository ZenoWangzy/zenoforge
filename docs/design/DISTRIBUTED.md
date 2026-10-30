# Distributed Zenoforge: several hosts, one pipeline, any OS

> **Status: design, nothing here is implemented.** Audience: engine maintainers. File and line references were read from the working `engine/` tree on 2026-10-29 (the export of the upstream pin current that day). Lines drift with every re-export: the function or variable name is the stable anchor, and `grep -n` recovers the line. Numbers marked *design target* are not measurements.

## 0. What this document decides

1. Several hosts can run one Zenoforge pipeline on the same target repository without doing the same work twice or fighting over the same ticket, PR, merge or release.
2. GitHub is the only shared substrate. Ownership lives in git refs (`refs/claims/*`), host visibility in git refs (`refs/status/*`), workflow state stays where it already is (labels, PRs, runs).
3. Single-host mode stays the default. With coordination off the engine makes no extra network call and behaves as today.
4. The engine becomes runnable on Linux (with or without systemd), macOS, and Windows (through WSL2) through the portability layer specified in `docs/design/PORTABILITY.md` (summarized in section 8), not by rewriting the scripts.
5. The coordination work is cut into 16 independently landable tickets, the config seam first (section 9); the portability tickets PT-1 to PT-10 live in `docs/design/PORTABILITY.md`. The acceptance test is a two-host fault-injection harness that runs in CI (section 7).

Reading guide: sections 1 to 3 are the problem and the shape of the answer; 4 is the protocol; 5 maps every existing lock and state file; 6 and 7 are failure modes and the harness; 8 is how portability and the fleet fit together; 9 and 10 are tickets and rollout.

---

## 1. Problem statement

### 1.1 What goes wrong today when a second host runs the same engine

Everything the engine knows about "who is working on what" lives on one machine. Start the engine on host B next to a running host A and these things happen, each traced to code:

| # | Scenario | Why it happens |
|---|---|---|
| 1 | B starts `zf-triage-7` while A's `zf-triage-7` runs. Two triage verdicts, two comments, two label transitions. | The only "is this ticket already running" test is `stage_unit_active` (`engine/lib.sh:13280`), which asks the local `systemctl --user`. The header says it outright: "The transient units ARE the ledger" (`engine/lib.sh:13196`). Another host's units are invisible, so absence reads as "inactive". |
| 2 | Per-stage caps double. `TRIAGE_CAP=8` (`engine/issue-pipeline.sh:133`) means 8 per host, and `cap_slots_remaining` is computed from `stage_unit_count` (`engine/lib.sh:13381`, used at `engine/issue-pipeline.sh:1672`, `:1950`), again local. | Same cause. |
| 3 | Two merge lanes. A and B both merge approved PRs; both file post-merge verification and main-red recovery for the same SHA. | The unit loop serializes merges by being a single scheduler tick under `SCHED_LOCK` (`engine/mac-autopilot/scheduler.sh:6675`, a local `mkdir` lock whose staleness test is `kill -0` on a local pid). The issue loop's `MERGE_LOCK_FILE` (`engine/lib.sh:291`) is a local flock. `gh pr merge` itself is safe (head-pinned, `engine/mac-autopilot/scheduler.sh:5392`) but everything around it is not. |
| 4 | Two release trains, two deploys. | `run_release_train` (`engine/mac-autopilot/scheduler.sh:6408`) asks `systemctl --user is-active zf-release-train` and a stamp file in the local runtime directory. `deploy-blocked-sha` is a local file (`engine/lib.sh:307`). |
| 5 | Two revert PRs for one red main; duplicate pipeline issues; duplicate alert mail. | `pipeline-issue-upsert.sh:52` says it in a comment: "a local per-class lock prevents same-host create races; multi-host writers need a shared claim". Alert dedupe is a local inbox (`engine/lib.sh:131` to `:282`). |
| 6 | When A dies, B cannot resume A's tickets. | Per-ticket progress (`attempts`, advisor decisions, recut children, review rounds) lives only in `$AGENT_HOME/state/<n>.json` and the unit ledger `units.json`, both local. |
| 7 | B burns a provider quota A already exhausted. | Cooldown and quota markers are local files (`engine/mac-autopilot/scheduler.sh:583`, `engine/lib.sh:15762`). |
| 8 | Every host re-reads the same GitHub state and they share one token. | Measured on the origin deployment, one host, one hour: 2,779 `gh` calls, about 2,300 once one defective call site (506 per hour) was fixed. Two hosts on one identity would use most of the 5,000 per hour budget before any worker makes a call of its own (only part of those calls are REST; issue and PR listings are GraphQL, which has its own budget). |

### 1.2 Constraints this design must satisfy

- **Reuse mature components.** Git ref updates with expected-old-value are the compare-and-swap; GitHub is the store; systemd, launchd, `flock` and the host's own tools are used where they exist. No new server.
- **No over-defense.** Each check below names the failure it stops (section 6 repeats the list).
- **N hosts.** Every mechanism says where its state lives, how the lock is taken, and what stays host-local.
- **Scion principles** (from the origin deployment's code-factory research): no global lock service, server-side operations through an API, no shared mutable refs, test after merge rather than serialize before it, sparse on-demand clones.
- **Smallest complete change.** Prefer one choke point per behavior. The engine already has them: `dispatch` (`engine/issue-pipeline.sh:390`), `guarded_write` (`engine/lib.sh:4017`), `guarded_pr_merge` (`engine/lib.sh:4441`), `issue_transition` (`engine/lib.sh:1879`), `dispatch_if_room` and `room_for` in the unit loop (`engine/mac-autopilot/scheduler.sh:1721` to `:1760`).
- **Behavior-neutral by default.** Until the tool is switched on, a change must not alter what a Linux/systemd single host does. Every ticket states how that is shown.
- **Upstream mapping.** The engine is exported one way from a private upstream; every change here is a change to `engine/<path>` that maps 1:1 to the upstream path, until a planned cutover makes this repository the source of truth.

### 1.3 Prior art and what this document changes

The origin deployment ruled on multi-device coordination on 2026-09-16: claims as atomic refs `refs/claims/issue-N` (create-if-absent, compare-and-swap with `--force-with-lease`), 60 s renewal and 15 min lease, three-valued reads (present, confirmed absent, unknown), one ticket lease plus one repository-wide release lease, effect intents compare-and-swapped into the claim before every external mutation, a status branch with `workers/<host>.json`, and one acceptance measurement: 100 of 100 two-host fault-injection trials. This document keeps all of that and extends it where the ruling was silent or predates the code:

| Topic | Ruling | This design | Why |
|---|---|---|---|
| Unit loop | Not covered (it predates `scheduler.sh`) | Same claim keys cover units, plus lane leases for its merge, land, release and main-red phases (section 4.8) | The unit loop owns implement, review, repair, merge and the release train. |
| Status | One shared branch `agent-runtime/status`, writers fetch, replay and retry | One ref per host, `refs/status/<host>`, single writer, plain force-push | A shared tip forces a retry loop and contradicts "no shared refs". Content (`workers/<host>.json` schema) is unchanged. |
| Who renews | Unspecified | A timer-driven agent (`engine/coord/renewd.sh --once`, every 60 s) batches all renewals and the status publish into one push | The issue loop is a 5-minute oneshot; the unit loop is a 2-minute tick. Neither can renew every minute. |
| Renewal uncertainty | "Stops publication and cancels local model processes" | Quantified: self-fence at 600 s without a successful renewal (section 4.5) | Must finish before any observer can take over (900 s). |
| Takeover clock rule | Same expired record unchanged across a full locally measured lease | Same, plus a gap rule: a gap between reads longer than half a lease resets the observation | A suspended laptop or a stepped clock must not manufacture an interval. |
| Cutover | Drain old units, then install | `adopt-local`: the enabling host claims its own running units | A live deployment is rarely quiet; adoption removes the drain window. |
| Rollback lever | Not specified | `refs/coord/control` (drain list, primary host, minimum protocol) | One write from any machine steers every host. |
| Hash rule | Pipeline code never extracts or compares identifiers | Readback compares two opaque ref values; no digest files are created | Needed to resolve a lost acknowledgement (section 4.5). |

Parameters (60 s, 15 min) come from the ruling and were not measured on this engine. They are environment variables and the harness runs on a virtual clock, so changing them costs nothing.

---

## 2. The single-host inventory

### 2.1 Locks

Every `flock`, lock file and lock directory under `engine/`. "Where" gives the flock line or the enclosing function, whichever is the clearer anchor. "Verdict" says what happens to it with N hosts.

| # | Lock | Where | Mechanism | Protects | Verdict with N hosts |
|---|---|---|---|---|---|
| L1 | Tick decision lock | `engine/lib.sh:286`; `engine/issue-pipeline.sh:994` to `:1006`; `engine/issue-pipeline-slices.sh:5` | flock fd 9 on `$AGENT_HOME/lock`; slices inherit it; the release delegate waits `-w 600` | One host's tick decision section (it reads live `systemctl` state) | **Host-local, keep.** Cross-host exclusion comes from claims. |
| L2 | Merge lock | `engine/lib.sh:291`, `:14769` (`acquire_merge_lock`), `:14779`; taken at `engine/lib.sh:4543` | flock fd 8, bounded wait 70 min | The `gh pr merge` call in `guarded_pr_merge` | **Becomes `lane-merge`** (section 4.8). |
| L3 | Per-issue state lock | `engine/lib.sh:1399` (`state_file`), `:1697` (`state_merge`, flock at `:1711`), `:1879` (`issue_transition`, flock at `:1908`) | flock on `$STATE_DIR/<n>.json.lock` | Read-modify-write of `state/<n>.json`; label-plus-file transition | **Host-local, keep.** Recovery fields are projected into the claim (4.6). |
| L4 | Transition and metrics ledgers | `engine/lib.sh:1479` (`ticket_stage_record`, flock `:1495`), `:1426` (`efficiency_metrics_append_rows`) | flock plus append | `ticket-transitions.jsonl`, `metrics/efficiency-*.jsonl` | **Host-local, keep.** Append-only logs; consumers read per host. |
| L5 | Advisor ticket claim, label-churn lock | `engine/lib.sh:16374` (`advisor_ticket_lock_file`), `:16250` (`try_lock_nonblocking`); `engine/run-advisor.sh:94`; `engine/lib.sh:4655` | non-blocking flock per ticket | One advisor run, one label-churn check per ticket | **Becomes the ticket lease** with `stage=advisor`. |
| L6 | Provider session lease | `engine/lib.sh:16345` (`acquire_web_session_lease`) | flock on `web-session.lock` | One automated session of an optional advisor provider | **Host-local.** The session is bound to the machine. |
| L7 | Codex budget | `engine/lib.sh:11477` to `:11574` (flock `:11504`) | flock on `locks/codex-budget.lock` | Daily token reservations | **Host-local accounting.** Totals are published in the status ref; a global budget is not enforced (accepted by the ruling). |
| L8 | Provider quota markers | `engine/lib.sh:15762` to `:15860` | flock per provider | "Quota exhausted until T" | **Host-local file, published** in the status ref; peers on the same declared account honor it (4.9). |
| L9 | Scheduler ledger lock | `engine/mac-autopilot/scheduler.sh:6675` to `:6695`, `:309` to `:327`, `:6743` | `mkdir` lock plus pid, stale test `kill -0` | Writes to `units.json` and `workers.json` (slow tick versus 30 s refill) | **Host-local, keep.** |
| L10 | Views lock, shared state read | `engine/mac-autopilot/scheduler.sh:6712` to `:6728`; `:1097` to `:1098` | `mkdir` lock; `flock -sn` | One dashboard render; no read mid-transition | **Host-local, keep.** |
| L11 | Execution admission | `engine/execution-admission.py:481` (gate), `:532` to `:546` (slot locks), `:277` to `:279`; `engine/bin/luna:51` to `:54` | `fcntl.flock` gate plus N slot files plus a CPU sampler | Machine capacity: global cap, memory floor, load, CPU target | **Host-local by nature.** Capacity is per machine. |
| L12 | Land queue | `engine/land-queue.sh:580`, `:636` (allocator), `:1435`, `:1501`, `:1663` (per request), `:266`; `engine/land-direct-main.sh:160`, `:985` (preflight slot) | flock allocator, per-request and per-slot files | FIFO order of direct-main landings on one host | **Local FIFO stays; cross-host order becomes `lane-land`.** The final `git push origin HEAD:main` (`engine/land-direct-main.sh:1398`) is already an optimistic compare-and-swap; the lander rebases after losing (`land_main_rebase_after_advance`, `:1290`). |
| L13 | Release train, release delegate | `engine/mac-autopilot/scheduler.sh:6413` to `:6415`; `engine/issue-pipeline.sh:995` to `:1006` | stamp file plus `systemctl is-active zf-release-train` | One release train | **Becomes `lane-release`.** |
| L14 | Worktree reaper | `engine/worktree-lifecycle.sh:171`, `:2108` | flock per git common dir | `git worktree` metadata | **Host-local.** |
| L15 | Mail and health state | `engine/notify.sh:1289`, `:1416`; `engine/night/maintainer-health-mail.sh:66` to `:661` | flock plus files | Mail dedupe state | **Local files kept; repo-wide alerts also take an event claim** (4.8). |
| L16 | Supervisor inbox | `engine/lib.sh:184` to `:187` (`supervisor_inbox_append`), `:10295` (`supervisor_inbox_append_once`) | flock plus daily budget files | Alert budget and dedupe | **Local inbox; repo-wide kinds take an event claim.** |
| L17 | Issue creation | `engine/pipeline-issue-upsert.sh:53`; `engine/roadmap.sh:310` | flock per class (comment at `:52` flags the gap) | One GitHub issue per stable class | **Short lease** `lock-issue-create-<class>` held while the script reads the open issues and creates one. |
| L18 | Plain file read-modify-write | `engine/lib.sh:2756`, `:7043`, `:10042`, `:10529`, `:10742`, `:10865`, `:10911`, `:12608`, `:12931`, `:14330`, `:14939`; `engine/open-pr-snapshot.py:250`; `engine/model-policy-fast-forward.sh:16`; `engine/owner-stop-request.sh:18`; `engine/delivery-request.sh:42`; `engine/hand-completion-refill.sh:51`; `engine/gitnexus-wrapper.sh:44`, `:67`; `engine/night/*.sh`; `engine/mac-autopilot/test-evidence.py:15`, `:42` | flock on a local file | Local read-modify-write | **Host-local, unchanged.** Only the flock binary itself changes on macOS (section 8). |

Eighteen rows, 161 flock lines in 25 files. Only L2, L5, L13 and L17 plus the dispatch decision itself (L1's real job) need a cross-host replacement. The rest guard files that exist once per host and stay that way.

### 2.2 State files and where they would live

`$AGENT_HOME` is `~/.zenoforge` by default (`engine/lib.sh:18`; 16 files re-derive it on their own, 21 lines). The unit loop runtime is `<checkout>/.scratch-supervisor/autopi/` (`engine/mac-autopilot/runtime-env.sh:15`).

| State | Path and anchor | What it holds | Class |
|---|---|---|---|
| Per-ticket state | `$AGENT_HOME/state/<n>.json` (`engine/lib.sh:25`, `:1399`) | attempts, model-policy active step and failures, advisor decision, recut children, hold, delivery and deploy state, conclusion, last failure, unit results | **Recovery-critical subset goes remote** (checkpoint); the file stays the local working copy |
| Unit ledger | `units.json` (`engine/mac-autopilot/scheduler.sh:91`) | per unit: id, stage, pr, branch, lane, footprint, approved SHA, review and repair history, `ci_*` facts, pids of self-check and precheck | **Subset goes remote**; `ci_*` and other GitHub-derived facts are rebuilt from GitHub |
| Worker ledger | `workers.json` (`:91`, written by `dispatch` at `:987`) | pid, unit, log, report, session id, workdir, token usage | **Host-local** |
| Runtime config | `config.json` (reconciled from `config.template.json`) | caps, models, budgets, footprint-mutex list | Host-local copy of a versioned template |
| Live policy | `$AGENT_HOME/model-policy.json` (`engine/lib.sh:335`) | role-to-model map | Host-local; its fingerprint is published for drift visibility |
| Cooldown, quota | `cooldown.json` (`engine/mac-autopilot/scheduler.sh:583`), quota markers (`engine/lib.sh:15762`) | provider unavailable until T | Host-local, **published** in status |
| Pause | `$AGENT_HOME/PAUSE` (`engine/lib.sh:287`), repo variables `AGENT_PIPELINE`, `AGENT_SUPERVISOR` | stop switches | PAUSE host-local; the variables are already global |
| Deploy-blocked, main-red | `deploy-blocked-sha` (`engine/lib.sh:307`), `main-red/` (`:308`), `gate-net-rerun.json` | release block, red-main recovery sessions | **Move to the lane claims' checkpoints** |
| Land queue | `$AGENT_HOME/land-queue/` (`engine/land-queue.sh:5`) | FIFO of landing requests | Host-local FIFO |
| Capacity admission | `$AGENT_HOME/locks/execution-*.lock`, `execution-*.json`, `execution-cpu.json` (`engine/execution-admission.py:273` to `:290`, `:481` to `:577`; `AGENT_GLOBAL_EXECUTION_CAP`, memory floor, load limit) | which slots are leased, CPU sample, owner identity from `/proc` start ticks and `boot_id` | **Host-local by nature**; running and cap counts are published in status |
| Worker pool (wrapper path) | `$WORKER_SCRATCH_ROOT/luna/<key>/` (events, last message, rc), `failover`, `rounds.log`, `tmp/luna-breaker`, `tmp/zc-breaker` (`engine/bin/worker`, `engine/bin/luna:25` to `:54`; `LUNA_MAX` default 10) | backend choice by runs in flight, breakers, escalation round counts | **Host-local**; breaker state is part of the published provider state |
| Ledgers and logs | `state/ticket-transitions.jsonl`, `metrics/efficiency-*.jsonl`, `logs/`, `scheduler.log`, `alerts/*.md`, `supervisor-inbox` | history and alerts | Host-local |
| Caches | `pr-run-snapshot.json` (`engine/mac-autopilot/runtime-env.sh:68`), `night/pr-details-cache.json`, open-issue caches | read caches; the snapshot comment says "GitHub has none of it, other hosts rebuild their own" | Host-local |
| Workers' workspace | worktrees (`WT_ROOT`, `engine/mac-autopilot/scheduler.sh:105`), `$WORKER_SCRATCH_ROOT/luna/<key>/`, breaker files, `rounds.log`, agent CLI sessions | in-flight work, resumable sessions | **Host-local.** Unpublished work is lost when a host dies (accepted). |
| Pinned code | `<checkout>/.scratch-supervisor/autopi-versions/<sha>`, `autopi-live` symlink (`engine/mac-autopilot/start.sh`) | the unit loop's running code version | Host-local |

### 2.3 Places that assume one host

| # | Assumption | Where |
|---|---|---|
| A1 | **Local unit absence means the ticket is inactive** | `stage_unit_active` (`engine/lib.sh:13280`), `stage_unit_count` (`:13381`), `stage_active_issues` (`:13511`); four more call sites in `lib.sh` (`:8124`, `:15310`, `:15388`, `:15609`); about twenty `stage_unit_*` calls in `engine/issue-pipeline.sh` (`:266`, `:866`, `:1672`, `:1677`, `:1740`, `:1831`, `:1950`, `:1965`, `:2311`, others); `issue_has_live_unit` (`engine/supervise-pipeline.sh:140`); `scheduler_size_recut_active` (`engine/mac-autopilot/scheduler.sh:1101`); `systemctl is-active zf-release-train` (`:6414`) |
| A2 | **Local pid checks as liveness** | `alive()` runs `ps -p` (`engine/mac-autopilot/scheduler.sh:307`); `pid_running` reads `/proc/<pid>/stat` (`engine/mac-autopilot/loop.sh:62`); stale-lock test `kill -0` (`scheduler.sh:6681`, `:6721`); worker identity by pid plus start time (`:1635`); admission identity from `/proc` start ticks and `boot_id` (`engine/execution-admission.py:100` to `:104`); boot-id comparison for a dispatched step (`engine/issue-pipeline.sh:292`) |
| A3 | **Local files as the truth about a ticket** | `state/<n>.json` is the only record of attempts; `units.json` is the only record of a unit's stage; `ensure_clone` and `WT_ROOT` are the only copy of in-flight work |
| A4 | **One tick, one scheduler** | `engine/run-tick.sh` (one timer, local failure counter `tick-failure-count`); one `loop.sh` per checkout; `release_train` single instance |
| A5 | **Caps counted from local occupancy** | `MAX`, `IMPLEMENT_CAP` (`engine/mac-autopilot/scheduler.sh:93`, `:95`, `room_for` `:1721`), stage caps `TRIAGE_CAP`, `RELEASE_CAP`, `ADVISOR_CAP`, `RECUT_CAP` (`engine/issue-pipeline.sh:133` to `:151`), footprint mutex (`scheduler.sh:1386`, reads `units.json` only) |
| A6 | **Quota and cooldown are per host** | `start_cooldown` (`engine/mac-autopilot/scheduler.sh:592`), `provider_quota_*` (`engine/lib.sh:15762`), `codex_budget_reserve` (`:11477`) |
| A7 | **Alert and mail dedupe is per host** | `supervisor_inbox_append` (`engine/lib.sh:131`), `engine/notify.sh:1289` |
| A8 | **Observers read local state** | `engine/mac-autopilot/node_health.py:1412` (`release-train.json`), `gen_dashboard.py:1044`, `bell.sh:142`, `engine/supervise-pipeline.sh:564` (local timer state) |
| A9 | **Engine version is per host** | `run-tick.sh` fast-forwards its own checkout; `loop.sh` `sync_from_main` re-pins on a HEAD change. Two hosts can run different engine SHAs for several minutes. |
| A10 | **One GitHub identity and one REST budget** | `gh()` (`engine/lib.sh:3650`) is the single read path; `GH_TOKEN` comes from one env file |
| A11 | **Engine and target repository are the same checkout** | `ZF_REPO_DIR` defaults to the parent of `engine/` (`engine/lib.sh:314`); 73 lines in 28 files build paths as `<checkout>/engine/...`; `start.sh` pins `engine/` out of the target checkout. `docs/install.md` "Not generic yet", item 1. |

### 2.4 The two loops, phase by phase

The issue loop (`engine/run-tick.sh` then `engine/issue-pipeline.sh`, every 5 min) and the unit loop (`engine/mac-autopilot/loop.sh` then `scheduler.sh`, every 120 s plus a 30 s refill). The ruling covered the first; the second is what owns implement, review, merge and release on the origin deployment. Phases of `main()` in `scheduler.sh` (`:6764` onward) and what each needs:

| Phase | Mutates | Multi-host rule |
|---|---|---|
| `harvest_workers`, `precheck_harvest`, `self_check_harvest`, `stuck_worker_disposition` | local worker records, local kills | Host-local. Touches only this host's workers. |
| `recover_orphans`, `recover_orphan_landing` | requeues units whose worker died | Local for this host's dead workers; **cross-host recovery is claim takeover**, not this phase. |
| `reconcile_size_recuts`, `aged_pr_lifecycle`, `reconcile_orphan_prs` | issues, PRs | Ticket lease for each object mutated (`coord_with_ticket`). |
| `register_new_issues`, `register_new_prs`, `retire_landed_pr_units`, `release_dependency_blocks`, `supersede_resolved_main_red_units` | local ledger from GitHub reads | Host-local cache, no lease. Every host registers every unit; only the lease holder advances one. |
| `dispatch_pending`, `dispatch_supervisor_arbiters`, `dispatch_prompt_evals` | starts workers | **Claim before dispatch** (`dispatch_if_room`). Evals are a capability (`needs:eval`), not a lease. |
| `fast_land_lane` | pushes to main | `lane-land` |
| `ci_admission` | draft-to-ready flips, WIP slots | Per-unit ticket lease for the flip; the free-slot count already comes from GitHub (runner busy state), so no semaphore (4.8). |
| `run_merge_lane` | `gh pr merge`, post-merge verification, main-red units | `lane-merge`; main-red unit creation under `lane-main-red` |
| `run_release_train` | release batches, deploy | `lane-release` |
| `stage_slo_watch`, `flush_focus_alert`, `launch_views` | alerts, dashboard | Alerts take an event claim; views are per host and also render the remote status refs |

---

## 3. The design on one page

```
                         GitHub (the only shared substrate)
        ┌──────────────────────────────────────────────────────────────┐
        │ labels, comments, PRs, runs      = workflow state (unchanged) │
        │ refs/claims/<key>   one ref per ticket, unit, lane, event     │
        │ refs/status/<host>  one ref per host (caps, load, quota)      │
        │ refs/coord/control  drain list, primary host, min protocol    │
        └──────▲───────────────────────▲───────────────────────▲───────┘
   1 fetch/30 s│  1 push/60 s (renew   │ create / CAS          │
               │   + status, batched)  │ (acquire, intent)     │
        ┌──────┴───────┐        ┌──────┴───────┐        ┌──────┴───────┐
        │ host-a       │        │ host-b       │        │ host-c       │
        │ linux+systemd│        │ macOS+launchd│        │ WSL2         │
        │ issue loop   │        │ unit loop    │        │ both loops   │
        │ unit loop    │        │ renewd       │        │ renewd       │
        │ renewd       │        │ local state  │        │ local state  │
        │ local state  │        └──────────────┘        └──────────────┘
        └──────────────┘
```

Four layers, landed in this order:

- **Seam (S).** One config loader: engine directory versus target clone, per-host identity, coordination switch. Defaults reproduce today's derivations exactly.
- **Coordination (K, I).** `engine/coord/coord.sh`: claims as refs, leases by renewal, takeover by observation, effect intents inside the claim, lane leases, status refs. Integration is a handful of choke points. With `ZF_COORD=off` the functions are one-line stubs defined in `engine/config.sh`; `coord.sh` is not even sourced.
- **Placement (I5).** Hosts publish capabilities; each dispatcher filters candidates to what its own host can do and uses rendezvous hashing only to avoid a stampede. Correctness stays with the compare-and-swap.
- **Portability.** Specified in `docs/design/PORTABILITY.md`: packages and PATH shims only where a native tool is missing, a portable process runner, and three scheduler renderers. Distributed mode adds no platform code of its own (section 8.2).

What moves to GitHub and what does not:

| Moves to GitHub (recovery checkpoint) | Stays on the host |
|---|---|
| Ownership: who works on which ticket, unit or lane, lease and generation | pids, workers, worktrees, scratch, agent CLI sessions |
| Per-ticket recovery fields: attempts, advisor decisions, recut children, pending transitions, review and repair round counters, approved SHA, branch, footprint, blocked-on | `state/<n>.json` and `units.json` as working copies, ledgers, logs, metrics |
| Effect intents: pending and done external mutations by stable key | admission, CPU and memory sampling, breaker files, land-queue FIFO |
| Host status: capabilities, load, quota, quota cooldowns, heartbeat, engine SHA | read caches, dashboards, flock lock files |
| Release and main-red lane facts (`deploy-blocked`, recovery session) | `PAUSE`, `capacity.env`, credentials |

Records are readable by anyone who can read the target repository. They carry logical host ids chosen by the operator, never paths, hostnames, tokens or e-mail addresses.

---

## 4. The protocol

### 4.1 Identity and configuration

`engine/config.sh` (ticket S0) is the one place that resolves these. Every default reproduces today's derivation; nothing changes until a variable is set.

| Variable | Default | Meaning |
|---|---|---|
| `ZF_ENGINE_DIR` | directory of `lib.sh` | Where engine code lives (S1 makes the 73 `<checkout>/engine/...` paths use it) |
| `ZF_REPO_DIR` | parent of `ZF_ENGINE_DIR` (today's `engine/lib.sh:314`) | The target repository clone |
| `ZF_REPO` | origin remote of `ZF_REPO_DIR` (today's `engine/lib.sh:316`) | `owner/name` of the target |
| `ZF_HOST_ID` | `$AGENT_HOME/host-id`, else sanitized `hostname -s`, written once | Logical host name, `^[a-z0-9][a-z0-9-]{0,31}$`. It is the only machine name that appears in published records; set it explicitly if the real hostname should not be public. |
| `ZF_COORD` | `off` | `off` or `on`. This is the host's own switch. |
| `ZF_COORD_LEASE_S` / `_RENEW_S` / `_SELF_FENCE_S` | 900 / 60 / 600 | Lease, renewal period, self-fence deadline (4.5) |
| `ZF_COORD_DEAD_GRACE_S` | 300 | How long `renewd` waits after a run is gone before it releases the claim for other hosts (4.5) |
| `ZF_COORD_REFRESH_MIN_S` | 30 | Minimum age of the last fetch before a new one is made |
| `ZF_COORD_GIT_TIMEOUT_S` | 30 | Bound for every coordination git call |
| `ZF_COORD_CHECKPOINT_MAX` | 8192 | Bytes of checkpoint per claim |
| `ZF_COORD_BACKEND` | `git` | Optional backend (4.11) |

A **run id** (`r-<UTC compact>-<4 hex>`) is made per dispatch and travels to the child as `ZF_COORD_RUN` with `ZF_COORD_KEY`. Two machines cloned from one image would share `host-id`; each status record carries a random per-install `instance`, and `renewd` refuses to start when it sees its own host id with a different instance (the failure it stops: two hosts renewing each other's claims as if they were one).

### 4.2 Ref namespace

```
refs/claims/issue-7            ticket lease (issue loop and unit loop share it)
refs/claims/pr-31              unit lease for a PR-born unit
refs/claims/main-red-1a2b3c4d5 unit lease for a main-red unit
refs/claims/lane-merge         repository-wide lanes: lane-merge, lane-land,
refs/claims/lane-release       lane-release, lane-main-red
refs/claims/event-<kind>-<day> at-most-once events (alerts)
refs/claims/lock-<name>        short repository-wide mutex (issue creation per class)
refs/status/<host-id>          one per host, single writer
refs/coord/control             operator control record
```

The key of a ticket or unit claim is the unit id the scheduler already uses (`issue-<n>`, `pr-<n>`, `main-red-<sha9>`; `engine/mac-autopilot/scheduler.sh:6096`, `:6188`, `:6463`). Because these refs live in the **target** repository, running several target repositories needs no namespace change.

Custom ref namespaces are neither branches nor tags: branch protection and rulesets that target branches do not apply, they do not appear in the branch list, and push-triggered workflows start for branch and tag updates. Rollout step 0.5 (section 10) checks this once on the real repository with a probe ref, because a CI run per renewal would be a real failure.

### 4.3 The claim record

One JSON file `claim.json` in the root tree of a parentless commit. The ref points at that commit. A new record is a new commit, so every write has a fresh object id and a ref value never repeats (no ABA).

```json
{
  "proto": 1,
  "key": "issue-7",
  "kind": "ticket",
  "gen": 5,
  "seq": 212,
  "owner": {"host": "host-a", "run": "r-20261029T181200Z-7f3a", "engine": "a1b2c3d"},
  "stage": "implement",
  "lease_s": 900,
  "renewed_at": "2026-10-29T18:12:00Z",
  "taken_from": {"host": "host-b", "run": "r-20261029T165500Z-91c0", "gen": 4},
  "requires": {"os": ["linux"], "cli": ["codex"]},
  "checkpoint": {"state": {}, "unit": {}},
  "intents": {
    "merge:pr-31": {"kind": "merge", "class": "idempotent", "state": "pending", "gen": 5, "run": "r-20261029T181200Z-7f3a"}
  }
}
```

- `gen` increments when ownership changes (acquire from absent, from released, or by takeover). `seq` increments on every write.
- `owner: null` means released; the checkpoint and intents stay so a successor resumes from them.
- `renewed_at` is for people and dashboards. **No host ever decides expiry from it** (4.5).
- `kind` is `ticket`, `unit`, `lane` or `event`. A reader that sees `proto` greater than it supports treats the claim as unknown (4.5). Older records are readable by newer engines.
- Size cap 16 KiB, checkpoint 8 KiB. If a projection exceeds the cap the writer keeps the previous checkpoint and records `checkpoint_truncated` (a bounded history list is dropped first).

### 4.4 The coordination clone and reads

A bare repository per host, separate from the product checkout, so the self-updating checkout (`engine/run-tick.sh`) and its quarantine logic are never involved:

```
C="$AGENT_HOME/coord/repo.git"
git init --bare "$C"
git -C "$C" remote add origin "$(git -C "$ZF_REPO_DIR" remote get-url origin)"
git -C "$C" config fetch.prune true            # explicit refspecs still prune their destinations
git -C "$C" config gc.auto 256
git -C "$C" config user.name  zenoforge-coord
git -C "$C" config user.email zenoforge-coord@users.noreply.github.com
```

The clone inherits global git configuration and the process environment (proxy variables, `GH_TOKEN` through the credential helper). If the product clone carries repository-local credential settings, `coord_init` copies them with `git config --get-regexp '^(credential|http|url)\.'`.

**Snapshot read, at most once per refresh window** (`coord_refresh`, reuses `git_fetch_bounded`, `engine/lib.sh:3895`, so timeouts, proxy retries and transient classification stay in one place):

```
git_fetch_bounded "$C" \
  '+refs/claims/*:refs/seen/claims/*' \
  '+refs/status/*:refs/seen/status/*' \
  '+refs/coord/*:refs/seen/coord/*'
```

Exit 0 means the snapshot is complete; anything else means every read in this window is **unknown**. The issue loop and the unit loop on one host share the stamp `$AGENT_HOME/coord/refresh.stamp`, so two loops cost at most one fetch per 30 s.

```
git -C "$C" for-each-ref --format='%(refname:strip=3) %(objectname)' refs/seen/claims/
git -C "$C" cat-file blob refs/seen/claims/issue-7:claim.json      # then: jq -e '.proto and .key and .gen'
```

**Targeted confirm read**, used before a takeover, before a lane acquire that polls, and to resolve an ambiguous push:

```
git -C "$C" ls-remote origin refs/claims/issue-7
#  exit 0, one line   -> present, value = first field
#  exit 0, no output  -> confirmed absent
#  exit != 0          -> unknown
```

`coord_read <key>` returns **0 present** (record on stdout, object id on fd 3), **1 confirmed absent**, **3 unknown** with a reason on stderr (`fetch-failed`, `timeout`, `auth`, `malformed`, `proto-too-new`, `ambiguous-push`). Callers must treat 3 as neither "free" nor "held".

### 4.5 Operations

Build a record object locally (plumbing only, no working tree):

```
blob=$(printf '%s' "$json" | git -C "$C" hash-object -w --stdin)
tree=$(printf '100644 blob %s\tclaim.json\n' "$blob" | git -C "$C" mktree)
new=$(GIT_AUTHOR_NAME=zf GIT_AUTHOR_EMAIL=zf@localhost \
      GIT_COMMITTER_NAME=zf GIT_COMMITTER_EMAIL=zf@localhost \
      git -C "$C" commit-tree "$tree" -m "claim issue-7 gen 5 seq 212")
```

**Acquire, key absent (create-if-absent).** The empty expectation means "must not exist":

```
git -C "$C" push --porcelain --force-with-lease="refs/claims/issue-7:" origin "$new:refs/claims/issue-7"
```

**Acquire from a released record, takeover, renew, intent writes, release (compare-and-swap).** The expectation is the exact value this operation read; it is passed as an explicit object id, never taken from `refs/seen/*`, so a background fetch can never move it:

```
git -C "$C" push --porcelain --force-with-lease="refs/claims/issue-7:$old" origin "$new:refs/claims/issue-7"
```

**Renew, batched.** One push renews every claim this host holds and publishes its status ref (one writer, plain force):

```
git -C "$C" push --porcelain \
  --force-with-lease=refs/claims/issue-7:$old7 \
  --force-with-lease=refs/claims/issue-9:$old9 \
  origin "$new7:refs/claims/issue-7" "$new9:refs/claims/issue-9" "+$st:refs/status/host-a"
```

**Delete (retire).** A janitor in `renewd` deletes a released claim whose value it has observed unchanged for 7 days:

```
git -C "$C" push --porcelain --force-with-lease="refs/claims/issue-7:$cur" origin ":refs/claims/issue-7"
```

Verified against a local bare remote (git 2.47): create-if-absent succeeds once and fails the second time with `[rejected] (stale info)`; 20 concurrent compare-and-swap pushes with the same expectation produce exactly one winner (the old value is part of the push command, so the server enforces it, not only the client); a batch with one stale expectation applies the others and reports `!` for the stale one; `ls-remote` on an absent ref exits 0 with no output; an unreachable remote exits 128; `fetch.prune=true` removes a seen ref after a remote delete even with an explicit refspec.

**Reading the push result.** `--porcelain` prints one line per ref. A line starting with `*`, `+`, `=` or `-` is applied; `!` with `(stale info)` or `(already exists)` is a lost compare-and-swap (someone else wrote: not an error, the claim is held by another). Everything else, including a non-zero exit with no per-ref lines (timeout, reset, proxy abort), is **unknown**.

**Resolving unknown (lost acknowledgement).** The push may have been applied. Read back:

```
git -C "$C" ls-remote origin refs/claims/issue-7
#  value == $new   -> applied; we own it (persist $new as the held value)
#  value == $old   -> not applied; retry or give up
#  anything else   -> someone else wrote; lease lost
#  ls-remote itself fails -> still unknown: act as if the write may have happened
```

Because `$new` is a fresh commit nobody else can produce, equality proves the write was ours.

**Takeover.** A host takes a claim with `owner != null` only when all of these hold:

1. The claim's value has been seen unchanged in successful snapshot reads whose first and last observation are at least `lease_s` apart **on this host's clock**, and no gap between two consecutive successful reads exceeded `lease_s / 2`. A longer gap, a backward step of the clock, or any change of value resets the observation. Observation state is `$AGENT_HOME/coord/obs/<key>` holding `{value, first_seen, last_seen}`. Remote timestamps are never compared with local time, so clock skew between hosts does not matter, and a clock step on one host cannot manufacture an interval.
2. A targeted `ls-remote` immediately before the push still shows the observed value.
3. The claim's `requires` fit this host (4.9).

Then the compare-and-swap above, expectation = observed value, `gen + 1`, `taken_from` set. If the owner renewed in the meantime, the swap loses; nothing else is needed. After a win: restore the checkpoint (4.6), reconcile intents (4.7), re-read labels and PR state from GitHub, then dispatch. A takeover is not charged to the ticket as an attempt, the same way `record_env_fault` refunds a dispatch that never ran.

**Same-host recovery is immediate.** If `owner.host` is this host and the local runner shows the run is not alive (unit inactive, or worker pid gone), the host re-acquires its own claim at once by compare-and-swap from the value it holds. This is a local fact about a local worker; it does not need the lease to expire. To free the claim for *other* hosts, `renewd` releases a claim whose run it has seen gone for `ZF_COORD_DEAD_GRACE_S` (default 300 s), the grace being there so the loop that owns the run harvests its result first. A reboot is the same case (`renewd` runs at boot; every held claim whose run is gone is released after the grace).

**Self-fence.** If `renewd` has not had a successful renewal for a claim for `ZF_COORD_SELF_FENCE_S` (600 s), it stops the local run (`systemctl --user stop zf-<stage>-<n>`, which the portable runner shim answers on hosts without systemd, or a process-group TERM then KILL for unit-loop workers) and marks the held entry `lost`. The deadline is shorter than the lease (900 s), and an observer needs at least one lease of unchanged reads, so the old worker is already stopped when anyone can take over. Residual overlap is only a process that was frozen (suspended VM) and wakes up later: it cannot renew (its swap loses), and for external effects section 4.7 applies. Wasted tokens are accepted.

**Unknown handling, summarized.**

| Operation | Read result 3 (unknown) |
|---|---|
| Dispatch a stage | Do not dispatch. No attempt is charged. Retry next tick. |
| Takeover | Never. A failed read neither advances nor resets the observation; if failures last longer than half a lease, the next successful read starts a new observation (the gap rule). |
| Renew | Keep trying each minute; after the self-fence deadline stop the local run. |
| Write to GitHub (label, PR, comment) | `coord_assert_owned` is a local check that the last successful renewal is younger than the self-fence deadline; if not, refuse. |
| Effect intent | The intent write is a compare-and-swap; unknown means the effect is not performed. |
| Release | Queued; renewal keeps retrying; the lease simply expires if the host dies. |
| Lane acquire | Wait with backoff (5 s doubling to 60 s), bounded like today's `MERGE_LOCK_WAIT_SECONDS`. |

### 4.6 Checkpoint: what moves remote and how

The claim's `checkpoint` object holds only what a successor cannot rebuild from GitHub and needs in order to resume without repeating a charged attempt or re-deciding a ruling. The field list is a versioned file, `engine/coord/checkpoint.json`:

```json
{
  "version": 1,
  "state": ["attempts", "attempts_reset", "advisor_decision", "advisor_episode_seq", "recut_children",
            "model_policy", "same_failure_streak", "last_failure_reason", "hold", "delivery_state",
            "deploy_state", "pr_number", "implement_started_sha", "escalated_head_sha", "conclusion"],
  "unit":  ["stage", "pr", "branch", "lane", "footprint", "approved_sha", "review_sha",
            "blocked_on", "blocked_resume_stage", "repair_hint", "loop_total_allowed"]
}
```

Excluded on purpose: pids, workdir, `session_id`, `self_check_pid`, `precheck_pid`, token usage (host-local), and everything under `ci_*` (rebuilt from GitHub runs). The first list follows the ruling (attempts, advisor decisions, recut children, pending transitions, operation records); the field names come from what `state_merge` callers and `set_unit` actually write.

- **Hold:** the claim holder is the sole writer. `renewd` projects `state/<n>.json` and the unit's row with `jq` and, if the projection changed since the last push, includes it in the next renewal (so the remote checkpoint is at most one renewal period old).
- **Acquire or takeover:** remote wins. The checkpoint is merged into the local files through the existing writers (`state_merge`, `units_update`, so every validation in `write_state` at `engine/mac-autopilot/scheduler.sh:142` still applies).
- **First acquire (absent):** local initializes remote.
- `state_read` and `state_merge` themselves do not change. That is what keeps this behavior-neutral and cheap.

### 4.7 Effect intents

A lease does not fence an external system: a worker can pause after checking its lease, lose it, then complete a request it already issued. So every external mutation that is not safe to repeat first writes a `pending` intent into the claim by compare-and-swap. That one write both checks ownership (a lost lease fails the swap) and reserves the operation under a stable key.

```
effect_begin    <claim> <effect-key> <kind> [--class idempotent|once]   # swap in {state: pending}; fail => do not perform
   ... perform the external mutation ...
effect_complete <claim> <effect-key> <result-json>                       # swap {state: done, result}
effect_reconcile <claim>                                                 # successor, after takeover
effect_run      <claim> <effect-key> <kind> -- <command...>              # begin, run the command, complete (pending if the command's outcome is unknown)
```

Keys are logical and reused by retries; host and run ids never take part in deduplication.

| Effect | Call site | Class | Key | Authoritative read for reconcile | Blocks |
|---|---|---|---|---|---|
| Merge a PR | `guarded_pr_merge` (`engine/lib.sh:4441`, merge at `:4548`); `engine/mac-autopilot/scheduler.sh:5392`; `engine/hotfix/hf-merge.sh:39` | idempotent (head-pinned, the server refuses a repeat) | `merge:pr-<N>` | `gh pr view --json state,mergeCommit` (`guarded_pr_merge` already does this at `:4454` and again after the merge at `:4559`) | the ticket |
| Push branch, open PR | worker publication; `engine/land-direct-main.sh:1398` | idempotent (compare-and-swap push; PR looked up by head branch) | `push:<branch>`, `pr-open:<branch>` | `git ls-remote`, `gh pr list --head` | the ticket |
| Revert PR | main-red step; `engine/sweep-merges.sh:49` | idempotent (branch name `agent/revert-main-<issue>-<sha12>` is the key) | `revert:<sha12>` | branch exists | `lane-main-red` |
| Deploy | `run-release.sh` (not in the public tree; the dispatcher gates it, `engine/issue-pipeline.sh:478`) | once | `deploy:<release-seq>` | `engine/production-deployment-read.sh` | `lane-release`, for every ticket |
| E-mail | `send_email_strict` (`engine/notify.sh:631`) | once | `mail:<ticket>:<event-no>` | none exists, so an ambiguous send stays `unknown` | nothing; never resent |
| Issue or PR comment | many | once, made idempotent with a body marker `<!-- zf-intent:KEY -->` | `comment:<issue>:<marker>` | list comments, search the marker | nothing |
| Label transition, issue close | `issue_transition` (`engine/lib.sh:1879`) | idempotent set-based writes | no intent; ownership assertion only | labels | - |
| Create a GitHub issue | `pipeline-issue-upsert.sh`, `roadmap-issue-create.sh` | once (class marker in the body) | short lease `lock-issue-create-<class>` | marker search (the script already does it) | - |

Rules:

- **Reconcile, never replay by default.** A successor looks at every intent still `pending`. Authoritative read says done: mark done. Idempotent class and not done: it may retry under the same key. Class `once` and not provably done: the intent becomes `unknown` and is never retried automatically; an inbox alert is raised through an event claim, and `coord.sh effect clear <claim> <key>` is the operator override. Absence of a visible result does not prove an old request cannot still complete.
- A pending or unknown deploy intent lives in the `lane-release` record, so it blocks the whole release lane, for every ticket, until reconciled or cleared. Merge, mail and comment intents live in the ticket claim.
- Completed intents are pruned to the last 20.
- E-mail with an ambiguous outcome is not resent. That is at-most-once submission and accepts a possibly omitted message. Guaranteed delivery plus no duplicates needs receiver-side idempotency or a cross-system transaction, which none of these primitives provides.
- Idempotent writes with no external memory (labels, close) take the cheap path: `coord_assert_owned` only, no network.

### 4.8 Lanes, events and caps

A **lane** is a claim with `kind: lane` held for the duration of a critical section. Acquire is create-if-absent or compare-and-swap from a released record; waiting is a bounded backoff poll of one targeted `ls-remote` (no fetch storm: waiters are rare and slow).

| Lane | Held around | Replaces | Notes |
|---|---|---|---|
| `lane-merge` | the final gate read plus `gh pr merge` in `guarded_pr_merge`, and `run_merge_lane`'s merge loop | `acquire_merge_lock` (`engine/lib.sh:14769`), and the implicit "only one scheduler" assumption of the unit loop | Short hold. A host that dies inside it blocks merging for one lease (15 min) plus observation. |
| `lane-land` | the lander from preflight to the push of `HEAD:main` | the cross-host part of the land queue | The push is already an optimistic swap; the lane keeps post-land attribution single-flight. |
| `lane-release` | deployment selection through completion; released during ordinary CI waiting | `zf-release-train` is-active check and the delegate lock | Its checkpoint carries `deploy_blocked_sha` and the last completed release. |
| `lane-main-red` | one step of red-main recovery: rerun, attribute, revert PR, reopen | per-host `main-red/` session ownership | Prevents two revert PRs. |

**Events.** `refs/claims/event-<kind>-<day>` is created if absent and never renewed or released. The creator sends the alert; everyone else skips. Unknown means skip (alerts are best effort). The janitor deletes events after 7 days. Applies to repository-wide kinds in `supervisor_inbox_append`. Issue upserts are different: the same class can legitimately need a new issue a day later, so they take a short lease `refs/claims/lock-issue-create-<class>` (a `lane` claim) around the read-then-create, which is exactly the race `pipeline-issue-upsert.sh:52` describes.

**Caps.** Caps that guard a host's own resources (execution admission, `MAX`, `IMPLEMENT_CAP`, `TRIAGE_CAP`) stay per host, so adding a host adds capacity, which is the point. Caps that guard a shared downstream resource are already global: `ci_pr_free_slots` is computed from the runner state GitHub reports, so `ci_wip` needs no semaphore; two hosts may admit one PR too many in the same tick, which costs one extra queued CI job, so no slot claims are built. An optional soft global cap per stage (`ZF_COORD_GLOBAL_CAPS=triage:6,advisor:2`) counts live claims with that stage from the snapshot and is off by default.

The unit loop's **footprint mutex** (`engine/mac-autopilot/scheduler.sh:1386`) reads only the local `units.json`. With coordination on it also reads the `footprint` of live claims from the snapshot, so two hosts do not implement overlapping files.

### 4.9 Status, capabilities and placement

Each host publishes `refs/status/<host-id>` (the blob `worker.json`, schema below) in the renewal push. Writer: the host itself, plain force. Nothing about ownership is read from it.

```json
{
  "proto": 1, "host": "host-a", "instance": "9f2c1e", "engine": "a1b2c3d", "heartbeat_at": "2026-10-29T18:12:00Z",
  "draining": false,
  "caps": {"os": "linux", "arch": "x86_64", "wsl": true, "cpus": 12, "mem_mb": 32768,
           "cli": {"codex": "ok", "claude": "ok", "zcode": "missing", "gh": "ok", "node": "22", "docker": "ok"}},
  "load": {"mem_avail_mb": 11800, "cpu_busy_pct": 41, "running": 4, "cap": 8},
  "quota": {"providers": {"codex": {"state": "ok"}, "claude": {"state": "cooling", "until": "2026-10-29T18:40:00Z"}},
            "gh": {"remaining": 3120, "reset_at": "2026-10-29T19:00:00Z"}},
  "policy": "a41c9e",
  "claims": [{"key": "issue-7", "stage": "implement", "gen": 5, "since": "2026-10-29T17:58:00Z"}],
  "tokens": {"day_used": 1840000}
}
```

Capabilities are detected by `engine/coord/caps.sh` at start and every 10 minutes (`command -v` plus a version probe; the OS facts are `ZF_OS` and its siblings from the portability layer, section 8). Providers share quota by an operator-declared account tag (`ZF_PROVIDER_ACCOUNT_codex=acct-a`); a peer's `cooling` for the same tag makes `cooling()` (`engine/mac-autopilot/scheduler.sh:588`) true locally, so one host's 429 stops every host from retrying the same account.

**Control record.** `refs/coord/control` is one operator-written JSON object, changed only by `ctl.sh control set` with a compare-and-swap:

```json
{"proto": 1, "primary": null, "drain": [], "min_proto": 1}
```

Every host reads it from the snapshot. If `primary` is set and is not this host, the host acquires nothing new. If this host is in `drain`, it acquires nothing new and releases at stage end. If `min_proto` is above the host's own protocol, it acquires nothing and alerts that an upgrade is needed. An absent or unreadable record means "no restrictions" only when the read was a confirmed absence; unknown blocks acquires like any other unknown.

**Liveness of a peer** is observed, not trusted: a host is live if its status value changed within three renewal periods of local observation and it is not draining.

**Placement.** There is no central scheduler. Each dispatcher keeps its existing candidate selection and adds three steps, all local:

1. **Admit, then filter by capability.** A host first checks its own capacity (memory floor, load, run count; section 8.2, item 5) and stops here if it cannot start the stage. A candidate carries `requires` (labels `needs:os=darwin`, `needs:cli=claude`, `needs:mem>=16g`, plus per-stage defaults in config, for instance the review stage requires the CLI of the configured reviewer model). A host drops candidates its own `caps` do not satisfy, and candidates whose model provider is cooling (own or same-account peer).
2. **Stagger by rendezvous hashing.** Among live, non-draining, eligible hosts with a free slot, rank hosts by `cksum(host-id + key)`. Rank 0 may claim immediately; rank r may claim only after the candidate has been visible and unclaimed for `r` ticks. This only reduces wasted compare-and-swap attempts; correctness is the swap.
3. **Affinity for resumable stages.** Repair and rereview prefer the host named in `checkpoint.last_host` (its agent CLI session can be resumed) for one tick, then anyone may take them with a fresh session.

A candidate no live host can satisfy raises one event-claimed alert ("unplaceable") instead of waiting silently.

### 4.10 Rate-limit budget and polling

Claims, status and control are git transport. Git over HTTPS is not part of the REST primary rate limit, so coordination adds **zero** REST calls. The only API call it adds is `gh api rate_limit` (free), once per loop tick, to fill the `gh.remaining` field.

| Operation | Transport | REST calls | Frequency per host |
|---|---|---|---|
| Snapshot fetch of claims, status, control | git | 0 | at most 1 per 30 s, shared by both loops (so at most 1 per tick) |
| Renewal and status publish, batched | git | 0 | 1 per 60 s, whatever the number of claims |
| Acquire (create or swap) | git | 0 | 1 per dispatch |
| Effect intent | git | 0 | 2 per non-idempotent external effect |
| Targeted `ls-remote` | git | 0 | takeover, lane polls, ambiguity only |
| Rate-limit probe | REST, not counted | 0 counted | 1 per tick |

So the coordination layer costs about 60 renewal pushes, up to 120 fetches and a few dozen acquires per hour per host (*design target*), and the claims keep renewing even when the REST quota is exhausted, because REST exhaustion does not touch git transport.

The real REST pressure is the engine's own reads, which every host repeats. On the origin deployment one host measured about 2,300 `gh` calls per hour (both loops, after one defective call site was fixed), about 55 per tick on average. The rules for N hosts:

1. The budget belongs to an identity. Hosts that share one `GH_TOKEN` share 5,000 per hour. From two hosts on, give each host its own identity (machine account or app installation; `GH_TOKEN` is already per host in `$AGENT_HOME/env`). This is an operator decision (section 11).
2. Every host reads `gh.remaining` each tick. Below 25 % it sheds optional reads in this order: dashboards and health issue filing, `aged_pr_lifecycle`, CI spend sampling, SLO watch. It never sheds claim traffic, merge-lane reads or release reads.
3. Only if shedding is observed in the status refs: one host holding a short lease `lock-census` publishes the PR and run census as `refs/status/census`, and the others read it from the fetch they already make. It has no ticket until shedding is measured; it is not built now.

### 4.11 Optional backend behind the same interface

`ZF_COORD_BACKEND=git` is the default and the only one built. The interface is six verbs, `read`, `list`, `create`, `cas`, `delete` and `status_put`, plus an optional server clock. A mature external store can implement them for large fleets:

- **etcd**: leases give server-side expiry (sub-minute takeover), a transaction gives compare-and-swap, a watch replaces the fetch.
- **PostgreSQL**: one table `claims(key primary key, gen, doc jsonb)`, `UPDATE ... WHERE gen = $old` as the swap; sensible when the operator already runs one.

Switch only when the git backend's limits bite: *design target* of roughly ten hosts and a hundred live claims (each snapshot fetch is bounded by the number of changed claim refs), or a need for takeover faster than a lease. Nothing else in this design depends on the choice.

---

## 5. Where each existing mechanism changes

All changes are guarded by the effective switch. With `ZF_COORD` unset, the functions named in the third column are stubs defined in `engine/config.sh` that return success immediately; no clone is created, no process is started, no network call is made.

| Existing mechanism | Anchor | Change when on |
|---|---|---|
| "Is `zf-<stage>-<n>` running" | `stage_unit_active` `engine/lib.sh:13280` | `local-active OR coord_remote_active <stage> <n>`: a claim exists, owner is another host, not expired by observation. Unknown counts as active (fail-closed, the direction the function already takes for a failed query). |
| Stage occupancy for caps | `stage_unit_count` `engine/lib.sh:13381` | Unchanged for per-host caps; optionally adds remote count for global caps. |
| Issue-loop dispatch | `dispatch` `engine/issue-pipeline.sh:390` | admission check (own capacity), then `coord_acquire issue-<n> <stage>` before `systemd-run`; pass `-E ZF_COORD_RUN -E ZF_COORD_KEY`; on held or unknown skip without charging an attempt. |
| Batch dispatch | `dispatch_triage_batch` `:556`, `dispatch_advisor_batch` `:509` | Acquire per issue; the batch runs with the subset won. |
| Release dispatch | `dispatch_release_batch` `:478` | `coord_lane_acquire release`. |
| Stage wrappers | `engine/run-triage.sh`, `run-recut.sh`, `run-advisor.sh` (and `run-release.sh`, `run-implement.sh` upstream) | First line after sourcing `lib.sh`: `coord_enter <key> <stage>`; dispatched runs validate `ZF_COORD_RUN`, direct manual runs acquire. Exit trap calls `coord_release`. |
| Every mutating call | `guarded_write` `engine/lib.sh:4017` | `coord_assert_owned "$ZF_COORD_SCOPE"` where scope is `ticket:<key>` or `lane:<name>`. An unscoped write is refused when on (the failure it stops: a manual or sweeper write racing the owner). Sweepers use `coord_with_ticket issue-N -- <write>`. |
| Label transitions | `issue_transition` `engine/lib.sh:1879` | Assertion before the write; `coord_checkpoint_set` after the local commit. |
| Merge | `acquire_merge_lock` `engine/lib.sh:14769` | `coord_lane_acquire merge` plus `effect_begin merge:pr-<N>`; the same for `scheduler.sh:5392`, `hotfix/hf-merge.sh:39`. |
| Unit-loop dispatch | `room_for` / `dispatch_if_room` `engine/mac-autopilot/scheduler.sh:1721`; 7 callers, one choke | `coord_acquire <unit-id>`; footprint check also reads remote claims. |
| Unit-loop harvest | `harvest_workers` `:2960` | `coord_release` after the stage advanced and any GitHub effect completed. |
| Orphan recovery | `recover_orphans` `:3233` | Local dead workers recover as today; remote ones recover through takeover and `coord_unit_restore`. |
| Land | `engine/land-queue.sh`, `land-direct-main.sh` | `coord_lane_acquire land` around the lander. |
| Release train | `run_release_train` `scheduler.sh:6408` (in the public tree the train is the hook script named by `ZF_RELEASE_TRAIN_SCRIPT`) | `coord_lane_acquire release` before the hook starts; the local stamp and `is-active` check stay as the host-local fast path. |
| Main-red | `open_main_red_unit` `scheduler.sh:6444`, main-red step in `issue-pipeline.sh` | `coord_lane_acquire main-red`. |
| Alerts | `supervisor_inbox_append` `engine/lib.sh:131` | Repo-wide kinds call `coord_event_once` first. |
| Issue upsert | `engine/pipeline-issue-upsert.sh:53` | `coord_lane_acquire lock-issue-create-<class>` around the read-then-create; the local flock stays as the same-host guard. |
| Mail | `send_email_strict` `engine/notify.sh:631` | `effect_begin mail:...`; outcome recorded as done, or unknown. |
| Cooldown, quota | `start_cooldown` `scheduler.sh:592`, `provider_quota_*` `engine/lib.sh:15762` | Written locally as today and published in status; `cooling()` consults same-account peers. |
| Observers | `supervise-pipeline.sh:140` (`issue_has_live_unit`), `node_health.py:1412`, `gen_dashboard.py:1044`, `bell.sh:142` | Read claims and `refs/seen/status/*` in addition to local state; show peers as stale or unreadable explicitly. |
| Unit ledger and `units.json` | `write_state` `scheduler.sh:142` | Unchanged. Remote data enters only through `units_update`, so the schema guard (no unit may be deleted, ids unique) still runs. |

---

## 6. Failure modes

Recovery bound for a dead host: the lease (900 s) of unchanged reads on the observer, plus at most one gap (450 s) in the observation, plus one tick. Typical case about 16 to 17 minutes; worst case about 22. These are *design targets* from the ruling's parameters.

| # | Failure | What detects it | Resulting behavior | Bound or cost |
|---|---|---|---|---|
| 1 | Host dies mid-stage (power, `kill -9`) | Observers see an unchanged claim for a full lease | Takeover by compare-and-swap, checkpoint restored, intents reconciled, GitHub re-read, stage re-dispatched. Unpublished local work (worktree, agent session) is lost. | about 16 to 22 min; wasted tokens |
| 2 | Worker dies, host alive | The local runner shows the run gone | The owning host re-acquires at once (its own loop recovers the stage). If nothing harvests it, `renewd` releases the claim after the 300 s grace (swap to `owner: null`, checkpoint kept) and any eligible host acquires on its next tick. | at most 300 s plus 60 s plus one tick |
| 3 | `renewd` stops, workers keep running | Held entry stops advancing; `coord_assert_owned` refuses once the last renewal is older than the self-fence deadline | Publications are refused; model runs end at their own `RuntimeMaxSec`. The timer is listed in `$AGENT_HOME/timers.local.list` (K2), which `run-tick.sh` reads together with the shipped list, so the existing repair path re-enables it and alerts. | tokens only |
| 4 | Host partitioned from GitHub entirely | Fetch and push fail: reads unknown | No dispatch, no takeover on that host. Self-fence at 600 s stops its runs. Others take over after the lease. On healing, its swaps lose; it discards local work. | as row 1 |
| 5 | Git transport works, REST does not (or REST quota exhausted) | `gh` calls fail, existing fail-closed paths | Claims keep renewing and no lease is lost. Engine reads fail-closed exactly as today; optional reads are shed (4.10). | none for coordination |
| 6 | REST works, git transport fails (proxy blocks smart HTTP) | Coordination reads unknown; `renewd` logs and, after 3 failures, raises a local inbox event | No new dispatch; running work self-fences at 600 s. The probe in rollout step 0.5 catches this before enabling. | operator action |
| 7 | Clock skew between hosts, any size | Not needed | None. Expiry uses only the observer's own elapsed time between two successful reads of the same value. `renewed_at` is never compared. | none |
| 8 | Clock step or suspend on an observer | Gap rule (> lease/2) or backward step | Observation resets; takeover is delayed, never early. | extra delay |
| 9 | Clock step or suspend on the owner | Owner's elapsed time since last renewal jumps | Self-fence triggers early (conservative). Its claim may be taken; its swaps then lose. | extra recovery |
| 10 | Push acknowledgement lost on acquire or takeover | Non-zero exit with no per-ref line | Readback with `ls-remote`: equals the new value, then owned; equals the old value, not applied; anything else, lost. If readback also fails the host stays in "maybe owner": it does not dispatch, and the next `renewd` pass resolves it. | one renewal period |
| 11 | Acknowledgement lost on renewal | Same | Held entry keeps `old` and `pending`; next pass reads back first. | none |
| 12 | Acknowledgement lost on an intent write | Same | `effect_begin` returns unknown, the effect is not performed. A pending intent may exist; the successor reconciles it (4.7). | none |
| 13 | Renewal races takeover | One swap loses | If the takeover wins, the old owner finds out on its next renewal (at most 60 s) and stops its run. | none |
| 14 | Two hosts acquire the same key | Server-side compare-and-swap | Exactly one wins; the loser reads `held`. Verified locally with 20 concurrent pushes. | none |
| 15 | GitHub outage | All reads unknown | Pipeline halts, as it does today. Self-fence stops runs at 600 s. After recovery, expired claims are re-acquired; checkpoints keep attempts and rulings. | outage length |
| 16 | Frozen process wakes after takeover (the "zombie") | Its swap or its intent write loses | Lease-checked writes fail. For a non-idempotent effect already issued before the freeze, the intent was written first, so the successor reconciles instead of replaying. | possible omission, never a duplicate (4.7) |
| 17 | Merge-lane holder dies inside the lane | Lane claim stops renewing | Merge is blocked for one lease plus observation; then takeover and the `merge:` intent is reconciled from the PR state. | about 16 to 22 min of merge delay |
| 18 | Deploy in flight when the host dies | `deploy:<seq>` is `pending` in `lane-release` | The release lane stays blocked for every ticket until `production-deployment-read.sh` proves the result, or an operator runs `coord.sh effect clear`. | accepted; blocked, never repeated |
| 19 | Malformed, oversize or too-new claim | JSON/size/`proto` validation | Treated as unknown for that key: nothing is dispatched on it, nothing deletes it. One event-claimed alert; `coord.sh claim clear` is the operator action. | one key stalled |
| 20 | Rolling upgrade: hosts on different engine SHAs | `proto` and `engine` in records | Older records stay readable; a record with a newer `proto` is unknown. `refs/coord/control` can set `min_proto` to force upgrades. | none |
| 21 | Two machines share one `host-id` | `instance` differs in the status ref | `renewd` refuses to start and raises an alert. | operator action |
| 22 | Token cannot push custom refs | `remote rejected` on the probe | Coordination cannot be enabled. Found at rollout step 0, before any claim exists. | none |
| 23 | Checkpoint restore fails on takeover | Non-zero from `state_merge` or `units_update` | The host releases the claim again (so a host with intact local state may take it) and raises an alert. No silent loss. | one extra lease |
| 24 | Coordination clone or held directory lost | `coord_init` finds no clone | The clone is a cache and is rebuilt. If held entries are gone, renewals stop and the claims expire; recovery as row 1. | as row 1 |
| 25 | Two timers start the same loop on one host | Local flocks | As today (L1, L9). | none |

Failures the ruling accepted and this design keeps: delayed failover, stale status, wasted tokens during cancellation, lost unpublished work, ordinary code conflicts between different tickets, GitHub outage halting progress, unresolved external effects staying blocked (including a possibly omitted e-mail). Local spend is accounting, not a global budget. Malicious workers and manual bypasses are not covered.

---

## 7. The fault-injection harness

### 7.1 Acceptance

The ruling's single measurement, kept as is: **100 of 100 two-host trials pass.** Each trial races two hosts on one ticket, verifies both appear in status, injects a claim-read failure and a worker death, then resumes the dead worker after takeover. A trial passes only if:

1. the initial stage is dispatched exactly once;
2. recoverable work completes within two lease intervals plus one tick after connectivity returns;
3. no external effect is duplicated (recorded sinks for merge, deployment and mail);
4. every ambiguous effect ends explicitly `unknown` or blocked, and is never replayed;
5. "zero duplicates but no recovery" fails.

It runs in CI on every pull request as an ordinary suite. Merge of I4, the last ticket that changes who may dispatch, merge or release, is gated on it; I5 and I6 keep it green.

### 7.2 What is simulated, what is real

Two hosts are two directories on one machine, each with its own `HOME`, `AGENT_HOME`, `ZF_HOST_ID`, PATH shims and coordination clone. They share one **bare git repository** (the "GitHub" for refs) and one **fake `gh`** (the "GitHub" for API state). The code under test is the real `engine/coord/coord.sh`, `renewd.sh --once`, the effect helpers (`effect_run` around the sink commands and the fake `gh pr merge`), checkpoint projection and restore against the real `state_merge`, and the real lane functions. The wiring of `guarded_pr_merge` itself is covered by the K6 and I4 suites. A bare repository enforces the same server-side old-value check as GitHub (shown in 4.5), so the compare-and-swap semantics are the real ones.

Not simulated and covered elsewhere: GitHub itself (one probe on the real repository at rollout step 0), real clock drift (the virtual clock covers any skew), and the 6.8k-line scheduler (its wiring is covered by per-ticket suites I1 to I4 using the existing stub style: 67 suites already fake `gh`, 20 already build bare remotes).

### 7.3 Layout

```
engine/coord/coordination.test.sh      the suite; found by tools/run-engine-tests.sh (any *.test.sh)
engine/coord/sim/lib.sh                world and host helpers: sim_world_new, sim_host_new <id> [skew], sim_as <id> -- cmd
engine/coord/sim/bin/git               fault shim: wraps real git, applies rules from $SIM_FAULTS
engine/coord/sim/bin/gh                fake GitHub API (state in $SIM_WORLD/gh.json under the harness's own flock)
engine/coord/sim/worker.sh             simulated stage worker with pause points
engine/coord/sim/pre-receive           installed in the bare remote: logs every ref update to refs.log
```

- **Git fault shim.** Active only for calls whose `-C` ends in `/coord/repo.git`. Rules `{host, subcommand, nth, mode}`: `fail` (exit 128, nothing applied), `lost-ack` (run the real git, then exit 128 with "the remote end hung up unexpectedly", so the push was applied but the caller cannot tell), `partition` (fail every call from a host for a window).
- **Fake `gh`.** `pr view` with the JSON fields `guarded_pr_merge` reads, `pr merge` (honors `--match-head-commit`, rejects a second merge of the same PR), `issue view|edit|comment`, `variable get`, `api rate_limit`, `run list`, `pr list`. Merge requests are logged with an `effective` flag.
- **Sinks.** `$SIM_WORLD/sinks/merge.log`, `deploy.log`, `mail.log`, append-only, one line per **request issued**. Merge has server-side deduplication, so only the effective merge counts; deploy and mail have none, so every request counts.
- **Virtual clock.** One function, `coord_now_s`, reads `$ZF_COORD_CLOCK_FILE` when set and `date +%s` otherwise. Each simulated host has its own clock file (world time plus that host's skew). The driver advances world time; nothing sleeps. This is the only test seam in `coord.sh`; it exists because a 15-minute lease cannot be waited out 100 times.
- **Server-side log.** `pre-receive` appends `refname old new` for every update, so the suite can assert that each claim ref has a linear history (each update's old value equals the previous new value) and that `gen` never decreases.
- **Worker.** Steps: `start`, `intent-merge`, `merge-request`, `complete-merge`, `intent-deploy`, `deploy-request`, `complete-deploy`, `intent-mail`, `mail-request`, `complete-mail`, `release`. `SIM_PAUSE_AT=<step>` stops it there (blocking on a fifo) so the driver can kill it (death) or let it continue later (resurrection).

### 7.4 One trial

Virtual constants: lease 900, renewal 60, tick 120. World at t=0: ticket `issue-7` labeled for implement; PR 31 approved at head `H`; release `r1` pending; hosts A and B both `ZF_COORD=on`.

1. **Race.** A and B run one decision tick concurrently (`sim_tick`: refresh, filter by capability, acquire, start the worker). Assert: exactly one acquire won, `dispatch.log` has one line for `(issue-7, implement)`.
2. **Status.** Both run `renewd --once`. Assert `refs/status/A` and `refs/status/B` parse and have different `instance`.
3. **Run.** The winner W executes the worker; the driver advances time 30 s per step and runs `renewd --once` every 60 s.
4. **Faults**, chosen by the trial parameters:
   - `death_point` in {before-claim, claimed-before-dispatch, mid-stage, between-intent-and-request, between-request-and-complete, complete-before-release}: W's worker and `renewd` are killed (or paused, for resurrection);
   - `read_fault` in {none, loser's fetch fails for three refreshes inside the expiry window, loser's `ls-remote` fails at the takeover step};
   - `ack_fault` in {none, lost-ack on one of W's renewals, lost-ack on W's intent write, lost-ack on the loser's takeover swap};
   - `skew` in {0, +300 s, -300 s} on the loser's clock;
   - for the two `once`-class effects, a coin (seeded) decides whether the request had been issued when W died.
5. **Wait.** The loser L runs `sim_tick` every 120 s of virtual time. Assert `dispatch.log` stays at one line until L's takeover. Time advances at most `2*900 + 120`.
6. **Takeover.** L takes over, restores the checkpoint, reconciles intents, and finishes the ticket.
7. **Resurrection.** W's frozen worker resumes (parameter `resurrect` in {immediately after takeover, one tick later, after completion}). Its next `effect_begin` must fail; its `renewd --once` must find the claim lost and stop the run.
8. **Assertions** (all must hold): the five pass conditions of 7.1; no malformed ref; exactly one owner per claim at every logged update; sink lines per logical key at most 1 (effective merge, deploy requests, mail requests); for a `once` effect left in doubt, the claim holds `unknown`, the sink has no second request, and for deploy `lane-release` is blocked; for recoverable trials the ticket reached its terminal labels and the PR is merged once.

### 7.5 The 100 trials

- Trials 1 to 36: the full cross of the six `death_point` values with six variants {no extra fault, read fault, lost ack on W, lost ack on takeover, skew +300, skew -300}.
- Trials 37 to 90: seeded random combinations of every parameter (seed = trial number).
- Trials 91 to 100: placement. Ticket carries `requires: cli=claude`; only B advertises it. A must never claim it; when B dies and no live host qualifies, A raises exactly one "unplaceable" event claim and still does not dispatch.

`ZF_COORD_TRIALS` (default 100) sets the count; `ZF_COORD_TRIAL=<n>` reruns one trial with its seed printed; `ZF_COORD_JOBS` (default 4) runs trials in parallel, each in its own world directory. *Design target:* about 1.5 s per trial, so the suite stays well inside `SUITE_TIMEOUT` (600 s) in `tools/run-engine-tests.sh`. The ordinary unit tests for `coord.sh` (20-way race, partial batch, readback after lost ack, observation reset on a clock step) live in `engine/coord/coord.test.sh` and run first.

### 7.6 Off-mode proof

A separate suite runs the existing dispatch fixtures with `ZF_COORD` unset behind a PATH `git` and `gh` that fail the test on any call whose `-C` argument ends in `/coord/repo.git` or that is `gh api rate_limit`, and asserts that `$AGENT_HOME/coord` does not exist afterwards and that the fake remote has no `refs/claims`. This is the "coordination off means no extra network calls" check, and it protects every later ticket.

---

## 8. Portability and the fleet

A distributed pipeline is only useful if the hosts can be the machines people have. Today `docs/install.md` requires "Linux with a systemd user manager", and CI only runs on `ubuntu-latest`, which is how the unit loop (born portable: its directory is still `mac-autopilot`, and `runtime-env.sh` has helpers that avoid BSD and GNU `date` differences) became Linux-only without anyone noticing when `pid_running` started reading `/proc` (`engine/mac-autopilot/loop.sh:62`).

`docs/design/PORTABILITY.md` is the authority for how the engine runs on each platform: the inventory of non-portable constructs, the dependency list, the runner shims, the three scheduler renderers (systemd, launchd, foreground loop), `engine/doctor.sh`, the CI matrix, and the Windows position. This section does not repeat it. It states the support matrix, what distributed mode needs from the platform layer, and the points where the two documents were reconciled.

### 8.1 Support matrix

| Host | Tier | How it runs |
|---|---|---|
| Linux with a systemd user manager | today's behavior | timers and transient units |
| Linux without systemd (containers, minimal VMs, WSL2 without systemd) | supported | the portable runner shims and a scheduler renderer other than systemd |
| macOS (Apple silicon and Intel) | supported | launchd or the foreground loop; Homebrew bash 5 and GNU tools |
| Windows 11 | supported through WSL2 only | the engine runs in the Linux guest, so this is one of the Linux rows |
| Native Windows (cmd, PowerShell, Git-Bash, MSYS2) | not supported | the engine's locks are inherited file descriptors (`exec {fd}>file` plus `flock`, 160 named-fd sites), its process model is `setsid` groups and `kill -0`, its tests assume POSIX modes and symlinks; porting that is a rewrite |

Placement sees the differences through capabilities: `os` is `linux` or `darwin`, `wsl` marks WSL2, and `runner` and `timers` say how the host runs work. A ticket that needs a platform carries a label (`needs:os=darwin`, 4.9).

### 8.2 What distributed mode needs from the platform layer

1. **Nothing new to install for coordination.** `coord.sh` needs `git`, `gh`, `jq`, bash 5 and `flock`, all of which the portability layer already requires on every platform.
2. **A host-local `flock`.** The per-claim write lock (K1), the host-id file (S0) and the refresh stamp use it.
3. **The renewer runs under every scheduler.** `renewd.sh --once` is a 60-second job. K2 ships the unit pair `zenoforge-renewd.service` and `.timer`; the systemd, launchd and loop renderers of PORTABILITY.md must pick it up like any other timer (joint item PT-9).
4. **Liveness of a host's own runs.** `renewd` and `coord_acquire` ask "is my run alive" through the commands the engine already uses (`systemctl --user is-active zf-<stage>-<n>`, `stop`), which the portable shim answers on hosts without systemd, and through `zf_pid_alive` for unit-loop workers. They never ask about another host's runs; that is what the claim is for.
5. **Admission before claim.** A host checks its own capacity (memory floor, load, run count) before it acquires, so a loaded laptop does not hold tickets it cannot start. This works on every platform only after capacity admission stops reading `/proc` directly (PT-4).
6. **Capability fields** `os`, `arch`, `wsl`, `runner`, `timers` for the status record (K3 reads them; PT-9 adds the last three).
7. **Sleep is a designed failure.** A sleeping laptop or an idle-stopped WSL2 distribution stops renewing; its claims expire and another host takes over after the observation interval. Nothing extra is needed beyond the install notes.
8. **`AGENT_HOME` and worktrees on the Linux filesystem** under WSL2, never under `/mnt/...` (flock and modes are unreliable on DrvFs).
9. **CI.** The unit tests of `coord.sh` and the 100-trial harness run on the Linux, macOS and WSL2 legs of the CI matrix (PT-2), so a regression in the coordination code on one platform is visible.

### 8.3 Where the two documents were reconciled

PORTABILITY.md was written against the same tree. Where they differ on portability mechanics (packages and shims, system facts, the run ledger, the scheduler renderers, macOS test selection), it wins and this document follows it. Three points are not purely portability and are settled here:

| Topic | PORTABILITY.md | This document | Resolution |
|---|---|---|---|
| How the renewer timer is enabled | Listed in `pipeline-timers.list` with its own off switch (PT-9) | Listed in a host-local `$AGENT_HOME/timers.local.list` that `ctl.sh enable` writes (K2) | `run-tick.sh` treats an unset repository variable as `observe` and then enables the timer (`timer_mode` defaults to `observe`), so a shipped list entry would start the renewer on every host with coordination off and break off-neutrality, and each listed variable costs one REST call per tick. K2 owns the mechanism and the unit files; PT-9 only confirms the renderers pick the timer up. |
| Merge lock | "No merge lock is needed; the second merge fails" (head-pinned merge) | `lane-merge` kept (4.8) | The head pin makes a duplicate merge harmless; the lane keeps today's serial merge order, which post-merge verification and main-red attribution were written against, at a cost of two pushes per merge. It is the first thing to drop if it ever shows contention (section 11, item 4). |
| Takeover clock | "The observer's own monotonic clock" | Local wall clock with the gap rule (4.5) | Observation state must survive short-lived processes and reboots, which a monotonic reading cannot; the gap rule gives the same protection against clock steps. |

---

## 9. Tickets

Sixteen independently landable changes. The portability tickets are PT-1 to PT-10 in `docs/design/PORTABILITY.md`; PT-9 is the one joint item and is described under K2. IDs: **S** seam, **H** harness, **K** coordination core, **I** integration, **R** rollout. Every ticket is a change to `engine/<path>` (or `tools/`, `.github/`, `docs/`) and maps 1:1 to the upstream path. "Off-neutral" answers: with the new behavior not switched on, is a Linux/systemd single host unchanged, and how is that shown.

Landing order (arrows are dependencies): `S0 → S1`; `S0 → K1 + H1 → K2, K3, K4, K5, K6 → I1, I2, I3, I4 → I5, I6 → R1`. The PT tickets proceed in parallel with K; only PT-4 (capacity admission off `/proc`) gates admission-before-claim on non-Linux hosts, and PT-9 gates K2 on non-systemd hosts.

### Seam

**S0. Config loader, host identity, coordination switch.**
- *Files:* new `engine/config.sh`, `engine/config.test.sh`; `engine/lib.sh:18` to `:25` and `:286` to `:317`; `engine/run-tick.sh` (its own `AGENT_HOME` and slug derivation); the 16 files that re-derive `AGENT_HOME` (21 lines, for example `engine/land-queue.sh:4`).
- *Change:* `config.sh` resolves `ZF_ENGINE_DIR`, `ZF_REPO_DIR`, `ZF_REPO`, `AGENT_HOME`, `ZF_HOST_ID` (persisted in `$AGENT_HOME/host-id`), the `ZF_COORD*` variables, and defines the stub functions (`coord_*`, `effect_*`, `coord_lane_*`) returning success; it sources `engine/platform-env.sh` first when PORTABILITY.md PT-1 has landed (so `ZF_OS` is set), and sources `coord/coord.sh` only when `ZF_COORD=on`. Python entry points read the same variables from the environment.
- *Why:* later tickets need one place; today each script derives its own.
- *Off-neutral:* yes. Every default equals the old derivation; stubs have no callers yet.
- *Test:* `config.test.sh` compares old and new derivations in three layouts (engine inside target, `AGENT_HOME` override, no origin remote), host-id sanitization and persistence, and that sourcing it runs no `git` or `gh` (PATH shims fail the test).

**S1. Split engine directory from target repository.**
- *Files:* 73 lines in 28 files that build `<checkout>/engine/...` (`engine/mac-autopilot/scheduler.sh:15`, `:84`, `:993`, `:1028`, `:1463`, `:1939`, `:1957`, `:2004`, `engine/run-tick.sh`, `engine/mac-autopilot/runtime-env.sh:8` to `:14`, `engine/mac-autopilot/start.sh`, others).
- *Change:* mechanical replacement by `$ZF_ENGINE_DIR/...`; `start.sh` pins the engine repository (`ZF_ENGINE_REPO_DIR`, default the target checkout); `run-tick.sh` fast-forwards the engine checkout and fetches the target clone separately; a lint in `config.test.sh` forbids new `<checkout>/engine/` literals.
- *Why:* `docs/install.md` "Not generic yet" item 1; a host's engine version becomes independent of the target; this is the engine-versus-target seam the ruling put first.
- *Off-neutral:* yes. Default `ZF_ENGINE_DIR=$ZF_REPO_DIR/engine`. The 28-file diff is verified by the lint plus the full existing suites; no logic changes.
- *Test:* lint, all suites, and one fixture with engine and target in different directories (triage `--dry-run` end to end).

### Harness

**H1. Two-host simulation harness.**
- *Files:* new `engine/coord/sim/` (`lib.sh`, `bin/git`, `bin/gh`, `worker.sh`, `pre-receive`), `engine/coord/coordination.test.sh`.
- *Change:* section 7. Lands with K1 and grows with every ticket that adds a fault case.
- *Why:* the acceptance measurement must exist before the code it measures.
- *Off-neutral:* yes (tests only).
- *Test:* it is the test; the first version asserts race, status, and a plain death with takeover.

### Coordination core

**K1. `coord.sh`: claims, three-valued reads, takeover.**
- *Files:* new `engine/coord/coord.sh`, `engine/coord/coord.test.sh`.
- *Change:* 4.3 to 4.5: `coord_init`, `coord_refresh`, `coord_read`, `coord_acquire`, `coord_release`, `coord_assert_owned`, observation state, held entries with a per-claim host-local flock, `coord_now_s` with the virtual-clock seam.
- *Why:* the primitive everything else calls.
- *Off-neutral:* yes. Not sourced unless `ZF_COORD=on`.
- *Test:* 20-way race has one winner, partial batch, readback after lost ack, observation resets on gap and on backward clock step, malformed and too-new claims are unknown; harness trials 1 to 12.

**K2. `renewd`: renewal, status publish, self-fence, janitor.**
- *Files:* new `engine/coord/renewd.sh`, `engine/systemd/zenoforge-renewd.service` and `.timer` (oneshot, every 60 s); `engine/run-tick.sh` reads an extra `$AGENT_HOME/timers.local.list` (3 lines) so the timer is repaired by the existing mechanism only on hosts that enabled coordination.
- *Change:* one batched push per pass (4.5), `instance` check, release of claims whose run has been gone for the 300 s grace, self-fence stop, deletion of claims released and unchanged for 7 days.
- *Why:* neither loop can renew every minute; a timer-driven pass needs no resident process, and every scheduler renderer of PORTABILITY.md picks the unit pair up (joint item PT-9, which only confirms the renderers; K2 owns the unit files and the enable mechanism, see 8.3).
- *Off-neutral:* yes. The list file is absent unless `enable` writes it; the unit file is installed but not enabled.
- *Test:* unit tests with the fake runner; harness death, self-fence and lost-ack trials.

**K3. Capabilities and status.**
- *Files:* new `engine/coord/caps.sh`, `engine/coord/status.sh`.
- *Change:* 4.9 record, detection, `status show`.
- *Why:* placement and observers need it; the acceptance requires both hosts visible.
- *Off-neutral:* yes.
- *Test:* detection with stubbed commands; golden `status show`.

**K4. Operator surface.**
- *Files:* new `engine/coord/ctl.sh`, `engine/coord/README.md`.
- *Change:* subcommands `probe`, `enable`, `adopt-local`, `drain`, `control set`, `effect clear`, `claim clear`, `purge`, `status show`.
- *Why:* rollout, rollback and the two operator overrides in 4.7 and failure row 19.
- *Off-neutral:* yes.
- *Test:* probe against a bare remote (create, check, delete with lease); `adopt-local` with a stubbed `zf-*` unit list and a `units.json` fixture; drain stops new acquires and releases at stage end; `control set primary=` stops other hosts within one tick.

**K5. Checkpoint projection and restore.**
- *Files:* new `engine/coord/checkpoint.json`, `engine/coord/checkpoint.sh`; adapter `scheduler_unit_restore` in `engine/mac-autopilot/scheduler.sh`.
- *Change:* 4.6.
- *Why:* without it a takeover loses attempts and advisor rulings.
- *Off-neutral:* yes (only called from `renewd` and `coord_acquire`).
- *Test:* round trip with real `state/<n>.json` and `units.json` fixtures; oversize keeps the old checkpoint; restore failure releases the claim and alerts.

**K6. Effect intents.**
- *Files:* new `engine/coord/effects.sh` and `engine/coord/reconcile.d/{merge,push,revert,deploy,mail,comment}.sh`; adapters in `engine/lib.sh` (`guarded_pr_merge`), `engine/notify.sh` (`send_email_strict`), `engine/pipeline-issue-upsert.sh`.
- *Change:* 4.7, including the `effect_run` wrapper that `guarded_pr_merge` and `send_email_strict` call.
- *Why:* leases do not fence external systems.
- *Off-neutral:* yes. The adapters call the stubs.
- *Test:* per-kind unit tests with the fake `gh`; harness trials with merge, deploy and mail death points.

### Integration

**I1. Issue-loop dispatch gate and remote occupancy.**
- *Files:* `engine/issue-pipeline.sh` (`dispatch` `:390`, batches `:478`, `:509`, `:556`, candidate loops), `engine/lib.sh` (`stage_unit_active` `:13280`, `stage_unit_count` `:13381`, `stage_active_issues` `:13511`), `engine/run-triage.sh`, `run-recut.sh`, `run-advisor.sh` (upstream also `run-implement.sh`, `run-release.sh`), `engine/supervise-pipeline.sh:140`.
- *Change:* section 5 rows for those anchors; `coord_enter` at wrapper entry; exit trap releases.
- *Why:* failures 1 and 2 of 1.1.
- *Off-neutral:* yes. Stubs; shown by the off-mode proof (7.6) over the dispatch fixtures.
- *Test:* two fake hosts, one bare remote: one dispatch; an unknown read dispatches nothing and charges no attempt.

**I2. Mutation gate.**
- *Files:* `engine/lib.sh` (`guarded_write` `:4017`, `issue_transition` `:1879`), sweepers (`engine/sweep-merges.sh`, `sweep-acceptor-backlog.sh`, `sweep-parked-backlog.sh`, `checks_blocked_sweep` and `closed-state` reconcile in `lib.sh`).
- *Change:* `coord_assert_owned "$ZF_COORD_SCOPE"` in `guarded_write`; sweepers wrap each write in `coord_with_ticket`.
- *Why:* the ruling requires enforcement inside the shared mutation functions, including direct entry paths.
- *Off-neutral:* yes. Stub.
- *Test:* unscoped write refused when on, unchanged when off; direct manual `run-triage.sh` acquires or fails.

**I3. Unit-loop gate and restore. (Riskiest.)**
- *Files:* `engine/mac-autopilot/scheduler.sh` (`room_for` and `dispatch_if_room` `:1721` to `:1760`, `dispatch` `:987`, `harvest_workers` `:2960`, `recover_orphans` `:3233`, footprint `:1386`).
- *Change:* section 5 rows; acquire in `dispatch_if_room` (the 7 callers share it); release after harvest; takeover restore through `units_update`; footprint check reads remote claims.
- *Why:* the unit loop owns implement, review and merge.
- *Off-neutral:* yes. Shown by running the existing scheduler fixtures with and without the change and diffing `scheduler.log` and `units.json` (byte-identical).
- *Test:* acquire-before-dispatch, release-after-harvest, takeover restore, `write_state` guards still reject deletions.

**I4. Lanes.**
- *Files:* `engine/lib.sh:4543` and `:14769`, `engine/mac-autopilot/scheduler.sh` (`:5392`, `run_merge_lane` `:5062`, `run_release_train` `:6408`, `fast_land_lane` `:2399`, `open_main_red_unit` `:6444`), `engine/land-queue.sh`, `engine/land-direct-main.sh`, `engine/issue-pipeline.sh:478` and the main-red step, `engine/hotfix/hf-merge.sh:39`.
- *Change:* 4.8.
- *Why:* failures 3, 4, 5 of 1.1.
- *Off-neutral:* yes. Without coordination the old flock and stamp paths run unchanged.
- *Test:* lane exclusivity; a dead lane holder is taken over; **the 100-trial harness is a merge gate for this ticket.**

**I5. Placement.**
- *Files:* new `engine/coord/place.sh`; `engine/mac-autopilot/scheduler.sh:588` (`cooling`), `engine/issue-pipeline.sh` candidate filters, `engine/lib.sh` provider quota.
- *Change:* 4.9: capability filter, rendezvous stagger, affinity, peer cooldown.
- *Why:* "dispatch picks work a host can do"; a 429 on a shared account stops everyone.
- *Off-neutral:* yes. Stub returns "eligible".
- *Test:* harness trials 91 to 100; unit tests for rank and stagger.

**I6. Observers and alert dedupe.**
- *Files:* `engine/supervise-pipeline.sh`, `engine/mac-autopilot/node_health.py`, `gen_dashboard.py`, `bell.sh`, `engine/lib.sh:131`, `engine/pipeline-issue-upsert.sh:53`, `engine/ticket-progress.sh`.
- *Change:* read claims and `refs/seen/status/*`, show peers as stale or unreadable, event claims for repo-wide alerts, the issue-create lease for upserts.
- *Why:* local unit absence must stop meaning global inactivity for observers too.
- *Off-neutral:* yes. Extra readers see no coordination data and behave as before.
- *Test:* golden dashboard fixture with remote status; duplicate-alert test across two hosts.

### Rollout

**R1. Operator documentation.**
- *Files:* new `docs/distributed.md`, updates to `docs/install.md`, `docs/architecture.md` (sections 4 and 10), `engine/README.md`.
- *Change:* section 10 as an operator guide.
- *Off-neutral:* yes (docs).
- *Test:* none beyond review.

---

## 10. Rollout, single host to two hosts, with rollback

Every step has one command from `engine/coord/ctl.sh` (K4).

| Step | Action | Proves | Rollback |
|---|---|---|---|
| 0. Land dark | Merge tickets in the order above with `ZF_COORD` unset | The off-mode proof (7.6) and every existing suite | Nothing to undo; the behavior is unchanged |
| 0.5. Probe | `ctl.sh probe` on the real target repository: push `refs/claims/probe-<host>` through the coordination clone, confirm `ls-remote` shows it, confirm no workflow run and no branch appeared, delete it with a lease | The ref namespace is accepted, the token may push it, git transport works through the host's proxy, and no CI run is triggered | Probe deletes itself |
| 1. Enable on the existing host alone | `ctl.sh enable --host-id host-a`: write `host.env` (`ZF_COORD=on`, `ZF_HOST_ID`), extend `timers.local.list`, start the timer, run `adopt-local` (claim every running `zf-*` unit and unit-loop worker with its checkpoint, so old unleased workers never overlap new ones, with no drain window) | Claims against real GitHub with real work, before a second host exists | `ZF_COORD=off`; `ctl.sh purge --host host-a` |
| 2. Add the second host | Install the engine on any supported host (8.1), own `GH_TOKEN`, `ctl.sh enable --host-id host-b`. First `ctl.sh control set primary=host-a` so host-b publishes status and capabilities but dispatches nothing; check `ctl.sh status show`; then `control set primary=` (clear) | Both hosts visible; the second host only starts taking work once it can be seen | `control set primary=host-a` (one write, effective within one tick) |
| 3. More hosts | Repeat step 2 | | Same |

Rollback levers, fastest first:

1. `ctl.sh control set primary=<host>`: every other host stops acquiring within one tick; their running claims finish and release.
2. `ctl.sh drain <host>`: that host stops acquiring and releases at stage end; then stop its timers.
3. `ZF_COORD=off` on a host: safe only on the last remaining host, so first set `primary` and drain the others.
4. `ctl.sh purge`: delete every ref under `refs/claims`, `refs/status`, `refs/coord`. Leaving them behind is harmless; each ticket's local state is intact because local files stay the working copy.

**What the origin deployment's live host must change to enable it:**

1. Land S0 through R1 (all off-neutral). S1 (engine/target split) is needed only at the planned cutover, not for coordination.
2. Write `host.env` with `ZF_COORD=on` and a `ZF_HOST_ID`; enable the coordination timer through `ctl.sh enable`.
3. Allow the pipeline token to push `refs/claims/*`, `refs/status/*`, `refs/coord/*` (the token already pushes `agent/*` branches; the step-0.5 probe confirms it).
4. For the second host: its own GitHub identity (the REST budget is per identity), an engine at the same or a newer SHA, and `ZF_PROVIDER_ACCOUNT_<provider>` tags if hosts share one agent account.
5. Nothing else: no new service, database, or secret.

---

## 11. Decisions this design leaves to the operator

1. **GitHub identity per host.** From two hosts on, the REST budget is the binding limit (4.10). A machine account or an app installation per host is the fix; the origin deployment deferred a pipeline machine account on 2026-10-22, and N=2 is the point where that decision matters.
2. **Public target repositories.** Claim and status records are as readable as the repository. They contain logical host ids and ticket keys only, but the naming convention for host ids is the operator's.
3. **Lease parameters.** 60 s and 900 s are the ruling's and unmeasured here. The harness runs on a virtual clock, so any other pair can be exercised for free before it is chosen.
4. **`lane-merge` and `lane-land`.** A head-pinned merge and the final `git push origin HEAD:main` are already optimistic swaps, so the two lanes only keep today's serial merge order and single-flight post-land attribution. If either is not worth one more lease per operation, drop it; nothing else depends on them.
5. **Census sharing** (4.10 item 3) stays unbuilt until the status refs show hosts shedding reads.
6. **Windows through WSL2 only.** Native Windows is a deliberate non-goal (section 8.1).
