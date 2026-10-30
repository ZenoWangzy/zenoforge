#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
# The expected dates in this suite are Los Angeles wall-clock dates; the shipped comms profile defaults to UTC, so the suite pins its own zone.
ZF_COMMS_PROFILE="$TMPDIR/comms-profile-la.json"
printf '%s\n' '{"maintainer":{"language":"zh-CN","timezone":"America/Los_Angeles","timezone_label":"洛杉矶时间"}}' > "$ZF_COMMS_PROFILE"
export ZF_COMMS_PROFILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPORT_SCRIPT="$SCRIPT_DIR/daily-perf-report.sh"
TMP_DIR="$TMPDIR/daily-report"
AGENT_HOME="$TMP_DIR/agent"
MOCK_BIN="$TMP_DIR/bin"
REPO_DIR="$TMP_DIR/repo"
REPORT_DAY=2026-09-26
mkdir -p "$AGENT_HOME/night/logs" "$AGENT_HOME/logs" "$AGENT_HOME/state" \
  "$MOCK_BIN" "$REPO_DIR/engine/state"
printf '{"incidents":[]}\n' > "$REPO_DIR/engine/state/incident-guards.json"

cat > "$TMP_DIR/activity.json" <<'JSON'
{"created_complete":true,"closed_complete":true,"issues":[
  {"number":3001,"title":"订单搜索 #3001 4b7c032e0","state":"CLOSED","createdAt":"2026-09-26T08:00:00Z","closedAt":"2026-09-26T12:00:00Z","labels":[]},
  {"number":3002,"title":"库存数量查看","state":"OPEN","createdAt":"2026-09-26T09:00:00Z","closedAt":null,"labels":[]},
  {"number":3003,"title":"销售日报筛选","state":"CLOSED","createdAt":"2026-09-25T09:00:00Z","closedAt":"2026-09-25T15:00:00Z","labels":[]},
  {"number":3004,"title":"订单导出明细","state":"CLOSED","createdAt":"2026-09-25T10:00:00Z","closedAt":"2026-09-25T15:30:00Z","labels":[]},
  {"number":3005,"title":"客户资料维护","state":"CLOSED","createdAt":"2026-09-19T08:00:00Z","closedAt":"2026-09-19T10:00:00Z","labels":[]},
  {"number":3006,"title":"商品信息展示","state":"OPEN","createdAt":"2026-09-19T09:00:00Z","closedAt":null,"labels":[]}
]}
JSON
printf '%s\n' '{"issue":3001,"deployed_sha":"4b7c032e0","outcome":"现在可以搜索订单","sent_at":"2026-09-26T11:45:00Z"}' \
  '{"issue":3003,"deployed_sha":"123456789abcdef","outcome":"现在可以筛选日报","sent_at":"2026-09-25T16:00:00Z"}' \
  '{"issue":3005,"deployed_sha":"abcdef0123456789","outcome":"现在可以维护客户资料","sent_at":"2026-09-19T11:30:00Z"}' \
  > "$AGENT_HOME/night/founder-health-outcomes.jsonl"
cat > "$AGENT_HOME/state/3001.json" <<'JSON'
{"deploy_state":"deployed","deployed_sha":"4b7c032e0","deployed_at":"2026-09-26T11:30:00Z"}
JSON
cat > "$AGENT_HOME/state/3003.json" <<'JSON'
{"deploy_state":"deployed","deployed_sha":"123456789abcdef","deployed_at":"2026-09-25T16:00:00Z"}
JSON
cat > "$AGENT_HOME/state/3005.json" <<'JSON'
{"deploy_state":"deployed","deployed_sha":"abcdef0123456789","deployed_at":"2026-09-19T11:30:00Z"}
JSON
mkdir -p "$AGENT_HOME/metrics"
cat > "$AGENT_HOME/metrics/efficiency-2026-09.jsonl" <<'METRICS'
{"record_type":"event","event_type":"ticket-created","issue":3001,"ts":"2026-09-26T08:00:00Z"}
{"record_type":"event","event_type":"ticket-released","issue":3001,"ts":"2026-09-26T11:30:00Z"}
{"record_type":"event","event_type":"github-closed","issue":3001,"ts":"2026-09-26T12:00:00Z"}
{"record_type":"event","event_type":"ticket-created","issue":3002,"ts":"2026-09-26T09:00:00Z"}
{"record_type":"event","event_type":"ticket-created","issue":3003,"ts":"2026-09-25T09:00:00Z"}
{"record_type":"event","event_type":"ticket-released","issue":3003,"ts":"2026-09-25T15:00:00Z"}
{"record_type":"event","event_type":"github-closed","issue":3003,"ts":"2026-09-25T15:30:00Z"}
{"record_type":"event","event_type":"ticket-created","issue":3004,"ts":"2026-09-25T10:00:00Z"}
{"record_type":"event","event_type":"github-closed","issue":3004,"ts":"2026-09-25T15:30:00Z"}
{"record_type":"event","event_type":"ticket-created","issue":3005,"ts":"2026-09-19T08:00:00Z"}
{"record_type":"event","event_type":"ticket-released","issue":3005,"ts":"2026-09-19T11:30:00Z"}
{"record_type":"event","event_type":"github-closed","issue":3005,"ts":"2026-09-19T12:00:00Z"}
METRICS
cat > "$TMP_DIR/issues.json" <<'JSON'
[{"number":3001,"title":"订单搜索 #3001 4b7c032e0","labels":[]},{"number":3003,"title":"销售日报筛选","labels":[]},{"number":3005,"title":"客户资料维护","labels":[]}]
JSON
cat > "$MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-} ${2:-}" == 'issue list' ]]; then cat "$DAILY_PERF_ISSUES_FILE"; exit 0; fi
if [[ "${1:-} ${2:-}" == 'api graphql' ]]; then
  mapfile -t issue_numbers < <(grep -oE 'issue_[0-9]+' <<< "$*" | sed 's/^issue_//')
  issue_ids="$(printf '%s\n' "${issue_numbers[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  jq -cn --slurpfile issues "$DAILY_PERF_ISSUES_FILE" --argjson ids "$issue_ids" '
    {data:{repository:(reduce $ids[] as $id ({};
      .["issue_" + $id] = (
        [$issues[0][] | select((.number|tostring) == $id)][0] as $issue
        | {number:$issue.number,title:$issue.title,state:"CLOSED",createdAt:null,closedAt:null,
           labels:{nodes:[$issue.labels[]? | {name:.}]}}
      )
    ))}}
  '
  exit 0
fi
printf 'unexpected gh call\n' >&2
exit 2
MOCK
chmod +x "$MOCK_BIN/gh"

NOW="$(date +%s)"
SAMPLED="$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$TMP_DIR/autopi"
jq -n --arg generated "$SAMPLED" \
  '{generated:$generated,metrics:[{node:"ci",desc:"队列延迟偏高",status:"UNHEALTHY"},{node:"merge",desc:"检查等待",status:"OK"}]}' \
  > "$TMP_DIR/autopi/node-health.json"
export PATH="$MOCK_BIN:$PATH" MAINTAINER_HEALTH_MAIL_ACTIVITY_FILE="$TMP_DIR/activity.json" \
  MAC_AUTOPILOT_RUNTIME_DIR="$TMP_DIR/autopi"
export DAILY_PERF_ISSUES_FILE="$TMP_DIR/issues.json" REPO='example-maintainer/example-repo'
cat > "$AGENT_HOME/recipients.json" <<'JSON'
{"founder_login":"maintainer","recipients":{"maintainer":"maintainer@example.test"}}
JSON
printf '2026-09-26T00:00:00Z\trecipients=maintainer@example.test\tsubject=一\tissue=none\tresult=sent\n2026-09-26T23:59:59Z\trecipients=maintainer@example.test\tsubject=二\tissue=none\tresult=sent\n2026-09-26T10:00:00Z\trecipients=maintainer@example.test\tsubject=三\tissue=none\tresult=failed\n' \
  > "$AGENT_HOME/logs/notify.log"
source "$REPORT_SCRIPT"
# Keep display assertions independent of live systemd units and GitHub queue state.
maintainer_health_mail_work_counts() { printf '{"active":2,"queued":7}\n'; }
REPORT="$(daily_perf_report_build "$AGENT_HOME" "$REPO_DIR" "$REPORT_DAY" '{}')"

run_mail_audit() {
  local gmail_count="$1" gmail_status="${2:-ok}"
  AGENT_HOME="$AGENT_HOME" FAKE_GMAIL_COUNT="$gmail_count" FAKE_GMAIL_STATUS="$gmail_status" \
    bash -c '
      set -euo pipefail
      source "$1"
      gmail_sent_message_count() {
        [ "$FAKE_GMAIL_STATUS" = ok ] || return 1
        printf "%s\\n" "$FAKE_GMAIL_COUNT"
      }
      daily_perf_report_reconcile_mail "$AGENT_HOME" 2026-09-26
    ' _ "$REPORT_SCRIPT"
}

run_mail_audit 2
if [ -e "$AGENT_HOME/supervisor-inbox" ]; then
  echo 'not ok - matching SENT and notify counts do not wake supervisor' >&2
  exit 1
fi
echo 'ok - matching SENT and notify counts do not wake supervisor'
run_mail_audit 3
grep -Fq 'mail-mismatch 日期=2026-09-26 Gmail=3 notify=2' "$AGENT_HOME/supervisor-inbox" \
  && echo 'ok - mail mismatch records both counts' \
  || { echo 'not ok - mail mismatch records both counts' >&2; exit 1; }
: > "$AGENT_HOME/supervisor-inbox"
run_mail_audit 0 unavailable
grep -Fq 'mail-count-check-failed 日期=2026-09-26' "$AGENT_HOME/supervisor-inbox" \
  && echo 'ok - unavailable SENT count wakes supervisor' \
  || { echo 'not ok - unavailable SENT count wakes supervisor' >&2; exit 1; }

assert_contains() {
  local label="$1" content="$2" expected="$3"
  if [[ "$content" == *"$expected"* ]]; then printf 'ok - %s\n' "$label"
  else printf 'not ok - %s (missing [%s])\n%s\n' "$label" "$expected" "$content" >&2; exit 1; fi
}
assert_contains 'daily summary names reporting day in Chinese' "$REPORT" '今日汇总（9月25日）'
assert_contains 'daily summary includes node and check timing section' "$REPORT" '流程环节与检查耗时'
assert_contains 'daily summary includes pipeline efficiency comparison' "$REPORT" '流水线效率'
assert_contains 'daily summary describes user-visible release' "$REPORT" '现在可以使用「订单搜索」'
assert_contains 'production version uses date and time, without hash' "$REPORT" '9月26日 04:30 上线的版本'
assert_contains 'average lead time uses production evidence time, not outcome-mail time' "$REPORT" '3.5小时'
if [[ "$REPORT" == *'04:45 上线的版本'* ]]; then
  echo 'not ok - daily launch line used later outcome-mail time'
  exit 1
fi
assert_contains 'daily comparison has closed-item decrease percentage' "$REPORT" '↓50%（上期2项）'
assert_contains 'daily comparison uses same weekday last week' "$REPORT" '同比：上周同日'
assert_contains 'daily table fills comparison values from event fixtures' "$REPORT" '| 新增事项 | 2项 | →0%（上期2项） | ↑100%（上期1项） |'
assert_contains 'daily summary reads current anomaly from scheduler scorecard' "$REPORT" '超出健康线的调度指标：队列延迟偏高'
assert_contains 'daily summary includes active and queued counts' "$REPORT" '2/7项'
if grep -Eq '#[0-9]+|[[:xdigit:]]{7,}|implement|canary|quarantine|rulings|owner|队列年龄|令牌消耗' <<< "$REPORT"; then
  echo 'not ok - daily summary exposes issue IDs, hashes, or internal metrics' >&2
  exit 1
fi
echo 'ok - daily summary hides IDs, hashes, and internal metrics'

cat > "$AGENT_HOME/state/3007.json" <<'JSON'
{"deploy_state":"deployed","deployed_sha":"fedcba9876543210"}
JSON
INCOMPLETE_EFFICIENCY="$(maintainer_health_mail_efficiency_block "$AGENT_HOME" daily "$REPORT_DAY" "$NOW")"
assert_contains 'release event still counts when another production timestamp is missing' \
  "$INCOMPLETE_EFFICIENCY" '| 上线的改进项数 | 1项 |'
INCOMPLETE_RELEASES="$(maintainer_health_mail_release_lines "$AGENT_HOME" \
  "$(date -u -d "$REPORT_DAY 00:00:00" +%s)" "$(date -u -d "$REPORT_DAY +1 day 00:00:00" +%s)")"
assert_contains 'missing production timestamp is explicit in launch summary' \
  "$INCOMPLETE_RELEASES" '上线时间待核实，无法确认本期上线内容'

DRY_RUN_DAY=2026-09-27
DRY_RUN_REPORT="$(AGENT_HOME="$AGENT_HOME" ZF_REPO_DIR="$REPO_DIR" \
  PATH="$MOCK_BIN:$PATH" bash "$REPORT_SCRIPT" --dry-run "$DRY_RUN_DAY")"
assert_contains 'daily dry-run renders timing section without persisted data' "$DRY_RUN_REPORT" '今日汇总（9月26日）'
if [ -e "$AGENT_HOME/logs/daily-perf-$DRY_RUN_DAY.md" ] \
  || [ -e "$AGENT_HOME/night/incident-guard-audit-$DRY_RUN_DAY.json" ] \
  || [ -e "$AGENT_HOME/night/efficiency/daily-$DRY_RUN_DAY.json" ]; then
  echo 'not ok - dry-run persists report or audit output' >&2
  exit 1
fi
echo 'ok - daily dry-run persists no report or audit output'

grep -Fq 'OnCalendar=*-*-* 01:00:00 UTC' "$SCRIPT_DIR/../systemd/zenoforge-daily-perf-report.timer" \
  && echo 'ok - daily summary timer runs at 01:00 UTC' \
  || { echo 'not ok - daily summary timer runs at 01:00 UTC' >&2; exit 1; }
grep -Eq '^ExecStart=:/bin/bash -c .*checkout/engine}/night/daily-perf-report\.sh"' \
  "$SCRIPT_DIR/../systemd/zenoforge-daily-perf-report.service" \
  && echo 'ok - daily summary service uses shared checkout script' \
  || { echo 'not ok - daily summary service uses shared checkout script' >&2; exit 1; }
echo 'ALL PASS'
