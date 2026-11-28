#!/usr/bin/env bash
# Single-host ticket claims shared by the issue feeder and autopilot scheduler.
# Source through lib.sh; writes are serialized by flock and published by rename.

declare -F pid_start_id >/dev/null || source "$(dirname -- "${BASH_SOURCE[0]}")/proc.sh" # lazy: tests source coord.sh alone

COORD_DIR="${AGENT_HOME:?AGENT_HOME must be set before loading coord.sh}/coord/claims"
COORD_LEASE_SECONDS="${ZF_COORD_LEASE_SECONDS:-900}"
# Keep released claims briefly for inspection; readers treat them as absent and sweeps scan every claim file.
COORD_RELEASED_RETAIN_SECONDS="${ZF_COORD_RELEASED_RETAIN_SECONDS:-3600}"
COORD_OWNER_SEQ=0
COORD_REMOTE_REPO=""
COORD_REMOTE_OID=""
COORD_REMOTE_EXPIRED=0
source "$(dirname -- "${BASH_SOURCE[0]}")/coord/checkpoint.sh"

coord_now_s() {
  local now
  if [[ -n "${ZF_COORD_CLOCK_FILE:-}" ]]; then
    [[ -r "$ZF_COORD_CLOCK_FILE" ]] || return 3
    IFS= read -r now < "$ZF_COORD_CLOCK_FILE" || return 3
  else
    now="$(date +'%s')" || return 3
  fi
  [[ "$now" =~ ^[0-9]+$ ]] || return 3
  printf '%s\n' "$now"
}

coord_issue_key() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || return 2
  printf 'issue-%s\n' "$1"
}

coord_unit_key() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  printf 'unit-%s\n' "$1"
}

coord_new_owner() {
  local now
  now="$(coord_now_s)" || return 3
  COORD_OWNER_SEQ=$((COORD_OWNER_SEQ + 1))
  printf 'owner-%s-%s-%s-%s\n' "${BASHPID:-$PPID}" "$COORD_OWNER_SEQ" "$RANDOM" "$now"
}

coord_process_start_ticks_into() { # pid -> COORD_START_TICKS with no subshell: the ledger lock poll calls it per try
  local pid="${1:-}"
  COORD_START_TICKS=""
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  pid_start_id_into "$pid" 2>/dev/null || return 1
  [[ "$PID_START_ID" =~ ^[0-9]+$ ]] || return 1
  COORD_START_TICKS="$PID_START_ID"
}
coord_process_start_ticks() { # pid -> /proc start ticks, distinguishing a reused PID
  coord_process_start_ticks_into "${1:-}" && printf '%s\n' "$COORD_START_TICKS"
}

coord_issue_live_worker() { # issue runtime-dir -> 0 live scheduler worker / 1 none / 3 unknown
  local issue="${1:-}" runtime="${2:-}" pids pid expected_start current_start workers units
  workers="$runtime/workers.json" units="$runtime/units.json"
  [[ "$issue" =~ ^[1-9][0-9]*$ && -n "$runtime" ]] || return 2
  [[ -r "$workers" && -r "$units" ]] || { echo "coord_live_worker: scheduler ledger unavailable issue=$issue" >&2; return 3; }
  jq -e 'type=="object" and (.workers|type)=="array"
    and all(.workers[]; (.pid|type)=="number" and .pid>0 and .pid==(.pid|floor) and (.unit|type)=="string"
      and ((has("pid_start")|not) or (.pid_start|type)=="number" and .pid_start>=0 and .pid_start==(.pid_start|floor)))' \
    "$workers" >/dev/null 2>&1 || { echo "coord_live_worker: worker ledger malformed issue=$issue" >&2; return 3; }
  jq -e 'type=="object" and (.units|type)=="array"
    and all(.units[]; (.id|type)=="string")' \
    "$units" >/dev/null 2>&1 || { echo "coord_live_worker: unit ledger malformed issue=$issue" >&2; return 3; }
  pids="$(jq -r --arg issue "$issue" --slurpfile units "$units" '
    .workers[] | select(.harvested!=true and .lease_expired!=true) as $w
    | ($w.issue // ([$units[0].units[] | select(.id==$w.unit) | .issue][0] // "")) as $worker_issue
    | select(($worker_issue|tostring)==$issue) | [.pid, (.pid_start // "")] | @tsv
  ' "$workers" 2>/dev/null)" || { echo "coord_live_worker: issue lookup failed issue=$issue" >&2; return 3; }
  while IFS=$'\t' read -r pid expected_start; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      if [[ "$expected_start" =~ ^[0-9]+$ ]]; then
        current_start="$(coord_process_start_ticks "$pid" 2>/dev/null || true)"
        [[ "$current_start" == "$expected_start" ]] || continue
      fi
      return 0
    fi
  done <<<"$pids"
  return 1
}

_coord_paths() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  COORD_FILE="$COORD_DIR/$1.json"
  COORD_LOCK_FILE="$COORD_DIR/$1.lock"
}

_coord_read_locked() {
  local key="$1" record
  COORD_RECORD=""
  [[ -e "$COORD_FILE" ]] || return 1
  [[ -r "$COORD_FILE" ]] || { echo "coord_read: claim unreadable key=$key" >&2; return 3; }
  record="$(cat -- "$COORD_FILE")" || { echo "coord_read: claim read failed key=$key" >&2; return 3; }
  jq -e --arg key "$key" '
    type == "object" and .version == 1 and .key == $key
    and ((.owner == null) or (.owner | type == "string" and length > 0))
    and (.owner_kind | type == "string" and length > 0)
    and (.subject | type == "string")
    and (.unit | type == "string" and length > 0 and test("^[A-Za-z0-9_.@:-]+$"))
    and (.stage | type == "string" and length > 0)
    and (.expires_at | type == "number" and floor == .)
    and ((has("pid") | not) or (.pid | type == "number" and floor == . and . > 0))
    and ((has("pid_start") | not) or (.pid_start | type == "number" and floor == . and . >= 0))
    and (if has("intents") then .intents | type == "object" and all(to_entries[];
      (.key | type == "string" and test("^[A-Za-z0-9._:/@+.-]+$"))
      and (.value | type == "object" and (.kind | IN("merge","push","revert","deploy","mail","comment"))
        and (.class | IN("idempotent","once")) and (.state | IN("pending","done","unknown","cleared"))
        and (.gen | type == "number" and floor == . and . >= 1) and (.run | type == "string" and length > 0)
        and ((has("started_at") | not) or (.started_at | type == "number" and floor == . and . >= 0))
        and ((has("completed_seq") | not) or (.completed_seq | type == "number" and floor == . and . >= 1))
        and ((has("completed_at") | not) or (.completed_at | type == "number" and floor == . and . >= 0))
        and ((has("reason") | not) or (.reason | type == "string")))
    ) else true end)
  ' <<<"$record" >/dev/null 2>&1 || { echo "coord_read: malformed or unsupported claim key=$key" >&2; return 3; }
  COORD_RECORD="$record"
  [[ "$(jq -r '.owner // empty' <<<"$record")" ]] || return 1
  return 0
}

_coord_write_locked() {
  local key="$1" record="$2" tmp
  tmp="$(mktemp "$COORD_DIR/.claim.XXXXXX")" || { echo "coord_write: temp file failed key=$key" >&2; return 1; }
  if ! jq -e --arg key "$key" 'type == "object" and .version == 1 and .key == $key' \
      <<<"$record" >/dev/null 2>&1 || ! printf '%s\n' "$record" >"$tmp"; then
    rm -f -- "$tmp"
    echo "coord_write: claim serialization failed key=$key" >&2
    return 1
  fi
  chmod 600 "$tmp" && mv -f -- "$tmp" "$COORD_FILE" || {
    rm -f -- "$tmp"
    echo "coord_write: atomic claim replace failed key=$key" >&2
    return 1
  }
}

coord_remote_enabled() { [[ "${ZF_COORD:-off}" == on ]]; }

coord_remote_active() {
  local issue="${2:-}" key status
  coord_remote_enabled || return 1
  key="$(coord_issue_key "$issue")" || return 2
  coord_remote_refresh || return 3
  if _coord_remote_cached_read "$key"; then return 0; else status=$?; fi
  return "$status"
}

coord_init() { coord_remote_enabled || return 0; coord_remote_init; }
coord_refresh() { coord_remote_enabled || return 0; coord_remote_refresh "${1:-}"; }



_coord_expire_locked() {
  local key="$1" record="$COORD_RECORD" kind now released unit stage state
  kind="$(jq -r '.owner_kind' <<<"$record")"
  if [[ "$kind" == systemd-worker ]]; then
    unit="$(jq -r '.unit // empty' <<<"$record")"
    stage="$(jq -r '.stage // empty' <<<"$record")"
    [[ -n "$unit" && "$stage" != release ]] || { echo "coord_expire: unsafe systemd owner key=$key" >&2; return 3; }
    [[ "$unit" == *.service ]] || unit="$unit.service"
    state="$(systemctl --user show "$unit" --property=ActiveState --value 2>/dev/null)" \
      || { echo "coord_expire: systemd state unknown key=$key" >&2; return 3; }
    case "$state" in
      active|activating|deactivating|reloading)
        systemctl --user stop "$unit" >/dev/null 2>&1 || { echo "coord_expire: could not stop stale unit key=$key" >&2; return 3; }
        state="$(systemctl --user show "$unit" --property=ActiveState --value 2>/dev/null)" \
          || { echo "coord_expire: stopped unit state unknown key=$key" >&2; return 3; }
        [[ "$state" == inactive || "$state" == failed || "$state" == dead ]] \
          || { echo "coord_expire: stale unit remains active key=$key" >&2; return 3; }
        ;;
      inactive|failed|dead) ;;
      *) echo "coord_expire: systemd state unknown key=$key" >&2; return 3 ;;
    esac
  fi
  if [[ "$kind" == scheduler-worker ]] && ! declare -F coord_on_expire >/dev/null; then
    echo "coord_expire: scheduler claim needs its footprint owner key=$key" >&2
    return 3
  fi
  if declare -F coord_on_expire >/dev/null && ! coord_on_expire "$record"; then
    echo "coord_expire: owner cleanup failed key=$key" >&2
    return 3
  fi
  now="$(coord_now_s)"
  released="$(jq -c --argjson now "$now" '.last_owner=.owner | .owner=null | .expires_at=0 | .released_at=$now | .release_reason="lease-expired"' <<<"$record")" \
    || return 3
  _coord_write_locked "$key" "$released" || { echo "coord_expire: could not publish released claim key=$key" >&2; return 3; }
}

coord_read() { # key -> JSON / exit 1 confirmed absent / exit 3 unknown
  local key="${1:-}" lock_fd rc now expires
  if coord_remote_enabled; then
    if _coord_remote_read "$key"; then printf '%s\n' "$COORD_RECORD"; return 0; else return $?; fi
  fi
  _coord_paths "$key" || return 2
  mkdir -p -- "$COORD_DIR" || { echo "coord_read: claim directory unavailable" >&2; return 3; }
  exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  _coord_read_locked "$key"; rc=$?
  if (( rc == 0 )); then
    now="$(coord_now_s)"
    expires="$(jq -r '.expires_at' <<<"$COORD_RECORD")"
    if (( expires <= now )); then
      _coord_expire_locked "$key" || rc=$?
      (( rc == 0 )) && rc=1
    fi
  fi
  (( rc == 0 )) && printf '%s\n' "$COORD_RECORD"
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  return "$rc"
}

coord_acquire() { # key owner kind subject unit stage; exit 0 acquired / 1 held / 3 unknown
  local key="${1:-}" owner="${2:-}" kind="${3:-}" subject="${4:-}" unit="${5:-}" stage="${6:-}"
  local pid="${7:-}" pid_start="${8:-}"
  local lock_fd rc now lease record old_intents='{}' held=0 restore_required=0 restore_record="" reconcile_required=0
  [[ -n "$owner" && -n "$kind" ]] || return 2
  if [[ -n "$pid" || -n "$pid_start" ]]; then
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid_start" =~ ^[0-9]+$ ]] || return 2
  fi
  [[ "$COORD_LEASE_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "coord_acquire: invalid lease duration" >&2; return 3; }
  if coord_remote_enabled; then
    _coord_paths "$key" || return 2
    mkdir -p -- "$COORD_DIR" || return 3
    exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
    flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
    if coord_control_allows_acquire; then
      if _coord_remote_acquire "$key" "$owner" "$kind" "$subject" "$unit" "$stage"; then rc=0; else rc=$?; fi
    else
      rc=$?
    fi
    if (( rc == 0 )); then
      _coord_remote_held_write "$key" "$owner" "$COORD_REMOTE_OID" "$COORD_RECORD" "$pid" "$pid_start" || rc=3
      if (( rc == 0 )) && declare -F effect_reconcile >/dev/null \
        && jq -e 'any((.intents // {})[]?; .state == "pending")' <<<"$COORD_RECORD" >/dev/null 2>&1; then
        reconcile_required=1
      fi
      if (( rc == 0 )) && [[ "${COORD_REMOTE_RESTORE_REQUIRED:-0}" == 1 ]]; then
        restore_required=1
        restore_record="$COORD_RECORD"
      fi
    fi
    flock -u "$lock_fd" || :
    exec {lock_fd}>&-
    if (( rc == 0 && restore_required == 1 )); then
      if coord_checkpoint_restore "$restore_record"; then
        :
      else
        echo "coord_acquire: checkpoint restore failed key=$key" >&2
        coord_release "$key" "$owner" >/dev/null 2>&1 || :
        coord_checkpoint_alert "$restore_record" || echo "coord_acquire: checkpoint restore alert failed key=$key" >&2
        return 3
      fi
    fi
    if (( rc == 0 && reconcile_required == 1 )); then
      if ZF_COORD_OWNER="$owner" effect_reconcile "$key"; then
        if _coord_remote_read "$key"; then
          _coord_remote_held_write "$key" "$owner" "$COORD_REMOTE_OID" "$COORD_RECORD" || return 3
        else
          return 3
        fi
      else
        return $?
      fi
    fi
    return "$rc"
  fi
  _coord_paths "$key" || return 2
  mkdir -p -- "$COORD_DIR" || { echo "coord_acquire: claim directory unavailable" >&2; return 3; }
  exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  _coord_read_locked "$key"; rc=$?
  if (( rc == 0 )); then
    now="$(coord_now_s)"
    if (( $(jq -r '.expires_at' <<<"$COORD_RECORD") <= now )); then
      old_intents="$(jq -ce '(.intents // {}) | if type == "object" then . else error end' <<<"$COORD_RECORD")" || rc=3
      (( rc != 0 )) || _coord_expire_locked "$key" || rc=$?
      if (( rc == 0 )); then rc=1; fi
    else
      held=1
    fi
  elif (( rc == 1 )) && [[ -n "$COORD_RECORD" ]]; then
    old_intents="$(jq -ce '(.intents // {}) | if type == "object" then . else error end' <<<"$COORD_RECORD")" || rc=3
  fi
  if (( held == 1 )); then
    rc=1
  elif (( rc == 1 )); then
    now="$(coord_now_s)"; lease="$COORD_LEASE_SECONDS"
    if record="$(jq -cn --arg key "$key" --arg owner "$owner" --arg kind "$kind" \
      --arg subject "$subject" --arg unit "$unit" --arg stage "$stage" \
      --argjson now "$now" --argjson lease "$lease" \
      '{version:1,key:$key,owner:$owner,owner_kind:$kind,subject:$subject,unit:$unit,stage:$stage,
        acquired_at:$now,renewed_at:$now,expires_at:($now+$lease)}')"; then
      if record="$(jq -cn --argjson record "$record" --argjson intents "$old_intents" '$record + {intents:$intents}')"; then
        if jq -e 'any((.intents // {})[]?; .state == "pending")' <<<"$record" >/dev/null 2>&1; then
          reconcile_required=1
        fi
        if _coord_write_locked "$key" "$record"; then rc=0; else rc=3; fi
      else
        rc=3
      fi
    else
      rc=3
    fi
  elif (( rc == 0 )); then
    rc=1
  fi
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  if (( rc == 0 && reconcile_required == 1 )) && declare -F effect_reconcile >/dev/null; then
    ZF_COORD_OWNER="$owner" effect_reconcile "$key" || return $?
  fi
  return "$rc"
}

coord_acquire_feeder() {
  local key="$1" owner="$2" subject="$3" unit="$4" stage="$5"
  local pid="${BASHPID:-$$}" pid_start
  pid_start="$(coord_process_start_ticks "$pid" 2>/dev/null)" || return 3
  coord_acquire "$key" "$owner" feeder "$subject" "$unit" "$stage" "$pid" "$pid_start"
}

coord_acquire_many() { # owner kind unit stage issue...; rolls back partial batch reservations
  local owner="$1" kind="$2" unit="$3" stage="$4" issue key status
  shift 4
  local -a acquired=()
  local -A seen=()
  for issue in "$@"; do
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] || continue
    [[ -n "${seen[$issue]:-}" ]] && continue
    seen["$issue"]=1
    key="$(coord_issue_key "$issue")" || return 2
    if coord_acquire "$key" "$owner" "$kind" "$issue" "$unit" "$stage"; then
      acquired+=("$issue")
    else
      status=$?
      coord_release_many "$owner" "${acquired[@]}" >/dev/null 2>&1 || :
      return "$status"
    fi
  done
  ((${#acquired[@]} > 0))
}

coord_release_many() { # owner issue...; conditional release of every batch member
  local owner="$1" issue key status=0 rc
  shift
  for issue in "$@"; do
    key="$(coord_issue_key "$issue")" || { status=2; continue; }
    coord_release "$key" "$owner" || { rc=$?; (( rc == 1 )) || status=3; }
  done
  return "$status"
}

coord_with_scheduler_lock() { # run a short ledger read or claim mutation without reversing ledger -> claim lock order
  local own_lock=false station_lock=false rc=0
  if [[ "${SCHED_LOCK_HELD:-false}" != true ]]; then
    if [[ "${HARVEST_STATION_ACTIVE:-false}" == true ]] && declare -F hs_lock >/dev/null; then
      hs_lock || return 3; own_lock=true; station_lock=true
    elif declare -F acquire_scheduler_lock_wait >/dev/null; then
      acquire_scheduler_lock_wait || return 3; own_lock=true
    fi
  fi
  "$@" || rc=$?
  if [[ "$own_lock" == true ]]; then
    if [[ "$station_lock" == true ]]; then hs_unlock; else release_scheduler_lock; fi
  fi
  return "$rc"
}
coord_reconcile_systemd_workers() { # heartbeat active issue-pipeline transient units; release inactive ones
  local file key rc record kind unit state owner stage unknown=0
  mkdir -p -- "$COORD_DIR" || return 3
  for file in "$COORD_DIR"/*.json; do
    [[ -e "$file" ]] || continue
    key="${file##*/}"; key="${key%.json}"
    if coord_read "$key" >/dev/null; then
      record="$COORD_RECORD"
    else
      rc=$?
      (( rc == 3 )) && unknown=1
      continue
    fi
    kind="$(jq -r '.owner_kind' <<<"$record")"
    [[ "$kind" == systemd-worker ]] || continue
    owner="$(jq -r '.owner' <<<"$record")"
    unit="$(jq -r '.unit // empty' <<<"$record")"
    stage="$(jq -r '.stage // empty' <<<"$record")"
    [[ "$unit" == *.service ]] || unit="$unit.service"
    state="$(systemctl --user show "$unit" --property=ActiveState --value 2>/dev/null)" || { unknown=1; continue; }
    case "$state" in
      active|activating|deactivating|reloading)
        coord_with_scheduler_lock coord_renew "$key" "$owner" || { rc=$?; (( rc == 3 )) && unknown=1; }
        ;;
      inactive|failed|dead)
        # A claim is taken before systemd-run starts the unit (admission can queue it ~20s); 07:46Z 10-30 a concurrent tick released the advisor-batch claim in that gap.
        (( $(coord_now_s) - $(jq -r '.renewed_at // 0' <<<"$record") < 120 )) && continue
        coord_with_scheduler_lock coord_release "$key" "$owner" || { rc=$?; (( rc == 3 )) && unknown=1; }
        ;;
      *) unknown=1 ;;
    esac
  done
  (( unknown == 0 ))
}

coord_renew() { # key owner [local pid [pid-start-ticks]]; a lease that has already expired cannot be revived
  local key="${1:-}" owner="${2:-}" pid="${3:-}" pid_start="${4:-}" lock_fd rc now expires record
  [[ "$COORD_LEASE_SECONDS" =~ ^[1-9][0-9]*$ ]] || return 3
  [[ -z "$pid" || "$pid" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ -z "$pid_start" || ( -n "$pid" && "$pid_start" =~ ^[0-9]+$ ) ]] || return 2
  if coord_remote_enabled; then
    _coord_paths "$key" || return 2
    mkdir -p -- "$COORD_DIR" || return 3
    exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
    flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
    if _coord_remote_renew "$key" "$owner"; then rc=0; else rc=$?; fi
    if (( rc == 0 )); then
      _coord_remote_held_write "$key" "$owner" "$COORD_REMOTE_OID" "$COORD_RECORD" "$pid" "$pid_start" || rc=3
    elif (( rc == 1 )); then
      _coord_remote_held_remove_if_owner "$key" "$owner" || rc=3
    fi
    flock -u "$lock_fd" || :
    exec {lock_fd}>&-
    return "$rc"
  fi
  _coord_paths "$key" || return 2
  exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  _coord_read_locked "$key"; rc=$?
  if (( rc == 0 )); then
    if [[ "$(jq -r '.owner' <<<"$COORD_RECORD")" != "$owner" ]]; then
      rc=1
    else
      now="$(coord_now_s)"; expires="$(jq -r '.expires_at' <<<"$COORD_RECORD")"
      if (( expires <= now )); then
        _coord_expire_locked "$key" || rc=$?
        (( rc == 0 )) && rc=1
      else
        if record="$(jq -c --argjson now "$now" --argjson lease "$COORD_LEASE_SECONDS" --arg pid "$pid" --arg pid_start "$pid_start" \
          '.renewed_at=$now | .expires_at=($now+$lease) | . + (if $pid=="" then {} else {pid:($pid|tonumber)} + (if $pid_start=="" then {} else {pid_start:($pid_start|tonumber)} end) end)' <<<"$COORD_RECORD")"; then
          if _coord_write_locked "$key" "$record"; then rc=0; else rc=3; fi
        else
          rc=3
        fi
      fi
    fi
  fi
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  return "$rc"
}

coord_release() { # key owner; release is conditional on current ownership
  local key="${1:-}" owner="${2:-}" lock_fd rc now record
  if coord_remote_enabled; then
    _coord_paths "$key" || return 2
    mkdir -p -- "$COORD_DIR" || return 3
    exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
    flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
    if _coord_remote_release "$key" "$owner"; then rc=0; else rc=$?; fi
    if (( rc == 0 )); then
      _coord_remote_held_remove_if_owner "$key" "$owner" || rc=3
      _coord_remote_observation_clear "$key" || rc=3
    elif (( rc == 1 )); then
      _coord_remote_held_remove_if_owner "$key" "$owner" || rc=3
    fi
    flock -u "$lock_fd" || :
    exec {lock_fd}>&-
    return "$rc"
  fi
  _coord_paths "$key" || return 2
  exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  _coord_read_locked "$key"; rc=$?
  if (( rc == 0 )); then
    if [[ "$(jq -r '.owner' <<<"$COORD_RECORD")" != "$owner" ]]; then
      rc=1
    elif (( $(jq -r '.expires_at' <<<"$COORD_RECORD") <= $(coord_now_s) )); then
      _coord_expire_locked "$key" || rc=$?
      (( rc == 0 )) && rc=1
    else
      now="$(coord_now_s)"
      if record="$(jq -c --argjson now "$now" '.last_owner=.owner | .owner=null | .expires_at=0 | .released_at=$now | .release_reason="released"' <<<"$COORD_RECORD")"; then
        if _coord_write_locked "$key" "$record"; then rc=0; else rc=3; fi
      else
        rc=3
      fi
    fi
  fi
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  return "$rc"
}

coord_assert_owned() { # key owner; only a fresh, current owner passes
  local scope="${1:-}" key owner="${2:-}" lock_fd rc now expires
  if (( $# == 1 )); then
    case "$scope" in
      ticket:*) key="${scope#ticket:}" ;;
      lane:*) key="lane-${scope#lane:}" ;;
      *) return 2 ;;
    esac
    owner="${ZF_COORD_OWNER:-${COORD_ENTRY_OWNER:-}}"
    [[ -n "$owner" ]] || return 3
  else
    key="$scope"
  fi
  if coord_remote_enabled; then _coord_remote_assert_owned "$key" "$owner"; return $?; fi
  _coord_paths "$key" || return 2
  mkdir -p -- "$COORD_DIR" || return 3
  exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  _coord_read_locked "$key"; rc=$?
  if (( rc == 0 )); then
    now="$(coord_now_s)"; expires="$(jq -r '.expires_at' <<<"$COORD_RECORD")"
    if (( expires <= now )); then
      _coord_expire_locked "$key" || rc=$?
      (( rc == 0 )) && rc=1
    elif [[ "$(jq -r '.owner' <<<"$COORD_RECORD")" != "$owner" ]]; then
      rc=1
    fi
  fi
  (( rc == 0 )) && printf '%s\n' "$COORD_RECORD"
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  return "$rc"
}

coord_assert_write_scope() {
  local actor="${1:-write}" status
  coord_remote_enabled || return 0
  if coord_assert_owned "${ZF_COORD_SCOPE:-}" >/dev/null; then
    return 0
  else
    status=$?
  fi
  printf '%s: refusing write without an owned coordination scope (scope=%s, status=%s)\n' \
    "$actor" "${ZF_COORD_SCOPE:-unscoped}" "$status" >&2
  return "$status"
}

coord_with_ticket() {
  local ticket="${1:-}" subject owner status
  [[ $# -ge 3 && "${2:-}" == -- && "$ticket" =~ ^issue-[1-9][0-9]*$ ]] || return 64
  subject="${ticket#issue-}"
  if [[ "${ZF_COORD_SCOPE:-}" == "ticket:$ticket" ]] \
    && [[ -n "${ZF_COORD_OWNER:-${COORD_ENTRY_OWNER:-}}" ]] \
    && coord_assert_owned "$ZF_COORD_SCOPE" >/dev/null; then
    shift 2
    if "$@"; then return 0; else return $?; fi
  fi
  owner="$(coord_new_owner)" || return 3
  if coord_acquire "$ticket" "$owner" manual-worker "$subject" "mutation-$subject" mutation; then
    :
  else
    return $?
  fi
  shift 2
  local ZF_COORD_SCOPE="ticket:$ticket" ZF_COORD_OWNER="$owner"
  if "$@"; then
    status=0
  else
    status=$?
  fi
  coord_release "$ticket" "$owner" >/dev/null 2>&1 || :
  return "$status"
}

coord_reap_expired() { # sweep expired claims; per-ticket locks keep reads and reaps atomic
  local file key lock_fd rc now
  coord_remote_enabled && return 0
  [[ "$COORD_RELEASED_RETAIN_SECONDS" =~ ^[0-9]+$ ]] \
    || { echo "coord_reap: invalid released claim retention duration" >&2; return 3; }
  mkdir -p -- "$COORD_DIR" || return 3
  for file in "$COORD_DIR"/*.json; do
    [[ -e "$file" ]] || continue
    key="${file##*/}"; key="${key%.json}"
    _coord_paths "$key" || continue
    exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
    flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
    _coord_read_locked "$key"; rc=$?
    if (( rc == 0 )); then
      now="$(coord_now_s)"
      if (( $(jq -r '.expires_at' <<<"$COORD_RECORD") <= now )); then
        _coord_expire_locked "$key" || rc=$?
      fi
    elif (( rc == 1 )) && [[ -e "$COORD_FILE" ]]; then
      now="$(coord_now_s)"
      if jq -e --arg key "$key" --argjson now "$now" --argjson retain "$COORD_RELEASED_RETAIN_SECONDS" \
          '.key == $key and has("owner") and .owner == null
           and (.released_at | type == "number" and floor == . and . < ($now - $retain))' \
          <<<"$COORD_RECORD" >/dev/null 2>&1; then
        rm -f -- "$COORD_FILE" || { echo "coord_reap: could not prune released claim key=$key" >&2; rc=3; }
      fi
    fi
    flock -u "$lock_fd" || :
    exec {lock_fd}>&-
    (( rc == 3 )) && return 3
  done
  return 0
}

COORD_ENTRY_KEY=""
COORD_ENTRY_OWNER=""
coord_enter() { # issue stage; dispatched owners must prove the feeder's claim
  local issue="${1:-}" stage="${2:-}" key owner status
  coord_remote_enabled || return 0
  key="$(coord_issue_key "$issue")" || return 2
  if [[ -n "${ZF_COORD_RUN:-}" ]]; then
    [[ "$ZF_COORD_RUN" == 1 && "${ZF_COORD_KEY:-}" == "$key" \
      && "${ZF_COORD_STAGE:-}" == "$stage" && -n "${ZF_COORD_OWNER:-}" ]] || return 3
    owner="$ZF_COORD_OWNER"
    if coord_assert_owned "$key" "$owner" >/dev/null; then
      :
    else
      status=$?
      echo "coord_enter: dispatched claim unavailable key=$key status=$status" >&2
      return "$status"
    fi
  else
    owner="$(coord_new_owner)"
    if coord_acquire "$key" "$owner" manual-worker "$issue" "manual-$stage-$issue" "$stage"; then
      :
    else
      status=$?
      echo "coord_enter: manual claim unavailable key=$key status=$status" >&2
      return "$status"
    fi
  fi
  COORD_ENTRY_KEY="$key" COORD_ENTRY_OWNER="$owner"
  ZF_COORD_SCOPE="ticket:$key" ZF_COORD_OWNER="$owner"
  trap 'coord_exit "$?"' EXIT
}

coord_exit() { # status; release only the claim this wrapper entered with
  local status="${1:-$?}"
  trap - EXIT
  if [[ -n "$COORD_ENTRY_KEY" && -n "$COORD_ENTRY_OWNER" ]]; then
    coord_release "$COORD_ENTRY_KEY" "$COORD_ENTRY_OWNER" >/dev/null 2>&1 || :
    COORD_ENTRY_KEY="" COORD_ENTRY_OWNER=""
  fi
  exit "$status"
}

