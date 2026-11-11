#!/usr/bin/env bash
# 4741: a failing repair report never replaces the passing implementation report, and an unfixable report gate failure stops after two repeats.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-scheduler-gates-fixture.sh"

fail() { echo "report-gate-repeat.test.sh: $*" >&2; exit 1; }

command git -C "$fixture/repo" init -q -b main
command git -C "$fixture/repo" config user.name t
command git -C "$fixture/repo" config user.email t@example.invalid
command git -C "$fixture/repo" commit --allow-empty -qm base
command git -C "$fixture/repo" update-ref refs/remotes/origin/main HEAD

session_id=11111111-2222-3333-4444-555555555555
head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TAG=20261107T000000Z
RESUME_DISPATCHES=0
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
pick_review_for_unit() { PICK_MODEL=gpt-6-luna; PICK_EFFORT=high; PICK_PROVIDER=codex; PICK_HARD=false; PICK_REASON=configured; PICK_ROUTE_PROVIDER=codex; }
dispatch() { [[ "${1:-}" != repair ]] || RESUME_DISPATCHES=$((RESUME_DISPATCHES + 1)); return 0; }
harvest_pr_implement() { set_unit "$1" '.pr=71003 | .branch="agent/issue-71003" | .stage="review-pending"'; }
session_usage_for_id() { printf '%s\n' '{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"raw":20,"fresh":20}'; }
session_file_for_id() { printf '%s\n' "$fixture/sessions/$session_id.jsonl"; }
session_tokens_for_id() { printf '20\n'; }

write_unit() { # implementation report name
  jqf -cn --arg sid "$session_id" --arg report "$1" \
    '{units:[{id:"issue-71003",issue:71003,lane:"pr",branch:"agent/issue-71003",stage:"implement",labels:["bug"],sessions:{repair:{id:$sid,provider:"codex",model:"gpt-6-luna"}},session_ids:{repair:$sid},implementation_report:$report,history:[]}]}' > "$UNITS"
}
harvest_report() { # new report name
  jqf -cn --arg report "$1" --arg sid "$session_id" --arg dir "$fixture/repo" --arg sha "$head_sha" \
    '{workers:[{pid:999999999,unit:"issue-71003",type:"repair",report:$report,log:"w.log",started:"2026-11-07T00:00:00Z",mode:"fresh",session_id:$sid,sha:$sha,workdir:$dir,provider:"codex",model:"gpt-6-luna",effort:"high",token_usage_start:{input_tokens:0,cached_input_tokens:0,output_tokens:0}}]}' > "$WORKERS"
  : > "$sup/w.log"
  harvest_workers
}

good=impl-71003-good.md
printf '## decision-log\nTried the report gate, kept the passing report, and verified the test.\n\n## root-cause\nx\n\n## recurrence-guard\nkind: test\n\n## prior-art\nSource: https://example.invalid/ref\n\nVERDICT: READY\n' > "$sup/$good"
short=impl-71003-short.md
printf '## decision-log\nTried the short report, kept its available details, and verified the test.\n\n## root-cause\nmerge conflict resolved\n\nVERDICT: READY\n' > "$sup/$short"

# A failing short worker report after a passing implementation report: the unit keeps the passing one and no report resume starts.
write_unit "$good"
harvest_report "$short"
[[ "$(jqf -r '.units[0].implementation_report' "$UNITS")" == "$good" ]] || fail "short report replaced the passing one: $(jqf -r '.units[0].implementation_report' "$UNITS")"
[[ "$RESUME_DISPATCHES" == 0 ]] || fail "kept report still resumed (resumes=$RESUME_DISPATCHES)"
[[ -z "$(incident_report_gate_reason "$(jqf -c '.units[0]' "$UNITS")" "$sup/$good")" ]] || fail 'the kept report no longer passes the gate'
[[ "$(jqf -r '.units[0] | has("report_gate_fail")' "$UNITS")" == false ]] || fail 'a passing report left a gate failure counter'

# No passing report: the first failure resumes once and records the reason, the same reason again escalates instead of dispatching another resume.
write_unit "$short"
harvest_report "$short"
[[ "$(jqf -r '.units[0].report_gate_fail.n' "$UNITS")" == 1 && "$RESUME_DISPATCHES" == 1 ]] || fail "first failure state wrong (resumes=$RESUME_DISPATCHES)"
jqf '.units[0].stage="implement"' "$UNITS" | write_state "$UNITS"
harvest_report "$short"
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == supervisor-review && "$RESUME_DISPATCHES" == 1 ]] \
  || fail "same gate reason twice did not escalate (stage=$(jqf -r '.units[0].stage' "$UNITS") resumes=$RESUME_DISPATCHES)"

# A passing report clears the counter, so a later failure counts from 1 again.
jqf --arg r "$good" '.units[0].implementation_report=$r | .units[0].stage="implement"' "$UNITS" | write_state "$UNITS"
harvest_report "$good"
[[ "$(jqf -r '.units[0] | has("report_gate_fail")' "$UNITS")" == false ]] || fail 'a passing report did not clear the gate failure counter'

echo 'ok - a repeated report gate failure escalates, a passing report clears the count'
