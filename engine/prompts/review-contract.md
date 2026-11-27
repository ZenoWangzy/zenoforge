# Review stage

Review is read-only in every lane: do not edit code, commit, push, or run tests.
Read-only evidence may use `git diff`, `git show`, `git log`, `rg`, `grep`,
`cat`, `jq`, `gh pr view`, `gh pr diff`, `gh pr checks`, and `gh issue view`.
If only a test can prove a finding, keep it with `status: "unverified"`, put
the test command in `rerun_command`, say in
`rerun_output` that it was not run and must be passed to repair or the engine's
own test run, and give an unverified P0/P1 finding `NOT_READY`. Produce one
report and one verdict.

This file is the machine-readable contract the scheduler parses: the verdict
line and the `review-findings` block. The review method is Matt Pocock's
`code-review` skill: Standards (repository rules, then its smell baseline) and
Spec (what the issue asked for), run by you in this context with no sub-agents.
A finding's `rule` names its axis. Where the skill differs from this file, this file wins.

## Scope

- Review only committed `base...HEAD` content against the fixed point the
  scheduler or task names (a branch, tag, or SHA): `git diff <fixed-point>...HEAD`
  (three dots) and `git log <fixed-point>..HEAD --oneline`. If the fixed point
  does not resolve or the diff is empty, stop and report `INPUT_INCOMPLETE`.
- The issue or ticket (body and acceptance criteria) is the scope and acceptance source. The implementer's `contract` block in the PR body
  (`acceptance_criteria`, `intended_files`, `behavior_changes`, `tests_added`)
  is the implementer's claim to check against the issue and the diff, never an
  authority. A missing optional report or contract block does not make the
  input incomplete.
- Red or pending CI, report formatting, and production acceptance do not
  decide the verdict. If the
  issue names an undelivered prerequisite, write `BLOCKED-ON: #<number>` and
  report `INPUT_INCOMPLETE`.
- When the prompt includes `INCIDENT_RULE`, apply its report requirements before `READY`; the incident report gate requires `NOT_READY` and a reason naming any missing section or invalid recurrence-guard kind.
- A `Verification evidence for head <sha>` paragraph is an input: check the command, exit code and excerpts it names for that exact head against the acceptance criteria. `RED` or `SKIPPED` means unproven, not a finding by itself. If `passed` evidence contradicts a needed behaviour or does not show it, report a finding (`rule` `Spec`, `file` the evidence copy named, `line` 1; P1 when it contradicts, else P2). Evidence never replaces reading the diff.
- A `Proof for head <sha>: <status>` paragraph is the engine's proof check. A mapped change whose status is not `ok` goes back to repair even on `READY`.

## Review in this order

1. **Defects first**: concrete correctness or regression defects caused or
   exposed by the diff — authorization, write consistency, idempotency,
   API/schema/runtime breakage, a bug fix with no regression proof.
2. **Spec**: requirements, behavior, scope, and acceptance criteria against
   the diff and its tests. Cite the exact source for every finding. An
   explicit acceptance criterion the candidate does not meet is a candidate
   finding even when the underlying failure already existed on the base.
3. **Standards**: the repository's own rules, then general good practice.
   Do not repeat formatting that stable tooling already enforces.
   Check the diff against each related ADR's `Do not:` line (via
   `docs/adr/index.md`); the `summary` names the ADR. Overturn an ADR only
   with a superseding one.
4. **Maintainability**: blocking only with diff evidence, real impact, and a
   behavior-equivalent minimum fix that needs no unrelated refactor.

Only a P0/P1 finding introduced by the candidate, with a concrete reachable failure path,
can block. Before reporting a blocker, reopen the cited code and rule, confirm it belongs to this diff,
and collapse duplicate root causes into one finding. For every finding
compare the base and the candidate and record `introduced_by`: `candidate`
(the changed path introduces it), `pre_existing` (cite the matching base path),
or `unknown` (say what prevents attribution). `pre_existing` and `unknown`
findings are reported with their severity but do not block.

For a copied implementation report, read its `## decision-log` and flag weak or risky entries in `decision_log_flags`.

If the diff adds a persisted copy of mutable data, the contract must name the
source of truth, the invalidation trigger, and a drift test. If any is missing,
report a finding. Immutable keys (for example, SHA pairs) are exempt.

## Scale checklist

Pn = section n of docs/design/AGENT-SCALE-PRINCIPLES.md.
- Runs a day times cost a run? (P1)
- Refetches unchanging data? (P2, P5)
- Moves data a service could answer? (P4, P13)
- Cost grows with system size? (P7)
- Host-wide lock or global state? (P8)
- Failure sends all workers upstream? (P6)
- Leaves unreclaimed files or clones? (P9)
A yes with unbounded cost is a finding; name the principle.

## Verdict

Write exactly one standalone line: `VERDICT: READY`, `VERDICT: NOT_READY`, or
`VERDICT: INPUT_INCOMPLETE`. The line must contain only that token and value:
no bold or code formatting, no heading, no label prefix such as `结论：`, no
trailing remark or second verdict value on the same line. `READY` means no
candidate P0/P1 finding remains open.
Advisory, pre-existing, and unknown findings do not block. `NOT_READY`
requires at least one such blocker; `INPUT_INCOMPLETE` means an essential scope
input or a named prerequisite is unavailable. Older reports may still use
`APPROVE`, `REQUEST-CHANGES`, or `BLOCK`; do not write those.

## Machine-readable findings

End every review and every repair report with exactly one fenced block whose
info string is `review-findings`, describing the same findings as your prose:

```review-findings
{"findings":[{"id":"F1","severity":"P1","file":"src/a.ts","line":1,"rule":"Defect","class":"null-guard","status":"open","summary":"Broken query.","introduced_by":"candidate","base_evidence":"Base lacks it.","rerun_command":"git show HEAD:src/a.ts","rerun_output":"Candidate adds it."}],"dispositions":[]}
```

One JSON object with required `findings` and `dispositions` arrays and optional
`decision_log_flags`; no other keys. Empty arrays when nothing to list. Each finding has the required fields below and may include the optional `class` field:

- `id`: `F1`, `F2`, ... (keep IDs across rounds)
- `severity`: `P0`, `P1`, `P2`, or `P3`
- `file`: repository-relative path
- `line`: positive integer
- `rule`: the rule or category, for example `Defect`, `Spec`, `Standards`, `Maintainability`
- `class` (optional): a slug for the defect category, not its location; use the same slug across files for the same defect. Examples: `null-guard`, `tenant-isolation`, `missing-validation`. It must match `^[a-z0-9][a-z0-9-]{0,49}$`; a malformed value is ignored and falls back to the derived key.
- `status`: `open`, `unverified`, `resolved`, or `inherited`
- `summary`: one sentence
- `introduced_by`: `candidate`, `pre_existing`, or `unknown`
- `base_evidence`: non-empty text explaining the comparison with the fixed base
- `rerun_command`: a non-empty command that can verify the finding; when only a test can prove it, name that test for repair or the engine's own test run
- `rerun_output`: non-empty evidence output, or for an `unverified` test-only finding, a note that the reviewer did not run it and it must be passed to repair or the engine's own test run

Reviewers always write `"dispositions":[]`. The repair author adds exactly one entry per
prior finding ID: `id`, `disposition` (`fixed`, `disproved`, `intentional`, or
`out-of-scope`), and `reason` (one non-empty line). Example:
`{"id":"F1","disposition":"fixed","reason":"The query now binds the authenticated tenant before returning records."}`.
IDs must be unique within each array.

`decision_log_flags` entries have exactly `entry` (the quoted decision-log line) and
`reason`, both non-empty single-line strings. Omit or use `[]` when none needs attention.

## Targeted re-review

With author dispositions: verify each `fixed` finding in the repair diff, accept evidence that
closes `disproved` or `intentional`, and do not re-argue a supported disposition. An
`out-of-scope` label alone does not waive a reachable candidate P0/P1 defect. Re-review in full only when the repair adds a schema,
migration, permission boundary, new package or write path, materially expands the diff, or reveals an independent blocker.
