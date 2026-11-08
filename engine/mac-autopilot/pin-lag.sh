#!/usr/bin/env bash
# Sourced by bell.sh: alert when the zf-auto-pin daemon (tools/auto-pin.sh) stops pinning while main moves ahead.
# No heartbeat: a dead daemon and a stuck pin both leave the last PINNED line behind main, which is all this reads.
# auto-pin.last is not read: a failed pin writes its SHA there too, so it looks current.

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
  local home=${ZF_AUTO_PIN_HOME:-$HOME/.zenoforge} log main pinned fails first_fail fail_log lag
  log=$home/auto-pin.log
  [[ $CHECK_ONLY != 1 && -s $log ]] || return 0
  main=$(cd "$ROOT" && timeout 8 git ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
  [[ -n $main ]] || return 0
  # Pinned means the last PINNED line; a failed pin has no successful line, so it does not count as pinned.
  pinned=$(sed -n 's/^[0-9:]* PINNED \([0-9a-f]*\) .*/\1/p' "$log" | tail -1)
  read -r fails first_fail fail_log <<< "$(awk '/ PINNED /{n = 0} / PIN-FAILED /{if (n++ == 0) {f = $3; l = substr($4, 5)}} END {print n + 0, f, l}' "$log")"
  if (( fails >= 2 )); then
    add_event high auto-pin-failing "auto-pin-failing: $fails PIN-FAILED since the last pin ${pinned:-none}; first failed ${first_fail}; log $fail_log" "tail -5 $log; systemctl --user status zf-auto-pin"
  fi
  lag=$(pin_lag_check "$pinned" "${main:0:12}" "$A/auto-pin-lag.stamp" "$now" "${ZF_AUTO_PIN_LAG_LIMIT:-1800}") || return 0
  add_event high auto-pin-stalled "auto-pin-stalled: last pinned ${pinned:0:12} trails main ${main:0:12} for ${lag}s; the zf-auto-pin daemon is dead or stuck" "systemctl --user status zf-auto-pin; ls -t $home/auto-pin-logs | head -3"
}
