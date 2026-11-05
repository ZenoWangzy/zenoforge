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

echo 'claude-implement-harvest.test.sh: PASS'
