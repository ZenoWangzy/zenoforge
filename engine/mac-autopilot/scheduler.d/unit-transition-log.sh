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

unit_task_state_write() {
  local from_stage="$2" old_owner="$3" old_history="$4" unit="$5" payload
  payload="$(jq -cn --arg from_stage "$from_stage" --arg old_owner "$old_owner" --argjson old_history "$old_history" --slurpfile unit <(printf '%s' "$unit") '{unit:$unit[0],from_stage:$from_stage,old_owner:$old_owner,old_history:$old_history}')" || return 1
  printf '%s\n' "$payload" | node "${ZF_ENGINE_DIR:-$ENGINE_ROOT/engine}/task-state.mjs" write-unit-transition "$AGENT_HOME/task-state"
}

unit_task_state_rollback() {
  local snapshots="${1:-}" snapshot status=0
  [[ -n "$snapshots" ]] || return 0
  while IFS= read -r snapshot; do
    [[ -n "$snapshot" ]] || continue
    node "${ZF_ENGINE_DIR:-$ENGINE_ROOT/engine}/task-state.mjs" rollback-transition "$AGENT_HOME/task-state" <<< "$snapshot" || status=1
  done <<< "$snapshots"
  return "$status"
}

unit_transition_observe_ledger() { # old-ledger candidate-ledger caller [unit-id from-stage]
  local old_file="$1" candidate="$2" caller="$3" id="${4:-}" from="${5:-}" to old_owner owner64 old_history unit64 unit snapshot snapshots=""
  while IFS=$'\t' read -r id from to owner64 old_history unit64; do
    [[ -n "$id" ]] || continue
    if [[ "$from" != "$to" ]]; then
      unit_transition_log_pair "$id" "$from" "$to" "$caller" || { printf '%s' "$snapshots"; return 1; }
    fi
    old_owner="$(base64 -d <<<"$owner64")" || old_owner="$id"
    unit="$(base64 -d <<<"$unit64")" || { say "task-state unit decode failed unit=$id"; continue; }
    snapshot="$(unit_task_state_write "$id" "$from" "$old_owner" "$old_history" "$unit")" \
      || { say "task-state write failed unit=$id stage=$to"; printf '%s' "$snapshots"; return 1; }
    snapshots+="$snapshot"$'\n'
  done < <(jq -r --slurpfile next "$candidate" --arg id "$id" --arg from "$from" '
    ($next[0].units | INDEX(.id)) as $idx
    | .units[] as $old
    | $idx[$old.id] as $new
    | select($new != null)
    | select($id == "" or $old.id == $id)
    | (($old.owner_id // $old.worker_id // "") as $owner
       | if ($owner | type) == "string" and ($owner | length) > 0 then $owner else $old.id end) as $old_owner
    | (($new.owner_id // $new.worker_id // "") as $owner
       | if ($owner | type) == "string" and ($owner | length) > 0 then $owner else $new.id end) as $new_owner
    | (($old.history // []) | length) as $old_history
    | (($new.history // []) | length) as $new_history
    | (($new.history // []) | last // {}) as $last
    | select(($old.stage // "") != ($new.stage // "") or $old_owner != $new_owner
      or ($new_history > $old_history and ($last.decision != null
        or (($last.result // "") as $result | ($result | type) == "string" and ($result | test("supervisor ruling"; "i"))))))
    | [$old.id, (if $from != "" then $from else ($old.stage // "") end), ($new.stage // ""),
       ($old_owner | @base64), ($old_history | tostring), ($new | @base64)] | @tsv' "$old_file" 2>/dev/null)
  printf '%s' "$snapshots"
}

unit_transition_load
