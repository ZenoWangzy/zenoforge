#!/usr/bin/env bash
# Process and host identity helpers: source this (never execute it); it runs nothing on load.
#   pid_live PID               success when PID exists and is not a zombie
#   pid_start_id PID           opaque number that changes when a pid is reused: callers only compare it for equality
#   pid_start_id_into PID      the same value in PID_START_ID with no subshell: the ledger lock poll calls it per try
#   host_boot_id               string that changes on reboot
#   process_cwds               one NUL-terminated "PID<TAB>CWD" record per process with a known working directory
#   pids_with_cwd_under DIR    pids (one per line) whose working directory is DIR or below it (filters process_cwds)
# Linux bodies are the /proc code the engine already had, moved here (worktree-lifecycle: pid_live, pid_start_ticks,
# process_cwds; lib: the boot id read). They must stay /proc reads and must not become `ps`: one ps per worker per
# poll drove the origin deployment to load 39 (see pid_running in the unit loop). macOS has no /proc, so those bodies use
# ps, sysctl and lsof.
_hostinfo() {
  local engine_dir
  engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  python3 "$engine_dir/hostinfo.py" "$@"
}

host_mem_avail_mb() {
  local meminfo_file="${1:-}" available_kib
  if [[ -z "$meminfo_file" && ${OSTYPE:-} == darwin* ]]; then
    _hostinfo mem_avail_mb
    return
  fi
  meminfo_file="${meminfo_file:-/proc/meminfo}"
  available_kib="$(awk '$1 == "MemAvailable:" { print $2; found=1; exit } END { if (!found) exit 1 }' "$meminfo_file" 2>/dev/null)" || return 1
  [[ "$available_kib" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((available_kib / 1024))"
}

host_load1() {
  local loadavg_file="${1:-}"
  if [[ -z "$loadavg_file" && ${OSTYPE:-} == darwin* ]]; then
    _hostinfo load1
    return
  fi
  loadavg_file="${loadavg_file:-/proc/loadavg}"
  awk 'NR == 1 { print $1; found=1; exit } END { if (!found) exit 1 }' "$loadavg_file" 2>/dev/null
}

host_ncpu() {
  if [[ ${OSTYPE:-} == darwin* ]]; then
    _hostinfo ncpu
  else
    nproc
  fi
}

host_cpu_busy_pct() {
  local stat_file="${1:-}" a b
  if [[ -z "$stat_file" && ${OSTYPE:-} == darwin* ]]; then
    _hostinfo cpu_busy_pct
    return
  fi
  stat_file="${stat_file:-/proc/stat}"
  a=($(head -1 "$stat_file"))
  sleep 2
  b=($(head -1 "$stat_file"))
  local busy=$(( (b[1]+b[2]+b[3]+b[6]+b[7]+b[8]) - (a[1]+a[2]+a[3]+a[6]+a[7]+a[8]) )) idle=$(( (b[4]+b[5]) - (a[4]+a[5]) ))
  printf '%s\n' "$((100 * busy / (busy + idle + 1)))"
}

host_mem_pressure_pct() {
  local pressure_file="${1:-}" pressure
  if [[ -z "$pressure_file" && ${OSTYPE:-} == darwin* ]]; then
    pressure="$(_hostinfo mem_pressure_pct)" || return 1
    [[ "$pressure" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    printf '%s\n' "${pressure%%.*}"
    return
  fi
  pressure_file="${pressure_file:-/proc/pressure/memory}"
  awk -F'avg10=' '/^full/{print int($2); found=1; exit} END { if (!found) exit 1 }' "$pressure_file" 2>/dev/null
}

if [[ ${OSTYPE:-} == darwin* ]]; then
  pid_live() {
    local pid="$1" state
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null || return 1
    state="$(LC_ALL=C ps -o stat= -p "$pid" 2>/dev/null)" || return 1
    state="${state// /}"
    [[ -n "$state" && "$state" != Z* ]]
  }

  # Epoch seconds of the process start. Still numeric, because callers validate ^[0-9]+$.
  # shortcut: one-second resolution, so a pid reused within the same second looks unchanged; macOS pids wrap at 99999, so never in practice.
  pid_start_id() {
    local started
    started="$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null)" && [[ -n "$started" ]] || return 1
    LC_ALL=C date -d "$started" +%s
  }
  pid_start_id_into() { PID_START_ID="$(pid_start_id "$1" 2>/dev/null)"; } # macOS keeps ps: a fork per call here

  host_boot_id() { sysctl -n kern.bootsessionuuid; }

  # shortcut: lsof -F newline mode, so a cwd containing a newline never matches; lsof sees only the caller's own processes
  # without root, which covers worktree owners. Upgrade to -F0 if a path with a newline ever appears.
  process_cwds() {
    local line pid=""
    while IFS= read -r line; do
      case "$line" in
        p*) pid="${line#p}" ;;
        n*) printf '%s\t%s\0' "$pid" "${line#n}" ;;
      esac
    done < <(lsof -a -d cwd -Fpn 2>/dev/null)
    return 0
  }
else
  pid_live() {
    local pid="$1" stat_line rest state
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null || return 1
    { IFS= read -r stat_line < "/proc/$pid/stat"; } 2>/dev/null || return 1 # braces: a vanished pid must not print the redirect error
    rest="${stat_line##*) }"
    read -r state _ <<< "$rest"
    [ "$state" != Z ]
  }

  # /proc/PID/stat field 22 (clock ticks since boot), fields counted after the "(comm) " that may itself contain spaces and parentheses.
  pid_start_id_into() {
    local stat_line rest fields
    { IFS= read -r stat_line < "/proc/$1/stat"; } 2>/dev/null || return 1
    rest="${stat_line##*) }"
    read -r -a fields <<< "$rest"
    PID_START_ID="${fields[19]}"
  }
  pid_start_id() { pid_start_id_into "$1" && printf '%s\n' "$PID_START_ID"; }

  host_boot_id() {
    local id
    IFS= read -r id < /proc/sys/kernel/random/boot_id || return 1
    printf '%s\n' "$id"
  }

  # One find for all processes: callers that check many owner paths per pass read this once.
  process_cwds() {
    local entry pid cwd
    while IFS= read -r -d '' entry; do
      [[ "$entry" == *' -> '* ]] || continue
      pid="${entry#/proc/}"
      pid="${pid%%/cwd -> *}"
      cwd="${entry#* -> }"
      [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
      cwd="${cwd% (deleted)}"
      [ -n "$cwd" ] && printf '%s\t%s\0' "$pid" "$cwd"
    done < <(find /proc/[0-9]*/cwd -maxdepth 0 -type l -printf '%p -> %l\0' 2>/dev/null)
    return 0
  }
fi

pids_with_cwd_under() {
  local dir="${1%/}" row pid cwd
  while IFS= read -r -d '' row; do
    pid="${row%%$'\t'*}"
    cwd="${row#*$'\t'}"
    if [[ "$cwd" == "$dir" || "$cwd" == "$dir"/* ]]; then printf '%s\n' "$pid"; fi
  done < <(process_cwds)
  return 0
}
