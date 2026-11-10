#!/usr/bin/env bash
# Focused recurrence guard for prior-art requirements in incident review reports.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

repo_root="$MAC_AUTOPILOT_ENV_ROOT"
source "$repo_root/engine/incident-rule.sh"
source "$repo_root/engine/mac-autopilot/scheduler.d/review-rules.sh"

incident_unit='{"id":"incident-prior-art","issue":164,"labels":["bug"]}'
ordinary_unit='{"id":"ordinary-change","issue":165,"labels":[]}'
report="$test_env_root/incident-prior-art.md"
base_body=$'## decision-log\nTried the existing report shape, kept the tested guard, and verified the report gate.\n\n## root-cause\nThe gate required only two headings.\n\n## recurrence-guard\nkind: test\nfile: engine/mac-autopilot/incident-prior-art-gate.test.sh:57\n'

assert_case() {
  local expected="$1" label="$2" unit="$3" body="$4" expected_reason="${5:-}" verdict reason
  printf '%s' "$body" > "$report"
  verdict="$(incident_review_verdict "$unit" READY "$report")"
  reason="$(incident_report_gate_reason "$unit" "$report")"
  if [[ "$verdict" != "$expected" || ( -n "$expected_reason" && "$reason" != *"$expected_reason"* ) ]]; then
    printf 'not ok - %s (expected=%s verdict=%s reason=%s)\n' "$label" "$expected" "$verdict" "$reason" >&2
    exit 1
  fi
  printf 'ok - %s\n' "$label"
}

if [[ "${1:-}" == --plant-old ]]; then
  # Planted pre-fix behavior from review-rules.sh: it checked only root-cause,
  # recurrence-guard, and the guard kind, so this real old-shape report passed.
  incident_report_gate_reason() {
    local unit_json="$1" report_path="${2:-}" guard_section kind_line kind
    incident_labels_match_json "$unit_json" "${INCIDENT_LABELS:-$INCIDENT_DEFAULT_LABELS_JSON}" || return 0
    [[ -n "$report_path" && -s "$report_path" ]] || { printf 'missing incident implementation report'; return 0; }
    grep -qE '^## root-cause[[:space:]]*$' "$report_path" || { printf 'missing ## root-cause'; return 0; }
    grep -qE '^## recurrence-guard[[:space:]]*$' "$report_path" || { printf 'missing ## recurrence-guard'; return 0; }
    guard_section="$(awk '/^## recurrence-guard[[:space:]]*$/{inside=1; next} /^##[[:space:]]/{inside=0} inside {print}' "$report_path")"
    kind_line="$(grep -iE '^[[:space:]]*([-*][[:space:]]+|[0-9]+[.)][[:space:]]+)?(guard[[:space:]]+)?kind:[[:space:]]*' <<<"$guard_section" | head -n1 | tr '[:upper:]' '[:lower:]' || true)"
    kind="$(sed -nE 's/^[[:space:]]*([-*][[:space:]]+|[0-9]+[.)][[:space:]]+)?(guard[[:space:]]+)?kind:[[:space:]]*`?([[:alnum:]-]+)`?.*$/\3/p' <<<"$kind_line" | head -n1)"
    case "$kind" in architecture|state|script|lint|test) return 0 ;; *) printf 'invalid recurrence guard'; return 0 ;; esac
  }
  printf '%s' "$base_body" > "$report"
  verdict="$(incident_review_verdict "$incident_unit" READY "$report")"
  if [[ "$verdict" == READY ]]; then
    printf 'not ok - planted pre-fix gate accepted the incident report without prior-art\n' >&2
    exit 1
  fi
  printf 'not ok - planted pre-fix gate failed to reproduce the prior-art bypass (verdict=%s)\n' "$verdict" >&2
  exit 1
fi

rule="$(incident_rule_text)"
[[ "$rule" == *'## prior-art'* && "$rule" == *'web search'* \
  && "$rule" == *'advisor (CTO) and the head'* && "$rule" == *'Escalation reference:'* ]] \
  || { echo 'not ok - incident rule omits prior-art research or escalation instructions' >&2; exit 1; }
echo 'ok - incident prompt requires researched prior-art and referenced escalation'

assert_case NOT_READY 'incident report without prior-art is rejected' "$incident_unit" "$base_body" 'missing ## prior-art'
assert_case NOT_READY 'prior-art without a URL is rejected' "$incident_unit" \
  "$base_body"$'\nSources elsewhere: https://sre.google/workbook/postmortem-culture/\n## prior-art\nClassic problem: incomplete incident postmortem. Experts recommend preventive follow-up.\n' \
  'http(s) source URL'
assert_case READY 'prior-art with source URLs is accepted' "$incident_unit" \
  "$base_body"$'\n## prior-art\nClassic problem: incomplete incident postmortem. Experts recommend preventive follow-up.\nSources: https://sre.google/workbook/postmortem-culture/ and https://doi.org/10.6028/NIST.IR.8428\n'
no_decision_log=$'## root-cause\nThe persisted state was selected incorrectly.\n\n## recurrence-guard\nkind: test\n\n## prior-art\nSource: https://example.invalid/incident-reference\n'
printf '%s' "$no_decision_log" > "$report"
[[ "$(incident_review_verdict "$incident_unit" READY "$report")" == NOT_READY ]] \
  || { echo 'not ok - READY review passed without a decision-log section' >&2; exit 1; }
printf 'ok - READY review without decision-log is rejected\n'
assert_case NOT_READY 'escalation note without a reference is rejected' "$incident_unit" \
  "$base_body"$'\n## prior-art\nClassic problem: incomplete incident postmortem.\nUncertain sources were escalated to advisor (CTO) and the head.\nSource: https://sre.google/workbook/postmortem-culture/\n' \
  'escalation reference'
assert_case READY 'escalation with a reference is accepted' "$incident_unit" \
  "$base_body"$'\n## prior-art\nClassic problem: incomplete incident postmortem.\nUncertain sources were escalated to advisor (CTO) and the head.\nEscalation reference: #164\nSource: https://sre.google/workbook/postmortem-culture/\n'
# A negated mention is not a stated escalation: it must not demand a reference.
for negated in \
  'No escalation was needed.' \
  'Escalation was not needed.' \
  'Escalation: none' \
  'We did not need to escalate.' \
  "Escalation wasn't necessary." \
  'Resolved without any escalation.' \
  'Nothing to escalate: the sources agree.'; do
  assert_case READY "negated escalation is accepted: $negated" "$incident_unit" \
    "$base_body"$'\n## prior-art\nClassic problem: incomplete incident postmortem.\n'"$negated"$'\nSource: https://sre.google/workbook/postmortem-culture/\n'
done
# The exact text from the rejected report, as its own sentence among others.
assert_case READY 'no escalation was needed inside a longer paragraph' "$incident_unit" \
  "$base_body"$'\n## prior-art\nThe three sources agree, so no escalation was needed.\nSource: https://sre.google/workbook/postmortem-culture/\n'
# A positive claim, alone or mixed with a negated one, still needs its reference.
assert_case NOT_READY 'positive escalation mixed with a negated one is rejected' "$incident_unit" \
  "$base_body"$'\n## prior-art\nSources conflict, so it was escalated to the advisor; no further escalation was needed.\nSource: https://sre.google/workbook/postmortem-culture/\n' \
  'escalation reference'
assert_case NOT_READY 'was-not-sure-and-escalated is still a positive claim' "$incident_unit" \
  "$base_body"$'\n## prior-art\nI was not sure and escalated to the CTO.\nSource: https://sre.google/workbook/postmortem-culture/\n' \
  'escalation reference'
assert_case READY 'non-incident report is unaffected' "$ordinary_unit" "$base_body"

echo 'incident-prior-art-gate.test.sh: PASS'
