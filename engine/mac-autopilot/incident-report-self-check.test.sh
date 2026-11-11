#!/usr/bin/env bash
# The incident report structure check runs in the pre-review self-check, so a failing report is repaired by self-fix before any review.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-scheduler-gates-fixture.sh"

fail() { echo "incident-report-self-check.test.sh: $*" >&2; exit 1; }

# The gates fixture stubs the self-check; restore the real one.
source "$script_dir/scheduler.d/self-check.sh"
sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
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
[[ "$(run_self_check "$bad")" == red ]] || fail 'second failing run was not red'
command git -C "$fixture/repo" init -q -b main 2>/dev/null || true
command git -C "$fixture/repo" config user.name t; command git -C "$fixture/repo" config user.email t@example.invalid
command git -C "$fixture/repo" commit --allow-empty -qm base 2>/dev/null || true
command git -C "$fixture/repo" branch -f agent/issue-71002 HEAD
self_fix_dispatch "$(jqf -c '.units[0]' "$UNITS")" || fail 'self-fix did not dispatch'
[[ "$captured" == *'事故报告结构检查'* && "$captured" == *'incident report check failed'* ]] || fail 'self-fix prompt lacks the incident report instruction'
[[ "$captured" == *"$sup/$bad"* ]] || fail 'self-fix prompt does not name the report to edit in place'

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
