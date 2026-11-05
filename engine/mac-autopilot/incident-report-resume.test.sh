#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-scheduler-gates-fixture.sh"

fail() { echo "incident-report-resume.test.sh: $*" >&2; exit 1; }

command git -C "$fixture/repo" init -q -b main
command git -C "$fixture/repo" config user.name t
command git -C "$fixture/repo" config user.email t@example.invalid
command git -C "$fixture/repo" commit --allow-empty -qm base
command git -C "$fixture/repo" update-ref refs/remotes/origin/main HEAD

session_id=11111111-2222-3333-4444-555555555555
head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TAG=20261105T000000Z
RESUME_DISPATCHES=0
REVIEW_DISPATCHES=0
LAST_CONTEXT=''
LAST_PROMPT=''

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
review_prompt() { printf 'review prompt\n'; }
pick_review_for_unit() { PICK_MODEL=gpt-6-luna; PICK_EFFORT=high; PICK_PROVIDER=codex; PICK_HARD=false; PICK_REASON=configured; PICK_ROUTE_PROVIDER=codex; }

dispatch() {
  local type="${1:-}" context="${15:-}"
  if [[ "$type" == repair ]]; then
    RESUME_DISPATCHES=$((RESUME_DISPATCHES + 1))
    [[ "$(jqf -r '.incident_report_resume // false' <<<"$context")" == true ]] \
      || fail 'report-only continuation did not use the existing repair dispatch path'
    LAST_CONTEXT="$context"
    LAST_PROMPT="${7}"
  elif [[ "$type" == review || "$type" == rereview ]]; then
    REVIEW_DISPATCHES=$((REVIEW_DISPATCHES + 1))
  fi
  return 0
}

harvest_pr_implement() {
  set_unit "$1" '.pr=71001 | .branch="agent/issue-71001" | .stage="review-pending"'
}
session_usage_for_id() { printf '%s\n' '{"input_tokens":20,"cached_input_tokens":0,"output_tokens":0,"raw":20,"fresh":20}'; }
session_file_for_id() { printf '%s\n' "$fixture/sessions/$session_id.jsonl"; }
session_tokens_for_id() { printf '20\n'; }

write_unit() {
  jqf -cn --arg sid "$session_id" --arg model gpt-6-luna --arg sha "$head_sha" --arg report "$1" \
    '{units:[{id:"issue-71001",issue:71001,lane:"pr",branch:"agent/issue-71001",stage:"implement",labels:["bug"],sessions:{repair:{id:$sid,provider:"codex",model:$model}},session_ids:{repair:$sid},implementation_report:$report,history:[]}]}' > "$UNITS"
}

write_worker() { # type report log context-json
  local type="$1" report="$2" log="$3" context="${4:-}"
  [[ -n "$context" ]] || context='{}'
  jqf -cn --arg type "$type" --arg report "$report" --arg log "$log" --arg sid "$session_id" \
    --arg model gpt-6-luna --arg dir "$fixture/repo" --arg sha "$head_sha" --argjson context "$context" \
    '{workers:[({pid:999999999,unit:"issue-71001",type:$type,report:$report,log:$log,started:"2026-11-05T00:00:00Z",mode:"fresh",session_id:$sid,sha:$sha,workdir:$dir,provider:"codex",model:$model,effort:"high",token_usage_start:{input_tokens:20,cached_input_tokens:0,output_tokens:0}} + $context)]}' > "$WORKERS"
  : > "$sup/$log"
}

missing_report_name=impl-71001-fix-source.md
missing_report="$sup/$missing_report_name"
cat > "$missing_report" <<'REPORT'
## root-cause
The persisted state was selected incorrectly.

## recurrence-guard
kind: test

VERDICT: READY
REPORT
write_unit "$missing_report_name"
write_worker implement "$missing_report_name" impl-71001-fix-source.worker.log
harvest_workers
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == repair && "$RESUME_DISPATCHES" == 1 && "$REVIEW_DISPATCHES" == 0 ]] \
  || fail "missing prior-art did not go to one session resume before review (stage=$(jqf -r '.units[0].stage' "$UNITS") resumes=$RESUME_DISPATCHES reviews=$REVIEW_DISPATCHES)"
jqf -e '.incident_report_resume == true and .incident_report_resume_session_id == "11111111-2222-3333-4444-555555555555" and .incident_report_resume_source_report == "impl-71001-fix-source.md"' \
  <<<"$LAST_CONTEXT" >/dev/null || fail 'resume context did not retain the source report and exact session id'
[[ "$LAST_PROMPT" == *'missing ## prior-art'* && "$LAST_PROMPT" == *'Existing report:'* ]] \
  || fail 'resume prompt did not name the structural failure and include the existing report'

# The resumed command is the same session and has a read-only sandbox, so it
# cannot write code while returning the completed report in its final message.
mkdir -p "$fixture/sessions"
touch "$(session_file_for_id "$session_id")"
CODEX_ENV_ARGS=()
build_codex_command repair gpt-6-luna high issue-71001 'report-only prompt' '' "$fixture/repo" codex true "$session_id" \
  || fail 'report-only command was not resumable from the recorded session'
[[ "$CODEX_MODE" == resume && " ${CODEX_COMMAND[*]} " == *" -s read-only resume $session_id "* ]] \
  || fail "report-only command did not resume the exact session in read-only mode (mode=$CODEX_MODE command=${CODEX_COMMAND[*]})"
if build_codex_command repair gpt-6-luna high issue-71001 'report-only prompt' '' "$fixture/repo" codex true aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee; then
  fail 'report-only command accepted a different session id'
fi

passing_report_name=impl-71001-fix-passing.md
passing_report="$sup/$passing_report_name"
cat > "$passing_report" <<'REPORT'
## root-cause
The persisted state was selected incorrectly.

## recurrence-guard
kind: test

## prior-art
Source: https://example.invalid/incident-reference

VERDICT: READY
REPORT
write_unit "$passing_report_name"
write_worker implement "$passing_report_name" impl-71001-fix-passing.worker.log
harvest_workers
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == review-pending && "$RESUME_DISPATCHES" == 1 ]] \
  || fail "passing report did not go straight to the normal review queue (stage=$(jqf -r '.units[0].stage' "$UNITS") resumes=$RESUME_DISPATCHES)"
dispatch_pending
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == review && "$REVIEW_DISPATCHES" == 1 ]] \
  || fail "passing report did not dispatch review (stage=$(jqf -r '.units[0].stage' "$UNITS") reviews=$REVIEW_DISPATCHES)"

# A report-only worker is already the single continuation for its source run.
resumed_report_name=incident-report-issue-71001-T1.md
resumed_report="$sup/$resumed_report_name"
cp "$missing_report" "$resumed_report"
write_unit "$missing_report_name"
jqf '.units[0].pr=71001 | .units[0].stage="repair"' "$UNITS" | write_state "$UNITS"
write_worker repair "$resumed_report_name" incident-report-issue-71001-T1.worker.log \
  "$(jqf -cn --arg source "$missing_report_name" '{incident_report_resume:true,incident_report_resume_source_type:"implement",incident_report_resume_source_report:$source,incident_report_resume_pending_stage:"review-pending",incident_report_resume_session_id:"11111111-2222-3333-4444-555555555555"}')"
harvest_workers
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == review-pending \
  && "$(jqf -r '.units[0].implementation_report' "$UNITS")" == "$missing_report_name" \
  && "$RESUME_DISPATCHES" == 1 ]] \
  || fail "second report failure resumed again or skipped the normal review stage (stage=$(jqf -r '.units[0].stage' "$UNITS") resumes=$RESUME_DISPATCHES)"
dispatch_pending
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == review && "$REVIEW_DISPATCHES" == 2 ]] \
  || fail "failed continuation did not fall through to review (stage=$(jqf -r '.units[0].stage' "$UNITS") reviews=$REVIEW_DISPATCHES)"

# A continuation that exits without a final message also returns to review
# instead of leaving the unit in repair or consuming a normal no-output retry.
empty_report_name=incident-report-issue-71001-empty-T2.md
rm -f "$sup/$empty_report_name"
write_unit "$missing_report_name"
jqf '.units[0].pr=71001 | .units[0].stage="repair"' "$UNITS" | write_state "$UNITS"
write_worker repair "$empty_report_name" incident-report-issue-71001-empty-T2.worker.log \
  "$(jqf -cn --arg source "$missing_report_name" '{incident_report_resume:true,incident_report_resume_source_type:"implement",incident_report_resume_source_report:$source,incident_report_resume_pending_stage:"review-pending",incident_report_resume_session_id:"11111111-2222-3333-4444-555555555555"}')"
harvest_workers
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == review-pending \
  && "$(jqf -r '.units[0].implementation_report' "$UNITS")" == "$missing_report_name" \
  && "$(jqf -r '[.units[0].history[]? | select(.stage=="worker-no-output")] | length' "$UNITS")" == 0 \
  && "$RESUME_DISPATCHES" == 1 ]] \
  || fail "empty continuation did not restore the original report for review (stage=$(jqf -r '.units[0].stage' "$UNITS") resumes=$RESUME_DISPATCHES)"
dispatch_pending
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == review && "$REVIEW_DISPATCHES" == 3 ]] \
  || fail "empty continuation did not fall through to review (stage=$(jqf -r '.units[0].stage' "$UNITS") reviews=$REVIEW_DISPATCHES)"

echo 'ok - incident report failures get at most one read-only same-session resume before review'
