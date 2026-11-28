#!/usr/bin/env bash

coord_control_record_valid() {
  jq -e '
    type == "object" and .proto == 1
    and ((.primary == null) or (.primary | type == "string" and test("^[a-z0-9][a-z0-9-]{0,31}$")))
    and (.drain | type == "array" and all(.[]; type == "string" and test("^[a-z0-9][a-z0-9-]{0,31}$")) and length == (unique | length))
    and (.min_proto | type == "number" and floor == . and . >= 1)
  ' <<<"$1" >/dev/null 2>&1
}

coord_remote_control_read() {
  local force="${1:-}" oid seen status
  COORD_CONTROL='{"proto":1,"primary":null,"drain":[],"min_proto":1}'
  COORD_CONTROL_OID=""
  seen=refs/seen/coord/control
  coord_remote_refresh "$force" || return 3
  if git -C "$COORD_REMOTE_REPO" show-ref --verify --quiet "$seen"; then :; else
    status=$?
    (( status == 1 )) && return 0
    return 3
  fi
  oid="$(git -C "$COORD_REMOTE_REPO" rev-parse "$seen" 2>/dev/null)" || return 3
  [[ "$oid" =~ ^[0-9a-f]{40,64}$ ]] || return 3
  COORD_CONTROL="$(git -C "$COORD_REMOTE_REPO" cat-file blob "$seen:control.json" 2>/dev/null)" || return 3
  coord_control_record_valid "$COORD_CONTROL" || return 3
  COORD_CONTROL_OID="$oid"
}

coord_control_allows_acquire() {
  coord_remote_control_read || return 3
  jq -e --arg host "${ZF_HOST_ID:-}" '
    (.min_proto <= 1)
    and (.primary == null or .primary == $host)
    and (.drain | index($host) == null)
  ' <<<"$COORD_CONTROL" >/dev/null 2>&1
}

coord_remote_init() {
  local repo="$AGENT_HOME/coord/repo.git" remote existing lock_fd status=0 was_new=0 line name value
  remote="$(git -C "${REPO_DIR:-}" remote get-url origin 2>/dev/null)" \
    || { echo "coord_init: repository origin unavailable" >&2; return 3; }
  mkdir -p "$AGENT_HOME/coord" || return 3
  exec {lock_fd}>"$AGENT_HOME/coord/repo.lock" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    (umask 077; git init --bare --quiet "$repo") || status=3
    (( status != 0 )) || was_new=1
  fi
  if (( status == 0 )); then
    existing="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
    if [[ -z "$existing" ]]; then
      git -C "$repo" remote add origin "$remote" || status=3
    elif [[ "$existing" != "$remote" ]]; then
      echo "coord_init: coordination origin does not match repository origin" >&2
      status=3
    fi
  fi
  if (( status == 0 )); then
    git -C "$repo" config fetch.prune true \
      && git -C "$repo" config user.name zenoforge-coord \
      && git -C "$repo" config user.email zenoforge-coord@users.noreply.github.com \
      || status=3
  fi
  if (( status == 0 && was_new == 1 )); then
    while IFS= read -r line; do
      name="${line%% *}"; value="${line#* }"
      git -C "$repo" config --add "$name" "$value" || status=3
    done < <(git -C "$REPO_DIR" config --get-regexp '^(credential|http|url)\.' 2>/dev/null || true)
  fi
  if (( status == 0 )); then chmod 600 "$repo/config" || status=3; fi
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  (( status == 0 )) || return 3
  COORD_REMOTE_REPO="$repo"
}

_coord_remote_record_valid() {
  jq -e --arg key "$1" '
    type == "object" and .version == 1 and .key == $key
    and ((has("proto")|not) or (.proto|type == "number" and floor == . and . == 1))
    and has("owner")
    and ((.owner == null) or (.owner | type == "string" and length > 0))
    and (.owner_kind | type == "string" and length > 0)
    and (.subject | type == "string")
    and (.unit | type == "string" and length > 0 and test("^[A-Za-z0-9_.@:-]+$"))
    and (.stage | type == "string" and length > 0)
    and (.expires_at | type == "number" and floor == .)
    and ((has("generation")|not) or (.generation|type == "number" and floor == . and . >= 1))
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
  ' <<<"$2" >/dev/null 2>&1
}

coord_remote_refresh() {
  local force="${1:-}" stamp="$AGENT_HOME/coord/refresh.stamp" lock_fd now last status=0
  coord_remote_init || return 3
  now="$(coord_now_s)" || return 3
  exec {lock_fd}>"$AGENT_HOME/coord/refresh.lock" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  last="$(cat "$stamp" 2>/dev/null || true)"
  if [[ "$force" != force && "$last" =~ ^[0-9]+$ ]] && (( now >= last && now - last < 30 )); then
    flock -u "$lock_fd" || :; exec {lock_fd}>&-
    return 0
  fi
  if git_fetch_bounded "$COORD_REMOTE_REPO" \
    '+refs/claims/*:refs/seen/claims/*' \
    '+refs/status/*:refs/seen/status/*' \
    '+refs/coord/*:refs/seen/coord/*' >/dev/null 2>&1; then
    printf '%s\n' "$now" >"$stamp" || status=3
  else
    echo "coord_refresh: remote coordination snapshot unknown" >&2
    status=3
  fi
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  return "$status"
}

coord_remote_scheduler_footprints() {
  local local_rows="${1:-[]}" refs ref key record owner kind unit stage held local_claim represented scope row output='[]'
  jq -e 'type == "array" and all(.[]; type == "object" and (.id | type == "string")
    and (.footprint | type == "array" and all(.[]; type == "string")))' <<<"$local_rows" >/dev/null 2>&1 || return 3
  coord_remote_refresh || return 3
  refs="$(git -C "$COORD_REMOTE_REPO" for-each-ref --format='%(refname)' refs/seen/claims 2>/dev/null)" || return 3
  while IFS= read -r ref; do
    [[ "$ref" == refs/seen/claims/* ]] || continue
    key="${ref#refs/seen/claims/}"
    [[ -n "$key" ]] || return 3
    record="$(git -C "$COORD_REMOTE_REPO" cat-file blob "$ref:claim.json" 2>/dev/null)" || return 3
    _coord_remote_record_valid "$key" "$record" || return 3
    owner="$(jq -r '.owner // empty' <<<"$record")" || return 3
    [[ -n "$owner" ]] || continue
    kind="$(jq -r '.owner_kind' <<<"$record")" || return 3
    stage="$(jq -r '.stage' <<<"$record")" || return 3
    [[ "$kind" == scheduler-worker && ( "$stage" == implement || "$stage" == repair ) ]] || continue
    unit="$(jq -r '.unit' <<<"$record")" || return 3
    represented=false
    jq -e --arg id "$unit" 'any(.[]; .id == $id)' <<<"$local_rows" >/dev/null 2>&1 && represented=true
    held="$AGENT_HOME/coord/held/$key"
    local_claim=false
    if [[ -r "$held" ]] && jq -e --arg owner "$owner" --arg unit "$unit" '.owner == $owner and .unit == $unit' "$held" >/dev/null 2>&1; then
      local_claim=true
    fi
    if [[ "$local_claim" == true && "$represented" == true ]]; then continue; fi
    if jq -e '
      type == "object"
      and ((has("checkpoint_truncated") | not) or (.checkpoint_truncated | type == "boolean"))
      and (.checkpoint_truncated // false) != true
      and (.checkpoint | type == "object")
      and (.checkpoint.unit | type == "object")
      and (.checkpoint.unit.footprint | type == "array" and all(.[];
        type == "string" and length > 0 and (startswith("/") | not)
        and ((split("/") | index("..")) == null) and ((split("/") | index(".")) == null)))
    ' <<<"$record" >/dev/null 2>&1; then
      scope="$(jq -c '.checkpoint.unit.footprint' <<<"$record")" || return 3
    elif [[ "$local_claim" == true && "$represented" == true ]]; then
      continue
    else
      echo "coord_footprints: writer checkpoint unavailable key=$key" >&2
      return 3
    fi
    row="$(jq -cn --arg id "$unit" --arg stage "$stage" --argjson footprint "$scope" \
      '{id:$id,stage:$stage,footprint:$footprint,remote_claim:true}')" || return 3
    output="$(jq -cn --argjson rows "$output" --argjson row "$row" '$rows + [$row]')" || return 3
  done <<<"$refs"
  printf '%s\n' "$output"
}


_coord_remote_cached_read() {
  local key="$1" ref="refs/seen/claims/$1" record status
  COORD_RECORD=""
  if git -C "$COORD_REMOTE_REPO" show-ref --verify --quiet "$ref"; then :; else
    status=$?
    (( status == 1 )) && return 1
    return 3
  fi
  record="$(git -C "$COORD_REMOTE_REPO" cat-file blob "$ref:claim.json" 2>/dev/null)" || return 3
  _coord_remote_record_valid "$key" "$record" \
    || { echo "coord_read: malformed or unsupported claim key=$key" >&2; return 3; }
  COORD_RECORD="$record"
  [[ -n "$(jq -r '.owner // empty' <<<"$record")" ]] || return 1
}

_coord_remote_read() {
  local key="$1" ref seen output oid remote_ref seen_oid record expires now
  COORD_RECORD="" COORD_REMOTE_OID="" COORD_REMOTE_EXPIRED=0
  _coord_paths "$key" || return 2
  coord_remote_init || return 3
  ref="refs/claims/$key"; seen="refs/seen/claims/$key"
  output="$(git -C "$COORD_REMOTE_REPO" ls-remote --refs origin "$ref" 2>/dev/null)" \
    || { echo "coord_read: remote claim read unknown key=$key" >&2; return 3; }
  [[ -n "$output" ]] || return 1
  [[ "$output" != *$'\n'* ]] || { echo "coord_read: ambiguous remote claim read key=$key" >&2; return 3; }
  IFS=$'\t' read -r oid remote_ref <<<"$output"
  [[ "$remote_ref" == "$ref" && "$oid" =~ ^[0-9a-f]{40,64}$ ]] \
    || { echo "coord_read: malformed remote ref key=$key" >&2; return 3; }
  git_fetch_bounded "$COORD_REMOTE_REPO" "+$ref:$seen" >/dev/null 2>&1 \
    || { echo "coord_read: remote claim fetch unknown key=$key" >&2; return 3; }
  seen_oid="$(git -C "$COORD_REMOTE_REPO" rev-parse "$seen" 2>/dev/null)" || return 3
  [[ "$seen_oid" == "$oid" ]] || { echo "coord_read: remote claim changed during read key=$key" >&2; return 3; }
  record="$(git -C "$COORD_REMOTE_REPO" cat-file blob "$seen:claim.json" 2>/dev/null)" || return 3
  _coord_remote_record_valid "$key" "$record" \
    || { echo "coord_read: malformed or unsupported claim key=$key" >&2; return 3; }
  COORD_RECORD="$record" COORD_REMOTE_OID="$oid"
  [[ -n "$(jq -r '.owner // empty' <<<"$record")" ]] || return 1
  expires="$(jq -r '.expires_at' <<<"$record")"
  now="$(coord_now_s)" || return 3
  (( expires > now )) || COORD_REMOTE_EXPIRED=1
  return 0
}

_coord_remote_store() {
  local key="$1" expected="$2" record="$3" ref blob tree commit output oid remote_ref
  coord_remote_init || return 3
  ref="refs/claims/$key"
  blob="$(printf '%s\n' "$record" | git -C "$COORD_REMOTE_REPO" hash-object -w --stdin)" || return 3
  tree="$(printf '100644 blob %s\tclaim.json\n' "$blob" | git -C "$COORD_REMOTE_REPO" mktree)" || return 3
  commit="$(GIT_AUTHOR_NAME=zenoforge-coord GIT_AUTHOR_EMAIL=zenoforge-coord@users.noreply.github.com \
    GIT_COMMITTER_NAME=zenoforge-coord GIT_COMMITTER_EMAIL=zenoforge-coord@users.noreply.github.com \
    git -C "$COORD_REMOTE_REPO" commit-tree "$tree" -m "claim $key")" || return 3
  output="$(git -C "$COORD_REMOTE_REPO" push --porcelain --force-with-lease="$ref:$expected" \
    origin "$commit:$ref" 2>&1)" || {
      if grep -qE '^!.*\((stale info|already exists)\)' <<<"$output"; then return 1; fi
      if output="$(git -C "$COORD_REMOTE_REPO" ls-remote --refs origin "$ref" 2>/dev/null)"; then
        [[ -n "$output" ]] || return 1
      else
        echo "coord_write: remote claim readback unknown key=$key" >&2
        return 3
      fi
      if [[ "$output" != *$'\n'* ]]; then
        IFS=$'\t' read -r oid remote_ref <<<"$output"
        [[ "$remote_ref" == "$ref" && "$oid" =~ ^[0-9a-f]{40,64}$ ]] || {
          echo "coord_write: remote claim readback malformed key=$key" >&2
          return 3
        }
        if [[ "$oid" == "$commit" ]]; then
          COORD_REMOTE_OID="$commit" COORD_RECORD="$record"
          return 0
        fi
        [[ "$oid" == "$expected" ]] || return 1
      fi
      echo "coord_write: remote claim update unknown key=$key" >&2
      return 3
    }
  grep -qE '^[*+=][[:space:]]' <<<"$output" || { echo "coord_write: remote claim update unconfirmed key=$key" >&2; return 3; }
  COORD_REMOTE_OID="$commit" COORD_RECORD="$record"
}

_coord_remote_observation_clear() {
  rm -f -- "$AGENT_HOME/coord/obs/$1"
}

_coord_remote_observe() {
  local key="$1" oid="$2" now dir path data first_seen old_value old_last tmp
  [[ "$oid" =~ ^[0-9a-f]{40,64}$ ]] || return 3
  now="$(coord_now_s)" || return 3
  now=$((10#$now))
  dir="$AGENT_HOME/coord/obs"
  path="$dir/$key"
  mkdir -p -- "$dir" || return 3
  first_seen="$now"
  if [[ -e "$path" ]]; then
    [[ -r "$path" ]] || return 3
    data="$(cat -- "$path")" || return 3
    if jq -e 'type == "object" and (.value|type == "string" and test("^[0-9a-f]{40,64}$"))
      and (.first_seen|type == "number" and floor == . and . >= 0)
      and (.last_seen|type == "number" and floor == . and . >= 0)' <<<"$data" >/dev/null 2>&1; then
      old_value="$(jq -r '.value' <<<"$data")"
      old_last="$(jq -r '.last_seen' <<<"$data")"
      if [[ "$old_value" == "$oid" ]] && (( now >= old_last )) && (( (now - old_last) * 2 <= COORD_LEASE_SECONDS )); then
        first_seen="$(jq -r '.first_seen' <<<"$data")"
      fi
    fi
  fi
  tmp="$(mktemp "$dir/.observation.XXXXXX")" || return 3
  if ! jq -cn --arg value "$oid" --argjson first "$first_seen" --argjson last "$now" \
      '{value:$value,first_seen:$first,last_seen:$last}' >"$tmp"; then
    rm -f -- "$tmp"
    return 3
  fi
  chmod 600 "$tmp" && mv -f -- "$tmp" "$path" || {
    rm -f -- "$tmp"
    return 3
  }
  (( now - first_seen >= COORD_LEASE_SECONDS ))
}

_coord_remote_held_write() {
  local key="$1" owner="$2" oid="$3" claim="$4" pid="${5:-}" pid_start="${6:-}" process_group="${7:-}"
  local dir="$AGENT_HOME/coord/held" path tmp now generation kind unit stage subject
  [[ "$oid" =~ ^[0-9a-f]{40,64}$ ]] || return 3
  now="$(coord_now_s)" || return 3
  generation="$(jq -r '.generation // 1' <<<"$claim")" || return 3
  [[ "$generation" =~ ^[1-9][0-9]*$ ]] || return 3
  kind="$(jq -r '.owner_kind // empty' <<<"$claim")" || return 3
  unit="$(jq -r '.unit // empty' <<<"$claim")" || return 3
  stage="$(jq -r '.stage // empty' <<<"$claim")" || return 3
  subject="$(jq -r '.subject // empty' <<<"$claim")" || return 3
  if [[ -z "$pid" ]]; then pid="$(jq -r '.pid // empty' <<<"$claim")" || return 3; fi
  if [[ -z "$pid_start" ]]; then pid_start="$(jq -r '.pid_start // empty' <<<"$claim")" || return 3; fi
  if [[ -z "$process_group" ]]; then process_group="$(jq -r '.process_group // empty' <<<"$claim")" || return 3; fi
  if [[ "$kind" == manual-worker && ! "$pid" =~ ^[1-9][0-9]*$ && "$owner" =~ ^owner-([1-9][0-9]*)- ]]; then
    pid="${BASH_REMATCH[1]}"
    if declare -F coord_process_start_ticks >/dev/null; then
      pid_start="$(coord_process_start_ticks "$pid" 2>/dev/null || true)"
    fi
  fi
  mkdir -p -- "$dir" || return 3
  path="$dir/$key"
  if [[ -r "$path" ]] && jq -e --arg owner "$owner" '.owner == $owner' "$path" >/dev/null 2>&1; then
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || pid="$(jq -r '.pid // empty' "$path")" || return 3
    [[ "$pid_start" =~ ^[0-9]+$ ]] || pid_start="$(jq -r '.pid_start // empty' "$path")" || return 3
    [[ "$process_group" =~ ^[1-9][0-9]*$ ]] || process_group="$(jq -r '.process_group // empty' "$path")" || return 3
  fi
  tmp="$(mktemp "$dir/.held.XXXXXX")" || return 3
  if ! jq -cn --arg key "$key" --arg owner "$owner" --arg oid "$oid" \
      --arg kind "$kind" --arg unit "$unit" --arg stage "$stage" --arg subject "$subject" \
      --arg pid "$pid" --arg pid_start "$pid_start" --arg process_group "$process_group" \
      --argjson generation "$generation" --argjson held_at "$now" \
      '{key:$key,owner:$owner,oid:$oid,generation:$generation,held_at:$held_at,owner_kind:$kind,unit:$unit,stage:$stage,subject:$subject}
       + (if $pid | test("^[1-9][0-9]*$") then {pid:($pid|tonumber)} else {} end)
       + (if $pid_start | test("^[0-9]+$") then {pid_start:($pid_start|tonumber)} else {} end)
       + (if $process_group | test("^[1-9][0-9]*$") then {process_group:($process_group|tonumber)} else {} end)' >"$tmp"; then
    rm -f -- "$tmp"
    return 3
  fi
  chmod 600 "$tmp" && mv -f -- "$tmp" "$path" || {
    rm -f -- "$tmp"
    return 3
  }
}

_coord_remote_held_remove_if_owner() {
  local key="$1" owner="$2" path="$AGENT_HOME/coord/held/$1"
  [[ -r "$path" ]] || return 0
  if jq -e --arg owner "$owner" '.owner == $owner' "$path" >/dev/null 2>&1; then
    rm -f -- "$path"
  fi
}

_coord_remote_acquire() {
  local key="$1" owner="$2" kind="$3" subject="$4" unit="$5" stage="$6"
  local status now record expected old_owner="" old_generation=0 generation old_checkpoint="" old_intents="" projection
  COORD_REMOTE_RESTORE_REQUIRED=0
  [[ -n "$owner" && -n "$kind" ]] || return 2
  [[ "$COORD_LEASE_SECONDS" =~ ^[1-9][0-9]*$ ]] || return 3
  _coord_paths "$key" || return 2
  if _coord_remote_read "$key"; then
    old_checkpoint="$(jq -c '.checkpoint // empty' <<<"$COORD_RECORD")" || return 3
    old_intents="$(jq -ce '(.intents // {}) | if type == "object" then . else error end' <<<"$COORD_RECORD")" || return 3
    old_owner="$(jq -r '.owner' <<<"$COORD_RECORD")"
    if [[ "$old_owner" == "$owner" ]]; then
      _coord_remote_observation_clear "$key" || return 3
      return 0
    fi
    expected="$COORD_REMOTE_OID"
    if _coord_remote_observe "$key" "$expected"; then status=0; else status=$?; fi
    (( status == 0 )) || return "$status"
    old_generation="$(jq -r '.generation // 1' <<<"$COORD_RECORD")" || return 3
    if _coord_remote_read "$key"; then
      [[ "$COORD_REMOTE_OID" == "$expected" ]] || return 1
    else
      status=$?
      return "$status"
    fi
  else
    status=$?
    (( status == 1 )) || return "$status"
    if [[ -n "$COORD_RECORD" ]]; then
      old_checkpoint="$(jq -c '.checkpoint // empty' <<<"$COORD_RECORD")" || return 3
      old_intents="$(jq -ce '(.intents // {}) | if type == "object" then . else error end' <<<"$COORD_RECORD")" || return 3
    fi
    expected="$COORD_REMOTE_OID"
    if [[ -n "$COORD_RECORD" ]]; then
      old_generation="$(jq -r '.generation // 1' <<<"$COORD_RECORD")" || return 3
    fi
  fi
  [[ "$old_generation" =~ ^[0-9]+$ ]] || return 3
  generation=$((old_generation + 1))
  now="$(coord_now_s)" || return 3
  record="$(jq -cn --arg key "$key" --arg owner "$owner" --arg kind "$kind" \
    --arg subject "$subject" --arg unit "$unit" --arg stage "$stage" --arg old_owner "$old_owner" \
    --argjson old_generation "$old_generation" --argjson generation "$generation" \
    --argjson now "$now" --argjson lease "$COORD_LEASE_SECONDS" \
    '{proto:1,version:1,key:$key,owner:$owner,owner_kind:$kind,subject:$subject,unit:$unit,stage:$stage,
      generation:$generation,acquired_at:$now,renewed_at:$now,expires_at:($now+$lease)}
      + (if $old_owner == "" then {} else {taken_from:{owner:$old_owner,generation:$old_generation}} end)')" || return 3
  if [[ -n "$old_intents" ]]; then
    record="$(jq -cn --argjson record "$record" --argjson intents "$old_intents" '$record + {intents:$intents}')" || return 3
  fi
  if [[ -n "$old_checkpoint" ]]; then
    record="$(jq -cn --argjson record "$record" --argjson checkpoint "$old_checkpoint" \
      '$record + {checkpoint:$checkpoint}')" || return 3
    COORD_REMOTE_RESTORE_REQUIRED=1
  elif [[ "$kind" == effect ]]; then
    :
  else
    projection="$(coord_checkpoint_project "$subject" "$unit")" || return 3
    record="$(coord_checkpoint_fit_claim "$record" "$projection")" || return 3
  fi
  _coord_remote_store "$key" "$expected" "$record" || return $?
  _coord_remote_observation_clear "$key" || return 3
}

_coord_remote_renew() {
  local key="$1" owner="$2" status now record subject unit projection old_unit
  if _coord_remote_read "$key"; then :; else status=$?; return "$status"; fi
  [[ "$(jq -r '.owner' <<<"$COORD_RECORD")" == "$owner" ]] || return 1
  (( COORD_REMOTE_EXPIRED == 0 )) || return 3
  subject="$(jq -r '.subject' <<<"$COORD_RECORD")" || return 3
  unit="$(jq -r '.unit' <<<"$COORD_RECORD")" || return 3
  projection="$(coord_checkpoint_project "$subject" "$unit")" || return 3
  if jq -e '.checkpoint.unit | type == "object" and length > 0' <<<"$COORD_RECORD" >/dev/null 2>&1 \
    && jq -e '.unit == {}' <<<"$projection" >/dev/null 2>&1; then
    old_unit="$(jq -c '.checkpoint.unit' <<<"$COORD_RECORD")" || return 3
    projection="$(jq -cn --argjson projection "$projection" --argjson unit "$old_unit" \
      '$projection | .unit=$unit')" || return 3
  fi
  record="$(coord_checkpoint_fit_claim "$COORD_RECORD" "$projection")" || return 3
  now="$(coord_now_s)" || return 3
  record="$(jq -c --argjson now "$now" --argjson lease "$COORD_LEASE_SECONDS" \
    '.renewed_at=$now | .expires_at=($now+$lease)' <<<"$record")" || return 3
  _coord_remote_store "$key" "$COORD_REMOTE_OID" "$record"
}

_coord_remote_release() {
  local key="$1" owner="$2" status now record
  if _coord_remote_read "$key"; then :; else status=$?; return "$status"; fi
  [[ "$(jq -r '.owner' <<<"$COORD_RECORD")" == "$owner" ]] || return 1
  now="$(coord_now_s)" || return 3
  record="$(jq -c --argjson now "$now" '.last_owner=.owner | .owner=null | .expires_at=0 | .released_at=$now | .release_reason="released"' <<<"$COORD_RECORD")" || return 3
  _coord_remote_store "$key" "$COORD_REMOTE_OID" "$record"
}

_coord_remote_assert_owned() {
  local key="$1" owner="$2" status held="$AGENT_HOME/coord/held/$1" now held_at deadline
  [[ -r "$held" ]] || return 3
  jq -e --arg key "$key" --arg owner "$owner" \
    'type == "object" and .key == $key and .owner == $owner and .lost != true
     and (.held_at | type == "number" and floor == . and . >= 0)' \
    "$held" >/dev/null 2>&1 || return 3
  now="$(coord_now_s)" || return 3
  held_at="$(jq -r '.held_at' "$held")" || return 3
  deadline="${ZF_COORD_SELF_FENCE_S:-600}"
  [[ "$deadline" =~ ^[1-9][0-9]*$ ]] || return 3
  (( now >= held_at && now - held_at < deadline )) || return 3
  if _coord_remote_read "$key"; then :; else status=$?; return "$status"; fi
  [[ "$(jq -r '.owner' <<<"$COORD_RECORD")" == "$owner" ]] || return 1
  (( COORD_REMOTE_EXPIRED == 0 )) || return 3
}

