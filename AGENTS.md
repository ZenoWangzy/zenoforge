# Zenoforge

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
- One suite: `bash engine/<name>.test.sh` or `node --test engine/<name>.test.mjs`. Run `npm install --no-save @typesafe-ai/sdk@0.7.0` first, as CI does.
- A shell suite starts with `set -euo pipefail` and then sources `test-env.sh`, which isolates `HOME` and `AGENT_HOME`.
- CI skips the suites listed in `tools/quarantine.txt` and prints each reason.

## Agent skills

### Issue tracker

GitHub issues, through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical role names, unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context. See `docs/agents/domain.md`.
