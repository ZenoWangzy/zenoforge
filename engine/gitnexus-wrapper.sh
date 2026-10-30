#!/usr/bin/env bash
set -euo pipefail

real_cli="${GITNEXUS_REAL_CLI:-$(dirname -- "${BASH_SOURCE[0]}")/gitnexus.real-link}"
resolve_analyze_memory_config() {
  local memory_cap_mb="${GITNEXUS_ANALYZE_MEMORY_CAP_MB:-5120}"
  local minimum_available_mb="${GITNEXUS_ANALYZE_MIN_AVAILABLE_MB:-$((memory_cap_mb + 2560))}"
  [[ "$memory_cap_mb" =~ ^[1-9][0-9]*$ ]] || {
    echo "gitnexus wrapper: invalid GITNEXUS_ANALYZE_MEMORY_CAP_MB=$memory_cap_mb" >&2
    return 2
  }
  [[ "$minimum_available_mb" =~ ^[1-9][0-9]*$ ]] || {
    echo "gitnexus wrapper: invalid GITNEXUS_ANALYZE_MIN_AVAILABLE_MB=$minimum_available_mb" >&2
    return 2
  }
  if (( minimum_available_mb < 6000 || minimum_available_mb < memory_cap_mb + 2560 )); then
    echo "gitnexus wrapper: minimum MemAvailable must be at least 6000MB and cap + 2560MB" >&2
    return 2
  fi
  printf '%s\t%s\n' "$memory_cap_mb" "$minimum_available_mb"
}

if [[ "${1:-}" == --print-minimum-available-mb ]]; then
  if ! memory_config="$(resolve_analyze_memory_config)"; then exit 2; fi
  IFS=$'\t' read -r _ minimum_available_mb <<< "$memory_config"
  printf '%s\n' "$minimum_available_mb"
  exit 0
fi
# ponytail: one host-wide lock prevents overlap; per-repo locks only if measured wait cost outweighs memory safety.
# Each one-shot command loads the whole graph. On 2026-09-29 a hand agent
# started 24 `gitnexus impact` calls at once; they peaked at 7.6G and froze WSL.
# One-shot commands queue on one host-wide lock; long-running servers do not.
# Homebrew flock on macOS rejects -w 0; -n is the equivalent non-blocking lock.
lock_fd() { if [[ $2 == 0 ]]; then flock -n "$1"; else flock -w "$2" "$1"; fi; }
if [[ "${1:-}" != analyze ]]; then
  case "${1:-}" in
    ''|mcp|serve|help|--help|-h|--version|-V) exec "$real_cli" "$@" ;;
  esac
  # /tmp, not AGENT_HOME: sandboxed implement agents see ~/.zenoforge read-only,
  # and a lock they cannot open broke every gitnexus call inside the sandbox.
  # Per uid: on a shared CI runner another user's lock file is not writable.
  query_lock="${GITNEXUS_QUERY_LOCK_FILE:-/tmp/zf-gitnexus-query-$(id -u).lock}"
  query_wait="${GITNEXUS_QUERY_LOCK_WAIT_SECONDS:-600}"
  mkdir -p -- "$(dirname -- "$query_lock")"
  exec 8>"$query_lock"
  if ! lock_fd 8 "$query_wait"; then
    echo "gitnexus $1 refused: query lock busy after ${query_wait}s" >&2
    exit 3
  fi
  exec "$real_cli" "$@"
fi
if [[ ! -x "$real_cli" ]]; then
  echo "gitnexus wrapper: executable missing: $real_cli" >&2
  exit 127
fi

if ! memory_config="$(resolve_analyze_memory_config)"; then exit 2; fi
IFS=$'\t' read -r memory_cap_mb minimum_available_mb <<< "$memory_config"

lock_wait_seconds="${GITNEXUS_ANALYZE_LOCK_WAIT_SECONDS:-20}"
[[ "$lock_wait_seconds" =~ ^[0-9]+$ ]] || {
  echo "gitnexus wrapper: invalid GITNEXUS_ANALYZE_LOCK_WAIT_SECONDS=$lock_wait_seconds" >&2
  exit 2
}
lock_file="${GITNEXUS_ANALYZE_LOCK_FILE:-${AGENT_HOME:-${HOME:?HOME is not set}/.zenoforge}/gitnexus-analyze.lock}"
if [[ "${ZF_GITNEXUS_REFRESH_LOCK_HELD:-0}" != 1 ]]; then
  mkdir -p -- "$(dirname -- "$lock_file")"
  exec 9>"$lock_file"
  if ! lock_fd 9 "$lock_wait_seconds"; then
    echo "gitnexus analyze refused: shared lock busy after ${lock_wait_seconds}s" >&2
    exit 3
  fi
fi

meminfo_file="${GITNEXUS_MEMINFO_FILE:-/proc/meminfo}"
available_kb="$(awk '$1 == "MemAvailable:" { print $2; exit }' "$meminfo_file" 2>/dev/null || true)"
if [[ ! "$available_kb" =~ ^[0-9]+$ ]]; then
  echo "gitnexus analyze refused: MemAvailable unavailable" >&2
  exit 3
fi
available_mb=$((available_kb / 1024))
if (( available_mb < minimum_available_mb )); then
  echo "gitnexus analyze refused: MemAvailable ${available_mb}MB < ${minimum_available_mb}MB" >&2
  exit 3
fi

execution_module="${ZF_EXECUTION_MODULE_DIR:-${AGENT_HOME:-${HOME:?HOME is not set}/.zenoforge}/checkout/engine}/execution-admission.sh"
source "$execution_module"
pipeline_execution_admit || exit $?
exec systemd-run --user --scope --quiet \
  -p "MemoryMax=${memory_cap_mb}M" -p MemorySwapMax=0 -- "$real_cli" "$@"
