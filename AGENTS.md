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

## Enforced rules

| Rule | Enforcer |
|---|---|
| Optional scheduler JSON reads go through `jqf_optional_file`; only a truly absent path is quiet, while an existing unreadable or malformed file still goes through `jqf`. | `engine/mac-autopilot/scheduler.d/core.sh`; `engine/mac-autopilot/intake-missing-state.test.sh` |
| `jqf` stays quiet only for the exact closed-consumer EPIPE (`writing output failed: Broken pipe`): a consumer that stops reading a jqf stream early (loop `break`/`return`, `head -n`) is not an error, while parse/runtime errors and other write failures (ENOSPC etc.) still log. | `engine/mac-autopilot/scheduler.d/core.sh`; `engine/mac-autopilot/jqf-epipe.test.sh` |
| A REQUEST-CHANGES whose `review-findings` block does not parse never reaches repair: the scheduler records `block=missing`, re-asks the same head once with the findings contract, and escalates to the supervisor if the re-ask fails too. | `engine/mac-autopilot/scheduler.d/harvest-workers.sh`; `engine/mac-autopilot/scheduler-gates.test.sh` |
| A `models.*` config key naming a model-policy-forbidden family is skipped at `pick()` (fixed key order, logged) and named in a config-load warning; it is never dispatched silently. | `engine/mac-autopilot/scheduler.d/models.sh`; `engine/mac-autopilot/scheduler-gates.test.sh` |
| Parent-relative defaults use the physical engine-version parent while `ZF_ENGINE_DIR` stays logical for live-link behavior. | `engine/config.sh`; `engine/config.test.sh` |
| Review and rereview must use a model family different from the unit/worker that wrote the head; Codex heads try GLM then policy-authorized Sonnet, GLM heads try Codex then Sonnet, and unavailable independent reviewers leave the stage pending with one bell alert. | `engine/lib.d/model-policy.sh`; `engine/mac-autopilot/scheduler.d/models.sh`; `engine/mac-autopilot/review-family.test.sh` |
