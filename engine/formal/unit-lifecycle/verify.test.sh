#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
EXPECTED_REPLAY="lane-free: RAN
lane-held-refill: SKIPPED
lane-held-station: SKIPPED
lane-held-tick: RAN-AFTER-RELEASE
pass-call-sites: 1
lane-callers: 3
ledger-duplicate-id: REFUSED
ledger-missing-stage: REFUSED"
full="$("$HERE/replay.test.sh" 2>&1)" || { echo "$full"; exit 1; }
got="$(sed -n 's/^RESULT //p' <<< "$full")"
if [[ "$got" != "$EXPECTED_REPLAY" ]]; then
  echo 'REPLAY real merge lane and unit ledger: CHANGED' >&2
  grep -v '^RESULT ' <<< "$full" >&2
  diff <(echo "$EXPECTED_REPLAY") <(echo "$got")
  exit 1
fi
echo 'REPLAY real merge lane and unit ledger: as expected'
bash "$HERE/table-drift.test.sh"
