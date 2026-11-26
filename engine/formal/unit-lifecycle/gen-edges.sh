#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
POLICY="$HERE/../../state/scheduling-policy.json"
GATES="$HERE/../../lib.d/dispatch-gates.sh"
terminal="$(sed -n "s/^SCHEDULER_UNIT_TERMINAL_STAGES='\(.*\)'$/\1/p" "$GATES")"
[[ -n "$terminal" ]] || { echo 'SCHEDULER_UNIT_TERMINAL_STAGES is missing' >&2; exit 1; }
jq -r --arg terminal "$terminal" '
  def tla_set($items): "{" + ([$items[] | "\"" + . + "\""] | join(", ")) + "}";
  .state_machine as $sm |
  ($terminal | split(" ") | map(select(length > 0)) | sort) as $terminals |
  ([$sm.transitions | to_entries[] as $entry | $entry.value[] as $to | [$entry.key, $to]] | sort_by(.[0], .[1])) as $edges |
  [
    "Stages == " + tla_set($sm.states | keys | sort),
    "Terminal == " + tla_set($terminals),
    "Legacy == " + tla_set([$sm.states | to_entries[] | select(.value.legacy == true) | .key] | sort),
    "Initial == " + tla_set($sm.initial_states | sort),
    "Escalation == " + tla_set($sm.escalation_targets | sort),
    "Edges == {\n" + ($edges | map("  <<\"" + .[0] + "\",\"" + .[1] + "\">>") | join(",\n")) + "\n}"
  ] | .[]
' "$POLICY"
