#!/usr/bin/env bash
# The incident report structure check runs in the pre-review self-check, so a failing report is repaired by self-fix before any review.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-scheduler-gates-fixture.sh"

fail() { echo "incident-report-self-check.test.sh: $*" >&2; exit 1; }

# The gates fixture stubs the self-check; restore the real one.
source "$script_dir/scheduler.d/self-check.sh"
sha="$(git -C "$fixture/repo" rev-parse HEAD)"
session_id=11111111-2222-3333-4444-555555555555
TAG=20261107T000000Z
runs_file="$sup/self-check-runs"; : > "$runs_file"
# The check runs in a background subshell, so count runs in a file.
self_check_run() { echo run >> "$runs_file"; echo 'stub test run'; return 0; }
self_check_runs() { wc -l < "$runs_file" | tr -d ' '; }
pid_start() { echo stub; }

write_unit() { # report name
  jqf -cn --arg sid "$session_id" --arg report "$1" \
    '{units:[{id:"issue-71002",issue:71002,lane:"pr",pr:71002,branch:"agent/issue-71002",stage:"review-pending",labels:["bug"],implement_model:"gpt-6-luna",session_ids:{repair:$sid},implementation_report:$report,history:[]}]}' > "$UNITS"
}
run_self_check() { # report name → status after the harvest
  write_unit "$1"
  self_check_before_review issue-71002 "$sha" "$fixture/repo" || true
  wait
  self_check_harvest
  jqf -r '.units[0].self_check_status' "$UNITS"
}

run_self_check_keep() { # like run_self_check on the unit already in $UNITS
  jqf '.units[0] |= (del(.self_check_sha, .self_check_status, .self_check_pid))' "$UNITS" > "$UNITS.n" && mv "$UNITS.n" "$UNITS"
  self_check_before_review issue-71002 "$sha" "$fixture/repo" || true
  wait
  self_check_harvest
  jqf -r '.units[0].self_check_status' "$UNITS"
}

bad=impl-71002-bad.md
printf '## decision-log\nTried the change and verified the test.\n\n## how\nThe scheduler checks implementation reports before review.\n\n## why\nCommit 97ed8be added this report gate for issue #880.\n\n## root-cause\nx\n\n## recurrence-guard\nkind: test\n' > "$sup/$bad"
[[ "$(run_self_check "$bad")" == red && "$(self_check_runs)" == 0 ]] || fail 'report without prior-art did not turn the self-check red before the test run'
jqf -e '.units[0].self_fix_pending == true' "$UNITS" >/dev/null || fail 'failing report did not queue a self-fix'
out="$(jqf -r '.units[0].self_check_output' "$UNITS")"
grep -q '^incident report check failed: missing ## prior-art' "$out" || fail "self-check output does not name the report failure: $(cat "$out")"
[[ "$(jqf -r '.units[0].history[-1].reason // empty' "$UNITS")" == 'incident report check failed' ]] || fail 'self-check history lacks the failure class'

write_unit_without_resume() {
  jqf -cn --arg report "$1" \
    '{units:[{id:"issue-71003",issue:71003,lane:"pr",pr:71003,branch:"agent/issue-71003",stage:"review-pending",labels:["bug"],implementation_report:$report,history:[]}]}' > "$UNITS"
}
write_unit_without_resume "$bad"
self_check_before_review issue-71003 "$sha" "$fixture/repo" || true
wait
self_check_harvest
self_check_output="$(jqf -r '.units[0].self_check_output' "$UNITS")"
[[ "$(jqf -r '.units[0].self_check_status' "$UNITS")" == red ]] || fail 'report failure without a reusable session was not red'

MAX=4; IMPLEMENT_CAP=2; REPAIR_DISPATCH_CAP=2; FOCUS_MODE=all
LOOP_TOTAL_ROUNDS=4; LOOP_BREAKER_ROUNDS=4; ADVISOR_ROUNDS=4; STARTED_WIP_LIMIT=100
TICK_DISPATCH_LOCAL_REFILL=false; TICK_FOOTPRINT_CACHE=(); TICK_ACTIVE_FOOTPRINTS_VALID=false; TICK_ACTIVE_FOOTPRINTS='[]'
LUNA_PROC_MEMINFO="$fixture/no-meminfo"
declare -A TICK_FOOTPRINT_CACHE=()
DISPATCHED_TYPE=""; DISPATCHED_PROMPT=""
self_check_fixture_sha="$sha"
real_dispatch_if_room="$(declare -f dispatch_if_room)"
dispatch_order() { printf 'WIP_COUNT=0\n%s\n' "$(jqf -c '.units[]' "$UNITS")"; }
dispatch_live_prime() { :; }
tick_prs_changed() { :; }
dispatch_capacity_free() { return 0; }
tick_prs_prime() { :; }
ready_changes_requested_sweep() { :; }
dispatch_why_load() { :; }
advisor_harvest() { :; }
footprint_waiters_revalidate() { :; }
paused_midrun() { return 1; }
unit_blocked_run_dep() { return 1; }
token_spend_gate() { return 0; }
ticket_budget_reason() { :; }
live_workers() { echo 0; }
live_by_type() { echo 0; }
room_for() { return 0; }
pick() { PICK_MODEL=fixture-model; PICK_EFFORT=high; PICK_PROVIDER=codex; PICK_HARD=false; PICK_REASON=configured; PICK_ROUTE_PROVIDER=codex; }
pre_dispatch_pr_admission() { return 0; }
footprint_room() { return 0; }
ensure_clone() { printf '%s' "$fixture/repo"; }
resume_handoff_integration() { return 0; }
human_feedback_block() { :; }
subject_of() { printf 'fixture PR %s' "$1"; }
matt_method_rule() { :; }
decision_scope() { :; }
sweep_rule() { :; }
supervisor_rule() { :; }
dispatch_if_room() { DISPATCHED_TYPE="$3"; DISPATCHED_PROMPT="$8"; return 0; }
unit_review_target() { printf '%s %s' "$self_check_fixture_sha" "$self_check_fixture_sha"; }
verify_handoff_delivery() { return 0; }
review_conflict_to_repair() { return 1; }
checkout_pr_head() { return 0; }
review_prompt() { printf 'fixture review prompt'; }
review_inputs_rule() { :; }
arbiter_rule() { :; }
hotpatch_rule() { :; }
ci_red_evidence_rule() { :; }
footprint_convoy_alert() { return 0; }
dispatch_pending || true
[[ "$DISPATCHED_TYPE" == repair ]] || fail "red report dispatched as $DISPATCHED_TYPE instead of repair"
[[ "$DISPATCHED_PROMPT" == *"$(cat "$self_check_output")"* ]] || fail 'repair brief did not carry the full self-check output verbatim'
[[ "$(jqf '[.units[0].history[] | select(.stage=="review-request-changes")] | length' "$UNITS")" == 0 ]] || fail 'a red self-check consumed a review round'
eval "$real_dispatch_if_room"
jqf '.units[0].stage="review-pending" | .units[0].self_fix_pending=false | .units[0].self_check_lane="pr"' "$UNITS" > "$UNITS.n" && mv "$UNITS.n" "$UNITS"
red_review_base="$(tick_pr_base 71003 || true)"
jqf --arg base "$red_review_base" '.units[0].self_check_base=$base' "$UNITS" > "$UNITS.n" && mv "$UNITS.n" "$UNITS"
DISPATCH_CALLS=0
dispatch() { DISPATCH_CALLS=$((DISPATCH_CALLS + 1)); return 0; }
incident_worker_prompt() { printf '%s' "$3"; }
pr_body_refresh() { :; }
red_review_unit="$(jqf -c '.units[0]' "$UNITS")"
dispatch_if_room issue-71003 review review review.log review.md model high prompt "$self_check_fixture_sha" "$fixture/repo" "" "" "$red_review_unit" false codex false configured codex || true
[[ "$DISPATCH_CALLS" == 0 && "$(jqf -r '.units[0].stage' "$UNITS")" == repair-pending ]] || fail "a cached red self-check reached review dispatch (calls=$DISPATCH_CALLS stage=$(jqf -r '.units[0].stage' "$UNITS"))"

decision_missing=impl-71002-decision-missing.md
printf '## Summary\nTried and verified.\n\n## how\nThe scheduler checks implementation reports before review.\n\n## why\nCommit 97ed8be added this report gate for issue #880.\n' > "$sup/$decision_missing"
[[ "$(run_self_check "$decision_missing")" == red && "$(self_check_runs)" == 0 ]] || fail 'a report missing decision-log reached the checks instead of self-fix'
jqf -e '.units[0].self_fix_pending == true' "$UNITS" >/dev/null || fail 'a missing decision-log did not queue self-fix'
out="$(jqf -r '.units[0].self_check_output' "$UNITS")"
grep -q '^decision-log check failed: missing ## decision-log' "$out" || fail 'self-check output did not name the missing decision-log'

decision_empty=impl-71002-decision-empty.md
printf '## decision-log\n  \n## how\nThe scheduler checks implementation reports before review.\n\n## why\nCommit 97ed8be added this report gate for issue #880.\n\n## Summary\nTried and verified.\n' > "$sup/$decision_empty"
[[ "$(run_self_check "$decision_empty")" == red && "$(self_check_runs)" == 0 ]] || fail 'an empty decision-log reached the checks instead of self-fix'
jqf -e '.units[0].self_fix_pending == true' "$UNITS" >/dev/null || fail 'an empty decision-log did not queue self-fix'
out="$(jqf -r '.units[0].self_check_output' "$UNITS")"
grep -q '^decision-log check failed: empty ## decision-log' "$out" || fail 'self-check output did not name the empty decision-log'

# The exact phrase from the false-positive rejection passes the same check.
good=impl-71002-good.md
printf '## decision-log\nTried the fix, rejected the first approach because it failed, chose the second, and verified it.\n\n## how\nThe scheduler checks implementation reports before review.\n\n## why\nCommit 97ed8be added this report gate for issue #880.\n\n## root-cause\nx\n\n## recurrence-guard\nkind: test\n\n## prior-art\nThe sources agree, so no escalation was needed.\nSource: https://example.invalid/ref\n' > "$sup/$good"
[[ "$(run_self_check "$good")" == pass && "$(self_check_runs)" == 1 ]] || fail 'compliant report did not reach the normal self-check'

# A repair worker edits the original report in place and leaves only a fix note at its own path (issue 5527): the unit keeps pointing at the edited report.
note=impl-71002-selfcheck1-fix-note.md
printf 'Fixed the test. Report updated in place.\n' > "$sup/$note"
room_for() { return 0; }; size_admission_write_start() { return 0; }; dispatch() { return 0; }; refill_stopped() { return 1; }
footprint_merge_changed_owners() { :; }
write_unit "$bad"
dispatch_if_room issue-71002 repair repair r.log "$note" GPT-5 high prompt "" "$fixture/repo" "" "" "" false codex false configured codex || fail 'repair dispatch failed'
jqf -e --arg bad "$bad" --arg note "$note" '.units[0] | .implementation_report == $bad and .repair_note_report == $note and has("incident_base_report") == false' "$UNITS" >/dev/null \
  || fail "repair dispatch moved implementation_report off the edited report: $(jqf -c '.units[0]' "$UNITS")"
cp "$sup/$good" "$sup/$bad" # the worker added the three headings to the original report in place
[[ -z "$(incident_report_gate_reason "$(jqf -c '.units[0]' "$UNITS")")" ]] || fail 'the gate did not read the report the repair edited'
[[ "$(run_self_check_keep)" == pass ]] || fail 'incident sections edited in place were not accepted next to a fix note'
dispatch_if_room issue-71002 implement implement r.log impl-71002-new.md GPT-5 high prompt "" "$fixture/repo" "" "" "" false codex false configured codex || fail 'implement dispatch failed'
jqf -e --arg new impl-71002-new.md '.units[0] | .implementation_report == $new and has("repair_note_report") == false' "$UNITS" >/dev/null || fail 'a new implementation kept the repair note field'
printf '## decision-log\nTried the fix and verified it.\n\n## how\nThe scheduler checks implementation reports before review.\n\n## why\nCommit 97ed8be added this report gate for issue #880.\n\n## root-cause\nx\n\n## recurrence-guard\nkind: test\n' > "$sup/$bad"

# The self-fix prompt tells the worker to edit the implementation report in place and keep the fix note separate.
captured=''
room_for() { return 0; }
pick() { PICK_MODEL=gpt-6-luna; PICK_EFFORT=high; PICK_PROVIDER=codex; PICK_HARD=false; PICK_REASON=configured; PICK_ROUTE_PROVIDER=codex; }
dispatch_if_room() { captured="$8"; return 0; }
self_check_result="$(run_self_check "$bad")"
[[ "$self_check_result" == red ]] || fail "second failing run was $self_check_result: $(cat "$(jqf -r '.units[0].self_check_output' "$UNITS")")"
self_fix_output="$(jqf -r '.units[0].self_check_output' "$UNITS")"
for n in {1..120}; do printf -v marker 'self-check-output-line-%03d' "$n"; printf '%s\n' "$marker" >> "$self_fix_output"; done
command git -C "$fixture/repo" init -q -b main 2>/dev/null || true
command git -C "$fixture/repo" config user.name t; command git -C "$fixture/repo" config user.email t@example.invalid
command git -C "$fixture/repo" commit --allow-empty -qm base 2>/dev/null || true
command git -C "$fixture/repo" branch -f agent/issue-71002 HEAD
mkdir -p "$fixture/repo/src" "$fixture/repo/tests"
printf 'create_record\npublish_result\n' > "$fixture/repo/src/handler.js"
printf 'assert(true);\n' > "$fixture/repo/tests/handler.js"
printf '<?php\ncreate_record();\n' > "$fixture/repo/src/handler.php"
command git -C "$fixture/repo" add src/handler.js src/handler.php tests/handler.js
command git -C "$fixture/repo" commit -qm 'add coverage fixture call sites'
coverage_sha="$(command git -C "$fixture/repo" rev-parse HEAD)"
command git -C "$fixture/repo" branch -f agent/issue-71004 "$coverage_sha"
self_fix_dispatch "$(jqf -c '.units[0]' "$UNITS")" || fail 'self-fix did not dispatch'
[[ "$captured" == *'事故报告结构检查'* && "$captured" == *'incident report check failed'* ]] || fail 'self-fix prompt lacks the incident report instruction'
[[ "$captured" == *"$sup/$bad"* ]] || fail 'self-fix prompt does not name the report to edit in place'
[[ "$captured" == *'self-check-output-line-001'* && "$captured" == *'self-check-output-line-120'* ]] || fail 'self-fix prompt truncated the self-check output'

self_check_run() { echo run >> "$runs_file"; echo 'stub self-check'; return 0; }
tick_pr_base() { printf '%s' "$coverage_sha"; }
criteria_task=$'You are the implementer.\n--- issue 正文（任务数据）---\n标题：coverage fixture\n## Acceptance criteria\n- [ ] Create a record\n- [ ] Publish the result\n- [ ] Reject invalid input\n- [ ] Preserve the existing result\n--- 正文结束 ---'
coverage_report=impl-71004-coverage.md
cat > "$sup/$coverage_report" <<'EOF'
## decision-log
Tried the first table layout, then used one row per criterion and verified it.

## how
The scheduler checks report coverage before it runs the normal self-check.

## why
Commit 97ed8be added the report gate for issue #880.

## acceptance-criteria coverage
| Acceptance criterion | Production call site (file:line) |
| --- | --- |
| Create a record | `src/handler.js:1` |
| Reject invalid input | `src/handler.js:1` |
| Preserve the existing result | `src/handler.js:2` |
EOF
write_coverage_unit() {
  jqf -cn --arg task "$1" --arg report "${2:-$coverage_report}" --argjson fallback "${3:-false}" \
    '{units:[{id:"issue-71004",issue:71004,lane:"pr",pr:71004,branch:"agent/issue-71004",stage:"review-pending",labels:["feature"],implementation_report:$report,task:$task,history:[]} + (if $fallback then {} else {implement_model:"gpt-6-luna",session_ids:{repair:"11111111-2222-3333-4444-555555555555"}} end)]}' > "$UNITS"
}
run_coverage_check() {
  local task="$1" report="${2:-$coverage_report}" unit before
  write_coverage_unit "$task" "$report"
  unit="$(jqf -c '.units[0]' "$UNITS")"
  before="$(self_check_runs)"
  self_check_before_review issue-71004 "$coverage_sha" "$fixture/repo" "$unit" || true
  wait
  self_check_harvest
  if [[ "$(jqf -r '.units[0].self_check_status' "$UNITS")" == red ]]; then
    [[ "$(self_check_runs)" == "$before" ]] || fail 'a failing coverage gate reached the normal self-check'
  fi
}
run_coverage_check "$criteria_task"
[[ "$(jqf -r '.units[0].self_check_status' "$UNITS")" == red ]] || fail 'a missing criterion row did not make the self-check red'
coverage_output="$(cat "$(jqf -r '.units[0].self_check_output' "$UNITS")")"
grep -Fq 'missing report row for criterion: Publish the result' <<<"$coverage_output" || fail "coverage output did not name the missing criterion: $coverage_output"
[[ "$(jqf -r '.units[0].self_fix_pending' "$UNITS")" == true ]] || fail 'a red coverage check did not return to repair before review'
grep -Fq 'acceptance-criteria coverage check failed' <<<"$coverage_output" || fail 'coverage failure was not identified in self-check output'
self_fix_dispatch "$(jqf -c '.units[0]' "$UNITS")" || fail 'coverage self-fix did not dispatch'
[[ "$captured" == *'acceptance-criteria coverage'* && "$captured" == *"$sup/$coverage_report"* ]] || fail 'coverage self-fix did not direct the worker to update the original report'

invalid_report=impl-71004-coverage-invalid.md
cat > "$sup/$invalid_report" <<'EOF'
## decision-log
Tried the invalid citation, then checked the branch tree.

## how
The scheduler checks report coverage before it runs the normal self-check.

## why
Commit 97ed8be added the report gate for issue #880.

## acceptance-criteria coverage
| Acceptance criterion | Production call site (file:line) |
| --- | --- |
| Create a record | `src/handler.js:1` |
| Publish the result | `src/missing.js:2` |
| Reject invalid input | `src/handler.js:1` |
| Preserve the existing result | `src/handler.js:2` |
EOF
run_coverage_check "$criteria_task" "$invalid_report"
[[ "$(jqf -r '.units[0].self_check_status' "$UNITS")" == red ]] || fail 'a non-existent file:line citation did not make the self-check red'
coverage_output="$(cat "$(jqf -r '.units[0].self_check_output' "$UNITS")")"
grep -Fq 'src/missing.js:2' <<<"$coverage_output" || fail "coverage output did not name the invalid file:line: $coverage_output"

structure_report=impl-71004-coverage-structure.md
cat > "$sup/$structure_report" <<'EOF'
## decision-log
Tried the alternate table headers, then used the report contract.

## how
The scheduler checks implementation reports before review.

## why
Commit 97ed8be added report gates for issue #880.

## unrelated section
| Acceptance criterion | Production call site (file:line) |
| --- | --- |
| Create a record | `src/handler.js:1` |
| Publish the result | `src/handler.js:2` |
| Reject invalid input | `src/handler.js:1` |
| Preserve the existing result | `src/handler.js:2` |
EOF
run_coverage_check "$criteria_task" "$structure_report"
[[ "$(jqf -r '.units[0].self_check_status' "$UNITS")" == red ]] || fail 'a coverage table outside the required section passed'
coverage_output="$(cat "$(jqf -r '.units[0].self_check_output' "$UNITS")")"
grep -Fq 'missing report row for criterion: Create a record' <<<"$coverage_output" || fail 'a missing required coverage section was not identified'

headers_report=impl-71004-coverage-headers.md
cat > "$sup/$headers_report" <<'EOF'
## decision-log
Tried alternate table headers, then used the report contract.

## how
The scheduler checks implementation reports before review.

## why
Commit 97ed8be added report gates for issue #880.

## acceptance-criteria coverage
| Criterion | Call site |
| --- | --- |
| Create a record | `src/handler.js:1` |
| Publish the result | `src/handler.js:2` |
| Reject invalid input | `src/handler.js:1` |
| Preserve the existing result | `src/handler.js:2` |
EOF
run_coverage_check "$criteria_task" "$headers_report"
[[ "$(jqf -r '.units[0].self_check_status' "$UNITS")" == red ]] || fail 'alternate coverage table headers passed'
coverage_output="$(cat "$(jqf -r '.units[0].self_check_output' "$UNITS")")"
grep -Fq 'missing report row for criterion: Create a record' <<<"$coverage_output" || fail 'alternate headers were not rejected'

nonproduction_report=impl-71004-coverage-nonproduction.md
cat > "$sup/$nonproduction_report" <<'EOF'
## decision-log
Tried a test path, then checked the production call site rule.

## how
The scheduler checks implementation reports before review.

## why
Commit 97ed8be added report gates for issue #880.

## acceptance-criteria coverage
| Acceptance criterion | Production call site (file:line) |
| --- | --- |
| Create a record | `tests/handler.js:1` |
| Publish the result | `src/handler.js:2` |
| Reject invalid input | `src/handler.js:1` |
| Preserve the existing result | `src/handler.js:2` |
EOF
run_coverage_check "$criteria_task" "$nonproduction_report"
[[ "$(jqf -r '.units[0].self_check_status' "$UNITS")" == red ]] || fail 'a test file was accepted as a production call site'
coverage_output="$(cat "$(jqf -r '.units[0].self_check_output' "$UNITS")")"
grep -Fq 'not a production source path: tests/handler.js:1' <<<"$coverage_output" || fail 'a non-production citation was not identified'

valid_report=impl-71004-coverage-valid.md
cat > "$sup/$valid_report" <<'EOF'
## decision-log
Tried and verified all four call sites.

## how
The scheduler checks report coverage before it runs the normal self-check.

## why
Commit 97ed8be added the report gate for issue #880.

## acceptance-criteria coverage
| Acceptance criterion | Production call site (file:line) |
| --- | --- |
| Create a record | `src/handler.js:1` |
| Publish the result | `src/handler.js:2` |
| Reject invalid input | `src/handler.js:1` |
| Preserve the existing result | `src/handler.js:2` |
EOF
run_coverage_check "$criteria_task" "$valid_report"
[[ "$(jqf -r '.units[0].self_check_status' "$UNITS")" == pass ]] || fail 'a complete coverage table did not pass'
coverage_output="$(cat "$(jqf -r '.units[0].self_check_output' "$UNITS")")"
grep -Fq 'acceptance-criteria coverage: passed (4 criteria)' <<<"$coverage_output" || fail 'a complete coverage check was not recorded'

write_coverage_unit "$criteria_task" "$coverage_report" true
fallback_unit="$(jqf -c '.units[0]' "$UNITS")"
self_check_before_review issue-71004 "$coverage_sha" "$fixture/repo" "$fallback_unit" || true
wait
self_check_harvest
[[ "$(jqf -r '.units[0].self_check_status' "$UNITS")" == red && "$(jqf -r '.units[0].stage' "$UNITS")" == repair-pending ]] \
  || fail 'a report-only fallback failure did not enter repair'
cp "$sup/$valid_report" "$sup/$coverage_report"
jqf '.units[0].stage="review-pending"' "$UNITS" > "$UNITS.next" && mv "$UNITS.next" "$UNITS"
fallback_unit="$(jqf -c '.units[0]' "$UNITS")"
self_check_before_review issue-71004 "$coverage_sha" "$fixture/repo" "$fallback_unit" || true
wait
self_check_harvest
[[ "$(jqf -r '.units[0].self_check_status' "$UNITS")" == pass ]] || fail 'a report-only fallback repair reused the stale red self-check result'

php_report=impl-71004-coverage-php.md
cat > "$sup/$php_report" <<'EOF'
## decision-log
Tried the source path, then checked the candidate line.

## how
The scheduler checks report coverage before review.

## why
Commit 97ed8be added report gates for issue #880.

## acceptance-criteria coverage
| Acceptance criterion | Production call site (file:line) |
| --- | --- |
| Create a record | `src/handler.php:1` |
| Publish the result | `src/handler.js:2` |
| Reject invalid input | `src/handler.js:1` |
| Preserve the existing result | `src/handler.js:2` |
EOF
run_coverage_check "$criteria_task" "$php_report"
[[ "$(jqf -r '.units[0].self_check_status' "$UNITS")" == pass ]] || fail 'a valid production source extension was rejected'

run_coverage_check 'Task without an acceptance-criteria checklist' "$valid_report"
[[ "$(jqf -r '.units[0].self_check_status' "$UNITS")" == pass ]] || fail 'an issue without parseable criteria did not pass'
coverage_output="$(cat "$(jqf -r '.units[0].self_check_output' "$UNITS")")"
grep -Fq 'acceptance-criteria coverage: skipped' <<<"$coverage_output" || fail 'skipped coverage check was silent'

how_why_bad=impl-71002-how-why-bad.md
printf '## decision-log\nTried the fix and verified the report gate.\n\n## how\nThe scheduler checks implementation reports before review.\n\n## why\nThis rule preserves report quality.\n\n## root-cause\nx\n\n## recurrence-guard\nkind: test\n\n## prior-art\nSource: https://example.invalid/ref\n' > "$sup/$how_why_bad"
[[ "$(run_self_check "$how_why_bad")" == red ]] || fail 'why without a citation was not red before self-fix'
self_fix_dispatch "$(jqf -c '.units[0]' "$UNITS")" || fail 'how/why self-fix did not dispatch'
[[ "$captured" == *'how/why check failed'* && "$captured" == *'## how'* && "$captured" == *'## why'* \
  && "$captured" == *"$sup/$how_why_bad"* ]] || fail 'self-fix prompt lacks how/why requirements or in-place report path'

decision_bad=impl-71002-decision-self-fix.md
printf '## Summary\nImplementation complete.\n\n## how\nThe scheduler checks implementation reports before review.\n\n## why\nCommit 97ed8be added this report gate for issue #880.\n' > "$sup/$decision_bad"
[[ "$(run_self_check "$decision_bad")" == red ]] || fail 'missing decision-log was not red before its self-fix'
self_fix_dispatch "$(jqf -c '.units[0]' "$UNITS")" || fail 'decision-log self-fix did not dispatch'
[[ "$captured" == *'决策日志结构检查'* && "$captured" == *'decision-log check failed'* && "$captured" == *'失败原因'* && "$captured" == *"$sup/$decision_bad"* ]] \
  || fail 'self-fix prompt lacks the decision-log requirements or in-place report path'

echo 'ok - incident report failure is caught in the self-check and repaired by self-fix before review'
