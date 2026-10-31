#!/usr/bin/env bash
# Single-host ticket claims shared by the issue feeder and autopilot scheduler.
# Source through lib.sh; writes are serialized by flock and published by rename.

COORD_DIR="${AGENT_HOME:?AGENT_HOME must be set before loading coord.sh}/coord/claims"
COORD_LEASE_SECONDS="${ZF_COORD_LEASE_SECONDS:-900}"
# Keep released claims briefly for inspection; readers treat them as absent and sweeps scan every claim file.
COORD_RELEASED_RETAIN_SECONDS="${ZF_COORD_RELEASED_RETAIN_SECONDS:-3600}"
COORD_OWNER_SEQ=0

coord_issue_key() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || return 2
  printf 'issue-%s\n' "$1"
}

coord_unit_key() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  printf 'unit-%s\n' "$1"
}

coord_new_owner() {
  COORD_OWNER_SEQ=$((COORD_OWNER_SEQ + 1))
  printf 'owner-%s-%s-%s-%s\n' "${BASHPID:-$$}" "$COORD_OWNER_SEQ" "$RANDOM" "$(date +%s)"
}

coord_process_start_ticks() { # pid -> /proc start ticks, distinguishing a reused PID
  local pid="${1:-}" ticks
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  ticks="$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')" || return 1
  [[ "$ticks" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$ticks"
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
  now="$(date +%s)"
  released="$(jq -c --argjson now "$now" '.last_owner=.owner | .owner=null | .expires_at=0 | .released_at=$now | .release_reason="lease-expired"' <<<"$record")" \
    || return 3
  _coord_write_locked "$key" "$released" || { echo "coord_expire: could not publish released claim key=$key" >&2; return 3; }
}

coord_read() { # key -> JSON / exit 1 confirmed absent / exit 3 unknown
  local key="${1:-}" lock_fd rc now expires
  _coord_paths "$key" || return 2
  mkdir -p -- "$COORD_DIR" || { echo "coord_read: claim directory unavailable" >&2; return 3; }
  exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  _coord_read_locked "$key"; rc=$?
  if (( rc == 0 )); then
    now="$(date +%s)"
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
  local lock_fd rc now lease record held=0
  [[ -n "$owner" && -n "$kind" ]] || return 2
  [[ "$COORD_LEASE_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "coord_acquire: invalid lease duration" >&2; return 3; }
  _coord_paths "$key" || return 2
  mkdir -p -- "$COORD_DIR" || { echo "coord_acquire: claim directory unavailable" >&2; return 3; }
  exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  _coord_read_locked "$key"; rc=$?
  if (( rc == 0 )); then
    now="$(date +%s)"
    if (( $(jq -r '.expires_at' <<<"$COORD_RECORD") <= now )); then
      _coord_expire_locked "$key" || rc=$?
      if (( rc == 0 )); then rc=1; fi
    else
      held=1
    fi
  fi
  if (( held == 1 )); then
    rc=1
  elif (( rc == 1 )); then
    now="$(date +%s)"; lease="$COORD_LEASE_SECONDS"
    if record="$(jq -cn --arg key "$key" --arg owner "$owner" --arg kind "$kind" \
      --arg subject "$subject" --arg unit "$unit" --arg stage "$stage" \
      --argjson now "$now" --argjson lease "$lease" \
      '{version:1,key:$key,owner:$owner,owner_kind:$kind,subject:$subject,unit:$unit,stage:$stage,
        acquired_at:$now,renewed_at:$now,expires_at:($now+$lease)}')"; then
      if _coord_write_locked "$key" "$record"; then rc=0; else rc=3; fi
    else
      rc=3
    fi
  elif (( rc == 0 )); then
    rc=1
  fi
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  return "$rc"
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
        coord_renew "$key" "$owner" || { rc=$?; (( rc == 3 )) && unknown=1; }
        ;;
      inactive|failed|dead)
        # A claim is taken before systemd-run starts the unit (admission can queue it ~20s); 07:46Z 10-30 a concurrent tick released the advisor-batch claim in that gap.
        (( $(date +%s) - $(jq -r '.renewed_at // 0' <<<"$record") < 120 )) && continue
        coord_release "$key" "$owner" || { rc=$?; (( rc == 3 )) && unknown=1; }
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
  _coord_paths "$key" || return 2
  exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  _coord_read_locked "$key"; rc=$?
  if (( rc == 0 )); then
    if [[ "$(jq -r '.owner' <<<"$COORD_RECORD")" != "$owner" ]]; then
      rc=1
    else
      now="$(date +%s)"; expires="$(jq -r '.expires_at' <<<"$COORD_RECORD")"
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
  _coord_paths "$key" || return 2
  exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  _coord_read_locked "$key"; rc=$?
  if (( rc == 0 )); then
    if [[ "$(jq -r '.owner' <<<"$COORD_RECORD")" != "$owner" ]]; then
      rc=1
    elif (( $(jq -r '.expires_at' <<<"$COORD_RECORD") <= $(date +%s) )); then
      _coord_expire_locked "$key" || rc=$?
      (( rc == 0 )) && rc=1
    else
      now="$(date +%s)"
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
  local key="${1:-}" owner="${2:-}" lock_fd rc now expires
  _coord_paths "$key" || return 2
  mkdir -p -- "$COORD_DIR" || return 3
  exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  _coord_read_locked "$key"; rc=$?
  if (( rc == 0 )); then
    now="$(date +%s)"; expires="$(jq -r '.expires_at' <<<"$COORD_RECORD")"
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

coord_reap_expired() { # sweep expired claims; per-ticket locks keep reads and reaps atomic
  local file key lock_fd rc now
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
      now="$(date +%s)"
      if (( $(jq -r '.expires_at' <<<"$COORD_RECORD") <= now )); then
        _coord_expire_locked "$key" || rc=$?
      fi
    elif (( rc == 1 )) && [[ -e "$COORD_FILE" ]]; then
      now="$(date +%s)"
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
