#!/usr/bin/env bash
set -euo pipefail

engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$engine_dir/config.sh"

renewd_instance() {
  local file="$AGENT_HOME/coord/instance" value temp
  mkdir -p "$AGENT_HOME/coord" || return 3
  if [[ ! -e "$file" ]]; then
    value="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" || return 3
    [[ "$value" =~ ^[0-9a-f]{32}$ ]] || return 3
    temp="$(mktemp "$AGENT_HOME/coord/.instance.XXXXXX")" || return 3
    printf '%s\n' "$value" >"$temp" && chmod 600 "$temp" && mv -n -- "$temp" "$file" || {
      rm -f -- "$temp"
      return 3
    }
  fi
  IFS= read -r value <"$file" || return 3
  [[ -n "$value" ]] || return 3
  printf '%s\n' "$value"
}

renewd_instance_matches() {
  local instance="$1" ref="refs/seen/status/$ZF_HOST_ID" record status
  if git -C "$COORD_REMOTE_REPO" show-ref --verify --quiet "$ref"; then :; else
    status=$?
    (( status == 1 )) && return 0
    return 3
  fi
  record="$(git -C "$COORD_REMOTE_REPO" cat-file blob "$ref:worker.json" 2>/dev/null)" || return 3
  jq -e --arg host "$ZF_HOST_ID" --arg instance "$instance" \
    'type == "object" and .proto == 1 and .host == $host and (.instance | type == "string" and length > 0)' \
    <<<"$record" >/dev/null 2>&1 || return 3
  [[ "$(jq -r '.instance' <<<"$record")" == "$instance" ]]
}

renewd_commit() {
  local file="$1" content="$2" blob tree
  blob="$(printf '%s\n' "$content" | git -C "$COORD_REMOTE_REPO" hash-object -w --stdin)" || return 3
  tree="$(printf '100644 blob %s\t%s\n' "$blob" "$file" | git -C "$COORD_REMOTE_REPO" mktree)" || return 3
  GIT_AUTHOR_NAME=zenoforge-coord GIT_AUTHOR_EMAIL=zenoforge-coord@users.noreply.github.com \
    GIT_COMMITTER_NAME=zenoforge-coord GIT_COMMITTER_EMAIL=zenoforge-coord@users.noreply.github.com \
    git -C "$COORD_REMOTE_REPO" commit-tree "$tree" -m "renew $file"
}

renewd_claim_record() {
  local key="$1" owner="$2" old_oid="$3" claim subject unit projection old_unit now
  claim="$(git -C "$COORD_REMOTE_REPO" cat-file blob "$old_oid:claim.json" 2>/dev/null)" || return 3
  jq -e --arg key "$key" --arg owner "$owner" \
    'type == "object" and .key == $key and .owner == $owner and (.expires_at | type == "number")' \
    <<<"$claim" >/dev/null 2>&1 || return 1
  subject="$(jq -r '.subject' <<<"$claim")" || return 3
  unit="$(jq -r '.unit' <<<"$claim")" || return 3
  projection="$(coord_checkpoint_project "$subject" "$unit")" || return 3
  if jq -e '.checkpoint.unit | type == "object" and length > 0' <<<"$claim" >/dev/null 2>&1 \
    && jq -e '.unit == {}' <<<"$projection" >/dev/null 2>&1; then
    old_unit="$(jq -c '.checkpoint.unit' <<<"$claim")" || return 3
    projection="$(jq -cn --argjson projection "$projection" --argjson unit "$old_unit" '$projection | .unit=$unit')" || return 3
  fi
  claim="$(coord_checkpoint_fit_claim "$claim" "$projection")" || return 3
  now="$(coord_now_s)" || return 3
  jq -c --argjson now "$now" --argjson lease "$COORD_LEASE_SECONDS" \
    '.renewed_at=$now | .expires_at=($now+$lease)' <<<"$claim"
}

renewd_pid_alive() {
  local pid="$1" expected="$2" group="$3" current=""
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    current="$(coord_process_start_ticks "$pid" 2>/dev/null || true)"
    if [[ "$expected" =~ ^[0-9]+$ && -n "$current" && "$current" != "$expected" ]]; then return 1; fi
    if [[ -z "$expected" || "$current" == "$expected" ]]; then
      pid_live "$pid" && return 0
    fi
  fi
  [[ "$group" =~ ^[1-9][0-9]*$ ]] && kill -0 -- "-$group" 2>/dev/null
}

renewd_run_state() {
  local record="$1" kind owner unit state worker workers_file pid expected group harvested
  kind="$(jq -r '.owner_kind' <<<"$record")" || return 3
  owner="$(jq -r '.owner' <<<"$record")" || return 3
  case "$kind" in
    systemd-worker)
      unit="$(jq -r '.unit' <<<"$record")" || return 3
      [[ "$unit" == *.service ]] || unit="$unit.service"
      state="$(systemctl --user show "$unit" --property=ActiveState --value 2>/dev/null)" || return 3
      case "$state" in
        active|activating|deactivating|reloading) return 0 ;;
        inactive|failed|dead) return 1 ;;
        *) return 3 ;;
      esac
      ;;
    scheduler-worker)
      workers_file="${ZF_COORD_WORKERS_FILE:-${MAC_AUTOPILOT_RUNTIME_DIR:-$REPO_DIR/.scratch-supervisor/autopi}/workers.json}"
      [[ -r "$workers_file" ]] || return 3
      jq -e 'type == "object" and (.workers | type == "array")' "$workers_file" >/dev/null 2>&1 || return 3
      worker="$(jq -c --arg owner "$owner" '[.workers[] | select(.claim_owner == $owner)][0] // empty' "$workers_file")" || return 3
      [[ -n "$worker" ]] || return 1
      harvested="$(jq -r '(.harvested == true) or (.lease_expired == true)' <<<"$worker")" || return 3
      [[ "$harvested" == true ]] && return 1
      pid="$(jq -r '.pid // empty' <<<"$worker")" || return 3
      expected="$(jq -r '.pid_start // empty' <<<"$worker")" || return 3
      group="$(jq -r '.process_group // empty' <<<"$worker")" || return 3
      renewd_pid_alive "$pid" "$expected" "$group"
      ;;
    manual-worker)
      pid="$(jq -r '.pid // empty' <<<"$record")" || return 3
      expected="$(jq -r '.pid_start // empty' <<<"$record")" || return 3
      group="$(jq -r '.process_group // empty' <<<"$record")" || return 3
      if [[ ! "$pid" =~ ^[1-9][0-9]*$ && "$owner" =~ ^owner-([1-9][0-9]*)- ]]; then pid="${BASH_REMATCH[1]}"; fi
      [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 3
      renewd_pid_alive "$pid" "$expected" "$group"
      ;;
    feeder)
      pid="$(jq -r '.pid // empty' <<<"$record")" || return 3
      expected="$(jq -r '.pid_start // empty' <<<"$record")" || return 3
      group="$(jq -r '.process_group // empty' <<<"$record")" || return 3
      [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
      renewd_pid_alive "$pid" "$expected" "$group"
      ;;
    *) return 3 ;;
  esac
}

renewd_worker_process() {
  local record="$1" kind owner worker workers_file
  kind="$(jq -r '.owner_kind' <<<"$record")" || return 3
  owner="$(jq -r '.owner' <<<"$record")" || return 3
  if [[ "$kind" == scheduler-worker ]]; then
    workers_file="${ZF_COORD_WORKERS_FILE:-${MAC_AUTOPILOT_RUNTIME_DIR:-$REPO_DIR/.scratch-supervisor/autopi}/workers.json}"
    if [[ -r "$workers_file" ]] && jq -e 'type == "object" and (.workers | type == "array")' "$workers_file" >/dev/null 2>&1; then
      worker="$(jq -c --arg owner "$owner" '[.workers[] | select(.claim_owner == $owner)][0] // empty' "$workers_file")" || return 3
      if [[ -n "$worker" ]]; then
        printf '%s\n' "$worker"
        return 0
      fi
    fi
  fi
  jq -ec 'select(.pid | type == "number" and floor == . and . > 0)
    | {pid:.pid}
      + (if (.pid_start | type) == "number" then {pid_start:.pid_start} else {} end)
      + (if (.process_group | type) == "number" then {process_group:.process_group} else {} end)' <<<"$record"
}

renewd_stop() {
  local record="$1" kind unit worker pid expected group current
  kind="$(jq -r '.owner_kind' <<<"$record")" || return 3
  if [[ "$kind" == systemd-worker ]]; then
    unit="$(jq -r '.unit' <<<"$record")" || return 3
    [[ "$unit" == *.service ]] || unit="$unit.service"
    systemctl --user stop "$unit"
    return $?
  fi
  worker="$(renewd_worker_process "$record")" || return $?
  pid="$(jq -r '.pid // empty' <<<"$worker")" || return 3
  expected="$(jq -r '.pid_start // empty' <<<"$worker")" || return 3
  group="$(jq -r '.process_group // empty' <<<"$worker")" || return 3
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
    owner="$(jq -r '.owner' <<<"$record")" || return 3
    if [[ "$owner" =~ ^owner-([1-9][0-9]*)- ]]; then pid="${BASH_REMATCH[1]}"; fi
  fi
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 3
  current="$(coord_process_start_ticks "$pid" 2>/dev/null || true)"
  [[ ! "$expected" =~ ^[0-9]+$ || -z "$current" || "$current" == "$expected" ]] || return 0
  if [[ "$group" =~ ^[1-9][0-9]*$ && "$group" == "$pid" ]]; then
    kill -TERM -- "-$group" 2>/dev/null || return 0
    for _ in {1..20}; do kill -0 -- "-$group" 2>/dev/null || return 0; sleep 0.1; done
    kill -KILL -- "-$group" 2>/dev/null || :
  else
    kill -TERM "$pid" 2>/dev/null || return 0
    for _ in {1..20}; do pid_live "$pid" || return 0; sleep 0.1; done
    kill -KILL "$pid" 2>/dev/null || :
  fi
}

renewd_mark_lost() {
  local key="$1" owner="$2" now="$3" path="$AGENT_HOME/coord/held/$1" temp
  [[ -r "$path" ]] || return 0
  jq -e --arg owner "$owner" '.owner == $owner' "$path" >/dev/null 2>&1 || return 1
  temp="$(mktemp "$AGENT_HOME/coord/held/.lost.XXXXXX")" || return 3
  jq -c --argjson now "$now" '.lost=true | .lost_at=$now' "$path" >"$temp" \
    && chmod 600 "$temp" && mv -f -- "$temp" "$path" || { rm -f -- "$temp"; return 3; }
}

renewd_held_claim() {
  local held="$1" key owner oid record repo process_data
  key="${held##*/}"
  owner="$(jq -r '.owner // empty' "$held" 2>/dev/null)" || return 3
  oid="$(jq -r '.oid // empty' "$held" 2>/dev/null)" || return 3
  [[ "$oid" =~ ^[0-9a-f]{40,64}$ ]] || return 3
  process_data="$(jq -c --arg key "$key" --arg owner "$owner" '
    select(.key == $key and .owner == $owner and (.owner_kind | type == "string" and length > 0))
    | {pid:.pid,pid_start:.pid_start,process_group:.process_group}' "$held" 2>/dev/null)" || process_data=""
  repo="${COORD_REMOTE_REPO:-$AGENT_HOME/coord/repo.git}"
  record="$(git -C "$repo" cat-file blob "$oid:claim.json" 2>/dev/null)" || return 3
  jq -e --arg key "$key" --arg owner "$owner" '.key == $key and .owner == $owner' <<<"$record" >/dev/null 2>&1 || return 3
  if [[ -n "$process_data" ]]; then
    record="$(jq -cn --argjson claim "$record" --argjson process "$process_data" '
      $claim
      + (if ($process.pid | type) == "number" then {pid:$process.pid} else {} end)
      + (if ($process.pid_start | type) == "number" then {pid_start:$process.pid_start} else {} end)
      + (if ($process.process_group | type) == "number" then {process_group:$process.process_group} else {} end)')" || return 3
  fi
  printf '%s\n' "$record"
}

renewd_remote_claim() {
  local key="$1" oid="$2" ref="refs/claims/$1" seen="refs/seen/claims/$1" actual record
  git_fetch_bounded "$COORD_REMOTE_REPO" "+$ref:$seen" >/dev/null 2>&1 || return 3
  actual="$(git -C "$COORD_REMOTE_REPO" rev-parse "$seen" 2>/dev/null)" || return 3
  [[ "$actual" == "$oid" ]] || return 3
  record="$(git -C "$COORD_REMOTE_REPO" cat-file blob "$seen:claim.json" 2>/dev/null)" || return 3
  jq -e --arg key "$key" '.key == $key and (.owner == null or (.owner | type == "string"))' <<<"$record" >/dev/null 2>&1 || return 3
  printf '%s\n' "$record"
}

renewd_fence_stale_local() {
  local held key owner now held_at deadline lost claim status=0
  local -a files=()
  now="$(coord_now_s)" || return 3
  deadline="${ZF_COORD_SELF_FENCE_S:-600}"
  [[ "$deadline" =~ ^[1-9][0-9]*$ ]] || return 3
  shopt -s nullglob
  files=("$AGENT_HOME/coord/held"/*)
  for held in "${files[@]}"; do
    key="${held##*/}"
    owner="$(jq -r '.owner // empty' "$held" 2>/dev/null)" || { status=3; continue; }
    held_at="$(jq -r '.held_at // empty' "$held" 2>/dev/null)" || { status=3; continue; }
    [[ -n "$owner" && "$held_at" =~ ^[0-9]+$ ]] || { status=3; continue; }
    lost="$(jq -r '.lost == true' "$held" 2>/dev/null)" || { status=3; continue; }
    if [[ "$lost" != true ]] && (( now >= held_at && now - held_at >= deadline )); then
      claim="$(renewd_held_claim "$held")" || { status=3; continue; }
      renewd_mark_lost "$key" "$owner" "$now" || { status=3; continue; }
      renewd_stop "$claim" || status=3
    elif [[ "$lost" == true ]]; then
      claim="$(renewd_held_claim "$held")" || { status=3; continue; }
      renewd_stop "$claim" || status=3
    fi
  done
  return "$status"
}

renewd_fence_all() {
  local held key owner claim now status=0
  local -a files=()
  now="$(coord_now_s)" || return 3
  shopt -s nullglob
  files=("$AGENT_HOME/coord/held"/*)
  for held in "${files[@]}"; do
    key="${held##*/}"
    owner="$(jq -r '.owner // empty' "$held" 2>/dev/null)" || owner=""
    [[ -n "$owner" ]] || { status=3; continue; }
    claim="$(renewd_held_claim "$held")" || { status=3; continue; }
    renewd_mark_lost "$key" "$owner" "$now" || status=3
    renewd_stop "$claim" || status=3
  done
  return "$status"
}

renewd_gone_long_enough() {
  local key="$1" owner="$2" now="$3" grace="$4" path="$AGENT_HOME/coord/gone/$1" data since temp
  mkdir -p "${path%/*}" || return 3
  if [[ -r "$path" ]] && data="$(cat -- "$path")" \
    && jq -e --arg owner "$owner" '.owner == $owner and (.since | type == "number" and floor == . and . >= 0)' <<<"$data" >/dev/null 2>&1; then
    since="$(jq -r '.since' <<<"$data")" || return 3
    if (( now < since )); then
      temp="$(mktemp "${path%/*}/.gone.XXXXXX")" || return 3
      jq -cn --arg owner "$owner" --argjson since "$now" '{owner:$owner,since:$since}' >"$temp" \
        && chmod 600 "$temp" && mv -f -- "$temp" "$path" || { rm -f -- "$temp"; return 3; }
      return 1
    fi
    (( now - since >= grace )) && return 0
    return 1
  fi
  temp="$(mktemp "${path%/*}/.gone.XXXXXX")" || return 3
  jq -cn --arg owner "$owner" --argjson since "$now" '{owner:$owner,since:$since}' >"$temp" \
    && chmod 600 "$temp" && mv -f -- "$temp" "$path" || { rm -f -- "$temp"; return 3; }
  return 1
}

renewd_release_record() {
  local claim="$1" now="$2"
  jq -c --argjson now "$now" \
    '.last_owner=.owner | .owner=null | .expires_at=0 | .released_at=$now | .release_reason="run-gone"' \
    <<<"$claim"
}

renewd_janitor_observe() {
  local key="$1" oid="$2" now="$3" path="$AGENT_HOME/coord/janitor/$1" data old_oid first_seen temp
  mkdir -p "${path%/*}" || return 3
  if [[ -r "$path" ]] && data="$(cat -- "$path")" \
    && jq -e '.oid | type == "string" and test("^[0-9a-f]{40,64}$")' <<<"$data" >/dev/null 2>&1; then
    old_oid="$(jq -r '.oid' <<<"$data")" || return 3
    first_seen="$(jq -r '.first_seen' <<<"$data")" || return 3
    if [[ "$old_oid" == "$oid" && "$first_seen" =~ ^[0-9]+$ ]] && (( now >= first_seen )); then
      (( now - first_seen >= 604800 )) && return 0
      return 1
    fi
  fi
  temp="$(mktemp "${path%/*}/.janitor.XXXXXX")" || return 3
  jq -cn --arg oid "$oid" --argjson first_seen "$now" '{oid:$oid,first_seen:$first_seen}' >"$temp" \
    && chmod 600 "$temp" && mv -f -- "$temp" "$path" || { rm -f -- "$temp"; return 3; }
  return 1
}

renewd_janitor_prepare() {
  local seen key oid record now rc marker
  local -a refs=()
  now="$(coord_now_s)" || return 3
  mapfile -t refs < <(git -C "$COORD_REMOTE_REPO" for-each-ref --format='%(refname)' refs/seen/claims/)
  for seen in "${refs[@]}"; do
    key="${seen#refs/seen/claims/}"
    [[ "$key" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    oid="$(git -C "$COORD_REMOTE_REPO" rev-parse "$seen" 2>/dev/null)" || return 3
    record="$(git -C "$COORD_REMOTE_REPO" cat-file blob "$seen:claim.json" 2>/dev/null)" || return 3
    if jq -e --arg key "$key" '.key == $key and .owner == null and (.released_at | type == "number" and floor == . and . >= 0)' \
      <<<"$record" >/dev/null 2>&1; then
      if renewd_janitor_observe "$key" "$oid" "$now"; then
        renewd_delete_keys+=("$key")
        renewd_delete_oids+=("$oid")
      else
        rc=$?
        (( rc == 1 )) || return "$rc"
      fi
    else
      rm -f -- "$AGENT_HOME/coord/janitor/$key"
    fi
  done
  shopt -s nullglob
  for marker in "$AGENT_HOME/coord/janitor"/*; do
    key="${marker##*/}"
    git -C "$COORD_REMOTE_REPO" show-ref --verify --quiet "refs/seen/claims/$key" || rm -f -- "$marker"
  done
}

renewd_once() {
  local instance caps heartbeat status_commit output push_status=0 actual ref oid key owner held updated new_oid i action now rc held_at deadline lost run_claim readback_ok=0
  local -a files=() refs=() old_oids=() new_oids=() keys=() owners=() records=() actions=() push_options=() push_specs=() read_refs=()
  local -a renewd_delete_keys=() renewd_delete_oids=()
  local -A remote_oids=()
  [[ "${ZF_COORD:-off}" == on ]] || return 0
  mkdir -p "$AGENT_HOME/coord" || return 3
  exec {lock_fd}>"$AGENT_HOME/coord/renewd.lock" || return 3
  flock -n "$lock_fd" || { exec {lock_fd}>&-; return 0; }
  REPO_DIR="$ZF_REPO_DIR"
  GIT_FETCH_TIMEOUT_SEC="${ZF_COORD_GIT_TIMEOUT_S:-30}"
  source "$engine_dir/lib.d/transport.sh"
  coord_source_if_enabled
  source "$engine_dir/coord/status.sh"
  source "$engine_dir/coord/caps.sh"
  coord_remote_init || { renewd_fence_stale_local || :; return 3; }
  coord_remote_refresh force || { renewd_fence_stale_local || :; return 3; }
  instance="$(renewd_instance)" || return 3
  if ! renewd_instance_matches "$instance"; then
    echo "renewd: host identity is already in use host=$ZF_HOST_ID" >&2
    renewd_fence_all || :
    return 3
  fi
  caps="$(coord_caps_json)" || return 3
  heartbeat="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 3
  status="$(ZF_COORD=on status_record "$ZF_HOST_ID" "$instance" "$heartbeat" "$caps")" || return 3
  status_commit="$(renewd_commit worker.json "$status")" || return 3
  shopt -s nullglob
  files=("$AGENT_HOME/coord/held"/*)
  for held in "${files[@]}"; do
    key="${held##*/}"
    jq -e --arg key "$key" 'type == "object" and .key == $key and (.owner | type == "string" and length > 0) and (.oid | type == "string" and test("^[0-9a-f]{40,64}$"))' \
      "$held" >/dev/null 2>&1 || { echo "renewd: held claim record is invalid key=$key" >&2; return 3; }
    owner="$(jq -r '.owner' "$held")" || return 3
    oid="$(jq -r '.oid' "$held")" || return 3
    if claim="$(git -C "$COORD_REMOTE_REPO" cat-file blob "$oid:claim.json" 2>/dev/null)"; then :; else return 3; fi
    run_claim="$(renewd_held_claim "$held")" || return 3
    lost="$(jq -r '.lost == true' "$held")" || return 3
    if [[ "$lost" == true ]]; then
      renewd_stop "$run_claim" || return 3
      continue
    fi
    now="$(coord_now_s)" || return 3
    if ! jq -e --arg key "$key" --arg owner "$owner" --argjson now "$now" \
      '.key == $key and .owner == $owner and (.expires_at | type == "number" and . > $now)' \
      <<<"$claim" >/dev/null 2>&1; then
      renewd_mark_lost "$key" "$owner" "$now" || return 3
      renewd_stop "$run_claim" || return 3
      continue
    fi
    held_at="$(jq -r '.held_at // empty' "$held")" || return 3
    deadline="${ZF_COORD_SELF_FENCE_S:-600}"
    [[ "$held_at" =~ ^[0-9]+$ && "$deadline" =~ ^[1-9][0-9]*$ ]] || return 3
    if (( now >= held_at && now - held_at >= deadline )); then
      renewd_mark_lost "$key" "$owner" "$now" || return 3
      renewd_stop "$run_claim" || return 3
      continue
    fi
    if renewd_run_state "$run_claim"; then
      rm -f -- "$AGENT_HOME/coord/gone/$key"
      updated="$(renewd_claim_record "$key" "$owner" "$oid")" || {
        rc=$?
        if (( rc == 1 )); then rm -f -- "$held"; continue; fi
        return "$rc"
      }
      action=renew
    else
      rc=$?
      if (( rc == 1 )); then
        now="$(coord_now_s)" || return 3
        if renewd_gone_long_enough "$key" "$owner" "$now" "${ZF_COORD_DEAD_GRACE_S:-300}"; then
          updated="$(renewd_release_record "$claim" "$now")" || return 3
          action=release
        else
          rc=$?
          (( rc == 1 )) || return "$rc"
          updated="$(renewd_claim_record "$key" "$owner" "$oid")" || return 3
          action=renew
        fi
      else
        rm -f -- "$AGENT_HOME/coord/gone/$key"
        updated="$(renewd_claim_record "$key" "$owner" "$oid")" || return 3
        action=renew
      fi
    fi
    new_oid="$(renewd_commit claim.json "$updated")" || return 3
    refs+=("refs/claims/$key")
    old_oids+=("$oid")
    new_oids+=("$new_oid")
    keys+=("$key")
    owners+=("$owner")
    records+=("$updated")
    actions+=("$action")
    push_options+=("--force-with-lease=refs/claims/$key:$oid")
    push_specs+=("$new_oid:refs/claims/$key")
  done
  renewd_janitor_prepare || return 3
  for ((i = 0; i < ${#renewd_delete_keys[@]}; i++)); do
    key="${renewd_delete_keys[$i]}"
    oid="${renewd_delete_oids[$i]}"
    ref="refs/claims/$key"
    refs+=("$ref")
    push_options+=("--force-with-lease=$ref:$oid")
    push_specs+=(":$ref")
  done
  refs+=("refs/status/$ZF_HOST_ID")
  push_specs+=("+$status_commit:refs/status/$ZF_HOST_ID")
  read_refs=("${refs[@]}")
  if output="$(git -C "$COORD_REMOTE_REPO" push --porcelain "${push_options[@]}" origin "${push_specs[@]}" 2>&1)"; then
    push_status=0
  else
    push_status=$?
    printf 'renewd: batched push failed status=%s output=%s\n' "$push_status" "${output%%$'\n'*}" >&2
  fi
  if actual="$(git -C "$COORD_REMOTE_REPO" ls-remote --refs origin "${read_refs[@]}")"; then
    readback_ok=1
    while IFS=$'\t' read -r oid ref; do
      [[ -n "$ref" ]] && remote_oids["$ref"]="$oid"
    done <<<"$actual"
  else
    (( push_status != 0 )) || return 3
  fi
  for ((i = 0; i < ${#keys[@]}; i++)); do
    key="${keys[$i]}"
    ref="refs/claims/$key"
    if [[ "${remote_oids[$ref]:-}" == "${new_oids[$i]}" ]] || (( push_status == 0 )); then
      if [[ "${actions[$i]}" == release ]]; then
        rm -f -- "$AGENT_HOME/coord/held/$key" "$AGENT_HOME/coord/gone/$key"
      else
        _coord_remote_held_write "$key" "${owners[$i]}" "${new_oids[$i]}" "${records[$i]}" || return 3
      fi
    elif (( readback_ok == 1 )) && [[ "${remote_oids[$ref]:-}" != "${old_oids[$i]}" ]]; then
      now="$(coord_now_s)" || return 3
      if [[ -n "${remote_oids[$ref]:-}" ]] \
        && actual="$(renewd_remote_claim "$key" "${remote_oids[$ref]}")" \
        && jq -e --arg owner "${owners[$i]}" --argjson now "$now" \
          '.owner == $owner and (.expires_at | type == "number" and . > $now)' <<<"$actual" >/dev/null 2>&1; then
        _coord_remote_held_write "$key" "${owners[$i]}" "${remote_oids[$ref]}" "$actual" || return 3
        rm -f -- "$AGENT_HOME/coord/gone/$key"
      else
        renewd_mark_lost "$key" "${owners[$i]}" "$now" || return 3
        renewd_stop "${records[$i]}" || return 3
      fi
    fi
  done
  for ((i = 0; i < ${#renewd_delete_keys[@]}; i++)); do
    key="${renewd_delete_keys[$i]}"
    ref="refs/claims/$key"
    if (( push_status == 0 )) || (( readback_ok == 1 )) && [[ -z "${remote_oids[$ref]:-}" ]]; then
      rm -f -- "$AGENT_HOME/coord/janitor/$key"
    elif (( readback_ok == 1 )) && [[ "${remote_oids[$ref]}" != "${renewd_delete_oids[$i]}" ]]; then
      rm -f -- "$AGENT_HOME/coord/janitor/$key"
    fi
  done
  [[ "${remote_oids[refs/status/$ZF_HOST_ID]:-}" == "$status_commit" ]] || (( push_status == 0 )) || return 3
  return 0
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  [[ $# -eq 1 && "$1" == --once ]] || { echo 'usage: renewd.sh --once' >&2; exit 2; }
  renewd_once
fi
