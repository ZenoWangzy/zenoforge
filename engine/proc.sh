#!/usr/bin/env bash
# Shared process and host identity helpers. Source this file; loading it performs no process probes.
# Linux stays on the /proc reads already used by the engine. macOS has no /proc, so its small
# platform-specific branches use ps and sysctl; platform-env.sh places GNU tools first on PATH.
if [[ ${OSTYPE:-} == darwin* ]]; then
  pid_live() {
    local pid="$1" state
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null || return 1
    state="$(LC_ALL=C ps -o stat= -p "$pid" 2>/dev/null)" || return 1
    state="${state// /}"
    [[ -n "$state" && "$state" != Z* ]]
  }

  pid_start_id() {
    local started
    started="$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null)" && [[ -n "$started" ]] || return 1
    LC_ALL=C date -d "$started" +%s
  }

  host_boot_id() { sysctl -n kern.bootsessionuuid; }
else
  pid_live() {
    local pid="$1" stat_line rest state
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null || return 1
    { IFS= read -r stat_line < "/proc/$pid/stat"; } 2>/dev/null || return 1
    rest="${stat_line##*) }"
    read -r state _ <<< "$rest"
    [ "$state" != Z ]
  }

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
fi
