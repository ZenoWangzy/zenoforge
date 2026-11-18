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
## decision-log
Tried the incident report, retained the root-cause summary, and verified the resume path.

## how
The scheduler checks implementation reports before review.

## why
Commit 97ed8be added this report gate for issue #880.

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
[[ "$LAST_PROMPT" == *'## how'* && "$LAST_PROMPT" == *'## why'* ]] \
  || fail 'resume prompt did not remind the continuation to include how and why'

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
## decision-log
Tried the incident report, retained the recurrence guard, and verified the final report.

## how
The scheduler checks implementation reports before review.

## why
Commit 97ed8be added this report gate for issue #880.

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

# A repair worker edits the original report in place and writes nothing at its own path: the gate reads the edited report, and the final message is saved as the repair note.
note_name=impl-71001-fix-note.md
rm -f "$sup/$note_name"
write_unit "$passing_report_name"
jqf --arg note "$note_name" '.units[0].pr=71001 | .units[0].stage="repair" | .units[0].repair_note_report=$note' "$UNITS" | write_state "$UNITS"
write_worker repair "$note_name" impl-71001-fix-note.worker.log
printf 'tokens used\n1,020\nFixed in place; the incident sections are in the original report.\n' > "$sup/impl-71001-fix-note.worker.log"
before_resumes=$RESUME_DISPATCHES
harvest_workers || : # verdict_of fails on a fix note with no verdict line
[[ "$RESUME_DISPATCHES" == "$before_resumes" && "$(jqf -r '.units[0].implementation_report' "$UNITS")" == "$passing_report_name" ]] \
  || fail "a repair that edited the original report was gated on its fix note (resumes=$RESUME_DISPATCHES report=$(jqf -r '.units[0].implementation_report' "$UNITS"))"
grep -q '^Fixed in place' "$sup/$note_name" && [[ "$(jqf -r '.units[0].repair_note_report' "$UNITS")" == "$note_name" ]] \
  || fail 'the worker final message was not saved at repair_note_report'
grep -q '^## prior-art' "$sup/$passing_report_name" || fail 'the recovered final message replaced the edited report'

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

# A repair round that ends with a failing report gets the same continuation. The repair-only admissions (round cap, Dagger runtime)
# do not apply to a read-only continuation, and a repair that pushed nothing (repair-pending) or sits at the breaker line is still in this round.
pr_view() { printf '%s\n' "$head_sha"; } # the PR head did not move
supervisor_inbox_append_once() { :; }
repair_cap_admission() { return 1; }
repair_runtime_admission() { return 1; }
repair_note=impl-71001-fix-round.md
write_repair_round() { # prior repair-no-push runs on this head
  local prior="$1" i history='[{"stage":"write-start","work_type":"repair","pr_head":"'"$head_sha"'"}]'
  for ((i = 0; i < prior; i++)); do
    history="$(jqf -c --arg r "head $head_sha unchanged after repair" '. + [{stage:"repair-no-push",result:$r}]' <<<"$history")"
  done
  write_unit "$missing_report_name"
  jqf --argjson h "$history" '.units[0].pr=71001 | .units[0].stage="repair" | .units[0].history=$h' "$UNITS" | write_state "$UNITS"
  printf 'See report impl-71001-fix-source.md for the details.\n\nVERDICT: READY\n' > "$sup/$repair_note"
  write_worker repair "$repair_note" impl-71001-fix-round.worker.log
}
before_resumes=$RESUME_DISPATCHES
write_repair_round 0 # first no-push: stage repair-pending
harvest_workers
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == repair && "$RESUME_DISPATCHES" == $((before_resumes + 1)) ]] \
  || fail "a repair that pushed nothing, with the cap and runtime gates closed, did not get the report continuation (stage=$(jqf -r '.units[0].stage' "$UNITS") resumes=$RESUME_DISPATCHES)"
jqf -e '.incident_report_resume_source_type == "repair" and .incident_report_resume_pending_stage == "repair-pending"' <<<"$LAST_CONTEXT" >/dev/null \
  || fail 'the repair continuation did not record its source type and pending stage'

before_resumes=$RESUME_DISPATCHES
write_repair_round 1 # second no-push on the head: the breaker line
harvest_workers
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == repair && "$RESUME_DISPATCHES" == $((before_resumes + 1)) ]] \
  || fail "the breaker parked the unit instead of letting the continuation finish the round (stage=$(jqf -r '.units[0].stage' "$UNITS") resumes=$RESUME_DISPATCHES)"
[[ "$(jqf -r '[.units[0].history[] | select(.stage=="repair-breaker")] | length' "$UNITS")" == 0 ]] || fail 'the breaker fired while a continuation was running'

# A repair that wrote the missing sections into its own fix note (the 6597 shape) is adopted as the implementation report: the merged report keeps the fix note first and the unit report in full, with no continuation or escalation.
adopted_fix_name=impl-71001-fix-round1.md
cat > "$sup/$adopted_fix_name" <<'REPORT'
## decision-log
Tried the repair in the fix note and verified the recurrence guard and prior-art sections.

## how
The scheduler adopts a repair report that passes the gate.

## why
Commit 97ed8be added this report gate for issue #880.

## root-cause
The persisted state was selected incorrectly.

## recurrence-guard
kind: test

## prior-art
Source: https://example.invalid/incident-reference

VERDICT: READY
REPORT
# The unit report fails (no prior-art) and holds text the review needs; the adopted report must keep it.
orig_report_name=impl-71001-orig-done.md
cat > "$sup/$orig_report_name" <<'REPORT'
## decision-log
Original attempt, kept for review.

## how
The unit report before the repair.

## why
Commit 97ed8be added this report gate for issue #880.

## root-cause
The original root-cause text that review reads.

## recurrence-guard
kind: test

Done: unique-6597-done-line verified against the fixture.

VERDICT: READY
REPORT
adopted_report_name=impl-71001-orig-done-adopted-impl-71001-fix-round1.md
write_unit "$orig_report_name"
jqf '.units[0].pr=71001 | .units[0].stage="repair"' "$UNITS" | write_state "$UNITS"
write_worker repair "$adopted_fix_name" impl-71001-fix-round1.worker.log
printf 'tokens used\n1,020\nFixed the sections in the fix note.\n' > "$sup/impl-71001-fix-round1.worker.log"
before_resumes=$RESUME_DISPATCHES
harvest_workers || :
[[ "$RESUME_DISPATCHES" == "$before_resumes" && "$(jqf -r '.units[0].implementation_report' "$UNITS")" == "$adopted_report_name" ]] \
  || fail "a repair that fixed the sections in its fix note was not adopted as a merged report (resumes=$RESUME_DISPATCHES report=$(jqf -r '.units[0].implementation_report' "$UNITS"))"
grep -Fq "report adopted unit=issue-71001 from=$adopted_fix_name" "$LOG" \
  || fail 'adopting a repair report did not log its source report'
[[ "$(jqf -r '.units[0] | has("report_gate_fail")' "$UNITS")" == false ]] || fail 'an adopted repair report left a gate failure counter'
[[ "$(jqf -r '[.units[0].history[] | select(.stage=="supervisor-escalated")] | length' "$UNITS")" == 0 ]] || fail 'a repair whose fix note passed the report gate was escalated'
grep -q '^Done: unique-6597-done-line' "$sup/$adopted_report_name" && grep -q '^## prior-art' "$sup/$adopted_report_name" \
  && grep -q '^## root-cause' "$sup/$adopted_report_name" \
  || fail 'the adopted report lost the unit report text or lacks the fix note sections'
grep -q '^Done: unique-6597-done-line' "$sup/$orig_report_name" || fail 'the unit report itself was overwritten'
[[ "$(jqf -r '.units[0].implementation_report' "$UNITS")" != "$orig_report_name" ]] || fail 'the adopted report did not replace the unit report pointer'

# A second repair can adopt a previously adopted report; it must keep only the original unit section and one adopted-name segment.
adopted_round2_fix_name=impl-71001-fix-round2.md
cp "$sup/$adopted_fix_name" "$sup/$adopted_round2_fix_name"
adopted_round2_report_name=impl-71001-orig-done-adopted-impl-71001-fix-round2.md
awk '
  !removed && /^## prior-art[[:space:]]*$/ { skipping=1; removed=1; next }
  skipping && /^VERDICT:/ { skipping=0 }
  !skipping { print }
' "$sup/$adopted_report_name" > "$sup/$adopted_report_name.new"
mv -f -- "$sup/$adopted_report_name.new" "$sup/$adopted_report_name"
write_unit "$adopted_report_name"
jqf '.units[0].pr=71001 | .units[0].stage="repair"' "$UNITS" | write_state "$UNITS"
write_worker repair "$adopted_round2_fix_name" impl-71001-fix-round2.worker.log
printf 'tokens used\n1,020\nFixed the sections in the second repair note.\n' > "$sup/impl-71001-fix-round2.worker.log"
before_resumes=$RESUME_DISPATCHES
harvest_workers || :
[[ "$RESUME_DISPATCHES" == "$before_resumes" && "$(jqf -r '.units[0].implementation_report' "$UNITS")" == "$adopted_round2_report_name" ]] \
  || fail "a second repair did not re-adopt the merged report under its original base name (report=$(jqf -r '.units[0].implementation_report' "$UNITS"))"
[[ "$(grep -oF -- '-adopted-' <<<"$adopted_round2_report_name" | wc -l | tr -d '[:space:]')" == 1 ]] \
  || fail 'a second adoption nested another -adopted- name segment'
[[ "$(grep -c '^Done: unique-6597-done-line' "$sup/$adopted_round2_report_name")" == 1 ]] \
  || fail 'a second adoption did not keep exactly one copy of the original unit report'

# A repair with no fix-note file cannot be adopted and leaves the original report selected.
missing_fix_name=impl-71001-fix-missing.md
rm -f -- "$sup/$missing_fix_name"
write_unit "$orig_report_name"
jqf '.units[0].pr=71001 | .units[0].stage="repair"' "$UNITS" | write_state "$UNITS"
write_worker repair "$missing_fix_name" impl-71001-fix-missing.worker.log
printf 'tokens used\n1,020\nThe fix note was not written.\n' > "$sup/impl-71001-fix-missing.worker.log"
harvest_workers || :
[[ "$(jqf -r '.units[0].implementation_report' "$UNITS")" == "$orig_report_name" ]] \
  || fail 'a repair without a fix-note file changed the original report path'
! grep -Fq "report adopted unit=issue-71001 from=$missing_fix_name" "$LOG" \
  || fail 'a repair without a fix-note file was logged as adopted'

# The report checked for adoption must be the exact path copied into the merged report.
checked_note_name=impl-71001-external-fix.md
checked_note_path="$fixture/$checked_note_name"
cp "$sup/$adopted_fix_name" "$checked_note_path"
printf 'wrong supervisor copy\n' > "$sup/$checked_note_name"
write_unit "$orig_report_name"
checked_unit_json="$(jqf -c '.units[0]' "$UNITS")"
checked_merged_name="$(incident_report_harvest_target issue-71001 repair "$checked_unit_json" "$checked_note_name" "$checked_note_path")"
[[ "$checked_merged_name" == impl-71001-orig-done-adopted-impl-71001-external-fix.md ]] \
  || fail "the checked repair note was not adopted from its resolved path (report=$checked_merged_name)"
grep -q '^Tried the repair in the fix note and verified the recurrence guard' "$sup/$checked_merged_name" \
  && ! grep -q '^wrong supervisor copy$' "$sup/$checked_merged_name" \
  || fail 'the adopted report did not copy the exact fix-note path that passed the gate'

# A repair whose fix note has no gated sections still fails the gate on the unit's report, as before.
nothing_fix_name=impl-71001-fix-nothing.md
printf 'Fixed nothing; see the summary.\n' > "$sup/$nothing_fix_name"
write_unit "$missing_report_name"
jqf '.units[0].pr=71001 | .units[0].stage="repair"' "$UNITS" | write_state "$UNITS"
write_worker repair "$nothing_fix_name" impl-71001-fix-nothing.worker.log
printf 'tokens used\n1,020\nNo change.\n' > "$sup/impl-71001-fix-nothing.worker.log"
before_resumes=$RESUME_DISPATCHES
harvest_workers || :
[[ "$RESUME_DISPATCHES" == $((before_resumes + 1)) && "$(jqf -r '.units[0].implementation_report' "$UNITS")" == "$missing_report_name" ]] \
  || fail "a repair that fixed nothing was not still gated on the unit report (resumes=$RESUME_DISPATCHES report=$(jqf -r '.units[0].implementation_report' "$UNITS"))"

how_why_report_name=impl-71001-how-why.md
cat > "$sup/$how_why_report_name" <<'REPORT'
## decision-log
Tried the report path and verified the required sections.

## how
The scheduler checks implementation reports before review.

## why
The report gate preserves the expected structure.

## root-cause
The report did not cite its design history.

## recurrence-guard
kind: test

## prior-art
Source: https://example.invalid/report-gate

VERDICT: READY
REPORT
before_resumes=$RESUME_DISPATCHES
write_unit "$how_why_report_name"
write_worker implement "$how_why_report_name" impl-71001-how-why.worker.log
harvest_workers
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == repair && "$RESUME_DISPATCHES" == $((before_resumes + 1)) \
  && "$LAST_PROMPT" == *'## why lacks a commit SHA'* ]] \
  || fail 'a missing how/why citation did not enter the existing one-session report continuation'

# A fresh worker's row has no session id (dispatch records only a resumed one); harvest knows the id from the run's log. The continuation must still start from that session.
fresh_source_name=impl-71001-fresh-source.md
cat > "$sup/$fresh_source_name" <<'REPORT'
## how
The scheduler checks implementation reports before review.

## why
Commit 97ed8be added this report gate for issue #880.

## root-cause
The persisted state was selected incorrectly.

## recurrence-guard
kind: test

## prior-art
Source: https://example.invalid/incident-reference

VERDICT: READY
REPORT
write_unit "$fresh_source_name"
jqf '.units[0].pr=71001 | .units[0].stage="implement"' "$UNITS" | write_state "$UNITS"
write_worker implement "$fresh_source_name" impl-71001-fresh-source.worker.log
jqf '.workers[0].session_id=""' "$WORKERS" | write_state "$WORKERS"
printf 'session id: %s\n' "$session_id" > "$sup/impl-71001-fresh-source.worker.log"
before_resumes=$RESUME_DISPATCHES
harvest_workers
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == repair && "$RESUME_DISPATCHES" == $((before_resumes + 1)) ]] \
  || fail "a fresh implement worker with a missing decision-log did not get a session continuation before review (stage=$(jqf -r '.units[0].stage' "$UNITS") resumes=$RESUME_DISPATCHES)"
jqf -e --arg sid "$session_id" '.incident_report_resume == true and .incident_report_resume_session_id == $sid and .incident_report_resume_source_report == "impl-71001-fresh-source.md"' \
  <<<"$LAST_CONTEXT" >/dev/null || fail 'fresh continuation did not carry the session id and source report'

# The continuation writes the missing section into its own report: the gate passes and the unit reaches review with that report.
fixed_resume_name=incident-report-issue-71001-fresh-T5.md
{ printf '## decision-log\nTried the continuation, checked the gate, and verified the report.\n\n'; cat "$sup/$fresh_source_name"; } > "$sup/$fixed_resume_name"
write_worker repair "$fixed_resume_name" incident-report-issue-71001-fresh-T5.worker.log \
  "$(jqf -cn --arg source "$fresh_source_name" --arg sid "$session_id" '{incident_report_resume:true,incident_report_resume_source_type:"implement",incident_report_resume_source_report:$source,incident_report_resume_pending_stage:"review-pending",incident_report_resume_session_id:$sid}')"
harvest_workers
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == review-pending && "$(jqf -r '.units[0].implementation_report' "$UNITS")" == "$fixed_resume_name" ]] \
  || fail "a continuation that wrote the missing section did not reach review with its report (stage=$(jqf -r '.units[0].stage' "$UNITS") report=$(jqf -r '.units[0].implementation_report' "$UNITS"))"

# The same reason again, from a repair that really fails, still escalates to the supervisor.
write_unit "$fresh_source_name"
jqf '.units[0].pr=71001 | .units[0].stage="repair" | .units[0].report_gate_fail={reason:"missing ## decision-log",n:1}' "$UNITS" | write_state "$UNITS"
repair_fail_name=impl-71001-fresh-repair.md
printf 'Fix note that does not repeat the section.\n\nVERDICT: READY\n' > "$sup/$repair_fail_name"
write_worker repair "$repair_fail_name" impl-71001-fresh-repair.worker.log
harvest_workers || :
[[ "$(jqf -r '.units[0].stage' "$UNITS")" == supervisor-review ]] \
  || fail "the same gate reason twice did not escalate to the supervisor (stage=$(jqf -r '.units[0].stage' "$UNITS"))"

# A Claude implement run is continued read-only too: it resumes only the expected session, with read tools only.
claude_session_file_for_id() { printf '%s\n' "$fixture/claude/$1.jsonl"; }
mkdir -p "$fixture/claude" && touch "$fixture/claude/$session_id.jsonl"
write_unit "$fresh_source_name"
jqf --arg sid "$session_id" '.units[0].sessions.repair={id:$sid,provider:"claude",model:"claude-haiku-5-5"}' "$UNITS" | write_state "$UNITS"
CODEX_ENV_ARGS=()
build_codex_command repair claude-haiku-5-5 high issue-71001 'report-only prompt' '' "$fixture/repo" claude true "$session_id" \
  || fail 'read-only Claude continuation was not resumable from the recorded session'
[[ "$CODEX_MODE" == resume && " ${CODEX_COMMAND[*]} " == *" --resume $session_id "* && " ${CODEX_COMMAND[*]} " == *" --tools Read,Grep,Glob "* ]] \
  || fail "read-only Claude continuation did not resume with read tools only (mode=$CODEX_MODE command=${CODEX_COMMAND[*]})"
if build_codex_command repair claude-haiku-5-5 high issue-71001 'report-only prompt' '' "$fixture/repo" claude true aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee; then
  fail 'read-only Claude continuation accepted a different session id'
fi

echo 'ok - incident report failures get at most one read-only same-session resume before review'
