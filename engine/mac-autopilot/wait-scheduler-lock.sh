#!/usr/bin/env bash
# loop.sh runs this once at start. KillMode=process keeps the old loop's tick children alive across a
# restart; they still hold .scheduler.lock, so the new loop's first tick would skip on the lock. Wait,
# bounded, until the holder is gone. "Held" is exactly acquire_scheduler_lock's test (scheduler.d/locks-views.sh):
# the lock dir exists and its pid file names a live process; a missing or dead pid is a stale lock, i.e. free.
# Fail open: when the bound expires, log and return 0 so a crashed scheduler always comes back.
# Not an ExecStartPre: the host unit is not in this repo, and systemd bounds ExecStartPre by TimeoutStartSec
# (90s default) and blocks `systemctl restart` for the whole wait. loop.sh is the one path every unit and nohup start passes.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/runtime-env.sh"
lock="$MAC_AUTOPILOT_RUNTIME_DIR/.scheduler.lock"
limit="${AUTOPI_LOCK_WAIT_SECONDS:-300}"
[[ "$limit" =~ ^[0-9]+$ ]] || limit=300
holder() { # prints the live holder pid, fails when the lock is free or stale
  local pid
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  [[ -d "$lock" && "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
}
log() { printf '[%s] loop start: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"; }
waited=0
while pid="$(holder)"; do
  (( waited > 0 )) || log "waiting up to ${limit}s for pid $pid to release .scheduler.lock"
  if (( waited >= limit )); then
    log "pid $pid still holds .scheduler.lock after ${limit}s; starting anyway"
    exit 0
  fi
  sleep 1; waited=$((waited + 1))
done
exit 0
