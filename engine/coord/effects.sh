#!/usr/bin/env bash

_effect_write_intent() {
  local claim="$1" owner="$2" effect_key="$3" intent="$4" expected="${5:-any}" record now lock_fd rc
  if coord_remote_enabled; then
    if _coord_remote_read "$claim"; then :; else return $?; fi
    [[ "$(jq -r '.owner // empty' <<<"$COORD_RECORD")" == "$owner" ]] || return 1
    (( COORD_REMOTE_EXPIRED == 0 )) || return 3
    if [[ "$expected" == absent ]] && jq -e --arg key "$effect_key" '(.intents // {}) | has($key)' <<<"$COORD_RECORD" >/dev/null; then return 1; fi
    if [[ "$expected" == pending ]] && ! jq -e --arg key "$effect_key" '.intents[$key].state == "pending"' <<<"$COORD_RECORD" >/dev/null; then return 1; fi
    record="$(jq -c --arg key "$effect_key" --argjson intent "$intent" '
      .intents = (.intents // {}) | .intents[$key]=$intent
      | if $intent.state == "done" then
          ([.intents | to_entries | map(select(.value.state == "done"))
            | sort_by(.value.completed_seq // 0)
            | if length > 20 then .[:length-20] else [] end | map(.key)]) as $drop
          | .intents |= with_entries(select(.key as $entry_key | ($drop | index($entry_key)) == null))
        else . end
    ' <<<"$COORD_RECORD")" || return 3
    (( ${#record} <= 16384 )) || return 3
    _coord_remote_store "$claim" "$COORD_REMOTE_OID" "$record"
    return $?
  fi
  _coord_paths "$claim" || return 2
  mkdir -p -- "$COORD_DIR" || return 3
  exec {lock_fd}>"$COORD_LOCK_FILE" || return 3
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 3; }
  _coord_read_locked "$claim"; rc=$?
  if (( rc == 0 )); then
    [[ "$(jq -r '.owner' <<<"$COORD_RECORD")" == "$owner" ]] || rc=1
  fi
  if (( rc == 0 )) && [[ "$expected" == absent ]] \
    && jq -e --arg key "$effect_key" '(.intents // {}) | has($key)' <<<"$COORD_RECORD" >/dev/null; then rc=1; fi
  if (( rc == 0 )) && [[ "$expected" == pending ]] \
    && ! jq -e --arg key "$effect_key" '.intents[$key].state == "pending"' <<<"$COORD_RECORD" >/dev/null; then rc=1; fi
  if (( rc == 0 )); then
    now="$(coord_now_s)" || rc=3
    (( rc != 0 )) || (( $(jq -r '.expires_at' <<<"$COORD_RECORD") > now )) || rc=3
  fi
  if (( rc == 0 )); then
    record="$(jq -c --arg key "$effect_key" --argjson intent "$intent" '
      .intents = (.intents // {}) | .intents[$key]=$intent
      | if $intent.state == "done" then
          ([.intents | to_entries | map(select(.value.state == "done"))
            | sort_by(.value.completed_seq // 0)
            | if length > 20 then .[:length-20] else [] end | map(.key)]) as $drop
          | .intents |= with_entries(select(.key as $entry_key | ($drop | index($entry_key)) == null))
        else . end
    ' <<<"$COORD_RECORD")" || rc=3
    (( rc != 0 || ${#record} <= 16384 )) || rc=3
    (( rc != 0 )) || _coord_write_locked "$claim" "$record" || rc=3
  fi
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  return "$rc"
}

_effect_read_owned() {
  local claim="$1" owner="$2"
  if coord_remote_enabled; then
    if _coord_remote_read "$claim"; then :; else return $?; fi
    [[ "$(jq -r '.owner // empty' <<<"$COORD_RECORD")" == "$owner" ]] || return 1
    (( COORD_REMOTE_EXPIRED == 0 )) || return 3
    printf '%s\n' "$COORD_RECORD"
  else
    coord_assert_owned "$claim" "$owner"
  fi
}

effect_claim_for() {
  local effect_key="${1:-}" claim
  [[ -n "$effect_key" ]] || return 2
  if [[ -n "${ZF_COORD_KEY:-}" && -n "${ZF_COORD_OWNER:-}" ]]; then
    printf '%s\n' "$ZF_COORD_KEY"
    return 0
  fi
  claim="${effect_key//[^A-Za-z0-9._-]/-}"
  printf 'effect-%s\n' "$claim"
}

effect_begin() {
  local claim="${1:-}" effect_key="${2:-}" kind="${3:-}" class="" owner intent record generation started
  [[ $# -ge 3 && "$claim" =~ ^[A-Za-z0-9._-]+$ && "$effect_key" =~ ^[A-Za-z0-9._:/@+.-]+$ ]] || return 2
  shift 3
  case "$kind" in
    merge|push|revert) class=idempotent ;;
    deploy|mail|comment) class=once ;;
    *) return 2 ;;
  esac
  while (($#)); do
    case "$1" in
      --class) (($# >= 2)) || return 2; class="$2"; shift 2 ;;
      *) return 2 ;;
    esac
  done
  [[ "$class" == idempotent || "$class" == once ]] || return 2
  owner="${ZF_COORD_OWNER:-${COORD_ENTRY_OWNER:-}}"
  [[ -n "$owner" ]] || return 2
  if coord_remote_enabled; then
    if _coord_remote_read "$claim"; then :; else return $?; fi
    [[ "$(jq -r '.owner // empty' <<<"$COORD_RECORD")" == "$owner" ]] || return 1
    (( COORD_REMOTE_EXPIRED == 0 )) || return 3
    record="$COORD_RECORD"
  else
    record="$(coord_assert_owned "$claim" "$owner")" || return $?
  fi
  if jq -e --arg key "$effect_key" '(.intents // {}) | has($key)' <<<"$record" >/dev/null; then
    EFFECT_STATE="$(jq -r --arg key "$effect_key" '.intents[$key].state' <<<"$record")"
    return 1
  fi
  generation="$(jq -r '.generation // .gen // 1' <<<"$record")" || return 3
  started="$(coord_now_s)" || return 3
  intent="$(jq -cn --arg kind "$kind" --arg class "$class" --arg owner "$owner" \
    --argjson generation "$generation" --argjson started "$started" \
    '{kind:$kind,class:$class,state:"pending",gen:$generation,run:$owner,started_at:$started}')" || return 3
  _effect_write_intent "$claim" "$owner" "$effect_key" "$intent" absent
}

effect_complete() {
  local claim="${1:-}" effect_key="${2:-}" result="${3:-}" owner record intent updated completed_seq completed_at
  [[ $# == 3 && "$claim" =~ ^[A-Za-z0-9._-]+$ && "$effect_key" =~ ^[A-Za-z0-9._:/@+.-]+$ ]] || return 2
  jq -e . <<<"$result" >/dev/null 2>&1 || return 2
  owner="${ZF_COORD_OWNER:-${COORD_ENTRY_OWNER:-}}"
  [[ -n "$owner" ]] || return 2
  if coord_remote_enabled; then
    if _coord_remote_read "$claim"; then :; else return $?; fi
    [[ "$(jq -r '.owner // empty' <<<"$COORD_RECORD")" == "$owner" ]] || return 1
    (( COORD_REMOTE_EXPIRED == 0 )) || return 3
    record="$COORD_RECORD"
  else
    record="$(coord_assert_owned "$claim" "$owner")" || return $?
  fi
  intent="$(jq -c --arg key "$effect_key" '.intents[$key] // empty' <<<"$record")" || return 3
  [[ -n "$intent" && "$(jq -r '.state' <<<"$intent")" == pending ]] || return 1
  completed_seq="$(jq -r '([.intents[]?.completed_seq] | map(select(type=="number")) | max // 0) + 1' <<<"$record")" || return 3
  completed_at="$(coord_now_s)" || return 3
  updated="$(jq -cn --argjson intent "$intent" --argjson result "$result" \
    --argjson completed_seq "$completed_seq" --argjson completed_at "$completed_at" \
    '$intent | .state="done" | .result=$result | .completed_seq=$completed_seq | .completed_at=$completed_at')" || return 3
  _effect_write_intent "$claim" "$owner" "$effect_key" "$updated" pending
}

effect_unknown() {
  local claim="${1:-}" effect_key="${2:-}" reason="${3:-}" owner record intent updated
  [[ $# == 3 && "$claim" =~ ^[A-Za-z0-9._-]+$ && "$effect_key" =~ ^[A-Za-z0-9._:/@+.-]+$ ]] || return 2
  owner="${ZF_COORD_OWNER:-${COORD_ENTRY_OWNER:-}}"
  [[ -n "$owner" ]] || return 2
  record="$(_effect_read_owned "$claim" "$owner")" || return $?
  intent="$(jq -c --arg key "$effect_key" '.intents[$key] // empty' <<<"$record")" || return 3
  [[ -n "$intent" && "$(jq -r '.state' <<<"$intent")" == pending ]] || return 1
  updated="$(jq -cn --argjson intent "$intent" --arg reason "$reason" \
    '$intent | .state="unknown" | .reason=$reason')" || return 3
  _effect_write_intent "$claim" "$owner" "$effect_key" "$updated" pending
}

effect_reconcile() {
  local claim="${1:-}" only_key="${2:-}" owner record keys effect_key intent script output status repo repo_dir
  [[ $# -ge 1 && $# -le 2 && "$claim" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  owner="${ZF_COORD_OWNER:-${COORD_ENTRY_OWNER:-}}"
  [[ -n "$owner" ]] || return 2
  repo="${REPO:-${ZF_REPO:-}}"
  repo_dir="${REPO_DIR:-${ZF_REPO_DIR:-}}"
  record="$(_effect_read_owned "$claim" "$owner")" || return $?
  if [[ -n "$only_key" ]]; then
    keys="$only_key"
  else
    keys="$(jq -r '(.intents // {}) | to_entries[] | select(.value.state == "pending") | .key' <<<"$record")" || return 3
  fi
  while IFS= read -r effect_key; do
    [[ -n "$effect_key" ]] || continue
    intent="$(jq -c --arg key "$effect_key" '.intents[$key] // empty' <<<"$record")" || return 3
    [[ -n "$intent" && "$(jq -r '.state' <<<"$intent")" == pending ]] || continue
    script="$(dirname -- "${BASH_SOURCE[0]}")/reconcile.d/$(jq -r '.kind' <<<"$intent").sh"
    [[ -r "$script" ]] || return 3
    if output="$(REPO="$repo" REPO_DIR="$repo_dir" ZF_REPO="${ZF_REPO:-$repo}" \
      ZF_REPO_DIR="${ZF_REPO_DIR:-$repo_dir}" bash "$script" "$claim" "$effect_key" "$intent")"; then
      status=0
    else
      status=$?
    fi
    case "$status" in
      0)
        jq -e . <<<"$output" >/dev/null 2>&1 || return 3
        effect_complete "$claim" "$effect_key" "$output" || return $?
        ;;
      1) ;;
      2)
        effect_unknown "$claim" "$effect_key" "$(jq -r '.kind' <<<"$intent") unresolved" || return $?
        if declare -F supervisor_inbox_append >/dev/null; then
          supervisor_inbox_append effect-unknown "claim=$claim key=$effect_key" || return 3
        fi
        ;;
      *) return 3 ;;
    esac
    record="$(_effect_read_owned "$claim" "$owner")" || return $?
  done <<<"$keys"
}

_effect_run_owned() {
  local claim="${1:-}" effect_key="${2:-}" kind="${3:-}" owner record intent state tmp result rc output
  [[ $# -ge 5 && "$claim" =~ ^[A-Za-z0-9._-]+$ && "$effect_key" =~ ^[A-Za-z0-9._:/@+.-]+$ && "$4" == -- ]] || return 2
  shift 4
  (($#)) || return 2
  owner="${ZF_COORD_OWNER:-${COORD_ENTRY_OWNER:-}}"
  [[ -n "$owner" ]] || return 2
  record="$(_effect_read_owned "$claim" "$owner")" || return $?
  if jq -e --arg key "$effect_key" '(.intents // {}) | has($key)' <<<"$record" >/dev/null; then
    intent="$(jq -c --arg key "$effect_key" '.intents[$key]' <<<"$record")" || return 3
    state="$(jq -r '.state' <<<"$intent")" || return 3
    case "$state" in
      done)
        output="$(jq -r '.result.stdout // empty' <<<"$intent")" || return 3
        printf '%s' "$output"
        return 0
        ;;
      pending)
        effect_reconcile "$claim" "$effect_key" || return $?
        record="$(_effect_read_owned "$claim" "$owner")" || return $?
        intent="$(jq -c --arg key "$effect_key" '.intents[$key]' <<<"$record")" || return 3
        state="$(jq -r '.state' <<<"$intent")" || return 3
        if [[ "$state" == done ]]; then
          output="$(jq -r '.result.stdout // empty' <<<"$intent")" || return 3
          printf '%s' "$output"
          return 0
        fi
        [[ "$state" == pending && "$(jq -r '.class' <<<"$intent")" == idempotent ]] || return 3
        ;;
      unknown) return 3 ;;
      *) return 3 ;;
    esac
  else
    effect_begin "$claim" "$effect_key" "$kind" || return $?
  fi
  tmp="$(mktemp)" || return 3
  if "$@" >"$tmp"; then rc=0; else rc=$?; fi
  if (( rc == 0 )); then
    result="$(jq -cn --rawfile stdout "$tmp" '{stdout:$stdout}')" || rc=3
    (( rc != 0 )) || effect_complete "$claim" "$effect_key" "$result" || rc=$?
  fi
  cat -- "$tmp" || { rm -f -- "$tmp"; return 3; }
  rm -f -- "$tmp"
  return "$rc"
}

effect_run() {
  local claim="${1:-}" effect_key="${2:-}" kind="${3:-}" owner status
  [[ $# -ge 5 && "$claim" =~ ^[A-Za-z0-9._-]+$ && "$effect_key" =~ ^[A-Za-z0-9._:/@+.-]+$ && "$4" == -- ]] || return 2
  owner="${ZF_COORD_OWNER:-${COORD_ENTRY_OWNER:-}}"
  if [[ -n "$owner" ]]; then
    _effect_run_owned "$@"
    return $?
  fi
  owner="$(coord_new_owner)" || return 3
  if ZF_COORD_OWNER="$owner" coord_acquire "$claim" "$owner" effect "$effect_key" "effect-$kind" effect; then
    :
  else
    status=$?
    return "$status"
  fi
  if ZF_COORD_OWNER="$owner" _effect_run_owned "$@"; then status=0; else status=$?; fi
  ZF_COORD_OWNER="$owner" coord_release "$claim" "$owner" >/dev/null 2>&1 || status=3
  return "$status"
}
