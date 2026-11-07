#!/usr/bin/env bash
# Resident 120-second bell poller (systemd unit zenoforge-autopilot-bell or start.sh).
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/runtime-env.sh"
source "$HERE/daemon-self-check.sh"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
LIVE="$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live"
while true; do
  bash "$LIVE/bell.sh" >> "$A/bell-loop.out" 2>&1 || true
  # The loop keeps the script bytes it started with; exit between passes when its script or a file it sources changed on the live
  # side, so the supervisor restarts it. bell.sh is run fresh each pass and is not listed.
  if zf_daemon_stale "$HERE" "$LIVE" bell-loop.sh runtime-env.sh daemon-self-check.sh ../config.sh ../platform-env.sh ../proc.sh; then
    echo "bell-loop: a script it uses changed on the live engine, exiting for the supervisor to restart"; exit 0
  fi
  sleep 120
done
