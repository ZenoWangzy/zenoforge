# Hotfix lane

The lane ships hotfixes as images: PR → merge → `hf-release.sh` rebuilds only the affected service image under its immutable merge-SHA tag → deploy that one service → real-user acceptance (验收用户 WebUI or 维护者 WeChat). Never fix production by editing container files or docker cp; the image lane (landed in b04717a90) replaced container patching.

- `hf-start.sh <issue> <slug> <brief-file>` creates a locked worktree and starts a priority worker with the delivery footer.
- `prepush-gates.sh [commit]` runs the PR gates against the candidate commit; the pre-push hook blocks hotfix pushes on failure.
- `hf-pr.sh [gh pr create options]` requires a hotfix branch and creates a labeled PR.
- `hf-merge.sh [--image-lane <anchor-issue>] <pr-number>` requires the label and every check in `required-pr-checks.json` before using the hotfix squash subject. Plain `hf-merge.sh` (the container-patch fallback) also requires 验收用户 acceptance evidence for the current PR head and the `Hotfix acceptance evidence` check. `--image-lane` moves that gate to after the deploy: no pre-merge acceptance record, and the merged SHA is handed to `hf-release.sh` immediately in a detached `zf-hf-release-<pr>` unit, so an image-lane PR cannot sit merged but undeployed.
- `hf-install-gate.sh <pr-number>` requires green main CI containing the merge. It applies to the image lane (`hf-release.sh`) only: `hf-apply-dist.sh` and `hf-apply-hook.sh` installs go live from the reviewed fix head and never wait for merge or CI. Refusal exits 3.
- `hf-accept.sh` runs the configured acceptance command or the legacy pack fallback. For `HF_ACCEPT_SET=demo`, set `HF_HARNESS_SHA` to the harness repository's full HEAD SHA. Neither the selected repository nor an explicitly set `VECTA_REPO_DIR` may resolve to the live `$AGENT_HOME/checkout`, including through symlinks. For any other acceptance set, a supplied `HF_HARNESS_SHA` must also match HEAD. Refusals exit 3 and are recorded as `<set>-refused`, so they do not count as demo runs in `hf-demo-gate.sh`.
- `hf-stale.sh` exits 1 and lists open hotfix PRs with no push for `HF_STALE_MINUTES` (default 30); the supervisor alert tick runs it so stalled hotfix work cannot sit unowned.
- `hf-source-check.sh <file>...` refuses any file that is not a blob in origin/main or an open hotfix PR head (no anonymous live code).

Every hotfix PR body must carry exactly one structured acceptance record:

```html
<!-- vecta-hotfix-acceptance:start -->
{
  "schema": "example.hotfix-acceptance/v1",
  "status": "pending",
  "accepted_by": "",
  "accepted_head_sha": "",
  "evidence": ""
}
<!-- vecta-hotfix-acceptance:end -->
```

After 验收用户 accepts the production hotfix, set `status` to `passed`, `accepted_by` to `验收用户`, `accepted_head_sha` to the exact current PR head SHA, and `evidence` to the acceptance evidence. The check runs again when the PR body is edited and rejects a record for an older head. `hf-merge.sh` revalidates the record and check results at merge time (plain mode, the container-patch fallback); in `--image-lane` mode 验收用户 accepts after the deploy and the record is completed then, while an acceptance that could not run for environment reasons leaves the hotfix 未验收 (see `hf-release.sh`). Before an install, `hf-install-gate.sh` requires the merged SHA (or a later main SHA containing it) to have a successful `Postsubmit validate` job.
- `hf-release.sh <pr-number> <anchor-issue>` is that image lane: it refuses to start while any `zf-release-*` unit is active (head is the sole release scheduler; the shared `vecta-release-batch` unit and run-release's own lock also refuse a race), waits for `hf-install-gate.sh` (green main CI containing the merge; `HF_RELEASE_GATE_WAIT_SECONDS`, default 2 h), then starts `run-release.sh` at the PR's merge SHA in the `vecta-release-batch` unit. The existing path rebuilds only the images `changed-images.mjs` maps from the diff, deploys them by SHA, captures drift, and runs acceptance. The head gets one supervisor-inbox line on start and one on end; if post-deploy acceptance could not run for environment reasons (ledger signature `env:production-e2e:runner`), the hotfix stays 未验收 and the hotfix owner (zf-57) is told on the first occurrence, without waiting for a repeat.

- `hf-brief-lint.sh <brief>` runs inside `hf-start.sh`: a worker brief needs 12+ lines, a Done-when line, file paths and a test command.
- `hf-worker-stuck.sh` lists live workers past `HF_WORKER_BUDGET_MIN` (45) with no commit and no change; `hf-stale.sh` runs it and, when the pack provides it, `hf-infra-probe.sh` (every 30 min) on the alert tick.
