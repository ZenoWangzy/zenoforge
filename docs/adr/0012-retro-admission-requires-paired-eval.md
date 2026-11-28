# Retro lesson admission requires paired eval evidence
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** For each automated-check candidate id, retro runs the default eval case set with labels `retro-base-<id>` and `retro-cand-<id>`; only the candidate run receives that candidate's lesson fragment. `run-eval --compare` must report those exact labels, no unpaired cases and zero pass-to-fail regressions, or the candidate stays an observation.
> **Do not:** admit an automated-check candidate from its event matcher alone; add a retro-specific evaluation harness
> **Rejected:** a second evaluation harness for retro candidates
> **Terms:** automated-check candidate, paired evaluation, frozen case, lesson fragment

The retro publisher creates both labels through the existing eval runner, compares them, and stores their labels and paired case IDs with the lesson fragment. The baseline uses the live engine as-is; the candidate run adds only the candidate proposal to every task prompt. Both runs use the default case set without a case filter. The fold check requires this evidence alongside the source-event match and ten silent normal sessions. If labels do not identify the candidate, the engine or model policy differs, cases are unpaired, or the comparison has a regression, the candidate stays an observation with the reason recorded.

## Consequences
- Retro admission reuses the eval case set and comparison format already owned by `engine/eval`.
- A candidate cannot be folded without a comparable before/after result.
- Retro evals suppress fresh-agent issue routing so evidence collection has no issue-tracker writes.
- Retro creates the candidate-specific eval runs and does not rely on labels supplied by the model.

Sources: [issue #1783](https://github.com/ZenoWangzy/zenoforge/issues/1783), [issue #1495](https://github.com/ZenoWangzy/zenoforge/issues/1495), [engine/eval/README.md](../../engine/eval/README.md)
