# Retro lesson admission requires paired eval evidence
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** An automated-check candidate enters lessons only when `run-eval --compare` on distinct before and after labels reports no pass-to-fail regressions, no unpaired case runs and at least one paired frozen case; missing evidence remains an observation.
> **Do not:** admit an automated-check candidate from its event matcher alone; add a retro-specific evaluation harness
> **Rejected:** a second evaluation harness for retro candidates
> **Terms:** automated-check candidate, paired evaluation, frozen case, lesson fragment

The retro publisher uses the existing eval comparison and stores its labels and paired case IDs with the lesson fragment. The fold check requires this evidence alongside the source-event match and ten silent normal sessions. If the labels are missing, invalid, incomplete or regressing, the candidate stays an observation with the reason recorded.

## Consequences
- Retro admission reuses the eval case set and comparison format already owned by `engine/eval`.
- A candidate cannot be folded without a comparable before/after result.
- Eval labels must exist before retro publishes an automated-check candidate; the retro stage does not create a candidate patch or eval run.

Sources: [issue #1783](https://github.com/ZenoWangzy/zenoforge/issues/1783), [issue #1495](https://github.com/ZenoWangzy/zenoforge/issues/1495), [engine/eval/README.md](../../engine/eval/README.md)
