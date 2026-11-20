unit_transition_load() {
  [[ "${UNIT_TRANSITION_POLICY_LOADED:-false}" == true ]] && return 0
  UNIT_TRANSITION_POLICY_LOADED=true
  UNIT_TRANSITION_POLICY_READY=false
  local policy rows kind from to
  policy="${UNIT_TRANSITION_POLICY_FILE:-}"
  if [[ -z "$policy" ]]; then
    policy="$(sched_config_file state/scheduling-policy.json 2>/dev/null)" || policy="$HERE/../state/scheduling-policy.json"
  fi
  [[ -f "$policy" && -r "$policy" ]] || { say "unit transition log off: unreadable policy $policy" || :; return 0; }
  [[ -s "$policy" ]] || { say "unit transition log off: empty policy $policy" || :; return 0; }
  rows="$(jq -r '
    .state_machine as $m
    | (($m.transitions // {} | to_entries[] as $entry | $entry.value[] | ["edge", $entry.key, .] | @tsv),
       ($m.escalation_targets[]? | ["escalation", ., ""] | @tsv),
       ($m.states // {} | to_entries[] | select(.value.legacy == true) | ["legacy", .key, ""] | @tsv),
       ($m.initial_states[]? | ["initial", ., ""] | @tsv))' "$policy" 2>/dev/null)" \
    || { say "unit transition log off: invalid policy $policy" || :; return 0; }
  UNIT_TRANSITION_EDGES=$'\n'
  UNIT_TRANSITION_ESCALATIONS=$'\n'
  UNIT_TRANSITION_LEGACY=$'\n'
  UNIT_TRANSITION_INITIAL=$'\n'
  while IFS=$'\t' read -r kind from to; do
    case "$kind" in
      edge) UNIT_TRANSITION_EDGES+="$from>$to"$'\n' ;;
      escalation) UNIT_TRANSITION_ESCALATIONS+="$from"$'\n' ;;
      legacy) UNIT_TRANSITION_LEGACY+="$from"$'\n' ;;
      initial) UNIT_TRANSITION_INITIAL+="$from"$'\n' ;;
    esac
  done <<< "$rows"
  UNIT_TRANSITION_POLICY_READY=true
}

unit_transition_list_has() {
  [[ "$1" == *$'\n'"$2"$'\n'* ]]
}

unit_transition_declared() {
  local from="$1" to="$2"
  [[ "$from" == "$to" ]] && return 0
  if [[ -z "$from" ]]; then
    unit_transition_list_has "$UNIT_TRANSITION_INITIAL" "$to"
    return $?
  fi
  unit_transition_list_has "$UNIT_TRANSITION_EDGES" "$from>$to" && return 0
  unit_transition_list_has "$UNIT_TRANSITION_ESCALATIONS" "$to" \
    && ! unit_transition_list_has "$UNIT_TRANSITION_LEGACY" "$from"
}

unit_transition_log_pair() {
  local id="$1" from="$2" to="$3" caller="$4" mode="${UNIT_TRANSITION_MODE:-log}"
  if [[ "${UNIT_TRANSITION_POLICY_READY:-false}" != true ]]; then
    if [[ "$mode" == enforce ]]; then
      say "unit-transition refused unit=$id from=$from to=$to caller=$caller policy=unavailable" || :
      return 1
    fi
    return 0
  fi
  unit_transition_declared "$from" "$to" && return 0
  if [[ "$mode" == enforce ]]; then
    say "unit-transition refused unit=$id from=$from to=$to caller=$caller" || :
    return 1
  fi
  say "unit transition undeclared unit=$id from=$from to=$to by=$caller" || :
  return 0
}

unit_transition_observe_ledger() { # old-ledger candidate-ledger caller [unit-id from-stage]
  local old_file="$1" candidate="$2" caller="$3" id="${4:-}" from="${5:-}" to
  if [[ -n "$id" ]]; then
    to="$(jq -r --arg id "$id" '[.units[] | select(.id == $id) | .stage][0] // empty' "$candidate" 2>/dev/null)" || return 0
    [[ "$from" != "$to" ]] || return 0
    unit_transition_log_pair "$id" "$from" "$to" "$caller" || return $?
    return 0
  fi
  while IFS=$'\t' read -r id from to; do
    [[ -n "$id" ]] || continue
    unit_transition_log_pair "$id" "$from" "$to" "$caller" || return $?
  done < <(jq -r --slurpfile next "$candidate" '
    ($next[0].units | INDEX(.id)) as $idx
    | .units[] as $old
    | $idx[$old.id] as $new
    | select($new != null)
    | select(($old.stage // "") != ($new.stage // ""))
    | [$old.id, ($old.stage // ""), ($new.stage // "")] | @tsv' "$old_file" 2>/dev/null)
}

unit_transition_load
