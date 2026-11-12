#!/usr/bin/env bash
# Host capability record (DISTRIBUTED.md 4.9): OS, arch, WSL, CPUs, memory and CLI presence as one JSON object.
# Source for coord_caps_json, or run it to print the JSON. Detection only: nothing reads it while coordination is off.
# Env seams for tests: ZF_OS, ZF_CAPS_CLI (space list of commands to probe), ZF_PROC_VERSION_FILE, ZF_MEMINFO_FILE.

coord_caps_json() {
  local os arch wsl=false cpus mem_mb tool state cli_json
  local -a cli_args=()
  if [[ -z ${ZF_OS:-} ]]; then
    if [[ $(uname -s) == Darwin ]]; then ZF_OS=darwin; else ZF_OS=linux; fi
  fi
  os=$ZF_OS
  arch=$(uname -m)
  grep -qi microsoft "${ZF_PROC_VERSION_FILE:-/proc/version}" 2>/dev/null && wsl=true
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cpus=0
  if [[ $os == darwin ]]; then
    mem_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
  else
    mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' "${ZF_MEMINFO_FILE:-/proc/meminfo}" 2>/dev/null)
  fi
  mem_mb=${mem_mb:-0}
  for tool in ${ZF_CAPS_CLI:-codex claude zcode gh node docker}; do
    if command -v "$tool" >/dev/null 2>&1; then state=ok; else state=missing; fi
    cli_args+=(--arg "$tool" "$state")
  done
  cli_json=$(jq -n "${cli_args[@]}" '$ARGS.named')
  jq -n --arg os "$os" --arg arch "$arch" --argjson wsl "$wsl" \
    --argjson cpus "$cpus" --argjson mem_mb "$mem_mb" --argjson cli "$cli_json" \
    '{os: $os, arch: $arch, wsl: $wsl, cpus: $cpus, mem_mb: $mem_mb, cli: $cli}'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then coord_caps_json; fi
