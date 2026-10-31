#!/usr/bin/env bash
# CI-safe replay of the real dispatch and claim code; the separate model check requires TLC.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
EXPECTED_REPLAY="live-worker-guard: HELD
slow-pr-guard: HELD
refill-pr-guard: LAUNCHED
claim-guard: HELD
coord-live-worker-pretty: LIVE"
full="$("$HERE/replay.test.sh" 2>&1)" || { echo "$full"; exit 1; }
got="$(sed -n 's/^RESULT //p' <<<"$full")"
if [[ "$got" == "$EXPECTED_REPLAY" ]]; then echo 'REPLAY real dispatch(): as expected'; else
  echo 'REPLAY real dispatch(): CHANGED'; grep -v '^RESULT ' <<<"$full"; diff <(echo "$EXPECTED_REPLAY") <(echo "$got"); exit 1; fi
