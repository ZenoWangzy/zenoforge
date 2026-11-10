# Shared total Codex/ZCode capacity used by both backend gates and the scheduler.
LUNA_RUNS_HARD_CAP=10
codex_runs() { local p n=0 pc; for p in $(pgrep -x codex) $(pgrep -x zcode-cli); do pc=$(ps -o comm= -p "$(ps -o ppid= -p "$p" | tr -d ' ')" 2>/dev/null); [[ "$pc" == codex || "$pc" == zcode-cli ]] || n=$((n+1)); done; echo "$n"; }
luna_run_cap() { local cap="${LUNA_MAX:-$LUNA_RUNS_HARD_CAP}"; (( cap < LUNA_RUNS_HARD_CAP )) || cap=$LUNA_RUNS_HARD_CAP; printf '%s\n' "$cap"; }
cpu_busy() { local a b; a=($(head -1 /proc/stat)); sleep 2; b=($(head -1 /proc/stat))
  local busy=$(( (b[1]+b[2]+b[3]+b[6]+b[7]+b[8]) - (a[1]+a[2]+a[3]+a[6]+a[7]+a[8]) )) idle=$(( (b[4]+b[5]) - (a[4]+a[5]) ))
  echo $(( 100 * busy / (busy + idle + 1) )); }
box_has_room() { # optional waiter age in seconds; shared by bin/luna, bin/zc, and the priority hold
  local age="${1:-$SECONDS}" runs avail cpu full cap
  [[ "$age" =~ ^[0-9]+$ ]] || age=0
  runs=$(codex_runs)
  cap=$(luna_run_cap)
  avail=$(awk '/^MemAvailable:/{print int($2/1024)}' "${LUNA_PROC_MEMINFO:-/proc/meminfo}")
  full=$(awk -F'avg10=' '/^full/{print int($2)}' "${LUNA_PROC_PSI_MEMORY:-/proc/pressure/memory}")
  (( runs < ${LUNA_MIN:-2} && avail >= 2048 )) && return 0
  # Hotfix may cross the run cap, but still requires memory headroom and no full-memory pressure.
  [[ "${LUNA_PRIORITY:-}" == hotfix ]] && (( avail >= 3072 && full < 10 )) && return 0
  # Aging skips only the CPU target; memory pressure, availability, and the run cap still apply.
  (( age >= ${LUNA_AGE_ADMIT_SECONDS:-1200} && runs < cap && full < 10 && avail >= ${LUNA_ADMIT_AVAIL_MB:-3328} )) && return 0
  (( runs < cap && full < 10 && avail >= ${LUNA_ADMIT_AVAIL_MB:-3328} )) || return 1
  cpu=$(cpu_busy)
  (( cpu < ${LUNA_CPU_TARGET:-85} ))
}
