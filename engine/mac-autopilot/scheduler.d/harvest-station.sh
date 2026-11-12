# ---------- Harvest station (scheduler.sh --harvest-station) ----------
# The full tick spent 128-215 s of its 822-1547 s in harvest_workers (17-19 gh calls) before it reached anything else, and held the
# ledger lock all that time. The station runs the harvest group alone, on loop.sh's short cadence, under its own lock:
# harvest_workers, the claim sweeps, self_check_harvest, precheck_harvest and recover_orphans (the group the refill already
# repeats in part). It snapshots worker and unit rows under SCHED_LOCK, runs harvest and independent reconciliations outside it,
# then commits each changed row under a short lock with compare-and-set. Claim mutations reacquire SCHED_LOCK before their claim lock;
# coord_reap_expired stays under SCHED_LOCK for expiry callbacks, and the result-file phases stay locked while reading and updating unit rows.
# The tick harvests itself only while no station
# pass started within AUTOPI_HARVEST_STATION_FRESH_SECONDS (an older loop.sh without the launcher, or a stuck station).
harvest_station_fresh() { # 0 = a station pass started within the freshness window, so the tick skips the harvest group
  local at; at="$(cat "$A/.harvest-station-epoch" 2>/dev/null)"
  [[ "$at" =~ ^[0-9]+$ ]] && (( $(date +%s) - at < ${AUTOPI_HARVEST_STATION_FRESH_SECONDS:-600} ))
}
hs_lock() { # take the ledger lock, waiting only until the pass deadline; the wait and the hold are logged per pass
  local t0=$SECONDS
  until acquire_scheduler_lock; do
    if (( SECONDS >= HARVEST_STATION_DEADLINE )); then HS_LOCK_WAIT=$((HS_LOCK_WAIT + SECONDS - t0)); return 1; fi
    sleep 0.05
  done
  HS_LOCK_WAIT=$((HS_LOCK_WAIT + SECONDS - t0)); HS_HOLD_FROM=$SECONDS
}
hs_unlock() {
  [[ "${SCHED_LOCK_HELD:-false}" == true ]] || return 0
  HS_LOCK_HOLD=$((HS_LOCK_HOLD + SECONDS - HS_HOLD_FROM))
  release_scheduler_lock
}
harvest_worker_cas_check() {
  [[ "${HARVEST_CAS_ACTIVE:-false}" == true ]] || return 0
  [[ "${HARVEST_CAS_STALE:-false}" != true ]] || return 1
  local current
  current="$(jqf -cS --argjson pid "$HARVEST_CAS_PID" --arg unit "$HARVEST_CAS_UNIT" \
    '[.workers[] | select(.pid==$pid and .unit==$unit)][0] // null' "$WORKERS")" \
    || { HARVEST_CAS_STALE=true; return 1; }
  [[ "$current" == "$HARVEST_CAS_WORKER_EXPECTED" ]] || { HARVEST_CAS_STALE=true; return 1; }
}
harvest_unit_cas_check() {
  [[ "${HARVEST_CAS_ACTIVE:-false}" == true ]] || return 0
  harvest_worker_cas_check || return 1
  [[ "$1" == "$HARVEST_CAS_UNIT" ]] || return 0
  local current
  current="$(jqf -cS --arg id "$1" '[.units[] | select(.id==$id)][0] // null' "$UNITS")" \
    || { HARVEST_CAS_STALE=true; return 1; }
  [[ "$current" == "$HARVEST_CAS_EXPECTED" ]] || { HARVEST_CAS_STALE=true; return 1; }
}
harvest_unit_cas_advance() {
  [[ "${HARVEST_CAS_ACTIVE:-false}" == true && "$1" == "$HARVEST_CAS_UNIT" ]] || return 0
  HARVEST_CAS_UNIT_SNAPSHOT="$(jqf -cS --arg id "$1" '[.units[] | select(.id==$id)][0] // null' "$UNITS")" \
    || { HARVEST_CAS_STALE=true; return 1; }
  HARVEST_CAS_EXPECTED="$HARVEST_CAS_UNIT_SNAPSHOT"
}
harvest_worker_cas_advance() {
  [[ "${HARVEST_CAS_ACTIVE:-false}" == true ]] || return 0
  HARVEST_CAS_WORKER_EXPECTED="$(jqf -cS --argjson pid "$HARVEST_CAS_PID" --arg unit "$HARVEST_CAS_UNIT" \
    '[.workers[] | select(.pid==$pid and .unit==$unit)][0] // null' "$WORKERS")" \
    || { HARVEST_CAS_STALE=true; return 1; }
}
workers_update() { # jq args; update only from the current workers ledger under one short lock
  local own_lock=false rc=0 tmp=""
  if [[ "${SCHED_LOCK_HELD:-false}" != true ]]; then
    if [[ "${HARVEST_STATION_ACTIVE:-false}" == true ]]; then hs_lock || return 1; else acquire_scheduler_lock_wait || return 1; fi
    own_lock=true
  fi
  if [[ "${HARVEST_CAS_ACTIVE:-false}" == true ]]; then harvest_unit_cas_check "$HARVEST_CAS_UNIT" || rc=1; fi
  if (( rc == 0 )); then
    tmp="$(mktemp "$WORKERS.update.XXXXXX")" || rc=1
    if (( rc == 0 )); then jqf "$@" "$WORKERS" > "$tmp" || rc=$?; fi
    if (( rc == 0 )) && ! cmp -s "$tmp" "$WORKERS"; then write_state "$WORKERS" < "$tmp" || rc=$?; fi
    if (( rc == 0 )); then harvest_worker_cas_advance || rc=$?; fi
  fi
  [[ -z "$tmp" ]] || rm -f -- "$tmp"
  if [[ "$own_lock" == true ]]; then if [[ "${HARVEST_STATION_ACTIVE:-false}" == true ]]; then hs_unlock; else release_scheduler_lock; fi; fi
  return "$rc"
}
coord_reconcile_scheduler_worker_locked() { # snapshot action; call only under the scheduler ledger lock
  local worker="$1" action="$2" key owner current expected
  key="$(jqf -r '.claim_key // empty' <<<"$worker")"
  owner="$(jqf -r '.claim_owner // empty' <<<"$worker")"
  current="$(jqf -cS --arg key "$key" --arg owner "$owner" '[.workers[] | select(.claim_key==$key and .claim_owner==$owner)][0] // null' "$WORKERS")" || return 1
  expected="$(jqf -cS . <<<"$worker")"
  [[ "$current" == "$expected" ]] || return 0
  case "$action" in
    release) coord_release "$key" "$owner" >/dev/null 2>&1 || : ;;
    renew) coord_renew "$key" "$owner" || say "claim renewal lost unit=$(jqf -r '.unit' <<<"$worker")" ;;
  esac
}
harvest_unit_snapshot() { # return the captured unit row during station harvest; otherwise read the ledger
  if [[ "${HARVEST_CAS_ACTIVE:-false}" == true && "$1" == "${HARVEST_CAS_UNIT:-}" ]]; then
    printf '%s\n' "$HARVEST_CAS_UNIT_SNAPSHOT"
  else
    jqf -c --arg id "$1" '[.units[] | select(.id==$id)][0] // {}' "$UNITS"
  fi
}
hs_timed() { # name command...: add its seconds and gh calls to the pass totals
  local name="$1" t0=$SECONDS g0 rc=0; shift
  g0="$(tick_gh_calls_count)"
  "$@" || rc=$?
  HS_SECS[$name]=$(( ${HS_SECS[$name]:-0} + SECONDS - t0 ))
  HS_GH[$name]=$(( ${HS_GH[$name]:-0} + $(tick_gh_calls_count) - g0 ))
  return "$rc"
}
hs_unharvested() { # pid:unit -> 0 while the ledger still holds that worker as unharvested
  jqf -e --argjson pid "${1%%:*}" --arg unit "${1#*:}" \
    '[.workers[] | select(.pid == $pid and .unit == $unit and .harvested != true)] | length > 0' "$WORKERS" >/dev/null 2>&1
}
hs_candidates() { # pid:unit lines from the locked worker snapshot. Process checks happen after the lock is released.
  local w
  while read -r w; do
    if harvest_worker_alive "$w" && [[ "$1" != true ]]; then continue; fi
    printf '%s:%s\n' "$(jqf -r .pid <<<"$w")" "$(jqf -r .unit <<<"$w")"
  done < <(jqf -c '.[]' <<<"${2:-[]}" 2>/dev/null)
}
harvest_station_pass() { # snapshot under lock; harvest and process checks outside it; CAS each ledger write
  local key live_due=false last live_every="${AUTOPI_HARVEST_LIVE_SECONDS:-900}" workers_snapshot worker_snapshot unit harvest_this
  [[ "$live_every" =~ ^[1-9][0-9]*$ ]] || live_every=900
  last="$(cat "$A/.harvest-live-epoch" 2>/dev/null)"
  if [[ ! "$last" =~ ^[0-9]+$ ]] || (( $(date +%s) - last >= live_every )); then live_due=true; date +%s > "$A/.harvest-live-epoch"; fi
  hs_lock || { HS_DEFERRED=$((HS_DEFERRED + 1)); return 0; }
  workers_snapshot="$(jqf -c '[.workers[] | select(.harvested != true)]' "$WORKERS" 2>/dev/null || echo '[]')"
  hs_unlock
  while IFS= read -r key; do
    HS_WORKERS=$((HS_WORKERS + 1))
    if (( SECONDS >= HARVEST_STATION_DEADLINE )); then HS_DEFERRED=$((HS_DEFERRED + 1)); continue; fi
    hs_lock || { HS_DEFERRED=$((HS_DEFERRED + 1)); continue; }
    worker_snapshot="$(jqf -c --argjson pid "${key%%:*}" --arg unit "${key#*:}" \
      '[.workers[] | select(.pid==$pid and .unit==$unit and .harvested != true)][0] // empty' "$WORKERS" 2>/dev/null)"
    harvest_this=false
    if [[ -n "$worker_snapshot" ]]; then
      unit="${key#*:}"
      HARVEST_CAS_PID="${key%%:*}"; HARVEST_CAS_UNIT="$unit"
      HARVEST_CAS_WORKER_EXPECTED="$(jqf -cS . <<<"$worker_snapshot")"
      HARVEST_CAS_UNIT_SNAPSHOT="$(jqf -cS --arg id "$unit" '[.units[] | select(.id==$id)][0] // null' "$UNITS")"
      HARVEST_CAS_EXPECTED="$HARVEST_CAS_UNIT_SNAPSHOT"
      HARVEST_CAS_STALE=false; HARVEST_CAS_ACTIVE=true; harvest_this=true
    fi
    hs_unlock
    [[ "$harvest_this" == true ]] || continue
    hs_timed harvest_workers harvest_workers false "$key" "$worker_snapshot" || :
    HARVEST_CAS_ACTIVE=false
    hs_lock || { HS_DEFERRED=$((HS_DEFERRED + 1)); continue; }
    if [[ "$HARVEST_CAS_STALE" == true ]]; then
      HS_DEFERRED=$((HS_DEFERRED + 1))
    else
      hs_unharvested "$key" || HS_HARVESTED=$((HS_HARVESTED + 1))
    fi
    hs_unlock
  done < <(hs_candidates "$live_due" "$workers_snapshot")
  hs_lock || return 0
  hs_timed coord_reap coord_reap_expired || say "claim expiry sweep incomplete; unreadable claims remain fail-closed"
  hs_unlock
  hs_timed coord_systemd coord_reconcile_systemd_workers || say "issue-pipeline claim reconciliation incomplete; unknown claims remain fail-closed"
  hs_timed coord_scheduler coord_reconcile_scheduler_workers || say "scheduler claim reconciliation incomplete; unknown claims remain fail-closed"
  hs_lock || return 0
  hs_timed self_check_harvest self_check_harvest || :
  hs_timed precheck_harvest precheck_harvest || :
  hs_timed recover_orphans recover_orphans || :
  hs_unlock
}
harvest_station_tick() {
  local old limit gh_calls name phases="" HARVEST_STATION_DEADLINE=0 GH_ETAG_DIR="$A/.gh-etag-harvest"
  local HS_LOCK_WAIT=0 HS_LOCK_HOLD=0 HS_HOLD_FROM=0 HS_WORKERS=0 HS_HARVESTED=0 HS_DEFERRED=0
  local HARVEST_STATION_ACTIVE=true HARVEST_CAS_ACTIVE=false HARVEST_CAS_STALE=false HARVEST_CAS_UNIT="" HARVEST_CAS_PID=""
  local HARVEST_CAS_EXPECTED=null HARVEST_CAS_WORKER_EXPECTED=null HARVEST_CAS_UNIT_SNAPSHOT=null
  local -A HS_SECS=() HS_GH=()
  cd "$ROOT" || { echo "scheduler: root $ROOT unavailable" >&2; return 1; }
  if ! mkdir "$HARVEST_STATION_LOCK" 2>/dev/null; then
    old="$(cat "$HARVEST_STATION_LOCK/pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then return 0; fi # a pass is still running
    rm -rf -- "$HARVEST_STATION_LOCK"
    mkdir "$HARVEST_STATION_LOCK" 2>/dev/null || return 0
  fi
  echo "$$" > "$HARVEST_STATION_LOCK/pid"
  date +%s > "$A/.harvest-station-epoch" # also when the pass cannot run: the tick must not start a second harvester
  if ! state_schema_ok; then
    say "state schema invalid; harvest station stopped before external actions"
  else
    limit="${AUTOPI_HARVEST_STATION_LIMIT_SECONDS:-240}"
    [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=240
    HARVEST_STATION_DEADLINE=$((SECONDS + limit))
    tick_gh_calls_begin
    MAIN_HEAD="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)"
    harvest_station_pass || :
    hs_unlock
    gh_calls="$(tick_gh_calls_count)"
    for name in harvest_workers coord_reap coord_systemd coord_scheduler self_check_harvest precheck_harvest recover_orphans; do
      [[ -n "${HS_SECS[$name]:-}" ]] && phases+="${phases:+,}${name}:${HS_SECS[$name]}s/${HS_GH[$name]}gh"
    done
    # A PAUSE does not stop it: the paused tick harvests too, and a harvest dispatches nothing.
    say "harvest-station done secs=$SECONDS gh_calls=$gh_calls lock_wait=$HS_LOCK_WAIT lock_hold=$HS_LOCK_HOLD workers=$HS_WORKERS harvested=$HS_HARVESTED deferred=$HS_DEFERRED limit=${limit}s ended=$(date -u +%H:%M:%SZ) phases=${phases:-none}"
    rm -f -- "$GH_TICK_CALLS_FILE" "$TICK_INTAKE_READS_FILE" "$TICK_INTAKE_READS_FILE.lock" "$TICK_INTAKE_READS_FILE.reached" 2>/dev/null || :
  fi
  [[ "$(cat "$HARVEST_STATION_LOCK/pid" 2>/dev/null)" != "$$" ]] || rm -rf -- "$HARVEST_STATION_LOCK"
}

report_only_pr_requeue_harvest() { # unit worker-json report-name report-path type → handle a report-only supervisor requeue or return 1
  local unit="$1" worker="$2" report_name="$3" report_path="$4" type="$5" pr head started unit_json current_head gate_report_name gate_report_path reason runs run run_count repo
  [[ "$type" == implement || "$type" == repair ]] || return 1
  [[ "$(jqf -r '.incident_report_resume // false' <<<"$worker")" != true ]] || return 1
  pr="$(unit_field "$unit" '.pr // empty')"
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] || return 1
  head="$(jqf -r '.pr_head // empty' <<<"$worker")"; started="$(jqf -r '.started // empty' <<<"$worker")"
  [[ "$head" =~ $SHA_RE && -n "$started" ]] || return 1
  unit_json="$(jqf -c --arg id "$unit" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
  jqf -e --arg type "$type" --arg started "$started" '
    (.history // []) as $h |
    ([$h | to_entries[] | select(.value.stage=="supervisor-requeue") | .key] | last // -1) as $r |
    ([$h | to_entries[] | select(.value.stage=="write-start" and .value.work_type==$type and .value.at==$started) | .key] | last // -1) as $w |
    $r >= 0 and $w > $r
    and (($h[$r].result // "") | ascii_downcase | contains("requeue"))
    and (($h[$r].result // "") | ascii_downcase | test("report[ -]only"))
  ' <<<"$unit_json" >/dev/null 2>&1 || return 1
  current_head="$(jqf -r --argjson pr "$pr" '[.[] | select(.number==$pr) | .headRefOid][0] // empty' <<<"${TICK_PRS:-[]}" 2>/dev/null || true)"
  [[ "$current_head" == "$head" ]] || return 1
  report_only_requeue_handled=true
  gate_report_name="$report_name"; gate_report_path="$report_path"
  if [[ "$type" == repair ]]; then
    gate_report_name="$(jqf -r --arg n "$report_name" '.implementation_report // $n' <<<"$unit_json")"
    gate_report_path="$SUP/$gate_report_name"
  fi
  set_unit "$unit" ".implementation_report=$(js "$gate_report_name")" || { to_supervisor "$unit" "could not save report-only requeue report $gate_report_name"; return 0; }
  reason="$(decision_log_gate_reason "$unit_json" "$gate_report_path")"
  [[ -n "$reason" ]] || reason="$(how_why_gate_reason "$unit_json" "$gate_report_path")"
  [[ -n "$reason" ]] || reason="$(incident_report_gate_reason "$unit_json" "$gate_report_path")"
  if [[ -n "$reason" ]]; then
    to_supervisor "$unit" "report-only requeue report $gate_report_name failed the report gate: $reason"
    return 0
  fi
  if [[ "$(unit_field "$unit" '.ci_rerun_sha // empty')" != "$head" ]]; then
    runs="$(gh run list --commit "$head" --json databaseId,conclusion --jq '.[] | select(.conclusion=="failure" or .conclusion=="cancelled") | .databaseId' 2>/dev/null)" \
      || { to_supervisor "$unit" "could not list failed or cancelled CI runs for unchanged head $head"; return 0; }
    if [[ -n "$runs" ]]; then
      run_count=0
      for run in $runs; do
        [[ "$run" =~ ^[0-9]+$ ]] || { to_supervisor "$unit" "invalid CI run id for unchanged head $head"; return 0; }
        run_count=$((run_count + 1))
      done
      repo="${REPO:-}"; [[ -n "$repo" ]] || repo='{owner}/{repo}'
      set_unit "$unit" "$(hist report-only-ci-rerun "head $head runs=$run_count") | .ci_rerun_sha=$(js "$head")" \
        || { to_supervisor "$unit" "could not record CI rerun for unchanged head $head"; return 0; }
      for run in $runs; do
        if ! gh api -X POST "repos/$repo/actions/runs/$run/rerun" >/dev/null 2>&1; then
          to_supervisor "$unit" "report-only requeue CI rerun failed for unchanged head $head run $run"
          return 0
        fi
      done
    fi
  fi
  set_unit "$unit" "$(hist report-only-requeue-delivered "$head") | .implementation_report=$(js "$gate_report_name") | .approved_sha=null | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
  say "report-only requeue unit=$unit PR#$pr passed the report gate; sent unchanged head $head to review"
}

harvest_implement_worker_result() { # unit worker-type report-path report-name local-only → preserve the existing direct-main/PR/fallback routes
  local unit="$1" type="$2" report_path="$3" report_name="$4" local_only="$5" decision
  if [[ "$type" == implement && -z "$(unit_field "$unit" .pr)" && "$(unit_field "$unit" .lane)" == direct-main ]]; then
    harvest_prless_implement "$unit" "$report_path" "$local_only"
  elif [[ "$type" == implement && -z "$(unit_field "$unit" .pr)" && "$(unit_field "$unit" .lane)" == pr ]]; then
    harvest_pr_implement "$unit" "$report_path"
  else
    decision="$(decision_entry 'Hand off delivered worker result to supervisor' 'the current unit state has no automatic delivery transition' "$report_name" '["Advance the unit without supervisor handling"]' scheduler)"
    set_unit "$unit" "$(hist delivered "" "$decision") | (.stage=\"supervisor-review\")"
    echo "[$STAMP] IMPL-DELIVERED unit=$unit report=$(basename "$report_path")" >> "$A/alerts/events.md"
  fi
}
