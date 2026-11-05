#!/usr/bin/env bash
# Sourced by bell.sh: alert when the zf-auto-pin daemon (tools/auto-pin.sh) stops pinning while main moves ahead.
# No heartbeat: a dead daemon and a stuck pin both leave auto-pin.last behind main, which is all this reads.

# pin_lag_check <last> <main> <stamp-file> <now> <limit-secs>: prints the lag in seconds and returns 0 once <last> has trailed
# <main> for <limit-secs>; returns 1 otherwise. The stamp holds "<last> <first-seen>", keyed on <last>, so any pin resets the clock.
pin_lag_check() {
  local last=$1 main=$2 stamp=$3 now=$4 limit=$5 seen_last="" seen_at=0
  if [[ -z $last || $last == "$main" ]]; then rm -f "$stamp"; return 1; fi
  read -r seen_last seen_at 2>/dev/null < "$stamp" || :
  if [[ $seen_last != "$last" ]]; then echo "$last $now" > "$stamp"; return 1; fi
  (( now - seen_at >= limit )) || return 1
  echo $((now - seen_at))
}

# Needs bell.sh's add_event, ROOT, A, now and CHECK_ONLY. Skips when this install has no auto-pin state, or on --check-only (no file writes).
auto_pin_scan() {
  local home=${ZF_AUTO_PIN_HOME:-$HOME/.zenoforge} last main lag
  [[ $CHECK_ONLY != 1 && -s $home/auto-pin.last ]] || return 0
  main=$(cd "$ROOT" && timeout 8 git ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
  [[ -n $main ]] || return 0
  read -r last < "$home/auto-pin.last"
  lag=$(pin_lag_check "$last" "$main" "$A/auto-pin-lag.stamp" "$now" "${ZF_AUTO_PIN_LAG_LIMIT:-1800}") || return 0
  add_event high auto-pin-stalled "auto-pin-stalled: last pinned ${last:0:12} trails main ${main:0:12} for ${lag}s; the zf-auto-pin daemon is dead or stuck" "systemctl --user status zf-auto-pin; ls -t $home/auto-pin-logs | head -3"
}
