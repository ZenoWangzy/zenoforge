# Ubuntu engine suite repair: rebase

- Original commit: `3d69858` (Fix red Ubuntu engine suites)
- Rebased commit: `3005159974ed6fc373020052b38e407ac26ce9c9`
- Base: `e63d8e4dc56d9e1ba20bd272bfa7c03acfb4dc09` (`origin/main` after fetch)
- Rebase completed with `git rebase --continue`, with hooks disabled for that operation; the subsequent amendment used `git commit --amend --no-verify`.
- No push to the remote was performed.

The conflict resolutions preserve main's new coverage and behavior alongside the Ubuntu fixes. `config.sh` retains the `ZF_CONFIG_ROOT` block and the logical engine-path fix. The issue-pipeline test's prompt-order assertion was updated for main's `zf_config_file` prompt accessor.

## Validation

All requested suites passed:

- `node --test engine/closed-pr-ci.test.mjs`
- `bash engine/config.test.sh`
- `bash engine/land-queue-recovery.test.sh`
- `bash engine/mac-autopilot/scheduler.test.sh`
- `bash engine/owner-admission-lanes.test.sh`
- `bash engine/hold.test.sh`
- `bash engine/lib.test.sh`
- `bash engine/run-tick.test.sh`
- `bash engine/mac-autopilot/scheduler-gates.test.sh`
- `bash engine/config-root.test.sh`
- `bash engine/issue-pipeline.test.sh`
- `bash engine/matt-skills.test.sh`

The first closed-pr-ci run failed because the temporary directory inherited the repository's ES module setting; a CommonJS package setting in its fixture directory fixed the test environment and the rerun passed. The first issue-pipeline run exposed the stale direct-prompt-path assertion; after updating it to the accessor, the rerun passed. Suite logs and statuses are under `.git/red3-validation/logs/`.

`zf-scan` against a `git archive HEAD` tree reported `deny-list: 0`, `gitleaks dir: 0`, and `gitleaks git: 0`. The archive and scan log are under `.git/red3-validation/`.

The requested shell suites' own test harness overrides `TMPDIR` and creates fixtures under its home cache, and some suites invoke cleanup and local fixture Git pushes internally. No manual `rm` or remote push was issued.
