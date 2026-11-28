# PR CI supplies test receipts for engine work
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** Engine-prompted PR implement and repair workers add or update regression tests, run static checks, and push; same-head PR CI supplies test execution evidence and the merge receipt. Local receipts remain available for manual use but do not gate PR delivery.
> **Do not:** require local suite runs or local test receipts before an engine worker pushes or its PR merges
> **Rejected:** local suite runs as the default worker feedback loop and local receipts as a PR merge requirement
> **Terms:** test receipt, same-head PR CI, engine worker, `tools/test-receipt.sh`

Issue #1775 documented a worker spending more than two hours recording local receipts after its commits were complete. PR CI already runs the required suites against the pushed head, so it is the shared source of test evidence. The manual receipt tool stays available for human-run checks; direct-main work continues to use the post-land Pipeline.
