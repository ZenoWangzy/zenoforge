#!/usr/bin/env bash
# Runtime canary for engine-sync swaps. State is stored beside engine versions;
# immutable version directories are only read.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/runtime-env.sh"

VERSIONS="$AGENT_HOME/engine-versions"
STATE="$VERSIONS/.swap-record.json"
SWAPS="$VERSIONS/.swap-history.jsonl"
HISTORY="$VERSIONS/.canary-ticks.jsonl"
TICK_START="$MAC_AUTOPILOT_RUNTIME_DIR/.engine-canary-tick.json"
SCHED_LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
LOOP_LOG="$MAC_AUTOPILOT_RUNTIME_DIR/loop.out"

mkdir -p "$VERSIONS" "$MAC_AUTOPILOT_RUNTIME_DIR"

file_bytes() {
  [[ -f "$1" ]] || { printf '0'; return; }
  wc -c < "$1" | tr -d '[:space:]'
}

log_target() {
  readlink -- "$1" 2>/dev/null || true
}

live_engine_id() {
  local resolved
  resolved="$(readlink -e -- "$AGENT_HOME/engine-live" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || return 0
  if [[ "$resolved" =~ /engine-versions/([^/]+)/engine/?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    basename -- "$(dirname -- "$resolved")"
  fi
}

live_autopi_id() {
  local resolved
  resolved="$(readlink -e -- "$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || return 0
  if [[ "$resolved" =~ /autopi-versions/([^/]+)/ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$resolved" =~ /engine-versions/([^/]+)/engine/ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    basename -- "$(dirname -- "$(dirname -- "$resolved")")"
  fi
}

canary_ticks() {
  local ticks=2
  if [[ -r "$MAC_AUTOPILOT_RUNTIME_DIR/config.json" ]]; then
    ticks="$(jq -r '.engine.canary_ticks // 2' "$MAC_AUTOPILOT_RUNTIME_DIR/config.json" 2>/dev/null || printf '2')"
  fi
  [[ "$ticks" =~ ^[0-9]+$ ]] || ticks=2
  printf '%s' "$ticks"
}

was_live() {
  local id="$1"
  [[ -r "$SWAPS" ]] && jq -e -s --arg id "$id" \
    'any(.[]; .old_id == $id or .new_id == $id)' "$SWAPS" >/dev/null 2>&1
}

atomic_link_replace() { # path, original link target
  local link="$1" target="$2" temp="$1.rollback.$$"
  [[ -n "$target" ]] || return 1
  ln -sfn -- "$target" "$temp" && mv -Tf -- "$temp" "$link"
}

extract_signatures() { # appended log bytes, line oriented, normalized signature output
  local line file variable command
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ jqf\ error\ \(rc=([0-9]+)\)\ in\ ([[:alnum:]_]+) ]]; then
      printf 'jqf error (rc=%s) in %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      continue
    fi
    if [[ "$line" == *TICK-TIMEOUT* ]]; then
      printf 'TICK-TIMEOUT\n'
      continue
    fi
    if [[ "$line" == *REFILL-TIMEOUT* ]]; then
      printf 'REFILL-TIMEOUT\n'
      continue
    fi
    if [[ "$line" =~ ((scheduler\.d|lib\.d)/[^[:space:]]+) ]]; then
      file="${BASH_REMATCH[1]%%:*}"
      if [[ "$line" == *'unbound variable'* ]] &&
        [[ "$line" =~ :[[:space:]]*([[:alnum:]_]+):[[:space:]]*unbound\ variable ]]; then
        variable="${BASH_REMATCH[1]}"
        printf 'unbound variable in %s: %s\n' "$file" "$variable"
        continue
      fi
      if [[ "$line" == *'command not found'* ]] &&
        [[ "$line" =~ :[[:space:]]*([^:[:space:]]+):[[:space:]]*command\ not\ found ]]; then
        command="${BASH_REMATCH[1]}"
        printf 'command not found in %s: %s\n' "$file" "$command"
        continue
      fi
    fi
  done
}

read_after_offset() { # file, byte offset
  local file="$1" offset="$2" bytes
  [[ -f "$file" ]] || return 0
  bytes="$(file_bytes "$file")"
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  (( offset <= bytes )) || offset=0 # rotated/truncated since the last tick
  tail -c +$((offset + 1)) -- "$file" 2>/dev/null || true
}

append_history() { # engine id, signatures file, completed time
  local engine_id="$1" sig_file="$2" completed_at="$3" signatures row
  signatures="$(jq -Rsc 'split("\n") | map(select(length > 0))' < "$sig_file")"
  row="$(jq -cn --arg engine_id "$engine_id" --arg completed_at "$completed_at" \
    --argjson signatures "$signatures" \
    '{engine_id:$engine_id,completed_at:$completed_at,signatures:$signatures}')"
  printf '%s\n' "$row" >> "$HISTORY"
}

record_swap() {
  (($# == 6)) || { echo 'usage: engine-canary.sh record-swap OLD NEW OLD_ENGINE_LINK NEW_ENGINE_LINK OLD_AUTOPI_LINK NEW_AUTOPI_LINK' >&2; return 2; }
  local old_id="$1" new_id="$2" old_engine_target="$3" new_engine_target="$4"
  local old_autopi_target="$5" new_autopi_target="$6" ticks baseline count time generation tmp
  [[ "$old_id" != "$new_id" ]] || return 0
  ticks="$(canary_ticks)"
  baseline='[]'; count=0
  if [[ -r "$HISTORY" ]] && (( ticks > 0 )); then
    baseline="$(jq -sc --arg old "$old_id" --argjson n "$ticks" \
      '[.[] | select(.engine_id == $old)] | .[-$n:] | map(.signatures // []) | add // [] | unique' \
      "$HISTORY" 2>/dev/null || printf '[]')"
    count="$(jq -sc --arg old "$old_id" --argjson n "$ticks" \
      '[.[] | select(.engine_id == $old)] | .[-$n:] | length' "$HISTORY" 2>/dev/null || printf '0')"
  fi
  time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  generation="$time-$new_id-$$-$RANDOM"
  tmp="$(mktemp "$VERSIONS/.swap-record.XXXXXX")"
  jq -cn --arg old_id "$old_id" --arg new_id "$new_id" --arg swapped_at "$time" \
    --arg generation "$generation" --arg old_engine_target "$old_engine_target" \
    --arg new_engine_target "$new_engine_target" --arg old_autopi_target "$old_autopi_target" \
    --arg new_autopi_target "$new_autopi_target" --argjson canary_ticks "$ticks" \
    --argjson baseline_signatures "$baseline" --argjson baseline_ticks "$count" \
    --argjson scheduler_offset "$(file_bytes "$SCHED_LOG")" --argjson loop_offset "$(file_bytes "$LOOP_LOG")" \
    '{old_id:$old_id,new_id:$new_id,swapped_at:$swapped_at,generation:$generation,
      old_engine_target:$old_engine_target,new_engine_target:$new_engine_target,
      old_autopi_target:$old_autopi_target,new_autopi_target:$new_autopi_target,
      canary_ticks:$canary_ticks,remaining_ticks:$canary_ticks,baseline_ticks:$baseline_ticks,
      baseline_signatures:$baseline_signatures,scheduler_offset:$scheduler_offset,loop_offset:$loop_offset,
      status:(if $canary_ticks == 0 then "passed" else "pending" end)}' > "$tmp"
  mv -f -- "$tmp" "$STATE"
  printf '%s\n' "$(jq -c '{old_id,new_id,swapped_at,old_engine_target,new_engine_target,old_autopi_target,new_autopi_target}' "$STATE")" >> "$SWAPS"
}

tick_begin() {
  local state_generation='' engine_id='' autopi_target autopi_id
  if [[ -r "$STATE" ]]; then
    state_generation="$(jq -r 'select(.status == "pending") | .generation // empty' "$STATE" 2>/dev/null || true)"
  fi
  engine_id="$(live_engine_id)"
  autopi_target="$(log_target "$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live")"
  autopi_id="$(live_autopi_id)"
  local tmp
  tmp="$(mktemp "$MAC_AUTOPILOT_RUNTIME_DIR/.engine-canary-tick.XXXXXX")"
  jq -cn --arg generation "$state_generation" --arg engine_id "$engine_id" \
    --arg autopi_target "$autopi_target" --arg autopi_id "$autopi_id" \
    --arg started_at "$(date +%s)" --argjson scheduler_offset "$(file_bytes "$SCHED_LOG")" \
    --argjson loop_offset "$(file_bytes "$LOOP_LOG")" \
    '{generation:$generation,engine_id:$engine_id,autopi_target:$autopi_target,autopi_id:$autopi_id,
      started_at:($started_at|tonumber),
      scheduler_offset:$scheduler_offset,loop_offset:$loop_offset}' > "$tmp"
  mv -f -- "$tmp" "$TICK_START"
}

rollback() { # first new signature
  local signature="$1" old_id new_id old_engine_target new_engine_target old_autopi_target new_autopi_target
  local engine_link="$AGENT_HOME/engine-live" autopi_link="$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live"
  local log_line at old_engine_dir marker tmp
  old_id="$(jq -r '.old_id' "$STATE")"; new_id="$(jq -r '.new_id' "$STATE")"
  old_engine_target="$(jq -r '.old_engine_target' "$STATE")"
  new_engine_target="$(jq -r '.new_engine_target' "$STATE")"
  old_autopi_target="$(jq -r '.old_autopi_target' "$STATE")"
  new_autopi_target="$(jq -r '.new_autopi_target' "$STATE")"
  [[ "$(live_engine_id)" == "$new_id" ]] || return 0
  [[ -n "$old_autopi_target" && -n "$old_engine_target" ]] || {
    echo "engine-canary: cannot roll back $new_id: previous live links were not recorded" >&2
    return 1
  }
  atomic_link_replace "$engine_link" "$old_engine_target"
  atomic_link_replace "$autopi_link" "$old_autopi_target"
  marker="$VERSIONS/.failed-$new_id"
  [[ "$new_id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "engine-canary: unsafe version id $new_id" >&2; return 1; }
  : > "$marker"
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log_line="ROLLBACK engine $new_id -> $old_id: $signature"
  printf '[%s] %s\n' "$at" "$log_line" >> "$SCHED_LOG"
  old_engine_dir="$(readlink -e -- "$engine_link" 2>/dev/null || true)"
  AGENT_HOME="$AGENT_HOME" ZF_ENGINE_DIR="$old_engine_dir" ZF_REPO_DIR="$MAC_AUTOPILOT_ROOT" \
    bash -c 'source "$ZF_ENGINE_DIR/lib.sh" && supervisor_inbox_append_once "$1" "$2"' \
      engine-canary "engine-canary-rollback:$new_id:$old_id" "$log_line"
  tmp="$(mktemp "$VERSIONS/.swap-record.XXXXXX")"
  jq --arg signature "$signature" --arg rolled_back_at "$at" \
    '.status="rolled-back" | .first_new_signature=$signature | .rolled_back_at=$rolled_back_at' \
    "$STATE" > "$tmp"
  mv -f -- "$tmp" "$STATE"
}

tick_complete() {
  [[ -r "$TICK_START" ]] || return 0
  local tmpdir start_generation start_engine_id start_autopi_target start_autopi_id current_generation status new_id current_id new_autopi_target
  local scheduler_offset loop_offset tick_scheduler_offset tick_done=0 first_new=''
  tmpdir="$(mktemp -d "$MAC_AUTOPILOT_RUNTIME_DIR/.engine-canary-complete.XXXXXX")"
  start_generation="$(jq -r '.generation // empty' "$TICK_START")"
  start_engine_id="$(jq -r '.engine_id // empty' "$TICK_START")"
  start_autopi_target="$(jq -r '.autopi_target // empty' "$TICK_START")"
  start_autopi_id="$(jq -r '.autopi_id // empty' "$TICK_START")"
  scheduler_offset="$(jq -r '.scheduler_offset // 0' "$TICK_START")"
  loop_offset="$(jq -r '.loop_offset // 0' "$TICK_START")"
  tick_scheduler_offset="$scheduler_offset"
  if [[ -r "$STATE" && -n "$start_generation" &&
    "$start_generation" == "$(jq -r '.generation // empty' "$STATE" 2>/dev/null || true)" &&
    "$start_engine_id" == "$(jq -r '.new_id // empty' "$STATE" 2>/dev/null || true)" ]]; then
    # Include log output such as a refill timeout that landed after the swap,
    # before this slow scheduler process started.
    scheduler_offset="$(jq -r '.scheduler_offset // 0' "$STATE")"
    loop_offset="$(jq -r '.loop_offset // 0' "$STATE")"
  fi
  read_after_offset "$SCHED_LOG" "$scheduler_offset" > "$tmpdir/scheduler.log"
  read_after_offset "$LOOP_LOG" "$loop_offset" > "$tmpdir/loop.out"
  { extract_signatures < "$tmpdir/scheduler.log"; extract_signatures < "$tmpdir/loop.out"; } \
    | awk 'NF && !seen[$0]++' > "$tmpdir/signatures"
  read_after_offset "$SCHED_LOG" "$tick_scheduler_offset" > "$tmpdir/current-scheduler.log"
  grep -Fq 'tick done' "$tmpdir/current-scheduler.log" && tick_done=1 || :
  if (( tick_done == 0 )) && grep -Fq 'scheduler tick skipped' "$tmpdir/current-scheduler.log"; then
    # scheduler.sh main() lost the .scheduler.lock race and exited 0 without running:
    # not a canary tick (no failure, no pass); the swap stays pending for the next real tick.
    rm -f -- "$TICK_START"
    rm -rf -- "$tmpdir"
    return 0
  fi
  if (( tick_done == 0 )); then
    # loop.sh waits for the bounded scheduler process to exit before calling
    # tick-complete; an exited slow tick that never wrote its summary cannot
    # later finish successfully.
    printf '%s\n' 'no tick done within tick limit' >> "$tmpdir/signatures"
  fi

  current_id="$(live_engine_id)"
  if [[ -r "$STATE" ]]; then
    status="$(jq -r '.status // empty' "$STATE" 2>/dev/null || true)"
    current_generation="$(jq -r '.generation // empty' "$STATE" 2>/dev/null || true)"
    new_id="$(jq -r '.new_id // empty' "$STATE" 2>/dev/null || true)"
    new_autopi_target="$(jq -r '.new_autopi_target // empty' "$STATE" 2>/dev/null || true)"
    if [[ "$status" == pending && -n "$start_generation" && "$start_generation" == "$current_generation" &&
      "$start_engine_id" == "$new_id" && "$current_id" == "$new_id" &&
      "$start_autopi_target" == "$new_autopi_target" && "$start_autopi_id" == "$new_id" ]]; then
      while IFS= read -r signature; do
        [[ -n "$signature" ]] || continue
        if ! jq -e --arg signature "$signature" 'any(.baseline_signatures[]?; . == $signature)' "$STATE" >/dev/null; then
          first_new="$signature"
          break
        fi
      done < "$tmpdir/signatures"
      if [[ -n "$first_new" ]]; then
        rollback "$first_new"
      else
        local remaining tmp_state
        remaining="$(jq -r '.remaining_ticks - 1' "$STATE")"
        tmp_state="$(mktemp "$VERSIONS/.swap-record.XXXXXX")"
        jq --argjson remaining "$remaining" --argjson scheduler_offset "$(file_bytes "$SCHED_LOG")" \
          --argjson loop_offset "$(file_bytes "$LOOP_LOG")" \
          '.remaining_ticks=$remaining | .scheduler_offset=$scheduler_offset | .loop_offset=$loop_offset
           | if $remaining <= 0 then .status="passed" else . end' \
          "$STATE" > "$tmp_state"
        mv -f -- "$tmp_state" "$STATE"
      fi
    fi
  fi
  append_history "$start_engine_id" "$tmpdir/signatures" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rm -f -- "$TICK_START"
  rm -rf -- "$tmpdir"
}

case "${1:-}" in
  record-swap) shift; record_swap "$@" ;;
  was-live) shift; (($# == 1)) || exit 2; was_live "$1" ;;
  tick-begin) (($# == 1)) || exit 2; tick_begin ;;
  tick-complete) (($# == 1)) || exit 2; tick_complete ;;
  *) echo 'usage: engine-canary.sh record-swap|was-live|tick-begin|tick-complete' >&2; exit 2 ;;
esac
