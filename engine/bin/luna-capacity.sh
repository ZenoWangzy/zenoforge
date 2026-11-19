# Shared total Codex/ZCode capacity used by both backend gates and the scheduler.
LUNA_RUNS_HARD_CAP=10
codex_runs() { local p n=0 pc; for p in $(pgrep -x codex) $(pgrep -x zcode-cli); do pc=$(ps -o comm= -p "$(ps -o ppid= -p "$p" | tr -d ' ')" 2>/dev/null); [[ "$pc" == codex || "$pc" == zcode-cli ]] || n=$((n+1)); done; echo "$n"; }
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
BOX_ROOM_WHY=""
box_has_room() { # optional waiter age in seconds; shared by bin/luna, bin/zc, and the priority hold
  local age="${1:-$SECONDS}" runs avail cpu full cap slice
  BOX_ROOM_WHY=""
  [[ "$age" =~ ^[0-9]+$ ]] || age=0
  runs=$(codex_runs)
  cap=$(luna_run_cap)
  avail=$(awk '/^MemAvailable:/{print int($2/1024)}' "${LUNA_PROC_MEMINFO:-/proc/meminfo}")
  full=$(awk -F'avg10=' '/^full/{print int($2)}' "${LUNA_PROC_PSI_MEMORY:-/proc/pressure/memory}")
  slice=$(slice_room_mb)
  if [[ -n "$slice" ]] && (( slice < ${LUNA_WORKER_PEAK_MB:-1200} )); then
    BOX_ROOM_WHY="worker slice ${slice}MB left under memory.high < ${LUNA_WORKER_PEAK_MB:-1200}MB worker peak"
    return 1
  fi
  (( runs < ${LUNA_MIN:-2} && avail >= 2048 )) && return 0
  # Hotfix may cross the run cap, but still requires memory headroom and no full-memory pressure.
  [[ "${LUNA_PRIORITY:-}" == hotfix ]] && (( avail >= 3072 && full < 10 )) && return 0
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
