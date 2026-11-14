#!/usr/bin/env bash
# Size admission cuts a ticket at 80% of the limit by estimate, and counts fixture JSON only past 500 lines.
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

# A ticket estimated past 80% of the limit is sent to recut at write-start, with the 80% line as the limit; the limit itself stays for diffs and waivers.
SIZE_ADMISSION_LINES=800; TICK_DISPATCH_LOCAL_REFILL=false
rejects=0 rejected_lines='' rejected_limit=''
size_admission_reject() { rejects=$((rejects + 1)); rejected_lines="$2"; rejected_limit="$9"; return 1; }
ws() { rejects=0; size_admission_write_start u "" "{\"id\":\"u\",\"estimated_changed_lines\":$1${2:+,$2}}" || :; }
ws 640; [[ "$rejects" == 0 ]] || fail 'an estimate at 80% of the limit was refused'
ws 641; [[ "$rejects" == 1 && "$rejected_lines" == 641 && "$rejected_limit" == 640 ]] || fail "an estimate of 641 was not refused at the 640 line (rejects=$rejects lines=$rejected_lines limit=$rejected_limit)"
rejects=0; size_admission_write_start u "" '{"id":"u","estimated_changed_lines":null}' || :; [[ "$rejects" == 0 ]] || fail 'a null estimate was refused'
ws 700 '"size_waiver":{"max_lines":1000}'; [[ "$rejects" == 0 ]] || fail 'a waived ticket was cut at 80% of the configured limit'
ws 1001 '"size_waiver":{"max_lines":1000}'; [[ "$rejects" == 1 && "$rejected_limit" == 1000 ]] || fail 'a waived ticket was not refused at its waiver'
# Two rechecks of one unit at one head in one pass: one gh read, at most one fetch, one footprint write (units.json is the stub's state).
calls="$fixture/recheck.calls"; : > "$calls"
echo '{"units":[{"id":"issue-7","pr":77,"stage":"implement-pending"}]}' > "$UNITS"
gh() { echo gh >> "$calls"; printf 'a/src/x.ts\n'; }
git() { if [[ "$3" == fetch ]]; then echo fetch >> "$calls"; return 0; fi; case "$3" in merge-base) echo abc ;; diff) printf '100\t0\ta/src/x.ts\n' ;; esac; }
set_unit() { echo "set $1" >> "$calls"; jq --arg id "$1" "(.units[] |= (if .id==\$id then ($2) else . end))" "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"; }
pass_recheck() { local -A TICK_SIZE_RECHECK_MEMO=(); local TICK_SIZE_RECHECK_PASS=true; size_admission_recheck issue-7 "$fixture/repo" feat ctx abc1234 false; size_admission_recheck issue-7 "$fixture/repo" feat ctx abc1234 false; }
pass_recheck || fail 'a recheck in a pass failed'
[[ "$(grep -c '^gh$' "$calls")" == 1 ]] || fail "a repeated recheck of one unit and head read gh $(grep -c '^gh$' "$calls") times"
[[ "$(grep -c '^fetch$' "$calls")" -le 1 ]] || fail 'a repeated recheck of one unit and head fetched more than once'
[[ "$(grep -c '^set ' "$calls")" == 1 ]] || fail "an unchanged footprint was written again ($(grep -c '^set ' "$calls") writes)"
unset -f gh git set_unit pass_recheck

# A split delivery moves its parent to tracker; a failed move goes to the supervisor and the split still returns 0.
gh() { return 1; }
scheduler_auto_filed_issue_create() { echo "https://github.com/o/r/issues/41"; }
unit_field() { echo t; }
hist() { echo '{}'; }
set_unit() { :; }
say() { :; }
transitions='' supervisor_msg=''
scheduler_issue_transition() { transitions="$1|$2|$3|$4"; return "${TRANSITION_RC:-0}"; }
to_supervisor() { supervisor_msg="$1|$2"; }
printf 'slice report\n' > "$fixture/split-report"
split_followup_issue issue-40 40 50 'SPLIT: the rest' "$fixture/split-report"
[[ "$transitions" == '40|tracker|intake-parent:roadmap-container:split-delivery|.tracker_parent = true' ]] || fail "a split did not move the parent to tracker ($transitions)"
TRANSITION_RC=1; rc=0; split_followup_issue issue-40 40 50 'SPLIT: the rest' "$fixture/split-report" || rc=$?
[[ "$rc" == 0 && "$supervisor_msg" == 'issue-40|split remainder #41 filed but parent #40 could not transition to tracker' ]] || fail "a failed tracker move was not sent to the supervisor with rc 0 (rc=$rc $supervisor_msg)"
echo "size-admission-estimate.test.sh: all assertions passed"
