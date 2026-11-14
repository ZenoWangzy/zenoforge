#!/usr/bin/env bash
# row 450: a format-only report gate miss gets one same-session re-ask that names the missing section and the absolute report path; a miss that remains escalates once, with no second re-ask.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-scheduler-gates-fixture.sh"
trap 'rm -rf "$test_env_root"' EXIT

fail() { echo "report-gate-reask.test.sh: $*" >&2; exit 1; }

command git -C "$fixture/repo" init -q -b main
command git -C "$fixture/repo" config user.name t
command git -C "$fixture/repo" config user.email t@example.invalid
command git -C "$fixture/repo" commit --allow-empty -qm base
command git -C "$fixture/repo" update-ref refs/remotes/origin/main HEAD

session_id=11111111-2222-3333-4444-555555555555
head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RESUMES=0; RESUME_PROMPT=""; RESUME_REPORT=""
room_for() { return 0; }
tick_prs_changed() { :; }
tick_prs_prime() { :; }
dispatch_capacity_free() { return 0; }
footprint_waiters_revalidate() { return 0; }
unit_review_target() { printf '%s %s\n' "$head_sha" "$head_sha"; }
verify_handoff_delivery() { return 0; }
ensure_clone() { printf '%s\n' "$fixture/repo"; }
checkout_pr_head() { :; }
subject_of() { printf 'issue %s\n' "$1"; }
cancel_unit_runs() { :; }
pick_review_for_unit() { PICK_MODEL=claude-opus-test; PICK_EFFORT=high; PICK_PROVIDER=claude; PICK_HARD=false; PICK_REASON=configured; PICK_ROUTE_PROVIDER=claude; }
dispatch() { :; }
harvest_pr_implement() { set_unit "$1" '.pr=71004 | .branch="agent/issue-71004" | .stage="review-pending"'; }
session_usage_for_id() { printf '%s\n' '{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"raw":20,"fresh":20}'; }
session_file_for_id() { printf '%s\n' "$fixture/sessions/$session_id.jsonl"; }
claude_session_file_for_id() { printf '%s\n' "$fixture/sessions/$session_id.jsonl"; }
session_tokens_for_id() { printf '20\n'; }
# A re-ask is one dispatch whose log name carries the incident-report marker; record its prompt and output name.
dispatch_if_room() {
  [[ "${4:-}" == *incident-report-* ]] || return 0
  RESUMES=$((RESUMES + 1)); RESUME_REPORT="$5"; RESUME_PROMPT="$8"
}

write_unit() { # implementation report, worker type, label (bug = incident rule, which also needs root-cause and prior-art)
  jqf -cn --arg sid "$session_id" --arg report "$1" --arg type "$2" --arg label "${3:-enhancement}" \
    '{units:[{id:"issue-71004",issue:71004,lane:"pr",branch:"agent/issue-71004",stage:(if $type == "repair" then "repair-pending" else "review-pending" end),labels:[$label],sessions:{repair:{id:$sid,provider:"claude",model:"claude-opus-test"}},session_ids:{repair:$sid},implementation_report:$report,history:[]}]}' > "$UNITS"
}
harvest_worker() { # report, worker type, extra worker fields (json object)
  local extra="${3:-}"; [[ -n "$extra" ]] || extra='{}'
  jqf -cn --arg report "$1" --arg type "$2" --arg sid "$session_id" --arg dir "$fixture/repo" --arg sha "$head_sha" --argjson extra "$extra" \
    '{workers:[({pid:999999999,unit:"issue-71004",type:$type,report:$report,log:"w.log",started:"2026-11-14T00:00:00Z",mode:"fresh",session_id:$sid,sha:$sha,workdir:$dir,provider:"claude",model:"claude-opus-test",effort:"high",no_output_check_after:1,token_usage_start:{input_tokens:0,cached_input_tokens:0,output_tokens:0}} + $extra)]}' > "$WORKERS"
  # A claude worker's final answer is the result line of its stream log: the same text as the report it produced.
  jq -cn --rawfile r "$sup/$1" --arg sid "$session_id" \
    '{type:"result",subtype:"success",is_error:false,session_id:$sid,result:$r,usage:{input_tokens:20,cache_read_input_tokens:0,output_tokens:5}}' > "$sup/w.log"
  harvest_workers
}
stage() { jqf -r '.units[0].stage' "$UNITS"; }

# 6651 shape: a claude implement report with no ## decision-log. The first miss dispatches one same-session re-ask, with the section and the absolute report path in its prompt.
missing=impl-71004-missing.md
printf '## how\nThe scheduler checks implementation reports before review.\n\n## why\nCommit 97ed8be added this report gate for issue #880.\n\n## verification\nRan the focused test.\n\nVERDICT: READY\n' > "$sup/$missing"
write_unit "$missing" implement
harvest_worker "$missing" implement
[[ "$RESUMES" == 1 ]] || fail "first miss did not dispatch one re-ask (resumes=$RESUMES)"
[[ "$RESUME_PROMPT" == *'## decision-log'* ]] || fail 'the re-ask prompt did not name ## decision-log'
[[ "$RESUME_PROMPT" == *"$sup/incident-report-issue-71004-"* ]] || fail 'the re-ask prompt did not name the absolute report path'
[[ "$(stage)" != supervisor-review ]] || fail 'a format-only miss escalated on its first failure'

# The re-ask saves its complete report at that path; the next harvest adopts it, and the gate passes.
reask="$RESUME_REPORT"
printf '## decision-log\nTried the report gate, kept the passing report, and verified the test.\n\n## how\nThe scheduler checks implementation reports before review.\n\n## why\nCommit 97ed8be added this report gate for issue #880.\n\n## verification\nRan the focused test.\n\nVERDICT: READY\n' > "$sup/$reask"
harvest_worker "$reask" implement '{"incident_report_resume":true,"incident_report_resume_source_report":"'"$missing"'","incident_report_resume_source_type":"implement","incident_report_resume_pending_stage":"review-pending"}'
[[ "$(jqf -r '.units[0].implementation_report' "$UNITS")" == "$reask" ]] || fail "re-ask report was not adopted (report=$(jqf -r '.units[0].implementation_report' "$UNITS"))"
[[ "$(jqf -r '.units[0] | has("report_gate_fail")' "$UNITS")" == false ]] || fail 'a passing re-ask left a gate failure counter'
[[ "$RESUMES" == 1 ]] || fail "adopting a passing re-ask dispatched another re-ask (resumes=$RESUMES)"

# 6597 shape: a repair whose report misses the recurrence-guard kind. Its re-ask is also one dispatch, and it edits the unit's implementation_report path.
guard_missing=impl-71004-guard.md
printf '## how\nThe scheduler checks implementation reports before review.\n\n## why\nCommit 97ed8be added this report gate for issue #880.\n\n## decision-log\nTried it and verified it.\n\n## root-cause\nmerge conflict resolved\n\n## recurrence-guard\nThe guard is planted in the test.\n\n## prior-art\nSource: https://example.invalid/ref\n\nVERDICT: READY\n' > "$sup/$guard_missing"
RESUMES=0
write_unit "$guard_missing" repair bug
harvest_worker "$guard_missing" repair
[[ "$RESUMES" == 1 ]] || fail "repair miss did not dispatch one re-ask (resumes=$RESUMES)"
[[ "$RESUME_PROMPT" == *'kind:'* && "$RESUME_PROMPT" == *"$sup/incident-report-issue-71004-"* ]] \
  || fail 'the repair re-ask prompt did not name the kind line and the absolute report path'

# Still missing after the one re-ask: the failure count survives the re-ask, and the next same-reason miss escalates exactly once with no second re-ask.
RESUMES=0
write_unit "$missing" implement
harvest_worker "$missing" implement
[[ "$RESUMES" == 1 ]] || fail "fresh first miss did not dispatch one re-ask (resumes=$RESUMES)"
still="$RESUME_REPORT"
printf '## how\nstill missing the section\n\n## why\nCommit 97ed8be.\n\nVERDICT: READY\n' > "$sup/$still"
harvest_worker "$still" implement '{"incident_report_resume":true,"incident_report_resume_source_report":"'"$missing"'","incident_report_resume_source_type":"implement","incident_report_resume_pending_stage":"review-pending"}'
[[ "$RESUMES" == 1 ]] || fail "a re-ask that still misses dispatched another re-ask (resumes=$RESUMES)"
[[ "$(jqf -r '.units[0].report_gate_fail.n' "$UNITS")" == 1 ]] || fail 'the remaining miss dropped the first failure count'
harvest_worker "$missing" repair
[[ "$(stage)" == supervisor-review ]] || fail "a miss that remained after the re-ask did not escalate (stage=$(stage))"
[[ "$RESUMES" == 1 ]] || fail "escalation dispatched a re-ask (resumes=$RESUMES)"

echo 'ok - a format-only report miss gets one same-session re-ask naming the section and absolute path, and a remaining miss escalates once'
