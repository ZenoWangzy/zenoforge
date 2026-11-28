# Zenoforge

Goal: an unattended, fully automatic, self-healing software factory. No human in the loop is the target, so do not propose human-intervention metrics or new hand-offs to a person. The `ready-for-human` and `needs-info` exits are gaps to remove, not features to keep.

A self-hosted software factory: coding agents take GitHub issues through triage, recut, implement, review, repair and merge. The engine is Bash, Node and Python under `engine/`; `docs/architecture.md` maps it.

Factory terms are defined in `GLOSSARY.md`.
Factory practices and their enforcement are indexed in `docs/agents/practices.md`.

## Method: Matt skills

Work here follows Matt Pocock's skills, vendored in `.agents/skills/`, with pstack (`engine/vendor/pstack`) and ub-mode (`engine/vendor/ub-mode`). `/ask-zeno` routes over all of them: start there. `/ask-matt` is the detail map of the Matt family.

- A new idea or an unclear request: `/grill-with-docs`, then `/to-spec`, `/to-tickets`, and `/implement` per ticket, which drives `/tdd` one red-green slice at a time.
- A bug, flake or regression: `/diagnosing-bugs`. A command that goes red on the bug comes before the fix.
- A change ready for review: `/code-review` against a fixed point (Standards and Spec).
- A pull request body: `/pr`.
- A problem you cannot name, one that came back, or a design with no precedent here: `/solve`, which finds the known problem and the existing solution first.
- A raw issue nobody has shaped: `/triage`. Tickets from `/to-tickets` are already agent-ready.

The engine's own stages use the same skills (`docs/architecture.md`, "Method: Matt skills"). The skill files are MIT and byte-identical to upstream: change the pin with `tools/sync-matt-skills.sh <commit>`, never by hand (`THIRD_PARTY_NOTICES.md`).

## Other Repos

- `mattpocock/skills` (source of the vendored Matt skills): `../mattpocock-skills`. Clone from `https://github.com/mattpocock/skills` if missing.
- `cursor/plugins` (source of pstack): `../cursor-plugins`. Clone from `https://github.com/cursor/plugins` if missing.
- `unclebob/ub-mode` (source of ub-mode): `../ub-mode`. Clone from `https://github.com/unclebob/ub-mode` if missing.

## Public repo

This repository is public. `engine/public-text-guard.mjs` checks tracked text, changed file paths, commit messages and PR bodies for home-directory paths and configured private terms. CI reads newline-separated terms from the `ZF_PUBLIC_TEXT_DENYLIST` secret; local land reads `zenoforge/public-text-denylist` under `XDG_CONFIG_HOME` or `ZF_PUBLIC_TEXT_DENYLIST_FILE`. Keep customer names, home-directory paths, hostnames, private repository names and credentials out of code, tests, docs, commit messages and PR text. Call the pipeline Zenoforge was extracted from "the origin deployment".

## Tests

- Engine-prompted PR-lane implement and repair workers add or update tests but do not run test files or suites locally, use a test runner, or record local test receipts. They may run `bash -n`, `node --check`, and static lint/typecheck scans, then push; PR CI runs the tests and provides the receipt. Direct-main workers follow their lane-specific no-test rule, and the post-land pipeline runs the tests.
- For manual verification, all suites: `bash tools/run-engine-tests.sh`, or one shard: `bash tools/run-engine-tests.sh 0 8`.
- For manual verification, one suite: `bash engine/<name>.test.sh` or `node --test engine/<name>.test.mjs`. Run `npm ci` first, as CI does.
- A shell suite starts with `set -euo pipefail` and then sources `test-env.sh`, which isolates `HOME` and `AGENT_HOME`.
- CI skips the suites listed in `tools/quarantine.txt` and prints each reason.

## Engine PR merges

Use `bash tools/merge-pr.sh <pr-number>` to merge an engine PR. It requires same-head PR CI test checks as the receipt for non-Markdown PRs, reads check buckets, allows pending checks except on gate files (`tools/merge-pr.sh`, `tools/merge-pr-bootstrap.sh`, `tools/pin-vecta.sh`, `tools/auto-pin.sh`, `engine/eval/`, `engine/mac-autopilot/bell.sh`, `bell-loop.sh`, `pin-lag.sh`, `engine/lib.d/main-red*.sh`, `engine/deploy-culprit.sh`, override name `gate-ci`), and refuses failed checks unless each failed check name is listed in `ZF_MERGE_OVERRIDE=<check-name>[,<check-name>]`. It also refuses a PR whose body lacks a `## prior-art` section with a source URL or a `no external prior art: <reason>` line; test-only PRs are exempt and `ZF_MERGE_OVERRIDE=prior-art` skips the check (logged). It also refuses a PR whose change to an overridden engine file would not three-way merge into the target's pack copy, since `tools/pin-vecta.sh` would refuse every pin after it (override name `override-merge`; an unreadable target refuses).

PR CI is the test receipt for the exact PR head SHA. The merge gate counts it only when `headRefOid` equals the PR head, all CheckRuns are completed with conclusion `SUCCESS`, `SKIPPED` or `NEUTRAL`, StatusContexts are `SUCCESS`, and all eight `suites (N)` shards plus `cli` are present as CheckRuns with a nonempty `workflowName`; required jobs must conclude `SUCCESS`. Local receipts do not gate PR merges. `tools/test-receipt.sh <command...>` remains available for manual runs and records each command's exit code under `<git common dir>/zf-test-receipts/`.

## Agent skills

### Issue tracker

GitHub issues, through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical role names, unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context. See `docs/agents/domain.md`. Before designing anything that runs per worker, per tick or per PR, read `docs/design/AGENT-SCALE-PRINCIPLES.md`.

## Enforced rules

Code and tests enforce the engine's gates. `docs/enforced-rules.md` lists each rule beside its enforcer: read the rows for the files you touch before you change an enforcer, and add a row there when you add an enforced rule. Every change meets these five:

- Lesson lints default to `mode: 'observe'`; a new lesson lint moves to `enforce` only in a change that cites its ledger counts.
- A pipeline unit never changes the protected paths in `engine/state/rule-files.json`.
- A source file over 800 lines may shrink but not grow, and a new file stays at or under 800 (`tools/size-ratchet.sh`).
- Manual quick-land workflow for human-operated changes: `bash tools/quick-land.sh --test "<cmd>" --prior-art "<URL or no external prior art: reason>" "<subject>"` (repeat `--test`). Code needs `--prior-art` and at least one `--test`; a Markdown-only change needs neither. Engine-prompted workers use their assigned delivery lane and do not run tests locally. Gate files, rule files and VectA override files still go through a PR.
- `pnpm`, `npm` and `corepack` installs are refused while a `node_modules` in the work tree is a symlink.
- No code comments: tools/comment-ratchet.mjs fails a change that adds one; run the delete-comment skill (.agents/skills/delete-comment) to remove them.
