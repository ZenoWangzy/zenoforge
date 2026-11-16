Refs queue row 190

## Summary

- The implement route checks its preferred family even when that family's configured share is zero. A positive-share alternate is considered only when the preferred family has no eligible independent reviewer.
- Any provider change records `reviewer-fallback-<provider>`, and a route refusal includes the reviewer refusal reason.
- Codex route checks read the recovery latch and quota state without invoking the recovery probe. The share-off Claude path does not emit an alert for the Claude family.

## Review round 2

Point 2: the share-based move for an already-sticky ZCode unit was outside row 190's intent. A sticky ZCode unit remains the selected route when it has an eligible reviewer, even at zero share. The share-based eligibility loop considers a positive-share alternate only after the preferred reviewer is unavailable.

## Trace and live evidence

- `engine/lib.d/model-policy.sh:843` routes Codex reviewer availability through `codex_quota_exhausted`. With the recovery latch present, `engine/lib.d/codex-budget.sh:550-555` can invoke the recovery probe; its default timeout is 2700 seconds (`engine/lib.d/codex-budget.sh:637`) and launch is at `engine/lib.d/codex-budget.sh:667`. The route-specific check in `engine/mac-autopilot/scheduler.d/models.sh:272` reads Codex state without calling that wrapper.
- Live `units.json` read: 155 units total, including 4 `implement-pending`. The named `scheduler.log` and `scheduler.log.1` reads had no route-refusal or route-alert entries. The default Codex recovery latch was absent at read time.
- Final head: `c1e0db4a5a52c9601b4d3d1974c8cbf3ae9d8606`.

## Tests

- `zf-batch timeout 1500 bash tools/test-receipt.sh bash engine/mac-autopilot/codex-week-fallback.test.sh` — `r=0` at the final head.
- The sticky-ZCode reviewer-fallback assertion is red on `origin/main`, whose picker dispatches the sticky provider without checking reviewer eligibility.
- `node engine/focused-test-paths.mjs`, `engine/mac-autopilot/scheduler.test.sh`, and `engine/mac-autopilot/scheduler-gates.test.sh` — covered by PR CI.

## prior-art

no external prior art: this uses the engine's existing reviewer identities and Codex recovery state.

## Merge Danger

**Door:** Two-way. Route selection and recovery-probe admission can be reverted.

**Blast Radius:** dispatch.
