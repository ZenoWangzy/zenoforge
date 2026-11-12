#!/usr/bin/env bash
# loop.sh runs this once at start. KillMode=process keeps the old loop's tick children alive across a
# restart; they still hold .scheduler.lock, so the new loop's first tick would skip on the lock. Wait,
# bounded, until the holder is gone. "Held" is exactly acquire_scheduler_lock's test (scheduler.d/locks-views.sh):
# the lock dir exists and its pid file names a live process whose start ticks match the recorded start (a reused pid is free);
# a missing or dead pid is a stale lock, i.e. free.
# Fail open: when the bound expires, log and return 0 so a crashed scheduler always comes back.
# Not an ExecStartPre: the host unit is not in this repo, and systemd bounds ExecStartPre by TimeoutStartSec
# (90s default) and blocks `systemctl restart` for the whole wait. loop.sh is the one path every unit and nohup start passes.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/runtime-env.sh"
lock="$MAC_AUTOPILOT_RUNTIME_DIR/.scheduler.lock"
limit="${AUTOPI_LOCK_WAIT_SECONDS:-300}"
[[ "$limit" =~ ^[0-9]+$ ]] || limit=300
holder() { # prints the live holder pid, fails when the lock is free or stale
  local pid want now
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  [[ -d "$lock" && "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  want="$(cat "$lock/start" 2>/dev/null || true)" # same /proc start ticks as coord_process_start_ticks
  if [[ "$want" =~ ^[0-9]+$ ]]; then
    now="$(pid_start_id "$pid" 2>/dev/null || true)" # proc.sh: /proc on Linux, ps on macOS
    [[ "$now" =~ ^[0-9]+$ && "$now" != "$want" ]] && return 1
  fi
  printf '%s' "$pid"
}
# A running tick lets go of the lock at every phase_yield_lock, so a free lock does not mean the old tick is gone:
# on 2026-11-07 the new loop started a second full tick beside one with 9 minutes left (528 s of two ticks on one ledger).
# loop.sh runs the tick as `bash <supervisor>/autopi-live/scheduler.sh` with no argument; read /proc with builtins, no process per entry.
live_tick() { # prints the pid of a running main tick, fails when none
  local d argv
  for d in /proc/[0-9]*; do
    { mapfile -d '' -t argv < "$d/cmdline"; } 2>/dev/null || continue # a process can exit between the glob and the read
    [[ "${#argv[@]}" == 2 && "${argv[0]##*/}" == bash && "${argv[1]}" == "$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live/scheduler.sh" ]] && { printf '%s' "${d#/proc/}"; return 0; }
  done
  return 1
}
holder_or_tick() { holder || live_tick; }
log() { printf '[%s] loop start: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"; }
waited=0
while pid="$(holder_or_tick)"; do
  (( waited > 0 )) || log "waiting up to ${limit}s for pid $pid to release .scheduler.lock"
  if (( waited >= limit )); then
    log "pid $pid still holds .scheduler.lock after ${limit}s; starting anyway"
    exit 0
  fi
  sleep 1; waited=$((waited + 1))
done
exit 0
