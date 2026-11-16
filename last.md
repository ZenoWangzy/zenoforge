# Step 2 PR 2 rebase report

- Rebased branch `step2/pr2`, originally `85fbc50`, onto fetched `origin/main` at `d9e03a5`. Result: `f063cd0` (`Migrate policy readers to config root`). The rebase was completed with `git rebase --continue`; the amended commit used `--no-verify`. No push. This report is untracked and must not be committed.
- Main had advanced through #91 during verification. The rebase applied cleanly; the scheduler required-check reader uses main's existing `sched_config_file`, with target config and explicit environment overrides retained. The issue-pipeline exit-75 admission assertions passed.
- Engine diff against the tested main: 46 files changed, 588 insertions, 99 deletions. The product configuration work and its comparison evidence remain as recorded in the original handoff below; this rebase did not modify that clone.

## Final verification on `d9e03a5` / `f063cd0`

- Full `bash engine/lib.test.sh`: main exit 1 and branch exit 1, with precisely the same two failures on both:
  - `empty signal transcript is marked explicitly` (missing `transcript_empty=true`).
  - `signal state records transcript emptiness` (expected `true`, got `false`).
- `bash engine/issue-pipeline.test.sh`: main and branch both exit 1 with the same sole failure, `pipeline-system triage uses lightweight classification before model prompt`. The assertion searches for the former literal prompt path, which main moved behind config. Exit-75 admission assertions passed on both.
- `engine/config-root.test.sh`, `engine/matt-skills.test.sh`, and `engine/mac-autopilot/supervisor-arbiter.test.sh`: passed.
- All changed reader test suites below passed. Eval: 22 passed, 9 skipped, 0 failed. The previous focused model-policy library run passed 540 assertions; the final full runs include those assertions.
- `bash -n`, `node --check`, and Python compilation passed for changed files. `git diff --check origin/main...HEAD` passed.
- `bash ~/project/zenoforge-export/zf-scan.sh <git archive HEAD tree> $PWD/.git`: deny-list 0, gitleaks directory 0, gitleaks history 0.
- Logs, archive trees, and the detached main test worktree are under `.git/`.

Reader test suites passed:

- `engine/apply-model-policy-default-view.test.sh`
- `engine/check-rulings-model-source.test.sh`
- `engine/check-rulings.test.sh`
- `engine/ci-flake-classification.test.sh`
- `engine/eval/runner.test.mjs`
- `engine/focused-test-paths.test.mjs`
- `engine/generate-lesson-enforcers.test.mjs`
- `engine/hotfix/hf-merge.test.sh`
- `engine/landed-incident-guards.test.sh`
- `engine/lesson-fragments.test.sh`
- `engine/lesson-recurrence-ranking.test.mjs`
- `engine/mac-autopilot/dashboard-front.test.sh`
- `engine/mac-autopilot/node_health.test.sh`
- `engine/mac-autopilot/scheduler-gates.test.sh`
- `engine/night/incident-guard-audit.test.mjs`
- `engine/night/maintainer-health-mail.test.sh`
- `engine/pipeline-system-close-evidence.test.sh`
- `engine/risk-class.test.mjs`
- `engine/rule-lane.test.sh`

## Original handoff (historical)

The following describes the original commit and its original verification; current rebase and test results are above.

# Step 2 PR 2 handoff

## Commits

- Engine: `85fbc50` — `Migrate policy readers to config root`
- Product config: `bc7d7a5` — `Add pipeline policy configuration`
- One commit per clone; nothing was pushed.

## Readers switched

- Config accessor support: `engine/pack-dir.mjs` adds the Node `zfConfigFile` resolver.
- Model policy: `engine/lib.sh`, `engine/apply-model-policy-default.sh`, `engine/model-policy-fast-forward.sh`, and `engine/eval/run-eval.mjs`.
- Rulings and scheduling: `engine/check-rulings.sh`, `engine/lib.d/pipeline-system.sh`, `engine/lib.d/model-policy.sh`, and `engine/scheduling-policy.mjs`.
- Risk paths and rule files: `engine/risk-class.mjs` and `engine/rule-lane.sh`.
- Incident guards and related readers: `engine/lesson-guard-schema.mjs`, `engine/lesson-fragments.sh`, `engine/generate-lesson-enforcers.mjs`, `engine/lesson-recurrence-ranking.mjs`, `engine/night/incident-guard-audit.mjs`, `engine/night/maintainer-health-mail.sh`, `engine/land-direct-main.sh`, and `engine/lib.d/merge-lane.sh`.
- Required checks: `engine/lib.sh`, `engine/hotfix/hf-merge.sh`, and `engine/mac-autopilot/scheduler.sh`.
- CI known flakes: `engine/lib.d/ci-checks.sh`.
- Python config-root handling: `engine/mac-autopilot/config_paths.py`, `engine/mac-autopilot/node_health.py`, and `engine/mac-autopilot/gen_dashboard.py`.
- Focused-test mapping now recognizes the target config policy path in `engine/focused-test-paths.mjs`.

`ZF_PACK_REL` path construction remains only for the legacy Git paths needed by model-policy update/fast-forward behavior; callers replaced by `zf_config_file` no longer rely on it for reads.

## Product data copied

Each destination is in `.zenoforge/`; every `cmp` returned 0 against its pack source.

| Destination | Pack source | Compare |
| --- | --- | --- |
| `model-policy.default.json` | `scripts/agent/model-policy.default.json` | `cmp=0` |
| `state/ci-known-flakes.json` | `scripts/agent/state/ci-known-flakes.json` | `cmp=0` |
| `state/incident-guards.json` | `scripts/agent/state/incident-guards.json` | `cmp=0` |
| `state/risk-paths.json` | `scripts/agent/state/risk-paths.json` | `cmp=0` |
| `state/rule-files.json` | `scripts/agent/state/rule-files.json` | `cmp=0` |
| `state/rulings.json` | `scripts/agent/state/rulings.json` | `cmp=0` |
| `state/scheduling-policy.json` | `scripts/agent/state/scheduling-policy.json` | `cmp=0` |

All seven copied files are JSON data. No executable files were added to the product config clone.

## Verification

- The changed reader test suites passed, including the target `.zenoforge/` override cases.
- `node --test engine/eval/runner.test.mjs`: 18 passed, 0 failed, 9 skipped because product eval corpus/skills are not exported.
- `bash engine/landed-incident-guards.test.sh`: passed.
- `LIB_TEST_MODEL_POLICY_ONLY=1 bash engine/lib.test.sh`: passed, 540 assertions.
- Full `bash engine/lib.test.sh`: exits 1 on two later transcript assertions: `empty signal transcript is marked explicitly` and `signal state records transcript emptiness`. The same pair appeared in earlier full runs; the focused config/model-policy cutoff passes.
- `bash -n`, `node --check`, and Python compilation passed across all changed engine files; `git diff --check` passed.
- Export scan from an archive of engine `HEAD`: deny-list 0; gitleaks directory 0; gitleaks history 0.

## Diff stats

- Engine against main: 46 files changed, 590 insertions(+), 99 deletions(-).
- Product config against main: 7 files changed, 32,871 insertions(+), 0 deletions(-).
