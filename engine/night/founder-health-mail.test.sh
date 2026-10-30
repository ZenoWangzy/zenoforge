#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
# The expected dates in this suite are Los Angeles wall-clock dates; the shipped comms profile defaults to UTC, so the suite pins its own zone.
ZF_COMMS_PROFILE="$TMPDIR/comms-profile-la.json"
printf '%s\n' '{"maintainer":{"language":"zh-CN","timezone":"America/Los_Angeles","timezone_label":"洛杉矶时间"}}' > "$ZF_COMMS_PROFILE"
export ZF_COMMS_PROFILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/founder-health-mail.sh"
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
mail_status_interval="$(founder_health_mail_digest_interval_seconds)"
founder_health_mail_ensure_ledger "$mail_status_ledger" 1000
assert_eq 'mail remains healthy through configured digest interval' 'OK' \
  "$(founder_health_mail_node_status "$mail_status_ledger" "$((1000 + mail_status_interval))")"
assert_eq 'missed digest becomes slow after five-minute grace' 'SLOW' \
  "$(founder_health_mail_node_status "$mail_status_ledger" "$((1000 + mail_status_interval + 300))")"
assert_eq 'missed digest becomes stuck after two-hour grace' 'STUCK' \
  "$(founder_health_mail_node_status "$mail_status_ledger" "$((1000 + mail_status_interval + 7200))")"

# 5297b1e16 起 founder_health_mail_maintainer_efficiency_block 返回
# {count,body,snapshot}；覆盖按同一契约返回固定表格。
founder_health_mail_efficiency_table='**效率（最近六小时）**
| 指标 | 当前六小时 | 前六小时 | 昨日同时段 |
| --- | ---: | ---: | ---: |
| 调度一轮耗时 | 430 秒 | 样本待补 | 样本待补 |
| 自动检查浪费占比 | 25% | 样本待补 | 样本待补 |
| 主干检查通过率 | 75% | 样本待补 | 样本待补 |
| 上线后复核有效率 | 50% | 样本待补 | 样本待补 |
| 派活失败次数 | 1 次 | 样本待补 | 样本待补 |
| 重复派活 | 1.0 次/人 | 样本待补 | 样本待补 |
| 提交失败次数 | 0 次 | 样本待补 | 样本待补 |
| 系统自动开单 / 关单 | 2 / 1 次 | 样本待补 | 样本待补 |'
founder_health_mail_maintainer_efficiency_block() {
  jq -cn --arg body "$founder_health_mail_efficiency_table" '{count:0,body:$body,snapshot:{}}'
}
founder_health_mail_no_launch_reason() { printf '主干检查未通过，修复后继续验证'; }
RETRY_VALID_BODY="$(founder_health_mail_build_body \
  '[{"key":"retry:1","section":"事项变化","text":"处理已更新。","kind":"node","created_at":1790640000}]' \
  "$founder_health_mail_efficiency_table" '没有新版本通过上线验证' '' '' 1790640000)"

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
live_work_counts="$(founder_health_mail_work_counts "$live_counts_home" 1791730000)"
assert_eq 'work counts use live units and current ready tickets' '{"active":5,"queued":2}' "$live_work_counts"

unset MAINTAINER_TEST_SYSTEMCTL_FILE MAINTAINER_TEST_READY_QUEUE_FILE

EMPTY_EPOCH_NOW="$(date +%s)"
EMPTY_EPOCH_TZ_MIN=$(( (1440 - (EMPTY_EPOCH_NOW / 60) % 1440 + 1) % 1440 ))
export TZ="PIN-$((EMPTY_EPOCH_TZ_MIN / 60)):$((EMPTY_EPOCH_TZ_MIN % 60))"

empty_sample_home="$tmp/empty-sample"
mkdir -p "$empty_sample_home/night" "$empty_sample_home/state"
printf 'progress status=STUCK sampled_at=\n' > "$empty_sample_home/night/night.log"
printf '{"incidents":[]}\n' > "$tmp/empty-incidents.json"
empty_day="$(date -u -d "@$EMPTY_EPOCH_NOW" +%Y-%m-%d)"
empty_measure="$(AGENT_INCIDENT_GUARDS_FILE="$tmp/empty-incidents.json" \
  founder_health_mail_measure "$empty_sample_home" "$empty_day" "$EMPTY_EPOCH_NOW" \
  "$(cd -- "$SCRIPT_DIR/../.." && pwd -P)")"
if jq -e 'has("health_samples") or has("longest_recovery_seconds")' <<< "$empty_measure" >/dev/null; then
  echo 'not ok - retired node sample fields remain in maintainer metrics'
  exit 1
fi
echo 'ok - maintainer metrics omit retired night sample fields'

assert_eq 'UTC digest slot stays fixed during first six-hour window' '20260928T06Z' \
  "$(founder_health_mail_slot_key "$(date -u -d '2026-09-28T10:59:59Z' +%s)")"
assert_eq 'UTC digest slot stays fixed before six-hour boundary' '20260928T06Z' \
  "$(founder_health_mail_slot_key "$(date -u -d '2026-09-28T11:59:59Z' +%s)")"
assert_eq 'UTC digest slot advances at six-hour boundary' '20260928T12Z' \
  "$(founder_health_mail_slot_key "$(date -u -d '2026-09-28T12:00:00Z' +%s)")"

# No pending change means no mail; the same reported key stays suppressed on
# later ticks and after a restart.
quiet_home="$tmp/quiet"
mkdir -p "$quiet_home/night" "$quiet_home/state"
quiet_sends=0
notify_founder_health() { quiet_sends=$((quiet_sends + 1)); }
founder_health_mail_tick "$quiet_home" 1790640000
assert_eq 'no change produces no maintainer mail' '0' "$quiet_sends"
founder_health_mail_record_event "$quiet_home/night/founder-health-mail.json" \
  'release:issue-1:sha-1' '发布进度' '事项已上线。' 1790640001 >/dev/null
founder_health_mail_tick "$quiet_home" 1790640002
assert_eq 'new change produces one digest' '1' "$quiet_sends"
assert_eq 'reported item key persists in ledger' 'true' \
  "$(jq -r '.reported_items | has("release:issue-1:sha-1")' "$quiet_home/night/founder-health-mail.json")"
assert_eq 'already reported item cannot be queued again' 'reported' \
  "$(founder_health_mail_record_event "$quiet_home/night/founder-health-mail.json" \
    'release:issue-1:sha-1' '发布进度' '事项已上线。' 1790640100)"
founder_health_mail_tick "$quiet_home" 1790643600
assert_eq 'already reported item is not repeated next hour' '1' "$quiet_sends"

# A digest just before the UTC hour boundary must hold the next routine digest
# until its full six-hour interval passes. Changes accumulate; urgent outage
# mail remains immediate and does not reset that interval.
(
  interval_home="$tmp/minimum-interval"
  mkdir -p "$interval_home/night" "$interval_home/state"
  interval_start="$(date -u -d '2026-09-28T10:59:26Z' +%s)"
  interval_19m=$((interval_start + 19 * 60))
  interval_20m=$((interval_start + 20 * 60))
  interval_5h59m59=$((interval_start + 21599))
  interval_6h=$((interval_start + 21600))
  routine_sends=0
  urgent_sends=0
  routine_mail="$tmp/minimum-interval-mail"
  notify_founder_health() {
    routine_sends=$((routine_sends + 1))
    printf '%s\n%s\n' "$1" "$2" >> "$routine_mail"
  }
  notify_founder_incident() { urgent_sends=$((urgent_sends + 1)); }

  founder_health_mail_ensure_ledger "$interval_home/night/founder-health-mail.json" "$interval_start"
  jq --argjson sent_at "$((interval_start - 21600))" '.last_sent_at=$sent_at | .last_digest_slot="20260928T00Z"' \
    "$interval_home/night/founder-health-mail.json" > "$interval_home/night/founder-health-mail.json.tmp"
  mv "$interval_home/night/founder-health-mail.json.tmp" "$interval_home/night/founder-health-mail.json"
  assert_eq 'interval fixture crosses UTC hour in 19 minutes' '10:59 -> 11:18' \
    "$(date -u -d "@$interval_start" +%H:%M) -> $(date -u -d "@$interval_19m" +%H:%M)"
  founder_health_mail_record_event "$interval_home/night/founder-health-mail.json" \
    'interval:first' '事项变化' '起始变化。' "$interval_start" >/dev/null
  founder_health_mail_record_event "$interval_home/night/founder-health-mail.json" \
    'daily:2026-10-12' '今日汇总' '昨天的统计已生成。' "$interval_start" daily >/dev/null
  founder_health_mail_tick "$interval_home" "$interval_start"
  assert_eq 'first six-hour digest sends' '1' "$routine_sends"
  assert_contains 'first six-hour digest carries pre-existing daily event' "$(cat "$routine_mail")" '昨天的统计已生成。'

  founder_health_mail_record_event "$interval_home/night/founder-health-mail.json" \
    'interval:boundary' '事项变化' '跨小时变化。' "$interval_19m" >/dev/null
  founder_health_mail_record_event "$interval_home/night/founder-health-mail.json" \
    'interval:accumulated' '事项变化' '间隔内新增变化。' "$interval_19m" >/dev/null
  founder_health_mail_tick "$interval_home" "$interval_19m"
  assert_eq '19-minute cross-hour tick sends no second digest' '1' "$routine_sends"
  assert_eq 'both changes remain queued during cooldown' '2' \
    "$(jq '.pending_events | length' "$interval_home/night/founder-health-mail.json")"

  founder_health_mail_incident_open "$interval_home/night/founder-health-mail.json" \
    99001 '线上服务中断' '服务中断。' '用户暂时无法使用。' '正在恢复服务。' \
    "$((interval_20m + 3600))" "$interval_20m" 1 >/dev/null
  assert_eq 'urgent outage mail sends inside routine interval' '1' "$urgent_sends"
  founder_health_mail_tick "$interval_home" "$interval_20m"
  assert_eq 'urgent mail does not reset routine interval' '1' "$routine_sends"

  founder_health_mail_tick "$interval_home" "$interval_5h59m59"
  assert_eq 'routine digest stays blocked one second before six hours' '1' "$routine_sends"
  founder_health_mail_tick "$interval_home" "$interval_6h"
  assert_eq 'routine digest sends at six hours after prior digest' '2' "$routine_sends"
  assert_contains 'next digest includes cross-hour change' "$(cat "$routine_mail")" '跨小时变化。'
  assert_contains 'next digest includes accumulated change' "$(cat "$routine_mail")" '间隔内新增变化。'
)

# Daily mail reads the independent scheduler scorecard, with freshness checked before rendering.
scorecard_home="$tmp/scorecard-mail"
scorecard_runtime="$tmp/scorecard-runtime"
mkdir -p "$scorecard_home" "$scorecard_runtime"
scorecard_now="$(date -u -d '2026-10-15T15:00:00Z' +%s)"
MAC_AUTOPILOT_RUNTIME_DIR="$scorecard_runtime"
export MAC_AUTOPILOT_RUNTIME_DIR
jq -n --arg generated "2026-10-15T14:00:00Z" \
  '{generated:$generated,metrics:[{node:"ci",desc:"queued runners",status:"UNHEALTHY"},{node:"review",desc:"review wait",status:"OK"}]}' \
  > "$scorecard_runtime/node-health.json"
scorecard_text="$(founder_health_mail_current_anomalies "$scorecard_home" "$scorecard_now")"
assert_contains 'current anomaly summary reads the scheduler scorecard' "$scorecard_text" 'queued runners'
assert_not_contains 'current anomaly summary skips healthy metrics' "$scorecard_text" 'review wait'
jq '.generated="2026-10-14T14:00:00Z"' "$scorecard_runtime/node-health.json" > "$scorecard_runtime/node-health.json.tmp"
mv "$scorecard_runtime/node-health.json.tmp" "$scorecard_runtime/node-health.json"
assert_eq 'stale scheduler scorecard is treated as missing data' '调度评分样本待补' \
  "$(founder_health_mail_current_anomalies "$scorecard_home" "$scorecard_now")"
unset MAC_AUTOPILOT_RUNTIME_DIR

state_home="$tmp/state-events"
mkdir -p "$state_home/night" "$state_home/state"
state_start="$(date -u -d '2026-09-28T10:00:00Z' +%s)"
state_now="$(date -u -d '2026-09-28T11:00:00Z' +%s)"
founder_health_mail_ensure_ledger "$state_home/night/founder-health-mail.json" "$state_start"
catalog_implementation="$(declare -f founder_health_mail_issue_catalog)"
cat > "$state_home/state/6001.json" <<'EOF'
{"state":"concluded","closed_by_pipeline":true,"run":{"outcome":"merged","merged_at":"2026-09-28T10:30:00Z","concluded_at":"2026-09-28T10:40:00Z","evidence":{"pr_number":42}},"deploy_state":"deployed","deployed_sha":"123456789abcdef","deployed_at":"2026-09-28T10:50:00Z"}
EOF
founder_health_mail_issue_catalog() {
  jq -cn --argjson ids "${1:-[]}" '[ $ids[] | {number:(tonumber),title:"订单检索",state:"CLOSED",labels:[{name:"focus"},{name:"priority:top"}]} ]'
}
founder_health_mail_collect_state_events \
  "$state_home/night/founder-health-mail.json" "$state_home" "$state_now"
assert_eq 'state changes queue release, deploy, and closure events' '3' \
  "$(jq '.pending_events | length' "$state_home/night/founder-health-mail.json")"
assert_contains 'deployment line uses production evidence timestamp' \
  "$(jq -r '.pending_events[] | select(.kind == "deploy") | .text' "$state_home/night/founder-health-mail.json")" \
  '9月28日 03:50 上线的版本'
assert_eq 'closed ticket headline hides tracker number' '修好了：订单检索。' \
  "$(jq -r '.pending_events[] | select(.kind == "closed") | .text' "$state_home/night/founder-health-mail.json")"
assert_contains 'priority closure appears in digest headline' \
  "$(founder_health_mail_build_body "$(jq -c '[.pending_events[]]' "$state_home/night/founder-health-mail.json")")" \
  '- 修好了：订单检索。'

# One damaged issue-state file must not suppress later valid issue events.
partial_home="$tmp/state-events-partial"
mkdir -p "$partial_home/night" "$partial_home/state"
founder_health_mail_ensure_ledger "$partial_home/night/founder-health-mail.json" "$state_start"
jq -n '{state:"concluded",closed_by_pipeline:true,run:{outcome:"merged",merged_at:"2026-09-28T10:30:00Z",concluded_at:"2026-09-28T10:40:00Z",evidence:{pr_number:43}},deploy_state:"deployed",deployed_sha:"abcdef123456789",deployed_at:"2026-09-28T10:50:00Z"}' \
  > "$partial_home/state/6003.json"
head -c 64 /dev/zero > "$partial_home/state/6002.json"
if ! founder_health_mail_collect_state_events \
  "$partial_home/night/founder-health-mail.json" "$partial_home" "$state_now" \
  2> "$partial_home/warnings.log"; then
  echo 'not ok - one damaged issue state must not abort the maintainer mail scan'
  cat "$partial_home/warnings.log"
  exit 1
fi
assert_eq 'valid issue after corrupt state still queues all events' '3' \
  "$(jq '.pending_events | length' "$partial_home/night/founder-health-mail.json")"
assert_contains 'corrupt issue state creates one supervisor alert' \
  "$(cat "$partial_home/supervisor-inbox")" 'founder-health-mail-unreadable-state issue=6002'
assert_contains 'partial state scan reports skipped issue to health wrapper' \
  "$(cat "$partial_home/warnings.log")" 'partial-state-scan unreadable=1 issues=6002'
if ! founder_health_mail_collect_state_events \
  "$partial_home/night/founder-health-mail.json" "$partial_home" "$state_now" \
  2> "$partial_home/repeat-warnings.log"; then
  echo 'not ok - repeated damaged issue state must remain isolated'
  cat "$partial_home/repeat-warnings.log"
  exit 1
fi
assert_eq 'recurring damaged state keeps one supervisor alert' '1' \
  "$(grep -c 'founder-health-mail-unreadable-state issue=6002' "$partial_home/supervisor-inbox")"
assert_eq 'recurring damaged state does not duplicate valid events' '3' \
  "$(jq '.pending_events | length' "$partial_home/night/founder-health-mail.json")"

# Recently merged old tickets need not appear in the newest 1000 issues.
catalog_home="$tmp/catalog-window"
mkdir -p "$catalog_home/night" "$catalog_home/state" "$catalog_home/bin"
cat > "$catalog_home/state/1598.json" <<'EOF'
{"run":{"outcome":"merged","merged_at":"2026-09-28T10:30:00Z","evidence":{"pr_number":2716}}}
EOF
cat > "$catalog_home/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CATALOG_CALLS"
if [[ "$1 $2" == 'api graphql' ]]; then
  if [[ "${CATALOG_VIEW_FAIL:-0}" == 1 ]]; then exit 1; fi
  query=''
  while (($#)); do
    if [[ "$1" == -f && "${2:-}" == query=* ]]; then query="${2#query=}"; break; fi
    shift
  done
  mapfile -t ids < <(grep -oE 'issue_[0-9]+' <<< "$query" | sed 's/^issue_//')
  labels="$(jq -c '[.[] | {name}]' <<< "${CATALOG_LABELS:-[]}")"
  printf '{"data":{"repository":{'
  first=1
  for id in "${ids[@]}"; do
    (( first )) || printf ','
    first=0
    printf '"issue_%s":{"number":%s,"title":"订单检索","state":"CLOSED","createdAt":"2026-09-01T00:00:00Z","closedAt":"2026-09-28T10:30:00Z","labels":{"nodes":%s}}' "$id" "$id" "$labels"
  done
  printf '}}}\n'
else
  echo 'unexpected gh request in catalog regression' >&2
  exit 97
fi
EOF
chmod +x "$catalog_home/bin/gh"
eval "$catalog_implementation"
(
  export PATH="$catalog_home/bin:$PATH" CATALOG_CALLS="$catalog_home/calls"
  founder_health_mail_work_counts() { printf '{"active":0,"queued":0}\n'; }
  notify_founder_health() { printf 'sent\n' >> "$catalog_home/sends"; }
  founder_health_mail_ensure_ledger "$catalog_home/night/founder-health-mail.json" "$state_start"
  founder_health_mail_tick "$catalog_home" "$state_now"
  founder_health_mail_tick "$catalog_home" "$((state_now + 60))"
  assert_eq 'catalog miss reaches one digest without a burst' '1' "$(wc -l < "$catalog_home/sends")"
  assert_eq 'catalog miss advances send ledger' "$state_now" "$(jq -r '.last_sent_at' "$catalog_home/night/founder-health-mail.json")"
  assert_eq 'old issue catalog lookup uses exactly one external call' '1' "$(grep -c '^api graphql ' "$catalog_home/calls")"
  assert_contains 'old issue is named directly in GraphQL query' "$(cat "$catalog_home/calls")" 'issue_1598: issue(number: 1598)'

  founder_health_mail_ensure_ledger "$catalog_home/night/pipeline.json" "$state_start"
  export CATALOG_LABELS='[{"name":"pipeline-system"}]'
  founder_health_mail_collect_state_events "$catalog_home/night/pipeline.json" "$catalog_home" "$state_now"
  assert_eq 'targeted lookup preserves pipeline exclusion' '0' "$(jq '.pending_events | length' "$catalog_home/night/pipeline.json")"

  export CATALOG_VIEW_FAIL=1
  jq '.pending_events["daily:2026-10-12"]={key:"daily:2026-10-12",section:"今日汇总",text:"昨天统计已生成。",created_at:1790640000,kind:"daily"}' \
    "$catalog_home/night/pipeline.json" > "$catalog_home/night/pipeline.json.tmp"
  mv "$catalog_home/night/pipeline.json.tmp" "$catalog_home/night/pipeline.json"
  if founder_health_mail_collect_state_events "$catalog_home/night/pipeline.json" "$catalog_home" "$state_now" 2>"$catalog_home/error"; then
    echo 'not ok - failed lookup invented an event'; exit 1
  fi
  assert_contains 'failed targeted lookup leaves actionable error' "$(cat "$catalog_home/error")" 'issue catalog lookup failed'
  assert_eq 'failed lookup preserves pending daily event' 'true' \
    "$(jq -r '.pending_events | has("daily:2026-10-12")' "$catalog_home/night/pipeline.json")"
  assert_eq 'failed targeted lookup leaves event unreported' '0' "$(jq '.reported_items | length' "$catalog_home/night/pipeline.json")"
)
# One unsafe legacy event must not poison the Chinese digest beside it.
poison_home="$tmp/poison-event"
mkdir -p "$poison_home/night"
(
  export AGENT_HOME="$poison_home"
  DRY_RUN=0
  founder_health_mail_incident_tick() { :; }
  notify_founder_health() {
    local reason
    reason="$(founder_mail_rejection_reason health "$1" "$2")"
    [ -z "$reason" ] || { echo "rejected: $reason" >&2; return 1; }
    printf '%s\n' "$2" > "$poison_home/body"
    printf 'sent\n' >> "$poison_home/sends"
  }
  ledger="$poison_home/night/founder-health-mail.json"
  founder_health_mail_record_event "$ledger" 'release:1598:2716:1' '发布进度' \
    '待上线：No preflight for the。' 1790640000 release >/dev/null
  founder_health_mail_record_event "$ledger" 'release:2:3:1' '发布进度' \
    '待上线：订单查询。' 1790640000 release >/dev/null
  if ! founder_health_mail_tick "$poison_home" 1790640000 2> "$poison_home/error"; then
    echo 'not ok - readable sibling could not be sent after unsafe item was filtered' >&2
    cat "$poison_home/error" >&2
    exit 1
  fi
  assert_eq 'poison event leaves one accepted send' 1 "$(wc -l < "$poison_home/sends")"
  assert_contains 'Chinese sibling survives poison event' "$(cat "$poison_home/body")" '订单查询'
  assert_eq 'poison English title excluded' 0 "$(grep -c 'No preflight' "$poison_home/body" || true)"
  assert_eq 'rejected event is marked consumed' true "$(jq '.reported_items | has("release:1598:2716:1")' "$ledger")"
  assert_eq 'rejected event leaves pending queue' false "$(jq '.pending_events | has("release:1598:2716:1")' "$ledger")"
  assert_eq 'rejected event remains recoverable in archive' true "$(jq '.rejected_events | has("release:1598:2716:1")' "$ledger")"
  assert_contains 'rejected key in retained tick output' "$(cat "$poison_home/error")" 'key=release:1598:2716:1 reason=body-language'
  founder_health_mail_tick "$poison_home" 1790643600 2>> "$poison_home/error"
  assert_eq 'poison-only retry sends no empty digest' 1 "$(wc -l < "$poison_home/sends")"
  assert_eq 'rejected key emits one inbox note' 1 "$(grep -c 'key=release:1598:2716:1' "$poison_home/supervisor-inbox")"
)

# Important open issues get at most one reminder in each four-hour window.
reminder_home="$tmp/reminders"
mkdir -p "$reminder_home/night" "$reminder_home/state"
reminder_ledger="$reminder_home/night/founder-health-mail.json"
founder_health_mail_ensure_ledger "$reminder_ledger" 100
founder_health_mail_track_important "$reminder_ledger" 'outage:42' outage '订单页无法打开' 42 100
founder_health_mail_collect_reminders "$reminder_ledger" "$reminder_home" 14499
assert_eq 'important item is not reminded before four hours' '0' \
  "$(jq '.pending_events | length' "$reminder_ledger")"
founder_health_mail_collect_reminders "$reminder_ledger" "$reminder_home" 14500
assert_eq 'important item is reminded at four hours' '仍在处理：订单页无法打开（已持续 4 小时）' \
  "$(jq -r '.pending_events[] | .text' "$reminder_ledger")"
founder_health_mail_collect_reminders "$reminder_ledger" "$reminder_home" 14501
assert_eq 'important reminder is not repeated inside four-hour window' '1' \
  "$(jq '.pending_events | length' "$reminder_ledger")"
reminder_events="$(jq -c '[.pending_events[]]' "$reminder_ledger")"
founder_health_mail_claim_digest "$reminder_ledger" 19700101T05Z 18000 "$reminder_events" >/dev/null
founder_health_mail_mark_sent "$reminder_ledger" 18000
founder_health_mail_collect_reminders "$reminder_ledger" "$reminder_home" 32399
assert_eq 'reminder cooldown starts at digest send time' '0' \
  "$(jq '.pending_events | length' "$reminder_ledger")"
founder_health_mail_collect_reminders "$reminder_ledger" "$reminder_home" 32400
assert_eq 'next reminder waits four hours after actual digest send' \
  '仍在处理：订单页无法打开（已持续 8 小时）' \
  "$(jq -r '.pending_events[] | .text' "$reminder_ledger")"

# A failed digest build must leave the slot available for the next tick.
retry_home="$tmp/digest-retry"
mkdir -p "$retry_home/night"
(
  founder_health_mail_build_body() {
    printf 'built\n' >> "$retry_home/builds"
    if [ "$(wc -l < "$retry_home/builds")" -eq 1 ]; then return 1; fi
    printf 'body\n'
  }
  founder_health_mail_record_event "$retry_home/night/founder-health-mail.json" \
    'retry:1' '事项变化' '处理已更新。' 1790640000 >/dev/null
  founder_health_mail_deliver() { printf 'delivered\n' >> "$retry_home/deliveries"; return 0; }
  founder_health_mail_incident_tick() { :; }
  if founder_health_mail_tick "$retry_home" 1790640000; then
    echo 'not ok - first digest build failure was hidden'
    exit 1
  fi
  if ! founder_health_mail_tick "$retry_home" 1790640001; then
    echo 'not ok - digest retry failed after build recovery'
    exit 1
  fi
  builds="$(wc -l < "$retry_home/builds")"
  deliveries=0
  [ ! -f "$retry_home/deliveries" ] || deliveries="$(wc -l < "$retry_home/deliveries")"
  if [ "$builds" -ne 2 ] || [ "$deliveries" -ne 1 ]; then
    echo "not ok - same-slot retry skipped: builds=$builds deliveries=$deliveries"
    exit 1
  fi
)
echo 'ok - digest build failure leaves same-slot retry available'

# Only a delivery that proves no Gmail POST was attempted may release the
# current UTC slot for retry. Any attempted POST keeps the one-per-slot claim.
retry_safe_home="$tmp/digest-safe-send-retry"
mkdir -p "$retry_safe_home/night"
(
  attempts=0
  notify_founder_health() {
    attempts=$((attempts + 1))
    if [ "$attempts" -eq 1 ]; then
      NOTIFY_LAST_SEND_RETRY_SAFE=1
      return 1
    fi
    NOTIFY_LAST_SEND_RETRY_SAFE=0
    return 0
  }
  founder_health_mail_incident_tick() { :; }
  founder_health_mail_build_body() { printf '%s\n' "$RETRY_VALID_BODY"; }
  founder_health_mail_record_event "$retry_safe_home/night/founder-health-mail.json" \
    'retry:1' '事项变化' '处理已更新。' 1790640000 >/dev/null
  if founder_health_mail_tick "$retry_safe_home" 1790640000; then
    echo 'not ok - pre-POST failure hidden from health maintenance'; exit 1
  fi
  founder_health_mail_tick "$retry_safe_home" 1790640001
  slot="$(founder_health_mail_slot_key 1790640000)"
  if [ "$attempts" -eq 2 ] && [ "$(jq -r '.last_digest_slot' "$retry_safe_home/night/founder-health-mail.json")" = "$slot" ] && \
    [ "$(jq -r '.last_sent_at' "$retry_safe_home/night/founder-health-mail.json")" = 1790640001 ]; then
    echo 'ok - proven pre-POST failure releases digest slot for same-slot retry'
  else
    echo "not ok - safe digest retry failed: attempts=$attempts ledger=$(cat "$retry_safe_home/night/founder-health-mail.json")"
    exit 1
  fi
)

retry_uncertain_home="$tmp/digest-uncertain-send"
mkdir -p "$retry_uncertain_home/night"
(
  attempts=0
  notify_founder_health() {
    attempts=$((attempts + 1))
    NOTIFY_LAST_SEND_RETRY_SAFE=0
    return 1
  }
  founder_health_mail_incident_tick() { :; }
  founder_health_mail_build_body() { printf '%s\n' "$RETRY_VALID_BODY"; }
  founder_health_mail_record_event "$retry_uncertain_home/night/founder-health-mail.json" \
    'retry:1' '事项变化' '处理已更新。' 1790640000 >/dev/null
  if founder_health_mail_tick "$retry_uncertain_home" 1790640000; then
    echo 'not ok - uncertain send failure hidden from health maintenance'; exit 1
  fi
  founder_health_mail_tick "$retry_uncertain_home" 1790640001
  slot="$(founder_health_mail_slot_key 1790640000)"
  if [ "$attempts" -eq 1 ] && [ "$(jq -r '.last_digest_slot' "$retry_uncertain_home/night/founder-health-mail.json")" = "$slot" ] && \
    [ "$(jq -r '.last_sent_at' "$retry_uncertain_home/night/founder-health-mail.json")" = 0 ]; then
    echo 'ok - uncertain POST keeps one-per-slot digest protection'
  else
    echo "not ok - uncertain digest send was retried: attempts=$attempts ledger=$(cat "$retry_uncertain_home/night/founder-health-mail.json")"
    exit 1
  fi
)

# Health outcome metrics reuse implement logs, unit results, ticket progress,
# issue transitions, and the inbox writer's class ledger.
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
  founder_health_mail_measure "$metric_home" '2026-09-29' "$metric_now" \
  "$action_repo")"
if jq -e '.implement_runs == 2 and .implement_result_count == 2 and .implement_success_rate == 0.5 and .oldest_queue_age_minutes == 260 and .repeat_failures == 1 and .false_freezes == 1 and ([.alert_classes[] | select(.kind == "acted-test")][0].action_rate == 1) and ([.alert_classes[] | select(.kind == "commit-test")][0].action_rate == 1) and ([.alert_classes[] | select(.kind == "quiet-test")][0].action_rate == 0) and ([.alert_classes[] | select(.kind == "node-stuck-30min")][0].action_rate == 0) and ([.alert_classes[] | select(.kind == "node-stuck-30min")][0].low_action == false)' <<< "$metric_json" >/dev/null; then
  echo 'ok - health measure reports runs, success, queue, repeats, freezes, and action rates'
else
  echo "not ok - health measure omitted outcome metrics: $metric_json"
  exit 1
fi
metric_lines="$(AGENT_INCIDENT_GUARDS_FILE="$tmp/empty-incidents.json" \
  founder_health_mail_metric_lines "$metric_home" "$metric_now")"
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
