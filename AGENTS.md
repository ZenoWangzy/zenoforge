# Zenoforge

Goal: an unattended, fully automatic, self-healing software factory. No human in the loop is the target, so do not propose human-intervention metrics or new hand-offs to a person. The `ready-for-human` and `needs-info` exits are gaps to remove, not features to keep.

A self-hosted software factory: coding agents take GitHub issues through triage, recut, implement, review, repair and merge. The engine is Bash, Node and Python under `engine/`; `docs/architecture.md` maps it.

## Method: Matt skills

Work here follows Matt Pocock's skills, vendored in `.agents/skills/` and entered through `/ask-matt`. Start there when unsure which one fits.

- A new idea or an unclear request: `/grill-with-docs`, then `/to-spec`, `/to-tickets`, and `/implement` per ticket, which drives `/tdd` one red-green slice at a time.
- A bug, flake or regression: `/diagnosing-bugs`. A command that goes red on the bug comes before the fix.
- A change ready for review: `/code-review` against a fixed point (Standards and Spec).
- A pull request body: `/pr`.
- A raw issue nobody has shaped: `/triage`. Tickets from `/to-tickets` are already agent-ready.

The engine's own stages use the same skills (`docs/architecture.md`, "Method: Matt skills"). The skill files are MIT and byte-identical to upstream: change the pin with `tools/sync-matt-skills.sh <commit>`, never by hand (`THIRD_PARTY_NOTICES.md`).

## Public repo

This repository is public. Keep customer names, home-directory paths, hostnames, private repository names and credentials out of code, tests, docs, commit messages and PR text. Call the pipeline Zenoforge was extracted from "the origin deployment".

## Tests

- All suites: `bash tools/run-engine-tests.sh`, or one shard: `bash tools/run-engine-tests.sh 0 8`.
- One suite: `bash engine/<name>.test.sh` or `node --test engine/<name>.test.mjs`. Run `npm ci` first, as CI does.
- A shell suite starts with `set -euo pipefail` and then sources `test-env.sh`, which isolates `HOME` and `AGENT_HOME`.
- CI skips the suites listed in `tools/quarantine.txt` and prints each reason.

## Engine PR merges

Use `bash tools/merge-pr.sh <pr-number>` to merge an engine PR. It reads check buckets, allows pending checks except on gate files (`tools/merge-pr.sh`, `tools/pin-vecta.sh`, `tools/auto-pin.sh`, `engine/eval/`, `engine/mac-autopilot/bell.sh`, `bell-loop.sh`, `pin-lag.sh`, `engine/lib.d/main-red*.sh`, `engine/deploy-culprit.sh`, override name `gate-ci`), and refuses failed checks unless each failed check name is listed in `ZF_MERGE_OVERRIDE=<check-name>[,<check-name>]`. It also refuses a PR whose body lacks a `## prior-art` section with a source URL or a `no external prior art: <reason>` line; test-only PRs are exempt and `ZF_MERGE_OVERRIDE=prior-art` skips the check (logged). `ZF_ALLOW_FULL_GATE=1` retains the local full-gate path.

A merge also requires a green test receipt for the PR head SHA: `tools/test-receipt.sh <command...>` records each run's exit code under `<git common dir>/zf-test-receipts/`, the last line per command must be rc 0, and a PR touching only Markdown or with a green `ZF_ALLOW_FULL_GATE=1` result for that SHA needs no receipt.

## Agent skills

### Issue tracker

GitHub issues, through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical role names, unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context. See `docs/agents/domain.md`.

## Enforced rules

| Rule | Enforcer |
|---|---|
| Optional scheduler JSON reads go through `jqf_optional_file`; only a truly absent path is quiet, while an existing unreadable or malformed file still goes through `jqf`. | `engine/mac-autopilot/scheduler.d/core.sh`; `engine/mac-autopilot/intake-missing-state.test.sh` |
| `jqf` stays quiet only for the exact closed-consumer EPIPE (`writing output failed: Broken pipe`): a consumer that stops reading a jqf stream early (loop `break`/`return`, `head -n`) is not an error, while parse/runtime errors and other write failures (ENOSPC etc.) still log. | `engine/mac-autopilot/scheduler.d/core.sh`; `engine/mac-autopilot/jqf-epipe.test.sh` |
| A REQUEST-CHANGES whose `review-findings` block does not parse never reaches repair: the scheduler records `block=missing`, re-asks the same head once with the findings contract, and escalates to the supervisor if the re-ask fails too. | `engine/mac-autopilot/scheduler.d/harvest-workers.sh`; `engine/mac-autopilot/scheduler-gates.test.sh` |
| A `models.*` config key naming a model-policy-forbidden family is skipped at `pick()` (fixed key order, logged) and named in a config-load warning; it is never dispatched silently. | `engine/mac-autopilot/scheduler.d/models.sh`; `engine/mac-autopilot/scheduler-gates.test.sh` |
| Incident implement/repair reports are structurally checked before review; a failure may get one same-session read-only continuation, while the existing review-time gate remains authoritative. | `engine/mac-autopilot/scheduler.d/harvest-workers.sh`; `engine/mac-autopilot/scheduler.d/worker-command.sh`; `engine/mac-autopilot/incident-report-resume.test.sh` |
| Parent-relative defaults use the physical engine-version parent while `ZF_ENGINE_DIR` stays logical for live-link behavior. | `engine/config.sh`; `engine/config.test.sh` |
| Review and rereview must use a model family different from the unit/worker that wrote the head; Codex heads try GLM then policy-authorized Sonnet, GLM heads try Codex then Sonnet, and unavailable independent reviewers leave the stage pending with one bell alert. | `engine/lib.d/model-policy.sh`; `engine/mac-autopilot/scheduler.d/models.sh`; `engine/mac-autopilot/review-family.test.sh` |
| A repair with no findings and a confirmed unchanged-head `repair-no-push` spends no stop-loss or repair-cap round; requeueing an unchanged head with no actionable findings or a confirmed no-push repair sends it to rereview. | `engine/mac-autopilot/scheduler.d/stop-loss.sh`; `engine/mac-autopilot/scheduler.d/evals-arbiter.sh`; `engine/mac-autopilot/noop-repair-rounds.test.sh` |
| Triage routes already-delivered work to `awaiting-release` only through `conclude_merged_run` with a PR verified merged into main; `wontfix` remains for genuinely declined work. | `engine/run-triage.sh`; `engine/run-triage.test.sh` |
| Sonnet fallback commands retain `Read,Grep,Glob,Bash` and `dontAsk`, permit the configured test runners, and do not grant git push or GitHub write commands. | `engine/mac-autopilot/scheduler.sh`; `engine/mac-autopilot/scheduler.d/worker-command.sh`; `engine/mac-autopilot/worker-command.test.sh` |
| A Markdown-only change of at most 30 lines, outside `engine/vendor/`, may land in one command with `bash tools/quick-land.sh "<subject>"`; it refuses anything else and any HEAD other than origin/main. | `tools/quick-land.sh`; `engine/quick-land.test.sh` |
| When `delivery.revert_rate_30d_pct` or `flow.main_red_hours` goes UNHEALTHY on a fresh `node-health.json`, the scheduler logs a `reliability breach` line and changes no limit; each metric clears only when back to OK, so WARN holds, and a missing, stale or unreadable scorecard logs nothing. | `engine/mac-autopilot/scheduler.d/health-release.sh`; `engine/mac-autopilot/reliability-cap.test.sh` |
| Engine PRs use `tools/merge-pr.sh`; pending checks are allowed except on gate files (override name `gate-ci`), while failed checks require their exact names in `ZF_MERGE_OVERRIDE`; a non-test PR needs a `## prior-art` section (override name `prior-art`). | `tools/merge-pr.sh`; `engine/merge-pr-helper.test.sh` |
| Issue-pipeline advisor units receive the configured provider job directory through `systemd-run` environment forwarding. | `engine/issue-pipeline.sh`; `engine/issue-pipeline.test.sh` |
| A source file over 800 lines may shrink but not grow, and a new or newly oversized file must stay at or under 800: sizes are baselined in `tools/size-baseline.txt`, and raising a line there is the visible, deliberate exception. | `tools/size-ratchet.sh`; `engine/size-ratchet.test.sh` |
| Evals never gate a merge, but an eval regression on a delivered change (prompts, `AGENTS.md`, `engine/vendor/`) opens one revert PR through `open_deploy_revert_pr` kind `eval`, merged by `engine/sweep-merges.sh` once its checks are green; a change already reverted is never reverted again. | `engine/mac-autopilot/scheduler.d/evals-arbiter.sh`; `engine/deploy-culprit.sh`; `engine/sweep-merges.sh`; `engine/mac-autopilot/eval-regression-revert.test.sh` |
| A dispatched worker's write below the deployment checkout root is refused loudly from node and python (the `engine/worker-write-guard` preloads, set by `worker_write_guard_env`), with the supervisor scratch kept writable; the incident-rule lesson entry belongs to the unit's own checkout registry, and a reviewed diff without its lesson row is NOT_READY. | `engine/worker-write-guard/`; `engine/mac-autopilot/scheduler.d/worker-scope.sh`; `engine/mac-autopilot/scheduler.d/dispatch.sh`; `engine/incident-rule.sh`; `engine/worker-write-guard.test.sh` |
| Triage routes a `ready-for-human`/`needs-owner` verdict or an unconfirmed phase-3 L2 freshness block to the advisor only when `advisor_reason` is `irreversible`, `production-data` or `security`; missing or unrecognized values default to `none`, autonomy admission remains enforced, and each default logs its source. A pending advisor convergence pass advances a leftover `model_policy.step == advisor` to its `on_success` step once and logs the policy-step decision as `kept`, so the same episode is not routed on every tick. | `engine/run-triage.sh`; `engine/lib.d/triage-default.sh`; `engine/run-triage.test.sh`; `engine/run-triage-batch.sh`; `engine/lib.d/route-advisor.sh`; `engine/run-triage-batch.test.sh` |
