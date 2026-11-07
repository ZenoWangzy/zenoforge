#!/usr/bin/env bash
# Sourced by resident loops. A loop keeps the engine version directory it started in, so a merged and pinned fix is not live until the
# loop restarts (#656 sat unused for 13 hours in zf-auto-pin). Call zf_daemon_stale between passes and exit 0 when it is true.
# zf_daemon_stale <started_dir> <live_link>: true when <live_link> now resolves to another directory than <started_dir>.
# Only under a supervisor that restarts a clean exit: systemd sets INVOCATION_ID (the rendered units use Restart=always); a loop
# started by hand or by start.sh has none, so it keeps running. launchd is not detected, so a Mac loop keeps its old behaviour.
zf_daemon_stale() {
  [[ -n ${INVOCATION_ID:-} ]] || return 1
  local now; now=$(cd -- "$2" 2>/dev/null && pwd -P) || return 1
  [[ $now != "$1" ]]
}
