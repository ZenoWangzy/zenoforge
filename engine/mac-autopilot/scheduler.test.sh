#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
# Output contract (#4480): a green run prints one summary line; a failing run
# prints the failing check's message, or the ERR trap's "not ok - ... line N"
# naming the failing command. Run one case with SCHED_TEST_CASE=<case> (names:
# the sched_run_case calls below); the shared prelude always runs.
set -E
trap 'printf "not ok - scheduler.test.sh line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"
scheduler="$script_dir/scheduler.sh"
template="$script_dir/config.template.json"
# Tick fixtures use synthetic ci/Pipeline suites rows; the adopted-PR case below
# runs the real aggregate check policy through gh-shim and the unit ledger.
export REQUIRED_PR_CHECKS_FILE="$test_env_root/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
# The product's scripts/branch-delivery-policy.mjs is not exported: classify_lane asks AUTOPILOT_POLICY_SCRIPT for a verdict on a PR's
# paths. This stand-in (the same one scheduler-gates.test.sh uses) calls everything outside packages/ and .github/ direct-main eligible.
POLICY_FIXTURE="$test_env_root/branch-delivery-policy.fixture.mjs"
cat > "$POLICY_FIXTURE" <<'JS'
import { readFileSync } from 'node:fs';
const paths = JSON.parse(process.argv[3] === '-' ? readFileSync(0, 'utf8') : process.argv[3]);
console.log(paths.every((p) => !p.startsWith('packages/') && !p.startsWith('.github/')) ? 'eligible' : 'not-eligible');
JS

bash -n "$scheduler"
unsafe_update_pattern='|= '
unsafe_update_pattern+='(select'
if grep -nF "$unsafe_update_pattern" "$scheduler"; then
  echo 'not ok - scheduler.test.sh: jq select update can delete unmatched units' >&2
  exit 1
fi
grep -Fq 'gh pr merge "$pr" --squash' "$scheduler"
grep -Fq 'resume "$session_id" -m "$model"' "$scheduler"
grep -Fq 'focus_mode' "$scheduler"
grep -Fq 'session id: ' "$scheduler"
grep -Fq 'dispatch mode=$CODEX_MODE' "$scheduler"
if grep -Fq 'spent()' "$scheduler"; then
  echo 'not ok - scheduler.test.sh: the old worker-log spend heuristic must stay removed' >&2
  exit 1
fi
if grep -Fq 'BUDGET-STOP' "$scheduler" || grep -Fq 'workorder_spend_runner' "$scheduler" || grep -Fq 'workorder_budget' "$scheduler"; then
  echo 'not ok - scheduler.test.sh: token hard stops must stay removed; the stop-loss is rounds+wall only (#4486)' >&2
  exit 1
fi
if grep -Eq 'gh pr merge .*--auto' "$scheduler"; then
  echo 'not ok - scheduler.test.sh: native auto-merge must stay disabled' >&2
  exit 1
fi
jq -e '.focus_mode == "all" and .budget_meter == "sessions_dir"' "$template" >/dev/null
jq -e '.max_workers == 10 and .auto_merge == true and .implement_cap == 8
  and .release_train.enabled == true and .supervisor_arbiter.enabled == true
  and .models.review == ["claude-haiku-5-5", "high"]
  and .models.implement == ["gpt-6-luna", "max", "fast"]
  and .models.triage == ["gpt-6-luna", "max", "fast"]
  and .models.review_fallback == ["gpt-6-luna", "max", "fast"]
  and .models.implement_hotfix == ["gpt-6.1-terra", "high"]' "$template" >/dev/null

sample='{"units":[{"id":"pr-1","stage":"ready-to-merge"},{"id":"pr-2","stage":"ready-to-merge"},{"id":"pr-3","stage":"merged"}]}'
updated="$(jq --arg id pr-2 \
  --arg merge_sha 0123456789abcdef0123456789abcdef01234567 \
  --arg pre_merge_sha abcdef0123456789abcdef0123456789abcdef01 \
  '(.units[] |= (if .id==$id then (.stage="merged" | .merge_sha=$merge_sha | .pre_merge_sha=$pre_merge_sha) else . end))' \
  <<<"$sample")"
jq -e '
  (.units | length) == 3
  and ([.units[] | select(.id=="pr-1")][0].stage == "ready-to-merge")
  and ([.units[] | select(.id=="pr-2")][0].stage == "merged")
  and ([.units[] | select(.id=="pr-2")][0].merge_sha == "0123456789abcdef0123456789abcdef01234567")
  and ([.units[] | select(.id=="pr-2")][0].pre_merge_sha == "abcdef0123456789abcdef0123456789abcdef01")
  and ([.units[] | select(.id=="pr-3")][0].stage == "merged")
' <<<"$updated" >/dev/null

fixture="$test_env_root/roi-fixture"
fixture_supervisor="$fixture/supervisor"
fixture_sessions="$fixture/sessions"
mkdir -p "$fixture_supervisor/autopi/alerts" "$fixture_sessions"
mkdir -p "$HOME/.claude/projects"
cp "$template" "$fixture_supervisor/autopi/config.json"
jq '.focus_mode = "release"' "$template" > "$fixture_supervisor/autopi/config.json"
cat > "$fixture_supervisor/autopi/units.json" <<'JSON'
{"units":[
  {"id":"pr-critical","stage":"review-pending","critical":true},
  {"id":"pr-regular","stage":"review-pending","critical":false},
  {"id":"pr-resume","stage":"repair-pending","critical":true,"sessions":{"repair":{"id":"11111111-2222-3333-4444-555555555555","provider":"codex","model":"model"}},"session_ids":{"repair":"11111111-2222-3333-4444-555555555555"}},
  {"id":"pr-fresh","stage":"repair-pending","critical":true,"session_ids":{"review":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}},
  {"id":"pr-budget","stage":"review-pending","critical":true},
  {"id":"pr-merged","stage":"merged","history":[{"stage":"merged","at":"2026-10-17T00:00:00Z"}]},
  {"id":"pr-mixed","stage":"repair-pending"}
]}
JSON
echo '{"workers":[]}' > "$fixture_supervisor/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture_supervisor"
export CODEX_SESSIONS_DIR="$fixture_sessions"
# Force a date boundary mismatch so the dashboard must use the scheduler's session timezone.
export SESSION_TZ=Pacific/Kiritimati
export TZ=Etc/GMT+12
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$scheduler"
unset AUTOPI_TEST_LIBRARY_ONLY

# Parent admission signals: ADR/spec pilots, open child links in task lists,
# and GitHub's native sub-issue relation. An ordinary related-issue mention is
# not a task-list child; closed children do not retire an implementation leaf.
gh() {
  case "$*" in
    'issue view 6201 --json state --jq .state') echo OPEN ;;
    'issue view 6202 --json state --jq .state') echo CLOSED ;;
    'issue view 6207 --json state --jq .state') return 1 ;;
    'api repos/example-maintainer/example-repo/issues/6200/sub_issues?per_page=100'|\
    'api repos/example-maintainer/example-repo/issues/6203/sub_issues?per_page=100'|\
    'api repos/example-maintainer/example-repo/issues/6210/sub_issues?per_page=100'|\
    'api repos/example-maintainer/example-repo/issues/6211/sub_issues?per_page=100') echo '[]' ;;
    'api repos/example-maintainer/example-repo/issues/6205/sub_issues?per_page=100') echo '[{"number":6206,"state":"open"}]' ;;
    'api repos/example-maintainer/example-repo/issues/6204/sub_issues?per_page=100') return 1 ;;
    *) echo "unexpected parent-admission gh call: $*" >&2; return 97 ;;
  esac
}
task_parent_json="$(jq -cn --arg body $'Migration tasks:\n\n- [ ] Implement child #6201' '{number:6200,title:"Migration tasks",body:$body,labels:[]}')"
[[ "$(scheduler_issue_intake_parent_reason 6200 "$task_parent_json")" == 'task list references open child #6201' ]] || {
  echo 'scheduler.test.sh: open child in a task list was not classified as a parent' >&2; exit 1;
}
adr_parent_json="$(jq -cn '{number:6199,title:"ADR-4 pilot",body:"Evaluate the scheduler pilot",labels:[]}')"
[[ "$(scheduler_issue_intake_parent_reason 6199 "$adr_parent_json")" == 'spec/ADR pilot' ]] || {
  echo 'scheduler.test.sh: ADR pilot was not classified as a parent' >&2; exit 1;
}
spec_parent_json="$(jq -cn --arg body $'Migration overview.\n\nSpec: migration plan' '{number:6198,title:"Migration design",body:$body,labels:[]}')"
[[ "$(scheduler_issue_intake_parent_reason 6198 "$spec_parent_json")" == 'spec/ADR pilot' ]] || {
  echo 'scheduler.test.sh: a second-line Spec: marker was not classified as a parent' >&2; exit 1;
}
spec_leaf_json="$(jq -cn '{number:6210,title:"Fix spec-compliance check",body:"Update the spec-compliance guard",labels:[]}')"
leaf_status=0
scheduler_issue_intake_parent_reason 6210 "$spec_leaf_json" >/dev/null || leaf_status=$?
[[ "$leaf_status" == 1 ]] || { echo 'scheduler.test.sh: a leaf mentioning spec without a Spec: marker was treated as a parent' >&2; exit 1; }
spec_title_parent_json="$(jq -cn '{number:6197,title:"Runtime pilot spec, ADR-1",body:"Prepare the pilot",labels:[]}')"
[[ "$(scheduler_issue_intake_parent_reason 6197 "$spec_title_parent_json")" == 'spec/ADR pilot' ]] || {
  echo 'scheduler.test.sh: the #4472 title-form spec marker was not classified as a parent' >&2; exit 1;
}
adr_title_parent_json="$(jq -cn '{number:4279,title:"运行时试点：后台任务迁移（ADR-2）",body:"Migrate the background runtime",labels:[]}')"
[[ "$(scheduler_issue_intake_parent_reason 4279 "$adr_title_parent_json")" == 'spec/ADR pilot' ]] || {
  echo 'scheduler.test.sh: the #4279 title-form ADR pilot marker was not classified as a parent' >&2; exit 1;
}
heading_spec_parent_json="$(jq -cn --arg body $'## Spec\nMigration plan' '{number:6196,title:"Migration design",body:$body,labels:[]}')"
[[ "$(scheduler_issue_intake_parent_reason 6196 "$heading_spec_parent_json")" == 'spec/ADR pilot' ]] || {
  echo 'scheduler.test.sh: a Spec heading was not classified as a parent' >&2; exit 1;
}
bare_spec_parent_json="$(jq -cn --arg body $'Spec\nMigration plan' '{number:6195,title:"Migration design",body:$body,labels:[]}')"
[[ "$(scheduler_issue_intake_parent_reason 6195 "$bare_spec_parent_json")" == 'spec/ADR pilot' ]] || {
  echo 'scheduler.test.sh: a bare Spec line was not classified as a parent' >&2; exit 1;
}
explicit_spec_parent_json="$(jq -cn --arg body 'This issue is a specification for the migration.' '{number:6194,title:"Migration design",body:$body,labels:[]}')"
[[ "$(scheduler_issue_intake_parent_reason 6194 "$explicit_spec_parent_json")" == 'spec/ADR pilot' ]] || {
  echo 'scheduler.test.sh: an explicit spec declaration was not classified as a parent' >&2; exit 1;
}
body_adr_parent_json="$(jq -cn --arg body $'## ADR-3 pilot\nMigration decision' '{number:6193,title:"Migration design",body:$body,labels:[]}')"
[[ "$(scheduler_issue_intake_parent_reason 6193 "$body_adr_parent_json")" == 'spec/ADR pilot' ]] || {
  echo 'scheduler.test.sh: a line-start ADR pilot marker was not classified as a parent' >&2; exit 1;
}
native_parent_json="$(jq -cn '{number:6205,title:"Scheduler migration",body:"Migrate the background runtime",labels:[]}')"
[[ "$(scheduler_issue_intake_parent_reason 6205 "$native_parent_json")" == 'has GitHub sub-issues' ]] || {
  echo 'scheduler.test.sh: native GitHub sub-issues were not classified as a parent' >&2; exit 1;
}
leaf_json="$(jq -cn '{number:6203,title:"Fix scheduler",body:"- Related issue #6201",labels:[]}')"
leaf_status=0
scheduler_issue_intake_parent_reason 6203 "$leaf_json" >/dev/null || leaf_status=$?
[[ "$leaf_status" == 1 ]] || { echo 'scheduler.test.sh: a related issue bullet was treated as a task-list child' >&2; exit 1; }
leaf_json="$(jq -cn '{number:6200,title:"Migration tasks",body:"- [ ] Implement child #6202",labels:[]}')"
leaf_status=0
scheduler_issue_intake_parent_reason 6200 "$leaf_json" >/dev/null || leaf_status=$?
[[ "$leaf_status" == 1 ]] || { echo 'scheduler.test.sh: a closed task-list child was treated as an open parent' >&2; exit 1; }
self_task_json="$(jq -cn --arg body $'Migration tasks:\n- [ ] Continue work in #6211' '{number:6211,title:"Migration tasks",body:$body,labels:[]}')"
leaf_status=0
scheduler_issue_intake_parent_reason 6211 "$self_task_json" >/dev/null || leaf_status=$?
[[ "$leaf_status" == 1 ]] || { echo 'scheduler.test.sh: a self-reference in a task list was treated as an open child' >&2; exit 1; }
unavailable_child_json="$(jq -cn '{number:6208,title:"Migration tasks",body:"- [ ] Implement child #6207",labels:[]}')"
leaf_status=0
scheduler_issue_intake_parent_reason 6208 "$unavailable_child_json" >/dev/null || leaf_status=$?
[[ "$leaf_status" == 2 ]] || { echo 'scheduler.test.sh: unreadable task-list child was treated as a leaf' >&2; exit 1; }
unavailable_json="$(jq -cn '{number:6204,title:"Fix scheduler",body:"Implement the retry",labels:[]}')"
leaf_status=0
scheduler_issue_intake_parent_reason 6204 "$unavailable_json" >/dev/null || leaf_status=$?
[[ "$leaf_status" == 2 ]] || { echo 'scheduler.test.sh: unavailable native-child lookup was not reported' >&2; exit 1; }
original_agent_lib="$SCHEDULER_AGENT_LIB"
failed_agent_lib="$(mktemp)"
printf 'return 1\n' > "$failed_agent_lib"
SCHEDULER_AGENT_LIB="$failed_agent_lib"
leaf_status=0
scheduler_issue_intake_parent_reason 6203 "$leaf_json" >/dev/null 2>&1 || leaf_status=$?
SCHEDULER_AGENT_LIB="$original_agent_lib"
rm -f "$failed_agent_lib"
[[ "$leaf_status" == 2 ]] || { echo 'scheduler.test.sh: failed shared-library load was treated as a verified leaf' >&2; exit 1; }
unset -f gh
# Gate orchestration has a real-tree fixture in scheduler-self-check.test.sh.
self_check_before_review() { return 0; }

live_workers() { echo 0; }
live_by_type() { echo 0; }
dispatched=()
dispatch() { dispatched+=("$4"); }
if dispatch_if_room pr-regular review review regular.log regular.md model max prompt; then
  echo 'not ok - scheduler.test.sh: release focus dispatched a non-critical unit' >&2
  exit 1
fi
[[ "$(jq -r '.units[] | select(.id=="pr-regular") | .stage' "$UNITS")" == "review-pending" ]]
[[ "${#dispatched[@]}" == 0 && "${FOCUS_SKIPPED[0]}" == "pr-regular" ]]
dispatch_if_room pr-critical review review critical.log critical.md model max prompt
[[ "$(jq -r '.units[] | select(.id=="pr-critical") | .stage' "$UNITS")" == "review" ]]
[[ "${dispatched[0]}" == "pr-critical" ]]
BUDGET=1
printf '{"date":"%s","fresh":101,"bound":{"unhealthy":100}}\n' "$TODAY" > "$A/budget.json"
budget_alert_if_needed
[[ "$(grep -c 'BUDGET-ALERT' "$A/alerts/waste.md")" == 1 ]]
dispatch_if_room pr-budget review review budget.log budget.md model max prompt
[[ "${dispatched[1]}" == "pr-budget" ]]
BUDGET=30000000
has_critical_label '["bug","CRITICAL"]'
if has_critical_label '["critical-ish"]'; then
  echo 'not ok - scheduler.test.sh: partial label match was treated as critical' >&2
  exit 1
fi

STAMP=TEST
FOCUS_SKIPPED=(pr-z pr-a pr-z)
NOW_EPOCH=1000
flush_focus_alert
NOW_EPOCH=2500
FOCUS_SKIPPED=(pr-a pr-z)
flush_focus_alert
[[ "$(wc -l < "$A/alerts/focus.md" | tr -d ' ')" == 1 ]]
grep -Fq '[TEST] focus: 2 units queued (pr-a,pr-z)' "$A/alerts/focus.md"
NOW_EPOCH=2801
flush_focus_alert
[[ "$(wc -l < "$A/alerts/focus.md" | tr -d ' ')" == 2 ]]

yesterday_text="$(TODAY="$TODAY" python3 -c 'from datetime import date, timedelta; import os; print((date.fromisoformat(os.environ["TODAY"]) - timedelta(days=1)).isoformat())')"
session_day="${TODAY//-//}"
yesterday_session_day="${yesterday_text//-//}"
mkdir -p "$fixture_sessions/$session_day"
mkdir -p "$fixture_sessions/$yesterday_session_day"
cat > "$fixture_sessions/$session_day/rollout-small-11111111-2222-3333-4444-555555555555.jsonl" <<'JSONL'
{"type":"turn_context","payload":{"model":"gpt-6-luna"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9,"cached_input_tokens":1,"output_tokens":2}}}}
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":2000,"total_tokens":1002000},"total_token_usage":{"input_tokens":2000000,"cached_input_tokens":1000000,"output_tokens":2000000,"total_tokens":4000000}}}}
JSONL
cat > "$fixture_sessions/$session_day/rollout-large-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl" <<'JSONL'
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":8000000,"cached_input_tokens":1000000,"output_tokens":0,"total_tokens":8000000},"total_token_usage":{"input_tokens":8000000,"cached_input_tokens":1000000,"output_tokens":0,"total_tokens":8000000}}}}
JSONL
cat > "$fixture_sessions/$session_day/rollout-mixed-99999999-aaaa-bbbb-cccc-dddddddddddd.jsonl" <<'JSONL'
{"type":"turn_context","payload":{"model":"gpt-6-luna"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0,"total_tokens":1000000}}}}
{"type":"turn_context","payload":{"model":"gpt-5.6-terra"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000000,"cached_input_tokens":1000000,"output_tokens":1000000,"total_tokens":5000000}}}}
JSONL
cat > "$fixture_sessions/$yesterday_session_day/rollout-terra-77777777-aaaa-bbbb-cccc-dddddddddddd.jsonl" <<'JSONL'
{"type":"turn_context","payload":{"model":"gpt-5.6-terra"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000000,"cached_input_tokens":1000000,"output_tokens":1000000,"total_tokens":4000000}}}}
JSONL
cat > "$fixture_sessions/$yesterday_session_day/rollout-unknown-88888888-aaaa-bbbb-cccc-dddddddddddd.jsonl" <<'JSONL'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":1000000,"total_tokens":2000000}}}}
JSONL
printf 'session id: 11111111-2222-3333-4444-555555555555\n' > "$fixture_supervisor/impl-pr-resume.worker.log"
printf 'session id: 99999999-aaaa-bbbb-cccc-dddddddddddd\n' > "$fixture_supervisor/impl-pr-mixed.worker.log"
build_codex_command repair model max pr-resume 'incremental repair'
[[ "$CODEX_MODE" == resume && "${CODEX_COMMAND[0]} ${CODEX_COMMAND[1]} ${CODEX_COMMAND[3]} ${CODEX_COMMAND[4]}" == 'codex exec danger-full-access resume' ]]
[[ "${CODEX_COMMAND[*]}" == *'11111111-2222-3333-4444-555555555555'* ]]
[[ "$(session_last_tokens_for_id 11111111-2222-3333-4444-555555555555)" == 1002000 ]]
fallback_session_id=cccccccc-dddd-eeee-ffff-000000000001
fallback_session_dir="$fixture_sessions/1999/01/01"
mkdir -p "$fallback_session_dir"
cat > "$fallback_session_dir/rollout-fallback-$fallback_session_id.jsonl" <<'JSONL'
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":9,"cached_input_tokens":7,"output_tokens":2},"total_token_usage":{"input_tokens":90,"cached_input_tokens":70,"output_tokens":20}}}}
JSONL
[[ "$(session_last_tokens_for_id "$fallback_session_id")" == 11 ]] || {
  echo 'not ok - scheduler.test.sh: last-token fallback counted cached input twice' >&2; exit 1;
}
[[ "$(session_tokens_for_id "$fallback_session_id")" == 110 ]] || {
  echo 'not ok - scheduler.test.sh: cumulative-token fallback counted cached input twice' >&2; exit 1;
}
build_codex_command rereview model max pr-fresh 'incremental review'
[[ "$CODEX_MODE" == fresh ]]
build_codex_command rereview model max pr-resume 'incremental review'
[[ "$CODEX_MODE" == fresh && "${CODEX_COMMAND[*]}" == *'codex exec -m model'* ]]

# Attribute usage by event timestamp, including files created on prior days.
SESSION_FIXTURE_ROOT="$fixture_sessions" python3 - <<'PY'
import json, os
from pathlib import Path
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
for path in Path(os.environ["SESSION_FIXTURE_ROOT"]).glob("*/*/*/*.jsonl"):
    day = "-".join(path.parts[-4:-1])
    stamp = datetime.fromisoformat(day).replace(hour=12, tzinfo=ZoneInfo(os.environ["SESSION_TZ"]))
    at = stamp.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    events = [dict(json.loads(line), timestamp=at) for line in path.read_text().splitlines()]
    path.write_text("".join(json.dumps(event) + "\n" for event in events))
PY
SESSIONS_DIR="$fixture_sessions"
TODAY="$(TZ="$SESSION_TZ" date +%Y-%m-%d)"
budget_result="$(update_budget)"
# codex input_tokens 已含 cached：total = in + out（cached 不重复计）
jq -e --arg today "$TODAY" '
  .date == $today and .status == "measured"
  and .total == 16000000 and .in == 13000000 and .cached == 3000000 and .out == 3000000
  and .fresh == 13000000 and .raw == 16000000
  and .providers.codex.fresh == 13000000 and .providers.claude.fresh == 0 and .bound == null
' <<<"$budget_result" >/dev/null
[[ "$(jq -cS . "$A/budget.json")" == "$(jq -cS . <<<"$budget_result")" ]]
mkdir -p "$fixture/bin"
merged_pr_fixture="$fixture/merged-prs.json"
TODAY="$TODAY" SESSION_TZ="$SESSION_TZ" python3 - "$merged_pr_fixture" <<'PY'
import json
import os
import sys
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

today = date.fromisoformat(os.environ["TODAY"])
session_tz = ZoneInfo(os.environ["SESSION_TZ"])

def merged_at(day, hour):
    local = datetime.combine(day, time(hour=hour), tzinfo=session_tz)
    return local.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")

prs = [
    {"number": 501, "mergedAt": merged_at(today, 1)},
    {"number": 502, "mergedAt": merged_at(today, 13)},
    {"number": 503, "mergedAt": merged_at(today + timedelta(days=1), 1)},
]
assert [pr["mergedAt"][:10] for pr in prs] == [
    (today - timedelta(days=1)).isoformat(),
    (today - timedelta(days=1)).isoformat(),
    today.isoformat(),
]
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(prs, output)
PY
export MERGED_PR_FIXTURE="$merged_pr_fixture"
cat > "$fixture/bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == 'api repos/example-maintainer/example-repo/deployments?environment=production&per_page=20' && -n "${DEPLOYMENT_FIXTURE:-}" ]]; then
  cat "$DEPLOYMENT_FIXTURE"
elif [[ "$*" == 'api repos/example-maintainer/example-repo/deployments/1/statuses' && -n "${DEPLOYMENT_FIXTURE:-}" ]]; then
  printf '%s\n' '[{"state":"success","created_at":"2026-10-24T00:00:00Z"}]'
elif [[ "$*" == 'api repos/{owner}/{repo}/actions/runners?per_page=100'* ]]; then
  # 看板 60ba960cf 起按 runner 池展示 CI 现状：PR 池一个在线且忙，Mac 池一个离线
  printf '%s\n' '[{"name":"cihost-ci-1","status":"online","busy":true,"labels":["cihost-ci"]},{"name":"zf-mac-2","status":"offline","busy":false,"labels":["other"]}]'
elif [[ "$*" == 'pr list --state merged --limit 30 --json number,mergedAt' ]]; then
  cat "$MERGED_PR_FIXTURE"
else
  echo '[]'
fi
SH
cat > "$fixture/bin/ssh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fixture/bin/gh" "$fixture/bin/ssh"
# A v2 cache has the same file stamps but the old cached-token total; it must be re-read.
python3 - "$fixture_sessions/$session_day/rollout-small-11111111-2222-3333-4444-555555555555.jsonl" \
  "$fixture_sessions/$session_day/rollout-mixed-99999999-aaaa-bbbb-cccc-dddddddddddd.jsonl" \
  "$fixture_supervisor/.cost_cache.json" <<'PY'
import json
import os
import sys

small_path, mixed_path, cache_path = sys.argv[1:]
files = {}
for session_path, usage in (
    (small_path, {
        "model": "gpt-6-luna", "models": ["gpt-6-luna"], "mixed_model": False,
        "in": 1000000, "cached": 1000000, "out": 2000000, "tokens_total": 5000000,
    }),
    (mixed_path, {
        "model": "mixed", "models": ["gpt-6-luna", "gpt-5.6-terra"], "mixed_model": True,
        "in": 2000000, "cached": 1000000, "out": 1000000, "tokens_total": 5000000,
    }),
):
    stat = os.stat(session_path)
    files[session_path] = {"mtime_ns": stat.st_mtime_ns, "size": stat.st_size, "usage": usage}
with open(cache_path, "w", encoding="utf-8") as output:
    json.dump({"version": 2, "files": files}, output)
PY
PATH="$fixture/bin:$PATH" python3 "$script_dir/gen_dashboard.py"
dashboard_data="$(sed 's/^window.DASH=//; s/;$//' "$A/dashboard.data.js")"
# 看板的 CI 现状与控制旋钮：没有 GitHub 数据时数值为空（显示"无数据"），不报错；旋钮列出当前值。
# 60ba960cf 起 CI 现状按 runner 池展示（wip_limit 与 ci_wip 旋钮已删，名额由 runner 算出）。
jq -e '(.ci_live.values | has("runners_online") and has("queued_runs") and has("wip_waiting"))
  and .ci_live.pools.PR == {"total":1,"online":1,"busy":1}
  and .ci_live.values.runners_online == 1
  and (.ci_live | has("wip_limit") | not)
  and ([.knobs[].key] | index("ci_wip") == null) and ([.knobs[] | select(.key == "focus_mode")][0].value == "release")' <<<"$dashboard_data" >/dev/null \
  || { echo "dashboard lacks the CI runner pools or control knobs: $(jq -c '{ci_live, knobs}' <<<"$dashboard_data")" >&2; exit 1; }
jq -e '.summary.focus_mode == "release"
  and .summary.real_daily_tokens == 16000000
  and .summary.tokens_per_merged == 16000000
  and .totals.merged_today == [501,502]
  and .summary.dollars_per_merged > 0.90999 and .summary.dollars_per_merged < 0.91001
  and .cost.today.tokens == 16000000
  and .cost.today.dollars > 1.8199 and .cost.today.dollars < 1.8201
  and .cost.today.unestimated_sessions == 1
  and .cost.yesterday.tokens == 5000000
  and .cost.yesterday.dollars > 14.7999 and .cost.yesterday.dollars < 14.8001
  and .cost.yesterday.unestimated_sessions == 0
  and .cost.unestimated_sessions == 1
  and .cost.budget_tokens == 16000000 and .cost.budget_tokens_match == true
  and ([.cost.per_unit[] | select(.unit == "pr-resume")][0].dollars == 1.11)
  and ([.cost.top_sessions[] | select(.session_id == "11111111-2222-3333-4444-555555555555")][0]
       | .model == "gpt-6-luna" and .tokens == 4000000 and .dollars > 1.1099 and .dollars < 1.1101 and (.unpriced_model | not))
  and ([.cost.top_sessions[] | select(.session_id == "99999999-aaaa-bbbb-cccc-dddddddddddd")][0]
       | .model == "mixed" and .mixed_model and .tokens == 4000000 and .dollars == null and .unpriced_model)
  and ([.cost.by_model[] | select(.model == "mixed")][0]
       | .dollars == null and .unestimated_sessions == 1)
  and ([.cost.per_unit[] | select(.unit == "pr-mixed")][0]
       | .dollars == null and .unestimated_sessions == 1)
  and (.cost.pricing_note | contains("OpenAI API 标准文本 token 公价"))
  and (.cost.pricing_note | contains("1 个混合模型 session"))
  and ([.alerts_tail[] | select(contains("bottleneck"))] | length) == 1' \
  <<<"$dashboard_data" >/dev/null
jq -e '.version == 3
  and ([.files[].usage | select(.mixed_model == true)] | length) == 1
  and ([.files[] | select(.usage.tokens_total == 5000000)] | length) == 0' \
  "$fixture_supervisor/.cost_cache.json" >/dev/null

jq -e '.pricing["gpt-6-luna"] == {"in":0.1,"cached":0.01,"out":0.5}
  and .pricing["gpt-5.6-terra"] == {"in":2,"cached":0.2,"out":12}
  and .pricing.default == {"in":0.1,"cached":0.01,"out":0.5}
  and (.pricing_note | contains("不是 Codex/ChatGPT 订阅账单"))' "$template" >/dev/null

# Removing pricing config exercises the generator's built-in per-model and default rates.
cp "$A/config.json" "$fixture/config.with-pricing.json"
jq 'del(.pricing)' "$A/config.json" > "$A/config.without-pricing.json"
mv "$A/config.without-pricing.json" "$A/config.json"
PATH="$fixture/bin:$PATH" TZ=Etc/GMT+12 python3 "$script_dir/gen_dashboard.py"
dashboard_fallback="$(sed 's/^window.DASH=//; s/;$//' "$A/dashboard.data.js")"
jq -e '.cost.today.dollars > 1.8199 and .cost.today.dollars < 1.8201
  and .cost.yesterday.dollars > 14.7999 and .cost.yesterday.dollars < 14.8001
  and (.cost.pricing_note | contains("混合模型 session"))' \
  <<<"$dashboard_fallback" >/dev/null
mv "$fixture/config.with-pricing.json" "$A/config.json"

# 非缓存计费用量单独展示；日预算仍含全部 input + output，不重复加 cached。
# 看板不用 emoji（WSL Chrome 无彩色 emoji 字体，显示成方框）。
jq -e '.summary.billable_daily_tokens == .cost.today.billable and .cost.today.billable <= .cost.today.tokens' <<<"$dashboard_data" >/dev/null \
  || { echo 'not ok - scheduler.test.sh: billable daily tokens missing or above the cached total' >&2; exit 1; }
python3 - "$script_dir/dashboard.html" <<'PY'
import pathlib, re, sys
assert not re.search("[\U0001F300-\U0001FAFF\u2600-\u26FF\u2700-\u27BF]", pathlib.Path(sys.argv[1]).read_text()), "dashboard.html uses emoji glyphs"
PY
grep -Fq 'key:["landing"]' "$script_dir/dashboard.html" || { echo 'not ok - scheduler.test.sh: landing units have no pipeline column' >&2; exit 1; }
override_output="$fixture_supervisor/dashboard.override.js"
MAC_AUTOPILOT_DASHBOARD_OUTPUT="$override_output" PATH="$fixture/bin:$PATH" TZ=Etc/GMT+12 python3 "$script_dir/gen_dashboard.py"
[[ -s "$override_output" ]] || { echo 'not ok - scheduler.test.sh: dashboard output override was ignored' >&2; exit 1; }
# 工作单旅程：时间按干活 / 等合并 / 等主管拆分，合并后未进生产的是"待发布"
cp "$A/units.json" "$fixture/units.saved.json"
cat > "$A/units.json" <<'JSON'
{"units":[{"id":"pr-j","pr":1,"stage":"merged","merge_sha":"0000000000000000000000000000000000000001","history":[
  {"stage":"review","at":"2020-01-01T00:00:00Z"},{"stage":"review-approve","at":"2020-01-01T01:00:00Z"},
  {"stage":"supervisor-escalated","at":"2020-01-01T03:00:00Z"},{"ev":"supervisor-requeue","at":"2020-01-01T04:00:00Z"},
  {"stage":"merged","at":"2020-01-01T05:00:00Z"}]},
 {"id":"pr-k","stage":"closed","history":[]}]}
JSON
MAC_AUTOPILOT_DASHBOARD_OUTPUT="$override_output" PATH="$fixture/bin:$PATH" python3 "$script_dir/gen_dashboard.py"
sed 's/^window.DASH=//; s/;$//' "$override_output" | jq -e '(.units[0].journey | .status == "awaiting-release" and .age_min == 300 and .split_min == {work:120, ready:120, supervisor:60} and .rounds == 0) and .units[1].journey.status == "closed"' >/dev/null \
  || { echo 'not ok - scheduler.test.sh: unit journey split/status wrong' >&2; exit 1; }
# 上线按改动碰到的镜像判：example 改动在 example 镜像发布前不算上线，哪怕别的镜像已发布到更新的提交
rel="$fixture/rel-repo"; mkdir -p "$rel/packages/example-pack/src" "$rel/packages/example-admin/src"
git -C "$rel" init -q && git -C "$rel" config user.email t@t && git -C "$rel" config user.name t
echo 0 > "$rel/README"; git -C "$rel" add -A; git -C "$rel" commit -qm base; rel_base="$(git -C "$rel" rev-parse HEAD)"
echo 1 > "$rel/packages/example-pack/src/a.ts"; git -C "$rel" add -A; git -C "$rel" commit -qm example; rel_example="$(git -C "$rel" rev-parse HEAD)"
echo 2 > "$rel/packages/example-admin/src/b.ts"; git -C "$rel" add -A; git -C "$rel" commit -qm admin; rel_admin="$(git -C "$rel" rev-parse HEAD)"
# The dashboard resolves release status through the authoritative image selector.
# Keep its boundary isolated while exercising real commit ancestry and replica evidence.
mkdir -p "$rel/scripts" "$rel/engine"
cat > "$rel/scripts/production-image-contract.json" <<'JSON'
{"images":[{"name":"example-pack"},{"name":"example-admin"}]}
JSON
cat > "$rel/engine/changed-images.mjs" <<JS
const images = {
  "$rel_example": ["example-pack"],
  "$rel_admin": ["example-admin"],
};
const touched = images[process.argv[3]];
if (process.argv.length !== 4 || !touched) process.exit(1);
process.stdout.write(touched.join("\\n") + "\\n");
JS
cat > "$fixture/bin/ssh" <<SH
#!/usr/bin/env bash
echo "reg/example-pack:live /srv/app/releases/main-${rel_base:0:12}/compose.yml"
echo "reg/example-admin:live /srv/app/releases/main-${rel_admin:0:12}/compose.yml"
SH
deployment_fixture="$fixture/deployments.json"
cat > "$deployment_fixture" <<JSON
[{"id":1,"sha":"$rel_admin","payload":{"images":{"example-pack":"sha256:example","example-admin":"sha256:admin"},"image_shas":{"example-pack":"$rel_base","example-admin":"$rel_admin"}}}]
JSON
cat > "$A/units.json" <<JSON
{"units":[{"id":"pr-example","pr":2,"stage":"merged","merge_sha":"$rel_example","history":[]},
 {"id":"pr-admin","pr":3,"stage":"merged","merge_sha":"$rel_admin","history":[]},
 {"id":"pr-wait","pr":4,"stage":"blocked-external","blocked_on":9,"history":[]},{"id":"pr-sup","pr":5,"stage":"supervisor-review","history":[]}]}
JSON
DEPLOYMENT_FIXTURE="$deployment_fixture" MAC_AUTOPILOT_ROOT="$rel" MAC_AUTOPILOT_DASHBOARD_OUTPUT="$override_output" PATH="$fixture/bin:$PATH" python3 "$script_dir/gen_dashboard.py"
sed 's/^window.DASH=//; s/;$//' "$override_output" | jq -e '([.units[] | {(.id): .journey.status}] | add) == {"pr-example":"awaiting-release","pr-admin":"released","pr-wait":"blocked","pr-sup":"waiting"}' >/dev/null \
  || { echo "not ok - scheduler.test.sh: release status ignores the touched image ($(sed 's/^window.DASH=//; s/;$//' "$override_output" | jq -c '[.units[] | {(.id): .journey.status}]'))" >&2; exit 1; }
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/ssh"
mv "$fixture/units.saved.json" "$A/units.json"
grep -Fq '(u.journey||{}).status)).length' "$script_dir/dashboard.html" || { echo 'not ok - scheduler.test.sh: in-flight card counts closed/done units' >&2; exit 1; }

# 集成测试左移：repair 与产品 implement 的 prompt 都带本机测试库规则；测试库不可用时照常 push，不卡交付。
[[ "$(grep -h '${INTEGRATION_RULE}' "$script_dir/scheduler.sh" "$script_dir"/scheduler.d/*.sh | wc -l)" -ge 2 ]] || { echo 'not ok - scheduler.test.sh: repair/implement prompts lack the local integration-test rule' >&2; exit 1; }
grep -E '^INTEGRATION_RULE=.*RUN_INTEGRATION=1.*照常 push' "$script_dir/scheduler.sh" >/dev/null || { echo 'not ok - scheduler.test.sh: integration rule must run tests locally yet never block the push' >&2; exit 1; }
# 优化类 ticket 先核实前提（#4370）：两条车道的 implement prompt 都带测量规则。
[[ "$(grep -h 'OPT_PREMISE_RULE}' "$script_dir/scheduler.sh" "$script_dir"/scheduler.d/*.sh | wc -l)" -ge 2 ]] || { echo 'not ok - scheduler.test.sh: implement prompts lack the optimization-premise rule' >&2; exit 1; }
grep -A3 "^OPT_PREMISE_RULE=" "$script_dir/scheduler.sh" | grep -q "测量窗口从被测机制最后一次改动之后开始" \
  || { echo 'not ok - scheduler.test.sh: the optimization-premise rule must bound the measurement window by the mechanism last change' >&2; exit 1; }
# Exercise the actual tick with external commands isolated from GitHub, git and Codex.
# Fake commands cover only the fixture repository; unexpected external calls fail.
export TZ=UTC SESSION_TZ=UTC
TODAY="$(date -u +%Y-%m-%d)"
session_day="${TODAY//-//}"
tick_gh() {
  printf 'gh %s\n' "$*" >> "$TF/calls"
  case "$1 $2" in
    # #4725 条件请求包装（gh_api_cached）发出的 `gh api -i [-H …] …`：剥掉 -i/-H 后按原样
    # 递归分发到下面的既有分支（会多记一行去掉 -i 的调用），再用 200 + ETag 头信封包一层。
    'api -i')
      local rest=() skip_next=0 arg body
      for arg in "$@"; do
        (( skip_next )) && { skip_next=0; continue; }
        case "$arg" in
          -i) ;;
          -H) skip_next=1 ;;
          *) rest+=("$arg") ;;
        esac
      done
      body="$(tick_gh "${rest[@]}")" || return $?
      printf 'HTTP/2.0 200 OK\nEtag: "stub"\n\n%s\n' "$body"
      return 0 ;;
    'run list')
      if [[ -f "$TF/ci-admission-runs.json" && "$*" == *'--limit 300 --json databaseId,status,event,headBranch,headSha,workflowName'* ]]; then
        cat "$TF/ci-admission-runs.json"
        return 0
      fi
      if [[ "$*" == *'--jq'* ]]; then
        [[ "$*" == *'.[0].databaseId'* ]] && echo 701
        return 0
      fi
      local sha="" previous="" arg n
      for arg in "$@"; do [[ "$previous" == --commit ]] && sha="$arg"; previous="$arg"; done
      if [[ "$*" == *'--workflow'* && -z "$sha" ]]; then
        if [[ "$*" == *'Pipeline suites'* && -f "$TF/main-suites.json" ]]; then
          cat "$TF/main-suites.json"
          return 0
        fi
        # The per-tick listing of main's runs: the fixture run attached to the main tip and to every merge commit a PR number maps to.
        local -a shas=("$(cat "$TF/main-sha")")
        for n in $(seq 1 300); do shas+=("$(printf '%040x' "$n")"); done
        command jq -n --slurpfile r "$TF/run.json" '[$ARGS.positional[] as $s | $r[0] + {headSha:$s}]' --args "${shas[@]}"
        return
      fi
      [[ -n "$sha" ]] || { echo '[]'; return; }
      command jq --arg sha "$sha" '[. + {headSha:$sha}]' "$TF/run.json"
      ;;
    'run view') [[ ! -f "$TF/log-unavailable" ]] || return 1; cat "$TF/failed.log" ;;
    'run rerun') echo "rerun $3" >> "$TF/actions"; [[ ! -f "$TF/rerun-unconfirmed" ]] ;;
    'issue view')
      if [[ -f "$TF/size-recut-mode" && "$*" == *'--json number,labels'* ]]; then
        command jq -cn --argjson n "$3" '{number:$n,labels:[{name:"ready-for-agent"}]}'
        return 0
      fi
      if [[ "$*" == *'--json number,title,state,labels'* || "$*" == *'--json number,title,body,state,labels'* ]]; then
        if [[ -f "$TF/issues/$3.json" ]]; then
          cat "$TF/issues/$3.json"
        elif [[ -f "$TF/intake-issue.json" ]]; then
          command jq '.state = (.state // "OPEN")' "$TF/intake-issue.json"
        else
          echo "missing issue fixture #$3" >&2
          return 97
        fi
        return 0
      fi
      if [[ -f "$TF/intake-issue.json" && ( "$*" == *'--json state,title,body'* || "$*" == *'--json number,title,body'* ) ]]; then
        command jq '.state = (.state // "OPEN")' "$TF/intake-issue.json"
        return 0
      fi
      [[ "$*" == *'--json labels -q .labels[].name'* ]] || {
        echo "unexpected gh call: $*" >&2
        return 97
      }
      [[ ! -f "$TF/size-recut-mode" ]] || echo ready-for-agent
      return 0
      ;;
    'pr checks')
      if [[ -f "$TF/pipeline-ci-adoption" ]]; then
        local started_at
        case "$(cat "$TF/pipeline-ci-adoption")" in
          old) started_at='2026-10-01T00:00:00Z' ;;
          fresh) started_at='2099-01-01T00:00:00Z' ;;
          *) echo "unexpected adoption phase: $(cat "$TF/pipeline-ci-adoption")" >&2; return 97 ;;
        esac
        command jq -cn --arg started_at "$started_at" '[
          {name:"Enforce branch delivery policy",bucket:"pass",started_at:$started_at},
          {name:"Required CI gates",bucket:"pass",started_at:$started_at},
          {name:"Required contract gates",bucket:"pass",started_at:$started_at},
          {name:"Example pack PR gate",bucket:"pass",started_at:$started_at},
          {name:"Touched packages PR gate",bucket:"pass",started_at:$started_at},
          {name:"Repo-path regression PR gate",bucket:"pass",started_at:$started_at}
        ]'
        return
      fi
      local check_name=ci
      if [[ -f "$TF/pipeline-prs" ]] && command grep -Fxq "$3" "$TF/pipeline-prs"; then check_name='Pipeline suites'; fi
      if [[ "$3" -gt "$(cat "$TF/dead-through")" ]]; then
        printf '[{"name":"%s","bucket":"pass"}]\n' "$check_name"
      else
        printf '[{"name":"%s","bucket":"pending"}]\n' "$check_name"
      fi ;;
    'pr merge')
      # Real-head fixtures (rule-lane) keep main on a commit the real rule git knows;
      # printf SHAs stay for fixtures that never run real git against main.
      if [[ -f "$TF/pr-head-$3" ]]; then cat "$TF/pr-head-$3" > "$TF/main-sha"; else printf '%040x\n' "$3" > "$TF/main-sha"; fi
      echo "merge $3" >> "$TF/actions" ;;
    'pr edit') echo "pr edit ${*:3}" >> "$TF/actions" ;;
    'issue edit')
      if [[ -f "$TF/fail-issue-edit" && "$3" == "$(cat "$TF/fail-issue-edit")" ]]; then
        echo "issue edit failed for #$3" >&2
        return 1
      fi
      echo "$1 $2 ${*:3}" >> "$TF/actions" ;;
    'pr comment')
      echo "$1 $2 ${*:3}" >> "$TF/actions"
      [[ ! -f "$TF/fail-pr-comment" || "$3" != "$(cat "$TF/fail-pr-comment")" ]] ;;
    'issue comment'|'issue close'|'pr close'|'pr ready') echo "$1 $2 ${*:3}" >> "$TF/actions" ;;
    'pr view')
      case "$*" in
        *'--json number,headRefName,title,body,state'*)
          local view_fixture="$TF/handoff-lookup.json" fixture_branch
          [[ ! -f "$TF/handoff-pr-view.json" ]] || view_fixture="$TF/handoff-pr-view.json"
          if [[ -f "$view_fixture" ]]; then
            command jq -ce --argjson n "$3" '.[] | select(.number==$n) | .state = (.state // "OPEN") | if has("labels") then . else . + {labels:[]} end' "$view_fixture"
          elif [[ -f "$TF/handoff-lookup-fail" ]]; then
            return 1
          else
            fixture_branch="$(command jq -r --argjson n "$3" '[.units[] | select(.pr==$n) | .branch // empty][0] // empty' "$TF/supervisor/autopi/units.json")"
            [[ -n "$fixture_branch" || ! -f "$TF/agent-home/state/$3.json" ]] || fixture_branch="$(command jq -r '.scheduler_handoff.open_branch // empty' "$TF/agent-home/state/$3.json")"
            command jq -cn --argjson n "$3" --arg branch "${fixture_branch:-agent/issue-$3}" '{number:$n,headRefName:$branch,title:"fixture",body:"",state:"OPEN",labels:[]}'
          fi ;;
        *files*) printf 'packages/fixture/src/index.ts\n' ;;
        *number,state,baseRefName,mergeCommit,mergedAt*)
          command jq -cn --argjson n "$3" --arg oid "$(printf '%040x' "$3")" \
            '{number:$n,state:"MERGED",baseRefName:"main",mergeCommit:{oid:$oid},mergedAt:"2026-10-29T00:00:00Z"}' ;;
        *mergeCommit*)
          if [[ -f "$TF/no-merge-sha" ]]; then echo ''
          elif [[ -f "$TF/pr-head-$3" ]]; then cat "$TF/pr-head-$3"
          else printf '%040x\n' "$3"; fi ;;
        *headRefOid*)
          if [[ -f "$TF/pr-head-$3" ]]; then cat "$TF/pr-head-$3"
          elif [[ -f "$TF/eval-pr" && "$3" == "$(cat "$TF/eval-pr")" ]]; then cat "$TF/eval-pr-head"
          else printf '%040x\n' "$3"; fi ;;
        *mergedAt*) echo '2026-10-17T00:00:00Z' ;;
        *state*) if [[ -f "$TF/closed-prs" ]] && grep -Fxq "$3" "$TF/closed-prs"; then echo CLOSED; else echo OPEN; fi ;;
        *headRefName*) echo fix/token-fixture ;;
        *baseRefName*) echo main ;;
      esac ;;
    'pr list')
      if [[ -f "$TF/aged-prs.json" && "$*" == *'--json number,headRefName,headRefOid,createdAt,baseRefName'* ]]; then cat "$TF/aged-prs.json"; return; fi
      if [[ -f "$TF/handoff-lookup-fail" && "$*" == *'--json number,headRefName,title,body'* ]]; then return 1; fi
      # The tick census is the open-PR census (948e839b2), so a failing handoff lookup fails that listing too.
      if [[ -f "$TF/handoff-lookup-fail" && "$*" == *statusCheckRollup* ]]; then return 1; fi
      if [[ -f "$TF/handoff-lookup.json" && "$*" == *'--json number,headRefName,title,body'* ]]; then
        if [[ "$*" == *'--head '* ]]; then
          command jq -c '[.[] | select(.headRefName=="agent/issue-779") | if has("labels") then . else . + {labels:[]} end]' "$TF/handoff-lookup.json"
        else
          command jq -c 'map(if has("labels") then . else . + {labels:[]} end)' "$TF/handoff-lookup.json"
        fi
        return
      fi
      if [[ -f "$TF/pr-census.json" && "$*" == *statusCheckRollup* ]]; then
        # The census carries the PR body (the handoff finds a PR through its "Refs #N" line); take it from the lookup fixture when the row has none.
        if [[ -f "$TF/handoff-lookup.json" ]]; then
          command jq -c --slurpfile RU "$TF/handoff-lookup.json" 'map(. as $r | . + {body: ($r.body // (first($RU[0][] | select(.number == $r.number) | .body) // ""))})' "$TF/pr-census.json"
        else cat "$TF/pr-census.json"; fi
        return
      fi
      if [[ -f "$TF/busy-pr" && "$*" == *'--json headRefName,title,body'* ]]; then
        cat "$TF/busy-pr"
        return
      fi
      if [[ "$*" == *statusCheckRollup* ]]; then
        # The census: check rows come from the per-PR `pr checks` fixture above, heads from the `pr view` fixture.
        local query="." rows='[]' n c previous="" arg
        for arg in "$@"; do [[ "$previous" == --jq ]] && query="$arg"; previous="$arg"; done
        for n in $(command jq -r '.units[] | select(.stage == "ready-to-merge" and .pr != null) | .pr' "$TF/supervisor/autopi/units.json"); do
          c="$(tick_gh pr checks "$n" --json name,bucket,link)"
          rows="$(command jq -c --argjson n "$n" --arg head "$(tick_gh pr view "$n" --json headRefOid --jq .headRefOid)" --argjson c "${c:-[]}" 'if any(.[]; .number == $n) then . else . + [{number: $n, headRefOid: $head, isDraft: false, title: "", labels: [], statusCheckRollup: ($c | map({__typename: "CheckRun", name: .name, detailsUrl: (.link // ""), startedAt: (.started_at // null), status: (if .bucket == "pending" then "IN_PROGRESS" else "COMPLETED" end), conclusion: ({pass: "SUCCESS", fail: "FAILURE", skipping: "SKIPPED", cancel: "CANCELLED"}[.bucket] // null)}))}] end' <<<"$rows")"
        done
        # handoff 夹具的 open PR 也在 census 里（948e839b2 起 handoff 复用 tick census），但只补
        # 没有检查行的 PR，不覆盖 ready-to-merge 单元的 checks。
        if [[ -f "$TF/handoff-lookup.json" ]]; then
          rows="$(command jq -c --slurpfile RU "$TF/handoff-lookup.json" '
            . as $rows
            | ($rows | map(. as $r | . + (([$RU[0][] | select(.number == $r.number)][0] // {}) | {headRefName, title, body} | with_entries(select(.value != null)))))
              + [$RU[0][] | select(.number as $n | ($rows | map(.number) | index($n)) == null)
                   | {number, headRefName, title: (.title // ""), body: (.body // ""), headRefOid: null, isDraft: false, labels: (.labels // []), statusCheckRollup: []}]' <<<"$rows")"
        fi
        command jq -cr "$query" <<<"$rows"
      else
        echo '[]'
      fi ;;
    'issue list')
      if [[ -f "$TF/intake-issue.json" && " $* " == *' --label ready-for-agent '* ]]; then
        command jq -c '[.]' "$TF/intake-issue.json"
      elif [[ -f "$TF/intake-issue.json" && " $* " == *' --label pipeline-system '* ]] \
        && command jq -e 'any(.labels[]; .name=="pipeline-system")' "$TF/intake-issue.json" >/dev/null; then
        command jq -c '[.]' "$TF/intake-issue.json"
      else
        echo '[]'
      fi ;;
    'label list') printf '%s\n' needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded ;;
    'label create') return 0 ;;
    'api repos/example-maintainer/example-repo/issues/'*'/sub_issues?per_page=100')
      issue_number="${2#repos/example-maintainer/example-repo/issues/}"
      issue_number="${issue_number%%/*}"
      [[ -f "$TF/sub-issues-$issue_number.json" ]] || { echo "missing sub-issue fixture #$issue_number" >&2; return 97; }
      cat "$TF/sub-issues-$issue_number.json"
      ;;
    'api graphql')
      if [[ "$*" == *'i9901:'* ]]; then
        if [[ -f "$TF/dependency-closed" ]]; then printf '9901\tCLOSED\tbug\n'; else printf '9901\tOPEN\tbug\n'; fi
      elif [[ "$*" == *'labels(first: 100)'* ]]; then
        # predecessor_candidates batches the blocking issues into one GraphQL call; answer from the issue fixtures.
        local pred_n pred_resp='{}'
        for pred_n in $(grep -oE 'issue\(number: [0-9]+\)' <<<"$*" | grep -oE '[0-9]+'); do
          [[ -f "$TF/issues/$pred_n.json" ]] || continue
          pred_resp="$(command jq -c --argjson r "$pred_resp" '$r + {("i" + (.number | tostring)): {number, title, body: (.body // ""), state: (.state // "OPEN"), labels: {nodes: (.labels // [])}}}' "$TF/issues/$pred_n.json")"
        done
        command jq -cn --argjson r "$pred_resp" '{data: {repository: $r}}'
      else
        echo '{}'
      fi ;;
    'api '*)
      if [[ "$*" == *'actions/runners?per_page=100'* ]]; then
        # PR CI 名额按在线 PR runner 算（60ba960cf）；无夹具时默认一个在线 PR runner
        if [[ -f "$TF/ci-runners.json" ]]; then
          local runners_q="" runners_prev="" arg
          for arg in "$@"; do [[ "$runners_prev" == --jq ]] && runners_q="$arg"; runners_prev="$arg"; done
          command jq -r "${runners_q:-.}" < "$TF/ci-runners.json"
        else
          echo 1
        fi
      elif [[ "$*" =~ actions/runs/([0-9]+)/jobs ]] && [[ -f "$TF/ci-admission-jobs.json" ]]; then
        command jq -c --arg id "${BASH_REMATCH[1]}" '.[$id] // []' "$TF/ci-admission-jobs.json"
      elif [[ "$*" == *'actions/runs?status='* && -f "$TF/ci-admission-runs.json" ]]; then
        command jq -c '.[]' "$TF/ci-admission-runs.json"
      elif [[ "$*" == *'actions/runs?status=queued'* && -f "$TF/queued-pr-runs.json" ]]; then
        command jq -c '.[]' "$TF/queued-pr-runs.json"
      elif [[ "$*" == *'/pulls/'*'/files'* ]]; then
        [[ ! -f "$TF/pr-files-fail" ]] || return 1
        if [[ -f "$TF/pr-files" ]]; then cat "$TF/pr-files"; else echo 'packages/fixture/src/index.ts'; fi
      elif [[ "$*" == *'commits/'*'/status'* ]]; then echo 1
      elif [[ "$*" == *'/comments'* ]]; then echo '[]'
      else echo '{}'; fi ;;
    *) echo "unexpected gh call: $*" >&2; return 97 ;;
  esac
}
tick_git() {
  if [[ "${1:-}" == -C && -f "$TF/real-clone-git" && "${2:-}" == "$TF/clones/"* ]]; then
    command git "$@"
    return
  fi
  [[ "${1:-}" != -C ]] || shift 2
  printf 'git %s\n' "$*" >> "$TF/calls"
  case "${1:-}" in
    -c) shift 2; tick_git "$@" ;;
    ls-remote) [[ "$*" != *--heads* ]] || return 0; printf '%s\trefs/heads/main\n' "$(cat "$TF/main-sha")" ;;
    remote) [[ "${2:-}" != get-url ]] || echo "$TF/origin" ;;
    clone) local destination="${!#}"; mkdir -p "$destination/.git" ;;
    rev-parse)
      case "$*" in
        *FETCH_HEAD*|*refs/autopi/merge-candidates/*)
          if [[ -f "$TF/real-rule-git" ]]; then command git -C "$TF/repo" "$@"
          elif [[ -f "$TF/fetched-head" ]]; then cat "$TF/fetched-head"
          else cat "$TF/main-sha"; fi ;;
        *--is-shallow-repository*) echo false ;;
        *refs/remotes/origin/main*|*HEAD*) cat "$TF/main-sha" ;;
        *--verify*) [[ -f "$TF/aged-head-readable" ]] && cat "$TF/main-sha" || return 1 ;;
        *) return 1 ;;
      esac ;;
    status) return 0 ;;
    log)
      [[ "$*" != *'--format=%H refs/remotes/origin/main'* ]] || { cat "$TF/main-sha"; return; }
      [[ "$*" != *'--format=%B'* ]] || { echo 'fixture product commit'; return; }
      local arg sha
      for arg in "$@"; do
        if [[ "$arg" == --grep=* ]]; then
          sha="${arg#--grep=This reverts commit }"; sha="${sha%%\\.*}"
          command grep -Fx "$sha" "$TF/reverted" || true
        fi
      done ;;
    revert)
      echo "revert $3" >> "$TF/actions"
      [[ ! -f "$TF/fail-revert" || "$3" != "$(cat "$TF/fail-revert")" ]] || return 1
      printf '%s\n' "$3" > "$TF/pending-revert" ;;
    push) cat "$TF/pending-revert" >> "$TF/reverted" ;;
    merge-base)
      if [[ "${2:-}" == --is-ancestor && -f "$TF/ancestry.tsv" ]]; then
        command grep -Fxq "${3:-} ${4:-}" "$TF/ancestry.tsv"
        return
      fi
      return 0 ;;
    merge) [[ "$*" == *--abort* ]] || [[ ! -f "$TF/handoff-conflict" ]] ;;
    cat-file)
      if [[ -f "$TF/real-rule-git" ]]; then command git -C "$TF/repo" "$@"; else return 0; fi ;;
    show)
      if [[ -f "$TF/real-rule-git" ]]; then command git -C "$TF/repo" "$@"; else return 1; fi ;;
    diff|diff-tree)
      if [[ -f "$TF/real-rule-git" ]]; then command git -C "$TF/repo" "$@"; else return 1; fi ;;
    rev-list)
      if [[ -f "$TF/real-rule-git" ]]; then command git -C "$TF/repo" "$@"
      elif [[ -f "$TF/aged-head-readable" ]]; then echo 400
      fi ;;
    cherry) [[ ! -f "$TF/aged-head-readable" ]] || printf '%s\n' '- 0000000000000000000000000000000000000001' ;;
    fetch)
      if [[ -f "$TF/real-rule-git" && "${!#}" == +refs/pull/*/head:refs/autopi/merge-candidates/* ]]; then
        command git -C "$TF/repo" "$@"
      elif [[ -f "$TF/real-rule-git" && "${!#}" == refs/pull/*/head ]]; then
        command git -C "$TF/repo" fetch -q origin "${!#}"
      else
        return 0
      fi ;;
    update-ref) if [[ -f "$TF/real-rule-git" ]]; then command git -C "$TF/repo" "$@"; else return 0; fi ;;
    init|config|checkout|for-each-ref|branch|sparse-checkout) return 0 ;;
    *) echo "unexpected git call: $*" >&2; return 97 ;;
  esac
}
tick_jq() {
  if [[ -f "$TF/corrupt-write" && "$*" == *'.stage="review-pending"'* ]]; then
    case "$(cat "$TF/corrupt-write")" in
      shape) echo '{}' ;;
      drop) command jq "$@" | command jq '.units = .units[1:]' ;;
      concat) command jq "$@" | tee /dev/stdout ;;
    esac
  else
    command jq "$@"
  fi
}
# The shipped policy has roadmap-order on: a stage label only lands on an issue that sits on the roadmap tree.
seed_roadmap_tree() {
  command jq -cn '{roots:[{number:9000,title:"Roadmap",state:"OPEN",labels:["roadmap"],children:[$ARGS.positional[] | {number:tonumber,title:"Issue",state:"OPEN",labels:[],children:[]}]}]}' \
    --args "$@" > "$TF/roadmap-tree.json"
}

new_tick_fixture() {
  TF="$test_env_root/tick-$1"; export TF
  mkdir -p "$TF/repo" "$TF/supervisor/autopi/alerts" "$TF/sessions" "$TF/bin"
  command jq --arg wt "$TF/clones" '.release_train.enabled=false | .max_workers=0 | .auto_merge=false | .auto_dispatch_new_prs=false | .issue_intake.enabled=false | .focus_mode="all" | .worktree_root=$wt' "$template" > "$TF/supervisor/autopi/config.json"
  echo '{"units":[]}' > "$TF/supervisor/autopi/units.json"
  echo '{"workers":[]}' > "$TF/supervisor/autopi/workers.json"
  echo '{"databaseId":701,"attempt":1,"status":"completed","conclusion":"failure","createdAt":"2026-10-18T00:00:00Z"}' > "$TF/run.json"
  printf '%040x\n' 100 > "$TF/main-sha"
  echo 0 > "$TF/dead-through"
  : > "$TF/failed.log"; : > "$TF/actions"; : > "$TF/calls"; : > "$TF/reverted"
  cat > "$TF/bin/codex" <<'SH'
#!/usr/bin/env bash
[[ -f "$TF/allow-dispatch" ]] || { echo 'unexpected worker dispatch' >&2; exit 97; }
# supervisor 裁决 worker（#4369）：按 $TF/supervise-action 写六动作报告。
if [[ "$*" == *"--output-last-message"* && "$*" == *" -p "* ]]; then
  echo "codex $*" >> "$TF/codex.calls"
  out="" prev=""
  for a in "$@"; do [[ "$prev" == --output-last-message ]] && out="$a"; prev="$a"; done
  action="$(cat "$TF/supervise-action" 2>/dev/null || echo requeue)"
  printf 'ACTION: %s\n' "$action" > "$out"
  [[ "$action" != needs-info ]] || printf 'QUESTION: 这批单据要对接哪个外部系统？\n' >> "$out"
  [[ "$action" != requeue ]] || printf 'REASON: 报告缺行\nGUIDANCE: 先 git merge origin/main 再按类别修复\n' >> "$out"
fi
echo 'session id: 11111111-2222-3333-4444-555555555555'
SH
  cat > "$TF/bin/gh-real" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
tick_gh "$@"
SH
  for tool in systemctl systemd-run; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" > "$TF/unexpected-host"\nexit 97\n' "$tool" > "$TF/bin/$tool"
  done
  cat > "$TF/bin/systemctl" <<'SH'
#!/usr/bin/env bash
if [[ "$*" =~ zf-recut-([0-9]+) ]]; then
  [[ ! -e "$TF/recut-inactive-${BASH_REMATCH[1]}" ]]
  exit $?
fi
echo 'unexpected host command in tick fixture' > "$TF/unexpected-host"
exit 97
SH
  chmod +x "$TF/bin/"*
  mkdir -p "$TF/repo/engine"
  cp -a "$script_dir" "$TF/repo/engine/mac-autopilot"
  copy_agent_library "$TF/repo/engine"
  cp "$TF/supervisor/autopi/config.json" "$TF/repo/engine/mac-autopilot/config.template.json"
  # merge_candidates 每拍经 $HERE/../../ci/ 调 pr-required-aggregate.mjs（16e097913 起按 run/时间
  # 取同 head 最新检查行）；夹具 repo 是 engine 子集，需一并带上。
  mkdir -p "$TF/repo/engine/ci"
  cp "$repo_root/engine/ci/pr-required-aggregate.mjs" "$TF/repo/engine/ci/pr-required-aggregate.mjs"
  echo '# fixture: dashboard has its own integration test' > "$TF/repo/engine/mac-autopilot/gen_dashboard.py"
  # These tick fixtures exercise the state machine; health/spend have their own suites.
  rm "$TF/repo/engine/mac-autopilot/node_health.py" "$TF/repo/engine/mac-autopilot/ci_spend.py"
}
enable_rule_lane_fixture() {
  cp "$repo_root/engine/rule-lane.sh" "$TF/repo/engine/rule-lane.sh"
  mkdir -p "$TF/repo/engine/state"
  cp "$repo_root/engine/state/rule-files.json" "$TF/repo/engine/state/rule-files.json"
  command git -C "$TF/repo" init -q -b main
  command git -C "$TF/repo" config user.name fixture
  command git -C "$TF/repo" config user.email fixture@example.invalid
  command git -C "$TF/repo" add engine/state/rule-files.json engine/mac-autopilot/config.template.json
  command git -C "$TF/repo" commit -qm 'rule-lane fixture main'
  command git init -q --bare "$TF/origin.git"
  command git -C "$TF/repo" remote add origin "$TF/origin.git"
  command git -C "$TF/repo" push -q origin main:refs/heads/main
  command git -C "$TF/repo" rev-parse HEAD > "$TF/main-sha"
  touch "$TF/real-rule-git"
}
prepare_tick_config() {
  [[ -f "$TF/config-drift" ]] || cp "$TF/supervisor/autopi/config.json" "$TF/repo/engine/mac-autopilot/config.template.json"
}
tick() (
  unset AUTOPI_TEST_LIBRARY_ONLY
  unset GH_TOKEN
  [[ "${TYPESAFE_TEST_MOCK:-0}" == 1 ]] || unset TYPESAFE_API_KEY
  prepare_tick_config
  export MAC_AUTOPILOT_ROOT="$TF/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$TF/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$TF/supervisor/autopi" CODEX_SESSIONS_DIR="$TF/sessions"
  export AGENT_HOME="$TF/agent-home" AUTOPILOT_PAUSE_FILE="$TF/pause"
  export AUTOPILOT_POLICY_SCRIPT="${AUTOPILOT_POLICY_SCRIPT:-$POLICY_FIXTURE}"
  export AP_SYSTEM_TMP="$TF/tmp" AP_SYSTEM_TMP_FS=fixture
  export ZF_GH_REAL_CLI="$TF/bin/gh-real" ZF_TEST_EVIDENCE_LEDGER="$TF/supervisor/test-evidence.jsonl"
  [[ ! -f "$TF/roadmap-tree.json" ]] || export ZF_ROADMAP_TREE_CACHE_FILE="$TF/roadmap-tree.json"
  git() { tick_git "$@"; }; jq() { tick_jq "$@"; }
  # A dispatched fixture worker stays alive across intra-tick refills until its output is ready.
  ps() {
    if [[ "${TF_REAL_PS:-0}" == 1 ]]; then command ps "$@"; return; fi
    [[ -f "$TF/worker-alive" ]] || return 1
    echo 'codex fixture worker'
  }
  node() {
    if [[ "${TYPESAFE_TEST_MOCK:-0}" == 1 && "$1" == "$TF/repo/engine/ts-judge.mjs" ]]; then
      case "${2:-}" in
        f12) command node "$TYPESAFE_TEST_DRIVER" f12 ;;
        record|record-adoption) command node "$TYPESAFE_JUDGE_SCRIPT" "$2" "${@:3}" ;;
        *) command node "$@" ;;
      esac
    else
      command node "$@"
    fi
  }
  export PATH="$repo_root/engine/gh-shim:$TF/bin:$PATH" AUTOPI_VIEWS_INLINE=true
  export -f git jq node ps tick_gh tick_git tick_jq
  # 额外参数原样传给 scheduler.sh（如 --refill）；不带参数就是一整拍慢 tick。
  local rc=0
  bash "$TF/repo/engine/mac-autopilot/scheduler.sh" "$@" > "$TF/tick.out" 2>&1 || rc=$?
  if (( rc != 0 && rc != 75 )); then cat "$TF/tick.out" >&2; return 1; fi
  [[ ! -e "$TF/unexpected-host" ]] || { cat "$TF/unexpected-host" >&2; return 1; }
  return "$rc"
)

# Single-case filter (#4480): SCHED_TEST_CASE=<case> runs only that case and
# prints one summary line; without it every case runs in file order. The
# prelude above (shared fixtures, helpers, static checks) always runs.
sched_case_names=""
sched_run_case() {
  local name="$1"
  sched_case_names="$sched_case_names ${name//_/-}"
  if [ -n "${SCHED_TEST_CASE:-}" ] && [ "${SCHED_TEST_CASE//-/_}" != "$name" ]; then return 0; fi
  sched_case_$name
  if [ -n "${SCHED_TEST_CASE:-}" ]; then
    echo "scheduler.test.sh: case ${name//_/-} PASS"
    exit 0
  fi
}

sched_case_ci_admission_priority() {
new_tick_fixture ci-admission-priority
command jq '.precheck=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
hotfix_sha="$(printf '%040x' 901)"
normal_sha="$(printf '%040x' 902)"
review_sha="$(printf '%040x' 903)"
command jq -n --arg hot "$hotfix_sha" --arg normal "$normal_sha" --arg review "$review_sha" \
  '{units:[
    {id:"normal-active",pr:901,branch:"agent/issue-901",stage:"ready-to-merge",approved_sha:$normal,ci_wip_wait:$normal,ready_since:1,product_paths:true,history:[]},
    {id:"normal-review",pr:902,branch:"agent/issue-902",stage:"review-pending",history:[]}
  ]}' > "$TF/supervisor/autopi/units.json"
command jq -n --arg hot "$hotfix_sha" --arg normal "$normal_sha" \
  '[
    {number:900,headRefName:"agent/issue-hf-900",headRefOid:$hot,isDraft:false,title:"hotfix",labels:[{name:"hotfix"}],statusCheckRollup:[]},
    {number:901,headRefName:"agent/issue-901",headRefOid:$normal,isDraft:false,title:"normal",labels:[],statusCheckRollup:[]}
  ]' > "$TF/pr-census.json"
# 名额按在线 PR runner 折算（60ba960cf）：这一拍 PR runner 全离线（postsubmit 池不算）→ 0 个空槽
command jq -n '{"runners":[{"id":3,"status":"online","labels":[{"name":"cihost-ci-postsubmit"}]},{"id":4,"status":"offline","labels":[{"name":"cihost-ci"}]}]}' > "$TF/ci-runners.json"
command jq -n --arg hot "$hotfix_sha" --arg normal "$normal_sha" --arg review "$review_sha" \
  '[
    {databaseId:901,status:"queued",event:"pull_request",headBranch:"agent/issue-hf-900",headSha:$hot,workflowName:"CI"},
    {databaseId:902,status:"in_progress",event:"pull_request",headBranch:"agent/issue-901",headSha:$normal,workflowName:"CI"},
    {databaseId:903,status:"queued",event:"pull_request",headBranch:"agent/issue-902",headSha:$review,workflowName:"CI"}
  ]' > "$TF/ci-admission-runs.json"
command jq -n '{"902":[{"status":"queued"}]}' > "$TF/ci-admission-jobs.json"
mkdir -p "$TF/repo/engine/night"
cat > "$TF/repo/engine/night/main-ci-recovery.sh" <<'SH'
#!/usr/bin/env bash
[[ "$1" == cancel-run ]] || exit 97
printf '%s %s\n' "$2" "${ZF_CANCEL_REASON:-}" >> "$TF/ci-cancellations"
SH
tick
[[ "$(sort "$TF/ci-cancellations")" == $'902 ci wip\n903 ci deferred' ]] \
  || { echo "scheduler.test.sh: controller cancelled the wrong CI runs: $(cat "$TF/ci-cancellations" 2>/dev/null)" >&2; exit 1; }
command jq -e --arg hot "$hotfix_sha" --arg normal "$normal_sha" --arg review "$review_sha" '
  .units as $units
  | ([$units[] | select(.pr == 900)] | length == 0)
  and ([$units[] | select(.id == "normal-active")][0] | .ci_held_sha == null and .ci_wip_wait == $normal)
  and ([$units[] | select(.id == "normal-review")][0] | .ci_deferred_sha == $review)
' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'scheduler.test.sh: hotfix admission state or lower-priority cancellation was wrong' >&2; exit 1; }
! grep -Fq 'ci hold' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: priority hold fired after retirement (#4625)' >&2; exit 1; }
# 第二拍：PR runner 恢复在线（2 个），热修 run 已在 runner 1 上跑（busy=true，6adc3ba00 起按
# runner busy 折算名额）→ 名额 = 2 − 1 = 1，等名额的 normal-active 补进空槽起跑 CI；
# 名额算术由日志与 slot 1/1 钉住。
command jq -n '{"runners":[{"id":1,"status":"online","busy":true,"labels":[{"name":"cihost-ci"}]},{"id":2,"status":"online","busy":false,"labels":[{"name":"vecta-suites"}]},{"id":3,"status":"online","busy":false,"labels":[{"name":"cihost-ci-postsubmit"}]}]}' > "$TF/ci-runners.json"
command jq -n --arg hot "$hotfix_sha" --arg normal "$normal_sha" --arg review "$review_sha" \
  '[
    {databaseId:901,status:"in_progress",event:"pull_request",headBranch:"agent/issue-hf-900",headSha:$hot,workflowName:"CI"},
    {databaseId:902,status:"queued",event:"pull_request",headBranch:"agent/issue-901",headSha:$normal,workflowName:"CI"},
    {databaseId:903,status:"queued",event:"pull_request",headBranch:"agent/issue-902",headSha:$review,workflowName:"CI"}
  ]' > "$TF/ci-admission-runs.json"
command jq -n '{"901":[{"status":"in_progress","runner_id":1}]}' > "$TF/ci-admission-jobs.json"
tick
command jq -e --arg normal "$normal_sha" '
  ([.units[] | select(.id == "normal-active")][0]
    | .ci_wip_wait == null and .approved_sha == $normal
    and ([.history[] | select(.stage == "ci-wip-start" and .result == "slot 1/1")] | length == 1))
' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'scheduler.test.sh: a freed runner slot did not start the waiting unit CI' >&2; exit 1; }
grep -Fq 'ci wip: 1 free PR runner slot(s)' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: the CI slot count was not sized from free PR runners' >&2; exit 1; }
}
sched_run_case ci_admission_priority

sched_case_pipeline_ci_adoption() {
# A full scheduler tick adopts a ready-to-merge non-agent branch, rejects checks
# older than the label event, then merges only after fresh aggregate passes.
new_tick_fixture pipeline-ci-adoption
enable_rule_lane_fixture
command git -C "$TF/repo" checkout -qb pr-adopt
mkdir -p "$TF/repo/packages/fixture/src"
printf 'export const adopted = true\n' > "$TF/repo/packages/fixture/src/index.ts"
command git -C "$TF/repo" add packages/fixture/src/index.ts
command git -C "$TF/repo" commit -qm 'adopted ordinary source'
adopted_head="$(command git -C "$TF/repo" rev-parse HEAD)"
command git -C "$TF/repo" push -q origin "$adopted_head:refs/pull/50/head"
printf '%s\n' "$adopted_head" > "$TF/pr-head-50"
command git -C "$TF/repo" checkout -q main
printf '%s\n' '{"databaseId":701,"attempt":1,"status":"completed","conclusion":"success","createdAt":"2026-10-29T00:00:00Z"}' > "$TF/run.json"
printf '%s\n' '{"required":["Enforce branch delivery policy","Required CI gates","Required contract gates"]}' > "$TF/required-pr-checks.json"
export REQUIRED_PR_CHECKS_FILE="$TF/required-pr-checks.json"
command jq '.auto_merge=true' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
command jq --arg sha "$adopted_head" \
  '.units=[{id:"pr-adopt",pr:50,lane:"pr",branch:"fix/dispatch-unique-sku-unit",stage:"ready-to-merge",approved_sha:$sha,history:[]}]' \
  "$TF/supervisor/autopi/units.json" > "$TF/units.tmp"
mv "$TF/units.tmp" "$TF/supervisor/autopi/units.json"
tick
grep -Fq 'gh pr edit 50 --add-label pipeline-ci' "$TF/calls" \
  || { echo 'scheduler.test.sh: tick did not label the adopted non-agent PR' >&2; exit 1; }
command jq -e --arg sha "$adopted_head" \
  '.units[0].ci_adopt_head == $sha and (.units[0].ci_adopt_at | type == "string") and .units[0].stage == "ready-to-merge"' \
  "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'scheduler.test.sh: adoption was not recorded or merged before CI ran' >&2; exit 1; }
if grep -q '^merge 50$' "$TF/actions"; then
  echo 'scheduler.test.sh: tick merged before the adopted branch had post-label checks' >&2; exit 1
fi
printf 'old\n' > "$TF/pipeline-ci-adoption"
tick
if grep -q '^merge 50$' "$TF/actions"; then
  echo 'scheduler.test.sh: tick reused pre-adoption aggregate passes' >&2; exit 1
fi
grep -Fq 'required checks without a real pass:' "$TF/supervisor/autopi/scheduler.log" \
  || { echo "scheduler.test.sh: stale adopted checks did not hold the merge" >&2; echo "--- scheduler.log ---" >&2; tail -20 "$TF/supervisor/autopi/scheduler.log" >&2; echo "--- actions ---" >&2; cat "$TF/actions" >&2; exit 1; }
printf 'fresh\n' > "$TF/pipeline-ci-adoption"
tick
[[ "$(command jq -r '.units[0].stage' "$TF/supervisor/autopi/units.json")" == merged ]] \
  || { echo 'scheduler.test.sh: fresh aggregate passes did not release the adopted PR' >&2; exit 1; }
grep -q '^merge 50$' "$TF/actions" \
  || { echo 'scheduler.test.sh: merge action for the adopted PR was not observed' >&2; exit 1; }
[[ "$(grep -c '^gh pr edit 50 --add-label pipeline-ci$' "$TF/calls")" == 1 ]] \
  || { echo 'scheduler.test.sh: repeated ticks re-applied the adoption label' >&2; exit 1; }
export REQUIRED_PR_CHECKS_FILE="$test_env_root/required-pr-checks.json"
}
sched_run_case pipeline_ci_adoption

sched_case_rule_lane() {
# One supervisor tick (#4548): the same rule-file diff with a
# valid replay trailer merges on a supervisor branch, is refused and moved to the
# supervisor queue on unit branches, and stays unmerged when the trailer or report is
# missing or invalid. Unavailable diffs and failed repair comments keep holding.
new_tick_fixture rule-lane
enable_rule_lane_fixture
touch "$TF/supervisor/test-evidence.jsonl"
command jq '.auto_merge=true' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
command git -C "$TF/repo" checkout -qb pr-rule-report
command jq '.auto_merge=true' "$TF/repo/engine/mac-autopilot/config.template.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/repo/engine/mac-autopilot/config.template.json"
mkdir -p "$TF/repo/docs/agents/rule-replays"
printf '%s\n' '{"schema":"zf-control-rule-replay/v1","falseStops":[]}' > "$TF/repo/docs/agents/rule-replays/zero.json"
command git -C "$TF/repo" add engine/mac-autopilot/config.template.json docs/agents/rule-replays/zero.json
command git -C "$TF/repo" commit -qm 'adjust scheduler rule' -m 'Rule-Replay: docs/agents/rule-replays/zero.json'
rule_head="$(command git -C "$TF/repo" rev-parse HEAD)"
command git -C "$TF/repo" push -q origin "$rule_head:refs/pull/51/head"
command git -C "$TF/repo" show -s --format=%B "$rule_head" | grep -Fq 'Rule-Replay: docs/agents/rule-replays/zero.json'
printf '%s\n' "$rule_head" > "$TF/pr-head-51"
command git -C "$TF/repo" checkout -q main
command git -C "$TF/repo" push -q origin "$rule_head:refs/pull/53/head"
printf '%s\n' "$rule_head" > "$TF/pr-head-53"
# The same committed diff offered as the supervisor's own PR (#4548: let the diff through, then read the report).
command git -C "$TF/repo" push -q origin "$rule_head:refs/pull/55/head"
printf '%s\n' "$rule_head" > "$TF/pr-head-55"
printf '53\n' > "$TF/fail-pr-comment"

command git -C "$TF/repo" checkout -qb pr-rule-missing
command jq '.auto_merge=true' "$TF/repo/engine/mac-autopilot/config.template.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/repo/engine/mac-autopilot/config.template.json"
command git -C "$TF/repo" add engine/mac-autopilot/config.template.json
command git -C "$TF/repo" commit -qm 'adjust scheduler rule without a report'
missing_head="$(command git -C "$TF/repo" rev-parse HEAD)"
command git -C "$TF/repo" push -q origin "$missing_head:refs/pull/56/head"
printf '%s\n' "$missing_head" > "$TF/pr-head-56"
command git -C "$TF/repo" checkout -q main

command git -C "$TF/repo" checkout -qb pr-rule-invalid
command jq '.auto_merge=true' "$TF/repo/engine/mac-autopilot/config.template.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/repo/engine/mac-autopilot/config.template.json"
mkdir -p "$TF/repo/docs/agents/rule-replays"
printf '%s\n' '{"schema":"zf-control-rule-replay/v2","falseStops":[]}' > "$TF/repo/docs/agents/rule-replays/bad.json"
command git -C "$TF/repo" add engine/mac-autopilot/config.template.json docs/agents/rule-replays/bad.json
command git -C "$TF/repo" commit -qm 'adjust scheduler rule' -m 'Rule-Replay: docs/agents/rule-replays/bad.json'
invalid_head="$(command git -C "$TF/repo" rev-parse HEAD)"
command git -C "$TF/repo" push -q origin "$invalid_head:refs/pull/57/head"
printf '%s\n' "$invalid_head" > "$TF/pr-head-57"
command git -C "$TF/repo" checkout -q main

command git -C "$TF/repo" checkout -qb pr-rule-newstop
command jq '.auto_merge=true' "$TF/repo/engine/mac-autopilot/config.template.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/repo/engine/mac-autopilot/config.template.json"
mkdir -p "$TF/repo/docs/agents/rule-replays"
printf '%s\n' '{"schema":"zf-control-rule-replay/v1","falseStops":[{"id":"a"},{"id":"b"},{"id":"c"}],"baseline":{"revision":"fixture"},"changedDecisions":[],"newFalseStops":[{"id":"n1"}]}' > "$TF/repo/docs/agents/rule-replays/newstop.json"
command git -C "$TF/repo" add engine/mac-autopilot/config.template.json docs/agents/rule-replays/newstop.json
command git -C "$TF/repo" commit -qm 'adjust scheduler rule' -m 'Rule-Replay: docs/agents/rule-replays/newstop.json'
newstop_head="$(command git -C "$TF/repo" rev-parse HEAD)"
command git -C "$TF/repo" push -q origin "$newstop_head:refs/pull/58/head"
printf '%s\n' "$newstop_head" > "$TF/pr-head-58"
command git -C "$TF/repo" checkout -q main

command git -C "$TF/repo" checkout -qb pr-rule-free
mkdir -p "$TF/repo/packages/fixture/src"
printf 'export const changed = true\n' > "$TF/repo/packages/fixture/src/index.ts"
command git -C "$TF/repo" add packages/fixture/src/index.ts
command git -C "$TF/repo" commit -qm 'change ordinary source'
clean_head="$(command git -C "$TF/repo" rev-parse HEAD)"
command git -C "$TF/repo" push -q origin "$clean_head:refs/pull/54/head"
printf '%s\n' "$clean_head" > "$TF/pr-head-54"
command git -C "$TF/repo" checkout -q main
base_main_sha="$(command git -C "$TF/repo" rev-parse HEAD)"
command jq '.batch_max=5' "$TF/repo/engine/mac-autopilot/config.template.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/repo/engine/mac-autopilot/config.template.json"
command git -C "$TF/repo" add engine/mac-autopilot/config.template.json
command git -C "$TF/repo" commit -qm 'advance main with a rule path update'
advanced_main_sha="$(command git -C "$TF/repo" rev-parse HEAD)"
command git -C "$TF/repo" push -q origin "$advanced_main_sha:refs/heads/main"
printf '%s\n' "$advanced_main_sha" > "$TF/main-sha"
[[ "$(command git -C "$TF/repo" merge-base "$advanced_main_sha" "$clean_head")" == "$base_main_sha" ]] \
  || { echo 'scheduler.test.sh: rule-free PR branch point is not the expected pre-advance main' >&2; exit 1; }
command git -C "$TF/repo" diff --name-only "$advanced_main_sha" "$clean_head" \
  | grep -Fxq 'engine/mac-autopilot/config.template.json' \
  || { echo 'scheduler.test.sh: fixture does not expose main drift in a two-point diff' >&2; exit 1; }

command jq -cn --arg bad "$rule_head" --arg clean "$clean_head" --arg missing "$(printf '%040x' 52)" \
  --arg no_report "$missing_head" --arg bad_report "$invalid_head" --arg newstop "$newstop_head" '{units:[
  {id:"pr-4548",issue:4548,pr:51,lane:"pr",branch:"agent/issue-4548",stage:"ready-to-merge",approved_sha:$bad,ready_since:1,history:[]},
  {id:"pr-4550",issue:4550,pr:52,lane:"pr",branch:"agent/issue-4550",stage:"ready-to-merge",approved_sha:$missing,ready_since:2,history:[]},
  {id:"pr-4551",issue:4551,pr:53,lane:"pr",branch:"agent/issue-4551",stage:"ready-to-merge",approved_sha:$bad,ready_since:3,history:[]},
  {id:"pr-4552",issue:4552,pr:54,lane:"pr",branch:"agent/issue-4552",stage:"ready-to-merge",approved_sha:$clean,ready_since:4,history:[]},
  {id:"pr-4553",issue:4553,pr:55,lane:"pr",branch:"supervisor/rule-4484",stage:"ready-to-merge",approved_sha:$bad,ready_since:5,history:[],ci_adopt_head:$bad,ci_adopt_at:"2026-10-29T00:00:00Z"},
  {id:"pr-4554",issue:4554,pr:56,lane:"pr",branch:"supervisor/miss-4548",stage:"ready-to-merge",approved_sha:$no_report,ready_since:6,history:[],ci_adopt_head:$no_report,ci_adopt_at:"2026-10-29T00:00:00Z"},
  {id:"pr-4555",issue:4555,pr:57,lane:"pr",branch:"supervisor/bad-4548",stage:"ready-to-merge",approved_sha:$bad_report,ready_since:7,history:[],ci_adopt_head:$bad_report,ci_adopt_at:"2026-10-29T00:00:00Z"},
  {id:"pr-4556",issue:4556,pr:58,lane:"pr",branch:"supervisor/newstop-4548",stage:"ready-to-merge",approved_sha:$newstop,ready_since:8,history:[],ci_adopt_head:$newstop,ci_adopt_at:"2026-10-29T00:00:00Z"}
]}' > "$TF/supervisor/autopi/units.json"
ZF_AGENT_NAME=supervisor tick

command jq -e --arg bad "$rule_head" --arg clean "$clean_head" --arg no_report "$missing_head" \
  --arg bad_report "$invalid_head" --arg newstop "$newstop_head" '
  ([.units[] | select(.pr==51)][0] | .stage=="supervisor-review" and .approved_sha==$bad and .rule_lane_commented_sha==$bad)
  and ([.units[] | select(.pr==52)][0] | .stage=="ready-to-merge")
  and ([.units[] | select(.pr==53)][0] | .stage=="supervisor-review" and (.rule_lane_commented_sha // null)==null)
  and ([.units[] | select(.pr==54)][0] | .stage=="merged" and .approved_sha==$clean)
  and ([.units[] | select(.pr==55)][0] | .stage=="merged" and .approved_sha==$bad)
  and ([.units[] | select(.pr==56)][0] | .stage=="ready-to-merge" and .approved_sha==$no_report)
  and ([.units[] | select(.pr==57)][0] | .stage=="ready-to-merge" and .approved_sha==$bad_report)
  and ([.units[] | select(.pr==58)][0] | .stage=="ready-to-merge" and .approved_sha==$newstop)
' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'scheduler.test.sh: rule-lane did not route each PR per the CTO ruling' >&2; exit 1; }
for rejected_pr in 51 52 53 56 57 58; do
  if grep -q "^merge $rejected_pr$" "$TF/actions"; then
    echo "scheduler.test.sh: scheduler merged blocked PR $rejected_pr" >&2; exit 1
  fi
done
grep -q '^merge 54$' "$TF/actions" \
  || { echo 'scheduler.test.sh: scheduler did not merge the rule-free PR' >&2; exit 1; }
grep -q '^merge 55$' "$TF/actions" \
  || { echo 'scheduler.test.sh: scheduler did not merge the supervisor rule PR with a valid report' >&2; exit 1; }
grep -Fq 'pr comment 51 --body 规则改动由 supervisor 落地：direct-main 规则通道，或 supervisor 合入的 PR 带 Rule-Replay 回放报告；unit PR 即使带回放报告也会拒绝。' "$TF/actions" \
  || { echo 'scheduler.test.sh: rejected rule PR did not receive the direct-main repair explanation' >&2; exit 1; }
grep -Fq 'rule-lane: repair comment failed PR#53' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: failed repair comment was not logged while the PR stayed held' >&2; exit 1; }
grep -Fq 'supervisor-review unit=pr-4548: PR#51 改到规则文件' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: unit rule rejection did not move the unit to the supervisor queue' >&2; exit 1; }
grep -Fq 'supervisor-review unit=pr-4551: PR#53 改到规则文件' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: comment-failure rejection did not move the unit to the supervisor queue' >&2; exit 1; }
grep -Fq 'merge skipped PR#52 (rule diff unavailable)' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: unavailable PR diff did not keep the candidate out of merge' >&2; exit 1; }
grep -Eq 'git fetch -q --no-tags origin .*\+refs/pull/51/head:refs/autopi/merge-candidates/' "$TF/calls" \
  || { echo 'scheduler.test.sh: merge lane did not fetch the exact PR head for rule-lane' >&2; exit 1; }
grep -Eq 'git fetch -q --no-tags origin .*\+refs/pull/52/head:refs/autopi/merge-candidates/' "$TF/calls" \
  || { echo 'scheduler.test.sh: merge lane did not observe the unavailable PR head' >&2; exit 1; }
grep -Fq 'gh pr merge 54 --squash --match-head-commit' "$TF/calls" \
  || { echo 'scheduler.test.sh: ordinary merge did not pass through gh-shim' >&2; exit 1; }
grep -Fq 'gh pr merge 55 --squash --match-head-commit' "$TF/calls" \
  || { echo 'scheduler.test.sh: supervisor rule merge did not pass through gh-shim' >&2; exit 1; }
grep -Fq 'rule-lane: decision=unit-reject refused=rule-files actor=unit:agent/issue-4548 touched=1 files=engine/mac-autopilot/config.template.json' \
  "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: scheduler log omitted the unit rule rejection event' >&2; exit 1; }
grep -Fq 'rule-lane: decision=unit-reject refused=rule-files actor=unit:agent/issue-4551 touched=1 files=engine/mac-autopilot/config.template.json' \
  "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: scheduler log omitted the comment-failure rejection event' >&2; exit 1; }
grep -Fq 'rule-lane: decision=pass actor=unit touched=0' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: a unit branch did not keep its unit actor under the supervisor tick' >&2; exit 1; }
grep -Fq 'rule-lane: decision=rule-lane actor=supervisor touched=1 reports=1 false-stops=0' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: supervisor rule PR with a valid report did not pass the rule lane' >&2; exit 1; }
grep -Fq 'reason=missing-trailer touched=engine/mac-autopilot/config.template.json' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: rule change without a Rule-Replay trailer was not refused' >&2; exit 1; }
grep -Fq 'reason=invalid-report path=docs/agents/rule-replays/bad.json' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: rule change with an invalid replay report was not refused' >&2; exit 1; }
grep -Fq 'reason=new-false-stops count=1 path=docs/agents/rule-replays/newstop.json' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: rule change introducing a new false stop was not refused' >&2; exit 1; }
grep -Fq 'merge skipped PR#56 (rule lane rejected the replay report)' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: an invalid report did not hold the supervisor PR out of merge' >&2; exit 1; }
}
sched_run_case rule_lane

sched_case_high_cache_lifetime() {
# A real scheduler tick dispatches a high-cache unit while its rounds and wall
# clock are within #4363's stop-loss. Lifetime raw tokens remain a metric, not a
# budget hold (#4486).
new_tick_fixture high-cache-lifetime
command jq '.max_workers=1' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
write_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
spend_log_started="$(date -u -d '5 minutes ago' +%Y%m%dT%H%M%SZ)"
printf 'VERDICT: NOT_READY\nF1 fixture repair\n' > "$TF/supervisor/prior.md"
command jq -cn --arg at "$write_started" '{units:[{
  id:"pr-9701",issue:9701,pr:9701,lane:"pr",title:"high cached token reads",
  branch:"fix/token-fixture",stage:"repair-pending",review_report:"prior.md",
  history:[{stage:"write-start",at:$at}]}]}' > "$TF/supervisor/autopi/units.json"
cat > "$TF/supervisor/impl-pr-9701-$spend_log_started.worker.log" <<'JSONL'
{"type":"pipeline.execution","mode":"fresh"}
{"type":"turn.completed","usage":{"input_tokens":40000000,"cached_input_tokens":38963245,"output_tokens":0}}
JSONL
touch "$TF/allow-dispatch" "$TF/worker-alive"
tick
command jq -e '
  .units[0].stage == "repair"
  and ([.units[0].history[] | select(.stage=="supervisor-budget-park")] | length) == 0
  and ((.units[0].note // "") | contains("budget") | not)
' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'not ok - scheduler.test.sh: tick parked or budget-noted a high-cache unit inside the rounds+wall limit' >&2; exit 1; }
command jq -e 'any(.workers[]; .unit=="pr-9701" and .type=="repair" and .harvested!=true)' \
  "$TF/supervisor/autopi/workers.json" >/dev/null \
  || { echo 'not ok - scheduler.test.sh: tick did not dispatch the high-cache repair through its worker lane' >&2; exit 1; }
if grep -Eq 'BUDGET-STOP|BUDGET-DEFER' "$TF/supervisor/autopi/scheduler.log"; then
  echo 'not ok - scheduler.test.sh: token accounting emitted a stop/defer event for an in-budget unit' >&2; exit 1
fi
if grep -Fq 'issue comment 9701' "$TF/actions"; then
  echo 'not ok - scheduler.test.sh: tick emitted a budget comment for an in-budget unit' >&2; exit 1
fi
grep -Fq 'gh pr view 9701' "$TF/calls" \
  || { echo 'not ok - scheduler.test.sh: high-cache tick bypassed the guarded gh-shim' >&2; exit 1; }
}
sched_run_case high_cache_lifetime

sched_case_config_reconcile() {
# A real paused tick reports a runtime drift before replacing it. The next
# matching tick neither re-emits the event nor changes the selected config.
new_tick_fixture config-reconcile
touch "$TF/pause"
tick
[[ ! -e "$TF/agent-home/supervisor-inbox" ]] || { echo 'scheduler.test.sh: matching config emitted a drift event' >&2; exit 1; }
touch "$TF/config-drift"
command jq '.max_workers=6' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
tick
command jq -e '.max_workers == 0' "$TF/supervisor/autopi/config.json" >/dev/null || { echo 'scheduler.test.sh: tick did not restore the repository config' >&2; exit 1; }
grep -Fq 'config-reconcile keys=max_workers' "$TF/supervisor/autopi/scheduler.log" || { echo 'scheduler.test.sh: tick log omitted the drift event' >&2; exit 1; }
grep -Fq 'config-reconcile' "$TF/agent-home/supervisor-inbox" || { echo 'scheduler.test.sh: tick did not report drift to the supervisor inbox' >&2; exit 1; }
grep -Fq 'max_workers' "$TF/agent-home/supervisor-inbox" || { echo 'scheduler.test.sh: inbox event omitted the config diff' >&2; exit 1; }
[[ "$(grep -c 'config-reconcile' "$TF/agent-home/supervisor-inbox")" == 1 ]] || { echo 'scheduler.test.sh: tick repeated an already reconciled drift event' >&2; exit 1; }
printf '{invalid json' > "$TF/supervisor/autopi/config.json"
tick
command jq -e '.max_workers == 0' "$TF/supervisor/autopi/config.json" >/dev/null || { echo 'scheduler.test.sh: tick did not replace invalid runtime JSON' >&2; exit 1; }
grep -Fq 'config-reconcile keys=invalid-json' "$TF/supervisor/autopi/scheduler.log" || { echo 'scheduler.test.sh: invalid config was not logged as drift' >&2; exit 1; }
[[ "$(grep -c 'config-reconcile' "$TF/agent-home/supervisor-inbox")" == 2 ]] || { echo 'scheduler.test.sh: invalid config drift event missing' >&2; exit 1; }
rm -rf "$TF/agent-home/logs"
touch "$TF/agent-home/logs"
command jq '.max_workers=6' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
if tick; then
  echo 'scheduler.test.sh: tick overwrote drift without an inbox event' >&2
  exit 1
fi
command jq -e '.max_workers == 6' "$TF/supervisor/autopi/config.json" >/dev/null || { echo 'scheduler.test.sh: failed inbox append still changed runtime config' >&2; exit 1; }
rm "$TF/agent-home/logs"
mkdir "$TF/agent-home/logs"
tick
command jq -e '.max_workers == 0' "$TF/supervisor/autopi/config.json" >/dev/null || { echo 'scheduler.test.sh: tick did not retry config reconciliation' >&2; exit 1; }
[[ "$(grep -c 'config-reconcile' "$TF/agent-home/supervisor-inbox")" == 3 ]] || { echo 'scheduler.test.sh: drift retry did not emit its event' >&2; exit 1; }
tick
[[ "$(grep -c 'config-reconcile' "$TF/agent-home/supervisor-inbox")" == 3 ]] || { echo 'scheduler.test.sh: unchanged config emitted a duplicate drift event' >&2; exit 1; }
}
sched_run_case config_reconcile

sched_case_main_red_superseded() {
# A green descendant main SHA supersedes an unstarted main-red unit before dispatch.
new_tick_fixture main-red-superseded
main_red_failed_sha="$(printf '%040x' 99)"
main_red_green_sha="$(cat "$TF/main-sha")"
main_red_id="main-red-${main_red_failed_sha:0:9}"
echo '{"databaseId":701,"attempt":1,"status":"completed","conclusion":"success","createdAt":"2026-10-29T00:00:00Z"}' > "$TF/run.json"
command jq -n --arg sha "$main_red_green_sha" \
  '[{headSha:$sha,status:"completed",conclusion:"success",createdAt:"2026-10-29T00:00:00Z"}]' \
  > "$TF/main-suites.json"
printf '%s %s\n' "$main_red_failed_sha" "$main_red_green_sha" > "$TF/ancestry.tsv"
printf '%s %s\n' "$main_red_green_sha" "$main_red_green_sha" >> "$TF/ancestry.tsv"
command jq '.max_workers=1' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
command jq -n --arg id "$main_red_id" --arg failed "$main_red_failed_sha" \
  '{units:[{id:$id,main_red:true,critical:true,ci_sha:$failed,lane:"direct-main",branch:("agent/"+$id),task:"fix the red Pipeline suite",footprint:[],stage:"implement-pending",history:[]}]}' \
  > "$TF/supervisor/autopi/units.json"
tick
command jq -e --arg id "$main_red_id" --arg sha "$main_red_green_sha" '
  any(.units[]; .id==$id and .stage=="closed"
    and any(.history[]; .stage=="superseded" and (.result | contains($sha))))
' "$TF/supervisor/autopi/units.json" >/dev/null || {
  cat "$TF/tick.out" >&2; echo 'scheduler.test.sh: green descendant main SHA did not supersede the pending main-red unit' >&2
  cat "$TF/supervisor/autopi/units.json" "$TF/supervisor/autopi/workers.json" "$TF/main-suites.json" "$TF/ancestry.tsv" >&2
  cat "$TF/supervisor/autopi/scheduler.log" "$TF/calls" >&2
  exit 1
}
command jq -e --arg id "$main_red_id" 'all(.workers[]; .unit!=$id)' "$TF/supervisor/autopi/workers.json" >/dev/null
! grep -Fq "unit=$main_red_id" "$TF/tick.out" || { cat "$TF/tick.out" >&2; echo 'scheduler.test.sh: superseded main-red unit was dispatched' >&2; exit 1; }

# An in-progress fixer is untouched even when main later has a green Pipeline suites run.
new_tick_fixture main-red-running
main_red_failed_sha="$(printf '%040x' 99)"
main_red_id="main-red-${main_red_failed_sha:0:9}"
main_red_pending_worker_id="${main_red_id}-pending-worker"
echo '{"databaseId":701,"attempt":1,"status":"completed","conclusion":"success","createdAt":"2026-10-29T00:00:00Z"}' > "$TF/run.json"
main_red_green_sha="$(cat "$TF/main-sha")"
command jq -n --arg sha "$main_red_green_sha" \
  '[{headSha:$sha,status:"completed",conclusion:"success",createdAt:"2026-10-29T00:00:00Z"}]' \
  > "$TF/main-suites.json"
touch "$TF/worker-alive"
command jq -n --arg id "$main_red_id" --arg failed "$main_red_failed_sha" \
  --arg pending "$main_red_pending_worker_id" \
  '{units:[
    {id:$id,main_red:true,ci_sha:$failed,lane:"direct-main",branch:("agent/"+$id),task:"fix the red Pipeline suite",footprint:[],stage:"implement",history:[]},
    {id:$pending,main_red:true,ci_sha:$failed,lane:"direct-main",branch:("agent/"+$pending),task:"fix the red Pipeline suite",footprint:[],stage:"implement-pending",history:[]}
  ]}' \
  > "$TF/supervisor/autopi/units.json"
command jq -n --arg id "$main_red_id" --arg pending "$main_red_pending_worker_id" \
  '{workers:[
    {pid:999999999,unit:$id,type:"implement",log:"running.log",report:"running.md",started:"2026-10-29T00:00:00Z",harvested:false},
    {pid:999999998,unit:$pending,type:"implement",log:"pending-worker.log",report:"pending-worker.md",started:"2026-10-29T00:00:00Z",harvested:false}
  ]}' \
  > "$TF/supervisor/autopi/workers.json"
tick
command jq -e --arg id "$main_red_id" --arg pending "$main_red_pending_worker_id" '
  any(.units[]; .id==$id and .stage=="implement" and all(.history[]?; .stage!="superseded"))
  and any(.units[]; .id==$pending and .stage=="implement-pending" and all(.history[]?; .stage!="superseded"))
' "$TF/supervisor/autopi/units.json" >/dev/null
command jq -e --arg id "$main_red_id" --arg pending "$main_red_pending_worker_id" '
  [.workers[] | select((.unit==$id or .unit==$pending) and .harvested==false)] | length==2
' "$TF/supervisor/autopi/workers.json" >/dev/null

# The latest Pipeline suites attempt for a SHA controls its result; the older green rerun and
# the failing SHA's own green rerun are not newer green main evidence.
new_tick_fixture main-red-no-green
main_red_failed_sha="$(printf '%040x' 99)"
main_red_id="main-red-${main_red_failed_sha:0:9}"
echo '{"databaseId":701,"attempt":1,"status":"in_progress","conclusion":null,"createdAt":"2026-10-29T00:00:00Z"}' > "$TF/run.json"
command jq -n --arg failed "$main_red_failed_sha" --arg main "$(cat "$TF/main-sha")" \
  '[
    {headSha:$failed,status:"completed",conclusion:"success",createdAt:"2026-10-29T00:00:00Z"},
    {headSha:$main,status:"completed",conclusion:"success",createdAt:"2026-10-29T00:00:00Z"},
    {headSha:$main,status:"in_progress",conclusion:null,createdAt:"2026-10-29T00:01:00Z"}
  ]' > "$TF/main-suites.json"
command jq -n --arg id "$main_red_id" --arg failed "$main_red_failed_sha" \
  '{units:[{id:$id,main_red:true,ci_sha:$failed,lane:"direct-main",branch:("agent/"+$id),task:"fix the red Pipeline suite",footprint:[],stage:"implement-pending",history:[]}]}' \
  > "$TF/supervisor/autopi/units.json"
tick
command jq -e --arg id "$main_red_id" '
  any(.units[]; .id==$id and .stage=="implement-pending" and all(.history[]?; .stage!="superseded"))
' "$TF/supervisor/autopi/units.json" >/dev/null

# A green run from a commit outside the current main history cannot supersede the unit.
new_tick_fixture main-red-detached-green
main_red_failed_sha="$(printf '%040x' 99)"
main_red_detached_sha="$(printf '%040x' 101)"
main_red_id="main-red-${main_red_failed_sha:0:9}"
command jq -n --arg id "$main_red_id" --arg failed "$main_red_failed_sha" \
  '{units:[{id:$id,main_red:true,ci_sha:$failed,lane:"direct-main",branch:("agent/"+$id),task:"fix the red Pipeline suite",footprint:[],stage:"implement-pending",history:[]}]}' \
  > "$TF/supervisor/autopi/units.json"
command jq -n --arg sha "$main_red_detached_sha" \
  '[{headSha:$sha,status:"completed",conclusion:"success",createdAt:"2026-10-29T00:00:00Z"}]' \
  > "$TF/main-suites.json"
printf '%s %s\n' "$main_red_failed_sha" "$main_red_detached_sha" > "$TF/ancestry.tsv"
tick
command jq -e --arg id "$main_red_id" '
  any(.units[]; .id==$id and .stage=="implement-pending" and all(.history[]?; .stage!="superseded"))
' "$TF/supervisor/autopi/units.json" >/dev/null

}
sched_run_case main_red_superseded

sched_case_body_blocked() {
# A real scheduler tick reads the issue's Blocked by section, parks an open
# predecessor before write-start, and reuses the DEP_CHECK_SECONDS state cache.
new_tick_fixture body-blocked
export DEP_CHECK_SECONDS=600
command jq '.max_workers=1' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
touch "$TF/allow-dispatch"
body_task='implement issue #9902

--- issue 正文（任务数据）---
正文背景提到 #9900。

## Blocked by
- #9901

## 验收
另一个引用 #9903。
--- 正文结束 ---'
command jq -cn --arg task "$body_task" '{units:[{id:"issue-9902",issue:9902,lane:"direct-main",branch:"agent/auto-issue-9902",stage:"implement-pending",task:$task,body_blocked_by:[9901],history:[]}]}' \
  > "$TF/supervisor/autopi/units.json"
tick
tick
command jq -e '.units[0].stage=="blocked-external" and .units[0].blocked_on==9901 and ([.units[0].history[].stage] | index("write-start") | not)' \
  "$TF/supervisor/autopi/units.json" >/dev/null || { cat "$TF/tick.out" >&2; echo 'scheduler.test.sh: open Blocked by predecessor reached implement dispatch' >&2; exit 1; }
[[ "$(grep -Fc 'gh api graphql' "$TF/calls")" == 1 ]] || { cat "$TF/calls" >&2; echo 'scheduler.test.sh: body dependency did not reuse its throttled GraphQL cache' >&2; exit 1; }
[[ ! -e "$TF/codex.calls" ]] || { cat "$TF/codex.calls" >&2; echo 'scheduler.test.sh: body-blocked issue launched a worker' >&2; exit 1; }
unset DEP_CHECK_SECONDS
}
sched_run_case body_blocked

sched_case_size_admission_repair() {
  # One real tick harvests repairs and self-fixes against a real fixture Git
  # remote. PRs 901/903 grew past admission; 902/904 remain admissible.
  new_tick_fixture size-admission-repair
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  local remote="$TF/origin.git" source="$TF/source" n clone
  command git init -q --bare -b main "$remote"
  command git init -q -b main "$source"
  seq 1 901 > "$source/base.ts"
  command git -C "$source" add -A
  command git -C "$source" commit -qm base
  command git -C "$source" remote add origin "$remote"
  command git -C "$source" push -q origin main
  command git -C "$source" checkout -q -b agent/issue-900
  seq 1 500 > "$source/parent.ts"
  command git -C "$source" add -A
  command git -C "$source" commit -qm parent
  command git -C "$source" push -q origin agent/issue-900
  for n in 901 902 903 904 906 907; do
    if (( n >= 906 )); then
      command git -C "$source" checkout -q -B "agent/issue-$n" agent/issue-900
    else
      command git -C "$source" checkout -q -B "agent/issue-$n" origin/main
    fi
    case "$n" in
      901) seq 1 801 > "$source/added.ts" ;;
      902) seq 1 800 > "$source/added.ts" ;;
      903) seq 1 100 > "$source/base.ts" ;;
      904) seq 1 800 > "$source/added.ts"; seq 1 1000 > "$source/pnpm-lock.yaml" ;;
      906) seq 1 301 > "$source/added.ts" ;;
      907) seq 1 801 > "$source/added.ts" ;;
    esac
    command git -C "$source" add -A
    command git -C "$source" commit -qm "repair $n"
    command git -C "$source" push -q origin "agent/issue-$n"
    clone="$TF/clones/size-$n"
    command git clone -q "$remote" "$clone"
    printf 'repair delivered\n' > "$TF/supervisor/repair-$n.md"
  done
  touch "$TF/real-clone-git"
  printf 'repair delivered\n' > "$TF/supervisor/repair-905.md"
  local parent_head other_parent_head
  parent_head="$(printf '%040x' 900)"; other_parent_head="$(printf '%040x' 908)"
  command jq -n --arg parent "$parent_head" --arg other "$other_parent_head" '{units:[
    {id:"issue-900",issue:900,pr:900,lane:"pr",branch:"agent/issue-900",stage:"ready-to-merge",approved_sha:$parent,reviewed_pr_head:$parent,history:[]},
    {id:"issue-908",issue:908,pr:908,lane:"pr",branch:"agent/issue-900",stage:"review-pending",history:[]},
    {id:"issue-901",issue:901,pr:901,lane:"pr",branch:"agent/issue-901",stage:"repair",history:[]},
    {id:"issue-902",issue:902,pr:902,lane:"pr",branch:"agent/issue-902",stage:"repair",history:[]},
    {id:"issue-903",issue:903,pr:903,lane:"pr",branch:"agent/issue-903",stage:"repair",self_fix_active:true,self_check_return_stage:"review-pending",history:[]},
    {id:"issue-904",issue:904,pr:904,lane:"pr",branch:"agent/issue-904",stage:"repair",self_fix_active:true,self_check_return_stage:"review-pending",history:[]},
    {id:"issue-905",issue:905,pr:905,lane:"pr",branch:"agent/issue-905",stage:"repair",history:[]},
    {id:"issue-906",issue:906,pr:906,lane:"pr",branch:"agent/issue-906",stage:"repair",history:[],blocked_on:900,stacked_on:"issue-900",stacked_on_unit:"issue-900",stacked_on_branch:"agent/issue-900",stacked_on_sha:$parent},
    {id:"issue-907",issue:907,pr:907,lane:"pr",branch:"agent/issue-907",stage:"repair",history:[],blocked_on:908,stacked_on:"issue-908",stacked_on_unit:"issue-908",stacked_on_branch:"agent/issue-900",stacked_on_sha:$other},
    {id:"issue-919",issue:919,pr:901,lane:"direct-main",branch:"agent/issue-901",stage:"repair",history:[]}
  ]}' > "$TF/supervisor/autopi/units.json"
  command jq -n --arg clones "$TF/clones" '{workers:([range(901;908) | select(.!=900)] | map(. as $n |
    {pid:(9000000+$n),unit:("issue-"+($n|tostring)),type:"repair",log:"missing.log",
     report:("repair-"+($n|tostring)+".md"),workdir:($clones+"/size-"+($n|tostring))}))}' \
    > "$TF/supervisor/autopi/workers.json"
  printf 'direct-main repair delivered\n' > "$TF/supervisor/repair-919.md"
  command jq --arg dir "$TF/clones/size-901" '.workers += [{pid:9000919,unit:"issue-919",type:"repair",log:"missing.log",report:"repair-919.md",workdir:$dir}]' "$TF/supervisor/autopi/workers.json" > "$TF/workers.tmp"; mv "$TF/workers.tmp" "$TF/supervisor/autopi/workers.json"
  tick
  command jq -e '
    ([.units[] | select(.id=="issue-901")][0] | .stage=="supervisor-review" and (.note | contains("801 changed lines"))) and
    ([.units[] | select(.id=="issue-902")][0].stage=="rereview-pending") and
    ([.units[] | select(.id=="issue-903")][0] | .stage=="supervisor-review" and (.note | contains("801 changed lines"))) and
    ([.units[] | select(.id=="issue-904")][0].stage=="review-pending") and
    ([.units[] | select(.id=="issue-905")][0].stage=="rereview-pending") and
    ([.units[] | select(.id=="issue-906")][0].stage=="rereview-pending") and
    ([.units[] | select(.id=="issue-907")][0] | .stage=="supervisor-review" and (.note | contains("801 changed lines"))) and
    ([.units[] | select(.id=="issue-919")][0].stage=="rereview-pending")
  ' "$TF/supervisor/autopi/units.json" >/dev/null || {
    echo 'not ok - scheduler.test.sh: repair size admission returned the wrong stages' >&2
    command jq '[.units[] | {id,stage,note}]' "$TF/supervisor/autopi/units.json" >&2
    exit 1
  }
  grep -Fq 'gh pr view 901 --json headRefName' "$TF/calls" || {
    echo 'not ok - scheduler.test.sh: size escalation bypassed gh-shim' >&2; exit 1;
  }

  # Initial oversize goes to the existing recut queue, with atomic issue state
  # and label writes. A failed label write remains at supervisor-review.
  new_tick_fixture size-recut-route
  local AGENT_HOME="$TF/agent-home"
  touch "$TF/size-recut-mode"
  echo 912 > "$TF/fail-issue-edit"
  cat > "$TF/roadmap-tree.json" <<'JSON'
{"roots":[{"number":9000,"title":"Roadmap","state":"OPEN","labels":["roadmap"],"children":[{"number":9001,"title":"Epic","state":"OPEN","labels":["roadmap-epic"],"children":[{"number":909,"title":"Issue 909","state":"OPEN","labels":[],"children":[]},{"number":912,"title":"Issue 912","state":"OPEN","labels":[],"children":[]}]}]}]}
JSON
  remote="$TF/origin.git"; source="$TF/source"
  command git init -q --bare -b main "$remote"
  command git init -q -b main "$source"
  echo base > "$source/base.ts"
  command git -C "$source" add -A; command git -C "$source" commit -qm base
  command git -C "$source" remote add origin "$remote"; command git -C "$source" push -q origin main
  for n in 909 912; do
    command git -C "$source" checkout -q -B "agent/issue-$n" origin/main
    seq 1 801 > "$source/change.ts"
    command git -C "$source" add -A; command git -C "$source" commit -qm oversized
    command git -C "$source" push -q origin "agent/issue-$n"
    command git clone -q "$remote" "$TF/clones/wt-issue-$n"
    printf 'implementation delivered\n' > "$TF/supervisor/implement-$n.md"
  done
  touch "$TF/real-clone-git"
  mkdir -p "$AGENT_HOME/state"
  printf '%s\n' '{"state":"ready-for-agent"}' > "$AGENT_HOME/state/909.json"
  printf '%s\n' '{"state":"ready-for-agent"}' > "$AGENT_HOME/state/912.json"
  command jq -n '{units:[909,912] | map({id:("issue-"+tostring),issue:.,lane:"pr",branch:("agent/issue-"+tostring),stage:"implement",task:"implement",history:[]})}' \
    > "$TF/supervisor/autopi/units.json"
  command jq -n --arg clones "$TF/clones" '{workers:[909,912] | map({pid:(9000000+.),unit:("issue-"+tostring),type:"implement",log:"missing.log",report:("implement-"+tostring+".md"),workdir:($clones+"/wt-issue-"+tostring)})}' \
    > "$TF/supervisor/autopi/workers.json"
  tick
  command jq -e '([.units[] | select(.id=="issue-909")][0] | .stage == "blocked-external" and .size_recut_pending == true) and ([.units[] | select(.id=="issue-912")][0].stage == "supervisor-review")' \
    "$TF/supervisor/autopi/units.json" >/dev/null || {
      echo 'not ok - scheduler.test.sh: initial oversized implementations did not route correctly' >&2
      command jq '[.units[] | {id,stage,note,size_recut_pending,history}]' "$TF/supervisor/autopi/units.json" >&2
      command cat "$TF/tick.out" "$TF/actions" >&2
      exit 1
    }
  command jq -e '.state == "needs-recut" and .size_admission.lines == 801 and .size_admission.limit == 800 and (.size_admission.head | length == 40)' \
    "$AGENT_HOME/state/909.json" >/dev/null || { echo 'not ok - scheduler.test.sh: measured size evidence was not recorded' >&2; exit 1; }
  grep -Eq '^issue edit 909 .*--add-label needs-recut' "$TF/actions" || { echo 'not ok - scheduler.test.sh: no recut label action through gh-shim' >&2; exit 1; }
  ! grep -Fq 'gh pr create' "$TF/calls" || { echo 'not ok - scheduler.test.sh: an oversized implementation opened a PR' >&2; exit 1; }
  command jq '. + {recut_children:[991]}' "$AGENT_HOME/state/909.json" > "$TF/state.tmp"; mv "$TF/state.tmp" "$AGENT_HOME/state/909.json"
  tick
  [[ "$(command jq -r '.units[] | select(.id=="issue-909") | .stage' "$TF/supervisor/autopi/units.json")" == blocked-external ]] \
    || { echo 'not ok - scheduler.test.sh: incomplete recut retired the unit early' >&2; exit 1; }
  # State can temporarily say tracker before the label write fails and rolls
  # back. A tick must defer while the transition's per-issue lock is held.
  local state_lock
  exec {state_lock}>"$AGENT_HOME/state/909.json.lock"
  flock -x "$state_lock"
  command jq '.state="tracker"' "$AGENT_HOME/state/909.json" > "$TF/state.tmp"; mv "$TF/state.tmp" "$AGENT_HOME/state/909.json"
  tick
  [[ "$(command jq -r '.units[] | select(.id=="issue-909") | .stage' "$TF/supervisor/autopi/units.json")" == blocked-external ]] \
    || { echo 'not ok - scheduler.test.sh: observed an uncommitted issue transition' >&2; exit 1; }
  command jq '.state="needs-recut"' "$AGENT_HOME/state/909.json" > "$TF/state.tmp"; mv "$TF/state.tmp" "$AGENT_HOME/state/909.json"
  flock -u "$state_lock"; exec {state_lock}>&-
  tick
  [[ "$(command jq -r '.units[] | select(.id=="issue-909") | .stage' "$TF/supervisor/autopi/units.json")" == blocked-external ]] \
    || { echo 'not ok - scheduler.test.sh: rolled-back transition retired the unit' >&2; exit 1; }
  command jq '.state="tracker"' "$AGENT_HOME/state/909.json" > "$TF/state.tmp"; mv "$TF/state.tmp" "$AGENT_HOME/state/909.json"
  tick
  [[ "$(command jq -r '.units[] | select(.id=="issue-909") | .stage' "$TF/supervisor/autopi/units.json")" == closed ]] \
    || { echo 'not ok - scheduler.test.sh: completed child issue recut did not retire the parent unit' >&2; exit 1; }
  local prior_head
  prior_head="$(command git -C "$source" rev-parse origin/agent/issue-909)"
  command git clone -q "$remote" "$TF/clones/wt-issue-910"
  command jq --arg head "$prior_head" '.units += [{id:"issue-910",issue:910,lane:"pr",branch:"agent/issue-909",task:"implement",stage:"blocked-external",size_recut_pending:true,history:[{stage:"size-recut",result:("head="+$head)}]},{id:"issue-911",issue:911,stage:"blocked-external",size_recut_pending:true,history:[]},{id:"issue-913",issue:913,stage:"blocked-external",size_recut_pending:true,history:[]},{id:"issue-914",issue:914,stage:"blocked-external",size_recut_pending:true,history:[]},{id:"issue-915",issue:915,stage:"blocked-external",size_recut_pending:true,history:[]},{id:"issue-916",issue:916,stage:"blocked-external",size_recut_pending:true,history:[]},{id:"issue-917",issue:917,stage:"blocked-external",size_recut_pending:true,history:[]},{id:"issue-918",issue:918,stage:"blocked-external",size_recut_pending:true,history:[]},{id:"issue-920",issue:920,stage:"blocked-external",size_recut_pending:true,history:[]},{id:"issue-921",issue:921,stage:"blocked-external",size_recut_pending:true,history:[]},{id:"issue-922",issue:922,stage:"blocked-external",size_recut_pending:true,history:[]}]' \
    "$TF/supervisor/autopi/units.json" > "$TF/units.tmp"; mv "$TF/units.tmp" "$TF/supervisor/autopi/units.json"
  printf '%s\n' '{"state":"needs-recut","recut_refused_at":"now"}' > "$AGENT_HOME/state/910.json"
  printf '%s\n' '{"state":"on-hold","hold":{"kind":"production-access"},"recut_refused_at":"now"}' > "$AGENT_HOME/state/911.json"
  printf '%s\n' '{"state":"needs-advisor"}' > "$AGENT_HOME/state/913.json"
  printf '%s\n' '{"state":"needs-recut"}' > "$AGENT_HOME/state/914.json"
  printf '%s\n' '{"state":"tracker","tracker_parent":true}' > "$AGENT_HOME/state/915.json"
  printf '%s\n' '{"state":"released","recut_children":[996]}' > "$AGENT_HOME/state/916.json"
  printf '%s\n' '{"state":"needs-recut","recut_children":[997]}' > "$AGENT_HOME/state/917.json"
  printf '%s\n' '{"state":"needs-recut","recut_refused_at":"now","recut_refused_reason":"cannot split"}' > "$AGENT_HOME/state/918.json"
  printf '%s\n' '{"state":"concluded","run":{"outcome":"duplicate"},"closed_by_pipeline":true}' > "$AGENT_HOME/state/920.json"
  printf '%s\n' '{"state":"needs-info","recut_refused_at":"now"}' > "$AGENT_HOME/state/921.json"
  printf '%s\n' '{"state":"on-hold","hold":{"kind":"production-access"},"recut_refused_at":"now"}' > "$AGENT_HOME/state/922.json"
  touch "$TF/recut-inactive-917" "$TF/recut-inactive-918"
  tick
  command jq -e '([.units[] | select(.id=="issue-910")][0].stage == "blocked-external") and ([.units[] | select(.id=="issue-911")][0].stage == "parked") and ([.units[] | select(.id=="issue-913" or .id=="issue-914")] | all(.stage == "blocked-external"))' \
    "$TF/supervisor/autopi/units.json" >/dev/null || { echo 'not ok - scheduler.test.sh: refused recut ignored its in-progress or held state' >&2; exit 1; }
  [[ "$(command jq -r '.units[] | select(.id=="issue-915") | .stage' "$TF/supervisor/autopi/units.json")" == closed ]] \
    || { echo 'not ok - scheduler.test.sh: advisor tracker did not retire the unit' >&2; exit 1; }
  [[ "$(command jq -r '.units[] | select(.id=="issue-916") | .stage' "$TF/supervisor/autopi/units.json")" == closed ]] \
    || { echo 'not ok - scheduler.test.sh: released recut parent did not retire the unit' >&2; exit 1; }
  command jq -e '([.units[] | select(.id=="issue-920")][0].stage == "closed") and ([.units[] | select(.id=="issue-921")][0].stage == "blocked-external")' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: duplicate or needs-info advisor outcome was mishandled' >&2; exit 1; }
  command jq -e '[.units[] | select(.id=="issue-917" or .id=="issue-918")] | all(.stage == "parked" and .size_recut_pending == true and (.note | contains("reconciliation")))' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: stranded recut markers were not safely parked' >&2; exit 1; }
  command jq -e '.recut_children == [997] and .state == "needs-recut"' "$AGENT_HOME/state/917.json" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: stranded child marker changed while parked' >&2; exit 1; }
  [[ "$(command jq -r '.units[] | select(.id=="issue-922") | .stage' "$TF/supervisor/autopi/units.json")" == parked ]] \
    || { echo 'not ok - scheduler.test.sh: refused recut did not remain on hold' >&2; exit 1; }
  printf '%s\n' '{"state":"needs-recut","hold":null,"recut_refused_at":"now"}' > "$AGENT_HOME/state/922.json"
  touch "$TF/recut-inactive-922"
  tick
  command jq -e '[.units[] | select(.id=="issue-917" or .id=="issue-918")] | all(.stage == "parked" and .size_recut_pending == true)' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: unreconciled recut resumed on a later tick' >&2; exit 1; }
  [[ "$(command jq -r '.units[] | select(.id=="issue-921") | .stage' "$TF/supervisor/autopi/units.json")" == blocked-external ]] \
    || { echo 'not ok - scheduler.test.sh: needs-info resumed before its answer' >&2; exit 1; }
  command jq -e '[.units[] | select(.id=="issue-922")][0] | .stage == "parked" and .size_recut_pending == true and (.note | contains("reconciliation"))' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: expired recut hold did not request reconciliation' >&2; exit 1; }
  [[ "$(grep -c 'size-recut issue=#922 action=parked' "$TF/supervisor/autopi/alerts/events.md")" == 1 ]] \
    || { echo 'not ok - scheduler.test.sh: expired hold did not emit one reconciliation event' >&2; exit 1; }
  tick
  [[ "$(grep -c 'size-recut issue=#922 action=parked' "$TF/supervisor/autopi/alerts/events.md")" == 1 ]] \
    || { echo 'not ok - scheduler.test.sh: expired hold emitted duplicate reconciliation events' >&2; exit 1; }
  ! grep -Fq 'gh pr create' "$TF/calls" || { echo 'not ok - scheduler.test.sh: unreconciled parent opened a PR' >&2; exit 1; }
  printf '%s\n' '{"state":"tracker","recut_children":[997]}' > "$AGENT_HOME/state/917.json"
  printf '%s\n' '{"state":"ready-for-agent","guarded":true,"recut_refused_at":"now"}' > "$AGENT_HOME/state/918.json"
  printf '%s\n' '{"state":"ready-for-agent","recut_refused_at":"now"}' > "$AGENT_HOME/state/921.json"
  printf '%s\n' '{"state":"ready-for-agent","recut_refused_at":"now"}' > "$AGENT_HOME/state/922.json"
  tick
  command jq -e '([.units[] | select(.id=="issue-917")][0].stage == "closed") and ([.units[] | select(.id=="issue-918")][0].stage == "implement-pending") and ([.units[] | select(.id=="issue-921")][0].stage == "implement-pending") and ([.units[] | select(.id=="issue-922")][0].stage == "implement-pending")' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: reconciled recut did not resume safely' >&2; exit 1; }
  printf '%s\n' '{"state":"ready-for-agent","hold":null,"hold_released_at":"now","recut_refused_at":"now"}' > "$AGENT_HOME/state/911.json"
  printf '%s\n' '{"state":"ready-for-agent"}' > "$AGENT_HOME/state/913.json"
  tick
  [[ "$(command jq -r '.units[] | select(.id=="issue-911") | .stage' "$TF/supervisor/autopi/units.json")" == implement-pending ]] \
    || { echo 'not ok - scheduler.test.sh: released hold did not resume the parked recut' >&2; exit 1; }
  [[ "$(command jq -r '.units[] | select(.id=="issue-913") | .stage' "$TF/supervisor/autopi/units.json")" == implement-pending ]] \
    || { echo 'not ok - scheduler.test.sh: advisor requeue did not resume the failed recut' >&2; exit 1; }
  printf '%s\n' '{"state":"ready-for-agent","guarded":true,"recut_refused_at":"now"}' > "$AGENT_HOME/state/910.json"
  tick
  [[ "$(command jq -r '.units[] | select(.id=="issue-910") | .stage' "$TF/supervisor/autopi/units.json")" == implement-pending ]] \
    || { echo 'not ok - scheduler.test.sh: guarded refusal did not restore the original unit' >&2; exit 1; }
  printf 'same oversized head\n' > "$TF/supervisor/implement-910.md"
  command jq '(.units[] | select(.id=="issue-910").stage)="implement"' "$TF/supervisor/autopi/units.json" > "$TF/units.tmp"; mv "$TF/units.tmp" "$TF/supervisor/autopi/units.json"
  command jq --arg dir "$TF/clones/wt-issue-910" '.workers += [{pid:9000910,unit:"issue-910",type:"implement",log:"missing.log",report:"implement-910.md",workdir:$dir}]' "$TF/supervisor/autopi/workers.json" > "$TF/workers.tmp"; mv "$TF/workers.tmp" "$TF/supervisor/autopi/workers.json"
  tick
  [[ "$(command jq -r '.units[] | select(.id=="issue-910") | .stage' "$TF/supervisor/autopi/units.json")" == supervisor-review ]] \
    || { echo 'not ok - scheduler.test.sh: refused unchanged head was sent back to recut' >&2; exit 1; }
  ! grep -Eq '^issue edit 910 .*--add-label needs-recut' "$TF/actions" \
    || { echo 'not ok - scheduler.test.sh: refused unchanged head reopened recut' >&2; exit 1; }
}
sched_run_case size_admission_repair

sched_case_oversized_repair_pre_dispatch_recut() {
  new_tick_fixture oversized-repair-pre-dispatch
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  command jq '.max_workers=8 | .implement_cap=8' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
  mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  local remote="$TF/origin" source="$TF/source" clone="$TF/clones/wt-issue-930"
  command git init -q --bare "$remote"
  command git init -q -b main "$source"
  mkdir -p "$source/packages/example/src"
  printf 'base\n' > "$source/packages/example/src/base.ts"
  command git -C "$source" add -A
  command git -C "$source" commit -qm base
  command git -C "$source" remote add origin "$remote"
  command git -C "$source" push -q origin main
  command git -C "$source" checkout -q -b agent/issue-930
  seq 1 801 > "$source/packages/example/src/large.ts"
  printf 'small diff\n' > "$source/packages/example/src/other.ts"
  command git -C "$source" add -A
  command git -C "$source" commit -qm oversized
  command git -C "$source" push -q origin agent/issue-930
  command git clone -q "$remote" "$clone"
  touch "$TF/real-clone-git" "$TF/size-recut-mode" "$TF/allow-dispatch"
  mkdir -p "$TF/agent-home/state"
  printf '%s\n' '{"state":"ready-for-agent"}' > "$TF/agent-home/state/930.json"
  seed_roadmap_tree 930
  printf 'VERDICT: REQUEST-CHANGES\nexisting review failure\n' > "$TF/supervisor/review-930.md"
  command jq -n '{units:[{id:"issue-930",issue:930,pr:930,lane:"pr",branch:"agent/issue-930",title:"oversized repair",stage:"repair-pending",review_report:"review-930.md",repair_hint:"review failure",footprint:["packages/example"],history:[]}]}' \
    > "$TF/supervisor/autopi/units.json"
  tick
  command jq -e '
    ([.units[] | select(.id=="issue-930")][0] | .stage=="blocked-external" and .size_recut_pending==true
      and .footprint_source=="pr-diff"
      and .footprint==["packages/example/src/large.ts","packages/example/src/other.ts"]
      and any(.history[]; .stage=="size-recut"))
  ' "$TF/supervisor/autopi/units.json" >/dev/null || {
    echo 'not ok - scheduler.test.sh: oversized repair did not enter recut with its actual PR footprint' >&2
    command jq '[.units[] | {id,stage,size_recut_pending,footprint,footprint_source,history}]' "$TF/supervisor/autopi/units.json" >&2
    cat "$TF/tick.out" "$TF/actions" >&2
    exit 1
  }
  command jq -e '.state=="needs-recut" and .size_admission.lines==802 and .size_admission.limit==800' \
    "$TF/agent-home/state/930.json" >/dev/null || { echo 'not ok - scheduler.test.sh: repair preflight size evidence was not recorded' >&2; exit 1; }
  command jq -e '.workers | length==0' "$TF/supervisor/autopi/workers.json" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: oversized repair occupied a worker' >&2; exit 1; }
  grep -Eq '^issue edit 930 .*--add-label needs-recut' "$TF/actions" \
    || { echo 'not ok - scheduler.test.sh: repair preflight did not use the existing recut label transition' >&2; exit 1; }
  grep -Fq 'unit issue-930 size admission routed issue #930 to recut' "$TF/supervisor/autopi/scheduler.log" \
    || { echo 'not ok - scheduler.test.sh: repair recut event was not emitted' >&2; exit 1; }
  grep -Fq 'gh pr view 930 --json headRefOid' "$TF/calls" \
    || { echo 'not ok - scheduler.test.sh: repair size preflight bypassed gh-shim' >&2; exit 1; }
}
sched_run_case oversized_repair_pre_dispatch_recut

tick_with_gh_shim() (
  unset GH_TOKEN GITHUB_TOKEN
  unset AUTOPI_TEST_LIBRARY_ONLY
  prepare_tick_config
  export MAC_AUTOPILOT_ROOT="$TF/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$TF/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$TF/supervisor/autopi" CODEX_SESSIONS_DIR="$TF/sessions"
  export AGENT_HOME="$TF/agent-home" AUTOPILOT_PAUSE_FILE="$TF/pause"
  export ZF_GH_REAL_CLI="$TF/bin/gh-real"
  git() {
    case " $* " in *" $TF/clones/eval-pr "*) command git "$@" ;; *) tick_git "$@" ;; esac
  }
  jq() { tick_jq "$@"; }
  unset -f gh 2>/dev/null || true
  export PATH="$script_dir/../gh-shim:$TF/bin:$PATH" AUTOPI_VIEWS_INLINE=true
  export -f git jq tick_gh tick_jq
  bash "$TF/repo/engine/mac-autopilot/scheduler.sh" > "$TF/tick.out" 2>&1 || { cat "$TF/tick.out" >&2; return 1; }
  [[ ! -e "$TF/unexpected-host" ]] || { cat "$TF/unexpected-host" >&2; return 1; }
)

sched_case_stuck_worker_disposition() {
# A real scheduler tick consumes the f8 scorecard, stops the stale worker group,
# records the event and requeues; its second stuck episode takes the existing f6 hold route.
new_tick_fixture stuck-worker-disposition
export TF_REAL_PS=1
tick_worker_dir="$TF/no-git-worktree"
mkdir -p "$tick_worker_dir"
tick_worker_log="$TF/supervisor/stuck-worker.log"
printf 'event line\n' > "$tick_worker_log"
start_tick_worker() {
  local label="$1" backend="$TF/$1-backend.pid"
  setsid bash -c 'sleep 600 & echo $! > "$1"; exec -a codex-worker sleep 600' _ "$backend" \
    < /dev/null > /dev/null 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" > "$TF/$1-worker.pid"
  for _ in {1..50}; do [[ -s "$backend" ]] && break; sleep 0.01; done
  printf '%s' "$pid"
}
worker_stopped() {
  local pid="$1" backend="$2" state
  for _ in {1..50}; do
    state="$(command ps -p "$pid" -o stat= 2>/dev/null | tr -d ' ')"
    [[ -z "$state" || "$state" == Z* ]] && break
    sleep 0.02
  done
  state="$(command ps -p "$pid" -o stat= 2>/dev/null | tr -d ' ')"
  [[ -z "$state" || "$state" == Z* ]] || return 1
  state="$(command ps -p "$backend" -o stat= 2>/dev/null | tr -d ' ')"
  [[ -z "$state" || "$state" == Z* ]]
}
write_tick_stuck_state() {
  local pid="$1" probe_at="$2" old_episode="$3" log=stuck-worker.log workdir="$tick_worker_dir"
  local probe_fp="$(stat -c %s "$tick_worker_log")|nogit|nogit"
  command jq -cn --arg id pr-4371-worker --arg log stuck-worker.log --arg workdir "$tick_worker_dir" \
    --arg at "$(date -u -d "@$(( $(date -u +%s) - 1200 ))" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg probe_at "$probe_at" --arg probe_fp "$probe_fp" --argjson pid "$pid" --argjson old "$old_episode" \
    '{units:[{id:$id,issue:4371,pr:4371,stage:"review",history:([{stage:"review-request-changes",at:$at}] + (if $old then [{stage:"stuck-killed",result:"episode 1",at:$at}] else [] end)),stuck_probe:{at:$probe_at,fp:$probe_fp}}]}' \
    > "$TF/supervisor/autopi/units.json"
  command jq -cn --arg log "$log" --arg workdir "$workdir" --arg at "$(date -u -d '@0' +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson pid "$pid" '{workers:[{pid:$pid,unit:"pr-4371-worker",type:"review",log:$log,report:"stuck.md",started:$at,workdir:$workdir,model:"fixture"}]}' \
    > "$TF/supervisor/autopi/workers.json"
  command jq -cn '{metrics:[{id:"flow.wip_age_stage_p90_hours",status:"UNHEALTHY",unhealthy:12}],flow:{wip_age:[{stage:"review",p90_hours:13.5,oldest:[{id:"pr-4371-worker",age_hours:14}]}]}}' \
    > "$TF/supervisor/autopi/node-health.json"
}
issue_hold_calls="$TF/hold.calls"
cat > "$TF/repo/engine/hold.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TF/hold.calls"
SH
chmod +x "$TF/repo/engine/hold.sh"
stuck_pid="$(start_tick_worker stuck-first)"
stuck_backend="$(cat "$TF/stuck-first-backend.pid")"
stale_probe_at="$(date -u -d "@$(( $(date -u +%s) - 90 * 60 ))" +%Y-%m-%dT%H:%M:%SZ)"
write_tick_stuck_state "$stuck_pid" "$stale_probe_at" false
tick
command jq -e '.units[0].stage == "review-pending" and any(.units[0].history[]; .stage=="stuck-killed")' \
  "$TF/supervisor/autopi/units.json" >/dev/null || { echo 'not ok - scheduler.test.sh: first stuck tick did not requeue' >&2; exit 1; }
command jq -e --argjson pid "$stuck_pid" '.workers[] | select(.pid==$pid) | .harvested == true and .stuck_killed == true' \
  "$TF/supervisor/autopi/workers.json" >/dev/null || { echo 'not ok - scheduler.test.sh: stuck tick did not harvest the worker' >&2; exit 1; }
grep -Fq 'STUCK-KILL unit=pr-4371-worker' "$TF/supervisor/autopi/alerts/events.md" \
  || { echo 'not ok - scheduler.test.sh: stuck tick emitted no STUCK-KILL event' >&2; exit 1; }
worker_stopped "$stuck_pid" "$stuck_backend" || { echo 'not ok - scheduler.test.sh: stuck tick left the worker backend alive' >&2; exit 1; }

stuck_pid="$(start_tick_worker stuck-second)"
stuck_backend="$(cat "$TF/stuck-second-backend.pid")"
printf 'event line\n' > "$tick_worker_log"
write_tick_stuck_state "$stuck_pid" "$stale_probe_at" true
tick
command jq -e '.units[0].stage == "supervisor-review" and any(.units[0].history[]; .stage=="stuck-stoploss")' \
  "$TF/supervisor/autopi/units.json" >/dev/null || { echo 'not ok - scheduler.test.sh: second stuck tick did not route to supervisor' >&2; exit 1; }
grep -Fq -- '--hold 4371 --holder scheduler-stop-loss' "$issue_hold_calls" \
  || { echo 'not ok - scheduler.test.sh: second stuck tick did not select the f6 hold action' >&2; exit 1; }
grep -Fq 'issue comment 4371' "$TF/actions" \
  || { echo 'not ok - scheduler.test.sh: second stuck tick did not comment through gh-shim' >&2; exit 1; }
worker_stopped "$stuck_pid" "$stuck_backend" || { echo 'not ok - scheduler.test.sh: second stuck tick left the worker backend alive' >&2; exit 1; }
for worker_pid_file in "$TF"/*-worker.pid; do
  worker_pid="$(cat "$worker_pid_file")"
  kill -TERM -- "-$worker_pid" 2>/dev/null || true
done
unset TF_REAL_PS
}
sched_run_case stuck_worker_disposition

[[ "$(decision_eval_stages_for_paths 'engine/prompts/triage.md')" == 'triage end-to-end ' ]] || {
  echo 'not ok - scheduler.test.sh: triage prompt did not select triage and end-to-end evals' >&2; exit 1;
}
[[ "$(decision_eval_stages_for_paths 'engine/prompts/advisor-batch.md')" == 'advisor end-to-end ' ]] || {
  echo 'not ok - scheduler.test.sh: advisor batch prompt did not select advisor and end-to-end evals' >&2; exit 1;
}
[[ "$(decision_eval_stages_for_paths 'engine/prompts/recut.md')" == 'end-to-end ' ]] || {
  echo 'not ok - scheduler.test.sh: recut prompt did not select end-to-end evals' >&2; exit 1;
}
[[ "$(decision_eval_stages_for_paths '.agents/skills/zf-code-review/SKILL.md')" == 'review end-to-end ' ]] || {
  echo 'not ok - scheduler.test.sh: review contract did not select review and end-to-end evals' >&2; exit 1;
}
[[ "$(decision_eval_stages_for_paths 'engine/model-policy.default.json')" == 'triage advisor implement review end-to-end ' ]] || {
  echo 'not ok - scheduler.test.sh: model policy did not select every eval stage' >&2; exit 1;
}

sched_case_gate_network() {
new_tick_fixture gate-network
command jq '.auto_merge=true' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
echo 'fatal: gnutls_handshake() failed: connection reset' > "$TF/failed.log"
tick; tick
[[ "$(command grep -c '^rerun ' "$TF/actions")" == 1 ]]
[[ ! -s "$TF/reverted" ]]
command jq -e '.units | length==0' "$TF/supervisor/autopi/units.json" >/dev/null
}
sched_run_case gate_network

sched_case_gate_suite_timeout() {
new_tick_fixture gate-suite-timeout
command jq '.auto_merge=true' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
echo '[pipeline suites] FAILED suite=engine/land-queue.test.sh exit_code=137 first_error=suite engine/land-queue.test.sh timed out after 492s' > "$TF/failed.log"
tick; tick
[[ "$(command grep -c '^rerun ' "$TF/actions")" == 1 ]]
[[ ! -s "$TF/reverted" ]]
command jq -e '.units | length==0' "$TF/supervisor/autopi/units.json" >/dev/null
}
sched_run_case gate_suite_timeout

sched_case_ready_starvation() {
local pr starve_sha
new_tick_fixture ready-starvation
enable_rule_lane_fixture
command jq '.auto_merge=true' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
command jq '.conclusion="success"' "$TF/run.json" > "$TF/run.tmp"; mv "$TF/run.tmp" "$TF/run.json"
command jq -n '{units:[range(1;18) | {id:("pr-"+tostring),pr:.,stage:"ready-to-merge",lane:"pr",ready_since:.,history:[]}]}' > "$TF/supervisor/autopi/units.json"
for pr in $(seq 1 17); do
  command git -C "$TF/repo" checkout -qb "starve-$pr"
  mkdir -p "$TF/repo/packages/fixture/src"
  printf 'export const pr = %s\n' "$pr" > "$TF/repo/packages/fixture/src/index.ts"
  command git -C "$TF/repo" add packages/fixture/src/index.ts
  command git -C "$TF/repo" commit -qm "starvation candidate $pr"
  starve_sha="$(command git -C "$TF/repo" rev-parse HEAD)"
  command git -C "$TF/repo" push -q origin "$starve_sha:refs/pull/$pr/head"
  printf '%s\n' "$starve_sha" > "$TF/pr-head-$pr"
  command git -C "$TF/repo" checkout -q main
  command jq --argjson pr "$pr" --arg sha "$starve_sha" '(.units[] | select(.pr==$pr)).approved_sha=$sha' "$TF/supervisor/autopi/units.json" > "$TF/units.tmp"
  mv "$TF/units.tmp" "$TF/supervisor/autopi/units.json"
done
echo 12 > "$TF/dead-through"
printf '%s\n' 13 14 15 16 17 > "$TF/pipeline-prs"
tick; tick
[[ "$(command grep -c '^merge ' "$TF/actions")" == 5 ]]
command jq -e '[.units[] | select(.stage=="merged")] | length==5' "$TF/supervisor/autopi/units.json" >/dev/null
}
sched_run_case ready_starvation

# #4515 发布状态单一事实源：合入 lane 在合并当时直接写 awaiting-release，
# 依据是台账 unit→issue 关系；fixture 的 PR census 根本不带 body，等价于
# "PR 正文里没有任何 issue 引用"，发布状态不再能从正文反推。
sched_case_merge_release_state() {
new_tick_fixture merge-release-state
enable_rule_lane_fixture
command jq '.auto_merge=true' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
command jq '.conclusion="success"' "$TF/run.json" > "$TF/run.tmp"; mv "$TF/run.tmp" "$TF/run.json"
# awaiting-release 转换要求 issue 已在 roadmap 树上（同 supervisor-arbiter case 的 fixture 模式）。
export ZF_ROADMAP_TREE_CACHE_FILE="$TF/roadmap-tree.json"
command jq -cn '{roots:[4470] | map({number:.,title:("fixture issue " + tostring),state:"open",labels:[],children:[]})}' \
  > "$ZF_ROADMAP_TREE_CACHE_FILE"
command git -C "$TF/repo" checkout -qb release-state-77
mkdir -p "$TF/repo/packages/fixture/src"
printf 'export const release = true\n' > "$TF/repo/packages/fixture/src/index.ts"
command git -C "$TF/repo" add packages/fixture/src/index.ts
command git -C "$TF/repo" commit -qm 'release state source'
sha="$(command git -C "$TF/repo" rev-parse HEAD)"
command git -C "$TF/repo" push -q origin "$sha:refs/pull/77/head"
printf '%s\n' "$sha" > "$TF/pr-head-77"
command git -C "$TF/repo" checkout -q main
command jq -n --arg sha "$sha" '{units:[{id:"pr-77",pr:77,issue:4470,lane:"pr",branch:"agent/issue-4470",stage:"ready-to-merge",approved_sha:$sha,ready_since:1,history:[]}]}' > "$TF/supervisor/autopi/units.json"
tick
command grep -q '^merge 77' "$TF/actions"
command jq -e '.state=="awaiting-release" and .run.outcome=="merged"
  and .run.evidence.pr_number=="77" and .deploy_state=="pending"' \
  "$TF/agent-home/state/4470.json" >/dev/null
command grep -q 'issue edit 4470 .*--add-label awaiting-release' "$TF/actions"
command grep -q 'issue comment 4470 ' "$TF/actions"
command grep -q 'entered awaiting-release at merge of PR#77' "$TF/supervisor/autopi/scheduler.log"
# 无 issue 的单元合入时无事可写，也不产生告警。
new_tick_fixture merge-release-unlinked
enable_rule_lane_fixture
command jq '.auto_merge=true' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
command jq '.conclusion="success"' "$TF/run.json" > "$TF/run.tmp"; mv "$TF/run.tmp" "$TF/run.json"
unset ZF_ROADMAP_TREE_CACHE_FILE
printf '%s\n' '{"required":["Enforce branch delivery policy","Required CI gates","Required contract gates"]}' \
  > "$TF/required-pr-checks.json"
export REQUIRED_PR_CHECKS_FILE="$TF/required-pr-checks.json"
command git -C "$TF/repo" checkout -qb feature/unlinked-src
mkdir -p "$TF/repo/packages/fixture/src"
printf 'export const unlinked = true\n' > "$TF/repo/packages/fixture/src/index.ts"
command git -C "$TF/repo" add packages/fixture/src/index.ts
command git -C "$TF/repo" commit -qm 'unlinked external source'
unlinked_sha="$(command git -C "$TF/repo" rev-parse HEAD)"
command git -C "$TF/repo" push -q origin "$unlinked_sha:refs/pull/78/head"
printf '%s\n' "$unlinked_sha" > "$TF/pr-head-78"
command git -C "$TF/repo" checkout -q main
command jq -n --arg sha "$unlinked_sha" \
  '{units:[{id:"pr-78",pr:78,lane:"pr",branch:"feature/unlinked",stage:"ready-to-merge",approved_sha:$sha,ready_since:1,history:[]}]}' \
  > "$TF/supervisor/autopi/units.json"
tick
command grep -q '^pr edit 78 --add-label pipeline-ci$' "$TF/actions"
command jq -e '.units[0].ci_adopt_head==.units[0].approved_sha and .units[0].stage=="ready-to-merge"' \
  "$TF/supervisor/autopi/units.json" >/dev/null
if command grep -q '^merge 78$' "$TF/actions"; then
  echo 'scheduler.test.sh: external PR merged before post-adoption checks ran' >&2
  exit 1
fi
printf 'old\n' > "$TF/pipeline-ci-adoption"
tick
if command grep -q '^merge 78$' "$TF/actions"; then
  echo 'scheduler.test.sh: external PR reused pre-adoption checks' >&2
  exit 1
fi
command grep -q 'required checks without a real pass:' "$TF/supervisor/autopi/scheduler.log"
printf 'fresh\n' > "$TF/pipeline-ci-adoption"
tick
command grep -q '^merge 78$' "$TF/actions"
if command grep -Eq '^issue (edit|comment) ' "$TF/actions"; then
  echo 'scheduler.test.sh: unlinked PR produced an issue write' >&2
  exit 1
fi
[[ ! -e "$TF/agent-home/state/78.json" ]]
if [[ -e "$TF/supervisor/autopi/alerts/merge.md" ]] \
  && command grep -q 'awaiting-release write failed' "$TF/supervisor/autopi/alerts/merge.md"; then
  echo 'unexpected merge alert for an unlinked unit' >&2
  exit 1
fi
export REQUIRED_PR_CHECKS_FILE="$test_env_root/required-pr-checks.json"
}
sched_run_case merge_release_state

sched_case_merge_release_write_failure() {
new_tick_fixture merge-release-write-failure
enable_rule_lane_fixture
command git -C "$TF/repo" checkout -qb release-write-77
mkdir -p "$TF/repo/packages/fixture/src"
printf 'export const release = true\n' > "$TF/repo/packages/fixture/src/index.ts"
command git -C "$TF/repo" add packages/fixture/src/index.ts
command git -C "$TF/repo" commit -qm 'release state source'
sha="$(command git -C "$TF/repo" rev-parse HEAD)"
command git -C "$TF/repo" push -q origin "$sha:refs/pull/77/head"
printf '%s\n' "$sha" > "$TF/pr-head-77"
command git -C "$TF/repo" checkout -q main
command jq '.auto_merge=true' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
command jq '.conclusion="success"' "$TF/run.json" > "$TF/run.tmp"; mv "$TF/run.tmp" "$TF/run.json"
export ZF_ROADMAP_TREE_CACHE_FILE="$TF/roadmap-tree.json"
command jq -cn '{roots:[4470] | map({number:.,title:("fixture issue " + tostring),state:"open",labels:[],children:[]})}' \
  > "$ZF_ROADMAP_TREE_CACHE_FILE"
command jq -n --arg sha "$sha" '{units:[{id:"pr-77",pr:77,issue:4470,lane:"pr",branch:"agent/issue-4470",stage:"ready-to-merge",approved_sha:$sha,ready_since:1,history:[]}]}' \
  > "$TF/supervisor/autopi/units.json"
echo 4470 > "$TF/fail-issue-edit"
tick
command grep -q '^merge 77' "$TF/actions"
command jq -e '.units[0].stage=="merged"' "$TF/supervisor/autopi/units.json" >/dev/null
command grep -q 'merged PR#77 but the awaiting-release write for issue #4470 failed' "$TF/supervisor/autopi/alerts/merge.md"
}
sched_run_case merge_release_write_failure

sched_case_merge_release_missing_sha() {
new_tick_fixture merge-release-missing-sha
enable_rule_lane_fixture
command git -C "$TF/repo" checkout -qb release-missing-77
mkdir -p "$TF/repo/packages/fixture/src"
printf 'export const release = true\n' > "$TF/repo/packages/fixture/src/index.ts"
command git -C "$TF/repo" add packages/fixture/src/index.ts
command git -C "$TF/repo" commit -qm 'release state source'
sha="$(command git -C "$TF/repo" rev-parse HEAD)"
command git -C "$TF/repo" push -q origin "$sha:refs/pull/77/head"
printf '%s\n' "$sha" > "$TF/pr-head-77"
command git -C "$TF/repo" checkout -q main
command jq '.auto_merge=true' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
command jq '.conclusion="success"' "$TF/run.json" > "$TF/run.tmp"; mv "$TF/run.tmp" "$TF/run.json"
export ZF_ROADMAP_TREE_CACHE_FILE="$TF/roadmap-tree.json"
command jq -cn '{roots:[4470] | map({number:.,title:("fixture issue " + tostring),state:"open",labels:[],children:[]})}' \
  > "$ZF_ROADMAP_TREE_CACHE_FILE"
command jq -n --arg sha "$sha" '{units:[{id:"pr-77",pr:77,issue:4470,lane:"pr",branch:"agent/issue-4470",stage:"ready-to-merge",approved_sha:$sha,ready_since:1,history:[]}]}' \
  > "$TF/supervisor/autopi/units.json"
touch "$TF/no-merge-sha"
tick
command grep -q '^merge 77' "$TF/actions"
command jq -e '.state=="awaiting-release" and .run.outcome=="merged"
  and .run.evidence.pr_number=="77" and .deploy_state=="pending"' \
  "$TF/agent-home/state/4470.json" >/dev/null
command grep -q 'entered awaiting-release at merge of PR#77' "$TF/supervisor/autopi/scheduler.log"
}
sched_run_case merge_release_missing_sha

sched_case_state_corruption() {
for corruption in shape drop concat; do
  new_tick_fixture "state-$corruption"
  echo '{"units":[{"id":"pr-one","stage":"review"},{"id":"pr-two","stage":"review"}]}' > "$TF/supervisor/autopi/units.json"
  echo "$corruption" > "$TF/corrupt-write"
  tick
  command jq -e -s 'length==1 and (.[0] | [.units[].id] == ["pr-one","pr-two"])' "$TF/supervisor/autopi/units.json" >/dev/null
  command grep -q 'write_state guard' "$TF/supervisor/autopi/scheduler.log"
done
}
sched_run_case state_corruption

sched_case_invalid_initial_state() {
new_tick_fixture invalid-initial-state
echo '{"units":{}}' > "$TF/supervisor/autopi/units.json"
if tick; then echo 'not ok - scheduler.test.sh: invalid initial schema was accepted' >&2; exit 1; fi
[[ ! -s "$TF/calls" ]]
}
sched_run_case invalid_initial_state

sched_case_worker_trim() {
new_tick_fixture worker-trim
command jq -n '{workers:[range(1;62) | {pid:.,unit:"pr-old",type:"review",harvested:true,started:("2026-10-17T00:00:"+tostring+"Z"),log:"unused",report:"unused"}]}' > "$TF/supervisor/autopi/workers.json"
tick
command jq -e '.workers | length==60' "$TF/supervisor/autopi/workers.json" >/dev/null
}
sched_run_case worker_trim

token_event() { # actual Codex JSONL protocol, with cumulative and latest-increment counters deliberately different
  command jq -cn --arg at "$1" --argjson input "$2" --argjson cached "$3" --argjson output "$4" \
    '{timestamp:$at,type:"event_msg",payload:{type:"token_count",info:{last_token_usage:{input_tokens:1,cached_input_tokens:0,output_tokens:1,total_tokens:2},total_token_usage:{input_tokens:$input,cached_input_tokens:$cached,output_tokens:$output,total_tokens:($input+$output)}}}}'
}
sched_case_cross_day_budget() {
new_tick_fixture cross-day-budget
yesterday="$(python3 -c 'from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(days=1)).date())')"
mkdir -p "$TF/sessions/${yesterday//-/\/}"
budget_session="$TF/sessions/${yesterday//-/\/}/rollout-11111111-2222-3333-4444-555555555555.jsonl"
token_event "${yesterday}T23:59:00Z" 100 30 20 > "$budget_session"
token_event "${TODAY}T00:01:00Z" 150 50 35 >> "$budget_session"
token_event "${TODAY}T00:02:00Z" 150 50 35 >> "$budget_session"
token_event "${TODAY}T00:03:00Z" 180 60 40 >> "$budget_session"
tick; tick
command jq -e '.total==100 and .in==80 and .cached==30 and .out==20' "$TF/supervisor/autopi/budget.json" >/dev/null
token_event "${TODAY}T00:04:00Z" 190 65 45 >> "$budget_session"
tick
command jq -e '.total==115 and .cached==35' "$TF/supervisor/autopi/budget.json" >/dev/null
# A same-day scanner failure must invalidate a previously measured total.
token_event "${TODAY}T00:05:00Z" 90 30 20 >> "$budget_session"
tick
command jq -e '.status=="unavailable" and .total==null' "$TF/supervisor/autopi/budget.json" >/dev/null
}
sched_run_case cross_day_budget

sched_case_dispatch_mode() {
for mode in resume fresh; do
  new_tick_fixture "dispatch-$mode"
  touch "$TF/allow-dispatch" "$TF/worker-alive"
  printf "NEW REVIEW FAILURE\n" > "$TF/supervisor/prior.md"
  command jq '.max_workers=1' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  command jq -n --arg mode "$mode" '{units:[{id:"pr-201",pr:201,lane:"pr",stage:"repair-pending",footprint:[],title:"token accounting",branch:"fix/token-fixture",review_report:"prior.md",history:[],sessions:(if $mode=="resume" then {repair:{id:"11111111-2222-3333-4444-555555555555",provider:"codex",model:"gpt-6-luna"}} else {} end),session_ids:{repair:(if $mode=="resume" then "11111111-2222-3333-4444-555555555555" else null end)}}]}' > "$TF/supervisor/autopi/units.json"
  mkdir -p "$TF/sessions/$session_day"
  dispatch_session="$TF/sessions/$session_day/rollout-11111111-2222-3333-4444-555555555555.jsonl"
  if [[ "$mode" == resume ]]; then token_event "${TODAY}T00:00:00Z" 100 30 20 > "$dispatch_session"; fi
  tick
  command jq -e --arg mode "$mode" '(.workers | length)==1 and (.workers[0] | .harvested!=true and .mode==$mode and .token_usage_start.input_tokens==(if $mode=="resume" then 100 else 0 end))' "$TF/supervisor/autopi/workers.json" >/dev/null
  token_event "${TODAY}T00:01:00Z" 120 40 30 >> "$dispatch_session"
  token_event "${TODAY}T00:02:00Z" 150 50 35 >> "$dispatch_session"
  worker_log="$(command jq -r '.workers[0].log' "$TF/supervisor/autopi/workers.json")"
  worker_report="$(command jq -r '.workers[0].report' "$TF/supervisor/autopi/workers.json")"
  echo 'session id: 11111111-2222-3333-4444-555555555555' > "$TF/supervisor/$worker_log"
  echo 'DELIVERED' > "$TF/supervisor/$worker_report"
  rm "$TF/worker-alive"
  command jq '.max_workers=0' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  tick; tick
  expected=65; [[ "$mode" == resume ]] || expected=185
  command jq -e --argjson expected "$expected" '.workers[0] | .harvested==true and .dispatch_tokens==$expected and .token_accounting=="measured" and (.finished_at|type)=="string"' "$TF/supervisor/autopi/workers.json" >/dev/null
  command jq -e --argjson expected "$expected" '.units[0].tokens==$expected' "$TF/supervisor/autopi/units.json" >/dev/null
done
}
sched_run_case dispatch_mode

sched_case_refill_entry() {
# #4628：worker 退出后 --refill 本地收割 direct-main 实现结果并派发等待中的实现；其他报告 harvest 留给慢 tick。
# 补派不跑登记/门禁/合并车道、不查询 GitHub 或远端。
# 共享台账锁被慢 tick 占住时返回 75、状态不动；PAUSE 下不派发。
new_tick_fixture refill-entry
command jq '.max_workers=1 | .implement_cap=1' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
true & refill_dead_pid=$!; wait "$refill_dead_pid"
command jq -n '{units:[
  {id:"issue-8802",lane:"direct-main",branch:"agent/issue-8802",task:"refill fixture task",footprint:[],stage:"implement-pending",history:[]},
  {id:"issue-8801",issue:8801,lane:"direct-main",branch:"agent/issue-8801",task:"refill completed fixture task",stage:"implement",history:[]},
  {id:"pr-8803",lane:"pr",branch:"agent/issue-8803",pr:8803,stage:"review-pending",history:[]},
  {id:"issue-8804",lane:"direct-main",branch:"agent/issue-8804",task:"blocked refill fixture",body_blocked_by:[4321],stage:"implement-pending",history:[]},
  {id:"issue-8805",lane:"direct-main",branch:"agent/issue-8805",task:"handoff refill fixture",handoff_start_ref:"rescue",handoff_start_sha:"0123456789abcdef0123456789abcdef01234567",stage:"implement-pending",history:[]},
  {id:"issue-8806",lane:"direct-main",branch:"agent/issue-8806",task:"budget refill fixture",stage:"implement-pending",history:[
    {stage:"write-start",at:"2026-10-29T00:00:00Z"},{stage:"write-start",at:"2026-10-29T00:00:00Z"},{stage:"write-start",at:"2026-10-29T00:00:00Z"}]}]}' > "$TF/supervisor/autopi/units.json"
command jq -n --argjson pid "$refill_dead_pid" \
  '{workers:[{pid:$pid,unit:"issue-8801",type:"implement",log:"impl-8801.log",report:"impl-8801.md",started:"2026-10-29T00:00:00Z",harvested:false}]}' > "$TF/supervisor/autopi/workers.json"
printf 'NEEDS-PR: fixture touches a product path\n' > "$TF/supervisor/impl-8801.md"
: > "$TF/supervisor/impl-8801.log"
cat > "$TF/bin/codex" <<'SH'
#!/usr/bin/env bash
[[ -f "$TF/allow-dispatch" ]] || { echo 'unexpected worker dispatch' >&2; exit 97; }
sleep 3
SH
chmod +x "$TF/bin/codex"
touch "$TF/allow-dispatch"
calls_before="$(wc -l < "$TF/calls")"
TF_REAL_PS=1 tick --refill
command jq -e '.units | length==6
  and any(.[]; .id=="issue-8802" and .stage=="implement")
  and any(.[]; .id=="issue-8801" and .lane=="pr" and .stage=="implement-pending")
  and any(.[]; .id=="pr-8803" and .stage=="review-pending")
  and any(.[]; .id=="issue-8804" and .stage=="implement-pending")
  and any(.[]; .id=="issue-8805" and .stage=="implement-pending")
  and any(.[]; .id=="issue-8806" and .stage=="implement-pending")' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { cat "$TF/tick.out" >&2; echo 'scheduler.test.sh: refill tick did not dispatch the waiting unit without harvesting the worker report' >&2; exit 1; }
command jq -e 'any(.workers[]; .unit=="issue-8802" and .type=="implement" and .harvested!=true)' "$TF/supervisor/autopi/workers.json" >/dev/null \
  || { cat "$TF/tick.out" >&2; echo 'scheduler.test.sh: refill tick did not record the dispatched worker' >&2; exit 1; }
command jq -e 'any(.workers[]; .unit=="issue-8801" and .harvested==true)' "$TF/supervisor/autopi/workers.json" >/dev/null \
  || { cat "$TF/tick.out" >&2; echo 'scheduler.test.sh: refill tick did not locally harvest the direct-main implementation result' >&2; exit 1; }
grep -Fq 'refill done' "$TF/supervisor/autopi/scheduler.log" || { cat "$TF/supervisor/autopi/scheduler.log" >&2; echo 'scheduler.test.sh: refill tick omitted its completion log line' >&2; exit 1; }
if grep -Fq 'tick done' "$TF/supervisor/autopi/scheduler.log"; then
  echo 'scheduler.test.sh: refill entry ran the slow tick' >&2; exit 1
fi
refill_calls="$(tail -n +$((calls_before + 1)) "$TF/calls")"
if grep -Eq '^gh ' <<<"$refill_calls" || grep -Eq '^git fetch .* origin([[:space:]]|$)' <<<"$refill_calls"; then
  printf '%s\n' "$refill_calls" >&2; echo 'scheduler.test.sh: refill tick touched GitHub or fetched a remote' >&2; exit 1
fi
refill_worker_pid="$(command jq -r '.workers[] | select(.unit=="issue-8802" and .harvested!=true) | .pid' "$TF/supervisor/autopi/workers.json")"
[[ "$refill_worker_pid" =~ ^[1-9][0-9]*$ ]] && kill -- "-$refill_worker_pid" 2>/dev/null || :
# 慢 tick 占着台账锁：补派静默跳过，台账不动。
refill_units_before="$(cat "$TF/supervisor/autopi/units.json")"
mkdir "$TF/supervisor/autopi/.scheduler.lock"; printf '%s\n' "$$" > "$TF/supervisor/autopi/.scheduler.lock/pid"
lock_rc=0; tick --refill || lock_rc=$?
[[ "$lock_rc" == 75 ]] || { echo "scheduler.test.sh: refill did not signal a busy shared lock (rc=$lock_rc)" >&2; exit 1; }
[[ "$(cat "$TF/supervisor/autopi/units.json")" == "$refill_units_before" ]] || { echo 'scheduler.test.sh: refill tick mutated state while the slow tick held the lock' >&2; exit 1; }
[[ "$(grep -c 'refill done' "$TF/supervisor/autopi/scheduler.log")" == 1 ]] || { echo 'scheduler.test.sh: refill tick did not skip while the lock was held' >&2; exit 1; }

# PAUSE：补派不派发；worker report 由慢 tick harvest。
new_tick_fixture refill-pause
command jq '.max_workers=2 | .implement_cap=2' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
true & refill_dead_pid=$!; wait "$refill_dead_pid"
command jq -n '{units:[
  {id:"pr-8801",lane:"pr",branch:"agent/pr-8801",stage:"implement",history:[]},
  {id:"issue-8802",lane:"direct-main",branch:"agent/issue-8802",task:"refill fixture task",footprint:[],stage:"implement-pending",history:[]}]}' > "$TF/supervisor/autopi/units.json"
command jq -n --argjson pid "$refill_dead_pid" \
  '{workers:[{pid:$pid,unit:"pr-8801",type:"implement",log:"impl-8801.log",report:"impl-8801.md",started:"2026-10-29T00:00:00Z",harvested:false}]}' > "$TF/supervisor/autopi/workers.json"
printf 'OBSOLETE: refill fixture\n' > "$TF/supervisor/impl-8801.md"
: > "$TF/supervisor/impl-8801.log"
touch "$TF/pause"
TF_REAL_PS=1 tick --refill
command jq -e '.units | length==2
  and any(.[]; .id=="pr-8801" and .stage=="implement")
  and any(.[]; .id=="issue-8802" and .stage=="implement-pending")' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { cat "$TF/tick.out" >&2; echo 'scheduler.test.sh: paused refill tick dispatched a pending unit' >&2; exit 1; }
command jq -e 'all(.workers[]; .harvested!=true)' "$TF/supervisor/autopi/workers.json" >/dev/null \
  || { echo 'scheduler.test.sh: paused refill tick harvested a worker report' >&2; exit 1; }
}
sched_run_case refill_entry

sched_case_refill_yields_shared_lock() {
# A slow GitHub phase gives the independent refill entry a chance to acquire the existing ledger lock.
local old_lock="$SCHED_LOCK" lock_root probe
lock_root="$(mktemp -d)"; SCHED_LOCK="$lock_root/.scheduler.lock"; SCHED_LOCK_HELD=false
acquire_scheduler_lock || { echo 'scheduler.test.sh: could not acquire fixture scheduler lock' >&2; exit 1; }
probe() {
  [[ ! -e "$SCHED_LOCK" ]] || return 1
  mkdir "$SCHED_LOCK" || return 1
  printf '%s\n' "$BASHPID" > "$SCHED_LOCK/pid"
  rm -rf -- "$SCHED_LOCK"
}
phase_yield_lock probe || { echo 'scheduler.test.sh: slow phase did not yield the shared scheduler lock' >&2; exit 1; }
[[ "$SCHED_LOCK_HELD" == true && "$(cat "$SCHED_LOCK/pid")" == "$BASHPID" ]] \
  || { echo 'scheduler.test.sh: slow phase did not reacquire the shared scheduler lock' >&2; exit 1; }
release_scheduler_lock
SCHED_LOCK="$old_lock"; rm -rf -- "$lock_root"
}
sched_run_case refill_yields_shared_lock

sched_case_accounting() {
for missing in missing-baseline missing-end session-changed counter-reset; do
  new_tick_fixture "accounting-$missing"
  echo '{"units":[{"id":"pr-301","stage":"review","tokens":42,"history":[]}]}' > "$TF/supervisor/autopi/units.json"
  command jq -n --arg missing "$missing" '{workers:[{pid:999999999,unit:"pr-301",type:"review",mode:"resume",session_id:"11111111-2222-3333-4444-555555555555",started:"2026-10-17T00:00:00Z",log:"review.log",report:"review.md",token_usage_start:(if $missing=="missing-baseline" then null else {input_tokens:100,cached_input_tokens:30,output_tokens:20} end)}]}' > "$TF/supervisor/autopi/workers.json"
  actual_session=11111111-2222-3333-4444-555555555555
  [[ "$missing" != session-changed ]] || actual_session=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
  echo "session id: $actual_session" > "$TF/supervisor/review.log"
  echo APPROVE > "$TF/supervisor/review.md"
  mkdir -p "$TF/sessions/$session_day"
  if [[ "$missing" != missing-end ]]; then
    input=150; [[ "$missing" != counter-reset ]] || input=90
    token_event "${TODAY}T00:01:00Z" "$input" 40 35 > "$TF/sessions/$session_day/rollout-$actual_session.jsonl"
  fi
  tick
  command jq -e --arg missing "$missing" '.workers[0].dispatch_tokens==null and .workers[0].token_accounting==$missing' "$TF/supervisor/autopi/workers.json" >/dev/null
  command jq -e '.units[0].tokens==42' "$TF/supervisor/autopi/units.json" >/dev/null
done
}
sched_run_case accounting

sched_case_pause_phases() {
# PAUSE keeps dispatch/merge phases stopped while the release train still runs.
# live_event_watch stays on under pause (#4501): closing an already-landed
# ticket on an observed production event is harvest/verification, not dispatch.
(
  pause_dir="$(mktemp -d)"
  ROOT="$pause_dir" A="$pause_dir" LOG="$pause_dir/log" STAMP=test SCHED_LOCK="$pause_dir/lock"
  UNITS="$pause_dir/units.json" WORKERS="$pause_dir/workers.json" PAUSE_FILE="$pause_dir/PAUSE"
  echo '{"units":[]}' > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; touch "$PAUSE_FILE"
  acquire_scheduler_lock() { return 0; }
  jqf() { command jq "$@"; }
  git() { return 1; }
  say() { :; }
  phase() { echo "$1" >> "$pause_dir/phases"; }
  for stub in rotate_logs update_budget budget_alert_if_needed cleanup_tick flush_focus_alert publish_pr_run_snapshot launch_views live_event_watch live_workers; do
    eval "$stub() { :; }"
  done
  eval "$(command sed -n '/^main() {/,/^}/p' "$scheduler")"
  main
  [[ "$(command cat "$pause_dir/phases")" == $'harvest_workers\nreconcile_size_recuts\nself_check_harvest\nprecheck_harvest\nrecover_orphans\nrecover_orphan_landing\nlive_event_watch\nrun_release_train' ]] \
    || { echo 'PAUSE must allow harvest and release train phases only' >&2; exit 1; }
)
}
sched_run_case pause_phases

sched_case_release_train_proxy() {
# 发布列车单元转发与 triage 批次相同的整套代理变量（含小写与 NODE_USE_ENV_PROXY）
train_dir="$(mktemp -d)"
(
  A="$train_dir" HERE="$train_dir/code" ROOT=/fixture/root HOME=/fixture/home CFG='{}'
  mkdir -p "$HERE"
  unset http_proxy https_proxy no_proxy
  export HTTPS_PROXY=http://bridge:1 HTTP_PROXY=http://bridge:1 NO_PROXY=localhost
  touch "$HERE/release_train.sh"; ZF_RELEASE_TRAIN_SCRIPT="$HERE/release_train.sh"
  jqf() { command jq "$@"; }
  say() { :; }
  systemctl() { return 3; }
  systemd-run() { printf '%s\n' "$@" "lower=${https_proxy-unset}|${http_proxy-unset}|${no_proxy-unset}" > "$train_dir/args"; }
  eval "$(command sed -n '/^run_release_train() {/,/^}/p' "$scheduler")"
  CFG='{"release_train":{"enabled":false}}'
  run_release_train
  [[ ! -e "$train_dir/args" ]] || { echo 'release_train_proxy: explicit disabled config started the train' >&2; exit 1; }
  CFG='{}'
  run_release_train
)
for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy ALL_PROXY NODE_USE_ENV_PROXY; do
  command grep -qxF "$v" "$train_dir/args"
done
# 空的小写 https_proxy 让 git 直连被墙的 GitHub：只有大写时，列车拿到的小写必须是大写的值
command grep -qxF 'lower=http://bridge:1|http://bridge:1|localhost' "$train_dir/args" || { echo 'train gets empty lowercase proxy vars' >&2; exit 1; }
rm -rf "$train_dir"
}
sched_run_case release_train_proxy

sched_case_classify_lane() {
# 车道分类：gh 不接受 --slurp 与 --jq 同用（10-20 起每次都失败、没有单元拿到车道）；按页 --jq 后本地合并
lane_dir="$(mktemp -d)"
classify_case() ( # files... → classify_lane 的输出或 FAIL
  printf '%s\n' "$@" > "$lane_dir/files"
  ROOT="$script_dir/../.."; POLICY_SCRIPT="$POLICY_FIXTURE"
  gh() {
    [[ " $* " == *" --slurp "* && " $* " == *" --jq "* ]] && { echo 'the `--slurp` option is not supported with `--jq` or `--template`' >&2; return 1; }
    [[ "$1 $2" == "api --paginate" && "$3" == "repos/{owner}/{repo}/pulls/77/files" ]] || return 1
    command cat "$lane_dir/files"
  }
  eval "$(command sed -n '/^classify_lane() {/,/^}/p' "$scheduler")"
  classify_lane 77 || echo FAIL
)
[[ "$(classify_case engine/lib.sh docs/agents/issue-pipeline.md)" == direct-main ]] || { echo 'non-product PR not classified direct-main' >&2; exit 1; }
[[ "$(classify_case engine/lib.sh packages/example-service/src/app.ts)" == pr ]] || { echo 'product PR not classified pr' >&2; exit 1; }
[[ "$(classify_case)" == FAIL ]] || { echo 'an empty file list was classified' >&2; exit 1; }
rm -rf "$lane_dir"
}
sched_run_case classify_lane

sched_case_fast_land() {
# 快车道候选：策略过期的 pr 车道单元要回来重分；策略当前的 pr 车道单元不进
fl_dir="$(mktemp -d)"
cat > "$fl_dir/units.json" <<'JSON'
{"units":[
 {"id":"pr-1","pr":1,"stage":"ready-to-merge","lane":"pr","lane_policy":"old"},
 {"id":"pr-2","pr":2,"stage":"ready-to-merge","lane":"pr","lane_policy":"cur"},
 {"id":"pr-3","pr":3,"stage":"ready-to-merge","lane":"pr"},
 {"id":"pr-4","pr":4,"stage":"ready-to-merge"},
 {"id":"pr-5","pr":5,"stage":"reviewing","lane":"pr","lane_policy":"old"}
]}
JSON
got="$(
  UNITS="$fl_dir/units.json"
  jqf() { command jq "$@" 2>/dev/null; }
  eval "$(command sed -n '/^lane_policy_blob() {/p; /^fast_land_candidates() {/,/^}/p' "$scheduler")"
  lane_policy_blob() { echo cur; }
  fast_land_candidates | command jq -r .id | paste -sd' '
)"
[[ "$got" == "pr-1 pr-3 pr-4" ]] || { echo "fast-land candidates wrong: $got" >&2; exit 1; }
rm -rf "$fl_dir"
}
sched_run_case fast_land

sched_case_footprint_mutex() {
# #4190/#4192/#4193: same-file writers wait; sibling files still run.
(
  # #4488 二轮起派发检查会读 ROOT 的共同修改历史；空目录没有 git 历史，
  # 热点扩展退回原足迹，下面的用例只受声明的足迹影响。
  ROOT="$(mktemp -d)"
  # The active-footprint snapshot is cached for the length of a tick; this case rewrites the workers between checks, so each check
  # starts from a fresh snapshot.
  footprint_room() { TICK_ACTIVE_FOOTPRINTS_VALID=false; TICK_FOOTPRINT_CONFLICT_VALID=false; _footprint_room "$@"; }
  UNITS="$fixture_supervisor/autopi/footprint-units.json"
  WORKERS="$fixture_supervisor/autopi/footprint-workers.json"
  cat > "$UNITS" <<'JSON'
{"units":[
 {"id":"a","stage":"implement","footprint":["packages/example/hooks/__init__.py"]},
 {"id":"b","stage":"implement-pending","footprint":["packages/example/hooks/__init__.py"]},
 {"id":"c","stage":"implement-pending","footprint":["packages/example/hooks/other.py"]},
 {"id":"d","stage":"repair-pending","footprint":["packages/example/hooks"]}]}
JSON
  echo '{"workers":[{"pid":123,"unit":"a","type":"implement"}]}' > "$WORKERS"
  if footprint_room b; then echo 'same-file implement admitted' >&2; exit 1; fi
  footprint_room c
  if footprint_room d; then echo 'directory/file repair overlap admitted' >&2; exit 1; fi
  # Completed workers release ownership; a review never reserves write scope.
  echo '{"workers":[{"pid":123,"unit":"a","type":"implement","harvested":true},{"pid":124,"unit":"a","type":"review"}]}' > "$WORKERS"
  footprint_room b
  # M2 故障注入接缝（#4498）：config footprint_mutex.enabled=false 跳过互斥——冲突单元放行，不再记 footprint wait
  echo '{"workers":[{"pid":123,"unit":"a","type":"implement"}]}' > "$WORKERS"
  : >> "$LOG"; before_lines="$(wc -l < "$LOG")"
  CFG='{"footprint_mutex":{"enabled":false}}'
  footprint_room b
  [[ "$(wc -l < "$LOG")" == "$before_lines" ]] || { echo 'kill switch still logged a footprint wait' >&2; exit 1; }
  CFG='{}'
  if footprint_room b; then echo 'same-file implement admitted without the kill switch' >&2; exit 1; fi
  # #4488: 在跑 unit 实际改过（预测之外）的文件挡住新派发；workdir 不可读时退回预测足迹。
  wdir="$(mktemp -d)"
  git -C "$wdir" init -q -b main
  git -C "$wdir" -c user.email=t@example.invalid -c user.name=test commit -q --allow-empty -m base
  git -C "$wdir" update-ref refs/remotes/origin/main HEAD
  mkdir -p "$wdir/tests/contract"
  printf 'x\n' > "$wdir/tests/contract/v4-mcp-tools.test.ts"
  git -C "$wdir" add -A
  git -C "$wdir" -c user.email=t@example.invalid -c user.name=test commit -q -m 'shared test edit'
  cat > "$UNITS" <<'JSON'
{"units":[
 {"id":"a","stage":"implement","footprint":["packages/example/hooks/__init__.py"]},
 {"id":"e","stage":"implement-pending","footprint":["tests/contract/v4-mcp-tools.test.ts"]}]}
JSON
  echo "{\"workers\":[{\"pid\":125,\"unit\":\"a\",\"type\":\"implement\",\"workdir\":\"$wdir\"}]}" > "$WORKERS"
  if footprint_room e; then echo 'committed live write beyond prediction admitted' >&2; exit 1; fi
  printf 'y\n' > "$wdir/tests/contract/untracked-yet.test.ts"
  cat > "$UNITS" <<'JSON'
{"units":[
 {"id":"a","stage":"implement","footprint":["packages/example/hooks/__init__.py"]},
 {"id":"f","stage":"implement-pending","footprint":["tests/contract/untracked-yet.test.ts"]}]}
JSON
  if footprint_room f; then echo 'untracked live write beyond prediction admitted' >&2; exit 1; fi
  cat > "$UNITS" <<'JSON'
{"units":[
 {"id":"a","stage":"implement","footprint":["packages/example/hooks/__init__.py"]},
 {"id":"g","stage":"implement-pending","footprint":["packages/example/hooks/other.py"]}]}
JSON
  echo '{"workers":[{"pid":125,"unit":"a","type":"implement","workdir":"/nonexistent/live-writes"}]}' > "$WORKERS"
  footprint_room g
  rm -rf -- "$wdir"
  # #4488 二轮：与预测文件在 git log 里反复共同修改的热点文件并入待派发 unit
  # 的检查范围，预测范围不相交但历史耦合的候选先排队；扩展不写回 .footprint。
  hdir="$(mktemp -d)"
  git -C "$hdir" init -q -b main
  hseq=0
  hcommit() { # file... -> 一次共同修改提交（序号保证内容各不相同）
    local f
    for f in "$@"; do mkdir -p "$hdir/$(dirname "$f")"; printf 'v%s\n' "$((++hseq))" > "$hdir/$f"; done
    git -C "$hdir" add -A
    git -C "$hdir" -c user.email=t@example.invalid -c user.name=test commit -q -m "co-mod $*"
  }
  qrt='packages/example-pack/src/v4/query-runtime.ts'
  hooks='packages/example-pack/runtime/agent/example-hooks/__init__.py'
  hcommit "$qrt" "$hooks"
  hcommit "$qrt" "$hooks"
  hcommit "$qrt" docs/only-once.md
  ROOT="$hdir"
  [[ "$(hotspot_expand "[\"$qrt\"]")" == "[\"$hooks\",\"$qrt\"]" ]]
  [[ "$(hotspot_expand '["packages/example-pack/src/v4"]')" == "[\"$hooks\",\"packages/example-pack/src/v4\"]" ]]
  cat > "$UNITS" <<'JSON'
{"units":[
 {"id":"a","stage":"implement","footprint":["packages/example-pack/runtime/agent/example-hooks/__init__.py"]},
 {"id":"h","stage":"implement-pending","footprint":["packages/example-pack/src/v4/query-runtime.ts"]},
 {"id":"i","stage":"implement-pending","footprint":["packages/nobody/touched-this.ts"]}]}
JSON
  echo '{"workers":[{"pid":126,"unit":"a","type":"implement"}]}' > "$WORKERS"
  if footprint_room h; then echo 'co-modification hotspot beyond prediction admitted' >&2; exit 1; fi
  [[ "$(jqf -r '.units[] | select(.id=="h") | (.footprint // []) | join(",")' "$UNITS")" == "$qrt" ]]
  footprint_room i
  echo '{"workers":[{"pid":126,"unit":"a","type":"implement","harvested":true}]}' > "$WORKERS"
  footprint_room h
  rm -rf -- "$hdir"
  ROOT="$(cd "$script_dir/../.." && pwd -P)"
  mkdir -p "$AGENT_HOME/state"
  echo '{"expected_paths":["packages/example/hooks/__init__.py"],"expected_packages":["packages/example"]}' > "$AGENT_HOME/state/4190.json"
  [[ "$(scheduler_footprint '{"issue":4190}')" == '["packages/example/hooks/__init__.py"]' ]]
  echo '{"expected_packages":["packages/example/hooks/__init__.py"]}' > "$AGENT_HOME/state/4190.json"
  [[ "$(scheduler_footprint '{"issue":4190}')" == '["packages/example"]' ]]
)
}
sched_run_case footprint_mutex

sched_case_hold_handoff_resume() {
  new_tick_fixture hold-handoff-resume
  export AGENT_HOME="$TF/agent-home"
  mkdir -p "$AGENT_HOME/state"
  source_repo="$TF/resume-source"; remote="$TF/resume-origin.git"
  command git init -q --bare "$remote"
  command git init -q -b main "$source_repo"
  command git -C "$source_repo" config user.name test
  command git -C "$source_repo" config user.email test@example.invalid
  command git -C "$source_repo" commit -q --allow-empty -m base
  command git -C "$source_repo" remote add origin "$remote"
  command git -C "$source_repo" push -q origin main
  command git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
  main_sha="$(command git -C "$source_repo" rev-parse HEAD)"
  command git -C "$source_repo" checkout -q -b agent/issue-777
  command git -C "$source_repo" commit -q --allow-empty -m old-branch
  command git -C "$source_repo" push -q origin agent/issue-777
  command git -C "$source_repo" checkout -q -b agent/auto-issue-777 "$main_sha"
  command git -C "$source_repo" commit -q --allow-empty -m old-direct-branch
  command git -C "$source_repo" push -q origin agent/auto-issue-777
  command git -C "$source_repo" checkout -q -b rescued/issue-777-new "$main_sha"
  command git -C "$source_repo" commit -q --allow-empty -m recovered-work
  rescue_sha="$(command git -C "$source_repo" rev-parse HEAD)"
  command git -C "$source_repo" push -q origin rescued/issue-777-new
  command git -C "$source_repo" checkout -q main
  command git -C "$source_repo" fetch -q origin '+refs/heads/rescued/issue-777-new:refs/remotes/origin/rescued/issue-777-new'
  old_worktree="$TF/hand-777"
  command git -C "$source_repo" worktree add -q -b hand/issue-777 "$old_worktree" "$rescue_sha"
  printf 'committed work\n' > "$old_worktree/prior.txt"
  command git -C "$old_worktree" add prior.txt
  command git -C "$old_worktree" commit -q -m 'prior local work'
  old_head="$(command git -C "$old_worktree" rev-parse HEAD)"
  printf 'uncommitted change\n' >> "$old_worktree/prior.txt"
  printf 'untracked work\n' > "$old_worktree/untracked.txt"
  mkdir -p "$old_worktree/output"
  printf 'untracked report\n' > "$old_worktree/output/report.txt"
  command jq -n --arg sha "$rescue_sha" '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-777",start_ref:"rescued/issue-777-new",start_sha:$sha}}' > "$AGENT_HOME/state/777.json"
  command jq -n '{number:777,title:"recovered work",body:"finish the prior change",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
  command jq '.max_workers=1 | .implement_cap=0 | .issue_intake.enabled=true' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
  mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  tick
  recovered_branch="agent/issue-777-recovered-${rescue_sha:0:12}"
  command jq -e --arg sha "$rescue_sha" --arg branch "$recovered_branch" 'any(.units[]; .issue==777 and .stage=="implement-pending" and .branch==$branch and .handoff_start_ref=="rescued/issue-777-new" and .handoff_start_sha==$sha)' \
    "$TF/supervisor/autopi/units.json" >/dev/null || { echo 'not ok - scheduler tick lost the held issue or its rescued commit' >&2; exit 1; }
  (
    ROOT="$source_repo"; WT_ROOT="$TF/real-clones"; MAIN_HEAD="$main_sha"; UNITS="$TF/supervisor/autopi/units.json"
    # Use a full fixture checkout so the test can inspect its exact commit.
    command jq '.units[0].lane="direct-main"' "$UNITS" > "$TF/units.tmp"; mv "$TF/units.tmp" "$UNITS"
    wt="$(ensure_clone issue-777 "$recovered_branch" 0 '' rescued/issue-777-new "$rescue_sha")"
    [[ "$(command git -C "$wt" rev-parse HEAD)" == "$rescue_sha" ]] || { echo 'not ok - scheduler checkout did not resume the rescued commit' >&2; exit 1; }
    command git -C "$wt" push -q origin "HEAD:refs/heads/$recovered_branch" || { echo 'not ok - recovered branch could not be pushed without force' >&2; exit 1; }
    direct_branch="agent/auto-issue-777-recovered-${rescue_sha:0:12}"
    wt="$(ensure_clone issue-778 "$direct_branch" 0 '' rescued/issue-777-new "$rescue_sha")"
    [[ "$(command git -C "$wt" rev-parse HEAD)" == "$rescue_sha" ]] || { echo 'not ok - direct-main recovery used its older branch instead of the rescue' >&2; exit 1; }
    wt="$(handoff_worktree_clone issue-779 agent/issue-777-preserved "$old_worktree" "$old_head" true)"
    command git -C "$wt" merge-base --is-ancestor "$old_head" HEAD || { echo 'not ok - handoff lost the prior local commit' >&2; exit 1; }
    cmp "$old_worktree/prior.txt" "$wt/prior.txt" && cmp "$old_worktree/untracked.txt" "$wt/untracked.txt" \
      || { echo 'not ok - handoff lost uncommitted or untracked work' >&2; exit 1; }
    [[ "$(command git -C "$wt" show HEAD:prior.txt)" == $'committed work\nuncommitted change' && "$(command git -C "$wt" show HEAD:untracked.txt)" == 'untracked work' ]] \
      || { echo 'not ok - the exact dirty work was not anchored in the handoff commit' >&2; exit 1; }
    [[ -n "$(command git -C "$old_worktree" status --porcelain)" ]] || { echo 'not ok - handoff changed the original worktree' >&2; exit 1; }
    pr_head="$(command git -C "$source_repo" rev-parse refs/remotes/origin/agent/issue-777)"
    wt="$(handoff_worktree_clone issue-780 agent/issue-777 "$old_worktree" "$old_head" true 1)"
    command git -C "$wt" merge-base --is-ancestor "$pr_head" HEAD && command git -C "$wt" merge-base --is-ancestor "$old_head" HEAD \
      || { echo 'not ok - handoff lost the existing PR or local commit history' >&2; exit 1; }
    cmp "$old_worktree/prior.txt" "$wt/prior.txt" && cmp "$old_worktree/untracked.txt" "$wt/untracked.txt" \
      || { echo 'not ok - PR handoff lost dirty work' >&2; exit 1; }
    snapshot_sha="$(command git -C "$wt" rev-parse HEAD)"
    command jq -n --arg sha "$old_head" '{units:[{id:"issue-780",issue:780,stage:"implement",lane:"direct-main",branch:"agent/issue-777",history:[],handoff_worktree_sha:$sha,handoff_start_ref:"rescued/issue-777-new"}]}' > "$UNITS"
    record_handoff_integration issue-780 "$wt" "$pr_head"
    command jq -e --arg sha "$snapshot_sha" '.units[0].handoff_worktree_applied==true and .units[0].handoff_start_applied==true and .units[0].handoff_integration_sha==$sha' "$UNITS" >/dev/null \
      || { echo 'not ok - preserved work was not recorded before the worker could wait for capacity' >&2; exit 1; }
    wt="$(ensure_clone issue-780 agent/issue-777 1)"
    resume_handoff_integration issue-780 "$wt"
    [[ "$(command git -C "$wt" rev-parse HEAD)" == "$snapshot_sha" ]] \
      || { echo 'not ok - retry lost or reapplied the preserved work' >&2; exit 1; }
    printf 'NEEDS-PR: product files required\n' > "$TF/needs-pr.report"
    if ! harvest_prless_implement issue-780 "$TF/needs-pr.report"; then
      echo 'not ok - direct-main NEEDS-PR report was not harvested' >&2; exit 1
    fi
    command jq -e '.units[0].stage=="implement-pending" and .units[0].lane=="pr" and .units[0].branch=="agent/issue-780"' "$UNITS" >/dev/null \
      || { echo 'not ok - direct-main handoff did not switch to PR implementation' >&2; exit 1; }
    wt="$(ensure_clone issue-780 agent/issue-780 0)"
    resume_handoff_integration issue-780 "$wt"
    command git -C "$wt" merge-base --is-ancestor "$snapshot_sha" HEAD \
      || { echo 'not ok - direct-main to PR conversion lost the preserved work' >&2; exit 1; }
    wt="$(handoff_worktree_clone issue-784 agent/issue-777 "" "$rescue_sha" false 1 rescued/issue-777-new)"
    command git -C "$wt" merge-base --is-ancestor "$pr_head" HEAD && command git -C "$wt" merge-base --is-ancestor "$rescue_sha" HEAD \
      || { echo 'not ok - later PR did not retain both its head and the rescued commit' >&2; exit 1; }
    command git -C "$source_repo" checkout -q -b rescued/issue-777-separate "$main_sha"
    printf 'separate rescue\n' > "$source_repo/rescue.txt"
    command git -C "$source_repo" add rescue.txt
    command git -C "$source_repo" commit -q -m 'independent rescue'
    separate_sha="$(command git -C "$source_repo" rev-parse HEAD)"
    command git -C "$source_repo" push -q origin rescued/issue-777-separate
    command git -C "$source_repo" checkout -q main
    wt="$(handoff_worktree_clone issue-785 agent/issue-777 "$old_worktree" "$old_head" true 1 rescued/issue-777-separate "$separate_sha")"
    command git -C "$wt" merge-base --is-ancestor "$pr_head" HEAD && command git -C "$wt" merge-base --is-ancestor "$old_head" HEAD && command git -C "$wt" merge-base --is-ancestor "$separate_sha" HEAD \
      && cmp "$old_worktree/prior.txt" "$wt/prior.txt" \
      || { echo 'not ok - PR, owner and separate rescue were not all preserved' >&2; exit 1; }
    command git -C "$source_repo" checkout -q -b agent/stacked-base "$main_sha"
    printf 'stacked prerequisite\n' > "$source_repo/stack.txt"
    command git -C "$source_repo" add stack.txt
    command git -C "$source_repo" commit -q -m 'stacked prerequisite'
    stack_sha="$(command git -C "$source_repo" rev-parse HEAD)"
    command git -C "$source_repo" push -q origin agent/stacked-base
    command git -C "$source_repo" checkout -q main
    wt="$(handoff_worktree_clone issue-787 agent/issue-777 "$old_worktree" "$old_head" true 1 rescued/issue-777-separate "$separate_sha" agent/stacked-base "$stack_sha")"
    command git -C "$wt" merge-base --is-ancestor "$old_head" HEAD && command git -C "$wt" merge-base --is-ancestor "$separate_sha" HEAD && command git -C "$wt" merge-base --is-ancestor "$stack_sha" HEAD \
      || { echo 'not ok - stacked prerequisite displaced prior handoff work' >&2; exit 1; }
    wt="$(ensure_clone issue-786 agent/issue-777 1)"
    command git -C "$source_repo" checkout -q -b hand/late-777 "$old_head"
    printf 'late local work\n' > "$source_repo/late.txt"
    command git -C "$source_repo" add late.txt
    command git -C "$source_repo" commit -q -m 'late local work'
    late_sha="$(command git -C "$source_repo" rev-parse HEAD)"
    command git -C "$source_repo" checkout -q main
    if command git -C "$wt" cat-file -e "$late_sha^{commit}" 2>/dev/null; then echo 'not ok - fixture clone already had late local commit' >&2; exit 1; fi
    wt="$(handoff_worktree_clone issue-786 agent/issue-777 "" "$late_sha" false 1 rescued/issue-777-separate "$separate_sha")"
    command git -C "$wt" merge-base --is-ancestor "$late_sha" HEAD && command git -C "$wt" merge-base --is-ancestor "$separate_sha" HEAD \
      || { echo 'not ok - existing clone lost the later local commit or the rescue' >&2; exit 1; }
    status=0
    handoff_worktree_clone issue-788 agent/issue-777 "$TF/missing-old-worktree" "$old_head" true 1 >/dev/null 2>&1 || status=$?
    [[ "$status" == 73 ]] || { echo 'not ok - missing dirty worktree was not surfaced for recovery' >&2; exit 1; }
    command git -C "$source_repo" checkout -q agent/issue-777
    printf 'output/\n' > "$source_repo/.gitignore"
    command git -C "$source_repo" add .gitignore
    command git -C "$source_repo" commit -q -m 'ignore generated output'
    command git -C "$source_repo" push -q origin agent/issue-777
    command git -C "$source_repo" checkout -q main
    wt="$(handoff_worktree_clone issue-789 agent/issue-777 "$old_worktree" "$old_head" true 1)"
    [[ "$(command git -C "$wt" show HEAD:output/report.txt)" == 'untracked report' ]] \
      || { echo 'not ok - new PR ignore rule omitted the old untracked work' >&2; exit 1; }
    command git -C "$source_repo" checkout -q agent/issue-777
    printf 'PR version\n' > "$source_repo/untracked.txt"
    command git -C "$source_repo" add untracked.txt
    command git -C "$source_repo" commit -q -m 'PR added same path'
    command git -C "$source_repo" push -q origin agent/issue-777
    command git -C "$source_repo" checkout -q main
    status=0
    handoff_worktree_clone issue-781 agent/issue-777 "$old_worktree" "$old_head" true 1 >/dev/null || status=$?
    [[ "$status" == 73 && "$(cat "$old_worktree/untracked.txt")" == 'untracked work' && "$(cat "$WT_ROOT/wt-issue-781/untracked.txt")" == 'PR version' ]] \
      || { echo 'not ok - same-path untracked work overwrote the PR version' >&2; exit 1; }
    command git -C "$source_repo" checkout -q -b agent/patch-test "$old_head"
    printf 'PR changed prior line\n' > "$source_repo/prior.txt"
    command git -C "$source_repo" add prior.txt
    command git -C "$source_repo" commit -q -m 'PR changed dirty path'
    command git -C "$source_repo" push -q origin agent/patch-test
    command git -C "$source_repo" checkout -q main
    status=0
    handoff_worktree_clone issue-782 agent/patch-test "$old_worktree" "$old_head" true 1 >/dev/null 2>&1 || status=$?
    [[ "$status" == 73 && "$(cat "$old_worktree/prior.txt")" == $'committed work\nuncommitted change' && "$(cat "$WT_ROOT/wt-issue-782/prior.txt")" == 'PR changed prior line' ]] \
      || { echo 'not ok - conflicting dirty patch did not preserve both versions' >&2; exit 1; }
    command git -C "$source_repo" checkout -q -b agent/merge-test "$main_sha"
    printf 'PR added prior file\n' > "$source_repo/prior.txt"
    command git -C "$source_repo" add prior.txt
    command git -C "$source_repo" commit -q -m 'PR added prior path'
    command git -C "$source_repo" push -q origin agent/merge-test
    command git -C "$source_repo" checkout -q main
    status=0
    handoff_worktree_clone issue-783 agent/merge-test "$old_worktree" "$old_head" true 1 >/dev/null 2>&1 || status=$?
    [[ "$status" == 73 && "$(cat "$old_worktree/prior.txt")" == $'committed work\nuncommitted change' && "$(cat "$WT_ROOT/wt-issue-783/prior.txt")" == 'PR added prior file' ]] \
      || { echo 'not ok - conflicting commits did not preserve both versions' >&2; exit 1; }
    if ensure_clone issue-778 agent/issue-778 0 '' rescued/issue-777-new 0000000000000000000000000000000000000000 >/dev/null; then
      echo 'not ok - scheduler accepted a changed rescued commit' >&2; exit 1
    fi
  )
  new_tick_fixture hold-handoff-direct
  mkdir -p "$TF/agent-home/state"
  command jq -n --arg sha "$rescue_sha" '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-777",start_ref:"rescued/issue-777-new",start_sha:$sha}}' > "$TF/agent-home/state/777.json"
  command jq -n '{number:777,title:"direct recovered work",body:"finish",labels:[{name:"ready-for-agent"},{name:"pipeline-system"}]}' > "$TF/intake-issue.json"
  command jq '.max_workers=1 | .implement_cap=0 | .issue_intake.enabled=true' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  tick
  command jq -e --arg branch "agent/auto-issue-777-recovered-${rescue_sha:0:12}" '.units[0].lane=="direct-main" and .units[0].branch==$branch' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - direct-main intake did not select a fresh rescue branch' >&2; exit 1; }
}
sched_run_case hold_handoff_resume

sched_case_hold_handoff_existing_unit() {
  local mode n
  for mode in implement repair active live; do
    new_tick_fixture "hold-handoff-existing-$mode"
    mkdir -p "$TF/agent-home/state"
    n=778
    command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-778"}}' > "$TF/agent-home/state/$n.json"
    command jq -n --argjson n "$n" '{number:$n,title:"resume held work",body:"finish the work",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
    command jq '.max_workers=2 | .implement_cap=0 | .issue_intake.enabled=true | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
    mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
    command jq -n --arg mode "$mode" --argjson n "$n" '{units:[{id:"existing",issue:$n,title:"resume held work",task:"prior work",lane:"pr",branch:"agent/issue-778",history:[],stage:(if $mode=="active" then "implement-pending" elif $mode=="live" then "implement" else "parked" end)} + (if $mode=="repair" then {pr:778} else {} end)]}' > "$TF/supervisor/autopi/units.json"
    if [[ "$mode" == live ]]; then
      touch "$TF/worker-alive"
      command jq -n '{workers:[{pid:99999998,unit:"existing",type:"implement",harvested:false}]}' > "$TF/supervisor/autopi/workers.json"
    fi
    tick
    if [[ "$mode" == live ]]; then
      command jq -e '.units[0].stage=="implement" and (.units[0].hold_handoff_episode // "")==""' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo 'not ok - a live worker consumed an unread handoff' >&2; exit 1; }
      rm "$TF/worker-alive"
      command jq '.workers[0].harvested=true' "$TF/supervisor/autopi/workers.json" > "$TF/workers.tmp"; mv "$TF/workers.tmp" "$TF/supervisor/autopi/workers.json"
      command jq '.units[0].stage="supervisor-review"' "$TF/supervisor/autopi/units.json" > "$TF/units.tmp"; mv "$TF/units.tmp" "$TF/supervisor/autopi/units.json"
      tick
    fi
    case "$mode" in
      implement) expected=implement-pending ;;
      repair) expected=repair-pending ;;
      active) expected=implement-pending ;;
      live) expected=implement-pending ;;
    esac
    command jq -e --arg stage "$expected" '(.units|length)==1 and .units[0].stage==$stage and .units[0].hold_handoff_episode=="hold-778"' \
      "$TF/supervisor/autopi/units.json" >/dev/null || { echo "not ok - $mode existing unit did not consume the hold handoff" >&2; exit 1; }
    tick
    command jq -e --arg stage "$expected" '(.units|length)==1 and .units[0].stage==$stage and ([.units[0].history[] | select(.stage=="supervisor-requeue")] | length) <= 1' \
      "$TF/supervisor/autopi/units.json" >/dev/null || { echo "not ok - $mode hold handoff was repeated" >&2; exit 1; }
    if [[ "$mode" == implement ]]; then
      touch "$TF/allow-dispatch" "$TF/worker-alive"
      command jq '.implement_cap=1' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
      mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
      tick
      command jq -e '([.workers[] | select(.unit=="existing" and .type=="implement" and .harvested!=true)] | length)==1' \
        "$TF/supervisor/autopi/workers.json" >/dev/null || { echo 'not ok - resumed existing unit was not dispatched' >&2; exit 1; }
      tick
      command jq -e '([.workers[] | select(.unit=="existing" and .type=="implement" and .harvested!=true)] | length)==1' \
        "$TF/supervisor/autopi/workers.json" >/dev/null || { echo 'not ok - hold handoff dispatched a duplicate worker' >&2; exit 1; }
    fi
  done
}
sched_run_case hold_handoff_existing_unit

sched_case_hold_handoff_new_pr_contract() {
  local mode previous_pr previous_lane expected_lane sha
  for mode in product nonproduct closed absent same same-changed; do
    new_tick_fixture "hold-handoff-new-pr-$mode"
    enable_rule_lane_fixture
    mkdir -p "$TF/agent-home/state"
    # The replacement PR needs a real head: the merge lane rule-checks the exact approved SHA.
    command git -C "$TF/repo" checkout -qb fix/replacement
    mkdir -p "$TF/repo/packages/fixture/src"
    printf 'export const replacement = true\n' > "$TF/repo/packages/fixture/src/index.ts"
    command git -C "$TF/repo" add packages/fixture/src/index.ts
    command git -C "$TF/repo" commit -qm 'replacement work'
    sha="$(command git -C "$TF/repo" rev-parse HEAD)"
    command git -C "$TF/repo" push -q origin "$sha:refs/pull/779/head"
    printf '%s\n' "$sha" > "$TF/pr-head-779"
    command git -C "$TF/repo" checkout -q main
    previous_pr=778; previous_lane=direct-main; expected_lane=pr
    [[ "$mode" != nonproduct ]] || { previous_lane=pr; expected_lane=direct-main; }
    [[ "$mode" != closed ]] || expected_lane=direct-main
    [[ "$mode" != absent ]] || { previous_pr=null; previous_lane=pr; expected_lane=pr; }
    [[ "$mode" != same ]] || { previous_pr=779; previous_lane=pr; expected_lane=pr; }
    [[ "$mode" != same-changed ]] || { previous_pr=779; previous_lane=direct-main; expected_lane=pr; }
    command jq -n --arg mode "$mode" '{state:"ready-for-agent",scheduler_handoff:({episode:"hold-779"} + (if $mode=="closed" or $mode=="absent" then {} else {open_pr:779,open_branch:"fix/replacement"} end))}' > "$TF/agent-home/state/779.json"
    command jq -n '{number:779,title:"resume held work",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
    command jq -n --arg mode "$mode" 'if $mode=="closed" or $mode=="absent" then [] else [{number:779,headRefName:"fix/replacement",title:"replacement",body:"Refs #779",labels:[]}] end' > "$TF/handoff-lookup.json"
    command jq -n '[{number:778,headRefName:"fix/old",title:"old",body:"",state:"CLOSED",labels:[]}]' > "$TF/handoff-pr-view.json"
    echo 778 > "$TF/closed-prs"
    if [[ "$mode" == nonproduct ]]; then echo 'docs/agents/issue-pipeline.md' > "$TF/pr-files"; else echo 'packages/fixture/src/index.ts' > "$TF/pr-files"; fi
    command jq '.max_workers=2 | .implement_cap=0 | .auto_merge=false | .issue_intake.enabled=true | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
    command jq -n --argjson pr "$previous_pr" --arg lane "$previous_lane" --arg sha "$sha" '{units:[{id:"existing",issue:779,pr:$pr,branch:"fix/old",lane:$lane,stage:"supervisor-review",history:[],ci_adopt_head:$sha,ci_adopt_at:"2026-10-01T00:00:00Z",ci_sync_head:$sha,ci_ready_sha:$sha,ci_ready_at:"2026-10-01T00:00:00Z",ci_held_sha:$sha,ci_wip_wait:$sha,gated:true,lane_policy:"old",product_paths:false}]}' > "$TF/supervisor/autopi/units.json"
    if [[ "$mode" == product ]]; then
      touch "$TF/pr-files-fail"
      tick
      command jq -e '.units[0].stage=="supervisor-review" and .units[0].pr==778 and .units[0].hold_handoff_waiting==true' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo 'not ok - unreadable replacement PR files did not keep the old unit waiting' >&2; exit 1; }
      ! grep -q '^merge ' "$TF/actions" || { echo 'not ok - unreadable replacement PR was merged' >&2; exit 1; }
      rm "$TF/pr-files-fail"
    fi
    tick
    if [[ "$mode" == same || "$mode" == same-changed ]]; then
      command jq -e --arg lane "$expected_lane" '.units[0].pr==779 and .units[0].stage=="repair-pending" and .units[0].lane==$lane and .units[0].ci_adopt_at=="2026-10-01T00:00:00Z" and .units[0].product_paths==null and .units[0].lane_policy!="old"' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo 'not ok - same PR lost reusable adoption evidence' >&2; exit 1; }
    else
      command jq -e --arg mode "$mode" --arg lane "$expected_lane" '.units[0] | .lane==$lane and .stage==(if $mode=="closed" or $mode=="absent" then "implement-pending" else "repair-pending" end) and (if $mode=="closed" or $mode=="absent" then .pr==null and .lane_policy==null else .pr==779 and (.lane_policy | type)=="string" and .lane_policy!="old" end) and .ci_adopt_head==null and .ci_adopt_at==null and .ci_sync_head==null and .ci_ready_sha==null and .ci_ready_at==null and .ci_held_sha==null and .ci_wip_wait==null and .gated==null and .product_paths==null' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo "not ok - $mode handoff reused the previous PR lane or CI evidence" >&2; exit 1; }
    fi
    if [[ "$mode" == product ]]; then
      printf '%s\n' '{"databaseId":701,"attempt":1,"status":"completed","conclusion":"success","createdAt":"2026-10-29T00:00:00Z"}' > "$TF/run.json"
      printf '%s\n' '{"required":["Enforce branch delivery policy","Required CI gates","Required contract gates"]}' > "$TF/required-pr-checks.json"
      export REQUIRED_PR_CHECKS_FILE="$TF/required-pr-checks.json"
      command jq '.auto_merge=true' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
      command jq --arg sha "$sha" '.units[0].stage="ready-to-merge" | .units[0].approved_sha=$sha' "$TF/supervisor/autopi/units.json" > "$TF/units.tmp"; mv "$TF/units.tmp" "$TF/supervisor/autopi/units.json"
      printf 'old\n' > "$TF/pipeline-ci-adoption"
      tick
      grep -Fq 'gh pr edit 779 --add-label pipeline-ci' "$TF/calls" \
        || { echo 'not ok - replacement PR did not start its own CI adoption' >&2; exit 1; }
      ! grep -q '^merge 779$' "$TF/actions" || { echo 'not ok - replacement PR merged before its own CI' >&2; exit 1; }
      tick
      ! grep -q '^merge 779$' "$TF/actions" || { echo 'not ok - replacement PR accepted old CI checks' >&2; exit 1; }
      printf 'fresh\n' > "$TF/pipeline-ci-adoption"
      tick
      grep -q '^merge 779$' "$TF/actions" || { echo 'not ok - replacement PR did not merge after fresh CI' >&2; exit 1; }
      export REQUIRED_PR_CHECKS_FILE="$test_env_root/required-pr-checks.json"
    fi
  done
}
sched_run_case hold_handoff_new_pr_contract

sched_case_hold_handoff_auto_registered_pr() {
  local sha
  sha="$(printf '%040x' 779)"
  new_tick_fixture hold-handoff-auto-registered-pr
  mkdir -p "$TF/agent-home/state"
  command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779",open_pr:779,open_branch:"fix/replacement"}}' > "$TF/agent-home/state/779.json"
  command jq -n '{number:779,title:"resume held work",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
  command jq -n '[{number:779,headRefName:"fix/replacement",title:"replacement",body:"Refs #779",labels:[]}]' > "$TF/handoff-lookup.json"
  command jq -n --arg sha "$sha" '[{number:779,headRefName:"fix/replacement",headRefOid:$sha,isDraft:false,title:"replacement",labels:[],statusCheckRollup:[]}]' > "$TF/pr-census.json"
  echo 'docs/agents/issue-pipeline.md' > "$TF/pr-files"
  command jq '.max_workers=0 | .auto_dispatch_new_prs=true | .issue_intake.enabled=false | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  touch "$TF/pr-files-fail"
  tick
  command jq -e '.units | length==1 and .[0].id=="pr-779" and .[0].stage=="review-pending" and .[0].hold_handoff_waiting==true and .[0].hold_handoff_episode==null' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { cat "$TF/supervisor/autopi/units.json" >&2; tail -n 40 "$TF/supervisor/autopi/scheduler.log" >&2; cat "$TF/tick.out" >&2; echo 'not ok - automatically registered PR bypassed an unreadable handoff classification' >&2; exit 1; }
  ! grep -q 'dispatch mode=.*unit=pr-779' "$TF/supervisor/autopi/scheduler.log" || { echo 'not ok - unclassified handoff was dispatched' >&2; exit 1; }
  rm "$TF/pr-files-fail"
  tick
  command jq -e '.units | length==1 and .[0].issue==779 and .[0].stage=="repair-pending" and .[0].lane=="direct-main" and .[0].hold_handoff_episode=="hold-779"' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - automatically registered PR did not resume on its classified lane' >&2; exit 1; }
}
sched_run_case hold_handoff_auto_registered_pr

sched_case_hold_handoff_preserved_clone() {
  local clone owner base_sha old_sha handoff_sha today i
  new_tick_fixture hold-handoff-preserved-clone
  clone="$TF/clones/wt-issue-779"
  owner="$TF/hand-779"
  mkdir -p "$TF/agent-home/state" "$TF/clones"
  command git init -q -b main "$clone"
  command git -C "$clone" config user.name test
  command git -C "$clone" config user.email test@example.invalid
  command git -C "$clone" commit -q --allow-empty -m base
  base_sha="$(command git -C "$clone" rev-parse HEAD)"
  command git -C "$clone" update-ref refs/remotes/origin/main "$base_sha"
  command git -C "$clone" checkout -q -b agent/issue-779
  printf 'unpublished prior work\n' > "$clone/prior.txt"
  command git -C "$clone" add prior.txt
  command git -C "$clone" commit -q -m 'unpublished prior work'
  old_sha="$(command git -C "$clone" rev-parse HEAD)"
  command git -C "$clone" worktree add -q -b hand/issue-779 "$owner" "$base_sha"
  printf 'new owner work\n' > "$owner/handoff.txt"
  command git -C "$owner" add handoff.txt
  command git -C "$owner" commit -q -m 'new handoff work'
  handoff_sha="$(command git -C "$owner" rev-parse HEAD)"
  touch "$TF/real-clone-git"
  command jq -n --arg path "$owner" --arg sha "$handoff_sha" '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779",worktree:$path,worktree_sha:$sha,worktree_dirty:false}}' > "$TF/agent-home/state/779.json"
  command jq -n '{number:779,title:"resume held work",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
  command jq '.max_workers=1 | .implement_cap=1 | .issue_intake.enabled=true | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  command jq -n '{units:[{id:"issue-779",issue:779,branch:"agent/issue-779",lane:"pr",stage:"closed",history:[]}]}' > "$TF/supervisor/autopi/units.json"
  mkdir -p "$TF/agent-home/night" "$TF/agent-home/logs"
  today="$(date -u +%Y-%m-%d)"
  command jq -n --arg day "$today" '{date:$day,demoted_classes:["handoff-preserved-clone"]}' > "$TF/agent-home/night/supervisor-alert-policy.json"
  for i in $(seq 1 21); do printf '%sT00:00:00Z\thandoff-preserved-clone\tfixture\n' "$today"; done > "$TF/agent-home/logs/supervisor-wakes.log"
  tick
  command jq -e '.units[0].stage=="closed" and .units[0].hold_handoff_waiting==true and .units[0].hold_handoff_episode==null' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - handoff reused the unit with an unpublished clone' >&2; exit 1; }
  [[ "$(command git -C "$clone" rev-parse HEAD)" == "$old_sha" && "$(command git -C "$clone" show "$old_sha:prior.txt")" == 'unpublished prior work' ]] \
    || { echo 'not ok - terminal cleanup lost the unpublished prior commit' >&2; exit 1; }
  grep -Fq 'handoff-preserved-clone issue=#779' "$TF/agent-home/supervisor-inbox" \
    || { echo 'not ok - preserved clone did not reach the supervisor' >&2; exit 1; }
  ! grep -q 'dispatch mode=.*unit=issue-779' "$TF/supervisor/autopi/scheduler.log" \
    || { echo 'not ok - handoff dispatched before preserving the old clone' >&2; exit 1; }
  tick
  [[ "$(grep -c 'handoff-preserved-clone issue=#779' "$TF/agent-home/supervisor-inbox")" == 1 ]] \
    || { echo 'not ok - preserved clone sent duplicate supervisor events' >&2; exit 1; }
  command jq '.scheduler_handoff.episode="hold-779-second"' "$TF/agent-home/state/779.json" > "$TF/state.tmp"; mv "$TF/state.tmp" "$TF/agent-home/state/779.json"
  tick
  [[ "$(grep -c 'handoff-preserved-clone issue=#779' "$TF/agent-home/supervisor-inbox")" == 2 ]] \
    || { echo 'not ok - a new preserved-clone episode was hidden from the supervisor' >&2; exit 1; }
  command git -C "$clone" update-ref refs/remotes/origin/agent/issue-779 "$old_sha"
  command jq '.implement_cap=0' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  tick
  command jq -e '.units[0].stage=="implement-pending" and .units[0].hold_handoff_episode=="hold-779-second"' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - handoff stayed blocked after the prior commit was preserved' >&2; exit 1; }
}
sched_run_case hold_handoff_preserved_clone

sched_case_hold_handoff_multiple_clones() {
  local id clone base_sha old_sha pr_sha
  new_tick_fixture hold-handoff-multiple-clones
  mkdir -p "$TF/agent-home/state" "$TF/clones"
  for id in issue-779 pr-779; do
    clone="$TF/clones/wt-$id"
    command git init -q -b main "$clone"
    command git -C "$clone" config user.name test
    command git -C "$clone" config user.email test@example.invalid
    command git -C "$clone" commit -q --allow-empty -m base
    base_sha="$(command git -C "$clone" rev-parse HEAD)"
    command git -C "$clone" update-ref refs/remotes/origin/main "$base_sha"
    command git -C "$clone" checkout -q -b "work/$id"
    printf '%s\n' "$id unpublished work" > "$clone/work.txt"
    command git -C "$clone" add work.txt
    command git -C "$clone" commit -q -m "unpublished $id"
  done
  old_sha="$(command git -C "$TF/clones/wt-issue-779" rev-parse HEAD)"
  pr_sha="$(command git -C "$TF/clones/wt-pr-779" rev-parse HEAD)"
  touch "$TF/real-clone-git"
  command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779",open_pr:779,open_branch:"fix/replacement"}}' > "$TF/agent-home/state/779.json"
  command jq -n '{number:779,title:"resume held work",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
  command jq -n '[{number:779,headRefName:"fix/replacement",title:"replacement",body:"Refs #779",labels:[]}]' > "$TF/handoff-lookup.json"
  command jq '.max_workers=0 | .implement_cap=0 | .issue_intake.enabled=true | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  command jq -n '{units:[{id:"issue-779",issue:779,branch:"agent/issue-779",lane:"pr",stage:"closed",history:[]},{id:"pr-779",pr:779,branch:"fix/replacement",lane:"pr",stage:"supervisor-review",history:[]}]}' > "$TF/supervisor/autopi/units.json"
  tick
  command jq -e '.units[0].stage=="closed" and .units[1].stage=="supervisor-review" and all(.units[]; .hold_handoff_waiting==true and .hold_handoff_episode==null)' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - multiple unfinished clones did not hold the handoff' >&2; exit 1; }
  [[ "$(command git -C "$TF/clones/wt-issue-779" rev-parse HEAD)" == "$old_sha" && "$(command git -C "$TF/clones/wt-pr-779" rev-parse HEAD)" == "$pr_sha" ]] \
    || { echo 'not ok - handoff changed an unfinished related clone' >&2; exit 1; }
  grep -Fq 'unit=issue-779 ' "$TF/agent-home/supervisor-inbox" && grep -Fq 'unit=pr-779 ' "$TF/agent-home/supervisor-inbox" \
    || { echo 'not ok - supervisor was not notified about both unfinished clones' >&2; exit 1; }
  tick
  [[ "$(grep -c 'handoff-preserved-clone issue=#779' "$TF/agent-home/supervisor-inbox")" == 2 ]] \
    || { echo 'not ok - related clone events were repeated or collapsed together' >&2; exit 1; }
  command git -C "$TF/clones/wt-pr-779" update-ref refs/remotes/origin/work/pr-779 "$pr_sha"
  tick
  command jq -e '.units[0].stage=="closed" and .units[1].stage=="supervisor-review" and all(.units[]; .hold_handoff_waiting==true)' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - handoff ignored the remaining unfinished clone' >&2; exit 1; }
  command git -C "$TF/clones/wt-issue-779" update-ref refs/remotes/origin/work/issue-779 "$old_sha"
  tick
  command jq -e '.units[0].stage=="parked" and .units[1].stage=="repair-pending" and .units[1].pr==779 and .units[1].hold_handoff_episode=="hold-779"' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - handoff did not resume after both clones were preserved' >&2; exit 1; }
}
sched_run_case hold_handoff_multiple_clones

sched_case_hold_handoff_open_pr() {
  local existing
  for existing in no yes outside-census stale; do
    new_tick_fixture "hold-handoff-open-pr-$existing"
    mkdir -p "$TF/agent-home/state"
    command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779",open_pr:779,open_branch:"agent/issue-779"}}' > "$TF/agent-home/state/779.json"
    command jq -n '{number:779,title:"handoff with open PR",body:"fix prior finding",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
    if [[ "$existing" == yes ]]; then
      command jq -n '{units:[{id:"pr-779",pr:779,branch:"agent/issue-779",lane:"pr",stage:"supervisor-review",history:[]}]}' > "$TF/supervisor/autopi/units.json"
    elif [[ "$existing" == stale ]]; then
      command jq -n '{units:[{id:"issue-779",issue:779,pr:778,branch:"agent/old",lane:"pr",stage:"ready-to-merge",history:[]}]}' > "$TF/supervisor/autopi/units.json"
    fi
    [[ "$existing" == outside-census ]] || printf 'agent/issue-779 issue #779\n' > "$TF/busy-pr"
    command jq '.max_workers=1 | .implement_cap=0 | .issue_intake.enabled=true | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
    tick
    command jq -e '(.units|length)==1 and .units[0].issue==779 and .units[0].pr==779 and .units[0].branch=="agent/issue-779" and .units[0].stage=="repair-pending" and (.units[0].repair_hint|contains("issue comments"))' \
      "$TF/supervisor/autopi/units.json" >/dev/null || { echo "not ok - open PR handoff ($existing existing unit) was not routed to repair" >&2; exit 1; }
  done
}
sched_run_case hold_handoff_open_pr

sched_case_hold_handoff_saturation_and_ownership() {
  new_tick_fixture hold-handoff-saturation
  mkdir -p "$TF/agent-home/state"
  command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779",open_pr:779,open_branch:"agent/issue-779"}}' > "$TF/agent-home/state/779.json"
  command jq -n '{number:779,title:"handoff with open PR",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
  command jq '.max_workers=1 | .implement_cap=0 | .auto_merge=true | .issue_intake.enabled=true | .issue_intake.max_ready=1 | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  command jq -n '{units:[
    {id:"issue-779",issue:779,pr:778,branch:"agent/old",lane:"pr",stage:"ready-to-merge",approved_sha:"000000000000000000000000000000000000030a",history:[]},
    {id:"pr-779",pr:779,branch:"agent/issue-779",lane:"pr",stage:"review",history:[]}]}' > "$TF/supervisor/autopi/units.json"
  command jq -n '{workers:[{pid:99999998,unit:"pr-779",type:"review",harvested:false}]}' > "$TF/supervisor/autopi/workers.json"
  touch "$TF/worker-alive"
  tick
  command jq -e 'all(.units[]; .hold_handoff_waiting==true) and .units[0].stage=="ready-to-merge" and .units[1].stage=="review"' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - handoff did not wait for the other live unit at saturation' >&2; exit 1; }
  ! grep -q '^merge ' "$TF/actions" || { echo 'not ok - old approval merged before the handoff' >&2; exit 1; }
  rm "$TF/worker-alive"
  command jq '.workers[0].harvested=true' "$TF/supervisor/autopi/workers.json" > "$TF/workers.tmp"; mv "$TF/workers.tmp" "$TF/supervisor/autopi/workers.json"
  command jq '.units[1].stage="ready-to-merge"' "$TF/supervisor/autopi/units.json" > "$TF/units.tmp"; mv "$TF/units.tmp" "$TF/supervisor/autopi/units.json"
  tick
  command jq -e '.units[0].stage=="parked" and .units[1].stage=="repair-pending" and .units[1].pr==779 and .units[1].issue==779' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - handoff did not reconcile the duplicate units' >&2; exit 1; }
  ! grep -q '^merge ' "$TF/actions" || { echo 'not ok - old approval merged at a full ready queue' >&2; exit 1; }

  new_tick_fixture hold-handoff-self-check
  mkdir -p "$TF/agent-home/state"
  command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779",open_pr:779,open_branch:"agent/issue-779"}}' > "$TF/agent-home/state/779.json"
  command jq -n '{number:779,title:"self check",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
  command jq '.max_workers=2 | .implement_cap=0 | .issue_intake.enabled=true | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  command jq -n --argjson pid "$$" --arg out "$TF/self-check" '{units:[{id:"issue-779",issue:779,pr:779,branch:"agent/issue-779",lane:"pr",stage:"review-pending",history:[],self_check_pid:$pid,self_check_output:$out,self_fix_pending:true}]}' > "$TF/supervisor/autopi/units.json"
  tick
  command jq -e '.units[0].hold_handoff_waiting==true and .units[0].stage=="review-pending" and .units[0].self_check_pid!=null' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - handoff raced the running self-check' >&2; exit 1; }
  command jq 'del(.units[0].self_check_pid)' "$TF/supervisor/autopi/units.json" > "$TF/units.tmp"; mv "$TF/units.tmp" "$TF/supervisor/autopi/units.json"
  tick
  command jq -e '.units[0].stage=="repair-pending" and (.units[0].self_fix_pending // false)==false' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - finished self-check did not release the handoff to repair' >&2; exit 1; }

  new_tick_fixture hold-handoff-precheck-disabled
  mkdir -p "$TF/agent-home/state"
  command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779",open_pr:779,open_branch:"agent/issue-779"}}' > "$TF/agent-home/state/779.json"
  command jq -n '{number:779,title:"precheck",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
  command jq '.max_workers=1 | .implement_cap=0 | .precheck=false | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  command jq -n '{units:[{id:"issue-779",issue:779,pr:779,branch:"agent/issue-779",lane:"pr",stage:"ready-to-merge",history:[],precheck_pid:99999998,precheck_head:"000000000000000000000000000000000000030b"}]}' > "$TF/supervisor/autopi/units.json"
  printf 'PRECHECK: PASS\n' > "$TF/supervisor/precheck-issue-779.out"
  tick
  command jq -e '.units[0].precheck_pid==null and .units[0].stage=="repair-pending" and any(.units[0].history[]; .stage=="precheck")' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - disabled precheck stranded a completed handoff' >&2; exit 1; }
}
sched_run_case hold_handoff_saturation_and_ownership

sched_case_hold_handoff_github_changed() {
  local mode
  for mode in closed held; do
    new_tick_fixture "hold-handoff-github-$mode"
    mkdir -p "$TF/agent-home/state"
    command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779",open_pr:779,open_branch:"agent/issue-779"}}' > "$TF/agent-home/state/779.json"
    command jq -n --arg mode "$mode" '{number:779,title:"changed after handoff",body:"finish",state:(if $mode=="closed" then "CLOSED" else "OPEN" end),labels:([{name:"ready-for-agent"}] + (if $mode=="held" then [{name:"on-hold"}] else [] end))}' > "$TF/intake-issue.json"
    command jq '.max_workers=2 | .auto_merge=true | .issue_intake.enabled=true | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
    command jq -n '{units:[{id:"issue-779",issue:779,pr:779,branch:"agent/issue-779",lane:"pr",stage:"ready-to-merge",history:[]}]}' > "$TF/supervisor/autopi/units.json"
    tick
    command jq -e '.units[0].hold_handoff_waiting==true and .units[0].stage=="ready-to-merge"' "$TF/supervisor/autopi/units.json" >/dev/null \
      || { echo "not ok - $mode issue was resumed despite its current GitHub state" >&2; exit 1; }
    ! grep -q '^merge ' "$TF/actions" || { echo "not ok - $mode issue merged an old approval" >&2; exit 1; }
  done
}
sched_run_case hold_handoff_github_changed

sched_case_hold_handoff_pr_lookup_failure() {
  local mode branch
  for mode in standard nonstandard partial unavailable; do
  new_tick_fixture "hold-handoff-pr-lookup-$mode"
  mkdir -p "$TF/agent-home/state"
  command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779"}}' > "$TF/agent-home/state/779.json"
  command jq -n '{number:779,title:"handoff",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
  command jq '.max_workers=1 | .implement_cap=0 | .auto_merge=true | .issue_intake.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  branch=agent/issue-779; [[ "$mode" == standard ]] || branch=fix/other
  command jq -n --arg branch "$branch" --arg sha "$(printf '%040x' 779)" '{units:[{id:"pr-779",pr:779,branch:$branch,lane:"pr",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}' > "$TF/supervisor/autopi/units.json"
  if [[ "$mode" == partial ]]; then
    command jq '.units += [{id:"pr-901",pr:901,branch:"fix/unreadable",lane:"pr",stage:"ready-to-merge",history:[]},{id:"pr-902",pr:902,stage:"closed",history:[]}]' "$TF/supervisor/autopi/units.json" > "$TF/units.tmp"; mv "$TF/units.tmp" "$TF/supervisor/autopi/units.json"
  fi
  touch "$TF/handoff-lookup-fail"
  if [[ "$mode" == nonstandard || "$mode" == partial ]]; then
    command jq -n '[{number:779,headRefName:"fix/other",title:"existing",body:"Fixes #779"}]' > "$TF/handoff-lookup.json"
  fi
  tick
  command jq -e '.units[0].hold_handoff_waiting==true' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - failed PR lookup left the previous approval runnable' >&2; exit 1; }
  if [[ "$mode" == partial ]]; then
    command jq -e '.units[1].hold_handoff_lookup_pending==true and .units[1].hold_handoff_waiting==true' "$TF/supervisor/autopi/units.json" >/dev/null \
      || { echo 'not ok - unreadable PR was not held during partial lookup' >&2; exit 1; }
    ! grep -q 'gh pr view 902 --json number,headRefName,title,body,state' "$TF/calls" \
      || { echo 'not ok - fallback queried a closed historical PR' >&2; exit 1; }
  fi
  if [[ "$mode" == nonstandard || "$mode" == partial ]]; then
    if [[ "$mode" == partial ]]; then
      command jq -n '[{number:779,headRefName:"fix/other",title:"existing",body:"Fixes #779"},{number:901,headRefName:"fix/unreadable",body:"Fixes #901"}]' > "$TF/handoff-lookup.json"
    fi
    rm "$TF/handoff-lookup-fail"
    tick
    command jq -e '.units[0].issue==779 and .units[0].stage=="repair-pending" and .units[0].approved_sha==null' "$TF/supervisor/autopi/units.json" >/dev/null \
      || { echo "not ok - resolved PR lookup ($mode) did not release the handoff" >&2; command jq -c '.units' "$TF/supervisor/autopi/units.json" >&2; exit 1; }
    if [[ "$mode" == partial ]]; then
      command jq -e '(.units[1].hold_handoff_waiting // false)==false' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo 'not ok - resolved PR lookup left an unrelated PR frozen' >&2; exit 1; }
    fi
  fi
  ! grep -q '^merge ' "$TF/actions" || { echo 'not ok - PR lookup failure released a stale merge' >&2; exit 1; }
  done
}
sched_run_case hold_handoff_pr_lookup_failure

sched_case_hold_handoff_hotfix_pr() {
  local mode sha
  sha="$(printf '%040x' 779)"
  for mode in census census-priority recorded recorded-priority recorded-census-large recorded-large unit review priority ready ready-priority unreadable unreadable-priority blocker-hotfix blocker-unreadable blocker-partial; do
    new_tick_fixture "hold-handoff-hotfix-$mode"
    mkdir -p "$TF/agent-home/state"
    command jq -n --arg mode "$mode" '{state:"ready-for-agent",scheduler_handoff:({episode:"hold-779"} + (if ($mode | startswith("recorded")) or ($mode | startswith("unreadable")) or $mode=="blocker-unreadable" then {open_pr:779,open_branch:"agent/issue-779"} else {} end))}' > "$TF/agent-home/state/779.json"
    command jq -n '{number:779,title:"handoff",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
    command jq '.max_workers=2 | .implement_cap=1 | .auto_merge=true | .auto_dispatch_new_prs=true | .issue_intake.enabled=true | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
    command jq -n --arg sha "$sha" '[{number:779,headRefName:"agent/issue-779",headRefOid:$sha,isDraft:false,title:"hotfix",labels:[{name:"hotfix"},{name:"agent/ci-gated"}],statusCheckRollup:[]}]' > "$TF/pr-census.json"
    case "$mode" in
      census|census-priority|blocker-hotfix) command jq -n '[{number:779,headRefName:"agent/issue-779",title:"hotfix",body:"Refs #779",labels:[{name:"hotfix"}]}]' > "$TF/handoff-lookup.json" ;;
      recorded|recorded-priority) echo '[]' > "$TF/handoff-lookup.json"; command jq -n '[{number:779,headRefName:"agent/issue-779",title:"hotfix",body:"",labels:[{name:"hotfix"}]}]' > "$TF/handoff-pr-view.json" ;;
      recorded-census-large) command jq -n '[{number:779,headRefName:"agent/issue-779",title:"hotfix",body:("Refs #779\n" + ("字" * 50000)),labels:[{name:"hotfix"}]}]' > "$TF/handoff-lookup.json" ;;
      recorded-large) echo '[]' > "$TF/handoff-lookup.json"; command jq -n '[{number:779,headRefName:"agent/issue-779",title:"hotfix",body:("Refs #779\n" + ("字" * 50000)),labels:[{name:"hotfix"}]}]' > "$TF/handoff-pr-view.json" ;;
      unit) command jq -n '[{number:779,headRefName:"fix/hotfix",title:"hotfix",body:"",labels:[{name:"hotfix"}]}]' > "$TF/handoff-lookup.json" ;;
      review|priority|ready|ready-priority) command jq -n '[{number:779,headRefName:"agent/issue-779",title:"hotfix",body:"Refs #779",labels:[{name:"hotfix"}]}]' > "$TF/handoff-lookup.json" ;;
      unreadable|unreadable-priority|blocker-unreadable) echo '[]' > "$TF/handoff-lookup.json"; command jq -n '[{number:779,headRefName:"agent/issue-779",title:"hotfix",body:"",labels:null}]' > "$TF/handoff-pr-view.json" ;;
      blocker-partial) touch "$TF/handoff-lookup-fail"; command jq -n '[{number:779,headRefName:"agent/issue-779",title:"hotfix",body:"Refs #779",labels:[{name:"hotfix"}]}]' > "$TF/handoff-pr-view.json" ;;
    esac
    if [[ "$mode" == unit || "$mode" == review || "$mode" == priority || "$mode" == ready || "$mode" == ready-priority || "$mode" == unreadable ]]; then
      local fixture_branch="agent/issue-779"
      [[ "$mode" != unit ]] || fixture_branch="fix/hotfix"
      command jq --arg branch "$fixture_branch" '.[0].headRefName=$branch' "$TF/pr-census.json" > "$TF/census.tmp"; mv "$TF/census.tmp" "$TF/pr-census.json"
      command jq -n --arg branch "$fixture_branch" --arg mode "$mode" --arg sha "$sha" '{units:[{id:"issue-779",issue:779,pr:779,branch:$branch,lane:"pr",stage:(if $mode=="ready" or $mode=="ready-priority" then "ready-to-merge" elif $mode=="review" then "review" elif $mode=="priority" then "review-pending" else "repair-pending" end),approved_sha:$sha,ci_priority:($mode=="ready-priority"),history:[]}]}' > "$TF/supervisor/autopi/units.json"
      if [[ "$mode" == review ]]; then
        touch "$TF/worker-alive"
        command jq -n '{workers:[{pid:99999998,unit:"issue-779",type:"review",harvested:false}]}' > "$TF/supervisor/autopi/workers.json"
      fi
    fi
    command jq -n --arg sha "$sha" --arg branch "${fixture_branch:-agent/issue-779}" '[{databaseId:9902,status:"queued",event:"pull_request",headBranch:$branch,headSha:$sha,workflowName:"CI"}]' > "$TF/queued-pr-runs.json"
    if [[ "$mode" == priority || "$mode" == census-priority || "$mode" == recorded-priority || "$mode" == unreadable-priority ]]; then
      command jq '.units += [{id:"priority",pr:9903,branch:"fix/priority",lane:"pr",stage:"ready-to-merge",hotpatch:true,history:[]}]' "$TF/supervisor/autopi/units.json" > "$TF/units.tmp"; mv "$TF/units.tmp" "$TF/supervisor/autopi/units.json"
      command jq '. += [{databaseId:9903,status:"queued",event:"pull_request",headBranch:"fix/priority",headSha:"0000000000000000000000000000000000000001",workflowName:"CI"}]' "$TF/queued-pr-runs.json" > "$TF/runs.tmp"; mv "$TF/runs.tmp" "$TF/queued-pr-runs.json"
      command jq '.auto_merge=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
    fi
    if [[ "$mode" == blocker-hotfix || "$mode" == blocker-unreadable || "$mode" == blocker-partial ]]; then
      printf '%s\n' '{"blockers":[779]}' > "$TF/supervisor/autopi/release-blockers.json"
    fi
    mkdir -p "$TF/repo/engine/night"
    printf '#!/usr/bin/env bash\nprintf "cancel-run %%s\\n" "$2" >> "$TF/actions"\n' > "$TF/repo/engine/night/main-ci-recovery.sh"
    tick
    if [[ "$mode" == unit || "$mode" == review || "$mode" == priority || "$mode" == ready || "$mode" == ready-priority || "$mode" == unreadable ]]; then
      command jq -e --arg mode "$mode" '.units[0].hold_handoff_waiting==true and .units[0].stage==(if $mode=="ready" or $mode=="ready-priority" then "ready-to-merge" elif $mode=="review" then "review" elif $mode=="priority" then "review-pending" else "repair-pending" end) and .units[0].hold_handoff_episode==null' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo "not ok - $mode hotfix handoff was not held" >&2; exit 1; }
    elif [[ "$mode" == *-priority ]]; then
      command jq -e '(.units | length)==1 and .units[0].id=="priority"' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo "not ok - $mode hotfix handoff created a unit" >&2; exit 1; }
    else
      command jq -e '(.units | length)==0' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo "not ok - $mode hotfix handoff created a unit" >&2; exit 1; }
    fi
    ! grep -Eq '^gh pr (ready|edit|merge|close) |^gh run cancel ' "$TF/calls" \
      || { echo "not ok - $mode hotfix PR was modified" >&2; exit 1; }
    grep -q '^gh api --paginate .*actions/runs?status=queued' "$TF/calls" \
      || { echo "not ok - $mode did not inspect the queued hotfix run" >&2; exit 1; }
    ! grep -q '^cancel-run ' "$TF/actions" \
      || { echo "not ok - $mode hotfix run was cancelled" >&2; exit 1; }
    ! grep -q 'dispatch mode=.*unit=.*779' "$TF/supervisor/autopi/scheduler.log" \
      || { echo "not ok - $mode hotfix handoff dispatched a worker" >&2; exit 1; }
    if [[ "$mode" == census || "$mode" == blocker-hotfix || "$mode" == recorded-census-large || "$mode" == recorded-large ]]; then
      local lookup_fixture="$TF/handoff-lookup.json"
      [[ "$mode" != recorded-large ]] || lookup_fixture="$TF/handoff-pr-view.json"
      command jq '.[0].labels=[]' "$lookup_fixture" > "$TF/lookup.tmp"; mv "$TF/lookup.tmp" "$lookup_fixture"
      command jq '.[0].labels=[{name:"agent/ci-gated"}]' "$TF/pr-census.json" > "$TF/census.tmp"; mv "$TF/census.tmp" "$TF/pr-census.json"
      command jq '.implement_cap=0' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
      tick
      command jq -e '.units[0].issue==779 and .units[0].pr==779 and .units[0].stage=="repair-pending" and .units[0].hold_handoff_episode=="hold-779"' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo 'not ok - handoff did not resume after the hotfix label was removed' >&2; exit 1; }
    fi
  done
}
sched_run_case hold_handoff_hotfix_pr

sched_case_hold_handoff_orphan_pr_lookup_failure() {
  new_tick_fixture hold-handoff-orphan-pr-lookup
  mkdir -p "$TF/agent-home/state"
  command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779"}}' > "$TF/agent-home/state/779.json"
  command jq -n '{number:779,title:"handoff",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
  command jq '.max_workers=1 | .implement_cap=0 | .issue_intake.enabled=false | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  command jq -n '{units:[{id:"issue-779",issue:779,lane:"pr",stage:"parked",history:[]}]}' > "$TF/supervisor/autopi/units.json"
  touch "$TF/handoff-lookup-fail"
  tick
  command jq -e '.units[0].stage=="parked" and .units[0].hold_handoff_waiting==true' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - incomplete census dispatched a handoff before discovering an orphan PR' >&2; exit 1; }
  command jq -n '[{number:779,headRefName:"fix/orphan",title:"existing",body:"Fixes #779"}]' > "$TF/handoff-lookup.json"
  rm "$TF/handoff-lookup-fail"
  tick
  command jq -e '.units[0].stage=="repair-pending" and .units[0].pr==779 and .units[0].branch=="fix/orphan"' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - recovered census did not select the orphan PR' >&2; exit 1; }
}
sched_run_case hold_handoff_orphan_pr_lookup_failure

sched_case_hold_handoff_pr_appeared() {
  new_tick_fixture hold-handoff-pr-appeared
  mkdir -p "$TF/agent-home/state"
  command jq -n --arg sha "$(printf '%040x' 779)" '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779",start_ref:"rescued/issue-779-work",start_sha:$sha}}' > "$TF/agent-home/state/779.json"
  command jq -n '{number:779,title:"PR appeared",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
  command jq '.max_workers=2 | .implement_cap=0 | .issue_intake.enabled=true | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  command jq -n '{units:[{id:"issue-779",issue:779,pr:779,branch:"agent/issue-779",lane:"pr",stage:"ready-to-merge",history:[]}]}' > "$TF/supervisor/autopi/units.json"
  tick
  command jq -e '.units[0].stage=="repair-pending" and .units[0].pr==779 and .units[0].handoff_start_ref=="rescued/issue-779-work"' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - PR appearing after the handoff lost the rescued ref' >&2; exit 1; }
}
sched_run_case hold_handoff_pr_appeared

sched_case_hold_handoff_nonstandard_pr() {
  new_tick_fixture hold-handoff-nonstandard-pr
  mkdir -p "$TF/agent-home/state"
  command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779"}}' > "$TF/agent-home/state/779.json"
  command jq -n '{number:779,title:"handoff",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
  command jq -n '[{number:779,headRefName:"fix/existing-work",title:"Existing work",body:"Refs #779"}]' > "$TF/handoff-lookup.json"
  command jq '.max_workers=1 | .implement_cap=0 | .auto_merge=true | .issue_intake.enabled=false | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  command jq -n '{units:[{id:"pr-779",pr:779,branch:"fix/existing-work",lane:"pr",stage:"ready-to-merge",history:[]}]}' > "$TF/supervisor/autopi/units.json"
  tick
  command jq -e '.units[0].issue==779 and .units[0].pr==779 and .units[0].branch=="fix/existing-work" and .units[0].stage=="repair-pending"' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - nonstandard PR was not associated with the handoff' >&2; exit 1; }
  ! grep -q '^merge ' "$TF/actions" || { echo 'not ok - nonstandard PR merged before its handoff' >&2; exit 1; }
}
sched_run_case hold_handoff_nonstandard_pr

sched_case_hold_handoff_after_consumption() {
  new_tick_fixture hold-handoff-after-consumption
  mkdir -p "$TF/agent-home/state"
  command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779"}}' > "$TF/agent-home/state/779.json"
  command jq -n '{number:779,title:"handoff",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
  command jq -n '[{number:779,headRefName:"fix/late-pr",title:"Late PR",body:"Refs #779"}]' > "$TF/handoff-lookup.json"
  command jq -n --arg sha "$(printf '%040x' 779)" '[{number:779,headRefOid:$sha,headRefName:"fix/late-pr",title:"Late PR",isDraft:false,labels:[],statusCheckRollup:[]}]' > "$TF/pr-census.json"
  command jq '.max_workers=2 | .auto_dispatch_new_prs=true | .auto_merge=true | .issue_intake.enabled=true | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  command jq -n '{units:[{id:"issue-779",issue:779,lane:"pr",stage:"implement",hold_handoff_episode:"hold-779",history:[]}]}' > "$TF/supervisor/autopi/units.json"
  command jq -n '{workers:[{pid:99999998,unit:"issue-779",type:"implement",harvested:false}]}' > "$TF/supervisor/autopi/workers.json"
  touch "$TF/worker-alive"
  tick
  command jq -e '(.units|length)==2 and all(.units[]; .hold_handoff_waiting==true) and .units[1].stage=="review-pending"' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - late PR started a second chain after handoff consumption' >&2; exit 1; }
  command jq -e '([.workers[] | select(.harvested!=true)] | length)==1' "$TF/supervisor/autopi/workers.json" >/dev/null \
    || { echo 'not ok - late PR dispatched a second worker' >&2; exit 1; }
}
sched_run_case hold_handoff_after_consumption

sched_case_hold_handoff_pr_ambiguity() {
  local mode
  for mode in unrelated ambiguous explicit multiple-issues; do
    new_tick_fixture "hold-handoff-pr-$mode"
    mkdir -p "$TF/agent-home/state"
    command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779"}}' > "$TF/agent-home/state/779.json"
    if [[ "$mode" == explicit ]]; then
      command jq '.scheduler_handoff += {open_pr:901,open_branch:"agent/issue-779"}' "$TF/agent-home/state/779.json" > "$TF/state.tmp"; mv "$TF/state.tmp" "$TF/agent-home/state/779.json"
    fi
    command jq -n '{number:779,title:"handoff",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
    command jq '.max_workers=2 | .implement_cap=0 | .auto_merge=true | .issue_intake.enabled=false | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
    if [[ "$mode" == unrelated ]]; then
      command jq -n '[{number:901,headRefName:"fix/other",title:"Other issue",body:"Fixes #901\nRefs #779"}]' > "$TF/handoff-lookup.json"
      command jq -n '{units:[{id:"issue-779",issue:779,lane:"pr",stage:"parked",history:[]},{id:"pr-901",pr:901,branch:"fix/other",lane:"pr",stage:"parked",history:[]}]}' > "$TF/supervisor/autopi/units.json"
    elif [[ "$mode" == ambiguous ]]; then
      command jq -n '[{number:901,headRefName:"fix/one",body:"Refs #779"},{number:902,headRefName:"fix/two",body:"Refs #779"}]' > "$TF/handoff-lookup.json"
      command jq -n '{units:[{id:"pr-901",pr:901,branch:"fix/one",lane:"pr",stage:"ready-to-merge",history:[]},{id:"pr-902",pr:902,branch:"fix/two",lane:"pr",stage:"ready-to-merge",history:[]}]}' > "$TF/supervisor/autopi/units.json"
    elif [[ "$mode" == explicit ]]; then
      command jq -n '[{number:901,headRefName:"agent/issue-779",body:"Refs #779"},{number:902,headRefName:"fix/two",body:"This PR fixes #779"}]' > "$TF/handoff-lookup.json"
      command jq -n '{units:[{id:"pr-901",pr:901,branch:"agent/issue-779",lane:"pr",stage:"ready-to-merge",history:[]},{id:"pr-902",pr:902,branch:"fix/two",lane:"pr",stage:"ready-to-merge",history:[]}]}' > "$TF/supervisor/autopi/units.json"
    else
      command jq -n '[{number:901,headRefName:"fix/two-issues",body:"Fixes #779\nFixes #780"}]' > "$TF/handoff-lookup.json"
      command jq -n '{units:[{id:"pr-901",issue:780,pr:901,branch:"fix/two-issues",lane:"pr",stage:"ready-to-merge",history:[]}]}' > "$TF/supervisor/autopi/units.json"
    fi
    tick
    if [[ "$mode" == unrelated ]]; then
      command jq -e '.units[0].issue==779 and .units[0].stage=="implement-pending" and .units[1].issue==null and .units[1].stage=="parked"' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo 'not ok - ordinary issue reference was mistaken for PR ownership' >&2; exit 1; }
    else
      command jq -e 'all(.units[]; .hold_handoff_waiting==true)' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo 'not ok - ambiguous PR handoffs were not frozen' >&2; exit 1; }
      grep -Fq 'handoff-pr-ambiguous issue=#779' "$TF/agent-home/supervisor-inbox" \
        || { echo 'not ok - ambiguous PR handoff did not notify supervisor' >&2; exit 1; }
      ! grep -q '^merge ' "$TF/actions" || { echo 'not ok - ambiguous handoff merged before resolution' >&2; exit 1; }
      if [[ "$mode" == ambiguous ]]; then
        command jq -n '[{number:901,headRefName:"fix/one",body:"Refs #779"},{number:902,headRefName:"fix/two",body:"Fixes #902"}]' > "$TF/handoff-lookup.json"
        command jq '.auto_merge=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
        tick
        command jq -e '.units[0].issue==779 and .units[0].stage=="repair-pending" and (.units[0].hold_handoff_waiting // false)==false and (.units[1].hold_handoff_waiting // false)==false' "$TF/supervisor/autopi/units.json" >/dev/null \
          || { echo 'not ok - resolving PR association left an unrelated unit frozen' >&2; exit 1; }
        command jq -n '[{number:903,headRefName:"fix/three",body:"Refs #779"},{number:904,headRefName:"fix/four",body:"Refs #779"}]' > "$TF/handoff-lookup.json"
        command jq -n '{units:[{id:"pr-903",pr:903,branch:"fix/three",lane:"pr",stage:"ready-to-merge",history:[]},{id:"pr-904",pr:904,branch:"fix/four",lane:"pr",stage:"ready-to-merge",history:[]}]}' > "$TF/supervisor/autopi/units.json"
        tick
        [[ "$(grep -c 'handoff-pr-ambiguous issue=#779' "$TF/agent-home/supervisor-inbox")" == 2 ]] \
          || { echo 'not ok - a later distinct PR ambiguity did not notify supervisor' >&2; exit 1; }
      fi
    fi
  done
}
sched_run_case hold_handoff_pr_ambiguity

sched_case_hold_handoff_orphan_and_aged_pr() {
  local mode sha branch
  for mode in ambiguous incomplete live-owner; do
    new_tick_fixture "hold-handoff-pr-lifecycle-$mode"
    mkdir -p "$TF/agent-home/state"
    command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779"}}' > "$TF/agent-home/state/779.json"
    command jq -n '{number:779,title:"handoff",body:"finish",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
    command jq '.max_workers=1 | .implement_cap=0 | .auto_merge=true | .issue_intake.enabled=false | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
    command jq -n '{units:[{id:"pr-901",issue:779,pr:901,branch:"fix/one",lane:"pr",stage:"ready-to-merge",history:[]}]}' > "$TF/supervisor/autopi/units.json"
    command jq -n '[{number:901,headRefName:"fix/one",body:"Refs #779"},{number:902,headRefName:"agent/issue-779",body:"Fixes #779"}]' > "$TF/handoff-lookup.json"
    branch=agent/issue-779
    if [[ "$mode" == live-owner ]]; then
      branch=agent/legacy-779
      command jq -n '{units:[{id:"issue-779",issue:779,lane:"pr",stage:"implement",history:[]}]}' > "$TF/supervisor/autopi/units.json"
      command jq -n '{workers:[{pid:99999998,unit:"issue-779",type:"implement",harvested:false}]}' > "$TF/supervisor/autopi/workers.json"
      command jq -n '[{number:902,headRefName:"agent/legacy-779",body:"Fixes #779"}]' > "$TF/handoff-lookup.json"
      touch "$TF/worker-alive"
    fi
    sha="$(printf '%040x' 902)"
    command jq -n --arg sha "$sha" --arg branch "$branch" '[{number:902,headRefOid:$sha,headRefName:$branch,title:"orphan",isDraft:false,labels:[],statusCheckRollup:[]}]' > "$TF/pr-census.json"
    command jq -n --arg sha "$sha" --arg branch "$branch" '[{number:902,headRefName:$branch,headRefOid:$sha,createdAt:"2020-01-01T00:00:00Z",baseRefName:"main"}]' > "$TF/aged-prs.json"
    touch "$TF/aged-head-readable"
    [[ "$mode" != incomplete ]] || touch "$TF/handoff-lookup-fail"
    tick
    ! grep -Eq '^(pr close 902|issue close 779)' "$TF/actions" \
      || { echo "not ok - $mode handoff let PR lifecycle close unresolved work" >&2; exit 1; }
    if [[ "$mode" == ambiguous ]]; then
      grep -Fq 'handoff-pr-ambiguous issue=#779' "$TF/agent-home/supervisor-inbox" \
        || { echo 'not ok - orphan ambiguity was not sent to supervisor' >&2; exit 1; }
      grep -Fq 'gh pr list --state open --limit 300 --json number,headRefName,headRefOid,createdAt,baseRefName' "$TF/calls" \
        || { echo 'not ok - aged PR fixture did not run' >&2; exit 1; }
    elif [[ "$mode" == incomplete ]]; then
      grep -Fq 'aged PR lifecycle deferred: handoff PR census unavailable' "$TF/supervisor/autopi/scheduler.log" \
        || { echo 'not ok - incomplete census did not defer aged PR cleanup' >&2; exit 1; }
    else
      command jq -e '.units[0].hold_handoff_waiting==true' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo 'not ok - live owner did not hold the handoff' >&2; exit 1; }
      grep -Fq 'gh pr list --state open --limit 300 --json number,headRefName,headRefOid,createdAt,baseRefName' "$TF/calls" \
        || { echo 'not ok - aged PR fixture did not run while waiting for the live owner' >&2; exit 1; }
    fi
  done
}
sched_run_case hold_handoff_orphan_and_aged_pr

sched_case_hold_handoff_body_dependency() {
  new_tick_fixture hold-handoff-body-dependency
  mkdir -p "$TF/agent-home/state"
  command jq -n '{state:"ready-for-agent",scheduler_handoff:{episode:"hold-779",open_pr:779,open_branch:"agent/issue-779"}}' > "$TF/agent-home/state/779.json"
  command jq -n '{number:779,title:"handoff",body:"## Blocked by\n- #9901",labels:[{name:"ready-for-agent"}]}' > "$TF/intake-issue.json"
  command jq '.max_workers=1 | .implement_cap=0 | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  command jq -n '{units:[{id:"issue-779",issue:779,pr:779,branch:"agent/issue-779",lane:"pr",stage:"parked",history:[]},{id:"issue-9901",issue:9901,stage:"implement",history:[]}]}' > "$TF/supervisor/autopi/units.json"
  tick
  command jq -e '.units[0].stage=="blocked-external" and .units[0].blocked_on==9901 and .units[0].blocked_resume_stage=="repair-pending"' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - PR handoff bypassed an open issue-body prerequisite' >&2; exit 1; }
  command jq '.units[1].stage="landed"' "$TF/supervisor/autopi/units.json" > "$TF/units.tmp"; mv "$TF/units.tmp" "$TF/supervisor/autopi/units.json"
  tick
  command jq -e '.units[0].stage=="repair-pending" and .units[0].blocked_on==null and .units[0].blocked_resume_stage==null' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - completed prerequisite did not resume handoff repair' >&2; exit 1; }
}
sched_run_case hold_handoff_body_dependency

sched_case_hold_handoff_delivery() {
  local mode
  for mode in no-push delivered; do
    new_tick_fixture "hold-handoff-delivery-$mode"
    command jq '.max_workers=2 | .implement_cap=0 | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
    sha="$(printf '%040x' 779)"; original="$sha"
    [[ "$mode" != delivered ]] || original="$(printf '%040x' 778)"
    command jq -n --arg sha "$sha" --arg original "$original" --arg integrated "$(printf '%040x' 100)" '{units:[{
      id:"issue-779",issue:779,pr:779,branch:"agent/issue-779",lane:"pr",stage:"rereview-pending",history:[],
      handoff_worktree_sha:$integrated,handoff_worktree_dirty:true,handoff_worktree_applied:true,
      handoff_integration_sha:$integrated,handoff_original_pr_head:$original,self_check_sha:$sha,self_check_status:"pass",self_check_lane:"pr",self_check_base:"main"}]}' > "$TF/supervisor/autopi/units.json"
    printf '%s\n' "$sha" > "$TF/fetched-head"
    if [[ "$mode" == delivered ]]; then touch "$TF/allow-dispatch" "$TF/worker-alive"; fi
    tick
    if [[ "$mode" == no-push ]]; then
      command jq -e '.units[0].stage=="supervisor-review" and (.units[0].note | contains("did not deliver"))' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo 'not ok - unchanged PR bypassed the preserved dirty work' >&2; exit 1; }
    else
      command jq -e --arg sha "$sha" '.units[0].handoff_delivery_verified_sha==$sha and (.units[0].stage=="review" or .units[0].stage=="rereview")' "$TF/supervisor/autopi/units.json" >/dev/null \
        || { echo 'not ok - delivered handoff did not proceed to review' >&2; command jq -c '.units[0]' "$TF/supervisor/autopi/units.json" >&2; tail -30 "$TF/supervisor/autopi/scheduler.log" >&2; exit 1; }
    fi
  done
}
sched_run_case hold_handoff_delivery

sched_case_hold_handoff_conflict_escalates() {
  new_tick_fixture hold-handoff-conflict
  command jq '.max_workers=2 | .implement_cap=1 | .supervisor_arbiter.enabled=false' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  command jq -n --arg sha "$(printf '%040x' 779)" '{units:[{
    id:"issue-779",issue:779,pr:779,branch:"agent/issue-779",lane:"pr",stage:"repair-pending",history:[],
    repair_hint:"read issue comments",handoff_worktree:"/preserved/owner",handoff_worktree_sha:$sha,handoff_worktree_dirty:false}]}' > "$TF/supervisor/autopi/units.json"
  : > "$TF/ancestry.tsv"
  touch "$TF/handoff-conflict"
  tick
  command jq -e '.units[0].stage=="supervisor-review" and (.units[0].note | contains("conflicts")) and .units[0].handoff_worktree=="/preserved/owner"' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - conflicting handoff did not reach supervisor with the owner worktree preserved' >&2; exit 1; }
  command jq '.supervisor_arbiter.enabled=true' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"; mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  mkdir -p "$TF/repo/engine/prompts"
  cp "$repo_root/engine/prompts/supervisor-arbiter.md" "$TF/repo/engine/prompts/supervisor-arbiter.md"
  echo approve > "$TF/supervise-action"
  touch "$TF/allow-dispatch"
  for attempt in $(seq 1 8); do
    tick
    [[ "$(command jq -r '.units[0].stage' "$TF/supervisor/autopi/units.json")" == parked ]] && break
  done
  command jq -e '.units[0].stage=="parked" and (.units[0].note | contains("approve refused"))' "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - supervisor approved before the preserved handoff was transferred' >&2; exit 1; }
}
sched_run_case hold_handoff_conflict_escalates

sched_case_supervisor_arbiter() {
# #4369：supervisor-review 的整拍链路。拍 1 派 terra 裁决 worker；拍 2 按报告动作迁移（requeue 带 GUIDANCE）；
# 拍 3 的 needs-info 给 issue 发澄清问题并打 needs-info 标签。断言对外动作，不断言内部实现。
new_tick_fixture supervisor-arbiter
command jq '.max_workers=2 | .supervisor_arbiter.enabled=true | .supervisor_arbiter.max_in_flight=1' "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
# This tick exercises supervisor label transitions; its issue is already a roadmap leaf.
export ZF_ROADMAP_TREE_CACHE_FILE="$TF/roadmap-tree.json"
command jq -cn '{roots:[502] | map({number:.,title:("fixture issue " + tostring),state:"open",labels:[],children:[]})}' \
  > "$ZF_ROADMAP_TREE_CACHE_FILE"
mkdir -p "$TF/repo/engine/prompts"
cp "$repo_root/engine/prompts/supervisor-arbiter.md" "$TF/repo/engine/prompts/supervisor-arbiter.md"
export ZF_EXECUTION_MODULE_DIR="$TF/repo/engine"
printf 'VERDICT: REQUEST-CHANGES\nF1 缺回归测试\n' > "$TF/supervisor/review-501.md"
command jq -n '{units:[
  {id:"pr-501",issue:501,pr:501,lane:"pr",branch:"agent/issue-501",stage:"supervisor-review",
   review_report:"review-501.md",
   history:[{stage:"review-request-changes",result:"F1",at:"2026-10-27T00:00:00Z"},
            {stage:"supervisor-escalated",result:"review report has no single VERDICT line",at:"2026-10-27T00:01:00Z"}]}]}' \
  > "$TF/supervisor/autopi/units.json"
touch "$TF/allow-dispatch"
echo requeue > "$TF/supervise-action"
: > "$TF/codex.calls"
tick
command jq -e --arg unit pr-501 'any(.workers[]; .unit == $unit and .type == "supervise" and .model == "profile:terra")' \
  "$TF/supervisor/autopi/workers.json" >/dev/null || { echo 'not ok - scheduler.test.sh: tick 1 did not dispatch the arbitration worker' >&2; exit 1; }
command jq -e --arg unit pr-501 'any(.units[] | select(.id==$unit) | .history[]; .stage == "supervisor-arbiter")' \
  "$TF/supervisor/autopi/units.json" >/dev/null || { echo 'not ok - scheduler.test.sh: arbitration dispatch not recorded in history' >&2; exit 1; }
grep -q -- '-p terra' "$TF/codex.calls" || { echo 'not ok - scheduler.test.sh: arbitration worker did not use the terra profile' >&2; exit 1; }
# 桩 worker 秒回：同拍 refill 就可能回收落地。跨拍轮询到 requeue 的对外结果为止。
stage_of() { command jq -r '.units[] | select(.id=="'"$1"'") | .stage' "$TF/supervisor/autopi/units.json"; }
for attempt in $(seq 1 20); do
  [[ "$(stage_of pr-501)" == repair-pending || "$(stage_of pr-501)" == repair ]] && break
  tick
done
[[ "$(stage_of pr-501)" == repair-pending || "$(stage_of pr-501)" == repair ]] \
  || { echo "not ok - scheduler.test.sh: requeue did not return the unit to repair-pending ($(command jq -c '.units[] | select(.id=="pr-501")' "$TF/supervisor/autopi/units.json"))" >&2; exit 1; }
command jq -e --arg unit pr-501 'any(.units[] | select(.id==$unit) | .history[]; .stage == "supervisor-requeue")' \
  "$TF/supervisor/autopi/units.json" >/dev/null || { echo 'not ok - scheduler.test.sh: requeue not recorded in history' >&2; exit 1; }
command jq -e --arg unit pr-501 '([.units[] | select(.id==$unit) | (.repair_hint // "")] | join("") | test("git merge origin/main"))' \
  "$TF/supervisor/autopi/units.json" >/dev/null || { echo 'not ok - scheduler.test.sh: requeue guidance missing from the unit' >&2; exit 1; }
command jq -e --arg unit pr-501 'any(.units[] | select(.id==$unit) | .history[]; .decision.decision == "Supervisor arbitration: requeue")' \
  "$TF/supervisor/autopi/units.json" >/dev/null || { echo 'not ok - scheduler.test.sh: arbitration decision not recorded in the unit' >&2; exit 1; }

# The scheduler arbitrates one unit per tick, so pr-502 joins only after pr-501's requeue round: otherwise its
# worker starts during that round and reads the requeue action instead of needs-info.
command jq '.units += [{id:"pr-502",issue:502,pr:502,lane:"pr",branch:"agent/issue-502",stage:"supervisor-review",
   history:[{stage:"supervisor-escalated",result:"needs a maintainer business fact",at:"2026-10-27T00:00:00Z"}]}]' \
  "$TF/supervisor/autopi/units.json" > "$TF/units.with-502" && mv "$TF/units.with-502" "$TF/supervisor/autopi/units.json"
echo needs-info > "$TF/supervise-action"
tick
for attempt in $(seq 1 20); do
  [[ "$(stage_of pr-502)" != supervisor-review ]] && break
  tick
done
[[ "$(stage_of pr-502)" == needs-human ]] \
  || { echo "not ok - scheduler.test.sh: needs-info did not move the unit to needs-human ($(stage_of pr-502))" >&2; exit 1; }
grep -Fq 'issue comment 502 --body 工厂 supervisor 需要澄清：这批单据要对接哪个外部系统？' "$TF/actions" \
  || { echo "not ok - scheduler.test.sh: needs-info question not posted to the issue: $(cat "$TF/actions")" >&2; exit 1; }
grep -Eq '^issue edit 502 .*--add-label needs-info$' "$TF/actions" \
  || {
    echo "not ok - scheduler.test.sh: needs-info label not applied; actions: $(grep ' 502 ' "$TF/actions" || true); gh calls: $(grep -E 'issue edit 502|label list' "$TF/calls" || true)" >&2
    tail -c 2000 "$TF/tick.out" >&2
    exit 1
  }
}
sched_run_case supervisor_arbiter

prepare_jev_f12_fixture() {
  command jq '.max_workers=2 | .supervisor_arbiter.enabled=true | .supervisor_arbiter.max_in_flight=1' \
    "$TF/supervisor/autopi/config.json" > "$TF/config.tmp"
  mv "$TF/config.tmp" "$TF/supervisor/autopi/config.json"
  export ZF_ROADMAP_TREE_CACHE_FILE="$TF/roadmap-tree.json"
  command jq -cn '{roots:[4630] | map({number:.,title:"fixture issue 4630",state:"open",labels:[],children:[]})}' \
    > "$ZF_ROADMAP_TREE_CACHE_FILE"
  mkdir -p "$TF/repo/engine/prompts" "$TF/agent-home/logs"
  cp "$repo_root/engine/prompts/supervisor-arbiter.md" "$TF/repo/engine/prompts/supervisor-arbiter.md"
  export ZF_EXECUTION_MODULE_DIR="$TF/repo/engine"
  # The scheduler reaches the judge through ts-judge.sh (548de8056), which execs the real node, so the node() wrapper below never
  # sees it; the fixture copy of the wrapper runs the mock driver instead.
  printf '%s\n' '#!/usr/bin/env bash' 'exec node "$TYPESAFE_TEST_DRIVER" "$@"' > "$TF/repo/engine/ts-judge.sh"
  printf 'VERDICT: REQUEST-CHANGES\nF1 needs a bounded follow-up\n' > "$TF/supervisor/review-4630.md"
  command jq -n '{units:[{id:"pr-4630",issue:4630,pr:4630,lane:"pr",branch:"agent/issue-4630",stage:"supervisor-review",
    review_report:"review-4630.md",history:[{stage:"supervisor-escalated",result:"two review attempts did not converge",at:"2026-10-27T00:00:00Z"}]}]}' \
    > "$TF/supervisor/autopi/units.json"
  cat > "$TF/jev-driver.mjs" <<'JS'
const { judge } = await import(process.env.TYPESAFE_JUDGE_SCRIPT);
let raw = "";
for await (const chunk of process.stdin) raw += chunk;
const state = JSON.parse(raw);
const response = await judge({
  questionSet: "f12",
  state,
  apiKey: process.env.TYPESAFE_API_KEY,
  file: process.env.TYPESAFE_JUDGE_LOG,
  client: {
    async systemOne() {
        return { answers: { action: { choice: process.env.TYPESAFE_TEST_CANDIDATE, confidence: Number(process.env.TYPESAFE_TEST_CONFIDENCE || 0.95) } } };
    },
  },
});
process.stdout.write(`${JSON.stringify(response)}\n`);
JS
  export TYPESAFE_TEST_MOCK=1
  export TYPESAFE_TEST_DRIVER="$TF/jev-driver.mjs"
  export TYPESAFE_JUDGE_SCRIPT="$repo_root/engine/ts-judge.mjs"
  export TYPESAFE_JUDGE_LOG="$TF/agent-home/logs/ts-judge.jsonl"
  export TYPESAFE_API_KEY=mock-only-key
  touch "$TF/allow-dispatch"
  : > "$TF/codex.calls"
}

sched_case_jev_f12_rollout() {
  # While the shadow sample is immature, the existing Terra action still owns the unit;
  # its result is recorded next to the mocked Jev candidate for this real scheduler tick.
  new_tick_fixture jev-f12-shadow
  prepare_jev_f12_fixture
  export TYPESAFE_TEST_CANDIDATE=requeue
  echo park > "$TF/supervise-action"
  tick
  for attempt in $(seq 1 10); do
    [[ -s "$TYPESAFE_JUDGE_LOG" ]] && break
    tick
  done
  command jq -e '.units[0].stage=="parked" and any(.units[0].history[]; .stage=="supervisor-park")' \
    "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: shadow collection replaced the Terra park action' >&2; exit 1; }
  grep -q -- '-p terra' "$TF/codex.calls" \
    || { echo 'not ok - scheduler.test.sh: immature Jev sample skipped the Terra arbiter' >&2; exit 1; }
  command jq -e 'any(.workers[]; .unit=="pr-4630" and .jev.candidate=="requeue" and .jev.confidence==0.95)' \
    "$TF/supervisor/autopi/workers.json" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: Jev candidate was not retained with the Terra worker record' >&2; exit 1; }
  command jq -e 'select(.question_set=="f12" and .mode=="shadow" and .baseline=="park" and .candidate=="requeue" and .agreement==false)' \
    "$TYPESAFE_JUDGE_LOG" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: the completed Terra decision was not recorded beside the Jev candidate' >&2; exit 1; }
  # After 20 matching shadow records, a confident bounded action can be applied without dispatching Terra.
  new_tick_fixture jev-f12-adoption
  prepare_jev_f12_fixture
  export TYPESAFE_TEST_CANDIDATE=park
  for index in $(seq 1 20); do
    printf '{"mode":"shadow","question_set":"f12","event_id":"fixture-%s","agreement":true}\n' "$index" >> "$TYPESAFE_JUDGE_LOG"
  done
  tick
  command jq -e '.units[0].stage=="parked" and any(.units[0].history[]; .decision.decision=="TypeSafe Jev: park")' \
    "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: mature Jev park decision was not applied to the unit' >&2; exit 1; }
  [[ ! -s "$TF/codex.calls" ]] \
    || { echo 'not ok - scheduler.test.sh: mature confident Jev action still dispatched a Terra worker' >&2; exit 1; }
  command jq -e 'select(.question_set=="f12" and .mode=="active" and .candidate=="park" and .decision=="park")' \
    "$TYPESAFE_JUDGE_LOG" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: adopted Jev action was not recorded in the decision journal' >&2; exit 1; }
  if grep -Fq 'mock-only-key' "$TYPESAFE_JUDGE_LOG"; then
    echo 'not ok - scheduler.test.sh: API key leaked into the decision journal' >&2
    exit 1
  fi

  # Mature history alone is insufficient: low confidence must still dispatch Terra.
  new_tick_fixture jev-f12-low-confidence
  prepare_jev_f12_fixture
  export TYPESAFE_TEST_CANDIDATE=park TYPESAFE_TEST_CONFIDENCE=0.79
  echo park > "$TF/supervise-action"
  for index in $(seq 1 20); do
    printf '{"mode":"shadow","question_set":"f12","event_id":"fixture-%s","agreement":true}\n' "$index" >> "$TYPESAFE_JUDGE_LOG"
  done
  tick
  grep -q -- '-p terra' "$TF/codex.calls" \
    || { echo 'not ok - scheduler.test.sh: low confidence Jev action bypassed the Terra arbiter' >&2; exit 1; }
  command jq -e 'any(.workers[]; .unit=="pr-4630" and .jev.candidate=="park" and .jev.confidence==0.79 and .jev.rollout_ready==true)' \
    "$TF/supervisor/autopi/workers.json" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: low-confidence Jev answer was not retained for its Terra comparison' >&2; exit 1; }

  # A mature recut recommendation respects the existing no-PR recut guard for this PR-backed unit.
  new_tick_fixture jev-f12-recut-pr
  prepare_jev_f12_fixture
  export TYPESAFE_TEST_CANDIDATE=recut TYPESAFE_TEST_CONFIDENCE=0.95
  for index in $(seq 1 20); do
    printf '{"mode":"shadow","question_set":"f12","event_id":"fixture-%s","agreement":true}\n' "$index" >> "$TYPESAFE_JUDGE_LOG"
  done
  tick
  command jq -e '.units[0].stage=="parked" and (.units[0].note | contains("already has PR #4630"))
    and any(.units[0].history[]; .decision.decision=="TypeSafe Jev: recut")' \
    "$TF/supervisor/autopi/units.json" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: Jev recut bypassed the existing PR guard or lost its decision record' >&2; exit 1; }
  command jq -e 'select(.question_set=="f12" and .mode=="active" and .candidate=="recut")' \
    "$TYPESAFE_JUDGE_LOG" >/dev/null \
    || { echo 'not ok - scheduler.test.sh: Jev recut adoption was not journaled' >&2; exit 1; }
  [[ ! -s "$TF/codex.calls" ]] \
    || { echo 'not ok - scheduler.test.sh: mature Jev recut dispatched a Terra worker despite the PR guard' >&2; exit 1; }
  unset TYPESAFE_TEST_MOCK TYPESAFE_TEST_DRIVER TYPESAFE_JUDGE_SCRIPT TYPESAFE_JUDGE_LOG TYPESAFE_API_KEY TYPESAFE_TEST_CANDIDATE TYPESAFE_TEST_CONFIDENCE
}
sched_run_case jev_f12_rollout

# #4279 regression: a no-label predecessor with an open native child is sent
# to triage during a real tick and never becomes an implement unit.
new_tick_fixture tracker-parent-intake
mkdir -p "$TF/issues"
command jq '.max_workers=1 | .release_train.enabled=false | .issue_intake={enabled:true,max_upstream:2,max_ready:30,labels:["pipeline-system"],product_labels:["ready-for-agent"]}' \
  "$template" > "$TF/supervisor/autopi/config.json"
command jq -n '{units:[{id:"issue-4278",issue:4278,lane:"pr",stage:"blocked-external",blocked_on:4279,history:[]}]}' \
  > "$TF/supervisor/autopi/units.json"
command jq -n '{number:4279,title:"Runtime scheduler migration",body:"Migrate the background runtime from polling to Runtime.",state:"OPEN",labels:[{name:"ready-for-agent"}]}' \
  > "$TF/issues/4279.json"
printf '%s\n' '[{"number":4280,"title":"Runtime migration child","state":"open"}]' > "$TF/sub-issues-4279.json"
seed_roadmap_tree 4279
tick
command jq -e 'all(.units[]; .issue != 4279)' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'scheduler.test.sh: #4279 was registered as an implement unit' >&2; exit 1; }
grep -Fq 'gh api repos/example-maintainer/example-repo/issues/4279/sub_issues?per_page=100' "$TF/calls" \
  || { echo 'scheduler.test.sh: #4279 native sub-issues were not checked' >&2; exit 1; }
grep -Eq '^issue edit 4279 --repo [^ ]+ .*--remove-label ready-for-agent .*--add-label needs-triage$' "$TF/actions" \
  || { echo "scheduler.test.sh: #4279 stage transition did not remove ready-for-agent and apply needs-triage: $(cat "$TF/actions")" >&2; exit 1; }
grep -Fq 'intake issue #4279 -> needs-triage (parent: has GitHub sub-issues)' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: parent disposition was not recorded in the tick log' >&2; exit 1; }

# A roadmap container cannot take an active stage; intake records it as a tracker.
new_tick_fixture roadmap-container-parent-intake
mkdir -p "$TF/issues" "$TF/repo/engine"
command jq '.max_workers=1 | .release_train.enabled=false | .issue_intake={enabled:true,max_upstream:2,max_ready:30,labels:["pipeline-system"],product_labels:["ready-for-agent"]}' \
  "$template" > "$TF/supervisor/autopi/config.json"
command jq -n '{units:[{id:"issue-4278",issue:4278,lane:"pr",stage:"blocked-external",blocked_on:4279,history:[]}]}' \
  > "$TF/supervisor/autopi/units.json"
command jq -n '{number:4279,title:"Runtime pilot spec, ADR-1",body:"Prepare the pilot",state:"OPEN",labels:[{name:"ready-for-agent"}]}' \
  > "$TF/issues/4279.json"
command jq '.switches["roadmap-order"]=true | .roles.advisor.disabled = false' "$repo_root/engine/model-policy.default.json" > "$TF/model-policy.json"
mkdir -p "$TF/agent-home"
export AGENT_HOME="$TF/agent-home" MODEL_POLICY_FILE="$TF/model-policy.json" \
  ZF_EXECUTION_MODULE_DIR="$TF/repo/engine" \
  ZF_ROADMAP_TREE_CACHE_FILE="$TF/roadmap-tree.json"
command jq -cn '{roots:[{number:4279,title:"Runtime parent",state:"open",labels:[],children:[{number:4280,title:"Open child",state:"open",labels:[],children:[]}]}]}' \
  > "$ZF_ROADMAP_TREE_CACHE_FILE"
tick
command jq -e 'all(.units[]; .issue != 4279)' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'scheduler.test.sh: roadmap container was registered as an implement unit' >&2; exit 1; }
command jq -e '.state == "tracker" and .tracker_parent == true' "$TF/agent-home/state/4279.json" >/dev/null \
  || { echo 'scheduler.test.sh: roadmap container did not enter tracker state' >&2; exit 1; }
tracker_edit="$(grep -E '^issue edit 4279 --repo ' "$TF/actions" || true)"
[[ "$(grep -Ec '^issue edit 4279 --repo ' "$TF/actions")" == 1 ]] \
  || { echo "scheduler.test.sh: tracker transition did not make exactly one issue edit: $(cat "$TF/actions")" >&2; exit 1; }
[[ "$tracker_edit" == *'--remove-label ready-for-agent'* && "$tracker_edit" != *'--add-label'* ]] \
  || { echo "scheduler.test.sh: tracker transition did not clear ready-for-agent without adding a stage label: $tracker_edit" >&2; exit 1; }
grep -Fq 'intake issue #4279 -> tracker (roadmap container parent: spec/ADR pilot)' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'scheduler.test.sh: roadmap container tracker disposition was not logged' >&2; exit 1; }

sched_case_m5_intake() {
# M5 生效即验收（#4501）：验收块没有 live-event 项的 pipeline-system 票在收单时退回补写
# （needs-info + 补写说明，不派单元）；验收块合法的票派发时把块存进 unit 记录。
new_tick_fixture m5-intake
mkdir -p "$TF/issues" "$TF/repo/engine/state" "$TF/agent-home"
command jq '.max_workers=1 | .release_train.enabled=false | .supervisor_arbiter.enabled=false | .issue_intake={enabled:true,max_upstream:2,max_ready:30,labels:["pipeline-system"],product_labels:["ready-for-agent"]}' \
  "$template" > "$TF/supervisor/autopi/config.json"
cp "$repo_root/engine/state/mechanism-registry.json" "$TF/repo/engine/state/mechanism-registry.json"
missing_body="$(printf '描述正文。\n\n```json\n%s\n```\n' '{"acceptance":[{"id":"tick","desc":"no live event here"}]}')"
command jq -n --arg body "$missing_body" '{number:4281,title:"pipeline ticket without live-event",body:$body,state:"OPEN",labels:[{name:"pipeline-system"},{name:"ready-for-agent"}]}' \
  > "$TF/issues/4281.json"
cp "$TF/issues/4281.json" "$TF/intake-issue.json"
printf '%s\n' '[]' > "$TF/sub-issues-4281.json"
seed_roadmap_tree 4281
tick
command jq -e 'all(.units[]; .issue != 4281)' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'not ok - scheduler.test.sh: M5 intake dispatched a unit for a ticket without live-event' >&2; exit 1; }
grep -Eq '^issue edit 4281 --repo [^ ]+ .*--remove-label ready-for-agent .*--add-label needs-info$' "$TF/actions" \
  || { echo "not ok - scheduler.test.sh: M5 return did not relabel needs-info: $(grep ' 4281 ' "$TF/actions" || true)" >&2
       echo "actions: $(cat "$TF/actions" || true)" >&2
       echo "scheduler.log: $(grep -E 'intake|m5|live-event' "$TF/supervisor/autopi/scheduler.log" || true)" >&2
       tail -c 1500 "$TF/tick.out" >&2
       exit 1; }
grep -Fq 'issue comment 4281 --body M5 生效即验收' "$TF/actions" \
  || { echo 'not ok - scheduler.test.sh: M5 return did not explain the missing live-event item' >&2; exit 1; }
grep -Fq 'intake issue #4281 -> needs-info (M5 live-event missing)' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'not ok - scheduler.test.sh: M5 return was not logged' >&2; exit 1; }

new_tick_fixture m5-intake-valid
mkdir -p "$TF/issues" "$TF/repo/engine/state" "$TF/agent-home"
command jq '.max_workers=1 | .release_train.enabled=false | .supervisor_arbiter.enabled=false | .issue_intake={enabled:true,max_upstream:2,max_ready:30,labels:["pipeline-system"],product_labels:["ready-for-agent"]}' \
  "$template" > "$TF/supervisor/autopi/config.json"
cp "$repo_root/engine/state/mechanism-registry.json" "$TF/repo/engine/state/mechanism-registry.json"
valid_acc="$(command jq -cn '{acceptance:[
  {id:"tick-close",desc:"tick 测试：落地后，事件没出现时不关票；事件出现后关票，并附上证据",passes:false},
  {id:"tamper",desc:"tick 测试：worker 改了验收块，拒绝关票并转交 supervisor",passes:false},
  {id:"timeout",desc:"tick 测试：超过沉默上限仍未出现事件，转交 supervisor",passes:false},
  {id:"live-event",desc:"生产事件：本 spec 下的其他票，按这个流程由调度器根据生产事件关闭",passes:false}
]}')"
valid_body="$(printf '正文。\n\n```json\n%s\n```\n' "$valid_acc")"
command jq -n --arg body "$valid_body" '{number:4282,title:"pipeline ticket with live-event",body:$body,state:"OPEN",labels:[{name:"pipeline-system"},{name:"ready-for-agent"}]}' \
  > "$TF/issues/4282.json"
cp "$TF/issues/4282.json" "$TF/intake-issue.json"
printf '%s\n' '[]' > "$TF/sub-issues-4282.json"
seed_roadmap_tree 4282
touch "$TF/allow-dispatch" "$TF/worker-alive"
tick
command jq -e --argjson acc "$valid_acc" 'any(.units[]; .issue == 4282 and .acceptance == $acc)' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo "not ok - scheduler.test.sh: acceptance block was not stored on the dispatched unit: $(command jq -c '.units[] | select(.issue==4282)' "$TF/supervisor/autopi/units.json")" >&2; exit 1; }

new_tick_fixture m5-intake-unbound
mkdir -p "$TF/issues" "$TF/repo/engine/state" "$TF/agent-home"
command jq '.max_workers=1 | .release_train.enabled=false | .supervisor_arbiter.enabled=false | .issue_intake={enabled:true,max_upstream:2,max_ready:30,labels:["pipeline-system"],product_labels:["ready-for-agent"]}' \
  "$template" > "$TF/supervisor/autopi/config.json"
cp "$repo_root/engine/state/mechanism-registry.json" "$TF/repo/engine/state/mechanism-registry.json"
unbound_acc="$(command jq -cn '{acceptance:[{id:"live-event",desc:"生产事件",event:"missing-mechanism"}]}')"
unbound_body="$(printf '正文。\n\n```json\n%s\n```\n' "$unbound_acc")"
command jq -n --arg body "$unbound_body" '{number:4283,title:"pipeline ticket with unregistered event",body:$body,state:"OPEN",labels:[{name:"pipeline-system"},{name:"ready-for-agent"}]}' \
  > "$TF/issues/4283.json"
cp "$TF/issues/4283.json" "$TF/intake-issue.json"
printf '%s\n' '[]' > "$TF/sub-issues-4283.json"
seed_roadmap_tree 4283
tick
command jq -e 'all(.units[]; .issue != 4283)' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'not ok - scheduler.test.sh: M5 intake dispatched a ticket with an unregistered event' >&2; exit 1; }
grep -Eq '^issue edit 4283 --repo [^ ]+ .*--add-label needs-info$' "$TF/actions" \
  || { echo 'not ok - scheduler.test.sh: unregistered M5 event was not returned to needs-info' >&2; exit 1; }
grep -Fq 'acceptance_item_ids' "$TF/actions" \
  || { echo 'not ok - scheduler.test.sh: unregistered M5 event return omitted repair guidance' >&2; exit 1; }
}
sched_run_case m5_intake

sched_case_m5_live_event_close() {
# M5 生效即验收（#4501）：验收块带 live-event 项的直落单落地后不关票（等待生产事件，
# inbox 显示已落地、待生效）；没有 live-event 项的单保持落地即关；登记事件出现后
# 关票并附证据行。
new_tick_fixture m5-live-event-close
mkdir -p "$TF/issues" "$TF/repo/engine/state" "$TF/agent-home"
command jq '.release_train.enabled=false | .supervisor_arbiter.enabled=false' "$template" > "$TF/supervisor/autopi/config.json"
cp "$repo_root/engine/state/mechanism-registry.json" "$TF/repo/engine/state/mechanism-registry.json"
acc="$(command jq -cn '{acceptance:[
  {id:"tick-close",desc:"tick 测试：落地后，事件没出现时不关票；事件出现后关票，并附上证据",passes:false},
  {id:"tamper",desc:"tick 测试：worker 改了验收块，拒绝关票并转交 supervisor",passes:false},
  {id:"timeout",desc:"tick 测试：超过沉默上限仍未出现事件，转交 supervisor",passes:false},
  {id:"live-event",desc:"生产事件：本 spec 下的其他票，按这个流程由调度器根据生产事件关闭",passes:false}
]}')"
issue_body="$(printf '正文。\n\n```json\n%s\n```\n' "$acc")"
git -C "$TF/repo" init -q
git -C "$TF/repo" config user.name "scheduler test"
git -C "$TF/repo" config user.email "scheduler-test@example.invalid"
git -C "$TF/repo" add .
git -C "$TF/repo" commit -q -m '[skip ci] feat: M5 close evidence #4501 #4505 #4506'
m5_land_sha="$(git -C "$TF/repo" rev-parse HEAD)"
git -C "$TF/repo" update-ref refs/remotes/origin/main "$m5_land_sha"
printf '%s\n' "$m5_land_sha" > "$TF/main-sha"
touch "$TF/real-rule-git" "$TF/aged-head-readable"
MAIN_HEAD="$m5_land_sha"
old_landed_at="$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
unlinked_land_sha="$m5_land_sha"
plain_land_sha="$(printf '%040x' 778)"
command jq -n --arg acc "$acc" --arg sha "$m5_land_sha" --arg at "$old_landed_at" --arg unlinked "$unlinked_land_sha" '{units:[
  {id:"issue-4501",issue:4501,lane:"direct-main",branch:"agent/auto-issue-4501",stage:"landing",acceptance:($acc|fromjson),history:[]},
  {id:"issue-4496",issue:4496,lane:"direct-main",branch:"agent/auto-issue-4496",stage:"landing",history:[]},
  {id:"issue-4505",issue:4505,lane:"direct-main",branch:"agent/auto-issue-4505",stage:"awaiting-live-event",landed_at:$at,land_sha:$sha,acceptance:($acc|fromjson),history:[]},
  {id:"issue-4504",issue:4504,lane:"direct-main",branch:"agent/auto-issue-4504",stage:"awaiting-live-event",landed_at:$at,land_sha:$unlinked,acceptance:($acc|fromjson),history:[]},
  {id:"issue-4506",issue:4506,lane:"direct-main",branch:"agent/auto-issue-4506",stage:"awaiting-live-event",landed_at:$at,land_sha:$sha,acceptance:($acc|fromjson),history:[]}]}' \
  > "$TF/supervisor/autopi/units.json"
command jq -n --arg body "$issue_body" '{number:4501,title:"M5 ticket",body:$body,state:"OPEN",labels:[]}' > "$TF/issues/4501.json"
command jq -n '{number:4496,title:"plain ticket",body:"no acceptance block",state:"OPEN",labels:[]}' > "$TF/issues/4496.json"
command jq -n --arg body "$issue_body" '{number:4505,title:"M5 already-closed ticket",body:$body,state:"CLOSED",labels:[]}' > "$TF/issues/4505.json"
command jq -n --arg body "$issue_body" '{number:4504,title:"M5 invalid-close-evidence ticket",body:$body,state:"OPEN",labels:[]}' > "$TF/issues/4504.json"
printf 'LANDED %s\n' "$m5_land_sha" > "$TF/supervisor/land-4501.md"
printf 'LANDED %s\n' "$plain_land_sha" > "$TF/supervisor/land-4496.md"
command jq -n '{workers:[
  {pid:999999901,unit:"issue-4501",type:"land",log:"land-4501.worker.log",report:"land-4501.md",started:"2026-10-29T00:00:00Z",harvested:false},
  {pid:999999902,unit:"issue-4496",type:"land",log:"land-4496.worker.log",report:"land-4496.md",started:"2026-10-29T00:00:00Z",harvested:false}]}' \
  > "$TF/supervisor/autopi/workers.json"
tick
command jq -e --arg sha "$m5_land_sha" '.units[] | select(.id=="issue-4501") | .stage=="awaiting-live-event" and (.landed_at|type=="string") and .land_sha==$sha' \
  "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo "not ok - scheduler.test.sh: landed live-event unit did not enter the wait stage: $(command jq -c '.units[] | select(.id=="issue-4501")' "$TF/supervisor/autopi/units.json")" >&2; exit 1; }
grep -Fq "live-event wait unit=issue-4501 issue=4501 sha=$m5_land_sha 已落地、待生效" "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'not ok - scheduler.test.sh: wait transition was not logged' >&2; exit 1; }
grep -Fq 'live-event-wait issue=#4501 status=已落地、待生效' "$TF/agent-home/supervisor-inbox" \
  || { echo 'not ok - scheduler.test.sh: supervisor inbox missing the landed-awaiting-event note' >&2; exit 1; }
if grep -Eq '^issue close 4501 ' "$TF/actions"; then
  echo 'not ok - scheduler.test.sh: ticket closed before the registered event appeared' >&2; exit 1
fi
command jq -e '.units[] | select(.id=="issue-4496") | .stage=="landed"' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'not ok - scheduler.test.sh: unit without live-event item did not keep the landed stage' >&2; exit 1; }
grep -Eq '^issue close 4496 ' "$TF/actions" \
  || { echo 'not ok - scheduler.test.sh: unit without live-event item was not closed immediately' >&2; exit 1; }
landed_at="$(command jq -r '.units[] | select(.id=="issue-4501") | .landed_at' "$TF/supervisor/autopi/units.json")"
event_epoch=$(( $(date -u -d "$landed_at" +%s) + 1 ))
event_line="[$(date -u -d "@$event_epoch" +%Y-%m-%dT%H:%M:%SZ)] live-event close issue=99 unit=issue-99 event=factory-m5-live-event-close evidence=fixture-firing"
printf '%s\n' "$event_line" >> "$TF/supervisor/autopi/scheduler.log"
existing_comment="结案：已落地 ${m5_land_sha}（direct-main 车道）并观测到登记的生产事件 factory-m5-live-event-close。证据：$event_line"
command jq -n --arg body "$issue_body" --arg comment "$existing_comment" '{number:4506,title:"M5 evidence comment already attached",body:$body,state:"CLOSED",labels:[],comments:[{body:$comment}]}' \
  > "$TF/issues/4506.json"
tick
command jq -e '.units[] | select(.id=="issue-4501") | .stage=="closed" and .acceptance!=null' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo "not ok - scheduler.test.sh: observed event did not close the ticket: $(command jq -c '.units[] | select(.id=="issue-4501")' "$TF/supervisor/autopi/units.json")" >&2; exit 1; }
command jq -e --argjson acc "$acc" '.units[] | select(.id=="issue-4501") | .acceptance==$acc' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'not ok - scheduler.test.sh: unit changed the immutable issue acceptance block' >&2; exit 1; }
grep -Fq 'live-event close issue=4501 unit=issue-4501 event=factory-m5-live-event-close' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'not ok - scheduler.test.sh: the M5 close event line was not logged' >&2; exit 1; }
m5_close_line="$(grep -E '^issue close 4501 ' "$TF/actions" | head -1)"
[[ "$m5_close_line" == *"结案：已落地 ${m5_land_sha}（direct-main 车道）并观测到登记的生产事件 factory-m5-live-event-close"* ]] \
  || { echo "not ok - scheduler.test.sh: close comment lacks the event evidence: $m5_close_line" >&2; exit 1; }
[[ "$m5_close_line" == *'evidence=fixture-firing'* ]] \
  || { echo "not ok - scheduler.test.sh: close comment lacks the observed evidence line: $m5_close_line" >&2; exit 1; }
command jq -e '.units[] | select(.id=="issue-4505") | .stage=="closed"' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'not ok - scheduler.test.sh: already-closed issue did not receive event closure evidence' >&2; exit 1; }
grep -Fq 'issue comment 4505 --repo example-maintainer/example-repo --body 结案：已落地' "$TF/actions" \
  || { echo 'not ok - scheduler.test.sh: already-closed issue is missing its evidence comment' >&2; exit 1; }
command jq -e '.units[] | select(.id=="issue-4504") | .stage=="supervisor-review"' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'not ok - scheduler.test.sh: invalid issue-linked SHA did not go to supervisor' >&2; exit 1; }
if grep -Eq '^issue close 4504 ' "$TF/actions"; then
  echo 'not ok - scheduler.test.sh: ticket without issue-linked main SHA was closed' >&2; exit 1
fi
command jq -e '.units[] | select(.id=="issue-4506") | .stage=="closed"' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'not ok - scheduler.test.sh: existing event evidence did not make closure retry idempotent' >&2; exit 1; }
if grep -Eq '^issue comment 4506 ' "$TF/actions"; then
  echo 'not ok - scheduler.test.sh: retry duplicated an existing event evidence comment' >&2; exit 1
fi
}
sched_run_case m5_live_event_close

sched_case_m5_live_event_tamper() {
# M5（#4501）：关票前对比当前验收块与存档；worker 改过验收项就拒绝关票并转 supervisor。
new_tick_fixture m5-live-event-tamper
mkdir -p "$TF/issues" "$TF/repo/engine/state" "$TF/agent-home"
command jq '.release_train.enabled=false | .supervisor_arbiter.enabled=false' "$template" > "$TF/supervisor/autopi/config.json"
cp "$repo_root/engine/state/mechanism-registry.json" "$TF/repo/engine/state/mechanism-registry.json"
acc="$(command jq -cn '{acceptance:[{id:"live-event",desc:"生产事件",event:"factory-m5-live-event-close"}]}')"
# 单元存档的是原始验收块；worker 落地后把 issue 正文里的块改宽了（passes 也翻成 true）
tampered_body="$(printf 'worker 改宽验收。\n\n```json\n%s\n```\n' '{"acceptance":[{"id":"live-event","desc":"放宽了的验收","event":"factory-m5-live-event-close","passes":true}]}')"
m5_tamper_sha="$(printf '%040x' 779)"
command jq -n --arg acc "$acc" '{units:[
  {id:"issue-4502",issue:4502,lane:"direct-main",branch:"agent/auto-issue-4502",stage:"awaiting-live-event",landed_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",land_sha:"'"$m5_tamper_sha"'",acceptance:($acc|fromjson),history:[]}]}' \
  > "$TF/supervisor/autopi/units.json"
command jq -n --arg body "$tampered_body" '{number:4502,title:"M5 tamper target",body:$body,state:"OPEN",labels:[]}' > "$TF/issues/4502.json"
printf '[%s] live-event close issue=98 unit=issue-98 event=factory-m5-live-event-close evidence=fixture-firing\n' \
  "$(date -u -d '+1 second' +%Y-%m-%dT%H:%M:%SZ)" > "$TF/supervisor/autopi/scheduler.log"
tick
command jq -e 'any(.units[] | select(.id=="issue-4502") | .history[]?; .stage=="supervisor-escalated" and ((.result // "") | contains("验收块")))' \
  "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo "not ok - scheduler.test.sh: tampered acceptance block did not escalate to the supervisor: $(command jq -c '.units[] | select(.id=="issue-4502")' "$TF/supervisor/autopi/units.json")" >&2; exit 1; }
command jq -e '.units[] | select(.id=="issue-4502") | .stage=="supervisor-review"' "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo 'not ok - scheduler.test.sh: tampered unit is not in supervisor-review' >&2; exit 1; }
if grep -Eq '^issue close 4502 ' "$TF/actions"; then
  echo 'not ok - scheduler.test.sh: ticket with a tampered acceptance block was closed' >&2; exit 1
fi
}
sched_run_case m5_live_event_tamper

sched_case_m5_live_event_timeout() {
# M5（#4501）：超过登记机制的沉默上限仍未出现事件，已落地、待生效的单转 supervisor。
new_tick_fixture m5-live-event-timeout
mkdir -p "$TF/issues" "$TF/repo/engine/state" "$TF/agent-home"
command jq '.release_train.enabled=false | .supervisor_arbiter.enabled=false' "$template" > "$TF/supervisor/autopi/config.json"
cp "$repo_root/engine/state/mechanism-registry.json" "$TF/repo/engine/state/mechanism-registry.json"
acc="$(command jq -cn '{acceptance:[{id:"live-event",desc:"生产事件",event:"factory-m5-live-event-close"}]}')"
stale_landed_at="$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
command jq -n --arg acc "$acc" --arg at "$stale_landed_at" '{units:[
  {id:"issue-4503",issue:4503,lane:"direct-main",branch:"agent/auto-issue-4503",stage:"awaiting-live-event",landed_at:$at,land_sha:"'"$(printf '%040x' 780)"'",acceptance:($acc|fromjson),history:[]}]}' \
  > "$TF/supervisor/autopi/units.json"
command jq -n --arg body "$(printf '正文。\n\n```json\n%s\n```\n' "$acc")" '{number:4503,title:"M5 timeout target",body:$body,state:"OPEN",labels:[]}' > "$TF/issues/4503.json"
# 只有早于落地时间的事件行：不算出现
printf '[%s] live-event close issue=97 unit=issue-97 event=factory-m5-live-event-close evidence=too-old\n' \
  "$(date -u -d '26 hours ago' +%Y-%m-%dT%H:%M:%SZ)" > "$TF/supervisor/autopi/scheduler.log"
tick
command jq -e 'any(.units[] | select(.id=="issue-4503") | .history[]?; .stage=="supervisor-escalated" and ((.result // "") | contains("沉默上限")))' \
  "$TF/supervisor/autopi/units.json" >/dev/null \
  || { echo "not ok - scheduler.test.sh: a silent landed unit was not escalated after the silence bound: $(command jq -c '.units[] | select(.id=="issue-4503")' "$TF/supervisor/autopi/units.json")" >&2; exit 1; }
if grep -Eq '^issue close 4503 ' "$TF/actions"; then
  echo 'not ok - scheduler.test.sh: a ticket past its silence bound was closed without the event' >&2; exit 1
fi
grep -Fq 'live-event close issue=97' "$TF/supervisor/autopi/scheduler.log" \
  || { echo 'not ok - scheduler.test.sh: the pre-landing fixture event line was consumed as new evidence' >&2; exit 1; }
}
sched_run_case m5_live_event_timeout

if [ -n "${SCHED_TEST_CASE:-}" ]; then
  echo "not ok - scheduler.test.sh: no case matches SCHED_TEST_CASE='$SCHED_TEST_CASE'; known:$sched_case_names" >&2
  exit 2
fi
echo 'scheduler.test.sh: PASS'
