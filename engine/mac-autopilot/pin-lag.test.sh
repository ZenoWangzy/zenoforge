#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pin-lag-test.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
fail() { echo "pin-lag.test.sh: $*" >&2; exit 1; }
source "$here/pin-lag.sh"
st=$tmp/stamp

# pure function: match clears, first sight records, limit reports, a pin resets the clock
echo "old 1" > "$st"
pin_lag_check a a "$st" 100 1800 && fail 'match must not report'; [[ ! -e $st ]] || fail 'match must clear the stamp'
pin_lag_check a b "$st" 100 1800 && fail 'first sight must not report'; [[ $(cat "$st") == "a 100" ]] || fail "first sight stamp: $(cat "$st")"
pin_lag_check a c "$st" 1899 1800 && fail 'under the limit must not report'; [[ $(cat "$st") == "a 100" ]] || fail 'main moving must not reset the clock'
lag=$(pin_lag_check a c "$st" 1900 1800) || fail 'at the limit must report'; [[ $lag == 1800 ]] || fail "lag $lag"
pin_lag_check b c "$st" 2000 1800 && fail 'a new last must restart the clock'; [[ $(cat "$st") == "b 2000" ]] || fail 'new last stamp'

# bell wiring: skip without state, skip on --check-only, event once past the limit
git init -q --bare "$tmp/origin.git"; git init -q --initial-branch=main "$tmp/root"
git -C "$tmp/root" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m one
git -C "$tmp/root" remote add origin "$tmp/origin.git"; git -C "$tmp/root" push -q origin main
main=$(git -C "$tmp/root" rev-parse HEAD)
events=(); add_event() { events+=("$1 $2"); }
ROOT=$tmp/root A=$tmp ZF_AUTO_PIN_HOME=$tmp/home CHECK_ONLY=0 now=100
mkdir -p "$tmp/home"
auto_pin_scan; ((${#events[@]} == 0)) && [[ ! -e $tmp/auto-pin-lag.stamp ]] || fail 'absent state must skip'
echo deadbeef > "$tmp/home/auto-pin.last"
CHECK_ONLY=1 auto_pin_scan; [[ ! -e $tmp/auto-pin-lag.stamp ]] || fail '--check-only must not write'
auto_pin_scan; ((${#events[@]} == 0)) || fail 'first sight raised'
now=2000 auto_pin_scan; [[ ${events[*]} == 'high auto-pin-stalled' ]] || fail "events: ${events[*]:-none}"
events=(); echo "$main" > "$tmp/home/auto-pin.last"; now=3000 auto_pin_scan
((${#events[@]} == 0)) && [[ ! -e $tmp/auto-pin-lag.stamp ]] || fail 'caught up must clear'
echo "pin-lag.test.sh: ok"
