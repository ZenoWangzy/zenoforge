#!/usr/bin/env bash
# agent_thread_budget: share one CPU budget across agent runs (maintainer 10-29 [...]).
# Each run's vitest/pnpm/libuv otherwise spawns ~nproc threads; 7 runs put ~80 runnable threads on
# 12 cores. Sourced by dispatch-codex.sh and the .scratch luna/zc launchers, so the cap is set once.
agent_thread_budget() {
  local p pc runs=0 threads
  for p in $(pgrep -x codex) $(pgrep -x zcode-cli); do
    pc="$(cat "/proc/$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)/comm" 2>/dev/null)"
    [[ "$pc" == codex || "$pc" == zcode-cli ]] || runs=$((runs + 1))
  done
  threads=$(( $(nproc) / (runs + 1) )); (( threads >= 1 )) || threads=1
  export VITEST_MAX_THREADS=$threads VITEST_MAX_FORKS=$threads UV_THREADPOOL_SIZE=2 npm_config_workspace_concurrency=2
}
