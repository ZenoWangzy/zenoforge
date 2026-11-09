#!/usr/bin/env bash
# Size admission cuts a ticket at 60% of the limit by estimate, and counts fixture JSON only past 500 lines.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/size-admission-estimate"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo"
jq '.auto_merge = false | .advisor = false | .precheck = false' "$script_dir/config.template.json" > "$sup/autopi/config.json"
echo '{"units":[]}' > "$sup/autopi/units.json"
echo '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { echo "size-admission-estimate.test.sh: $*" >&2; exit 1; }
tab() { printf '%s\t0\t%s\n' "$1" "$2"; }

# Fixture JSON is free up to 500 lines and counts in full above that; source lines always count.
[[ "$({ tab 100 a/src/x.ts; tab 500 a/tests/fixtures/big.json; } | changed_lines_count)" == 100 ]] || fail 'a 500-line fixture was counted'
[[ "$({ tab 100 a/src/x.ts; tab 300 a/test/fixtures/a.json; tab 201 a/fixtures/b.json; } | changed_lines_count)" == 601 ]] || fail 'fixtures past 500 lines were not counted in full'
[[ "$({ tab 40 a/src/fixtures.ts; } | changed_lines_count)" == 40 ]] || fail 'a non-JSON file named fixtures was dropped'

# A ticket estimated past 60% of the limit is refused at write-start, with the 60% line as the limit; the limit itself stays for diffs and waivers.
SIZE_ADMISSION_LINES=800; TICK_DISPATCH_LOCAL_REFILL=false
rejects=0 rejected_lines='' rejected_limit=''
size_admission_reject() { rejects=$((rejects + 1)); rejected_lines="$2"; rejected_limit="$9"; return 1; }
ws() { rejects=0; size_admission_write_start u "" "{\"id\":\"u\",\"estimated_changed_lines\":$1${2:+,$2}}" || :; }
ws 480; [[ "$rejects" == 0 ]] || fail 'an estimate at 60% of the limit was refused'
ws 500; [[ "$rejects" == 1 && "$rejected_lines" == 500 && "$rejected_limit" == 480 ]] || fail "an estimate of 500 was not refused at the 480 line (rejects=$rejects lines=$rejected_lines limit=$rejected_limit)"
ws 700 '"size_waiver":{"max_lines":1000}'; [[ "$rejects" == 0 ]] || fail 'a waived ticket was cut at 60% of the configured limit'
ws 1001 '"size_waiver":{"max_lines":1000}'; [[ "$rejects" == 1 && "$rejected_limit" == 1000 ]] || fail 'a waived ticket was not refused at its waiver'
echo "size-admission-estimate.test.sh: all assertions passed"
