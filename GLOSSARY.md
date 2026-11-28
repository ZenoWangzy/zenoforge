# Glossary

Factory terms, definitions only. Why a term works the way it does lives in the ADRs (`docs/adr/`); how it is built lives in `docs/architecture.md`.

- **ADR**: a short record of one hard-to-reverse decision in `docs/adr/`, with a Decision, Do-not and Terms header. Used in: `docs/adr/`.
- **Hotfix**: a unit carrying the `hotfix` label; the model picker tries the `<role>_hotfix` model first for it. Used in: `docs/architecture.md`.
- **Issue loop**: the loop that decides stage changes and labels for issues on each tick of `engine/run-tick.sh`; it never merges. Used in: `docs/architecture.md`, `docs/adr/0001-orchestrator-is-deterministic-code.md`.
- **Lane (direct-main lane)**: the path that squashes an approved PR into one `[skip ci]` commit and lands it on main without a merge button. Used in: `docs/architecture.md`.
- **Land-direct-main**: the script `engine/land-direct-main.sh`, which performs a lane landing. Used in: `docs/architecture.md`.
- **Pin**: the engine commit a deployment runs, prepared by `tools/pin-vecta.sh` in an isolated worktree. Used in: `tools/pin-vecta.sh`.
- **Quick-land**: the one-command path that lands an ordinary change on main with no PR, `tools/quick-land.sh`; code changes need prior art and at least one test. Used in: `AGENTS.md`.
- **Ratchet**: a count that may fall but never rise, enforced by a check, such as file size above the cap or the number of code comments. Used in: `tools/size-ratchet.sh`, `docs/adr/0007-file-size-only-shrinks-above-cap.md`.
- **Receipt**: proof that tests passed for one exact PR head SHA; PR CI supplies merge receipts, while `tools/test-receipt.sh` records manual runs. Used in: `AGENTS.md`.
- **Release train**: the scheduled step that builds and ships what has merged since the last release. Used in: `docs/design/DISTRIBUTED.md`.
- **Station (工位)**: a scheduler pass with its own lock and its own timer, such as CI admission, merge or harvest. Used in: `docs/architecture.md`.
- **Tick**: one run of a loop: it decides what happens next, starts detached workers and exits. Used in: `docs/adr/0001-orchestrator-is-deterministic-code.md`.
- **Unit**: one work item the unit loop runs (implement, review, self-fix, land), recorded in the unit ledger. Used in: `docs/architecture.md`.
- **Unit loop**: the loop that runs workers and owns the serial merge queue. Used in: `docs/architecture.md`.
- **Worker**: a detached process a tick starts; agent CLIs run only inside workers, never inside a tick. Used in: `docs/adr/0001-orchestrator-is-deterministic-code.md`.
