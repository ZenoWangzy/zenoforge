#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
# The expected dates in this suite are Los Angeles wall-clock dates; the shipped comms profile defaults to UTC, so the suite pins its own zone.
ZF_COMMS_PROFILE="$TMPDIR/comms-profile-la.json"
printf '%s\n' '{"maintainer":{"language":"zh-CN","timezone":"America/Los_Angeles","timezone_label":"洛杉矶时间"}}' > "$ZF_COMMS_PROFILE"
export ZF_COMMS_PROFILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/maintainer-health-mail.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/logs" "$tmp/state"
test_bin="$tmp/bin"
mkdir -p "$test_bin"
cat > "$test_bin/systemctl" <<'EOF2'
#!/usr/bin/env bash
[ -z "${MAINTAINER_TEST_SYSTEMCTL_FILE:-}" ] || cat -- "$MAINTAINER_TEST_SYSTEMCTL_FILE"
EOF2
cat > "$test_bin/gh" <<'EOF2'
#!/usr/bin/env bash
if [[ " $* " == *" --label ready-for-agent "* ]] && [ -n "${MAINTAINER_TEST_READY_QUEUE_FILE:-}" ]; then
  cat -- "$MAINTAINER_TEST_READY_QUEUE_FILE"
else
  printf '[]\n'
fi
EOF2
chmod +x "$test_bin/systemctl" "$test_bin/gh"
PATH="$test_bin:$PATH"
export PATH
# The owner report does not read git history in this suite's tick fixtures.
post_land_mttr_summary() { jq -cn '{summary:{count:0},bounds:{meaning:""}}'; }
notify_maintainer_incident() { :; }
notify_maintainer_resolution() { :; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (expected [%s], got [%s])\n' "$label" "$expected" "$actual"
    exit 1
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (missing [%s])\n' "$label" "$needle"
    exit 1
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (found [%s])\n' "$label" "$needle"
    exit 1
  fi
}

mail_status_ledger="$tmp/mail-status-ledger.json"
mail_status_interval="$(maintainer_health_mail_digest_interval_seconds)"
maintainer_health_mail_ensure_ledger "$mail_status_ledger" 1000
assert_eq 'mail remains healthy through the daily cadence' 'OK' \
  "$(maintainer_health_mail_node_status "$mail_status_ledger" "$((1000 + mail_status_interval + 299))")"
assert_eq 'missed daily mail becomes slow after five-minute grace' 'SLOW' \
  "$(maintainer_health_mail_node_status "$mail_status_ledger" "$((1000 + mail_status_interval + 300))")"
assert_eq 'missed daily mail becomes stuck after one further hour' 'STUCK' \
  "$(maintainer_health_mail_node_status "$mail_status_ledger" "$((1000 + mail_status_interval + 3600))")"

assert_eq 'daily slot key stays fixed across one UTC day' '20260928' \
  "$(maintainer_health_mail_slot_key "$(date -u -d '2026-09-28T10:59:59Z' +%s)")"
assert_eq 'daily slot key stays fixed late in the day' '20260928' \
  "$(maintainer_health_mail_slot_key "$(date -u -d '2026-09-28T23:59:59Z' +%s)")"
assert_eq 'daily slot key advances at the next UTC midnight' '20260929' \
  "$(maintainer_health_mail_slot_key "$(date -u -d '2026-09-29T00:00:00Z' +%s)")"

live_counts_home="$tmp/live-counts"
mkdir -p "$live_counts_home/night"
printf '%s\n' \
  'zf-implement-1.service loaded active running worker' \
  'zf-implement-2.service loaded active running worker' \
  'zf-implement-3.service loaded active running worker' \
  'zf-implement-4.service loaded active running worker' \
  'zf-implement-5.service loaded active running worker' \
  > "$tmp/live-units.txt"
printf '%s\n' '[{"number":1,"labels":[{"name":"ready-for-agent"}]},{"number":2,"labels":[{"name":"ready-for-agent"}]},{"number":3,"labels":[{"name":"ready-for-agent"},{"name":"on-hold"}]},{"number":4,"labels":[{"name":"ready-for-agent"},{"name":"pipeline-system"}]},{"number":5,"labels":[{"name":"ready-for-agent"},{"name":"needs-owner"}]}]' \
  > "$tmp/live-ready.json"
MAINTAINER_TEST_SYSTEMCTL_FILE="$tmp/live-units.txt"
MAINTAINER_TEST_READY_QUEUE_FILE="$tmp/live-ready.json"
export MAINTAINER_TEST_SYSTEMCTL_FILE MAINTAINER_TEST_READY_QUEUE_FILE
live_work_counts="$(maintainer_health_mail_work_counts "$live_counts_home" 1791730000)"
assert_eq 'work counts use live units and current ready tickets' '{"active":5,"queued":2}' "$live_work_counts"

unset MAINTAINER_TEST_SYSTEMCTL_FILE MAINTAINER_TEST_READY_QUEUE_FILE

# --- Owner report facts ----------------------------------------------------------

# A fixture home with one deployed requirement in the window, one outcome row,
# a pending awaiting-release census, metric events, and spend records.
facts_home="$tmp/facts"
facts_now="$(date -u -d '2026-11-07T16:00:00Z' +%s)"
mkdir -p "$facts_home/night" "$facts_home/state" "$facts_home/metrics" "$facts_home/spend" \
  "$facts_home/.scratch-supervisor/autopi"
maintainer_health_mail_ensure_ledger "$facts_home/night/founder-health-mail.json" "$facts_now"
jq -n --arg generated '2026-11-07T16:00:00Z' \
  '{generated:$generated,metrics:[{status:"OK"},{status:"NO-DATA"}]}' \
  > "$facts_home/.scratch-supervisor/autopi/node-health.json"
fixture_issue_seed="$(printf '%s' "$facts_home" | cksum | awk '{print 100000 + ($1 % 800000)}')"
fixture_issue_live="$fixture_issue_seed"
fixture_issue_waiting=$((fixture_issue_seed + 1))
fixture_issue_second_release=$((fixture_issue_seed + 2))
fixture_issue_declined=$((fixture_issue_seed + 3))
fixture_issue_factory=$((fixture_issue_seed + 4))
cat > "$facts_home/state/${fixture_issue_live}.json" <<EOF
{"state":"awaiting-release","run":{"outcome":"merged","merged_at":"2026-11-07T02:00:00Z"},"deploy_state":"deployed","deployed_sha":"123456789abcdef","deployed_at":"2026-11-07T06:30:00Z"}
EOF
cat > "$facts_home/state/${fixture_issue_waiting}.json" <<EOF
{"state":"awaiting-release","run":{"outcome":"merged","merged_at":"2026-11-07T05:00:00Z"}}
EOF
cat > "$facts_home/state/${fixture_issue_second_release}.json" <<EOF
{"state":"concluded","deploy_state":"deployed","deployed_sha":"abcdef123456789","deployed_at":"2026-11-07T05:00:00Z"}
EOF
cat > "$facts_home/state/${fixture_issue_declined}.json" <<'EOF'
{"state":"concluded","run":{"outcome":"wontfix"}}
EOF
cat > "$facts_home/state/${fixture_issue_factory}.json" <<'EOF'
{"state":"concluded","closed_by_pipeline":true,"pipeline_system":{"enabled":true},"run":{"outcome":"pipeline-system","concluded_at":"2026-10-01T00:00:00Z"}}
EOF
cat > "$facts_home/metrics/efficiency-2026-11.jsonl" <<EOF
{"record_type":"event","event_type":"ticket-created","stage":"needs-triage","issue":${fixture_issue_live},"ts":"2026-11-02T06:00:00Z"}
{"record_type":"event","event_type":"stage-entered","stage":"awaiting-release","issue":${fixture_issue_live},"ts":"2026-11-07T02:30:00Z"}
{"record_type":"event","event_type":"ticket-released","stage":"released","issue":${fixture_issue_live},"ts":"2026-11-07T06:30:00Z"}
{"record_type":"event","event_type":"ticket-created","stage":"needs-triage","issue":${fixture_issue_waiting},"ts":"2026-11-07T09:00:00Z"}
{"record_type":"event","event_type":"ticket-released","stage":"released","issue":${fixture_issue_second_release},"ts":"2026-11-07T05:00:00Z"}
{"record_type":"event","event_type":"ticket-created","stage":"needs-triage","issue":${fixture_issue_second_release},"ts":"2026-11-07T09:00:00Z"}
{"record_type":"event","event_type":"ticket-created","stage":"needs-triage","issue":${fixture_issue_declined},"ts":"2026-11-01T00:00:00Z"}
{"record_type":"hourly","sampled_at":"2026-11-07T15:00:00Z","metrics":{"tokens":9}}
EOF
printf '%s\n' "$(jq -cn --argjson issue "$fixture_issue_live" --arg sent_at '2026-11-07T06:31:00Z' \
  --arg outcome '用户可以把订单导出成表格。' --arg sha '123456789abcdef' \
  '{sent_at:$sent_at,issue:$issue,outcome:$outcome,deployed_sha:$sha}')" \
  > "$facts_home/night/founder-health-outcomes.jsonl"
printf '%s\timplement\t模型\t%s\t\t1500\n' \
  "$(date -u -d '2026-11-07T13:50:00Z' +%s)" "$fixture_issue_live" \
  > "$facts_home/spend/2026-11-07.log"
printf '%s\n' "2026-11-07T06:30:00Z founder-req #${fixture_issue_live} 提出 → 上线：订单导出（请 PushNotification 通知创始人）" \
  > "$facts_home/supervisor-inbox"
jq -cn --argjson live "$fixture_issue_live" --argjson waiting "$fixture_issue_waiting" \
  '{($live|tostring):3,($waiting|tostring):2}' > "$facts_home/founder-req-stage.json"
cat > "$facts_home/metrics/units-2026-11.jsonl" <<EOF
{"record_type":"event","event_type":"unit-end","event_id":"unit-req","ts":"2026-11-07T14:00:00Z","wall_s":3600,"tickets":[${fixture_issue_live}]}
{"record_type":"event","event_type":"unit-end","event_id":"unit-self","ts":"2026-11-07T14:05:00Z","wall_s":600,"tickets":[${fixture_issue_factory}]}
{"record_type":"event","event_type":"unit-end","event_id":"unit-unclassified","ts":"2026-11-07T14:10:00Z","wall_s":300,"tickets":[]}
EOF
facts="$(maintainer_health_mail_daily_facts "$facts_home" "$facts_home/night/founder-health-mail.json" "$facts_now" "$SCRIPT_DIR/../..")"
assert_eq 'one requirement reached production in the window' '1' "$(jq -r '.releases.period_count' <<< "$facts")"
assert_contains 'release line states the user-visible outcome' \
  "$(jq -r '.releases.items[0].text' <<< "$facts")" '用户可以把订单导出成表格'
assert_eq 'current founder requirements count as open' '1' "$(jq -r '.progress.open_total' <<< "$facts")"
assert_eq 'awaiting-release total comes from the state census' '1' "$(jq -r '.progress.awaiting_total' <<< "$facts")"
assert_eq 'new proposals in the window are counted' '1' "$(jq -r '.progress.created_period' <<< "$facts")"
assert_eq 'new proposals total uses the requirement ladder' '2' "$(jq -r '.progress.created_total' <<< "$facts")"
assert_eq 'released-all-time comes from the deployment catalog' '1' "$(jq -r '.progress.released_total' <<< "$facts")"
expected_lead_days="$(jq -nr '(("2026-11-07T06:30:00Z" | fromdateiso8601) - ("2026-11-02T06:00:00Z" | fromdateiso8601)) / 86400')"
assert_eq 'median lead time is measured in days' "$expected_lead_days" "$(jq -r '.efficiency.lead_days_week' <<< "$facts")"
assert_eq 'week and previous week per-day counts stay separate' '1' "$(jq -r '.efficiency.per_day_week * 7 | round' <<< "$facts")"
assert_eq 'unit ledger splits product work from factory maintenance' '85.7' "$(jq -r '.efficiency.split.requirement_pct' <<< "$facts")"
assert_eq 'unclassified time stays outside the work-share calculation' '300.0' "$(jq -r '.efficiency.split.unclassified_seconds' <<< "$facts")"
assert_eq 'spend tokens come from the window day log' '1500' "$(jq -r '.spend.tokens' <<< "$facts")"
assert_eq 'spend per requirement divides by releases in window' '1500' "$(jq -r '.spend.per_requirement' <<< "$facts")"
assert_eq 'report day is the Beijing date' '11-08' "$(jq -r '.report_day' <<< "$facts")"
assert_eq 'a calm factory concludes normally' '正常' "$(jq -r '.conclusion.level' <<< "$facts")"

facts_body="$(maintainer_health_mail_build_body "$facts")"
maintainer_health_mail_output_contract "$facts_body" "$facts_now"
assert_contains 'body names the released requirement' "$facts_body" '「订单导出」：用户可以把订单导出成表格'
assert_contains 'body states the in-flight requirement counts' "$facts_body" '目前在办共 1 个'
assert_contains 'body states the awaiting-release backlog' "$facts_body" '已做完等上线：过去一天 1 个；当前共 1 个'
assert_contains 'body states spend per delivered requirement' "$facts_body" '每个上线需求平均 1500 令牌'
assert_contains 'a measured week with no prior releases says 无样本' "$facts_body" '上一个 7 天 无样本'
assert_contains 'body states money is not measured' "$facts_body" '金额没有完整记录，无法算出总花费'
assert_contains 'body states no decisions wait' "$facts_body" '- 没有'
assert_contains 'subject counts released requirements' "$(maintainer_health_mail_subject "$facts")" '工厂日报 11-08：上线 1 个需求'
assert_contains 'subject states the decision count' "$(maintainer_health_mail_subject "$facts")" '有 0 件事等你'

many_release_facts="$(jq -c '.releases.items += [{text:"「第二项」：用户可以查看更多信息"},{text:"「第三项」：用户可以完成另一件事"},{text:"「第四项」：用户可以完成更多操作"}]' <<< "$facts")"
many_release_body="$(maintainer_health_mail_build_body "$many_release_facts")"
maintainer_health_mail_output_contract "$many_release_body" "$facts_now"
assert_contains 'one-screen report counts extra releases without listing every one' "$many_release_body" '另有 2 个需求上线，邮件未逐项列出'
assert_eq 'one-screen report stays at or below twenty-five lines' 'true' \
  "$([[ "$(wc -l <<< "$many_release_body" | tr -d '[:space:]')" -le 25 ]] && printf true || printf false)"

# A window with no releases names zero and the reason.
quiet_releases="$(maintainer_health_mail_release_facts "$facts_home" "$((facts_now - 7200))" "$((facts_now - 3600))")"
assert_eq 'empty window counts zero releases' '0' "$(jq -r '.period_count' <<< "$quiet_releases")"
assert_contains 'zero-release reason names the awaiting-release backlog' \
  "$(jq -r '.zero_reason' <<< "$quiet_releases")" '还有 1 项已做完，正在等待上线'

# An empty home leaves every number unmeasured instead of inventing one.
empty_home="$tmp/empty"
mkdir -p "$empty_home/night" "$empty_home/state"
printf '%s\n' 'not a ledger yet' > "$empty_home/night/founder-health-mail.json"
assert_eq 'an empty state directory leaves the production census unmeasured' 'null' \
  "$(maintainer_health_mail_state_census "$empty_home")"
empty_facts="$(maintainer_health_mail_daily_facts "$empty_home" "$empty_home/night/founder-health-mail.json" "$facts_now" "$SCRIPT_DIR/../..")"
empty_body="$(maintainer_health_mail_build_body "$empty_facts")"
maintainer_health_mail_output_contract "$empty_body" "$facts_now"
assert_contains 'empty home says releases are unverified' "$empty_body" '上线记录未能完整核对'
assert_contains 'empty home leaves the subject decision count unmeasured' \
  "$(maintainer_health_mail_subject "$empty_facts")" '待决定事项未测量'
assert_contains 'empty home leaves lead time unmeasured' "$empty_body" '近 7 天中位 未测量'
assert_contains 'empty home leaves the self-work share unmeasured' "$empty_body" '占比未测量'
assert_contains 'empty home states per-requirement spend is unmeasured' "$empty_body" '每个上线需求的令牌花费未测量'
assert_contains 'empty home states decision facts are unmeasured without inventing a decision' "$empty_body" '待决定事项未测量，无法列出问题和建议'

# The conclusion escalates: open incident beats risk beats normal.
conclusion_home="$tmp/conclusion"
mkdir -p "$conclusion_home/night"
conclusion_ledger="$conclusion_home/night/founder-health-mail.json"
fixture_incident_issue=$((fixture_issue_seed + 10))
maintainer_health_mail_ensure_ledger "$conclusion_ledger" 1000
maintainer_health_mail_incident_open "$conclusion_ledger" "$fixture_incident_issue" '线上服务中断' '服务中断。' \
  '用户暂时无法使用。' '正在恢复服务。' "$((facts_now + 3600))" "$facts_now" 1 >/dev/null
open_facts="$(maintainer_health_mail_daily_facts "$conclusion_home" "$conclusion_ledger" "$facts_now" "$SCRIPT_DIR/../..")"
assert_eq 'an open outage makes the conclusion 出事了' '出事了' "$(jq -r '.conclusion.level' <<< "$open_facts")"
assert_contains 'quality section counts the open incident' \
  "$(maintainer_health_mail_build_body "$open_facts")" '目前仍在处理 1 起'
assert_contains 'subject counts released requirements even during an outage' \
  "$(maintainer_health_mail_subject "$open_facts")" '工厂日报'
risk_runtime="$tmp/risk-runtime"
mkdir -p "$risk_runtime"
jq -n --arg generated "2026-11-07T15:30:00Z" \
  '{generated:$generated,metrics:[{node:"ci",desc:"排队积压",status:"UNHEALTHY"},{node:"flow",desc:"速度下降",status:"WARN"}]}' > "$risk_runtime/node-health.json"
assert_eq 'fresh risk and unhealthy scorecard rows are counted' '2' \
  "$(MAC_AUTOPILOT_RUNTIME_DIR="$risk_runtime" maintainer_health_mail_attention_count "$facts_home" "$facts_now")"

# Decisions come from the ledger, capped at three lines in the body.
fixture_decision_threshold=$((fixture_issue_seed + 11))
fixture_decision_signup=$((fixture_issue_seed + 12))
fixture_decision_terms=$((fixture_issue_seed + 13))
fixture_decision_plan=$((fixture_issue_seed + 14))
maintainer_health_mail_track_important "$conclusion_ledger" "decision:${fixture_decision_threshold}:阈值" decision '库存预警阈值' "$fixture_decision_threshold" "$facts_now" '库存预警阈值调到多少？' '建议：先按默认值运行一周' >/dev/null
maintainer_health_mail_track_important "$conclusion_ledger" "decision:${fixture_decision_signup}:注册" decision '自助注册' "$fixture_decision_signup" "$facts_now" '下周是否开放自助注册？' '建议：先小范围开放' >/dev/null
maintainer_health_mail_track_important "$conclusion_ledger" "decision:${fixture_decision_terms}:账期" decision '账期' "$fixture_decision_terms" "$facts_now" '账期是否从三十天改到十五天？' '建议：先维持三十天' >/dev/null
maintainer_health_mail_track_important "$conclusion_ledger" "decision:${fixture_decision_plan}:套餐" decision '套餐' "$fixture_decision_plan" "$facts_now" '是否下架旧套餐？' '建议：暂时保留旧套餐' >/dev/null
decision_facts="$(maintainer_health_mail_daily_facts "$conclusion_home" "$conclusion_ledger" "$facts_now" "$SCRIPT_DIR/../..")"
assert_eq 'four open decisions surface in facts' '4' "$(jq -r '.decisions.total' <<< "$decision_facts")"
assert_contains 'subject says something waits for the owner' \
  "$(maintainer_health_mail_subject "$decision_facts")" '有 4 件事等你'
decision_body="$(maintainer_health_mail_build_body "$decision_facts")"
assert_eq 'decision lines are capped at three' '3' "$(sed -n '/^需要你决定$/,$p' <<< "$decision_body" | grep -c '^- ')"
assert_contains 'each decision carries a recommendation' "$decision_body" '建议：先按默认值运行一周'
assert_contains 'decision body ends each question with a question mark' "$decision_body" '库存预警阈值调到多少？'

incomplete_decision_ledger="$conclusion_home/night/incomplete-decisions.json"
jq -n '{important_items:{one:{kind:"decision",status:"open",question:"",recommendation:""}}}' > "$incomplete_decision_ledger"
incomplete_decisions="$(maintainer_health_mail_decision_facts "$incomplete_decision_ledger")"
assert_eq 'a decision with missing fields remains counted but not listed' '1' "$(jq -r '.total' <<< "$incomplete_decisions")"
assert_eq 'missing decision fields do not get a fabricated recommendation' '0' "$(jq -r '.items | length' <<< "$incomplete_decisions")"
incomplete_body="$(maintainer_health_mail_build_body "$(jq -cn --argjson decisions "$incomplete_decisions" \
  --argjson base "$decision_facts" '$base | .decisions=$decisions')")"
assert_contains 'missing decision fields are stated without a proposed answer' \
  "$incomplete_body" '有 1 件事项缺少问题或建议，暂无法给出建议'

# --- Tick cadence -----------------------------------------------------------------

# A new day sends the report even with no queued change; the same day never
# resends; an urgent outage mail inside the day changes nothing about the
# daily cadence.
cadence_home="$tmp/cadence"
mkdir -p "$cadence_home/night" "$cadence_home/state"
cadence_day1="$(date -u -d '2026-11-07T00:10:00Z' +%s)"
cadence_day1_late="$((cadence_day1 + 1200))"
cadence_day2="$(date -u -d '2026-11-08T00:00:30Z' +%s)"
routine_sends=0
urgent_sends=0
routine_mail="$cadence_home/sent"
notify_maintainer_health() {
  routine_sends=$((routine_sends + 1))
  printf '%s\n%s\n' "$1" "$2" >> "$routine_mail"
}
notify_maintainer_incident() { urgent_sends=$((urgent_sends + 1)); }
maintainer_health_mail_tick "$cadence_home" "$cadence_day1"
assert_eq 'first daily report sends without any queued change' '1' "$routine_sends"
assert_contains 'daily subject carries the Beijing date' "$(sed -n '1p' "$routine_mail")" '工厂日报'
maintainer_health_mail_tick "$cadence_home" "$cadence_day1_late"
assert_eq 'same-day re-tick sends nothing' '1' "$routine_sends"
maintainer_health_mail_incident_open "$cadence_home/night/founder-health-mail.json" \
  99001 '线上服务中断' '服务中断。' '用户暂时无法使用。' '正在恢复服务。' \
  "$((cadence_day1_late + 3600))" "$cadence_day1_late" 1 >/dev/null
assert_eq 'urgent outage mail sends immediately inside the day' '1' "$urgent_sends"
maintainer_health_mail_tick "$cadence_home" "$cadence_day2"
assert_eq 'next day sends the next report' '2' "$routine_sends"
assert_eq 'ledger records both sends' '2' \
  "$(grep -c '^工厂日报' "$routine_mail")"

# A report build failure must leave the day's slot available for retry.
retry_home="$tmp/digest-retry"
mkdir -p "$retry_home/night"
retry_facts_file="$TMPDIR/owner-report-facts-fixture.json"
cat > "$retry_facts_file" <<'FIX'
{"report_day":"11-07","conclusion":{"level":"正常","reason":"无线上事故，也没有待上线的积压"},"window":{"start":1793596800,"end":1793683200},"releases":{"period_count":0,"total_ever":null,"last_at":null,"complete":false,"items":[],"zero_reason":"没有新版本通过上线验证。"},"progress":{"created_period":0,"open_total":0,"awaiting_period":0,"awaiting_total":0,"released_period":0,"released_total":null},"efficiency":{"per_day_week":0,"per_day_prev":0,"lead_days_week":null,"lead_days_prev":null,"split":null},"spend":{"tokens":0,"tokens_complete":true,"per_requirement":null,"money_usd":null,"money_complete":false},"quality":{"incidents_period":0,"incidents_open":0,"open_subjects":[],"rollbacks":0,"post_land_fixes":0},"decisions":{"items":[],"total":0,"incomplete":0},"attention":null}
FIX
maintainer_health_mail_output_contract "$(maintainer_health_mail_build_body "$(cat "$retry_facts_file")")" 1793683200
(
  maintainer_health_mail_daily_facts() {
    printf 'built\n' >> "$retry_home/builds"
    if [ "$(wc -l < "$retry_home/builds")" -eq 1 ]; then return 1; fi
    cat "$retry_facts_file"
  }
  retry_now="$(date -u -d '2026-11-07T00:05:00Z' +%s)"
  if maintainer_health_mail_tick "$retry_home" "$retry_now"; then
    echo 'not ok - first report build failure was hidden'
    exit 1
  fi
  if ! maintainer_health_mail_tick "$retry_home" "$((retry_now + 60))"; then
    echo 'not ok - report retry failed after build recovery'
    exit 1
  fi
  builds="$(wc -l < "$retry_home/builds")"
  [ "$builds" -eq 2 ] || { echo "not ok - same-slot retry skipped: builds=$builds"; exit 1; }
)
echo 'ok - report build failure leaves same-slot retry available'

# Only a delivery that proves no Gmail POST was attempted may release the
# current day for retry. Any attempted POST keeps the one-per-day claim.
retry_safe_home="$tmp/digest-safe-send-retry"
mkdir -p "$retry_safe_home/night"
(
  attempts=0
  notify_maintainer_health() {
    attempts=$((attempts + 1))
    if [ "$attempts" -eq 1 ]; then
      NOTIFY_LAST_SEND_RETRY_SAFE=1
      return 1
    fi
    NOTIFY_LAST_SEND_RETRY_SAFE=0
    return 0
  }
  maintainer_health_mail_daily_facts() { cat "$retry_facts_file"; }
  retry_now="$(date -u -d '2026-11-07T00:05:00Z' +%s)"
  if maintainer_health_mail_tick "$retry_safe_home" "$retry_now"; then
    echo 'not ok - pre-POST failure hidden from health maintenance'; exit 1
  fi
  maintainer_health_mail_tick "$retry_safe_home" "$((retry_now + 60))"
  slot="$(maintainer_health_mail_slot_key "$retry_now")"
  if [ "$attempts" -eq 2 ] && [ "$(jq -r '.last_digest_slot' "$retry_safe_home/night/founder-health-mail.json")" = "$slot" ] && \
    [ "$(jq -r '.last_sent_at' "$retry_safe_home/night/founder-health-mail.json")" = "$((retry_now + 60))" ]; then
    echo 'ok - proven pre-POST failure releases the day for a same-day retry'
  else
    echo "not ok - safe report retry failed: attempts=$attempts ledger=$(cat "$retry_safe_home/night/founder-health-mail.json")"
    exit 1
  fi
)

retry_uncertain_home="$tmp/digest-uncertain-send"
mkdir -p "$retry_uncertain_home/night"
(
  attempts=0
  notify_maintainer_health() {
    attempts=$((attempts + 1))
    NOTIFY_LAST_SEND_RETRY_SAFE=0
    return 1
  }
  maintainer_health_mail_daily_facts() { cat "$retry_facts_file"; }
  retry_now="$(date -u -d '2026-11-07T00:05:00Z' +%s)"
  if maintainer_health_mail_tick "$retry_uncertain_home" "$retry_now"; then
    echo 'not ok - uncertain send failure hidden from health maintenance'; exit 1
  fi
  maintainer_health_mail_tick "$retry_uncertain_home" "$((retry_now + 60))"
  slot="$(maintainer_health_mail_slot_key "$retry_now")"
  if [ "$attempts" -eq 1 ] && [ "$(jq -r '.last_digest_slot' "$retry_uncertain_home/night/founder-health-mail.json")" = "$slot" ] && \
    [ "$(jq -r '.last_sent_at' "$retry_uncertain_home/night/founder-health-mail.json")" = 0 ]; then
    echo 'ok - uncertain POST keeps one-per-day protection'
  else
    echo "not ok - uncertain report send was retried: attempts=$attempts ledger=$(cat "$retry_uncertain_home/night/founder-health-mail.json")"
    exit 1
  fi
)

# --- Ledger de-duplication --------------------------------------------------------

quiet_home="$tmp/quiet"
mkdir -p "$quiet_home/night" "$quiet_home/state"
quiet_ledger="$quiet_home/night/founder-health-mail.json"
quiet_event_key="release:$(printf '%s' "$quiet_home" | cksum | awk '{print $1}')"
maintainer_health_mail_record_event "$quiet_ledger" \
  "$quiet_event_key" '发布进度' '事项已上线。' 1790640001 >/dev/null
assert_eq 'recorded change waits in the pending queue' 'true' \
  "$(jq -r --arg key "$quiet_event_key" '.pending_events | has($key)' "$quiet_ledger")"
assert_eq 'pending item cannot be queued twice' 'existing' \
  "$(maintainer_health_mail_record_event "$quiet_ledger" \
    "$quiet_event_key" '发布进度' '事项已上线。' 1790640100)"
consumed="$(maintainer_health_mail_claim_digest "$quiet_ledger" 20261108 1790726400 \
  "$(jq -c '[.pending_events[]]' "$quiet_ledger")")"
assert_eq 'claim consumes the queued event' 'reserved' "$consumed"
assert_eq 'consumed event is marked reported' 'true' \
  "$(jq -r --arg key "$quiet_event_key" '.reported_items | has($key)' "$quiet_ledger")"
assert_eq 'consumed event leaves the pending queue' '0' \
  "$(jq '.pending_events | length' "$quiet_ledger")"
assert_eq 'already reported item cannot be queued again' 'reported' \
  "$(maintainer_health_mail_record_event "$quiet_ledger" \
    "$quiet_event_key" '发布进度' '事项已上线。' 1790730000)"
maintainer_health_mail_mark_sent "$quiet_ledger" 1790726400
assert_eq 'send time recorded' '1790726400' "$(jq -r '.last_sent_at' "$quiet_ledger")"

# --- Health measure (feeds the daily perf report file) ----------------------------

metric_home="$tmp/metrics"
mkdir -p "$metric_home/logs" "$metric_home/state"
metric_now="$(date -u -d '2026-09-29T12:00:00Z' +%s)"
printf '{"incidents":[]}\n' > "$tmp/empty-incidents.json"
printf '%s\n' '{"state":"ready-for-agent","unit_results":{"implement":{"result":"success","exit_status":"0","recorded_at":"2026-09-28T13:30:00Z"}},"model_policy":{"failures":[{"same_failure_streak":1,"recorded_at":"2026-09-28T14:00:00Z"}]}}' \
  > "$metric_home/state/9201.json"
printf '%s\n' '{"state":"ready-for-agent","unit_results":{"implement":{"result":"exit-code","exit_status":"1","recorded_at":"2026-09-29T10:40:00Z"}}}' \
  > "$metric_home/state/9202.json"
: > "$metric_home/logs/implement-9201-20260928T130000Z.log"
: > "$metric_home/logs/implement-9202-20260929T103000Z.log"
cat > "$metric_home/state/ticket-stage-status.json" <<'EOF'
{"sampled_at":"2026-09-29T11:30:00Z","tickets":{"9201":{"stage":"ready-for-agent","stage_age_minutes":75},"9202":{"stage":"ready-for-agent","stage_age_minutes":230},"9203":{"stage":"needs-triage","stage_age_minutes":500}}}
EOF
cat > "$metric_home/state/ticket-transitions.jsonl" <<'EOF'
{"ts":"2026-09-29T09:00:00Z","issue":9203,"from_stage":"ready-for-agent","to_stage":"on-hold","kind":"park"}
{"ts":"2026-09-29T10:00:00Z","issue":9203,"from_stage":"on-hold","to_stage":"ready-for-agent","kind":"advance"}
{"ts":"2026-09-28T00:16:00Z","issue":9301,"from_stage":"needs-triage","to_stage":"ready-for-agent","kind":"advance"}
{"ts":"2026-09-28T00:17:00Z","issue":9302,"from_stage":"needs-triage","to_stage":"ready-for-agent","kind":"advance"}
{"ts":"2026-09-28T00:18:00Z","issue":9303,"from_stage":"needs-triage","to_stage":"ready-for-agent","kind":"advance"}
{"ts":"2026-09-28T00:19:00Z","issue":9304,"from_stage":"needs-triage","to_stage":"ready-for-agent","kind":"advance"}
{"ts":"2026-09-28T00:20:00Z","issue":9305,"from_stage":"needs-triage","to_stage":"ready-for-agent","kind":"advance"}
EOF
{
  printf '%s\n' '{"at":"2026-09-29T10:00:00Z","kind":"ticket-progress","targets":[{"type":"issue","id":"9601"}],"state":"","decision":"budget"}'
  for issue in 9204 9205 9206 9207 9208; do
    printf '{"at":"2026-09-28T00:0%s:00Z","kind":"ticket-progress","targets":[{"type":"issue","id":"%s"}],"state":"","decision":"budget"}\n' \
      "$((issue - 9200))" "$issue"
  done
  for issue in 9301 9302 9303 9304 9305; do
    printf '{"at":"2026-09-28T00:1%s:00Z","kind":"acted-test","targets":[{"type":"issue","id":"%s"}],"state":"","decision":"wake"}\n' \
      "$((issue - 9300))" "$issue"
  done
  for issue in 9401 9402 9403 9404 9405; do
    printf '{"at":"2026-09-28T00:2%s:00Z","kind":"quiet-test","targets":[{"type":"issue","id":"%s"}],"state":"","decision":"wake"}\n' \
      "$((issue - 9400))" "$issue"
  done
  for sample in 1 2 3 4 5; do
    printf '{"at":"2026-09-28T00:4%s:00Z","kind":"node-stuck-30min","targets":[{"type":"node","id":"build"}],"state":"STUCK","decision":"wake"}\n' \
      "$sample"
  done
  printf '%s\n' '{"at":"2026-09-28T00:30:00Z","kind":"commit-test","targets":[{"type":"issue","id":"9501"}],"state":"","decision":"wake"}'
} > "$metric_home/logs/supervisor-alerts-2026-09-28.jsonl"
action_repo="$tmp/action-repo"
git init -q --initial-branch=main "$action_repo"
GIT_AUTHOR_DATE='2026-09-28T01:00:00Z' GIT_COMMITTER_DATE='2026-09-28T01:00:00Z' \
  git -C "$action_repo" -c user.name='Agent Test' -c user.email='agent-test@example.invalid' \
  commit --allow-empty -qm 'close issue 9501'
git -C "$action_repo" update-ref refs/remotes/origin/main "$(git -C "$action_repo" rev-parse HEAD)"
metric_json="$(AGENT_INCIDENT_GUARDS_FILE="$tmp/empty-incidents.json" \
  maintainer_health_mail_measure "$metric_home" '2026-09-29' "$metric_now" \
  "$action_repo")"
if jq -e '.implement_runs == 2 and .implement_result_count == 2 and .implement_success_rate == 0.5 and .oldest_queue_age_minutes == 260 and .repeat_failures == 1 and .false_freezes == 1 and ([.alert_classes[] | select(.kind == "acted-test")][0].action_rate == 1) and ([.alert_classes[] | select(.kind == "commit-test")][0].action_rate == 1) and ([.alert_classes[] | select(.kind == "quiet-test")][0].action_rate == 0) and ([.alert_classes[] | select(.kind == "node-stuck-30min")][0].action_rate == 0) and ([.alert_classes[] | select(.kind == "node-stuck-30min")][0].low_action == false)' <<< "$metric_json" >/dev/null; then
  echo 'ok - health measure reports runs, success, queue, repeats, freezes, and action rates'
else
  echo "not ok - health measure omitted outcome metrics: $metric_json"
  exit 1
fi
metric_lines="$(AGENT_INCIDENT_GUARDS_FILE="$tmp/empty-incidents.json" \
  maintainer_health_mail_metric_lines "$metric_home" "$metric_now")"
# 2026-10-04: class ids such as ticket-progress and mail-credential-health tripped the founder-mail
# internal-word filter, and the 00Z and 08Z digests were refused. Report a plain count instead.
if [[ "$metric_lines" == *'50%'* && "$metric_lines" == *'待修'* && "$metric_lines" != *'ticket-progress'* ]] \
  && ! (source "$SCRIPT_DIR/../notify.sh" >/dev/null 2>&1; grep -iEq "$MAINTAINER_BODY_INTERNAL_PATTERN" <<< "$metric_lines"); then
  echo 'ok - health report summarizes demoted alerts without internal class ids, and passes the internal-word filter'
else
  echo "not ok - health report leaks internal alert ids or omits metrics: $metric_lines"
  exit 1
fi
jq -e '.date == "2026-09-29" and (.demoted_classes | index("quiet-test")) != null and (.demoted_classes | index("node-stuck-30min")) == null' \
  "$metric_home/night/supervisor-alert-policy.json" >/dev/null
echo 'ok - low-action class policy is persisted without demoting node-stuck'

# The incident metrics use the target config registry ahead of an engine copy.
incident_config="$tmp/config/.zenoforge/state/incident-guards.json"
mkdir -p "$(dirname "$incident_config")"
printf '{"incidents":[{"id":"config-recurrence","date":"2026-09-29","recurs_of":"root","class":"config-class"}]}\n' \
  > "$incident_config"
config_metric="$(ZF_REPO_DIR="$tmp/config" ZF_CONFIG_ROOT="$tmp/config/.zenoforge" \
  ZF_ENGINE_DIR="$SCRIPT_DIR/.." maintainer_health_mail_measure \
    "$metric_home" '2026-09-29' "$metric_now" "$action_repo")"
jq -e '.recurrences_day == 1 and .recurrence_categories == ["config-class"]' \
  <<< "$config_metric" >/dev/null || {
    echo 'not ok - health measure did not read the target incident registry' >&2
    exit 1
}
echo 'ok - health measure reads target incident config'
echo 'ALL PASS'
