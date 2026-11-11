#!/usr/bin/env bash
# The implement report headings apply to every unit; the incident rule stays label-scoped.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

repo_root="$MAC_AUTOPILOT_ENV_ROOT"
HERE="$repo_root/engine/mac-autopilot"
queue_source="$HERE/scheduler.d/dispatch-queue.sh"
source "$queue_source"
source "$repo_root/engine/incident-rule.sh"
jqf() { jq "$@"; }
source "$repo_root/engine/mac-autopilot/scheduler.d/review-rules.sh"

bug_unit='{"id":"incident-bug","issue":5389,"labels":["bug"]}'
plain_unit='{"id":"ordinary","issue":5390,"labels":["enhancement"]}'
line='This unit IS an incident unit: its label bug is in incident.labels, so every requirement below applies to your report.'
[[ "$(grep -cF '$(implement_report_sections)' "$queue_source" || true)" == 2 ]] \
  || { echo 'not ok - implement report sections are not included in both REPORT blocks' >&2; exit 1; }
declare -F implement_report_sections >/dev/null \
  || { echo 'not ok - implement report section helper is missing from the dispatch queue' >&2; exit 1; }
report_sections="$(implement_report_sections)"

bug_prompt="$(incident_worker_prompt implement "$bug_unit" "$report_sections")"
[[ "$bug_prompt" == *"$line"$'\nINCIDENT_RULE\n'* ]] \
  || { echo 'not ok - bug-labelled implement prompt lacks the matched-label line before INCIDENT_RULE' >&2; exit 1; }

plain_prompt="$(incident_worker_prompt implement "$plain_unit" "$report_sections")"
[[ "$plain_prompt" == "$report_sections" && "$plain_prompt" != *'INCIDENT_RULE'* ]] \
  || { echo 'not ok - non-incident implement prompt received the incident rule or lost its base prompt' >&2; exit 1; }

for section in '## how' '## why' '## decision-log'; do
  grep -Fxq -- "$section" <<<"$plain_prompt" \
    || { echo "not ok - ordinary implement prompt lacks gate-required $section" >&2; exit 1; }
done

two_labels="$(incident_match_line '{"labels":[{"name":"bug"},{"name":"incident"},{"name":"enhancement"}]}' '["bug","incident","production-anomaly"]')"
[[ "$two_labels" == 'This unit IS an incident unit: its label bug, incident is in incident.labels, so every requirement below applies to your report.' ]] \
  || { echo "not ok - two matched labels are not named comma-separated: $two_labels" >&2; exit 1; }

echo 'ok - implement report headings reach ordinary workers and incident rule names matched labels only'
