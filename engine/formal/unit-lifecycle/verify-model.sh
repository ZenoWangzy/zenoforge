#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TLA_HOME="${TLA_HOME:-${test_host_home:-$HOME}/.local/opt/tla}"
[[ -x "$TLA_HOME/jre/bin/java" && -r "$TLA_HOME/tla2tools.jar" ]] || { echo 'BLOCKED: TLC not found; see README.md' >&2; exit 2; }
EXPECTED_TLC='UnitLifecycle:lifecycle:PASS MergeLane:merge-no-lock:FAIL MergeLane:merge-flock:PASS'
EXPECTED_REPLAY="lane-free: RAN
lane-held-refill: SKIPPED
lane-held-station: SKIPPED
lane-held-tick: RAN-AFTER-RELEASE
pass-call-sites: 1
lane-callers: 3
ledger-duplicate-id: REFUSED
ledger-missing-stage: REFUSED"
rc=0
RUN="$(mktemp -d)"
trap 'rm -rf "$RUN"' EXIT
cp "$HERE"/*.cfg "$HERE"/*.tla "$RUN/"
for pair in $EXPECTED_TLC; do
  module="${pair%%:*}"
  rest="${pair#*:}"
  cfg="${rest%%:*}"
  want="${rest##*:}"
  out="$("$TLA_HOME/jre/bin/java" -cp "$TLA_HOME/tla2tools.jar" tlc2.TLC -deadlock -workers 1 -config "$RUN/$cfg.cfg" -metadir "$RUN/$cfg-meta" "$RUN/$module.tla" 2>&1)" || :
  if grep -q 'No error has been found' <<< "$out"; then got=PASS; elif grep -q 'is violated' <<< "$out"; then got=FAIL; else got=ERROR; fi
  echo "TLC $cfg: $got (expected $want)"
  [[ "$got" != ERROR ]] || printf '%s\n' "$out" >&2
  [[ "$got" == "$want" ]] || rc=1
  if [[ "$got" == FAIL && -n "${VERIFY_TRACE:-}" ]]; then
    trace="$(sed -n '/^The behavior up to this point is:/,$p' <<< "$out")"
    if [[ -n "$trace" ]]; then printf '%s\n' "$trace"; else grep -E '^State [0-9]+:' <<< "$out"; fi
  fi
done
full="$("$HERE/replay.test.sh" 2>&1)" || :
got="$(sed -n 's/^RESULT //p' <<< "$full")"
if [[ "$got" == "$EXPECTED_REPLAY" ]]; then
  echo 'REPLAY real merge lane and unit ledger: as expected'
else
  echo 'REPLAY real merge lane and unit ledger: CHANGED'
  grep -v '^RESULT ' <<< "$full"
  diff <(echo "$EXPECTED_REPLAY") <(echo "$got")
  rc=1
fi
exit "$rc"
