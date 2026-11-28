# Shared worker-scope capacity used by both backend gates and the scheduler.
LUNA_RUNS_HARD_CAP="${LUNA_RUNS_HARD_CAP:-99}"
LUNA_GATE_HOME="${AGENT_HOME:-${ZF_HOME:-}}"
if [[ -z "$LUNA_GATE_HOME" ]]; then
  LUNA_GATE_ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
  if [[ -r "$LUNA_GATE_ENGINE_DIR/deploy.env" ]]; then
    LUNA_GATE_HOME="$(source "$LUNA_GATE_ENGINE_DIR/deploy.env" >/dev/null 2>&1; printf '%s' "${AGENT_HOME:-${ZF_HOME:-}}")"
  fi
  unset LUNA_GATE_ENGINE_DIR
fi
LUNA_GATE_HOME="${LUNA_GATE_HOME:-${HOME:-}/.zenoforge}"
LUNA_GATE_LAST_SOURCE="${LUNA_GATE_LAST_SOURCE:-$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || true)}"
LUNA_CPU_BUSY_FILE="$LUNA_GATE_HOME/locks/luna-host-cpu.sample"
LUNA_CPU_BUSY_LOCK="$LUNA_GATE_HOME/locks/luna-host-cpu.lock"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/proc.sh"

luna_reload_live_gate() {
  local live_file="$LUNA_GATE_HOME/engine-live/bin/luna-capacity.sh" resolved source_file function_name
  local old_cap="${LUNA_RUNS_HARD_CAP:-}" old_why="${BOX_ROOM_WHY:-}" old_ahead="${LUNA_WAIT_AHEAD:-}"
  local -a old_functions=()
  local -A saved_functions=()
  resolved="$(readlink -f -- "$live_file" 2>/dev/null)" || return 0
  [[ -f "$resolved" && -r "$resolved" && "$resolved" != "${LUNA_GATE_LAST_SOURCE:-}" ]] || return 0
  bash -n "$resolved" 2>/dev/null || return 0

  source_file="${LUNA_GATE_LAST_SOURCE:-}"
  if [[ -r "$source_file" ]]; then
    mapfile -t old_functions < <(sed -nE 's/^([[:alnum:]_]+)\(\) \{.*/\1/p' "$source_file")
  fi
  for function_name in "${old_functions[@]}"; do
    saved_functions["$function_name"]="$(declare -f "$function_name" 2>/dev/null || true)"
  done

  if source "$resolved" 2>/dev/null; then
    LUNA_GATE_LAST_SOURCE="$resolved"
    printf 'luna: gate reloaded from %s\n' "$resolved" >&2
  else
    for function_name in "${old_functions[@]}"; do
      if [[ -n "${saved_functions[$function_name]}" ]]; then
        eval "${saved_functions[$function_name]}"
      else
        unset -f "$function_name"
      fi
    done
    LUNA_RUNS_HARD_CAP="$old_cap" BOX_ROOM_WHY="$old_why" LUNA_WAIT_AHEAD="$old_ahead"
    LUNA_GATE_LAST_SOURCE="$source_file"
  fi
}

luna_run_cap() { local cap="${LUNA_MAX:-$LUNA_RUNS_HARD_CAP}"; (( cap < LUNA_RUNS_HARD_CAP )) || cap=$LUNA_RUNS_HARD_CAP; printf '%s\n' "$cap"; }
cpu_busy() { host_cpu_busy_pct "${LUNA_PROC_STAT:-}"; }
luna_cpu_sample_read() {
  local sampled_at sample now ttl="${LUNA_CPU_SAMPLE_STALE_SECONDS:-45}"
  LUNA_CPU_BUSY_VALUE=""
  read -r sampled_at sample 2>/dev/null < "$LUNA_CPU_BUSY_FILE" || return 1
  [[ "$sampled_at" =~ ^[0-9]+$ && "$sample" =~ ^[0-9]{1,3}$ ]] || return 1
  printf -v now '%(%s)T' -1
  (( now >= sampled_at && now - sampled_at <= ttl )) || return 1
  LUNA_CPU_BUSY_VALUE="$sample"
}
luna_cpu_sampler_has_waiter() {
  local slots="$1" f pid
  for f in "$slots"/wait-*; do
    [[ -e "$f" ]] || continue
    pid="${f##*-}"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}
luna_cpu_sampler_loop() {
  local slots="$1" sample sampled_at tmp interval="${LUNA_CPU_SAMPLE_INTERVAL:-15}"
  [[ "$interval" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] || interval=15
  while luna_cpu_sampler_has_waiter "$slots"; do
    sample="$(cpu_busy 2>/dev/null)" || sample=100
    [[ "$sample" =~ ^[0-9]{1,3}$ ]] || sample=100
    printf -v sampled_at '%(%s)T' -1
    tmp="${LUNA_CPU_BUSY_FILE}.${BASHPID}.tmp"
    if printf '%s %s\n' "$sampled_at" "$sample" > "$tmp"; then
      mv -f -- "$tmp" "$LUNA_CPU_BUSY_FILE" || rm -f -- "$tmp"
    else
      rm -f -- "$tmp"
    fi
    sleep "$interval"
  done
}
luna_cpu_sampler_start() {
  local slots="$1" fd lock_dir="${LUNA_CPU_BUSY_LOCK%/*}"
  [[ -d "$lock_dir" ]] || mkdir -p -- "$lock_dir" || return 1
  exec {fd}>"$LUNA_CPU_BUSY_LOCK" || return 1
  if flock -n "$fd"; then
    ( luna_cpu_sampler_loop "$slots" ) >/dev/null 2>&1 &
    LUNA_CPU_SAMPLER_PID=$!
  fi
  exec {fd}>&-
}
# 11-19 (head row, vecta-81 cgroup read): zf-workers.slice sat at its MemoryHigh while MemAvailable still passed, so admitted
# workers were throttled in reclaim (load1 60 with idle CPU). A start needs one worker peak (measured 603-1165 MB) left under
# the slice's memory.high; no slice dir or memory.high=max skips the check.
LUNA_WORKER_SLICE_DIR="${LUNA_WORKER_SLICE_DIR:-/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/zf.slice/zf-workers.slice}"
slice_room_mb() { # prints MB left under the worker slice's memory.high, or nothing when there is no bound to read
  local high cur
  high=$(cat "$LUNA_WORKER_SLICE_DIR/memory.high" 2>/dev/null) || return 0
  # 11-22 (row 987): memory.current counts page cache the kernel reclaims at memory.high; an orphan find held 1274 MB of
  # file pages (anon 1.5 MB) and refused dispatch for 60 min. Count anon+shmem when memory.stat is there.
  cur=$(awk '$1 == "anon" || $1 == "shmem" { s += $2; a = 1 } END { if (a) print s }' "$LUNA_WORKER_SLICE_DIR/memory.stat" 2>/dev/null)
  [[ -n "$cur" ]] || cur=$(cat "$LUNA_WORKER_SLICE_DIR/memory.current" 2>/dev/null) || return 0
  [[ "$high" =~ ^[0-9]+$ && "$cur" =~ ^[0-9]+$ ]] || return 0
  echo $(( (high - cur) / 1048576 ))
}
worker_scope_runs() { local scope n=0; for scope in "$LUNA_WORKER_SLICE_DIR"/luna-*.scope "$LUNA_WORKER_SLICE_DIR"/zc-*.scope; do [[ -d "$scope" ]] || continue; n=$((n+1)); done; echo "$n"; }
# 11-21 (queue row 881): the flat 1200 MB peak held implement stations out for hours at memory.high 3072 while real
# workers peaked far lower. One ended luna/zc scope appends its cgroup memory.peak to a backend-keyed rolling tail,
# and the gate uses that backend's p90 with execution-admission.py's 512 MB calibration floor. Sibling of the
# class-keyed store: record_scope_memory_peak keeps only class rows, so backend rows there would be dropped on its
# next append. Row 894 added the third backend sched: the scheduler's own run-p worker scopes, recorded at end by
# worker-scope-watch, so the no-backend dispatch hold can size itself from them.
LUNA_MEMORY_PEAK_TAIL=200
luna_backend_peak_values() { # <backend>: that backend's recorded peaks (MB), rolling tail, oldest first
  jq -Rr --arg b "$1" 'fromjson? // empty | select(type == "object") | select(.backend == $b) | .memory_peak_mb | numbers | select(. == floor and . > 0)' \
    "$LUNA_GATE_HOME/locks/execution-memory-peaks-backend.jsonl" 2>/dev/null \
    | tail -"$LUNA_MEMORY_PEAK_TAIL" || :
}
luna_backend_peak_count() { # <backend>: valid samples in that backend's rolling tail
  luna_backend_peak_values "$1" | wc -l
}
luna_backend_peak_p90() { # <backend>: that backend's p90 with the 512 MB floor, or nothing with no samples
  luna_backend_peak_values "$1" | sort -n \
    | awk '{ v[NR] = $1 } END { if (NR) { r = int((9 * NR + 9) / 10); if (r < 1) r = 1; if (v[r] < 512) v[r] = 512; print v[r] } }' || :
}
# Row 894: the no-backend ask falls back to this until LUNA_SCHED_PEAK_MIN_SAMPLES sched samples exist.
LUNA_NO_BACKEND_PEAK_MB=800
LUNA_SCHED_PEAK_MIN_SAMPLES=5
worker_peak_mb() { # <backend|->: prints "<mb> <set|measured|interim|default>"; explicit LUNA_WORKER_PEAK_MB wins, a known
  # backend uses its own p90 with the interim peak when it has no samples, and an ask with no backend (the scheduler's dispatch
  # hold, which starts run-p workers) uses the sched p90 of recorded scheduler worker peaks once enough samples
  # exist, else the interim fixed peak
  local backend="${1:-}" p90="" samples=""
  if [[ -n "${LUNA_WORKER_PEAK_MB:-}" ]]; then printf '%s set\n' "$LUNA_WORKER_PEAK_MB"; return 0; fi
  if [[ "$backend" == luna || "$backend" == zc ]]; then
    p90="$(luna_backend_peak_p90 "$backend")"
    if [[ -n "$p90" ]]; then printf '%s measured\n' "$p90"; return 0; fi
    printf '%s default\n' "$LUNA_NO_BACKEND_PEAK_MB" # row 987: 1200 held zc out with no zc sample at 1149 MB room
  else
    samples="$(luna_backend_peak_count sched)"
    if [[ "$samples" =~ ^[0-9]+$ && "$samples" -ge "$LUNA_SCHED_PEAK_MIN_SAMPLES" ]]; then
      p90="$(luna_backend_peak_p90 sched)"
      if [[ -n "$p90" ]]; then printf '%s measured\n' "$p90"; return 0; fi
    fi
    printf '%s interim\n' "$LUNA_NO_BACKEND_PEAK_MB"
  fi
}
# 11-21 (row 894 experiment): systemd reaps a scope's cgroup the moment its last process ends, so a read after
# wait returns nothing. The wrapper samples memory.peak while the scoped pid lives (builtin read; the wrapper may
# itself sit in a TasksMax-bound scope) and the last sample, at most 10 s stale, survives the cgroup.
luna_watch_scope_peak() { # <scope> <pid> <sample-file>: keep the last memory.peak read while the scoped pid lives
  local scope="$1" pid="$2" sample="$3" bytes fd
  exec {fd}<> <(:) || return 0
  while kill -0 "$pid" 2>/dev/null; do
    bytes=''
    read -r bytes < "$LUNA_WORKER_SLICE_DIR/$scope.scope/memory.peak" 2>/dev/null || :
    if [[ "$bytes" =~ ^[1-9][0-9]*$ ]]; then printf '%s\n' "$bytes" > "$sample"; fi
    read -r -t 10 -u "$fd" || :
  done
}
luna_record_scope_peak() { # <backend> <scope> [peak bytes read while the scope lived]: best-effort append of one ended
  # worker scope's cgroup peak to the rolling tail; given bytes spare the cgroup read (already reaped at the caller's
  # wait), and with neither readable bytes nor a readable memory.peak it records nothing
  local backend="$1" scope="$2" bytes="${3:-}" mb file tmp
  [[ ( "$backend" == luna || "$backend" == zc || "$backend" == sched ) && -n "$scope" ]] || return 0
  [[ "$bytes" =~ ^[1-9][0-9]*$ ]] || bytes=$(cat "$LUNA_WORKER_SLICE_DIR/$scope.scope/memory.peak" 2>/dev/null) || return 0
  mb=$(( (bytes + 1048575) / 1048576 ))
  file="$LUNA_GATE_HOME/locks/execution-memory-peaks-backend.jsonl"
  mkdir -p "${file%/*}" 2>/dev/null || return 0
  tmp=$(mktemp "${file}.XXXXXX") || return 0
  if flock 9; then
    { jq -Rc 'fromjson? // empty | select(type == "object") | select(.backend == "luna" or .backend == "zc" or .backend == "sched") | select(.memory_peak_mb | numbers | . == floor) | select(.memory_peak_mb > 0)' "$file" 2>/dev/null || true
      printf '{"backend":"%s","memory_peak_mb":%d}\n' "$backend" "$mb"
    } | tail -"$LUNA_MEMORY_PEAK_TAIL" > "$tmp" && mv -f -- "$tmp" "$file" || rm -f -- "$tmp" 2>/dev/null || :
  else
    rm -f -- "$tmp" 2>/dev/null || :
  fi 9>>"${file%.jsonl}.lock" || rm -f -- "$tmp" 2>/dev/null || :
  return 0
}
# Keep the old test seam name; production runs now come from worker cgroup scopes.
codex_runs() { worker_scope_runs; }
slice_cpu_max() { cat "${LUNA_WORKER_SLICE_DIR%/*}/cpu.max" 2>/dev/null || true; }
slice_cpu_run_cap() { local quota period; read -r quota period <<< "${1:-}"; [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ && "$period" -gt 0 ]] || return 0; awk -v q="$quota" -v p="$period" -v per="${WORKER_CPU_PER_RUN:-0.5}" 'BEGIN { if (per > 0) printf "%d\n", int(q / p / per); else print 0 }'; }
slice_cpu_floor_run_cap() { local quota period; read -r quota period <<< "${1:-}"; [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ && "$period" -gt 0 ]] || return 0; awk -v q="$quota" -v p="$period" -v floor="${WORKER_CPU_FLOOR:-0.15}" 'BEGIN { if (floor > 0) printf "%d\n", int(q / p / floor); else print 0 }'; }
slice_cpu_sample_file() { local root="${ZF_SCRATCH_ROOT:-${WORKER_SCRATCH_ROOT:-${HOME:-/tmp}/.zenoforge/scratch}}"; printf '%s/zf-slice-cpu.sample\n' "${LUNA_SLOTS:-$root/tmp/luna-slots}"; }
slice_cpu_now() { awk '{ printf "%d\n", $1 * 100 }' "${LUNA_PROC_UPTIME:-/proc/uptime}" 2>/dev/null; }
slice_cpu_store_sample() {
  local file="$1" at="$2" usage="$3" measured="$4" tmp
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  if ! printf '%s %s %s\n' "$at" "$usage" "$measured" > "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}
slice_cpu_used() { # latest worker CPU average in cores (zf-workers.slice only; scheduler, batch, release and bell load in zf.slice is not counted), only after a 30-second cpu.stat delta
  local stat="$LUNA_WORKER_SLICE_DIR/cpu.stat" file usage now last_at="" last_usage="" last_measured="" elapsed_cs used
  usage=$(awk '$1 == "usage_usec" && $2 ~ /^[0-9]+$/ { print $2; found=1; exit } END { if (!found) exit 1 }' "$stat" 2>/dev/null) || return 1
  [[ "$usage" =~ ^[0-9]+$ ]] || return 1
  file=$(slice_cpu_sample_file)
  mkdir -p "${file%/*}" 2>/dev/null || return 1
  now=$(slice_cpu_now) || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  if [[ -r "$file" ]]; then read -r last_at last_usage last_measured < "$file" || true; fi
  if [[ "$last_at" =~ ^[0-9]+$ && "$last_usage" =~ ^[0-9]+$ ]] && (( now > last_at && usage >= last_usage )); then
    elapsed_cs=$((now - last_at))
    if (( elapsed_cs >= 3000 )); then
      used=$(awk -v delta="$((usage - last_usage))" -v centiseconds="$elapsed_cs" 'BEGIN { printf "%.6f", delta / (centiseconds * 10000) }')
      slice_cpu_store_sample "$file" "$now" "$usage" "$used" || return 1
      printf '%s\n' "$used"
      return 0
    elif [[ "$last_measured" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      printf '%s\n' "$last_measured"
      return 0
    fi
    # No measurement yet: keep the baseline, or callers polling under 30 s apart reset it forever.
    return 1
  fi
  slice_cpu_store_sample "$file" "$now" "$usage" - || return 1
  return 1
}
BOX_ROOM_WHY=""
box_has_room() { # optional waiter age in seconds, then the asking backend (luna|zc); shared by bin/luna, bin/zc, and the priority hold
  local age="${1:-$SECONDS}" backend="${2:-}" shared_cpu="${3:-}" runs scope_runs avail cpu full cap slice peak peak_source quota_line quota period cpu_cap floor_cap fallback_cap cpu_used cpu_est quota_cpus used_display
  BOX_ROOM_WHY=""
  [[ "$age" =~ ^[0-9]+$ ]] || age=0
  runs=$(codex_runs)
  scope_runs=$(worker_scope_runs)
  quota_line=$(slice_cpu_max)
  cpu_cap=$(slice_cpu_run_cap "$quota_line")
  read -r quota period <<< "$quota_line"
  cap=$(luna_run_cap)
  avail="$(host_mem_avail_mb "${LUNA_PROC_MEMINFO:-}")"
  full="$(host_mem_pressure_pct "${LUNA_PROC_PSI_MEMORY:-}")"
  slice=$(slice_room_mb)
  if [[ -n "$slice" ]]; then
    read -r peak peak_source <<< "$(worker_peak_mb "$backend")"
    if (( slice < peak )); then
      BOX_ROOM_WHY="worker slice ${slice}MB left under memory.high < ${peak}MB worker peak backend=${backend:--} source=${peak_source:-default}"
      return 1
    fi
  fi
  # Hotfix crosses the run cap and the zf.slice CPU scope cap (ruling hand-resource-hotfix-optimization-general), but keeps
  # the memory floor: slice room above, MemAvailable >= 3072 MB and no full-memory pressure. 11-20: the scope cap came first
  # and held a production hotfix at "worker scopes 4/4" with 6.4 GB free.
  [[ "${LUNA_PRIORITY:-}" == hotfix ]] && (( avail >= 3072 && full < 10 )) && return 0
  floor_cap=$(slice_cpu_floor_run_cap "$quota_line")
  if [[ -n "$cpu_cap" ]]; then
    fallback_cap=$cpu_cap
    if [[ -n "$floor_cap" ]] && (( floor_cap < fallback_cap )); then fallback_cap=$floor_cap; fi
    if cpu_used=$(slice_cpu_used); then
      cpu_est="${WORKER_CPU_PER_RUN_EST:-0.25}"
      [[ "$cpu_est" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] || cpu_est=0.25
      quota_cpus=$(awk -v q="$quota" -v p="$period" 'BEGIN { printf "%.6g", q / p }')
      if (( scope_runs >= floor_cap )) || ! awk -v used="$cpu_used" -v est="$cpu_est" -v quota="$quota" -v period="$period" 'BEGIN { exit !(used + est <= quota / period) }'; then
        used_display=$(awk -v used="$cpu_used" 'BEGIN { printf "%.2f", used }')
        BOX_ROOM_WHY="zf-workers.slice cpu used $used_display/$quota_cpus CPUs, est +$cpu_est per run"
        return 1
      fi
    elif (( scope_runs >= fallback_cap )); then
      BOX_ROOM_WHY="worker scopes $scope_runs/$fallback_cap at zf.slice CPU quota $quota/$period (${WORKER_CPU_PER_RUN:-0.5} CPUs per run)"
      return 1
    fi
  fi
  (( runs < ${LUNA_MIN:-2} && avail >= 2048 )) && return 0
  # Aging skips only the CPU target; memory pressure, availability, and the run cap still apply.
  (( age >= ${LUNA_AGE_ADMIT_SECONDS:-1200} && runs < cap && full < 10 && avail >= ${LUNA_ADMIT_AVAIL_MB:-3328} )) && return 0
  if ! (( runs < cap && full < 10 && avail >= ${LUNA_ADMIT_AVAIL_MB:-3328} )); then
    BOX_ROOM_WHY="runs $runs/$cap avail ${avail}MB full $full"
    return 1
  fi
  # The CPU sample takes 2 s: reuse one from the last LUNA_CPU_SAMPLE_TTL seconds. Assigned here, not inside $(...), so the cache outlives the call.
  if [[ "$shared_cpu" == shared ]]; then
    if ! luna_cpu_sample_read; then
      BOX_ROOM_WHY="host CPU sample unavailable or stale"
      return 1
    fi
    cpu="$LUNA_CPU_BUSY_VALUE"
  else
    if [[ -z "${LUNA_CPU_BUSY_AT:-}" ]] || (( SECONDS - LUNA_CPU_BUSY_AT >= ${LUNA_CPU_SAMPLE_TTL:-10} )); then
      LUNA_CPU_BUSY_VALUE=$(cpu_busy); LUNA_CPU_BUSY_AT=$SECONDS
    fi
    cpu=$LUNA_CPU_BUSY_VALUE
  fi
  if (( cpu < ${LUNA_CPU_TARGET:-85} )); then return 0; fi
  BOX_ROOM_WHY="runs $runs/$cap avail ${avail}MB full $full cpu ${cpu}/${LUNA_CPU_TARGET:-85}%"
  return 1
}

luna_wait_priority_rank() { # keep aligned with higher_priority_waiting: hotfix > opt > normal
  case "$1" in hotfix) LUNA_WAIT_PRIORITY_RANK=0 ;; opt) LUNA_WAIT_PRIORITY_RANK=1 ;; *) LUNA_WAIT_PRIORITY_RANK=2 ;; esac
}
luna_wait_ticket_time() {
  LUNA_WAIT_TICKET_TIME=0
  read -r LUNA_WAIT_TICKET_TIME < "$1" 2>/dev/null || :
  [[ "$LUNA_WAIT_TICKET_TIME" =~ ^[0-9]+$ ]] || LUNA_WAIT_TICKET_TIME=0
}
wait_stale_drop() {
  local slots="$1" f pid
  for f in "$slots"/wait-*; do
    [[ -e "$f" ]] || continue
    pid="${f##*-}"
    { [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; } || rm -f -- "$f"
  done
}
luna_wait_ticket_ahead() {
  local slots="$1" wait_f="$2" priority="$3" own_pid="${2##*-}" own_rank own_time
  local f key pid ticket_priority ticket_rank ticket_time
  [[ "$own_pid" =~ ^[0-9]+$ ]] || return 1
  luna_wait_priority_rank "$priority"
  own_rank=$LUNA_WAIT_PRIORITY_RANK
  luna_wait_ticket_time "$wait_f"
  own_time=$LUNA_WAIT_TICKET_TIME
  for f in "$slots"/wait-*; do
    [[ -e "$f" && "$f" != "$wait_f" ]] || continue
    key="${f##*/}"; pid="${key##*-}"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || continue
    ticket_priority="${key#wait-}"; ticket_priority="${ticket_priority%-*}"
    luna_wait_priority_rank "$ticket_priority"
    ticket_rank=$LUNA_WAIT_PRIORITY_RANK
    luna_wait_ticket_time "$f"
    ticket_time=$LUNA_WAIT_TICKET_TIME
    if (( ticket_rank < own_rank || (ticket_rank == own_rank && (ticket_time < own_time || (ticket_time == own_time && pid < own_pid))) )); then
      LUNA_WAIT_AHEAD="$key"
      return 0
    fi
  done
  return 1
}
LUNA_WAIT_AHEAD=""
luna_waiter_has_room() { # publish once, clean stale tickets, respect priority/FIFO, then check capacity
  local slots="$1" wait_f="$2" priority="$3" age="${4:-$SECONDS}" backend="${5:-}" now last scope runs base="${LUNA_WAIT_SECONDS:-15}" maximum="${LUNA_WAIT_MAX_SECONDS:-30}" check_interval
  LUNA_WAIT_AHEAD=""
  [[ -d "$slots" ]] && { [[ -e "$wait_f" ]] || printf '%(%s)T\n' -1 > "$wait_f"; } || return 1
  [[ -e "$wait_f" ]] || return 1
  wait_stale_drop "$slots"
  if luna_wait_ticket_ahead "$slots" "$wait_f" "$priority"; then
    now=$SECONDS; last="${LUNA_WAIT_LOG_AT:-}"
    if [[ ! "$last" =~ ^[0-9]+$ ]] || (( now - last >= 60 )); then
      printf 'capacity gate yield waiter=%s ahead=%s\n' "${wait_f##*/}" "$LUNA_WAIT_AHEAD" >&2
      LUNA_WAIT_LOG_AT=$now
    fi
    return 1
  fi
  if [[ "$priority" != hotfix ]] && (( age < ${LUNA_AGE_ADMIT_SECONDS:-1200} )); then
    runs=0
    for scope in "$LUNA_WORKER_SLICE_DIR"/luna-*.scope "$LUNA_WORKER_SLICE_DIR"/zc-*.scope; do
      [[ -d "$scope" ]] || continue
      runs=$((runs + 1))
    done
    if (( runs >= ${LUNA_MIN:-2} )); then
      if ! luna_cpu_sample_read; then
        BOX_ROOM_WHY="host CPU sample unavailable or stale"
        LUNA_WAIT_ROOM_CHECK_AT=""
        now=$SECONDS; last="${LUNA_CPU_SAMPLER_TRY_AT:-}"
        if [[ ! "$last" =~ ^[0-9]+$ ]] || (( now - last >= ${LUNA_CPU_SAMPLER_RETRY_SECONDS:-15} )); then
          LUNA_CPU_SAMPLER_TRY_AT=$now
          luna_cpu_sampler_start "$slots" || :
        fi
        return 1
      fi
      if (( LUNA_CPU_BUSY_VALUE >= ${LUNA_CPU_TARGET:-85} )); then
        BOX_ROOM_WHY="host CPU busy ${LUNA_CPU_BUSY_VALUE}/${LUNA_CPU_TARGET:-85}%"
        LUNA_WAIT_ROOM_CHECK_AT=""
        return 1
      fi
    fi
  fi
  now=$SECONDS; last="${LUNA_WAIT_ROOM_CHECK_AT:-}"
  [[ "$base" =~ ^[0-9]+$ ]] || base=15
  [[ "$maximum" =~ ^[0-9]+$ ]] || maximum=30
  (( base < 15 )) && base=15
  (( maximum < base )) && maximum=$base
  check_interval=$((maximum + 1))
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < check_interval )); then return 1; fi
  if box_has_room "$age" "$backend" shared; then return 0; fi
  [[ "$BOX_ROOM_WHY" == "host CPU sample unavailable or stale" ]] || LUNA_WAIT_ROOM_CHECK_AT=$SECONDS
  if [[ "$BOX_ROOM_WHY" == 'host CPU sample unavailable or stale' ]]; then
    now=$SECONDS; last="${LUNA_CPU_SAMPLER_TRY_AT:-}"
    if [[ ! "$last" =~ ^[0-9]+$ ]] || (( now - last >= ${LUNA_CPU_SAMPLER_RETRY_SECONDS:-15} )); then
      LUNA_CPU_SAMPLER_TRY_AT=$now
      luna_cpu_sampler_start "$slots" || :
    fi
  fi
  return 1
}
luna_wait_backoff() {
  local attempt="${1:-0}" base="${LUNA_WAIT_SECONDS:-15}" maximum="${LUNA_WAIT_MAX_SECONDS:-30}" n
  [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=0
  [[ "$base" =~ ^[0-9]+$ ]] || base=15
  [[ "$maximum" =~ ^[0-9]+$ ]] || maximum=30
  (( base < 15 )) && base=15
  (( maximum < base )) && maximum=$base
  LUNA_WAIT_DELAY=$base
  n=0
  while (( n < attempt && LUNA_WAIT_DELAY < maximum )); do
    LUNA_WAIT_DELAY=$((LUNA_WAIT_DELAY * 2))
    (( LUNA_WAIT_DELAY > maximum )) && LUNA_WAIT_DELAY=$maximum
    n=$((n + 1))
  done
}
luna_waiter_sleep() {
  local slots="$1" delay="$2" fifo="$1/capacity-wake.fifo" fd
  if [[ ! -p "$fifo" ]]; then
    mkfifo "$fifo" 2>/dev/null || [[ -p "$fifo" ]] || return 1
  fi
  exec {fd}<>"$fifo" || return 1
  read -r -t "$delay" -u "$fd" || :
  exec {fd}>&-
}
