# ---------- Existing-walk station (scheduler.sh --existing-walk) ----------
# Units already in the ledger waited for the full tick (a 636 s median gap, 1151 s p90, 2026-11-08/09) to be walked through intake's
# handoff block: register_new_issues 1, 43 s median per tick for about 38 rows, always a complete lap. The station runs that walk alone,
# on loop.sh's short cadence, under its own lock. The walk never holds the ledger lock across a row's GitHub reads: each ledger write
# takes the lock for that one write (units_update, set_unit), so the tick, the refill and the merge lane run between writes. lock_wait /
# lock_hold in the pass line sum those takes. The detached intake worker runs a stale walk before new-issue intake; when a pass is fresh,
# it reads what the station left: walked rows (INTAKE_EXISTING_WALKED, so new-issue intake still skips them) and waiting PRs/branches.
existing_walk_fresh() { # 0 = a station pass started within the freshness window, so the tick skips the existing walk
  local at; at="$(cat "$A/.existing-walk-epoch" 2>/dev/null)"
  [[ "$at" =~ ^[0-9]+$ ]] && (( $(date +%s) - at < ${AUTOPI_EXISTING_WALK_FRESH_SECONDS:-600} ))
}
existing_walked_load() { # tick: what the last finished station pass left, while that pass is fresh: its end time, the PRs and branches handoffs wait on, the rows walked
  local at prs branches n
  INTAKE_EXISTING_WALKED=()
  { IFS= read -r at && [[ "$at" =~ ^[0-9]+$ ]] && (( $(date +%s) - at < ${AUTOPI_EXISTING_WALK_FRESH_SECONDS:-600} )) || return 0
    IFS= read -r prs; IFS= read -r branches
    # handoff_pr_waiting reads these in the tick's later phases: a hotfix PR with no unit yet is held back only by this list.
    if jqf -e 'type == "array"' <<<"$prs" >/dev/null 2>&1; then HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$prs" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"; fi
    if jqf -e 'type == "array"' <<<"$branches" >/dev/null 2>&1; then HANDOFF_WAIT_BRANCHES="$(jqf -c --argjson add "$branches" '. + $add | unique' <<<"${HANDOFF_WAIT_BRANCHES:-[]}")"; fi
    while IFS= read -r n; do [[ "$n" =~ ^(0|[1-9][0-9]*)$ ]] && INTAKE_EXISTING_WALKED["$n"]=ok; done; } 2>/dev/null < "$A/.existing-walked" || :
}
ew_secs() { printf '%d.%d' "$(($1 / 1000000))" "$(($1 % 1000000 / 100000))"; } # microseconds as seconds with one decimal
existing_walk_tick_pass() {
  local old limit rc=0 gh_calls n tmp ok_rows=() GH_ETAG_DIR="$A/.gh-etag-existing-walk"
  cd "$ROOT" || { echo "scheduler: root $ROOT unavailable" >&2; return 1; }
  if ! mkdir "$EXISTING_WALK_LOCK" 2>/dev/null; then
    old="$(cat "$EXISTING_WALK_LOCK/pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then return 0; fi # a pass is still running
    rm -rf -- "$EXISTING_WALK_LOCK"
    mkdir "$EXISTING_WALK_LOCK" 2>/dev/null || return 0
  fi
  echo "$$" > "$EXISTING_WALK_LOCK/pid"
  date +%s > "$A/.existing-walk-epoch" # also when the pass cannot run: the tick must not start a second walker
  if [[ -e "$PAUSE_FILE" ]]; then
    say "existing-walk paused by $PAUSE_FILE: no pass" # the tick runs no intake while paused either
  elif ! state_schema_ok; then
    say "state schema invalid; existing-walk stopped before external actions"
  else
    limit="${AUTOPI_EXISTING_WALK_LIMIT_SECONDS:-240}"
    [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=240
    tick_gh_calls_begin
    MAIN_HEAD="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)"
    INTAKE_WALK_ROWS=0 INTAKE_WALK_LAP=false LOCK_WAIT_US=0 LOCK_HOLD_US=0
    ISSUE_INTAKE_EXISTING_BUDGET_SECONDS="$limit" register_new_issues 1 || rc=$?
    release_scheduler_lock # a write that failed midway must not leave the lock to the next pass
    for n in "${!INTAKE_EXISTING_WALKED[@]}"; do [[ "${INTAKE_EXISTING_WALKED[$n]}" == ok ]] && ok_rows+=("$n"); done
    tmp="$A/.existing-walked.$$"
    { date +%s; printf '%s\n%s\n' "${HANDOFF_WAIT_PRS:-[]}" "${HANDOFF_WAIT_BRANCHES:-[]}"; printf '%s\n' ${ok_rows[@]+"${ok_rows[@]}"}; } > "$tmp" && mv -f -- "$tmp" "$A/.existing-walked" || rm -f -- "$tmp"
    gh_calls="$(tick_gh_calls_count)"
    say "existing-walk done secs=$SECONDS rows=$INTAKE_WALK_ROWS lock_wait=$(ew_secs "$LOCK_WAIT_US") lock_hold=$(ew_secs "$LOCK_HOLD_US") lap_done=$INTAKE_WALK_LAP walked=${#ok_rows[@]} gh_calls=$gh_calls rc=$rc limit=${limit}s ended=$(date -u +%H:%M:%SZ)"
    rm -f -- "$GH_TICK_CALLS_FILE" "$TICK_INTAKE_READS_FILE" "$TICK_INTAKE_READS_FILE.lock" "$TICK_INTAKE_READS_FILE.reached" 2>/dev/null || :
  fi
  [[ "$(cat "$EXISTING_WALK_LOCK/pid" 2>/dev/null)" != "$$" ]] || rm -rf -- "$EXISTING_WALK_LOCK"
}
existing_walk_tick() {
  local TICK_STEP_LOCK_RESULT=""
  tick_step_lock_run existing_walk existing_walk_tick_pass "$@"
}
