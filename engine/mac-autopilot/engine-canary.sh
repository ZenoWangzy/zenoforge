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

# The stamp is the process start: a line stamped before the swap came from a process that began on the old engine.
drop_before_swap() { # swapped_at, file
  awk -v t="$1" 'substr($0,1,1)=="[" && substr($0,22,1)=="]" && substr($0,2,20) < t { next } { print }' "$2"
}

keep_window() { # from, to (exclusive), file: lines stamped in [from, to)
  awk -v lo="$1" -v hi="$2" 'substr($0,1,1)=="[" && substr($0,22,1)=="]" && substr($0,2,20) >= lo && substr($0,2,20) < hi { print }' "$3"
}

canary_host_conditions() {
  local load_file="${ZF_CANARY_PROC_LOADAVG:-/proc/loadavg}"
  local memory_file="${ZF_CANARY_PROC_MEMORY_PRESSURE:-/proc/pressure/memory}"
  local cpus="${ZF_CANARY_CPU_COUNT:-}" load5='' psi='' threshold overloaded=0
  [[ "$cpus" =~ ^[1-9][0-9]*$ ]] || cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
  [[ "$cpus" =~ ^[1-9][0-9]*$ ]] || cpus=1
  load5="$(awk 'NR == 1 { print $2; exit }' "$load_file" 2>/dev/null || true)"
  psi="$(awk '$1 == "full" { for (i = 2; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/^avg60=/, "", $i); print $i; exit } }' "$memory_file" 2>/dev/null || true)"
  [[ "$load5" =~ ^[0-9]+([.][0-9]+)?$ ]] || load5=''
  [[ "$psi" =~ ^[0-9]+([.][0-9]+)?$ ]] || psi=''
  threshold="${ZF_CANARY_LOAD_HOLD:-$cpus}"
  [[ "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]] || threshold="$cpus"
  if [[ -n "$load5" ]] && awk -v l5="$load5" -v limit="$threshold" 'BEGIN { exit !(l5 >= limit) }'; then
    overloaded=1
  fi
  if [[ -n "$psi" ]] && awk -v pressure="$psi" 'BEGIN { exit !(pressure >= 10) }'; then
    overloaded=1
  fi
  local load_json=null psi_json=null threshold_json="$threshold"
  [[ -n "$load5" ]] && load_json="$load5"
  [[ -n "$psi" ]] && psi_json="$psi"
  jq -cn --arg load_display "${load5:-unknown}" --argjson load5 "$load_json" --argjson cpus "$cpus" \
    --argjson psi "$psi_json" --argjson threshold "$threshold_json" --argjson overloaded "$overloaded" \
    '{load5:$load5,load5_display:$load_display,cpus:$cpus,memory_psi_full_avg60:$psi,load_threshold:$threshold,overloaded:($overloaded == 1)}'
}

pack_change_for_swap() { # old id, new id: metadata-backed pack diff evidence
  local old_id="$1" new_id="$2" old_prefix new_prefix old_value new_value old_ref old_source new_ref new_source repo changed files executable=0 path
  old_prefix="${old_id%-*}"; new_prefix="${new_id%-*}"
  if [[ "$old_id" != *-* || "$new_id" != *-* || "$old_prefix" != "$new_prefix" || "${old_id##*-}" == "${new_id##*-}" ]]; then
    printf '{"classification":"not-pack-only","changed_files":[]}'
    return 0
  fi
  old_value="$(sed -n 's/^pack_sha=//p' "$VERSIONS/$old_id/BUILD-INFO" 2>/dev/null | head -n1 || true)"
  new_value="$(sed -n 's/^pack_sha=//p' "$VERSIONS/$new_id/BUILD-INFO" 2>/dev/null | head -n1 || true)"
  if [[ "$old_value" != *:* || "$new_value" != *:* ]]; then
    printf '{"classification":"unknown","reason":"pack source metadata unavailable","changed_files":[]}'
    return 0
  fi
  old_ref="${old_value%%:*}"; old_source="${old_value#*:}"
  new_ref="${new_value%%:*}"; new_source="${new_value#*:}"
  if [[ ! "$old_ref" =~ ^[0-9a-f]{7,64}$ || ! "$new_ref" =~ ^[0-9a-f]{7,64}$ || -z "$old_source" || -z "$new_source" ]]; then
    printf '{"classification":"unknown","reason":"pack source metadata unavailable","changed_files":[]}'
    return 0
  fi
  repo="${ZF_REPO_DIR:-$MAC_AUTOPILOT_ROOT}"
  changed="$(git -C "$repo" diff --name-only "$old_ref" "$new_ref" -- "$old_source" "$new_source" 2>/dev/null)" || {
    printf '{"classification":"unknown","reason":"pack source diff unavailable","changed_files":[]}'
    return 0
  }
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ "$path" =~ \.(sh|py|mjs|js)$ || "$path" == bin/* || "$path" == */bin/* ]]; then
      executable=1
      break
    fi
  done <<<"$changed"
  files="$(jq -Rn '[inputs | select(length > 0)]' <<<"$changed")"
  local classification=data-only
  (( executable == 0 )) || classification=executable
  jq -cn --arg classification "$classification" --arg old_source "$old_source" --arg new_source "$new_source" \
    --arg old_ref "$old_ref" --arg new_ref "$new_ref" --argjson changed_files "$files" \
    '{classification:$classification,old_source:$old_source,new_source:$new_source,old_ref:$old_ref,new_ref:$new_ref,changed_files:$changed_files}'
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
  local old_autopi_target="$5" new_autopi_target="$6" ticks baseline count time generation tmp window cutoff window_sigs
  local min_baseline_ticks chronic_hours chronic_cutoff chronic_log_sigs chronic_history_sigs pack_change
  [[ "$old_id" != "$new_id" ]] || return 0
  ticks="$(canary_ticks)"
  window="${CANARY_BASELINE_WINDOW_SECS:-3600}"
  [[ "$window" =~ ^[0-9]+$ ]] || window=3600
  time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cutoff="$(date -u -d "@$(( $(date +%s) - window ))" +%Y-%m-%dT%H:%M:%SZ)"
  min_baseline_ticks="${ZF_CANARY_MIN_BASELINE_TICKS:-2}"
  [[ "$min_baseline_ticks" =~ ^[0-9]+$ ]] || min_baseline_ticks=2
  chronic_hours="${ZF_CANARY_CHRONIC_HOURS:-6}"
  [[ "$chronic_hours" =~ ^[0-9]+$ ]] || chronic_hours=6
  chronic_cutoff="$(date -u -d "@$(( $(date +%s) - chronic_hours * 3600 ))" +%Y-%m-%dT%H:%M:%SZ)"
  baseline='[]'; count=0
  if [[ -r "$HISTORY" ]] && (( ticks > 0 )); then
    # Chronic signatures (e.g. REFILL-TIMEOUT) also come from rows of any engine completed within the window, so a pin
    # whose predecessor has no rows does not inherit an empty baseline and roll back on the same chronic line.
    baseline="$(jq -sc --arg old "$old_id" --argjson n "$ticks" --argjson w "$window" \
      '([.[] | select(.engine_id == $old)] | .[-$n:]) as $own
       | ((now - $w) | strftime("%Y-%m-%dT%H:%M:%SZ")) as $cutoff
       | ($own + [.[] | select((.completed_at // "") >= $cutoff)])
       | map(.signatures // []) | add // [] | unique' \
      "$HISTORY" 2>/dev/null || printf '[]')"
    count="$(jq -sc --arg old "$old_id" --argjson n "$ticks" \
      '[.[] | select(.engine_id == $old)] | .[-$n:] | length' "$HISTORY" 2>/dev/null || printf '0')"
  fi
  # Tick rows only read lines appended between tick-begin and tick-complete, so a chronic line logged between ticks
  # never reaches them: every signature stamped in the window before the swap is baseline too.
  if [[ -r "$SCHED_LOG" ]]; then
    window_sigs="$(keep_window "$cutoff" "$time" "$SCHED_LOG" | extract_signatures | jq -Rsc 'split("\n") | map(select(length > 0))')"
    baseline="$(jq -cn --argjson a "$baseline" --argjson b "$window_sigs" '$a + $b | unique')"
  fi
  if [[ "$(jq -r 'length' <<<"$baseline")" == 0 || "$count" -lt "$min_baseline_ticks" ]]; then
    chronic_log_sigs='[]'; chronic_history_sigs='[]'
    if [[ -r "$SCHED_LOG" ]]; then
      chronic_log_sigs="$(keep_window "$chronic_cutoff" "$time" "$SCHED_LOG" | extract_signatures | jq -Rsc 'split("\n") | map(select(length > 0))')"
    fi
    if [[ -r "$HISTORY" ]]; then
      chronic_history_sigs="$(jq -sc --arg from "$chronic_cutoff" --arg to "$time" \
        '[.[] | select((.completed_at // "") >= $from and (.completed_at // "") < $to) | (.signatures // [])[]] | unique' \
        "$HISTORY" 2>/dev/null || printf '[]')"
    fi
    baseline="$(jq -cn --argjson a "$baseline" --argjson b "$chronic_log_sigs" --argjson c "$chronic_history_sigs" '$a + $b + $c | unique')"
  fi
  pack_change="$(pack_change_for_swap "$old_id" "$new_id")"
  generation="$time-$new_id-$$-$RANDOM"
  tmp="$(mktemp "$VERSIONS/.swap-record.XXXXXX")"
  jq -cn --arg old_id "$old_id" --arg new_id "$new_id" --arg swapped_at "$time" \
    --arg generation "$generation" --arg old_engine_target "$old_engine_target" \
    --arg new_engine_target "$new_engine_target" --arg old_autopi_target "$old_autopi_target" \
    --arg new_autopi_target "$new_autopi_target" --argjson canary_ticks "$ticks" \
    --argjson baseline_signatures "$baseline" --argjson baseline_ticks "$count" \
    --argjson pack_change "$pack_change" \
    --argjson scheduler_offset "$(file_bytes "$SCHED_LOG")" --argjson loop_offset "$(file_bytes "$LOOP_LOG")" \
    '{old_id:$old_id,new_id:$new_id,swapped_at:$swapped_at,generation:$generation,
      old_engine_target:$old_engine_target,new_engine_target:$new_engine_target,
      old_autopi_target:$old_autopi_target,new_autopi_target:$new_autopi_target,
      canary_ticks:$canary_ticks,remaining_ticks:$canary_ticks,baseline_ticks:$baseline_ticks,
      baseline_signatures:$baseline_signatures,scheduler_offset:$scheduler_offset,loop_offset:$loop_offset,
      pack_change:$pack_change,hold_evidence:[],held_timeout_signatures:[],host_hold_logged_signatures:[],
      rollback_evidence:null,host_load:null,
      status:(if $canary_ticks == 0 then "passed" else "pending" end)}' > "$tmp"
  mv -f -- "$tmp" "$STATE"
  printf '%s\n' "$(jq -c '{old_id,new_id,swapped_at,old_engine_target,new_engine_target,old_autopi_target,new_autopi_target}' "$STATE")" >> "$SWAPS"
}

hold_timeout() { # signature, host-condition JSON, host-load|data-only
  local signature="$1" host="$2" hold_kind="$3" status at load_display cpus log_once=0 tmp
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  load_display="$(jq -r '.load5_display' <<<"$host")"
  cpus="$(jq -r '.cpus' <<<"$host")"
  if [[ "$hold_kind" == host-load ]] && ! jq -e --arg signature "$signature" \
    'any(.host_hold_logged_signatures[]?; . == $signature)' "$STATE" >/dev/null; then
    log_once=1
  fi
  status=held-data-only
  [[ "$hold_kind" == host-load ]] && status=held-host-load
  if (( log_once )); then
    printf '[%s] CANARY-HOLD host load %s/%s on %s\n' "$at" "$load_display" "$cpus" "$signature" >> "$SCHED_LOG"
  fi
  tmp="$(mktemp "$VERSIONS/.swap-record.XXXXXX")"
  jq --arg signature "$signature" --arg at "$at" --arg kind "$hold_kind" --arg status "$status" \
    --argjson host "$host" --argjson scheduler_offset "$(file_bytes "$SCHED_LOG")" \
    --argjson loop_offset "$(file_bytes "$LOOP_LOG")" \
    '.held_timeout_signatures = ((.held_timeout_signatures // []) + [$signature] | unique)
     | .hold_evidence = ((.hold_evidence // []) + [{action:(if $kind == "host-load" then "held-host-load" else "held-data-only" end),
         signature:$signature,observed_at:$at,reason:$kind,load5:$host.load5,cpus:$host.cpus,
         memory_psi_full_avg60:$host.memory_psi_full_avg60,load_threshold:$host.load_threshold}])
     | .host_load = {load5:$host.load5,cpus:$host.cpus,memory_psi_full_avg60:$host.memory_psi_full_avg60,
         load_threshold:$host.load_threshold}
     | .status=$status | .scheduler_offset=$scheduler_offset | .loop_offset=$loop_offset
     | if $kind == "host-load" then .host_hold_logged_signatures = ((.host_hold_logged_signatures // []) + [$signature] | unique) else . end' \
    "$STATE" > "$tmp"
  mv -f -- "$tmp" "$STATE"
}

tick_begin() {
  local state_generation='' engine_id='' autopi_target autopi_id
  if [[ -r "$STATE" ]]; then
    state_generation="$(jq -r 'select(.status == "pending" or .status == "held-host-load" or .status == "held-data-only") | .generation // empty' "$STATE" 2>/dev/null || true)"
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
  local signature="$1" evidence="$2" old_id new_id old_engine_target new_engine_target old_autopi_target new_autopi_target
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
  jq --arg signature "$signature" --arg rolled_back_at "$at" --argjson evidence "$evidence" \
    '.status="rolled-back" | .first_new_signature=$signature | .rolled_back_at=$rolled_back_at
     | .rollback_evidence=$evidence | .host_load=($evidence.host_load // .host_load)' \
    "$STATE" > "$tmp"
  mv -f -- "$tmp" "$STATE"
}

tick_complete() {
  [[ -r "$TICK_START" ]] || return 0
  local tmpdir start_generation start_engine_id start_autopi_target start_autopi_id current_generation status new_id current_id new_autopi_target swapped_at
  local scheduler_offset loop_offset tick_scheduler_offset tick_done=0 first_new='' decision_host='null' decision_evidence held=0 decision_kind
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
  swapped_at="$(jq -r '.swapped_at // empty' "$STATE" 2>/dev/null || true)"
  { drop_before_swap "$swapped_at" "$tmpdir/scheduler.log" | extract_signatures
    drop_before_swap "$swapped_at" "$tmpdir/loop.out" | extract_signatures
  } | awk 'NF && !seen[$0]++' > "$tmpdir/signatures"
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
    if [[ ( "$status" == pending || "$status" == held-host-load || "$status" == held-data-only ) &&
      -n "$start_generation" && "$start_generation" == "$current_generation" &&
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
        if [[ "$first_new" == REFILL-TIMEOUT || "$first_new" == TICK-TIMEOUT || "$first_new" == 'no tick done within tick limit' ]]; then
          decision_host="$(canary_host_conditions)"
          if jq -e '.overloaded' <<<"$decision_host" >/dev/null; then
            hold_timeout "$first_new" "$decision_host" host-load
            held=1
          elif jq -e '.pack_change.classification == "data-only"' "$STATE" >/dev/null; then
            hold_timeout "$first_new" "$decision_host" data-only
            held=1
          elif jq -e --arg signature "$first_new" 'any(.held_timeout_signatures[]?; . == $signature)' "$STATE" >/dev/null; then
            decision_kind=repeated-after-host-hold
            decision_evidence="$(jq -cn --arg signature "$first_new" --arg kind "$decision_kind" \
              --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson host "$decision_host" \
              --slurpfile state "$STATE" \
              '{signature:$signature,observed_at:$observed_at,reason:$kind,
                baseline_signatures:$state[0].baseline_signatures,baseline_ticks:$state[0].baseline_ticks,
                pack_change:$state[0].pack_change,
                host_load:{load5:$host.load5,cpus:$host.cpus,memory_psi_full_avg60:$host.memory_psi_full_avg60,
                  load_threshold:$host.load_threshold}}')"
            rollback "$first_new" "$decision_evidence"
          else
            decision_kind=new-timeout
            decision_evidence="$(jq -cn --arg signature "$first_new" --arg kind "$decision_kind" \
              --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson host "$decision_host" \
              --slurpfile state "$STATE" \
              '{signature:$signature,observed_at:$observed_at,reason:$kind,
                baseline_signatures:$state[0].baseline_signatures,baseline_ticks:$state[0].baseline_ticks,
                pack_change:$state[0].pack_change,
                host_load:{load5:$host.load5,cpus:$host.cpus,memory_psi_full_avg60:$host.memory_psi_full_avg60,
                  load_threshold:$host.load_threshold}}')"
            rollback "$first_new" "$decision_evidence"
          fi
        else
          decision_kind=new-signature
          decision_evidence="$(jq -cn --arg signature "$first_new" --arg kind "$decision_kind" \
            --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --slurpfile state "$STATE" \
            '{signature:$signature,observed_at:$observed_at,reason:$kind,
              baseline_signatures:$state[0].baseline_signatures,baseline_ticks:$state[0].baseline_ticks,
              pack_change:$state[0].pack_change,host_load:null}')"
          rollback "$first_new" "$decision_evidence"
        fi
      fi
      if [[ -z "$first_new" ]]; then
        local remaining tmp_state
        remaining="$(jq -r '.remaining_ticks - 1' "$STATE")"
        tmp_state="$(mktemp "$VERSIONS/.swap-record.XXXXXX")"
        jq --argjson remaining "$remaining" --argjson scheduler_offset "$(file_bytes "$SCHED_LOG")" \
          --argjson loop_offset "$(file_bytes "$LOOP_LOG")" \
          '.remaining_ticks=$remaining | .scheduler_offset=$scheduler_offset | .loop_offset=$loop_offset
           | if $remaining <= 0 then .status="passed" else . end' \
          "$STATE" > "$tmp_state"
        mv -f -- "$tmp_state" "$STATE"
      elif (( held )); then
        : # A held timeout is not a successful canary tick; wait for a repeat or clean ticks.
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
