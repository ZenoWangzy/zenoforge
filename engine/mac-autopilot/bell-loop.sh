#!/usr/bin/env bash
# Resident 120-second bell poller (systemd unit zenoforge-autopilot-bell or start.sh).
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/runtime-env.sh"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
LIVE="$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live"
while true; do
  bash "$LIVE/bell.sh" >> "$A/bell-loop.out" 2>&1 || true
  sleep 120
done
