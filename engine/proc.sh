#!/usr/bin/env bash
# Process and host identity helpers: source this (never execute it); it runs nothing on load.
#   pid_live PID               success when PID exists and is not a zombie
#   pid_start_id PID           opaque number that changes when a pid is reused: callers only compare it for equality
#   host_boot_id               string that changes on reboot
#   pids_with_cwd_under DIR    pids (one per line) whose working directory is DIR or below it
# Linux bodies are the /proc code the engine already had, moved here (worktree-lifecycle: pid_live, pid_start_ticks,
# load_process_cwds; lib: the boot id read). They must stay /proc reads and must not become `ps`: one ps per worker per
# poll drove the origin deployment to load 39 (see pid_running in the unit loop). macOS has no /proc, so those bodies use
# ps, sysctl and lsof.
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

  host_boot_id() { sysctl -n kern.bootsessionuuid; }

  # shortcut: lsof -F newline mode, so a cwd containing a newline never matches; lsof sees only the caller's own processes
  # without root, which covers worktree owners. Upgrade to -F0 if a path with a newline ever appears.
  pids_with_cwd_under() {
    local dir="${1%/}" line pid=""
    while IFS= read -r line; do
      case "$line" in
        p*) pid="${line#p}" ;;
        n*) if [[ "${line#n}" == "$dir" || "${line#n}" == "$dir"/* ]]; then printf '%s\n' "$pid"; fi ;;
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
  pid_start_id() {
    local stat_line rest fields
    { IFS= read -r stat_line < "/proc/$1/stat"; } 2>/dev/null || return 1
    rest="${stat_line##*) }"
    read -r -a fields <<< "$rest"
    printf '%s\n' "${fields[19]}"
  }

  host_boot_id() {
    local id
    IFS= read -r id < /proc/sys/kernel/random/boot_id || return 1
    printf '%s\n' "$id"
  }

  pids_with_cwd_under() {
    local dir="${1%/}" entry pid cwd
    while IFS= read -r -d '' entry; do
      [[ "$entry" == *' -> '* ]] || continue
      pid="${entry#/proc/}"
      pid="${pid%%/cwd -> *}"
      cwd="${entry#* -> }"
      [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
      cwd="${cwd% (deleted)}"
      if [[ "$cwd" == "$dir" || "$cwd" == "$dir"/* ]]; then printf '%s\n' "$pid"; fi
    done < <(find /proc/[0-9]*/cwd -maxdepth 0 -type l -printf '%p -> %l\0' 2>/dev/null)
    return 0
  }
fi
