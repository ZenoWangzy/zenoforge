# Repeated Log Shape Owner Ledger

This ledger classifies the five repeated shapes recorded by #390.

| Log shape | Owner | Disposition |
| --- | --- | --- |
| `Resource limits for this query exceeded.` | backend — `engine/lib.d/transport.sh` | Owner issue [#1569](https://github.com/ZenoWangzy/zenoforge/issues/1569) tracks the repeated GraphQL resource-limit failures. |
| `intake_admit_unlabeled_issues: could not admit ## to needs-triage; retrying next tick` | backend — `engine/lib.d/sweeps.sh` | Owner issue [#1570](https://github.com/ZenoWangzy/zenoforge/issues/1570) tracks repeated admission failures. |
| `hold_restore: ## has no exact durable hold record; issue left unchanged` | backend — `engine/lib.d/holds.sh` | Non-failure: restore fails closed when exact hold metadata is absent, avoiding an invented record or an issue-state change. |
| `hold_sweep: ## is ownerless; no exact durable hold record, leaving on-hold unchanged` | backend — `engine/lib.d/holds.sh` | Non-failure: the sweep preserves the on-hold state and records one keyed recovery action in the supervisor inbox. |
| `issue_transition: refused tracker parent ## -> active state needs-triage` | backend — `engine/lib.d/issue-state.sh` | Non-failure: tracker parents are containers, so the guard correctly refuses to admit one as active triage work. |
