#!/usr/bin/env bash
set -euo pipefail

engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$engine_dir/config.sh"
REPO_DIR="$ZF_REPO_DIR"
GIT_FETCH_TIMEOUT_SEC="${GIT_FETCH_TIMEOUT_SEC:-60}"
source "$engine_dir/lib.d/transport.sh"
source "$engine_dir/coord.sh"
ZF_COORD=on

ctl_error() {
  echo "ctl.sh: $*" >&2
}

ctl_remote_delete() {
  local ref="$1" oid="$2" output current
  output="$(git -C "$COORD_REMOTE_REPO" push --porcelain --force-with-lease="$ref:$oid" origin ":$ref" 2>&1)" || {
    current="$(git -C "$COORD_REMOTE_REPO" ls-remote --refs origin "$ref" 2>/dev/null)" \
      || { ctl_error "delete outcome unknown for $ref"; return 3; }
    [[ -z "$current" ]] && return 0
    ctl_error "could not delete $ref: $output"
    return 3
  }
}

CTL_PROBE_REF=""
CTL_PROBE_OID=""
ctl_probe_cleanup() {
  [[ -n "$CTL_PROBE_REF" && -n "$CTL_PROBE_OID" ]] || return 0
  ctl_remote_delete "$CTL_PROBE_REF" "$CTL_PROBE_OID" >/dev/null 2>&1 || :
}

ctl_probe() {
  local host="$1" key owner ref oid remote_line remote_oid remote_ref
  [[ "$host" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { ctl_error 'invalid host id'; return 2; }
  key="probe-$host-$$-$RANDOM"
  owner="$(coord_new_owner)"
  coord_remote_init || { ctl_error 'coordination remote unavailable'; return 3; }
  _coord_remote_acquire "$key" "$owner" probe "$host" "$key" probe || {
    ctl_error 'could not create leased probe ref'
    return 3
  }
  ref="refs/claims/$key"
  oid="$COORD_REMOTE_OID"
  CTL_PROBE_REF="$ref"
  CTL_PROBE_OID="$oid"
  trap ctl_probe_cleanup EXIT
  if _coord_remote_read "$key"; then
    oid="$COORD_REMOTE_OID"
    CTL_PROBE_OID="$oid"
  else
    ctl_error 'could not read probe ref'
    return 3
  fi
  remote_line="$(git -C "$COORD_REMOTE_REPO" ls-remote --refs origin "$ref")" || {
    ctl_remote_delete "$ref" "$oid" || :
    ctl_error 'could not verify probe ref'
    return 3
  }
  IFS=$'\t' read -r remote_oid remote_ref <<<"$remote_line"
  if [[ "$remote_ref" != "$ref" || "$remote_oid" != "$oid" ]]; then
    ctl_remote_delete "$ref" "$oid" || :
    ctl_error 'probe ref readback did not match its lease'
    return 3
  fi
  ctl_remote_delete "$ref" "$oid" || return 3
  CTL_PROBE_REF=""
  CTL_PROBE_OID=""
  trap - EXIT
  echo 'probe passed'
}

ctl_validate_control() {
  coord_control_record_valid "$1"
}

ctl_read_control() {
  coord_remote_control_read || return 3
  CTL_CONTROL="$COORD_CONTROL"
  CTL_CONTROL_OID="$COORD_CONTROL_OID"
}

ctl_remote_read_file() {
  local ref="$1" file="$2"
  ctl_remote_read_ref "$ref" || return $?
  CTL_REF_CONTENT="$(git -C "$COORD_REMOTE_REPO" cat-file blob "$CTL_REF_SEEN:$file" 2>/dev/null)" || return 3
}

ctl_remote_read_ref() {
  local ref="$1" line oid remote_ref seen
  CTL_REF_OID=""
  CTL_REF_CONTENT=""
  CTL_REF_SEEN=""
  coord_remote_init || return 3
  line="$(git -C "$COORD_REMOTE_REPO" ls-remote --refs origin "$ref" 2>/dev/null)" || return 3
  [[ -n "$line" ]] || return 1
  [[ "$line" != *$'\n'* ]] || return 3
  IFS=$'\t' read -r oid remote_ref <<<"$line"
  [[ "$remote_ref" == "$ref" && "$oid" =~ ^[0-9a-f]{40,64}$ ]] || return 3
  seen="refs/seen/${ref#refs/}"
  git_fetch_bounded "$COORD_REMOTE_REPO" "+$ref:$seen" >/dev/null 2>&1 || return 3
  [[ "$(git -C "$COORD_REMOTE_REPO" rev-parse "$seen" 2>/dev/null)" == "$oid" ]] || return 3
  CTL_REF_OID="$oid"
  CTL_REF_SEEN="$seen"
}

ctl_write_ref_file() {
  local ref="$1" file="$2" expected="$3" record="$4" message="$5"
  local blob tree commit output line oid remote_ref
  [[ "$file" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  blob="$(printf '%s\n' "$record" | git -C "$COORD_REMOTE_REPO" hash-object -w --stdin)" || return 3
  tree="$(printf '100644 blob %s\t%s\n' "$blob" "$file" | git -C "$COORD_REMOTE_REPO" mktree)" || return 3
  commit="$(GIT_AUTHOR_NAME=zenoforge-coord GIT_AUTHOR_EMAIL=zenoforge-coord@users.noreply.github.com \
    GIT_COMMITTER_NAME=zenoforge-coord GIT_COMMITTER_EMAIL=zenoforge-coord@users.noreply.github.com \
    git -C "$COORD_REMOTE_REPO" commit-tree "$tree" -m "$message")" || return 3
  output="$(git -C "$COORD_REMOTE_REPO" push --porcelain --force-with-lease="$ref:$expected" origin "$commit:$ref" 2>&1)" && return 0
  line="$(git -C "$COORD_REMOTE_REPO" ls-remote --refs origin "$ref" 2>/dev/null)" || { ctl_error "write outcome unknown for $ref: $output"; return 3; }
  if [[ "$line" == *$'\n'* ]]; then
    ctl_error "ref readback is ambiguous for $ref"
    return 3
  fi
  IFS=$'\t' read -r oid remote_ref <<<"$line"
  if [[ "$remote_ref" != "$ref" || ! "$oid" =~ ^[0-9a-f]{40,64}$ ]]; then
    if [[ -z "$line" && -n "$expected" ]]; then return 1; fi
    ctl_error "ref readback is malformed for $ref"
    return 3
  fi
  [[ "$oid" == "$commit" ]] && return 0
  [[ "$oid" != "$expected" ]] && return 1
  ctl_error "write failed for $ref: $output"
  return 3
}

ctl_write_control() {
  local expected="$1" record="$2"
  ctl_validate_control "$record" || return 2
  ctl_write_ref_file refs/coord/control control.json "$expected" "$record" 'coord control'
}

ctl_update_control() {
  local operation="$1" value="$2" record rc attempt item
  local -a hosts=()
  for attempt in 1 2 3 4 5; do
    ctl_read_control || { ctl_error 'control record unavailable or invalid'; return 3; }
    case "$operation" in
      primary)
        [[ -z "$value" || "$value" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { ctl_error 'invalid primary host id'; return 2; }
        record="$(jq -c --arg value "$value" '.primary = (if $value == "" then null else $value end)' <<<"$CTL_CONTROL")" || return 3
        ;;
      min_proto)
        [[ "$value" =~ ^[1-9][0-9]*$ ]] || { ctl_error 'min_proto must be a positive integer'; return 2; }
        record="$(jq -c --argjson value "$value" '.min_proto = $value' <<<"$CTL_CONTROL")" || return 3
        ;;
      drain)
        hosts=()
        if [[ -n "$value" ]]; then
          IFS=, read -r -a hosts <<<"$value"
          for item in "${hosts[@]}"; do
            [[ "$item" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { ctl_error 'invalid drain host id'; return 2; }
          done
        fi
        record="$(printf '%s\n' "$CTL_CONTROL" | jq -c --args '.drain = ($ARGS.positional | unique | sort)' -- "${hosts[@]}")" || return 3
        ;;
      drain-add)
        [[ "$value" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { ctl_error 'invalid host id'; return 2; }
        record="$(jq -c --arg host "$value" '.drain += [$host] | .drain |= (unique | sort)' <<<"$CTL_CONTROL")" || return 3
        ;;
      *) return 2 ;;
    esac
    if ctl_write_control "$CTL_CONTROL_OID" "$record"; then return 0; else rc=$?; fi
    (( rc == 1 )) || return "$rc"
  done
  ctl_error 'control changed concurrently; retry the command'
  return 1
}

ctl_adopt_local() {
  local units_file="${ZF_COORD_UNITS_FILE:-${MAC_AUTOPILOT_RUNTIME_DIR:-$AGENT_HOME/autopilot}/units.json}"
  local prefix="${ZF_UNIT_PREFIX:-zf}" active line unit base issue stage unit_row owner status adopted=0
  [[ "$prefix" =~ ^[A-Za-z0-9._-]+$ ]] || { ctl_error 'invalid unit prefix'; return 2; }
  [[ -r "$units_file" ]] || { ctl_error 'unit ledger unavailable'; return 3; }
  jq -e 'type == "object" and (.units | type == "array")' "$units_file" >/dev/null 2>&1 \
    || { ctl_error 'unit ledger malformed'; return 3; }
  active="$(systemctl --user list-units --state=active --no-legend --plain "$prefix-*.service" 2>&1)" \
    || { ctl_error "active unit list unavailable: $active"; return 3; }
  while IFS= read -r line; do
    read -r unit _ <<<"$line"
    [[ "$unit" == "$prefix-"*'.service' ]] || continue
    base="${unit#"$prefix"-}"
    base="${base%.service}"
    issue="${base##*-}"
    stage="${base%-*}"
    [[ "$issue" =~ ^[1-9][0-9]*$ && "$stage" =~ ^[a-z][a-z0-9-]*$ ]] || continue
    unit_row="$(jq -c --arg issue "$issue" '[.units[] | select((.issue | tostring) == $issue or .id == ("issue-" + $issue))][0] // empty' "$units_file")" \
      || { ctl_error "unit ledger lookup failed for $unit"; return 3; }
    [[ -n "$unit_row" ]] || continue
    stage="$(jq -r '.stage // empty' <<<"$unit_row")"
    [[ "$stage" =~ ^[a-z][a-z0-9-]*$ ]] || { ctl_error "unit ledger stage invalid for $unit"; return 3; }
    owner="$(coord_new_owner)"
    if coord_acquire "issue-$issue" "$owner" systemd-worker "$issue" "$unit" "$stage"; then
      adopted=$((adopted + 1))
    else
      status=$?
      (( status == 1 )) && continue
      ctl_error "claim state unknown for $unit"
      return 3
    fi
  done <<<"$active"
  echo "adopted $adopted local units"
}

ctl_enable() {
  local host="$1" env_file="$AGENT_HOME/host.env" host_file="$AGENT_HOME/host-id"
  local timers_file="$AGENT_HOME/timers.local.list" timer=zenoforge-renewd.timer temp lock_fd
  [[ "$host" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { ctl_error 'invalid host id'; return 2; }
  mkdir -p "$AGENT_HOME" || return 3
  umask 077
  temp="$(mktemp "$AGENT_HOME/.host-env.XXXXXX")" || return 3
  printf 'ZF_COORD=on\nZF_HOST_ID=%s\n' "$host" >"$temp" && mv -f -- "$temp" "$env_file" || {
    rm -f -- "$temp"
    ctl_error 'could not write host settings'
    return 3
  }
  temp="$(mktemp "$AGENT_HOME/.host-id.XXXXXX")" || return 3
  printf '%s\n' "$host" >"$temp" && mv -f -- "$temp" "$host_file" || {
    rm -f -- "$temp"
    ctl_error 'could not write host id'
    return 3
  }
  exec {lock_fd}>"$AGENT_HOME/timers.local.lock" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  if [[ -e "$timers_file" && ! -r "$timers_file" ]]; then
    flock -u "$lock_fd" || :
    exec {lock_fd}>&-
    ctl_error 'local timer list is unreadable'
    return 3
  fi
  temp="$(mktemp "$AGENT_HOME/.timers-local.XXXXXX")" || {
    flock -u "$lock_fd" || :
    exec {lock_fd}>&-
    return 3
  }
  [[ ! -f "$timers_file" ]] || cat -- "$timers_file" >"$temp" || {
    rm -f -- "$temp"
    flock -u "$lock_fd" || :
    exec {lock_fd}>&-
    return 3
  }
  grep -Fxq "$timer" "$temp" || printf '%s\n' "$timer" >>"$temp"
  mv -f -- "$temp" "$timers_file" || {
    rm -f -- "$temp"
    flock -u "$lock_fd" || :
    exec {lock_fd}>&-
    return 3
  }
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  systemctl --user set-environment ZF_COORD=on "ZF_HOST_ID=$host" \
    && systemctl --user daemon-reload \
    && systemctl --user start "$timer" || { ctl_error 'could not start coordination renewal timer'; return 3; }
  ZF_COORD=on
  ZF_HOST_ID="$host"
  ctl_adopt_local
}

ctl_status_show() {
  local output line oid ref host seen record directory status
  coord_remote_init || { ctl_error 'coordination remote unavailable'; return 3; }
  directory="$(mktemp -d "${TMPDIR:-/tmp}/coord-status.XXXXXX")" || return 3
  output="$(git -C "$COORD_REMOTE_REPO" ls-remote --refs origin 'refs/status/*')" || {
    rm -rf -- "$directory"
    ctl_error 'status refs unavailable'
    return 3
  }
  while IFS=$'\t' read -r oid ref; do
    [[ -n "$ref" ]] || continue
    host="${ref#refs/status/}"
    [[ "$ref" == refs/status/* && "$host" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$oid" =~ ^[0-9a-f]{40,64}$ ]] || {
      rm -rf -- "$directory"
      ctl_error 'status ref name or object id is invalid'
      return 3
    }
    seen="refs/seen/status/$host"
    git_fetch_bounded "$COORD_REMOTE_REPO" "+$ref:$seen" >/dev/null 2>&1 || {
      rm -rf -- "$directory"
      ctl_error "status fetch failed for $host"
      return 3
    }
    [[ "$(git -C "$COORD_REMOTE_REPO" rev-parse "$seen" 2>/dev/null)" == "$oid" ]] || {
      rm -rf -- "$directory"
      ctl_error "status changed during read for $host"
      return 3
    }
    record="$(git -C "$COORD_REMOTE_REPO" cat-file blob "$seen:worker.json" 2>/dev/null)" || {
      rm -rf -- "$directory"
      ctl_error "status record unavailable for $host"
      return 3
    }
    jq -e --arg host "$host" 'type == "object" and .proto == 1 and .host == $host
      and (.instance | type == "string" and length > 0)
      and (.heartbeat_at | type == "string" and length > 0)
      and (.caps | type == "object")' <<<"$record" >/dev/null 2>&1 || {
      rm -rf -- "$directory"
      ctl_error "status record invalid for $host"
      return 3
    }
    printf '%s\n' "$record" >"$directory/$host.json" || { rm -rf -- "$directory"; return 3; }
  done <<<"$output"
  if output="$(bash "$engine_dir/coord/status.sh" show "$directory" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  rm -rf -- "$directory"
  if (( status != 0 )); then ctl_error "$output"; return "$status"; fi
  [[ -z "$output" ]] || printf '%s\n' "$output"
}

ctl_claim_clear() {
  local key="$1" ref record owner expires now rc checkpoint_size max_checkpoint
  [[ "$key" == refs/claims/* ]] && key="${key#refs/claims/}"
  [[ "$key" =~ ^[A-Za-z0-9._-]+$ ]] || { ctl_error 'invalid claim key'; return 2; }
  ref="refs/claims/$key"
  if ctl_remote_read_ref "$ref"; then
    record="$(git -C "$COORD_REMOTE_REPO" cat-file blob "$CTL_REF_SEEN:claim.json" 2>/dev/null || true)"
  else
    rc=$?
    (( rc == 1 )) && { echo 'claim absent'; return 0; }
    ctl_error 'claim ref unavailable or unknown'
    return 3
  fi
  if jq -e 'type == "object"' <<<"$record" >/dev/null 2>&1; then
    owner="$(jq -r '.owner // empty' <<<"$record")"
    expires="$(jq -r '.expires_at // empty' <<<"$record")"
    now="$(date +%s)"
    if [[ -n "$owner" ]]; then
      if [[ ! "$expires" =~ ^[0-9]+$ ]]; then
        ctl_error 'claim owner lease is unknown'
        return 3
      fi
      if (( expires > now )); then
        ctl_error 'refusing to clear a live claim'
        return 1
      fi
    fi
    if _coord_remote_record_valid "$key" "$record" && jq -e '.checkpoint != null' <<<"$record" >/dev/null 2>&1; then
      checkpoint_size="$(jq -c -j '.checkpoint' <<<"$record" | wc -c)"
      max_checkpoint="${ZF_COORD_CHECKPOINT_MAX:-8192}"
      [[ "$max_checkpoint" =~ ^[0-9]+$ ]] || max_checkpoint=8192
      (( checkpoint_size <= max_checkpoint )) || ctl_error 'clearing an oversized checkpoint claim'
    fi
  fi
  ctl_remote_delete "$ref" "$CTL_REF_OID"
}

ctl_effect_clear() {
  local key="$1" effect="$2" ref record now owner expires
  [[ "$key" == refs/claims/* ]] && key="${key#refs/claims/}"
  [[ "$key" =~ ^[A-Za-z0-9._-]+$ && -n "$effect" ]] || { ctl_error 'invalid claim or effect key'; return 2; }
  ref="refs/claims/$key"
  ctl_remote_read_file "$ref" claim.json || { ctl_error 'claim record unavailable'; return 3; }
  _coord_remote_record_valid "$key" "$CTL_REF_CONTENT" || { ctl_error 'claim record invalid'; return 3; }
  owner="$(jq -r '.owner // empty' <<<"$CTL_REF_CONTENT")"
  expires="$(jq -r '.expires_at' <<<"$CTL_REF_CONTENT")"
  if [[ -n "$owner" ]] && (( expires > $(date +%s) )); then
    ctl_error 'refusing to change an effect on a live claim'
    return 1
  fi
  jq -e --arg effect "$effect" '.effects | type == "object" and .[$effect] != null
    and (.[$effect].class == "once") and (.[$effect].state == "pending" or .[$effect].state == "unknown")' \
    <<<"$CTL_REF_CONTENT" >/dev/null 2>&1 || { ctl_error 'effect is not an unresolved once intent'; return 1; }
  now="$(date +%s)"
  record="$(jq -c --arg effect "$effect" --arg host "$ZF_HOST_ID" --argjson now "$now" \
    '.effects[$effect].state = "cleared" | .effects[$effect].cleared_at = $now | .effects[$effect].cleared_by = $host' \
    <<<"$CTL_REF_CONTENT")" || return 3
  ctl_write_ref_file "$ref" claim.json "$CTL_REF_OID" "$record" "clear effect $effect"
}

ctl_purge() {
  local refs oid ref key record owner expires now rc
  coord_remote_init || { ctl_error 'coordination remote unavailable'; return 3; }
  refs="$(git -C "$COORD_REMOTE_REPO" ls-remote --refs origin 'refs/claims/*' 'refs/status/*' 'refs/coord/*')" \
    || { ctl_error 'coordination refs unavailable'; return 3; }
  while IFS=$'\t' read -r oid ref; do
    [[ -n "$ref" ]] || continue
    [[ "$ref" == refs/claims/* || "$ref" == refs/status/* || "$ref" == refs/coord/* ]] \
      && [[ "$oid" =~ ^[0-9a-f]{40,64}$ ]] || { ctl_error 'coordination ref listing malformed'; return 3; }
    if [[ "$ref" == refs/claims/* ]]; then
      key="${ref#refs/claims/}"
      if ctl_remote_read_file "$ref" claim.json; then
        [[ "$CTL_REF_OID" == "$oid" ]] || { ctl_error "claim changed during purge preflight: $key"; return 3; }
        _coord_remote_record_valid "$key" "$CTL_REF_CONTENT" || {
          ctl_error "claim $key is invalid; clear it explicitly before purge"
          return 3
        }
        owner="$(jq -r '.owner // empty' <<<"$CTL_REF_CONTENT")"
        expires="$(jq -r '.expires_at' <<<"$CTL_REF_CONTENT")"
        now="$(date +%s)"
        if [[ -n "$owner" ]] && (( expires > now )); then
          ctl_error "claim $key is still active; drain hosts and let the stage finish"
          return 1
        fi
      else
        rc=$?
        (( rc == 1 )) || { ctl_error "claim $key became unknown during purge"; return 3; }
      fi
    fi
  done <<<"$refs"
  while IFS=$'\t' read -r oid ref; do
    [[ -n "$ref" ]] || continue
    ctl_remote_delete "$ref" "$oid" || return $?
  done <<<"$refs"
  echo 'coordination refs purged'
}

case "${1:-}" in
  probe)
    shift
    host="$ZF_HOST_ID"
    while (($#)); do
      case "$1" in
        --host-id) (($# >= 2)) || { ctl_error 'usage: ctl.sh probe [--host-id id]'; exit 2; }; host="$2"; shift 2 ;;
        *) ctl_error 'usage: ctl.sh probe [--host-id id]'; exit 2 ;;
      esac
    done
    ctl_probe "$host"
    ;;
  enable)
    shift
    [[ $# -eq 2 && "$1" == --host-id ]] || { ctl_error 'usage: ctl.sh enable --host-id <id>'; exit 2; }
    ctl_enable "$2"
    ;;
  control)
    shift
    [[ "${1:-}" == set && $# -eq 2 && "$2" == *=* ]] || { ctl_error 'usage: ctl.sh control set key=value'; exit 2; }
    key="${2%%=*}"
    value="${2#*=}"
    case "$key" in primary|min_proto|drain) ctl_update_control "$key" "$value" ;;
      *) ctl_error 'control key must be primary, min_proto, or drain'; exit 2 ;;
    esac
    ;;
  drain)
    [[ $# -eq 2 ]] || { ctl_error 'usage: ctl.sh drain <host-id>'; exit 2; }
    ctl_update_control drain-add "$2"
    ;;
  adopt-local)
    [[ $# -eq 1 ]] || { ctl_error 'usage: ctl.sh adopt-local'; exit 2; }
    ctl_adopt_local
    ;;
  status)
    [[ $# -eq 2 && "$2" == show ]] || { ctl_error 'usage: ctl.sh status show'; exit 2; }
    ctl_status_show
    ;;
  claim)
    [[ $# -eq 3 && "$2" == clear ]] || { ctl_error 'usage: ctl.sh claim clear <key>'; exit 2; }
    ctl_claim_clear "$3"
    ;;
  effect)
    [[ $# -eq 4 && "$2" == clear ]] || { ctl_error 'usage: ctl.sh effect clear <claim> <key>'; exit 2; }
    ctl_effect_clear "$3" "$4"
    ;;
  purge)
    [[ $# -eq 1 ]] || { ctl_error 'usage: ctl.sh purge'; exit 2; }
    ctl_purge
    ;;
  *)
    ctl_error 'usage: ctl.sh probe [--host-id id] | enable --host-id id | adopt-local | drain <host-id> | control set key=value | effect clear <claim> <key> | claim clear <key> | purge | status show'
    exit 2
    ;;
esac
