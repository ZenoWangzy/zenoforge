mark_supervisor_owned_units() {
  TICK_SUPERVISOR_MARKING_DEFERRED=false
  hotfix_lane_supervisor_owned || return 0
  local branches ids hotpatch_only=false
  if ! branches="$(ci_hotfix_branches)"; then
    say "supervisor-owned marking deferred: hotfix classification unavailable"
    ids="$(jqf -r '[.units[] | select((.supervisor_owned // false) != true and (.hotpatch // false) == true) | .id] | join(" ")' "$UNITS")"
    hotpatch_only=true
    branches='[]'
    TICK_SUPERVISOR_MARKING_DEFERRED=true
  else
    ids="$(jqf -r --slurpfile hot <(printf '%s' "$branches") '[.units[] | select((.supervisor_owned // false) != true
        and ((.hotpatch // false) == true or ((.branch // "") as $br | $hot[0] | index($br) != null))) | .id] | join(" ")' "$UNITS")"
  fi
  mark_supervisor_owned_ids "$ids" "$branches" "$hotpatch_only" || :
}
mark_supervisor_owned_ids() { # id…：补标 supervisor_owned（只增不减）；台账写失败下一拍重试
  [[ -n "${1:-}" ]] || return 0
  local ids_file start count id marked batch_size="${SCHEDULER_LOCK_UNIT_BATCH_SIZE:-20}" hot="${2:-[]}" hotpatch_only="${3:-false}"
  local -a ids=() batch=()
  [[ "$batch_size" =~ ^[1-9][0-9]*$ ]] || batch_size=20
  read -r -a ids <<<"$1"
  count=${#ids[@]}
  for ((start = 0; start < count; start += batch_size)); do
    scheduler_lock_yield_between_units || return 1
    batch=("${ids[@]:start:batch_size}")
    ids_file="$(mktemp)" || return 1
    printf '%s\n' "${batch[@]}" | jqf -Rsc 'gsub("\\s+";" ") | split(" ") | map(select(length > 0))' > "$ids_file" \
      || { rm -f -- "$ids_file"; return 1; }
    units_update --slurpfile ids "$ids_file" --argjson hot "$hot" --arg hotpatch_only "$hotpatch_only" \
      '.units |= map(. as $unit | if (($ids[0] | index($unit.id)) != null) and ($unit.supervisor_owned // false) != true
        and (($unit.hotpatch // false) == true or ($hotpatch_only != "true" and ($hot | index($unit.branch // "")) != null))
        then $unit.supervisor_owned = true else $unit end)' \
      || { rm -f -- "$ids_file"; say "supervisor-owned marking: ledger write failed; retried next tick"; return 1; }
    marked="$(jqf -r --slurpfile ids "$ids_file" \
      '[.units[] | select(.supervisor_owned==true and (.id as $id | $ids[0] | index($id) != null)) | .id] | .[]' "$UNITS")" || marked=""
    rm -f -- "$ids_file"
    while IFS= read -r id; do
      [[ -n "$id" ]] && say "unit=$id supervisor-owned: counted for census only; review and merge stay with the hotfix supervisor"
    done <<<"$marked"
  done
  scheduler_lock_yield_between_units || return 1
  return 0
}
supervisor_marking_deferred() { [[ "${TICK_SUPERVISOR_MARKING_DEFERRED:-false}" == true ]]; }
