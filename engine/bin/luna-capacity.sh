# Shared worker-scope capacity used by both backend gates and the scheduler.
LUNA_RUNS_HARD_CAP=10
luna_run_cap() { local cap="${LUNA_MAX:-$LUNA_RUNS_HARD_CAP}"; (( cap < LUNA_RUNS_HARD_CAP )) || cap=$LUNA_RUNS_HARD_CAP; printf '%s\n' "$cap"; }
cpu_busy() { local a b; a=($(head -1 /proc/stat)); sleep 2; b=($(head -1 /proc/stat))
  local busy=$(( (b[1]+b[2]+b[3]+b[6]+b[7]+b[8]) - (a[1]+a[2]+a[3]+a[6]+a[7]+a[8]) )) idle=$(( (b[4]+b[5]) - (a[4]+a[5]) ))
  echo $(( 100 * busy / (busy + idle + 1) )); }
# 11-19 (head row, vecta-81 cgroup read): zf-workers.slice sat at its MemoryHigh while MemAvailable still passed, so admitted
# workers were throttled in reclaim (load1 60 with idle CPU). A start needs one worker peak (measured 603-1165 MB) left under
# the slice's memory.high; no slice dir or memory.high=max skips the check.
LUNA_WORKER_SLICE_DIR="${LUNA_WORKER_SLICE_DIR:-/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/zf.slice/zf-workers.slice}"
slice_room_mb() { # prints MB left under the worker slice's memory.high, or nothing when there is no bound to read
  local high cur
  high=$(cat "$LUNA_WORKER_SLICE_DIR/memory.high" 2>/dev/null) || return 0
  cur=$(cat "$LUNA_WORKER_SLICE_DIR/memory.current" 2>/dev/null) || return 0
  [[ "$high" =~ ^[0-9]+$ && "$cur" =~ ^[0-9]+$ ]] || return 0
  echo $(( (high - cur) / 1048576 ))
}
worker_scope_runs() { local scope n=0; for scope in "$LUNA_WORKER_SLICE_DIR"/luna-*.scope "$LUNA_WORKER_SLICE_DIR"/zc-*.scope; do [[ -d "$scope" ]] || continue; n=$((n+1)); done; echo "$n"; }
# Keep the old test seam name; production runs now come from worker cgroup scopes.
codex_runs() { worker_scope_runs; }
slice_cpu_max() { cat "${LUNA_WORKER_SLICE_DIR%/*}/cpu.max" 2>/dev/null || true; }
slice_cpu_run_cap() { local quota period; read -r quota period <<< "${1:-}"; [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ && "$period" -gt 0 ]] || return 0; awk -v q="$quota" -v p="$period" -v per="${WORKER_CPU_PER_RUN:-0.5}" 'BEGIN { if (per > 0) printf "%d\n", int(q / p / per); else print 0 }'; }
slice_cpu_floor_run_cap() { local quota period; read -r quota period <<< "${1:-}"; [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ && "$period" -gt 0 ]] || return 0; awk -v q="$quota" -v p="$period" -v floor="${WORKER_CPU_FLOOR:-0.15}" 'BEGIN { if (floor > 0) printf "%d\n", int(q / p / floor); else print 0 }'; }
slice_cpu_sample_file() { local root="${ZF_SCRATCH_ROOT:-${WORKER_SCRATCH_ROOT:-${HOME:-/tmp}/.zenoforge/scratch}}"; printf '%s/zf-slice-cpu.sample\n' "${LUNA_SLOTS:-$root/tmp/luna-slots}"; }
slice_cpu_store_sample() {
  local file="$1" at="$2" usage="$3" measured="$4" tmp
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  if ! printf '%s %s %s\n' "$at" "$usage" "$measured" > "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}
slice_cpu_used() { # latest zf.slice CPU average in cores, only after a 30-second cpu.stat delta
  local stat="${LUNA_WORKER_SLICE_DIR%/*}/cpu.stat" file usage now last_at="" last_usage="" last_measured="" elapsed used
  usage=$(awk '$1 == "usage_usec" && $2 ~ /^[0-9]+$/ { print $2; found=1; exit } END { if (!found) exit 1 }' "$stat" 2>/dev/null) || return 1
  [[ "$usage" =~ ^[0-9]+$ ]] || return 1
  file=$(slice_cpu_sample_file)
  mkdir -p "${file%/*}" 2>/dev/null || return 1
  now=$(date +%s) || return 1
  if [[ -r "$file" ]]; then read -r last_at last_usage last_measured < "$file" || true; fi
  if [[ "$last_at" =~ ^[0-9]+$ && "$last_usage" =~ ^[0-9]+$ ]] && (( now > last_at && usage >= last_usage )); then
    elapsed=$((now - last_at))
    if (( elapsed >= 30 )); then
      used=$(awk -v delta="$((usage - last_usage))" -v seconds="$elapsed" 'BEGIN { printf "%.6f", delta / (seconds * 1000000) }')
      slice_cpu_store_sample "$file" "$now" "$usage" "$used" || return 1
      printf '%s\n' "$used"
      return 0
    elif [[ "$last_measured" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      printf '%s\n' "$last_measured"
      return 0
    fi
  fi
  slice_cpu_store_sample "$file" "$now" "$usage" - || return 1
  return 1
}
BOX_ROOM_WHY=""
box_has_room() { # optional waiter age in seconds; shared by bin/luna, bin/zc, and the priority hold
  local age="${1:-$SECONDS}" runs scope_runs avail cpu full cap slice quota_line quota period cpu_cap floor_cap fallback_cap cpu_used cpu_est quota_cpus used_display
  BOX_ROOM_WHY=""
  [[ "$age" =~ ^[0-9]+$ ]] || age=0
  runs=$(codex_runs)
  scope_runs=$(worker_scope_runs)
  quota_line=$(slice_cpu_max)
  cpu_cap=$(slice_cpu_run_cap "$quota_line")
  read -r quota period <<< "$quota_line"
  cap=$(luna_run_cap)
  avail=$(awk '/^MemAvailable:/{print int($2/1024)}' "${LUNA_PROC_MEMINFO:-/proc/meminfo}")
  full=$(awk -F'avg10=' '/^full/{print int($2)}' "${LUNA_PROC_PSI_MEMORY:-/proc/pressure/memory}")
  slice=$(slice_room_mb)
  if [[ -n "$slice" ]] && (( slice < ${LUNA_WORKER_PEAK_MB:-1200} )); then
    BOX_ROOM_WHY="worker slice ${slice}MB left under memory.high < ${LUNA_WORKER_PEAK_MB:-1200}MB worker peak"
    return 1
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
        BOX_ROOM_WHY="zf.slice cpu used $used_display/$quota_cpus CPUs, est +$cpu_est per run"
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
  if [[ -z "${LUNA_CPU_BUSY_AT:-}" ]] || (( SECONDS - LUNA_CPU_BUSY_AT >= ${LUNA_CPU_SAMPLE_TTL:-10} )); then
    LUNA_CPU_BUSY_VALUE=$(cpu_busy); LUNA_CPU_BUSY_AT=$SECONDS
  fi
  cpu=$LUNA_CPU_BUSY_VALUE
  if (( cpu < ${LUNA_CPU_TARGET:-85} )); then return 0; fi
  BOX_ROOM_WHY="runs $runs/$cap avail ${avail}MB full $full cpu ${cpu}/${LUNA_CPU_TARGET:-85}%"
  return 1
}

luna_wait_priority_rank() { # keep aligned with higher_priority_waiting: hotfix > opt > normal
  case "$1" in hotfix) echo 0 ;; opt) echo 1 ;; *) echo 2 ;; esac
}
luna_wait_ticket_time() {
  local time
  time=$(cat "$1" 2>/dev/null) || time=""
  [[ "$time" =~ ^[0-9]+$ ]] || time=$(stat -c %Y -- "$1" 2>/dev/null) || time=0
  [[ "$time" =~ ^[0-9]+$ ]] || time=0
  printf '%s\n' "$time"
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
  own_rank=$(luna_wait_priority_rank "$priority")
  own_time=$(luna_wait_ticket_time "$wait_f")
  for f in "$slots"/wait-*; do
    [[ -e "$f" && "$f" != "$wait_f" ]] || continue
    key="${f##*/}"; pid="${key##*-}"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || continue
    ticket_priority="${key#wait-}"; ticket_priority="${ticket_priority%-*}"
    ticket_rank=$(luna_wait_priority_rank "$ticket_priority")
    ticket_time=$(luna_wait_ticket_time "$f")
    if (( ticket_rank < own_rank || (ticket_rank == own_rank && (ticket_time < own_time || (ticket_time == own_time && pid < own_pid))) )); then
      printf '%s\n' "$key"
      return 0
    fi
  done
  return 1
}
LUNA_WAIT_AHEAD=""
luna_waiter_has_room() { # publish once, clean stale tickets, respect priority/FIFO, then check capacity
  local slots="$1" wait_f="$2" priority="$3" age="${4:-$SECONDS}" now last ahead
  LUNA_WAIT_AHEAD=""
  [[ -d "$slots" ]] && { [[ -e "$wait_f" ]] || date +%s > "$wait_f"; } || return 1
  [[ -e "$wait_f" ]] || return 1
  wait_stale_drop "$slots"
  if ahead=$(luna_wait_ticket_ahead "$slots" "$wait_f" "$priority"); then
    LUNA_WAIT_AHEAD="$ahead"
    now=$SECONDS; last="${LUNA_WAIT_LOG_AT:-}"
    if [[ ! "$last" =~ ^[0-9]+$ ]] || (( now - last >= 60 )); then
      printf 'capacity gate yield waiter=%s ahead=%s\n' "${wait_f##*/}" "$ahead" >&2
      LUNA_WAIT_LOG_AT=$now
    fi
    return 1
  fi
  box_has_room "$age"
}
