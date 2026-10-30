# Hotfix lane

- `hf-start.sh <issue> <slug> <brief-file>` creates a locked worktree and starts a priority worker with the delivery footer.
- `prepush-gates.sh [commit]` runs the gates listed one per line in the target repo's `.zenoforge/prepush-gates` against the candidate commit; the pre-push hook blocks hotfix pushes on failure.
- `hf-pr.sh [gh pr create options]` requires a hotfix branch and creates a labeled PR.
- `hf-merge.sh <pr-number>` requires the label, 验收用户 acceptance evidence for the current PR head, every check in `required-pr-checks.json`, and the `Hotfix acceptance evidence` check before using the hotfix squash subject.
- `hf-install-gate.sh <pr-number>` requires green main CI containing the merge before an install can proceed; refusal exits 3.
- `hf-stale.sh` exits 1 and lists open hotfix PRs with no push for `HF_STALE_MINUTES` (default 30); the supervisor alert tick runs it so stalled hotfix work cannot sit unowned.
- `hf-source-check.sh <file>...` refuses any file that is not a blob in origin/main or an open hotfix PR head (no anonymous live code).

Every hotfix PR body must carry exactly one structured acceptance record:

```html
<!-- zf-hotfix-acceptance:start -->
{
  "schema": "example.hotfix-acceptance/v1",
  "status": "pending",
  "accepted_by": "",
  "accepted_head_sha": "",
  "evidence": ""
}
<!-- zf-hotfix-acceptance:end -->
```

After 验收用户 accepts the production hotfix, set `status` to `passed`, `accepted_by` to `验收用户`, `accepted_head_sha` to the exact current PR head SHA, and `evidence` to the acceptance evidence. The check runs again when the PR body is edited and rejects a record for an older head. `hf-merge.sh` revalidates the record and check results at merge time. Before an install, `hf-install-gate.sh` requires the merged SHA (or a later main SHA containing it) to have a successful `Postsubmit validate` job.
