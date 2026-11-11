#!/usr/bin/env bash
# Harvest of a finished Claude implement worker (claude -p stream-json): the final answer becomes the report, the
# session and usage come from the stream, and a usage-limit or 429 result is a provider fault (cooldown plus the
# claude marker), never a zero-output death.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "claude-implement-harvest.test.sh: $*" >&2; exit 1; }
sup="$test_env_root/supervisor"
mkdir -p "$sup/autopi/alerts" "$test_env_root/root" "$test_env_root/agent/locks"
cp "$script_dir/config.template.json" "$sup/autopi/config.json"
export MAC_AUTOPILOT_ROOT="$test_env_root/root" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" AUTOPI_TEST_LIBRARY_ONLY=true
export AGENT_HOME="$test_env_root/agent"
unset GH_TOKEN GITHUB_TOKEN
source "$script_dir/scheduler.sh"
tick_prs_prime() { :; }
tick_prs_changed() { :; }
cancel_unit_runs() { :; }
sid=eeeeeeee-0000-0000-0000-00000000000e

dead_pid() { bash -c 'echo $$' ; }
seed() { # log-name unit
  printf '{"units":[{"id":"%s","stage":"implement","lane":"pr","history":[]}]}' "$2" > "$UNITS"
  local pid; pid="$(dead_pid)"
  jq -n --argjson pid "$pid" --arg unit "$2" --arg log "$1" --arg sid "$sid" \
    '{workers:[{pid:$pid,pid_start:1,process_group:$pid,claim_owner:"o",unit:$unit,type:"implement",provider:"claude",model:"claude-sonnet-5-5",effort:"high",
      log:$log,report:"impl-report.md",started:"2026-11-04T00:00:00Z",mode:"fresh",session_id:"",workdir:"/nonexistent",
      token_usage_start:{input_tokens:0,cached_input_tokens:0,output_tokens:0}}]}' > "$WORKERS"
}

# usage-limit result: provider fault, not a zero-output death
cat > "$sup/limit.worker.log" <<JSONL
{"type":"system","subtype":"init","session_id":"$sid"}
{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You've hit your limit - resets 3pm","session_id":"$sid","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}
JSONL
rm -f "$sup/impl-report.md"
seed limit.worker.log issue-1
harvest_workers
jq -e '.workers[0].harvested == true and .workers[0].token_accounting == "measured"' "$WORKERS" >/dev/null || fail "limit worker not harvested: $(jq -c '.workers[0]' "$WORKERS")"
jq -e '.claude > 0' "$COOLDOWN" >/dev/null || fail 'usage limit did not start a claude cooldown'
provider_quota_exhausted claude || fail 'usage limit did not write the claude marker'
jq -e '.units[0].history | any(.stage == "worker-provider-limit") and all(.stage != "worker-no-output")' "$UNITS" >/dev/null \
  || fail 'usage limit was counted as a zero-output death'
[[ ! -s "$sup/impl-report.md" ]] || fail 'the limit error text became the report'
jq -e --arg sid "$sid" '.units[0].sessions.repair | .id == $sid and .provider == "claude" and .model == "claude-sonnet-5-5"' "$UNITS" >/dev/null \
  || fail 'the Claude session was not recorded for resume'

# successful result: usage measured, final answer recovered as the report
rm -f "$COOLDOWN" "$CLAUDE_EXHAUSTED_MARKER_FILE"
cat > "$sup/ok.worker.log" <<JSONL
{"type":"system","subtype":"init","session_id":"$sid"}
{"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"REPORT BODY","session_id":"$sid","usage":{"input_tokens":3,"cache_creation_input_tokens":100,"cache_read_input_tokens":900,"output_tokens":40}}
JSONL
seed ok.worker.log issue-2
harvest_workers || :
[[ "$(cat "$sup/impl-report.md" 2>/dev/null)" == 'REPORT BODY' ]] || fail 'the Claude final answer was not recovered as the report'
jq -e '.workers[0].token_accounting == "measured" and .workers[0].dispatch_tokens == 1043 and .workers[0].session_id != ""' "$WORKERS" >/dev/null \
  || fail "usage was not measured from the result line: $(jq -c '.workers[0]' "$WORKERS")"
! provider_quota_exhausted claude || fail 'a successful run held claude'

# codex resumed run: turn.completed usage is the thread's cumulative counter, so this run's fresh tokens are the final
# snapshot minus the dispatch snapshot (fresh = input - cached + output: 1500 - 700 = 800, not the cumulative 1500).
codex_sid=eeeeeeee-0000-0000-0000-00000000000f
cat > "$sup/codex.worker.log" <<JSONL
{"type":"thread.started","thread_id":"$codex_sid"}
{"type":"turn.started"}
{"type":"turn.completed","usage":{"input_tokens":2000,"cached_input_tokens":800,"output_tokens":300}}
JSONL
printf 'CODEX REPORT\n' > "$sup/codex-report.md"
codex_worker() { # mode start-json
  printf '{"units":[{"id":"issue-3","stage":"implement","lane":"pr","history":[]}]}' > "$UNITS"
  jq -n --argjson pid "$(dead_pid)" --arg sid "$codex_sid" --arg mode "$1" --argjson start "$2" \
    '{workers:[{pid:$pid,pid_start:1,process_group:$pid,claim_owner:"o",unit:"issue-3",type:"implement",provider:"codex",model:"gpt-6-luna",effort:"high",
      log:"codex.worker.log",report:"codex-report.md",started:"2026-11-08T00:00:00Z",mode:$mode,session_id:$sid,workdir:"/nonexistent",token_usage_start:$start}]}' > "$WORKERS"
}
codex_worker resume '{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100}'
: > "$LOG"
harvest_workers || :
grep -q ' harvest unit=issue-3 .* tokens=800 ' "$LOG" \
  || fail "resumed codex run did not record its own fresh tokens: $(grep 'unit=issue-3' "$LOG" || true)"
codex_worker fresh '{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0}'
: > "$LOG"
harvest_workers || :
grep -q ' harvest unit=issue-3 .* tokens=1500 ' "$LOG" \
  || fail "fresh codex run did not record its stream fresh tokens: $(grep 'unit=issue-3' "$LOG" || true)"

# A supervisor requeue limited to the report returns an unchanged open PR to review and restarts its red CI once.
report_only_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
report_only_started=2026-11-11T13:01:00Z
report_only_reruns="$sup/report-only-reruns.log"
report_only_unit=issue-report-only-pass
report_only_report=report-only-pass.md
report_only_pr=742
REPO=example/repo
: > "$report_only_reruns"
gh() {
  case "$1 $2" in
    'run list')
      [[ "$3" == --commit && "$4" == "$report_only_head" ]] || fail "CI run list used the wrong head: $*"
      printf '77\n'
      ;;
    'api -X')
      [[ "$3" == POST && "$4" == "repos/$REPO/actions/runs/77/rerun" ]] || fail "unexpected run rerun endpoint: $*"
      printf '%s\n' "$*" >> "$report_only_reruns"
      ;;
    *) fail "unexpected gh call in report-only harvest: $*" ;;
  esac
}
seed_report_only_requeue() { # unit report started → implement worker with a supervisor report-only marker and unchanged PR head
  local unit="$1" report="$2" started="$3" pid
  printf '%s\n' "$4" > "$sup/$report"
  printf '{"units":[{"id":"%s","pr":%s,"branch":"agent/%s","lane":"pr","stage":"implement","implementation_report":"old-report.md","history":[{"stage":"pr-opened","result":"PR#%s %s"},{"stage":"supervisor-requeue","result":"Supervisor ruling (head): requeue for the report only.","at":"2026-11-11T13:00:00Z"},{"stage":"write-start","work_type":"implement","at":"%s"}]}]}' \
    "$unit" "$report_only_pr" "$unit" "$report_only_pr" "$report_only_head" "$started" > "$UNITS"
  pid="$(dead_pid)"
  jq -n --argjson pid "$pid" --arg unit "$unit" --arg report "$report" --arg started "$started" --arg head "$report_only_head" \
    '{workers:[{pid:$pid,pid_start:1,claim_owner:"o",unit:$unit,type:"implement",provider:"fixture",log:"report-only.log",report:$report,
      started:$started,mode:"fresh",sha:$head,pr_head:$head,workdir:"/nonexistent",token_usage_start:{input_tokens:0,cached_input_tokens:0,output_tokens:0}}]}' > "$WORKERS"
  : > "$sup/report-only.log"
  TICK_PRS="$(jq -cn --argjson pr "$report_only_pr" --arg head "$report_only_head" '[{number:$pr,headRefOid:$head,headRefName:"agent/report-only",isDraft:false}]')"
}
seed_report_only_requeue "$report_only_unit" "$report_only_report" "$report_only_started" \
  $'## how\nRewrote only the report for the unchanged head.\n\n## why\nThe report needed the required sections for #742.\n\n## decision-log\nTried: checked the report headings.\nFailure: the prior report was incomplete.\nChoice: keep the code and rewrite the report only.\nVerification: all report gates pass for the existing head.'
harvest_workers || :
jq -e '.units[0] | .stage == "review-pending" and .implementation_report == "report-only-pass.md"' "$UNITS" >/dev/null \
  || fail "valid report-only requeue did not return its unchanged PR to review: $(jq -c '.units[0]' "$UNITS")"
[[ "$(wc -l < "$report_only_reruns")" == 1 ]] || fail "report-only requeue did not issue exactly one REST CI rerun: $(cat "$report_only_reruns")"

report_only_unit=issue-report-only-fail
report_only_report=report-only-fail.md
seed_report_only_requeue "$report_only_unit" "$report_only_report" "$report_only_started" $'## how\nReport rewrite without the required decision log.'
harvest_workers || :
jq -e '.units[0] | .stage == "supervisor-review" and any(.history[]; .stage == "supervisor-escalated")' "$UNITS" >/dev/null \
  || fail "gate-failing report-only requeue did not escalate: $(jq -c '.units[0]' "$UNITS")"
[[ "$(wc -l < "$report_only_reruns")" == 1 ]] || fail 'gate-failing report-only requeue attempted a CI rerun'

echo 'claude-implement-harvest.test.sh: PASS'
