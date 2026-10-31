#!/usr/bin/env bash
# One command: TLC on the dispatch-claim model + replay on the real dispatch code. Exit 0 = everything matches EXPECTED below.
# Exit 1 = a result changed (read it with SKILL.md). Exit 2 = TLC/Java missing (blocked, see README.md).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TLA_HOME="${TLA_HOME:-${test_host_home:-$HOME}/.local/opt/tla}"  # test-env.sh moves HOME
[[ -x "$TLA_HOME/jre/bin/java" && -r "$TLA_HOME/tla2tools.jar" ]] || { echo "BLOCKED: TLC not found in $TLA_HOME (install steps: $HERE/README.md)"; exit 2; }
# config -> expected TLC outcome. refill-gap is the open finding F1; when it flips to PASS the code was fixed: change it here.
EXPECTED_TLC="no-claim:FAIL ledger-lag-1024:FAIL refill-gap:FAIL fixed:PASS"
EXPECTED_REPLAY="live-worker-guard: HELD
slow-pr-guard: HELD
refill-pr-guard: LAUNCHED
claim-guard: HELD
coord-live-worker-pretty: LIVE"
rc=0
RUN="$(mktemp -d)"; trap 'rm -rf "$RUN"' EXIT; cp "$HERE"/*.cfg "$HERE/DispatchClaim.tla" "$RUN/"  # TLC writes TTrace files next to the spec
for pair in $EXPECTED_TLC; do
  cfg="${pair%%:*}" want="${pair##*:}"
  out="$("$TLA_HOME/jre/bin/java" -cp "$TLA_HOME/tla2tools.jar" tlc2.TLC -deadlock -workers 1 -config "$RUN/$cfg.cfg" -metadir "$RUN/meta" "$RUN/DispatchClaim.tla" 2>&1)" || :
  if grep -q 'No error has been found' <<<"$out"; then got=PASS; elif grep -q 'is violated' <<<"$out"; then got=FAIL; else got=ERROR; fi
  echo "TLC $cfg: $got (expected $want)"; [[ "$got" == "$want" ]] || rc=1
  if [[ "$got" == FAIL && -n "${VERIFY_TRACE:-}" ]]; then grep -E '^State [0-9]+:' <<<"$out" | sed 's/ line.*//'; fi
done
full="$("$HERE/replay.test.sh" 2>&1)" || :; got="$(sed -n 's/^RESULT //p' <<<"$full")"
if [[ "$got" == "$EXPECTED_REPLAY" ]]; then echo "REPLAY real dispatch(): as expected"; else
  echo "REPLAY real dispatch(): CHANGED"; grep -v '^RESULT ' <<<"$full"; diff <(echo "$EXPECTED_REPLAY") <(echo "$got"); rc=1; fi
exit "$rc"
