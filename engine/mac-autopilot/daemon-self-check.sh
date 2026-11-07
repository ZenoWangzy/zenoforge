#!/usr/bin/env bash
# Sourced by resident loops. A loop keeps the script bytes it started with, so a merged and pinned fix is not live until it restarts
# (#656 sat unused for 13 hours in zf-auto-pin). Call zf_daemon_stale between passes and exit 0 when it is true.
# zf_daemon_stale <started_dir> <live_dir> <own script> [file...]: true when a listed file, relative to both directories, differs in
# bytes. List the loop's own script first, then everything it sources. A pin that leaves those bytes alone does not restart the loop.
# A file missing on the live side counts as stale, except the own script: a restart must find it, or the supervisor crash-loops
# and the loop is gone. A missing sourced file is safe to restart on: the live loop script decides what it sources.
# Only under a supervisor that restarts a clean exit: systemd sets INVOCATION_ID (the rendered units use Restart=always); a loop
# started by hand or by start.sh has none, so it keeps running. launchd is not detected, so a Mac loop keeps its old behaviour.
zf_daemon_stale() {
  [[ -n ${INVOCATION_ID:-} && -d $2 && -f $2/$3 ]] || return 1
  local started=$1 live=$2 f; shift 2
  for f; do cmp -s "$started/$f" "$live/$f" || return 0; done
  return 1
}
