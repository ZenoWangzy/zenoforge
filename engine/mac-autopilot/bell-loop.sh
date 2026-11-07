#!/usr/bin/env bash
# Resident 120-second bell poller (systemd unit zenoforge-autopilot-bell or start.sh).
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/runtime-env.sh"
source "$HERE/daemon-self-check.sh"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
LIVE="$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live"
while true; do
  bash "$LIVE/bell.sh" >> "$A/bell-loop.out" 2>&1 || true
  # The loop keeps the version directory it started in; exit between passes so the supervisor restarts it on the live one.
  if zf_daemon_stale "$HERE" "$LIVE"; then echo "bell-loop: the live engine moved, exiting for the supervisor to restart"; exit 0; fi
  sleep 120
done
