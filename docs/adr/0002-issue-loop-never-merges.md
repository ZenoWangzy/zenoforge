# The issue loop never merges; only the unit loop's merge queue merges
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** The issue loop (`engine/run-tick.sh`, `engine/issue-pipeline.sh`) decides stage changes and labels; merges happen only in the unit loop's serial merge queue, pinned to the reviewed head SHA.
> **Do not:** add a direct PR-merge call (`gh pr merge` or a merge REST call) to an issue-loop file; add an allowlist entry to `engine/issue-loop-merge-boundary.test.sh` without a reason and an exact count; merge from the issue loop outside the merge lane
> **Rejected:** none stated
> **Terms:** issue loop, unit loop, merge queue, merge lane, `--match-head-commit`

The README and the architecture page both say the issue loop decides stage changes and never merges. The unit loop runs the workers and owns the serial merge queue. Each merge is `gh pr merge <pr> --squash --match-head-commit <approved-sha>`, so GitHub refuses it if the head moved after the approving review. After a merge, the scheduler checks the exact merged SHA on main.

Two paths are documented exceptions, and both are on record. `pipeline_system_hand_external_pr_conclusion` in `engine/issue-pipeline.sh` squash-merges a green factory-repo PR for a hand-owned issue. `supervisor_hold_sweep` reaches `merge_agent_pr`, and that call goes through the merge lane. The boundary test fails on any other direct merge call in the issue-loop files.

## Consequences
- A new merge path goes through the merge lane or it fails the boundary test.
- The two exceptions stay listed, and their counts are checked.
- Head pinning makes a merge refuse a PR whose head changed after review.

Sources: README.md#how-it-works, docs/architecture.md#13-how-the-loops-meet, docs/architecture.md#6-merging, docs/architecture.md#1-the-two-loops
