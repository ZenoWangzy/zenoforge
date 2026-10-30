# Zenoforge architecture

> **Alpha.** This page describes what the code in `engine/` does, read from the scripts. Where this page and the code disagree, the code is right. For installing and running it, see [install.md](install.md).

## At a glance

Zenoforge runs two loops on one host. Both are plain Bash, Node, and Python scripts, started by systemd timers or by hand. Neither loop runs an agent in the foreground. A tick decides what should happen next, starts detached workers, and exits. The next tick reads what the workers left behind.

Ticket state lives in GitHub labels and comments. The engine also keeps a per-issue JSON snapshot and a unit ledger on disk.

| Loop | Entry point | Cadence | Owns |
|---|---|---|---|
| Issue loop | `engine/run-tick.sh` runs `engine/issue-pipeline.sh` | every 5 min (`engine/systemd/zenoforge-agent.timer`) | issue labels and stage changes: triage, advisor, recut, holds, release batches, main-red recovery |
| Unit loop | `engine/mac-autopilot/loop.sh` runs `scheduler.sh` | every 120 s, with a refill pass every 30 s | work units (implement, review, self-fix, land, and others), the serial merge queue, dashboard and health data |

About 50 of the 230 non-test files under `engine/` and `tools/` contain Chinese text (comments, strings, prompts and state files), so expect to read some of it.

## 1. The two loops

### 1.1 Issue loop

`engine/run-tick.sh` is the entry point. It runs as a oneshot unit (`engine/systemd/zenoforge-agent.service`). Each tick does this, in order (function `run_tick`):

1. Saves any uncommitted changes in the dedicated checkout to `$AGENT_HOME/quarantine/`, then resets the checkout to HEAD.
2. Refuses to run unless the checkout is on `main`.
3. Fetches `origin/main` and fast-forwards to it. If the default model policy changed, it refreshes the live policy copy (`engine/model-policy-fast-forward.sh`).
4. Copies changed `*.service` and `*.timer` files from `engine/systemd/` into the systemd user directory and runs `daemon-reload`.
5. Enables or starts each timer listed in `engine/systemd/pipeline-timers.list`, unless that timer's GitHub variable is set to `off`.
6. Runs `engine/issue-pipeline.sh`.

A tick that refuses counts as a failure. After three in a row, it writes an event to the supervisor inbox.

`engine/issue-pipeline.sh` is a bounded-concurrency dispatcher. Its header says it "only ever decides, it never blocks on an agent model call." It fills each stage's cap by starting transient units with `systemd-run --user --collect`, so the work outlives the tick. The unit names follow `zf-<stage>-<n>`, for example `zf-triage-<n>`, `zf-advisor-<n>`, and `zf-release-batch`. The stages it dispatches are:

- triage (`run-triage.sh`, `run-triage-batch.sh`)
- advisor (`run-advisor.sh`, `run-advisor-batch.sh`). The advisor role is disabled by default, and no advisor provider ships.
- recut (`run-recut.sh`)
- needs-info replies (`reconcile_needs_info_issues`)
- release batches (`run-release.sh`)
- one main-red recovery step (`main-red-bisect` in the sweep loop)

Two of these scripts are not in this checkout: `run-release.sh` and `run-advisor-batch.sh`. The implement leg is described in the header as `run-implement.sh`, which is also missing. See [install.md](install.md#not-generic-yet).

### 1.2 Unit loop

`engine/mac-autopilot/loop.sh` runs forever. Its pieces:

- **Scheduler tick.** Every `tick_seconds` (120 by default, from `engine/mac-autopilot/config.template.json`), it runs `scheduler.sh` under a timeout (`AUTOPI_TICK_LIMIT_SECONDS`, default 1800).
- **Refill pass.** Between ticks, a refill runs every 30 seconds (`AUTOPI_REFILL_SECONDS`), so a freed worker slot is refilled without waiting for the next tick.
- **Bell.** `engine/mac-autopilot/bell-loop.sh` runs `bell.sh`, one anomaly scan, every 120 seconds.
- **Watcher.** Every 15th loop, it runs `watcher/watch.sh` from the supervisor directory, if that file exists.

`scheduler.sh` is about 6,500 lines in numbered sections. The ones that matter most:

- **1. Harvest.** Collects finished workers and classifies them by type. The ledger is `units.json`, the live workers are in `workers.json`.
- **1b, 1c. Recovery.** Repairs orphaned work and disposes of stuck workers.
- **2. Dispatch.** Starts new work, bounded by focus and concurrency.
- **3. Merge queue.** Merges approved PRs one at a time, then checks the exact merged SHA on main.
- **4a. Intake.** Pulls issues into free capacity.
- **4b. SLO guard.** Writes an alert when a waiting stage runs past its budget.
- **4c. Release trigger.** Every 15 minutes, runs the issue loop's release selector.
- **4. Review.** Reviews the newest pending PRs, up to a limit.
- **4z. Acceptance.** Closes direct-landed tickets once the production event they wait for is recorded.

The scheduler also has an old-PR lifecycle section and derived views (health score and dashboard data).

### 1.3 How the loops meet

They share GitHub labels and the per-issue state files. The issue loop never merges. Its header says merge is "owned by the autopilot scheduler, not by this script." The unit loop does not source `lib.sh`. It has its own transition helper (`scheduler_issue_transition` in `engine/mac-autopilot/scheduler.sh`), written to follow the same rules.

## 2. Stage chain and labels

```
  new issue (no state label yet)
        |
        v
  needs-triage --- triage (run-triage.sh) decides the route
        |
        +--> ready-for-agent --> implement --> PR --> review --> repair --> merge
        |        |    ^                                                       |
        |        |    +-- advisor verdict -- needs-advisor (run-advisor.sh)   v
        |        |                                                    awaiting-release
        |        |                                                            |
        |        |                                  release batch (run-release.sh)
        |        |                                                            v
        |        |                                                  released --> concluded
        |
        +--> needs-recut --> recut (run-recut.sh) --> child issues, parent becomes a tracker
        +--> needs-info          waits for a person's answer, then goes back to triage
        +--> ready-for-human     a person decides; the pipeline never moves past it
```

The diagram shows the main path and the common side branches. `ISSUE_TRANSITION_TABLE` in `engine/lib.sh` lists every allowed move.

### 2.1 The labels

`ALL_STATE_LABELS` in `engine/lib.sh` is the list of state labels the engine manages:

| Label | Meaning in the code |
|---|---|
| `needs-triage` | Waiting for triage |
| `needs-info` | Waiting for an answer from a person |
| `ready-for-agent` | Accepted for implementation |
| `ready-for-human` | A person decides. The code comment says this is the one state the pipeline never automates past |
| `needs-advisor` | Sent to the advisor for a judgment call |
| `needs-recut` | Too big. To be cut into child issues |
| `checks-blocked` | Required checks could not run or could not be read. A sweep re-checks them (`checks_blocked_sweep`) |
| `needs-owner` | Needs an owner before work can move. The code has no comment for it, so check the callers |
| `duplicate`, `wontfix`, `finish-first` | Closed as a duplicate or declined. `finish-first` waits for a blocking PR to land |
| `awaiting-release` | Merged. Waiting for release |
| `awaiting-pipeline-sync`, `awaiting-pipeline-health` | Waiting for the pipeline's own sync or health check before release |
| `released` | Deployment proven in production |
| `concluded` | Finished with a proven outcome |

Two more labels are used but are not in that list:

- `on-hold`, set by `hold_issue` (`engine/lib.sh`).
- `tracker`, for umbrella issues that have child issues. Retired by `retire_tracker_parent`.

The `hotfix` label is covered in section 7.

### 2.2 How labels change

Every state change goes through `issue_transition` (`engine/lib.sh`). It checks the transition table and any reason-specific rules (`issue_transition_allowed`). It takes the same lock as `state_merge`, so two writers cannot interleave. GitHub and the local file cannot share a transaction. If the GitHub label write fails, the local snapshot rolls back. Any drift it cannot undo is reported by the health checks.

`ensure_state_labels` (`engine/lib.sh`) creates any missing state label on the repository during the fast-lane tick, so you do not need to create them by hand.

## 3. Workers and backends

There are two worker paths. The unit loop is the main one.

### 3.1 Unit loop workers

`scheduler.sh` builds each worker command in `build_codex_command`:

- Fresh runs use `codex exec` with the model and reasoning effort from `config.json`, under the `models` key (`[model, effort]`).
- Resumed runs use `codex exec resume <session>` when the unit already has a session.
- A Claude model runs as `claude -p` with no write permission. The dispatcher saves its report from stdout. Review workers use this path, with the read-only tool allowlist `CLAUDE_REVIEW_TOOLS` and `--permission-mode dontAsk`.

`pick <role>` (`scheduler.sh`) chooses the model. It tries `<role>_hotfix` first for units with the `hotfix` label, then `<role>`, then `<role>_fallback`. It skips any model whose provider is cooling down.

Cooldowns come from `start_cooldown`. A provider goes on cooldown for 30 minutes when the error says a usage or quota limit was hit. Otherwise it is 5 minutes, which covers the short capacity and overload errors.

The issue loop's codex sandbox mode is `ZF_CODEX_SANDBOX`, default `danger-full-access` (`CODEX_SANDBOX_MODE` in `engine/lib.sh`). The unit loop does not read it: `build_codex_command` in `scheduler.sh` always passes `-s danger-full-access`. See the security note in section 11.

### 3.2 Wrapper workers: `engine/bin/worker`

`bin/worker <key> <cwd> <prompt-file> [schema]` runs one agent with failover. The factory feeder (`engine/factory/launch.sh`) starts it. Its behavior, from the file:

- **Backend choice.** `WORKER_BACKEND=luna` or `zc` picks the first backend. Otherwise, the backend with fewer runs in flight is chosen, and ties alternate. `luna` is Codex through `bin/luna`. `zc` is ZCode through `bin/zc`.
- **Capacity gate.** `bin/luna` waits until fewer than `LUNA_MAX` runs (default 10) are active, sampled CPU is under `LUNA_CPU_TARGET` (default 85%), memory pressure is under 5%, and at least 3 GB is free. Each run is placed in a systemd scope with `MemoryMax` set to `LUNA_MEM_MAX` (default 4G).
- **Stall detection.** If output and `git status` and HEAD have not changed for `WORKER_STALL_MINUTES` (default 10), the run is stopped.
- **Breakers.** When a backend fails, the wrapper touches a breaker file (`tmp/luna-breaker` or `tmp/zc-breaker`). While the file is younger than `WORKER_BREAKER_SECONDS` (default 1800), that backend is skipped.
- **Failover.** One failover to the other backend, in the same worktree. The prompt tells the second agent that another agent already worked there. If both backends fail, the wrapper writes rc 75 and exits with it, and records each step in a `failover` file.
- **Model escalation.** After two failed rounds on the same ticket (counted in `rounds.log`), the model switches to `gpt-6.1-terra`. The name is hard-coded. If a run fails with "Selected model is at capacity" on a terra or sol model, the wrapper retries with `gpt-6-luna`.

### 3.3 Issue loop escalation

`escalation.steps` in `engine/model-policy.default.json` lists four steps: `work`, `advisor`, `work_retry` (one attempt), and `conclude`. A failed `work` step retries itself. Advisor success leads to `work_retry`, and a failed `work_retry` leads to `conclude`. Which issues reach the advisor is decided by the routing functions in `engine/lib.sh` (for example `route_to_advisor`), not by the file alone.

In `engine/lib.sh`, `same_failure_streak` counts repeats of the same failure. `two_strike_failure_class` separates environmental failures (quota, timeouts, slot waits) from the rest. `implement_two_strike_route` acts on the repeats.

## 4. Capacity admission

Capacity is enforced in two layers.

1. **Shared admission** (`engine/execution-admission.py`). `engine/execution-shim/` shadows `systemd-run` on the PATH, so unit starts pass through the check. Shell callers use `engine/execution-admission.sh`, which runs the Python check and run commands. The admission uses OS file locks, so the count holds across processes. Each check computes how many more workers fit, from:
   - the global cap `AGENT_GLOBAL_EXECUTION_CAP` (1 to 16, default 10),
   - a memory floor `AGENT_EXECUTION_MIN_MEM_MB` (default 6144),
   - available memory divided by `AGENT_EXECUTION_MEM_PER_WORKER_MB` (default 1024),
   - load average headroom from `AGENT_EXECUTION_MAX_LOAD` (default: CPU count) and `AGENT_EXECUTION_LOAD_PER_WORKER`,
   - an optional CPU target `AGENT_EXECUTION_CPU_TARGET_PERCENT` (1 to 95).

   Priority classes (`hotfix`, `release`, `opt`, `normal`) get different headroom. A start that does not fit is deferred. The caller records the deferral and retries on a later tick. Invalid capacity values also defer, instead of running.
2. **Wrapper gate** in `bin/luna`, described in section 3.2.

Two more guards sit above these:

- In `run-tick.sh`, if `git fetch` times out while the 1-minute load is above `AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER` (default 2) times the CPU count, the tick refuses with `fetch-starved` and dispatches nothing.
- In the unit loop, `max_workers` (10) and `implement_cap` (8) in `config.template.json` bound concurrency.

## 5. Review by a different provider

The intent is that the reviewer uses a different provider from the implementer. The code tries to do that, and it records when it cannot.

**Issue loop.** `review_model_for_implementer` (`engine/lib.sh`) takes the `review` role from the live policy. If that role names a different provider and the provider is available, it is used. Availability means the provider's quota is not exhausted and its CLI and config are present. For Codex, a probe must also pass. If the review role is unavailable or uses the same provider, the code records `review_provider_fallback` in the issue state and reviews on the implementer's own provider. A ZCode implementer can use the `work` role's provider instead (`review_cross_identity_for`).

With the shipped `model-policy.default.json`, both `work` and `review` use the Codex provider. So the default lookup finds no different provider, and the review falls back to Codex. The `forbidden` list in the same file blocks any role whose model, effort, or fallback text contains `claude`, `sonnet`, `opus`, or the other listed words (`model_policy_validate_json` in `engine/lib.sh`). The availability check only knows Codex and ZCode, so ZCode is the only other provider the review path can use in this loop. If it is not available, the fallback is recorded.

**Unit loop.** `engine/mac-autopilot/config.template.json` sets the `review` model to a Claude model and the `implement` model to a Codex model. So the default unit-loop review is cross-provider, and the Claude reviewer runs read-only.

**Known inconsistency.** The two model systems are not reconciled. The `forbidden` check does not read `config.json`. The template's `implement_hotfix` entry uses `gpt-6.1-terra`, a name that the policy's forbidden list would reject in a policy role. The escalation path in `bin/worker` also hard-codes that name.

## 6. Merging

**Product PRs.** The unit loop merges, in a serial queue (`scheduler.sh`, section 3). The command is `gh pr merge <pr> --squash --match-head-commit <approved-sha>` (`scheduler.sh`, merge queue section 3). GitHub refuses the merge if the head moved after the review that approved it. After the merge, the scheduler runs the suites against the exact merged SHA on main.

**Required checks.** Each PR workflow should end with one always-concluding aggregate job. `engine/ci/pr-required-aggregate.mjs` computes the verdict. A conditional gate can be skipped only when the `--expected` ownership clause says it should not run. Any other skip, failure, or missing result is red. Exit codes: 0 green, 1 red, 2 bad arguments. The scheduler reads the names that must pass from `engine/mac-autopilot/required-pr-checks.json` and refuses any PR that lacks a real pass on each one (`required_checks_without_pass`).

**Red main.** The issue loop has a `main-red-bisect` step. Each tick runs one bounded step of recovery: a flaky rerun, then culprit attribution, then a revert PR named `agent/revert-main-<issue>-<sha12>`, then a reopened ticket. The culprit search is `main_ci_find_first_failing_pipeline_candidate` in `engine/night/main-ci-recovery.sh`. Despite the step name, it does not binary-search. It walks the candidate commits in order, and blames the first commit where the suite is green on its parent and red on itself. The search has a 240-second ceiling. An optional judge (`engine/ts-judge.mjs`) can replace the culprit only when it reports `adopted`.

`engine/sweep-merges.sh` merges the revert PR once its checks are green, through the same head-pinned merge. A failed production release is attributed by `engine/deploy-culprit.sh` to the one merged change that touched the failed migration or image. Its revert branch is `agent/revert-deploy-<issue>-<sha12>`.

**Direct-main lane.** Changes that do not need a PR review go through `engine/mac-autopilot/land-pr.sh`. It squashes the approved PR into one `[skip ci]` commit and lands it with `engine/land-direct-main.sh`. Before it lands, it asks the target repository's `scripts/branch-delivery-policy.mjs` to classify the change. That file is not part of this engine, and the bootstrap refuses to land without it. `engine/land-queue.sh` stores each landing request with its head SHA, and refuses to land if the branch no longer points at that SHA.

## 7. Hotfix lane

A change enters the hotfix lane when the issue has the `hotfix` label, or the branch starts with `hotfix/` or `agent/issue-hf-` (`hotfix_lane` in `config.template.json`, and `is_hotfix_lane_issue` in `engine/lib.sh`).

- **Priority.** `dispatch_priority_order` is `hotfix`, `opt`, `normal`. Admission gives hotfix work more headroom. `bin/luna` gives `LUNA_PRIORITY=hotfix` runs the top CPU weight and keeps the memory floor.
- **Scripts** in `engine/hotfix/`:
  - `hf-start.sh` creates a locked worktree from `origin/main` and starts a priority worker.
  - `prepush-gates.sh` runs the PR gates on the candidate commit before push.
  - `hf-pr.sh` opens the labeled PR.
  - `hf-merge.sh` refuses to merge unless the label is set, the acceptance record passes, and every check in `required-pr-checks.json` has passed.
  - `hf-install-gate.sh` refuses an install until main CI is green on a commit that contains the merge.
  - `hf-stale.sh` lists hotfix PRs with no push for `HF_STALE_MINUTES` (default 30).
  - `hf-source-check.sh` refuses any file that is not on `origin/main` or in an open hotfix PR.
- **Acceptance record.** The PR body carries one JSON block between `zf-hotfix-acceptance` markers. `hf-merge.sh` requires `status` to be `passed`, and `accepted_head_sha` to equal the current PR head. The block also names the person who accepted it (`engine/hotfix/README.md`, and `validate-acceptance.mjs`).

## 8. Health, dashboard, and cost

- **Node health.** `engine/mac-autopilot/node_health.py` scores each node of the flow (intake, implement, review, PR CI, merge, main Postsubmit, release, production, close, plus the scheduler tick, workers, and supervisor). Each node is healthy, unhealthy, or WARN in between. The bounds are in `engine/mac-autopilot/NODE-HEALTH.md`. The `node_health` key in `config.json` overrides a bound for one metric. `--alert` writes unhealthy nodes to the alerts file. `--file-issues` can open or comment on GitHub issues, and runs only when you pass the flag.
- **Bell.** `bell.sh` runs every 120 seconds and includes a stale-dashboard check.
- **Dashboard.** `gen_dashboard.py` writes the dashboard data. `dashboard.html` is a static page in the runtime directory.
- **Reports.** `health_report.py` and `waste_report.py` are read-only summaries of the pipeline's records, including token and CI-repair waste.
- **Cost.** `worker_cost.py` reports spend per unit, ticket, phase, and backend. `usage_reader.py` is the one reader for token use from session logs. `ci_spend.py` reports CI runner minutes and the share that could not change a verdict, and writes `ci-spend.json` for `node_health`. `config.template.json` holds a price table and a `daily_token_budget`. The file's own note says the prices are estimates based on public list prices, not a bill.

## 9. Lessons and rules

Lessons are stored in the target repository, under `lessons/`, and not in this engine. The engine expects `lessons/RULES.md`, `lessons/CATALOG.md`, `lessons/full/` (root-cause write-ups), `lessons/pending/`, and `lessons/recurrence-ranking.json`.

- `engine/generate-lesson-enforcers.mjs` reads `lessons/RULES.md` and `engine/state/incident-guards.json`, and writes `lessons/enforcers.json`.
- `engine/lesson-lints.mjs` adds landing-time checks for lessons that have recurred at least twice and have a structural prevention anchor.
- `engine/lesson-recurrence-ranking.mjs` ranks lessons by recurrence.
- `engine/lesson-fragments.sh` tracks lesson fragments and their guard registration.

`engine/state/mechanism-registry.json` also exists. This page does not cover it.

## 10. Where state lives

| Path | Default | What it holds |
|---|---|---|
| `$AGENT_HOME` | `~/.zenoforge` (`AGENT_HOME`, else `ZF_HOME`) | Root for issue-loop state (resolved in `engine/config.sh`, which `engine/lib.sh` sources first) |
| `$AGENT_HOME/host-id` | | Logical host name, written once, and only when `ZF_COORD=on` (`zf_host_id_resolve`, `engine/config.sh`) |
| `$AGENT_HOME/state/<issue>.json` | | One JSON snapshot per issue: attempts, stage history, review fallback, label snapshot. `state_file`, `engine/lib.sh` |
| `$AGENT_HOME/model-policy.json` | | Live model policy, copied from `engine/model-policy.default.json` (`MODEL_POLICY_DEFAULT` in `engine/lib.sh`) |
| `$AGENT_HOME/capacity.env` | | Host capacity settings (`AGENT_*` keys). Sourced by `lib.sh` |
| `$AGENT_HOME/PAUSE` | | Manual stop. A JSON object with `caller` set to `operator`, plus `reason`, `issue`, `provider`, `model`, and an ISO UTC `timestamp` (`manual_pause_is_valid`, `engine/lib.sh`) |
| `$AGENT_HOME/quarantine/` | | Saved dirty-checkout changes from `run-tick.sh` |
| `$AGENT_HOME/logs`, `night/`, `main-red/`, `locks/`, `land-queue/`, `mails/`, `supervisor-inbox` | | Logs and records for each subsystem |
| `$WORKER_SCRATCH_ROOT` (default `~/.zenoforge/scratch`) | | `bin/worker` runs: `luna/<key>/` (events, last message, rc), `failover`, `rounds.log`, and `tmp/*-breaker` |
| `ZF_WORKTREE_ROOT` (default `~/wt`) | | Git worktrees |
| `<checkout>/.scratch-supervisor/autopi/` (`MAC_AUTOPILOT_RUNTIME_DIR`) | | Unit-loop runtime: `units.json` (the unit ledger), `workers.json` (live workers), `config.json` (runtime config, reconciled from the template), `scheduler.log`, `alerts/`, `pr-run-snapshot.json`, `dashboard.html` |
| `<checkout>/.scratch-supervisor/autopi-versions/<sha>/` | | Published copy of `engine/mac-autopilot` at one commit. `autopi-live` points at the current one (`engine/mac-autopilot/start.sh`) |

`units.json` is not under `$AGENT_HOME`. It is in the checkout's `.scratch-supervisor` tree, because the unit loop's root is derived from the checkout.

GitHub is the source of truth for labels. The local state file is a snapshot of them.

## 11. Security note

Workers run with broad permissions by default. Codex runs in `danger-full-access`. The issue loop reads `ZF_CODEX_SANDBOX` (default `danger-full-access`), and the unit loop always passes `-s danger-full-access`. ZCode runs in yolo mode (`engine/bin/zc`, which says yolo "is not a sandbox"). The engine does not sandbox workers. Run it under a dedicated OS account on a machine you can rebuild.

## 12. What this page does not cover

- How the implement and release legs run in full. Their scripts are not in this checkout. See [install.md](install.md#not-generic-yet).
- The eval harness (`engine/eval/README.md`). It has no case files in this checkout.
- The `mechanism-registry.json` and `rule-files.json` seeds.
