# Fresh GitHub read of a predecessor (#536): the dependency cache refreshes only every DEP_CHECK_SECONDS, so a stale CLOSED frees nothing until one fresh read says so.
declare -gA DISPATCH_BODY_DEP_FRESH=()
DISPATCH_BODY_DEP_PRIMED=false DISPATCH_BODY_DEP_QUERY_COUNT=0 DISPATCH_BODY_DEP_UNITS=0
dispatch_body_dependencies_prime() { # one pass: batch the missing fresh states for body blockers
  local dep state memo stamp results started_us elapsed has_body body_ids task_b64 dropped task blockers
  local -a missing=()
  local -A seen=()
  DISPATCH_BODY_DEP_FRESH=(); DISPATCH_BODY_DEP_PRIMED=true; DISPATCH_BODY_DEP_QUERY_COUNT=0; DISPATCH_BODY_DEP_UNITS=0
  started_us=${EPOCHREALTIME/[.,]/}
  while IFS=$'\t' read -r has_body body_ids task_b64 dropped; do
    if [[ "$has_body" == true ]]; then
      blockers="$(tr ',' '\n' <<<"$body_ids")"
    else
      task="$(printf '%s' "$task_b64" | base64 -d 2>/dev/null || true)"
      blockers="$(issue_body_blocked_by <<<"$task")"
    fi
    while IFS= read -r dep; do
      [[ "$dep" =~ ^[0-9]+$ ]] || continue
      [[ ",$dropped," == *",$dep,"* ]] && continue
      seen[$dep]=1
    done <<<"$blockers"
  done < <(jqf -r '.units[] as $u
    | select($u.stage=="implement-pending" or ($u.stage=="repair-pending" and $u.hold_handoff_episode != null))
    | [((($u.body_blocked_by | type)=="array")|tostring),
       (if ($u.body_blocked_by | type)=="array" then [$u.body_blocked_by[] | select(type=="number") | tostring] | join(",") else "" end),
       (if ($u.task // "")=="" then "-" else ($u.task|@base64) end),
       ([($u.dropped_deps // [])[] | tostring]|join(","))] | @tsv' "$UNITS")
  DISPATCH_BODY_DEP_UNITS=${#seen[@]}
  for dep in "${!seen[@]}"; do
    state="$(jqf_optional_file "$A/dep-check.cache.json" -r --arg d "$dep" '.states[$d].state // empty' 2>/dev/null || true)"
    [[ -n "$state" ]] && continue
    memo="$A/dep-fresh-$dep"; stamp=""
    if [[ -f "$memo" ]]; then read -r stamp state < "$memo" || stamp=""; else state=""; fi
    if [[ "$stamp" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - stamp < ${DEP_CHECK_SECONDS:-600} )); then
      DISPATCH_BODY_DEP_FRESH[$dep]="$state"
    else
      missing+=("$dep")
    fi
  done
  if ((${#missing[@]})); then
    DISPATCH_BODY_DEP_QUERY_COUNT=1
    results="$(dep_states "${missing[@]}" 2>/dev/null || true)"
    while IFS=$'\t' read -r dep state _; do
      [[ "${seen[$dep]:-}" == 1 ]] || continue
      DISPATCH_BODY_DEP_FRESH[$dep]="$state"
      if [[ -n "$state" && "$state" != CLOSED && "$state" != MERGED ]]; then printf '%s %s\n' "$NOW_EPOCH" "$state" > "$A/dep-fresh-$dep"; fi
    done <<< "$results"
    for dep in "${missing[@]}"; do
      [[ -n "${DISPATCH_BODY_DEP_FRESH[$dep]+set}" ]] || DISPATCH_BODY_DEP_FRESH[$dep]=""
    done
  fi
  elapsed=$((${EPOCHREALTIME/[.,]/} - started_us))
  if [[ "${TICK_DISPATCH_PENDING_ACTIVE:-false}" == true ]] && (( elapsed >= 2000000 )); then
    say "dispatch detail body_dependency_prime units=$DISPATCH_BODY_DEP_UNITS secs=$(format_duration_us "$elapsed")s gh_calls=$DISPATCH_BODY_DEP_QUERY_COUNT"
  fi
}
dep_fresh_state() { # predecessor → the fresh GitHub state, empty when unreadable; only a nonempty OPEN read is memoized
  local f="$A/dep-fresh-$1" stamp memo fresh
  if [[ "${DISPATCH_BODY_DEP_PRIMED:-false}" == true && -n "${DISPATCH_BODY_DEP_FRESH[$1]+set}" ]]; then printf '%s' "${DISPATCH_BODY_DEP_FRESH[$1]}"; return 0; fi
  if [[ -f "$f" ]] && read -r stamp memo < "$f" && [[ "$stamp" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - stamp < ${DEP_CHECK_SECONDS:-600} )); then printf '%s' "$memo"; return 0; fi
  fresh="$(dep_states "$1" 2>/dev/null | awk -F'\t' -v d="$1" '$1 == d { print $2; exit }' || true)"
  if [[ -n "$fresh" && "$fresh" != CLOSED && "$fresh" != MERGED ]]; then printf '%s %s\n' "$NOW_EPOCH" "$fresh" > "$f"; fi
  printf '%s' "$fresh"
}
dep_fresh_closed() { # predecessor → 0 only when a fresh GitHub read says CLOSED or MERGED; an unreadable read is not closed
  local fresh; fresh="$(dep_fresh_state "$1")"
  [[ "$fresh" == CLOSED || "$fresh" == MERGED ]]
}
unit_dep_dropped() { # unit dep → 0 when a supervisor reroute dropped dep for the unit (dropped_deps); any other blocker source asks this before it holds the unit
  [[ "$2" =~ ^[0-9]+$ ]] && jqf -e --arg id "$1" --argjson d "$2" 'any(.units[]; .id == $id and ((.dropped_deps // []) | index($d) != null))' "$UNITS" >/dev/null
}
