# Row 898: slow GitHub reads with the ledger lock released. Pattern: decide under the lock, run the call in
# this window, revalidate the row after the re-take, then write. phase_yield_lock_batch clears the warm
# tick-PR caches; this variant keeps them (a refill running in the window changes no PRs) so a per-unit
# window does not add one gh pr list per unit to the owning phase.
slow_call_yield() { # phase-name fn args… → the callback's rc, or 1 when the re-take was refused
  local rc=0 phase="$1"; shift
  # A caller that never held the lock (library-mode phase tests) must not gain one here: the
  # unconditional re-take below leaked a held lock into unlocked callers (row 898 round 2).
  if [[ "${SCHED_LOCK_HELD:-false}" != true ]]; then
    "$@"
    return $?
  fi
  release_scheduler_lock
  "$@" || rc=$?
  reacquire_scheduler_lock_timed || rc=1
  phase_mark "$phase"
  LIVE_WORKER_CACHE_UNTIL=0
  TICK_ACTIVE_FOOTPRINTS_VALID=false
  TICK_FOOTPRINT_CONFLICT_VALID=false
  return "$rc"
}

# retire_landed_pr_units's per-unit GitHub reads: PR state, the merged PR's mergeCommit, and the closed-PR
# issue route. The pure branch tests (ready-to-merge, awaiting-release marks) re-run under the lock at apply
# time; only the network answers travel through these globals.
retire_row_current() { # id pr → 0 while the unit row still matches the row the retire list was built from
  jqf -e --arg id "$1" --argjson pr "$2" 'any(.units[]; .id==$id and .pr==$pr
    and ((.stage | IN("closed","landed","merged","done","needs-human")) | not)
    and (.hold_handoff_waiting // false) == false)' "$UNITS" >/dev/null
}
RETIRE_STATE=""; RETIRE_MERGE_SHA=""; RETIRE_ROUTE_RC=0
retire_unit_collect() { # id pr → RETIRE_STATE / RETIRE_MERGE_SHA / RETIRE_ROUTE_RC; runs with the lock released
  local id="$1" pr="$2" state
  RETIRE_STATE="" RETIRE_MERGE_SHA="" RETIRE_ROUTE_RC=0
  state="$(pr_view "$pr" state)"
  RETIRE_STATE="$state"
  [[ -z "$state" ]] || TICK_PR_STATE["$pr"]="$state"
  case "$state" in
    MERGED)
      if jqf -e --arg id "$id" 'any(.units[]; .id == $id and .stage == "ready-to-merge"
          and ((.approved_sha // "") != "") and (.hotpatch // false) == false and (.supervisor_owned // false) == false)' "$UNITS" >/dev/null; then
        RETIRE_MERGE_SHA="$(gh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid // empty' 2>/dev/null)"
      fi ;;
    CLOSED)
      closed_unit_issue_route "$id" pr-closed || RETIRE_ROUTE_RC=$? ;;
  esac
  return 0
}
