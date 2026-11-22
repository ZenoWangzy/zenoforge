# Repair is capped and escalates; a failed fix run does not chain more fix runs
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** Repair work is bounded by a cap per unit; a unit at the cap gets no further repair run, and the issue-loop escalation ends in `conclude` rather than another retry.
> **Do not:** start a repair run for a unit already at the repair cap; send the same PR head to repair twice from the merge-tree sweep; add a retry step after `work_retry`
> **Rejected:** none stated
> **Terms:** repair cap, escalation steps, `work_retry`, `conclude`, rounds

The merge-tree sweep skips "units at the repair cap" and sends a head to repair once (`merge_sweep_head`). The issue loop's escalation is four steps in `engine/model-policy.default.json`: `work`, `advisor`, `work_retry` (one attempt) and `conclude`. A failed `work` step retries itself. Advisor success leads to `work_retry`, and a failed `work_retry` leads to `conclude`. The wrapper switches model after two failed rounds on the same ticket, counted in `rounds.log`.

`docs/architecture.md` does not state a numeric repair-cap value, so this ADR does not give one.

## Consequences
- A fix that keeps failing ends at `conclude` or at the cap, so the factory does not loop on one unit.
- Changing the cap value is a config change; changing the escalation order needs a new ADR.
- The one-retry rule on `work_retry` is the only retry after an advisor verdict.

Sources: docs/architecture.md#12-unit-loop (merge-tree sweep bullet), docs/architecture.md#33-issue-loop-escalation, docs/architecture.md#32-wrapper-workers
