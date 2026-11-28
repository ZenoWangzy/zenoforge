# Architecture decision records

ADRs record surprising, hard-to-reverse decisions; read the Do not lines before changing the area.

| ADR | Decision | Status | Terms |
|---|---|---|---|
| [0001](0001-orchestrator-is-deterministic-code.md) | The orchestrator is deterministic code, not an agent. | accepted | issue loop, unit loop, tick, detached worker, stage chain |
| [0002](0002-issue-loop-never-merges.md) | The issue loop never merges; only the unit loop's merge queue merges. | accepted | issue loop, unit loop, merge queue, merge lane, `--match-head-commit` |
| [0003](0003-matt-skills-vendored-byte-identical.md) | Matt skills are vendored byte-identical at a pinned commit and never hand-edited. | accepted | Matt skills, vendored, pinned commit, `.agents/skills/`, `tools/sync-matt-skills.sh` |
| [0004](0004-human-exits-are-gaps.md) | Human exits (ready-for-human, needs-info) are gaps to remove, not features. | accepted | ready-for-human, needs-info, needs-owner, needs-advisor, transient model verdict |
| [0005](0005-repair-is-capped.md) | Repair is capped and escalates; a failed fix run does not chain more fix runs. | accepted | repair cap, escalation steps, `work_retry`, `conclude`, rounds |
| [0006](0006-review-uses-different-provider.md) | Review runs on a different provider from the implementer when one is available. | accepted | cross-provider review, review role, implementer, `review_provider_fallback`, availability |
| [0007](0007-file-size-only-shrinks-above-cap.md) | File size only shrinks above the cap. | accepted | enforced rules, size ratchet, cap, shrink, `tools/size-ratchet.sh` |
| [0008](0008-suppression-directives-need-adr-backed-exceptions.md) | Suppression directives need ADR-backed exceptions. | accepted | suppression directive, suppression ratchet, ADR-backed exception |
| [0009](0009-skip-ci-must-not-hide-tested-files.md) | Skip-CI commits must not hide tested files. | accepted | skip-CI commit, test reference, direct-main admission |
| [0010](0010-clean-host-ci-uses-init-dry-run.md) | Clean-host CI uses init dry-run. | accepted | clean-host install, `init --dry-run`, doctor, GitHub Actions |
| [0011](0011-retro-lessons-without-measured-gain-are-withdrawn.md) | Retro lessons without measured gain are withdrawn. | accepted | admitted lesson, engine-version window, withdrawal event |
| [0012](0012-engine-pr-ci-test-receipts.md) | PR CI supplies test receipts for engine work. | accepted | test receipt, same-head PR CI, engine worker, `tools/test-receipt.sh` |
