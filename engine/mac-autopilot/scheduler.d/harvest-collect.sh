# Row 898: an ended worker's log is frozen, so its whole-log reads (usage reader, whole-log jq, footer
# greps, session usage) run with the ledger lock released through phase_yield_lock_batch; the results
# are applied under the lock only after the worker row is revalidated (same pid, unit, log and pid_start).
# Verdict-dependent slow calls (repair_head_class's ls-remote, the LANDED issue view and close) cannot be
# pre-collected without changing which calls run, so each takes its own yielded window at its call site.
declare -A HARVEST_COLLECT=()
declare -A HARVEST_REPAIR_CLS=()
declare -A HARVEST_LAND_ACCEPT=()
HARVEST_WORKER_BLOB=""
HARVEST_SLOW_RESULT=""

harvest_collect_key() { # worker-json → pid:unit:log, the row identity the collect blobs are keyed by
  printf '%s:%s:%s' "$(jqf -r '.pid // 0' <<<"$1")" "$(jqf -r '.unit // ""' <<<"$1")" "$(jqf -r '.log // ""' <<<"$1")"
}

harvest_row_revalidate() { # worker-json → 0 while the row is still the same unharvested worker; 1 skips it with one line
  local pid unit start log row got
  pid="$(jqf -r '.pid // 0' <<<"$1")"; unit="$(jqf -r '.unit // ""' <<<"$1")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0 # a row without a pid cannot be keyed; leave it to the loop's own filters
  start="$(jqf -r '.pid_start // ""' <<<"$1")"; log="$(jqf -r '.log // ""' <<<"$1")"
  row="$(jqf -c --argjson pid "$pid" --arg unit "$unit" '[.workers[] | select(.pid==$pid and .unit==$unit and .harvested!=true)][0] // empty' "$WORKERS" 2>/dev/null)" || row=""
  if [[ -z "$row" || "$(jqf -r '.log // ""' <<<"$row")" != "$log" ]]; then
    say "harvest skip unit=$unit pid=$pid: the worker row changed while the ledger lock was released"
    return 1
  fi
  [[ -z "$start" || "$(jqf -r '.pid_start // ""' <<<"$row")" == "$start" ]] || {
    say "harvest skip unit=$unit pid=$pid: the worker row was replaced while the ledger lock was released"
    return 1
  }
  return 0
}

harvest_blob_field() { # blob field → the collected string ("" when absent)
  jqf -r --arg k "$2" '.[$k] // empty' <<<"$1"
}

harvest_slow_yield() { # fn args… → run one slow harvest call with the ledger lock released, then re-take it.
  # The invalidation set matches scheduler_lock_yield_between_units minus tick_prs_changed: a refill that
  # runs inside this window changes no PRs, while clearing the warm list here would add one gh pr list per
  # worker to every pass (harvest_workers re-primes per finished implement/repair/land worker already).
  local rc=0
  release_scheduler_lock
  "$@" || rc=$?
  reacquire_scheduler_lock_timed || rc=1
  phase_mark harvest_workers
  LIVE_WORKER_CACHE_UNTIL=0
  TICK_ACTIVE_FOOTPRINTS_VALID=false
  TICK_FOOTPRINT_CONFLICT_VALID=false
  return "$rc"
}

harvest_worker_collect() { # worker-json ended → HARVEST_WORKER_BLOB; runs with the ledger lock released.
  # All variables are local: phase_yield_lock_batch keeps its own rc, and a draft variable here must not write over it.
  local w="$1" ended="$2" unit wtype report rep lg claude_impl=false
  local stream="" tk_footer="" mnf=false execution="" session_id="" final_msg="" limit_hit="" usage_raw=""
  unit="$(jqf -r '.unit // empty' <<<"$w")"
  wtype="$(jqf -r '.type // empty' <<<"$w")"
  report="$(jqf -r '.report // empty' <<<"$w")"; rep="$SUP/$report"
  lg="$SUP/$(jqf -r '.log // empty' <<<"$w")"
  [[ "$(jqf -r '.provider // empty' <<<"$w")" == claude && "$wtype" =~ ^(implement|repair)$ ]] && claude_impl=true
  # The session/token stream and the footer token count feed live-worker alerts too, so both modes read them.
  stream="$(python3 "$USAGE_READER" "$([[ "$claude_impl" == true ]] && echo claude-stream || echo codex-stream)" "$lg" 2>/dev/null || true)"
  tk_footer="$(tokens_of "$lg")"
  if [[ "$wtype" == implement || "$wtype" == repair ]]; then
    grep -Eiq 'model_not_found' "$lg" 2>/dev/null && mnf=true
  fi
  if [[ "$ended" == true ]]; then
    execution="$(jq -Rsc '[split("\n")[] | fromjson? | select(.type=="pipeline.execution")] | last // {}' "$lg" 2>/dev/null)"
    session_id="$(jqf -r '.session_id // empty' <<<"$stream")"
    [[ "$session_id" =~ $SESSION_RE ]] || session_id="$(grep -m1 -Eo 'session id: [[:xdigit:]-]{36}' "$lg" 2>/dev/null | sed 's/^session id: //' || true)"
    if [[ "$(jqf -r '.reason // empty' <<<"$execution")" == resume-startup-failed ]]; then
      # The fallback in harvest_workers clears the row's session before its own last resort, so the ledger id never wins here.
      [[ "$session_id" =~ $SESSION_RE ]] || session_id=""
    else
      [[ "$session_id" =~ $SESSION_RE ]] || session_id="$(jqf -r '.session_id // empty' <<<"$w")"
    fi
    [[ "$session_id" =~ $SESSION_RE ]] || session_id=""
    python3 "$USAGE_READER" codex-ingest "$lg" "$session_id" "$(jqf -r '.started // empty' <<<"$w")" "$BUDGET_EVENTS" >/dev/null 2>&1 || true
    if [[ ! -s "$rep" ]]; then
      final_msg="$(final_message_of "$lg")"
      limit_hit="$( { tail -n 40 "$lg"; cat "$rep.partial"; } 2>/dev/null | grep -m1 -oiE "$PROVIDER_LIMIT_RE" || true)"
    fi
    [[ "$claude_impl" == true ]] || usage_raw="$(session_usage_for_id "$session_id")"
  fi
  HARVEST_WORKER_BLOB="$(jqf -cn \
    --arg mode "$([[ "$ended" == true ]] && echo ended || echo live)" \
    --arg stream "$stream" --arg tk_footer "${tk_footer:-}" --arg mnf "$mnf" --arg execution "$execution" \
    --arg session_id "$session_id" --arg final_msg "$final_msg" --arg limit_hit "$limit_hit" --arg usage_raw "$usage_raw" \
    '{mode:$mode,stream:$stream,tk_footer:$tk_footer,mnf:$mnf,execution:$execution,session_id:$session_id,final_msg:$final_msg,limit_hit:$limit_hit,usage_raw:$usage_raw}')"
}

harvest_repair_head_class_collect() { # unit workdir → HARVEST_SLOW_RESULT = "<class> <head before the run>"
  HARVEST_SLOW_RESULT="$(repair_head_class "$1" "$2")"
}

harvest_land_acceptance_collect() { # issue → HARVEST_SLOW_RESULT = the acceptance block, "" when the body has none
  HARVEST_SLOW_RESULT="$(gh issue view "$1" --json number,title,body,state,labels 2>/dev/null | jqf -r '.body // ""' | acceptance_block_from_body || true)"
}

harvest_landed_issue_close() { # issue sha → the LANDED issue close, run with the ledger lock released
  gh issue close "$1" --comment "Landed on main as $2 through the autopilot direct-main lane (reviewed local commit, no PR)." >/dev/null 2>&1 || :
}
