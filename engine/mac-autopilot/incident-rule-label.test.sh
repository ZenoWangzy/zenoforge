#!/usr/bin/env bash
# The appended incident rule names the matched label, so a bug-labelled worker never reads the unit as non-incident.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

repo_root="$MAC_AUTOPILOT_ENV_ROOT"
source "$repo_root/engine/incident-rule.sh"
jqf() { jq "$@"; }
source "$repo_root/engine/mac-autopilot/scheduler.d/review-rules.sh"

bug_unit='{"id":"incident-bug","issue":5389,"labels":["bug"]}'
plain_unit='{"id":"ordinary","issue":5390,"labels":["enhancement"]}'
line='This unit IS an incident unit: its label bug is in incident.labels, so every requirement below applies to your report.'

bug_prompt="$(incident_worker_prompt implement "$bug_unit" 'base implement prompt')"
[[ "$bug_prompt" == $'base implement prompt\n'"$line"$'\nINCIDENT_RULE\n'* ]] \
  || { echo 'not ok - bug-labelled implement prompt lacks the matched-label line before INCIDENT_RULE' >&2; exit 1; }

plain_prompt="$(incident_worker_prompt implement "$plain_unit" 'base implement prompt')"
[[ "$plain_prompt" == 'base implement prompt' ]] \
  || { echo 'not ok - non-incident implement prompt received the incident rule or its matched-label line' >&2; exit 1; }

two_labels="$(incident_match_line '{"labels":[{"name":"bug"},{"name":"incident"},{"name":"enhancement"}]}' '["bug","incident","production-anomaly"]')"
[[ "$two_labels" == 'This unit IS an incident unit: its label bug, incident is in incident.labels, so every requirement below applies to your report.' ]] \
  || { echo "not ok - two matched labels are not named comma-separated: $two_labels" >&2; exit 1; }

echo 'ok - incident rule names the matched label for bug-labelled units only'
