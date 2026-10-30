#!/usr/bin/env bash
# Scheduler -> fake Codex: repair prompt, explicit session selection and cold fallback.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/mac-autopilot/test-env.sh"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/resume"
mkdir -p "$fixture/sup/autopi" "$fixture/sessions/2026/10/24" "$fixture/repo"
git init -q -b fixture "$fixture/repo"
git -C "$fixture/repo" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m base
git -C "$fixture/repo" update-ref refs/remotes/origin/main HEAD
cp "$script_dir/mac-autopilot/config.template.json" "$fixture/sup/autopi/config.json"
printf '{"units":[]}' > "$fixture/sup/autopi/units.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/sup"
export CODEX_SESSIONS_DIR="$fixture/sessions" AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
fail() { echo "repair-resume: $*" >&2; exit 1; }
sid=11111111-2222-3333-4444-555555555555
new_sid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
export CALLS="$fixture/calls" NEW_SID="$new_sid" FAKE_MODE=ok
cat > "$test_env_bin/codex" <<'SH'
#!/usr/bin/env bash
python3 - "$@" <<'PY'
import json, os, sys
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\n')
PY
if [[ "$FAKE_MODE" == empty ]]; then
  printf '{"type":"thread.started","thread_id":"%s"}\n' "$NEW_SID"; exit 1
fi
if [[ " $* " == *' resume '* ]]; then
  case "$FAKE_MODE" in
    startup) echo '{"type":"thread.started","thread_id":"11111111-2222-3333-4444-555555555555"}'; echo '{"type":"turn.started"}'; exit 2 ;;
    worked) echo '{"type":"item.started","item":{"type":"command_execution"}}'; exit 3 ;;
  esac
fi
printf '{"type":"thread.started","thread_id":"%s"}\n' "$NEW_SID"
echo '{"type":"turn.started"}'
echo '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":2}}'
echo '{"type":"item.completed","item":{"type":"agent_message","text":"repair done"}}'
SH
chmod +x "$test_env_bin/codex"
counters() { # input cached output -> one cumulative Codex token_count line
  printf '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s,"cached_input_tokens":%s,"output_tokens":%s}}}}\n' "$1" "$2" "$3"
}
seed() {
  jq -n --arg sid "$sid" '{units:[{id:"u",stage:"repair-pending",lane:"pr",history:[],
    session_ids:{repair:$sid,review:"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"},
    sessions:{repair:{id:$sid,provider:"codex",model:"model"}}}]}' > "$UNITS"
  echo '{"workers":[]}' > "$WORKERS"
  counters 1000 0 100 > "$fixture/sessions/2026/10/24/rollout-$sid.jsonl"
  : > "$CALLS"
}
seed
dispatch repair model max u run.log run.md 'FULL ORIGINAL BRIEF' '' "$fixture/repo" '' 'NEW REVIEW FAILURE'
wait "$!"
python3 - "$CALLS" "$sid" <<'PY'
import json, sys
calls=[json.loads(s) for s in open(sys.argv[1])]
assert len(calls)==1, calls
assert 'resume' in calls[0] and sys.argv[2] in calls[0], calls
assert calls[0][-1]=='NEW REVIEW FAILURE', calls
assert '--last' not in calls[0] and '--ephemeral' not in calls[0], calls
PY
echo 'PASS repair resumes with only new failure'

assert_call() { # expected mode, prompt, optional session id
  python3 - "$CALLS" "$1" "$2" "${3:-}" <<'PY'
import json, sys
calls=[json.loads(s) for s in open(sys.argv[1])]
assert len(calls)==1, calls
assert ('resume' in calls[0]) == (sys.argv[2]=='resume'), calls
assert calls[0][-1]==sys.argv[3] or (sys.argv[2]=='fresh' and calls[0][-1].startswith(sys.argv[3])), calls
if sys.argv[4]: assert sys.argv[4] in calls[0], calls
assert '--last' not in calls[0] and '--ephemeral' not in calls[0], calls
PY
}
run_repair() {
  dispatch repair model max u run.log run.md 'FULL ORIGINAL BRIEF' '' "$fixture/repo" '' 'NEW REVIEW FAILURE'
  wait "$!"
}
for reason in no-recorded-session provider-changed model-changed session-files-missing; do
  seed
  case "$reason" in
    no-recorded-session) set_unit u '.sessions={}' ;;
    provider-changed) set_unit u '.sessions.repair.provider="claude"' ;;
    model-changed) set_unit u '.sessions.repair.model="other-model"' ;;
    session-files-missing) rm "$fixture/sessions/2026/10/24/rollout-$sid.jsonl" ;;
  esac
  run_repair
  assert_call fresh 'FULL ORIGINAL BRIEF'
  jq -Rse --arg reason "$reason" 'split("\n") | any(.[] | fromjson?; .type=="pipeline.execution" and .mode=="fresh" and .reason==$reason)' "$SUP/run.log" >/dev/null
  echo "PASS cold fallback: $reason"
done

seed
export FAKE_MODE=startup
run_repair
python3 - "$CALLS" <<'PY'
import json, sys
calls=[json.loads(s) for s in open(sys.argv[1])]
assert len(calls)==2, calls
assert 'resume' in calls[0] and calls[0][-1]=='NEW REVIEW FAILURE', calls
assert 'resume' not in calls[1] and calls[1][-1].startswith('FULL ORIGINAL BRIEF'), calls
PY
jq -Rse 'split("\n") | any(.[] | fromjson?; .type=="pipeline.execution" and .mode=="fresh" and .reason=="resume-startup-failed" and .resume_exit==2)' "$SUP/run.log" >/dev/null
# Harvest uses the cold run's identity, mode and counters; the aborted turn
# must not poison completion or accidentally restore the old session.
alive() { return 1; }
harvest_workers || fail "harvest failed"
jq -e --arg sid "$new_sid" --arg old "$sid" '.workers[0] | .session_id==$sid and .resume_session_id==$old and .mode=="fresh" and .execution_reason=="resume-startup-failed" and .harvested==true' "$WORKERS" >/dev/null
jq -e --arg sid "$new_sid" '.units[0].sessions.repair == {id:$sid,provider:"codex",model:"model"}' "$UNITS" >/dev/null
echo 'PASS startup fallback and durable session metadata'

seed
export FAKE_MODE=worked
status=0
run_repair || status=$?
[[ "$status" == 3 ]] || fail "resume work failure status=$status"
assert_call resume 'NEW REVIEW FAILURE' "$sid"
echo 'PASS no cold replay after resume does work'

# A fresh implementer emits a session id even if it fails before a final
# report. It must still be recorded with the model that actually ran.
seed
export FAKE_MODE=empty
dispatch implement model high u initial.log initial.md 'FULL ORIGINAL BRIEF' '' "$fixture/repo"
wait "$!" || true
harvest_workers || fail "harvest failed"
jq -e --arg sid "$new_sid" '.units[0] | .sessions.repair=={id:$sid,provider:"codex",model:"model"} and .session_ids.repair==$sid and .session_ids.review=="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"' "$UNITS" >/dev/null
jq -e --arg sid "$new_sid" '.workers[0].session_id==$sid' "$WORKERS" >/dev/null
echo 'PASS fresh implementer records id independently of review and final report'
# The next dispatch reads the id just harvested, never the unrelated review id.
counters 1000 0 100 > "$fixture/sessions/2026/10/24/rollout-$new_sid.jsonl"
export FAKE_MODE=ok
: > "$CALLS"
run_repair
assert_call resume 'NEW REVIEW FAILURE' "$new_sid"
echo 'PASS next repair reads the recorded implementer session'


seed
export FAKE_MODE=ok
printf 'NEW REVIEW FINDINGS\n' > "$SUP/prior.md"
failure="$(repair_failure_prompt '{"review_report":"prior.md"}' prior.md)"
dispatch repair model max u review.log review.md 'FULL ORIGINAL BRIEF' '' "$fixture/repo" '' "$failure"
wait "$!"
assert_call resume 'NEW REVIEW FINDINGS' "$sid"
# CI repair sends the failed step and tail, without the previous review.
cat > "$test_env_bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'pr checks') echo '[{"name":"Test suite","bucket":"fail","link":"https://example.invalid/actions/runs/1/job/42"}]'; exit 1 ;;
  'api --allow-escape-sequences') printf 'post-job output\nAssertionError: expected true\n' ;;
  api*) echo 'Run affected regression tests' ;;
  *) exit 99 ;;
esac
SH
chmod +x "$test_env_bin/gh"
: > "$CALLS"
failure="$(repair_failure_prompt '{"pr":1,"repair_hint":"NEW CI FAILURE","history":[{"stage":"ci-test-red"}]}' prior.md)"
dispatch repair model max u ci.log ci.md 'FULL ORIGINAL BRIEF' '' "$fixture/repo" '' "$failure"
wait "$!"
python3 - "$CALLS" <<'PY'
import json, sys
prompt=json.loads(open(sys.argv[1]).readline())[-1]
assert 'NEW CI FAILURE' in prompt and 'Test suite' in prompt and 'AssertionError: expected true' in prompt, prompt
assert 'Run affected regression tests' in prompt, prompt
assert 'FULL ORIGINAL BRIEF' not in prompt and 'NEW REVIEW FINDINGS' not in prompt, prompt
PY
echo 'PASS review and CI prompts contain only new failure evidence'

# A hint-carrying unit (hotpatch) that then gets REQUEST-CHANGES: the findings travel with the hint.
printf 'HOTPATCH FINDINGS\n' > "$SUP/hot.md"
failure="$(repair_failure_prompt '{"repair_hint":"HOTPATCH HINT","history":[{"stage":"review-request-changes"}]}' hot.md)"
[[ "$failure" == *'HOTPATCH HINT'* && "$failure" == *'HOTPATCH FINDINGS'* ]] || fail "hint plus review lost the findings: $failure"
# A hint with no report yet (first repair of a hotpatch) is the whole failure, not an error.
failure="$(repair_failure_prompt '{"repair_hint":"HOTPATCH HINT","history":[]}' '')" || fail "hint without report failed"
[[ "$failure" == 'HOTPATCH HINT' ]] || fail "hint-only prompt: $failure"
# No hint and no readable report is an error the caller escalates, never an empty prompt.
if repair_failure_prompt '{"history":[]}' missing.md >/dev/null 2>&1; then fail "missing report accepted"; fi
echo 'PASS hint plus review, hint only, missing report'

# Cumulative-raw cutoff applies to repair; a self-fix is exempt and never goes cold.
seed
counters 8950000 8700000 50000 > "$fixture/sessions/2026/10/24/rollout-$sid.jsonl"
build_codex_command repair model max u 'COLD BRIEF' 'NEW REVIEW FAILURE'
[[ "$CODEX_MODE" == fresh && "$CODEX_PATH_REASON" == session-too-large ]] || fail "9M raw repair resumed (mode=$CODEX_MODE reason=$CODEX_PATH_REASON)"
counters 7800000 7500000 100000 > "$fixture/sessions/2026/10/24/rollout-$sid.jsonl"
build_codex_command repair model max u 'COLD BRIEF' 'NEW REVIEW FAILURE'
[[ "$CODEX_MODE" == resume ]] || fail "7.9M raw repair did not resume (reason=$CODEX_PATH_REASON)"
counters 8950000 8700000 50000 > "$fixture/sessions/2026/10/24/rollout-$sid.jsonl"
set_unit u '.self_fix_active=true'
build_codex_command repair model max u 'COLD BRIEF' 'SELF FIX FAILURE'
[[ "$CODEX_MODE" == resume ]] || fail "self-fix over the cutoff did not resume"
set_unit u '.sessions.repair.model="other-model"'
if build_codex_command repair model max u 'COLD BRIEF' 'SELF FIX FAILURE'; then fail "self-fix without a resumable session went cold"; fi
set_unit u '.sessions={}'
if build_codex_command repair model max u 'COLD BRIEF' 'SELF FIX FAILURE'; then fail "self-fix with no recorded session went cold"; fi
echo 'PASS repair cutoff and self-fix guard'
