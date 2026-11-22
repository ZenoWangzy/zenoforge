# Human exits (ready-for-human, needs-info) are gaps to remove, not features
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** The `ready-for-human` and `needs-info` exits are gaps in the factory, to be removed; new work does not add a hand-off to a person.
> **Do not:** add a new `ready-for-human` or `needs-info` exit; park a ticket to wait for a person; make a human reply the only way out of a stage
> **Rejected:** none stated
> **Terms:** ready-for-human, needs-info, needs-owner, needs-advisor, transient model verdict

The goal in AGENTS.md is an unattended, self-healing factory, so `ready-for-human` and `needs-info` are called "gaps to remove, not features to keep." The label table says `ready-for-human` is a transient model verdict: triage defaults to implementation, or sends an irreversible, production-data or security call to the advisor, and "it never parks for a person." `needs-info` is a wait for a person's answer that then returns to triage. The README says some tickets are still routed to a person and calls that a gap to remove.

The advisor route that triage uses is disabled by default and no advisor provider ships, so removing a person exit depends on that route first. That dependency is open work, not settled here.

## Consequences
- Existing person exits remain until their removal lands; the ADR does not delete them.
- A change that adds a person hand-off needs a new ADR that supersedes this one.
- Reviewers check new states against this rule.

Sources: AGENTS.md (opening paragraph), docs/architecture.md#21-the-labels, docs/architecture.md#2-stage-chain-and-labels, docs/architecture.md#33-issue-loop-escalation, README.md (intro paragraph)
