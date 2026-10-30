#!/usr/bin/env bash
# Complete existing terminal-owner cleanup events; scheduler intake is separate.
hand_completion_event_dir() {
  printf '%s/hand-completion-events\n' "${ZF_NIGHT_DIR:-$AGENT_HOME/night}"
}

hand_completion_identity_terminal() {
  local pid="$1" ticks="$2" fields
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$ticks" =~ ^[0-9]+$ ]] || return 2
  if [ -d "/proc/$pid" ]; then
    fields="$(cat "/proc/$pid/stat")" || return 75
    fields="${fields##*) }"; read -r -a fields <<< "$fields"
    [[ "${fields[19]}" != "$ticks" || "${fields[0]}" = Z ]] || return 75
  fi
}

# Atomic first publication precedes every heavy admission; duplicates cannot
# reset a partially completed continuation, including its terminal receipt.
hand_completion_event_publish() {
  local pid="$1" ticks="$2" target="$3" dir tmp
  hand_completion_identity_terminal "$pid" "$ticks" || return $?
  dir="$(hand_completion_event_dir)"; mkdir -p -- "$dir" || return 1
  HAND_COMPLETION_EVENT="$dir/$pid-$ticks.json"
  tmp="$(mktemp "$dir/.publish.XXXXXX")" || return 1
  if ! jq -cn --argjson pid "$pid" --arg ticks "$ticks" --arg worktree "$target" \
    '{pid:$pid,start_ticks:$ticks,worktree:$worktree,phase:"cleanup"}' > "$tmp"; then
    rm -f -- "$tmp"; return 1
  fi
  if ! ln -- "$tmp" "$HAND_COMPLETION_EVENT" 2>/dev/null && [ ! -f "$HAND_COMPLETION_EVENT" ]; then
    rm -f -- "$tmp"; return 1
  fi
  rm -f -- "$tmp"
}

hand_completion_events_pending() {
  local dir status=0
  local -a files=()
  dir="$(hand_completion_event_dir)"
  shopt -s nullglob; files=("$dir"/*.json); shopt -u nullglob
  ((${#files[@]})) || return 1
  # Unreadable is pending, never an invented empty/success result.
  jq -se 'any(.[]; .phase != "done")' "${files[@]}" >/dev/null 2>&1 || status=$?
  [ "$status" != 1 ]
}

hand_completion_event_run() {
  local repo="$1" file="$2" event_fd entry pid ticks target phase status=0 tmp guard
  [[ "${file##*/}" =~ ^([1-9][0-9]*)-([0-9]+)\.json$ ]] || return 75
  pid="${BASH_REMATCH[1]}"; ticks="${BASH_REMATCH[2]}"
  exec {event_fd}>>"$file.lock" || return 1
  if ! flock -n "$event_fd"; then exec {event_fd}>&-; return 75; fi
  entry="$(jq -ce --argjson pid "$pid" --arg ticks "$ticks" '
    select(keys == ["phase","pid","start_ticks","worktree"] and .pid == $pid and .start_ticks == $ticks
      and (.worktree | type == "string" and startswith("/") and (test("[\\r\\n\\t]") | not))
      and (.phase == "cleanup" or .phase == "refill" or .phase == "done"))' "$file" 2>/dev/null)" \
    || { exec {event_fd}>&-; return 75; }
  phase="$(jq -r .phase <<< "$entry")"
  if [ "$phase" = done ]; then exec {event_fd}>&-; return 0; fi
  if ! hand_completion_identity_terminal "$pid" "$ticks"; then exec {event_fd}>&-; return 75; fi
  target="$(jq -r .worktree <<< "$entry")"
  guard="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/execution-admission.py"
  if [ "$phase" = cleanup ]; then
    python3 "$guard" run -- bash "${guard%/*}/worktree-lifecycle.sh" watch-cleanup "$repo" "$target" "$pid" "$ticks" || status=$?
    if [ "$status" != 0 ]; then exec {event_fd}>&-; return "$status"; fi
    tmp="$(mktemp "$file.XXXXXX")" || { exec {event_fd}>&-; return 75; }
    if ! jq '.phase = "refill"' <<< "$entry" > "$tmp" || ! mv -- "$tmp" "$file"; then
      rm -f -- "$tmp"; exec {event_fd}>&-; return 75
    fi
  fi
  # Ready intake already belongs to the autopilot scheduler. There is no hand
  # queue to refill after cleanup, and calling the old no-op slice here would
  # contend with the enclosing pipeline tick's decision lock.
  tmp="$(mktemp "$file.XXXXXX")" || { exec {event_fd}>&-; return 75; }
  if ! jq '.phase = "done"' "$file" > "$tmp" || ! mv -- "$tmp" "$file"; then
    rm -f -- "$tmp"; exec {event_fd}>&-; return 75
  fi
  exec {event_fd}>&-
  return 0
}

# One existing consumer pass, no watcher/poll loop. Its normal backoff retries.
hand_completion_events_run_once() {
  local repo="$1" dir file phase status=0
  local -a files=()
  dir="$(hand_completion_event_dir)"
  shopt -s nullglob; files=("$dir"/*.json); shopt -u nullglob
  for file in "${files[@]}"; do
    phase="$(jq -er .phase "$file" 2>/dev/null)" || { status=75; continue; }
    [ "$phase" != done ] || continue
    if hand_completion_event_run "$repo" "$file"; then return 0; else status=$?; fi
  done
  return "$status"
}
