# Zenoforge

Goal: an unattended, fully automatic, self-healing software factory. No human in the loop is the target, so do not propose human-intervention metrics or new hand-offs to a person. The `ready-for-human` and `needs-info` exits are gaps to remove, not features to keep.

A self-hosted software factory: coding agents take GitHub issues through triage, recut, implement, review, repair and merge. The engine is Bash, Node and Python under `engine/`; `docs/architecture.md` maps it.

## Method: Matt skills

Work here follows Matt Pocock's skills, vendored in `.agents/skills/` and entered through `/ask-matt`. Start there when unsure which one fits.

- A new idea or an unclear request: `/grill-with-docs`, then `/to-spec`, `/to-tickets`, and `/implement` per ticket, which drives `/tdd` one red-green slice at a time.
- A bug, flake or regression: `/diagnosing-bugs`. A command that goes red on the bug comes before the fix.
- A change ready for review: `/code-review` against a fixed point (Standards and Spec).
- A pull request body: `/pr`.
- A raw issue nobody has shaped: `/triage`. Tickets from `/to-tickets` are already agent-ready.

The engine's own stages use the same skills (`docs/architecture.md`, "Method: Matt skills"). The skill files are MIT and byte-identical to upstream: change the pin with `tools/sync-matt-skills.sh <commit>`, never by hand (`THIRD_PARTY_NOTICES.md`).

## Public repo

This repository is public. Keep customer names, home-directory paths, hostnames, private repository names and credentials out of code, tests, docs, commit messages and PR text. Call the pipeline Zenoforge was extracted from "the origin deployment".

## Tests

- All suites: `bash tools/run-engine-tests.sh`, or one shard: `bash tools/run-engine-tests.sh 0 8`.
- One suite: `bash engine/<name>.test.sh` or `node --test engine/<name>.test.mjs`. Run `npm ci` first, as CI does.
- A shell suite starts with `set -euo pipefail` and then sources `test-env.sh`, which isolates `HOME` and `AGENT_HOME`.
- CI skips the suites listed in `tools/quarantine.txt` and prints each reason.

## Engine PR merges

Use `bash tools/merge-pr.sh <pr-number>` to merge an engine PR. It reads check buckets, allows pending checks except on gate files (`tools/merge-pr.sh`, `tools/pin-vecta.sh`, `tools/auto-pin.sh`, `engine/eval/`, `engine/mac-autopilot/bell.sh`, `bell-loop.sh`, `pin-lag.sh`, `engine/lib.d/main-red*.sh`, `engine/deploy-culprit.sh`, override name `gate-ci`), and refuses failed checks unless each failed check name is listed in `ZF_MERGE_OVERRIDE=<check-name>[,<check-name>]`. It also refuses a PR whose body lacks a `## prior-art` section with a source URL or a `no external prior art: <reason>` line; test-only PRs are exempt and `ZF_MERGE_OVERRIDE=prior-art` skips the check (logged). It also refuses a PR whose change to an overridden engine file would not three-way merge into the target's pack copy, since `tools/pin-vecta.sh` would refuse every pin after it (override name `override-merge`; an unreadable target refuses). `ZF_ALLOW_FULL_GATE=1` retains the local full-gate path.

A merge requires a green test receipt for the exact PR head SHA: `tools/test-receipt.sh <command...>` records each run's exit code under `<git common dir>/zf-test-receipts/`, and the last line per command must be rc 0. With no nonempty local receipt, `statusCheckRollup` may count only when `headRefOid` equals the PR head, all CheckRuns are completed with conclusion `SUCCESS`, `SKIPPED` or `NEUTRAL`, StatusContexts are `SUCCESS`, and all eight `suites (N)` shards plus `cli` are present as CheckRuns with a nonempty `workflowName`; required jobs must conclude `SUCCESS`, and the CI receipt path is disabled for PRs touching `.github/`. A red local full-suite result or a nonempty local receipt with a failed last run still refuses. Markdown-only PRs and a green `ZF_ALLOW_FULL_GATE=1` result for that SHA need no additional receipt.

## Agent skills

### Issue tracker

GitHub issues, through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical role names, unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context. See `docs/agents/domain.md`. Before designing anything that runs per worker, per tick or per PR, read `docs/design/AGENT-SCALE-PRINCIPLES.md`.

## Enforced rules

Code and tests enforce the engine's gates. `docs/enforced-rules.md` lists each rule beside its enforcer: read the rows for the files you touch before you change an enforcer, and add a row there when you add an enforced rule. Every change meets these four:

- A pipeline unit never changes the protected paths in `engine/state/rule-files.json`.
- A source file over 800 lines may shrink but not grow, and a new file stays at or under 800 (`tools/size-ratchet.sh`).
- A Markdown-only change of at most 30 lines may land with `bash tools/quick-land.sh "<subject>"`.
- `pnpm`, `npm` and `corepack` installs are refused while a `node_modules` in the work tree is a symlink.
