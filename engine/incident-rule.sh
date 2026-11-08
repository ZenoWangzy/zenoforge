#!/usr/bin/env bash
# One prompt contract shared by autopilot and the hotfix worker lane.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/matt-skills.sh"

INCIDENT_DEFAULT_LABELS_JSON='["bug","incident","production-anomaly"]'

incident_labels_from_config() { # JSON config → configured incident label names
  jq -c --argjson defaults "$INCIDENT_DEFAULT_LABELS_JSON" '
    if (.incident.labels | type) == "array"
      and all(.incident.labels[]; type == "string" and length > 0)
    then .incident.labels else $defaults end
  ' <<<"$1"
}

incident_labels_match_json() { # issue/unit JSON, configured labels JSON → success if any label matches
  jq -e --argjson configured "$2" '
    ([.labels[]? | if type == "string" then . else (.name // empty) end]) as $labels
    | any($labels[]; . as $label | ($configured | index($label)) != null)
  ' <<<"$1" >/dev/null 2>&1
}

incident_rule_text() { # canonical requirements shared across implementation, review, arbiter and hotfix prompts
  cat <<EOF
INCIDENT_RULE
For an incident unit (its issue has a label in the configured incident.labels set), use $(pstack_skill_md principle-fix-root-causes) to find the first place the system went wrong, and $(pstack_skill_md correct) to make the recurrence structurally impossible.

The implementation or repair report must contain:
- A section headed exactly \`## root-cause\`, giving the first place the system went wrong, backed by the actual original log line and a repository file:line.
- A section headed exactly \`## recurrence-guard\` with a \`kind:\` line set to architecture, state, script, lint, or test; the guard's file:line; and the exact command with captured output showing it FAILS against a planted copy of the real past bad input/code and PASSES after the fix. Prose is not a guard.
- A section headed exactly \`## prior-art\` researched with web search. Name the classic problem this incident is a variant of, how leading domain experts frame it, mature solutions, and community best practice; explain which researched solution informed this fix and cite the sources as direct http(s) URLs in this section. If the case is uncertain or sources conflict, do not guess: escalate to the advisor (CTO) and the head, state that in this section, and include an explicit \`Escalation reference:\` with the issue, PR, or URL for that escalation.
- A complete lesson entry added to the incident-guard registry tracked in THIS checkout — the repository's .zenoforge/state/incident-guards.json when this repo carries one, otherwise engine/state/incident-guards.json — committed on this unit's branch so the PR or landing delivers it. Add it as one new fragment file, <registry file minus .json>.d/<id>.json holding {"incidents": [the one record]} (or run node engine/incident-guards.mjs add <registry file> <record.json>), and never edit the registry file itself: every incident edited its tail and the parallel PRs conflicted. Registries resolved outside this checkout (the running deployment's shared checkout, an engine-versions pin directory, anything under the agent home) are live deployment state: reading them is fine, writing them is forbidden — a row written there bypasses the unit's own diff and dirties a checkout no worker owns. Conform to engine/lesson-guard-schema.mjs: include the required root-cause and classic-problem record fields, research sources, compared options, lesson_id, and a runnable machine check or mechanism link. Set enforcement.enforced_by to an array containing the repo-relative path of this same recurrence guard.

Reviewers must verify this report before READY. Missing any required heading, a prior-art section with no http(s) source URL, an escalation note without an explicit escalation reference, or a recurrence guard whose kind is prose or is absent/invalid, requires NOT_READY/request-changes with a reason naming the missing or invalid part. Also verify the researched framing, planted reproduction, before/after command output, file:line and lesson enforcer are concrete. A diff that delivers no lesson registry row (the entry was written nowhere, or into a registry file outside this checkout, such as a deployment checkout or an engine-versions pin) requires the same NOT_READY/request-changes, naming the missing registry row.
EOF
}
