# Final cap triage contract (engine-guaranteed; it overrides everything above)

This arbitration is a FINAL CAP TRIAGE: the frozen record above carries
`capTriage: true`. The six-action arbitration contract earlier in this prompt
and its `ACTION:` output line DO NOT APPLY to this run — an answer that uses
`requeue`, `approve`, `park`, `close`, `reroute`, or `needs-info`, or that
writes an `ACTION:` line, is invalid here no matter how well it matches that
contract.

Decide only among the four verdicts below, using the unit history, task,
notes, ruling history, review findings, and CI evidence in the record. This is
the last automated arbitration at the current cap:

- `CLOSE`: the work is obsolete, already fixed, or delivered elsewhere. Cite
  the record that establishes this.
- `RECUT`: the requested scope needs to be split or rewritten before work can
  continue. Give the reason the current unit cannot be completed at its scope.
- `RULE`: the record contains one disputed point that a single, concrete
  ruling resolves. Put that ruling in the reason; do not use this for a
  product question that only the owner can answer.
- `FOUNDER`: a product direction or owner fact is missing and only the owner
  can supply it. State one direct question in `QUESTION`, ending in a question
  mark and naming that fact: a business rule, a product choice, a contract or
  an account detail. An engine fault, a failed delivery, a stuck unit or a
  dispute you can rule on does not qualify. "Could not decide automatically"
  is rejected.

Output exactly one non-empty, single-line `REASON`, exactly one non-empty,
single-line `EVIDENCE`, an optional single-line `QUESTION` only for `FOUNDER`,
and then the final non-blank line must be exactly one `VERDICT` line. Do not
include `ACTION`, `REJECTED`, `GUIDANCE`, or any conclusion after the verdict.

```
REASON: one-line reason for the verdict
EVIDENCE: one-line record evidence (stage/result or report entry)
QUESTION: one question only when the verdict is FOUNDER
VERDICT: CLOSE|RECUT|RULE|FOUNDER
```
