# Cutover gate report

Commit: `53a655c` (`Compare cutover suites with live baseline`), committed with `--no-verify`. No push.

The gate now records PASS/FAIL per suite from a copied live version, compares each candidate result with that baseline, applies `tools/quarantine.txt`, and rejects missing or malformed baseline entries. It runs a copied host-ops runner and compares its individual results with its `BASELINE.tsv`. Undefined-function exceptions are scoped to a function and caller and require a reason. The checked-in allow-list contains only the retired reviewed-PR train calls. Usage is in `scripts/cutover-gate.md`.

## Real comparison

Not run. Both-green, both-red, newly-red and newly-green counts are **unknown**; the newly-red list is **unknown**. The previous report's 179 passing and 107 failing suites were candidate-only and cannot establish these counts.

The requested unmodified `engine-sync.sh --build main HEAD` reads `engine.env.flip` and calls `rm`; both conflict with the explicit instructions for this session. Engine suite scripts also call `rm` and some read `.env` fixtures. The host-ops runner writes to its own directory unless copied. An altered builder or altered test execution would not establish the requested results for the actual build and suite list, so no substitute numbers are presented. The live version and host-ops tree were not modified. The local `main` resolved to `e63d8e4dc56d9e1ba20bd272bfa7c03acfb4dc09` and the pack checkout HEAD to `9d4caeca228c169a21237d193d46c3bcdc2d01d6`; neither establishes a fresh build.

## Undefined functions

Production definitions were searched across the engine, pack checkout, and the product repository's `origin/main`, excluding `*.env`. The product `origin/main` does not contain the examined `scripts/agent/night/hand-exit-handoff.sh`, `_untracked/prs/drive-train.sh`, or `_untracked/prs/queue-lib.sh` paths. The engine's `bin/queue-lib.sh` is absent. The source says the legacy drive-train queue is dead; it is a reviewed-PR train, distinct from the separate release-leg poller.

| Function | Calls in engine | Definition found | Classification |
| --- | --- | --- | --- |
| `cancel_runs` | `bin/drive-train.sh:15,30` | No | Dead caller: retired reviewed-PR train |
| `hand_agent_role_for_identity` | `night/hand-exit-handoff.sh:307,443,525` | Test stubs only: `night/hand-handoff-chain.test.sh:52`, `night/hand-crash-recovery.test.sh:29` | Real bug: active handoff code calls a helper with no production definition; errors are suppressed |
| `lower_pending` | `bin/drive-train.sh:66` | No | Dead caller: retired reviewed-PR train |
| `publish_train` | `bin/drive-train.sh:30` | No | Dead caller: retired reviewed-PR train |
| `red_train` | `bin/drive-train.sh:43,47,53` | No | Dead caller: retired reviewed-PR train |
| `refresh_runs` | `bin/drive-train.sh:49` | No | Dead caller: retired reviewed-PR train |
| `set_state` | `bin/drive-train.sh:15,29,30,41,65,72,80` | No | Dead caller: retired reviewed-PR train |
| `train_expected_runs` | `bin/drive-train.sh:31` | No | Dead caller: retired reviewed-PR train |
| `train_runs` | `bin/drive-train.sh:51` | No | Dead caller: retired reviewed-PR train |

No production definition was found in a file demonstrably dropped by the build. The missing train library prevents proving where its historical definitions lived.

## Verification

- `bash scripts/cutover-gate.test.sh` — passed, including baseline green to candidate red (exit 1), red in both (exit 0), host-ops baseline comparison, and caller-specific allow-list tests.
- `shellcheck scripts/cutover-gate.sh scripts/cutover-gate.test.sh` — passed.
- `bash -n scripts/cutover-gate.sh scripts/cutover-gate.test.sh` — passed.
- `git diff --check` and staged diff check — passed.
- Real baseline, fresh candidate build and real host-ops test run — not run for the restrictions above.
