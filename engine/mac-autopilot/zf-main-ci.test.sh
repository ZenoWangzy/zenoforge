#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
fail() { echo "zf-main-ci.test.sh: $*" >&2; exit 1; }
source "$here/../lib.d/ci-checks.sh"; source "$here/zf-main-ci.sh"

# fixture: newest finished engine-tests run is red (an in-progress run above it is skipped), cli-tests is green
RUNS='[{"databaseId":9,"workflowName":"engine-tests","conclusion":"","headSha":"cccccccccccccccccccccccccccccccccccccccc"},
 {"databaseId":8,"workflowName":"engine-tests","conclusion":"failure","headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
 {"databaseId":7,"workflowName":"cli-tests","conclusion":"success","headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
 {"databaseId":6,"workflowName":"engine-tests","conclusion":"failure","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
LOG=$'suites (2)\tRun\t2026-11-05T13:40:00Z FAIL engine/x.test.sh rc=1\nsuites (2)\tRun\t2026-11-05T13:40:00Z     not ok - secret assertion text\n'
gh_timeout() { if [[ $4 == run && $5 == list ]]; then echo "$RUNS"; else echo "$LOG"; fi; }
events=(); add_event() { events+=("$1|$2|$3|$4"); }
ENGINE_INCIDENT_REPO=o/r now=100 STATE_JSON='{"main_ci_runs_seen":{}}'

zf_main_ci_scan
((${#events[@]} == 1)) || fail "want one event, got ${#events[@]}: ${events[*]:-none}"
[[ ${events[0]} == 'high|zf-main-red:bbbbbbbbbbbb|'* ]] || fail "event: ${events[0]}"
[[ ${events[0]} == *'engine-tests: engine/x.test.sh'* ]] || fail "test name missing: ${events[0]}"
[[ ${events[0]} != *'secret assertion text'* ]] || fail 'log line leaked'
[[ ${events[0]} == *'engine/mac-autopilot/zf-main-ci.sh'* ]] || fail 'evidence must route to the engine repo'

events=(); zf_main_ci_scan; ((${#events[@]} == 0)) || fail 'a reported run must not re-file'
echo "zf-main-ci.test.sh: ok"
