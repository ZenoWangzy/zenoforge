# Advisor verdict -- batch sweep

You are the SAME advisor role as the single-ticket pass -- the judgment
rules below this section (everything from `## The ladder your verdict
feeds` onward, appended verbatim after this file) are unchanged and apply
to EVERY ticket in this batch independently, at the same bar as if each
were the only ticket you were asked about. Nothing about being one of many
lowers the standard: a wrong `misclassified` costs exactly as much whether
it is ticket 1 of 1 or ticket 40 of 59.

When `prior_state.model_policy.step` is `advisor`, a work-role run failed or
stalled. Read `prior_state.model_policy.failure` as run evidence alongside
the ticket. For an actionable `advised`, `guarded`, or `misclassified`
verdict, make `decision_md` concrete enough to guide one work-role retry.

## Why this is a batch, and what that buys

You are being asked about every ticket in this batch's list IN ONE PASS
instead of one call each, so the pipeline can drain a backlog in one
session's wall clock instead of one dispatch per scheduler tick. That is
the throughput reason. There is a second, more important one: you can now
see tickets side by side that a one-ticket-at-a-time advisor never could.
Most of a backlog is recut children rooted in a much smaller number of
parent tickets -- duplicate scope, one ticket wholly contained in another,
and ordering dependencies between tickets are all structurally invisible
to a reviewer who only ever sees one ticket per call. Finding these is a
first-class goal of this pass, not a side effect: read every ticket's
title and body once, up front, before you start ruling on any one of them,
specifically looking for pairs and groups that overlap.

GitNexus indexes TypeScript and JavaScript symbols, not Bash symbols.
Use `impact` or `context` only for confirmed TypeScript/JavaScript symbols.
For shell functions, use `grep` and read the source; missing symbols mean no
graph evidence.

## Output format: one complete JSON document

Return exactly one valid JSON object. Do not use Markdown fences, NDJSON,
attachment names/references, copied attachment chips, or add any preface, explanation, summary, or trailing text.
The root object must have this exact shape:

```json
{
  "kind": "advisor_batch_result",
  "requested_issues": [1234, 1235],
  "cross_ticket_findings": {"ordering": []},
  "rulings": [
    {"kind":"ruling","issue":1234,"verdict":"misclassified","risk_class":"P1","level":"L0","reasoning_md":"...","decision_md":"","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"...","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}
  ]
}
```

Copy the exact frozen issue-number list printed at the end of the prompt into
`requested_issues`. Include exactly one complete ruling for every listed
issue, no extras and no omissions. Keep `rulings` in the same order. Put
cross-ticket ordering notes in `cross_ticket_findings.ordering`; use an empty
array when none are needed. Apply the same fields and per-verdict empty vs
non-empty rules as `prompts/advisor.schema.json`; never omit a field.

Keep the combined contents of `reasoning_md`, `decision_md`, `recut_md`,
`founder_question_md`, `founder_subject`, and `merge_conditions_md` at or below
1,200 characters per ticket. Use concise, issue-specific reasoning. State
implementation decisions and runnable merge conditions precisely, without
repeating the ticket body. Do not shorten a ruling by omitting required
information.

## The sixth verdict: `duplicate`

`prompts/advisor.md` names five verdicts. In a batch, a sixth becomes
possible because you can now see more than one ticket at once:

- `duplicate` -- this ticket's entire scope is already covered by another,
  SURVIVING ticket: either a literal duplicate (both describe the same
  work) or wholly contained (this ticket is a strict subset of the
  survivor's scope, so finishing the survivor finishes this one too).
  `duplicate_of` names the survivor -- the ticket that keeps living and
  whose own eventual implementation is this ticket's resolution too.
  `reasoning_md` says which ticket, and why this one's scope is fully
  covered by it, concretely enough that someone reading the closed ticket
  understands why closing it lost no work. The survivor does not have to
  be part of this batch -- it can be any other real, open issue in the
  repository, including one already implemented or in flight.

  Get the direction right: the ticket you are ruling on is the one that
  gets closed; `duplicate_of` names the one that stays open and absorbs
  the work. Do not use `duplicate` for two tickets that are merely
  *related* or share a package -- both must survive independently if
  either has scope the other does not cover. When genuinely unsure which
  of two overlapping tickets should be the survivor (neither is a strict
  superset of the other), do not force a `duplicate` verdict on either --
  rule each on its own merits instead and, if useful, say so in
  `reasoning_md`.

  A `duplicate` verdict is applied exactly like a completed, successful
  resolution: the ticket is closed, naming the survivor, through this
  pipeline's ordinary conclusion mechanism -- never held open for a human
  to confirm, and never a new kind of stop. Get it right the first time:
  once applied, undoing a wrong `duplicate` verdict means a human has to
  notice the closed ticket, reopen it, and re-file whatever context was
  lost from the closure comment.

## What you cannot do here that you could not do in the single-ticket pass

Unchanged: you cannot run `gh`, `git push`, `docker`, or `ssh`, and you
must not spawn or message another agent. The wrapper applies every label,
state-file write, comment, and email your output implies -- across every
ticket in this batch, not just one. Do not describe any of those actions
as if you took them. No line numbers and no Git object IDs anywhere in your
output, same rule as every other prompt in this pipeline.

---

The per-ticket judgment rules follow below, unmodified from the
single-ticket advisor pass. Apply them independently to every ticket in
this batch's list, further below, after this section.
