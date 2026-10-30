#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
# The expected dates in this suite are Los Angeles wall-clock dates; the shipped comms profile defaults to UTC, so the suite pins its own zone.
ZF_COMMS_PROFILE="$TMPDIR/comms-profile-la.json"
printf '%s\n' '{"maintainer":{"language":"zh-CN","timezone":"America/Los_Angeles","timezone_label":"洛杉矶时间"}}' > "$ZF_COMMS_PROFILE"
export ZF_COMMS_PROFILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/maintainer-health-mail.sh"

assert_contains() {
  local label="$1" value="$2" expected="$3"
  [[ "$value" == *"$expected"* ]] || { printf 'not ok - %s (missing %s)\n' "$label" "$expected" >&2; exit 1; }
  printf 'ok - %s\n' "$label"
}
assert_not_contains() {
  local label="$1" value="$2" rejected="$3"
  [[ "$value" != *"$rejected"* ]] || { printf 'not ok - %s (found %s)\n' "$label" "$rejected" >&2; exit 1; }
  printf 'ok - %s\n' "$label"
}
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [[ "$expected" == "$actual" ]] || { printf 'not ok - %s (expected %s, got %s)\n' "$label" "$expected" "$actual" >&2; exit 1; }
  printf 'ok - %s\n' "$label"
}

now="$(date -u -d '2026-10-12T14:00:00Z' +%s)"
mkdir -p "$AGENT_HOME/night" "$AGENT_HOME/metrics"
maintainer_health_mail_active_implements() { printf '0\n'; }
cat > "$AGENT_HOME/metrics/efficiency-2026-10.jsonl" <<'METRICS'
{"record_type":"event","event_type":"ticket-created","issue":101,"ts":"2026-10-12T13:00:00Z"}
{"record_type":"event","event_type":"ticket-released","issue":101,"ts":"2026-10-12T13:30:00Z"}
{"record_type":"event","event_type":"github-closed","issue":101,"ts":"2026-10-12T13:45:00Z"}
{"record_type":"event","event_type":"ticket-created","issue":102,"ts":"2026-10-12T12:00:00Z"}
{"record_type":"event","event_type":"ticket-released","issue":102,"ts":"2026-10-12T12:30:00Z"}
{"record_type":"event","event_type":"github-closed","issue":102,"ts":"2026-10-12T12:45:00Z"}
{"record_type":"event","event_type":"ticket-created","issue":103,"ts":"2026-10-05T13:00:00Z"}
{"record_type":"event","event_type":"ticket-released","issue":103,"ts":"2026-10-05T13:15:00Z"}
{"record_type":"event","event_type":"github-closed","issue":103,"ts":"2026-10-05T13:30:00Z"}
{"record_type":"hourly","sampled_at":"2026-10-12T13:00:00Z","metrics":{"queue_to_implement_seconds":3600,"implement_to_merge_seconds":1800,"merge_to_release_seconds":null,"ci_queue_seconds":300,"ci_run_seconds":120}}
{"record_type":"hourly","sampled_at":"2026-10-11T13:00:00Z","metrics":{"queue_to_implement_seconds":7200,"implement_to_merge_seconds":1800,"merge_to_release_seconds":null,"ci_queue_seconds":600,"ci_run_seconds":180}}
{"record_type":"daily","event_id":"daily:2026-10-11","day":"2026-10-11","nodes":{"status":"available","stages":[{"key":"unrouted","samples":2,"mean_seconds":37800,"p50_seconds":36000,"p90_seconds":40000,"open_at_end":1,"comparison":{"previous_day":"2026-10-10","previous_mean_seconds":null,"seven_day_days":["2026-10-04"],"seven_day_mean_seconds":117521.5}}],"terminal":[]},"checks":{"ci":[{"key":"ci:pr:Pipeline suites shard 1","name":"Pipeline suites shard 1","category":"ci","cohort":"pr","source_status":"available","status_samples":1,"fail_cancel_rate":0,"run":{"samples":1,"mean_seconds":1188,"comparison":{"previous_day":"2026-10-10","previous_mean_seconds":null,"seven_day_days":[],"seven_day_mean_seconds":null}},"queue":{"samples":1,"mean_seconds":10008,"comparison":{"previous_day":"2026-10-10","previous_mean_seconds":null,"seven_day_days":[],"seven_day_mean_seconds":null}}}],"local":[]}}
METRICS
ledger="$AGENT_HOME/night/founder-health-mail.json"
cat > "$ledger" <<'LEDGER'
{"started_at":1791810000,"last_sent_at":0,"last_digest_slot":"","nodes":{},"incidents":[],"reported_items":{},"important_items":{},"pending_events":{
  "node:merge:alert:0":{"key":"node:merge:alert:0","section":"处理变化","text":"变更合入暂停，自1月1日 08:00起约497719小时：部分检查未通过。","kind":"node","created_at":1791809358},
  "node:merge:alert:1791730462":{"key":"node:merge:alert:1791730462","section":"处理变化","text":"变更合入暂停，自10月11日 22:54起约1小时：部分检查未通过。","kind":"node","created_at":1791809358},
  "merge-reminder-old":{"key":"merge-reminder-old","section":"仍在处理","text":"仍在处理：变更合入暂停，自10月11日 22:54起约1小时：部分检查未通过。（已持续 17 小时）","kind":"reminder","reminder_for":"node-important:merge:1791730462","created_at":1791810000},
  "merge-reminder-zero":{"key":"merge-reminder-zero","section":"仍在处理","text":"仍在处理：仍在处理：变更合入暂停，自1月1日 08:00起约497719小时。（已持续 4 小时）","kind":"reminder","reminder_for":"node-important:merge:0","created_at":1791810001},
  "node:implement:alert:0":{"key":"node:implement:alert:0","section":"处理变化","text":"开发暂停，自1月1日 08:00起约497724小时：连接 GitHub 的网络时断时续。","kind":"node","created_at":1791809358},
  "release:bad-title":{"key":"release:bad-title","section":"发布进度","text":"待上线：No preflight for the #3451 ABCDEF1234567890。","kind":"release","created_at":1791810001}
}}
LEDGER

work_data="$(maintainer_health_mail_work_counts "$AGENT_HOME" "$now")"
efficiency='**效率（最近六小时）**
| 指标 | 当前六小时 | 前六小时 | 昨日同时段 |
| --- | ---: | ---: | ---: |
| 调度一轮耗时 | 900 秒 | 1000 秒 | 1100 秒 |
| 自动检查浪费占比 | 25% | 40% | 35% |
| 主干检查通过率 | 75% | 60% | 65% |
| 上线后复核有效率 | 50% | 70% | 65% |
| 派活失败次数 | 1 次 | 2 次 | 1 次 |
| 重复派活 | 1.0 次/人 | 1.3 次/人 | 1.1 次/人 |
| 提交失败次数 | 0 次 | 1 次 | 0 次 |
| 系统自动开单 / 关单 | 2 / 1 次 | 3 / 2 次 | 2 / 2 次 |
- 自动检查浪费占比较前六小时下降38%。'
pipeline_efficiency="$(maintainer_health_mail_pipeline_efficiency_block "$AGENT_HOME" hourly "$now")"
assert_contains 'missing lifecycle history renders unknown hours and coverage' "$pipeline_efficiency" \
  '实现 数据待补 覆盖待补'
maintainer_health_mail_work_counts() { printf '{"active":0,"queued":227}\n'; }
work_data="$(maintainer_health_mail_work_counts "$AGENT_HOME" "$now")"
work_reason="$(maintainer_health_mail_no_work_reason "$(jq -r '.active' <<< "$work_data")" "$(jq -r '.queued' <<< "$work_data")")"
assert_contains 'live queue count explains that work remains available' "$work_reason" '仍有待领取事项在队列中'
events="$(jq -c '[.pending_events[]]' "$ledger")"
body="$(maintainer_health_mail_build_body "$events" "$efficiency" '没有新版本通过上线验证' "$work_reason" "$pipeline_efficiency" "$now")"

maintainer_health_mail_output_contract "$body" "$now"
source "$SCRIPT_DIR/../notify.sh"
raw_mail="$(build_gmail_raw_message 'maintainer@fixture.invalid' '工作进展简报' "$body" '' '100-200-301')"
python3 - "$raw_mail" <<'PY'
import base64
import sys
from email import policy
from email.parser import BytesParser

message = BytesParser(policy=policy.default).parsebytes(base64.urlsafe_b64decode(sys.argv[1]))
assert message['X-Zenoforge-Agent-Mailer'] == 'zf-pipeline-v1'
assert message['X-Zenoforge-Agent-Mailer-ID'] == '100-200-301'
print('ok - pipeline MIME carries origin and notify.log correlation headers')
PY
assert_contains 'rendered golden includes requested efficiency table' "$body" '| 调度一轮耗时 | 900 秒 | 1000 秒 | 1100 秒 |'
assert_contains 'rendered golden puts efficiency before launch status' "$body" '**效率（最近六小时）**'
assert_eq 'efficiency section is first in the maintainer mail' '**效率（最近六小时）**' "$(sed -n '1p' <<< "$body")"
assert_contains 'zero active count uses the live ready queue' "$body" '当前无人处理：仍有待领取事项在队列中。'
assert_contains 'earliest valid open time wins and duration is recomputed' "$body" '自10月11日 07:54起约23小时'
assert_contains 'missing start is stated as unavailable' "$body" '开发暂停，开始时间暂无数据'
assert_contains 'English release fragment becomes readable Chinese' "$body" '待上线：这项改进的上线准备尚未完成。'
assert_not_contains 'no epoch-derived date survives' "$body" '1月1日'
assert_not_contains 'no issue or commit id survives' "$body" '#3451'
assert_not_contains 'no commit hash survives' "$body" 'ABCDEF1234567890'
assert_not_contains 'no doubled section prefix survives' "$body" '仍在处理：仍在处理'
assert_eq 'one near-duplicate merge condition renders once' '1' "$(grep -o '变更合入暂停' <<< "$body" | wc -l | tr -d '[:space:]')"
reminder_only='[{"key":"reminder:node-important:merge:0:1791810000","section":"仍在处理","text":"仍在处理：变更合入暂停，自1月1日 08:00起约497719小时；预计恢复时间暂无数据。","kind":"reminder","reminder_for":"node-important:merge:0","created_at":1791810000}]'
reminder_normalized="$(maintainer_health_mail_normalize_events "$reminder_only" "$now")"
assert_eq 'legacy reminder-only node events collapse to one condition' '1' "$(jq 'length' <<< "$reminder_normalized")"
assert_contains 'legacy reminder-only node event gets a safe start time' "$reminder_normalized" '开始时间暂无数据'
assert_not_contains 'legacy reminder-only node event drops epoch date' "$reminder_normalized" '1月1日'
assert_not_contains 'legacy reminder-only node event drops unknown ETA fragment' "$reminder_normalized" '预计恢复时间暂无数据'
legacy_epoch_alert='[{"key":"node:deploy:alert:0","section":"处理变化","text":"版本上线暂停，自1月1日 08:00起约497705小时：生产验证未完成，检查通过后继续；预计恢复时间暂无数据。","kind":"node","created_at":0}]'
epoch_alert_normalized="$(maintainer_health_mail_normalize_events "$legacy_epoch_alert" "$now")"
assert_contains 'legacy epoch-zero alert is rewritten with unknown start and next action' \
  "$epoch_alert_normalized" '版本上线暂停，开始时间暂无数据：生产验证未完成，检查通过后继续。'
assert_not_contains 'legacy epoch-zero alert drops false start date' "$epoch_alert_normalized" '1月1日'
assert_not_contains 'legacy epoch-zero alert drops false duration' "$epoch_alert_normalized" '497705小时'
if grep -oE '[A-Za-z]+' <<< "$body" | grep -vxF GitHub >/dev/null; then
  echo 'not ok - rendered golden contains ASCII outside allowlist' >&2
  exit 1
fi
echo 'ok - rendered golden has no unapproved ASCII runs'

bad_duration="${body/约23小时/约1小时}"
if duration_error="$(maintainer_health_mail_output_contract "$bad_duration" "$now")"; then
  echo 'not ok - duration mismatch passed contract' >&2
  exit 1
fi
assert_contains 'contract rejects contradictory duration' "$duration_error" 'duration-mismatch'

bad_metric="${body/| 调度一轮耗时 | 900 秒 | 1000 秒 | 1100 秒 |/| 调度一轮耗时 | 暂无数据 | 1000 秒 | 1100 秒 |}"
if metric_error="$(maintainer_health_mail_output_contract "$bad_metric" "$now")"; then
  echo 'not ok - metric cell with unavailable data passed contract' >&2
  exit 1
fi
assert_contains 'contract still rejects unavailable metric cells' "$metric_error" 'metric-cell-empty'

sent=0
export DRY_RUN=0
notify_maintainer_health() {
  sent=$((sent + 1))
  printf '%s\n' "$2" > "$AGENT_HOME/sent-body"
}
maintainer_health_mail_record_event "$ledger" 'poison:pending' '发布进度' \
  '待上线：No preflight for the。' "$now" release >/dev/null
maintainer_health_mail_record_event "$ledger" 'safe:pending' '事项变化' \
  '订单查询已恢复。' "$now" event >/dev/null
events="$(maintainer_health_mail_filter_events "$(jq -c '[.pending_events[]]' "$ledger")" "$AGENT_HOME" "$now")"
maintainer_health_mail_deliver "$ledger" "$now" '20261012T14Z' '工作进展简报' \
  "$body"$'\n- Channel Gateway 审批与飞\n订单查询已恢复。' "$events"
assert_eq 'one English title and bad pending event still permit transport' '1' "$sent"
assert_not_contains 'English title never reaches transport' "$(cat "$AGENT_HOME/sent-body")" 'Channel Gateway'
assert_contains 'valid sibling remains in delivered mail' "$(cat "$AGENT_HOME/sent-body")" '订单查询已恢复。'
maintainer_health_mail_output_contract "$(cat "$AGENT_HOME/sent-body")" "$now"
assert_eq 'rejected pending event exits pending ledger' 'false' "$(jq '.pending_events | has("poison:pending")' "$ledger")"
assert_eq 'rejected event is archived with original evidence' '待上线：No preflight for the。' \
  "$(jq -r '.rejected_events["poison:pending"].event.text' "$ledger")"
assert_eq 'same rejected key cannot requeue' 'reported' \
  "$(maintainer_health_mail_record_event "$ledger" 'poison:pending' '发布进度' '待上线：No preflight for the。' "$now" release)"
# Even after the inbox is consumed and the normal 24-hour once window expires,
# the ledger remembers each rejected line and event.
rm -f "$AGENT_HOME/supervisor-inbox" "$AGENT_HOME/supervisor-inbox.once"
later_body="$(grep -v '自.*起约' <<< "$body")"
maintainer_health_mail_deliver "$ledger" "$((now + 90000))" '20261013T15Z' '工作进展简报' \
  "$later_body"$'\n- Channel Gateway 审批与飞' '[{"key":"later:safe","created_at":1791900000}]'
assert_eq 'rejected lines do not alert again after inbox consumption' 'false' \
  "$([ -e "$AGENT_HOME/supervisor-inbox" ] && printf true || printf false)"
assert_eq 'mixed Chinese and English title is rendered in Chinese' '渠道网关 审批与飞书通知' \
  "$(maintainer_health_mail_plain_title 'Channel Gateway 审批与飞书通知')"
assert_eq 'unknown English in title uses readable fallback' '功能改进' \
  "$(maintainer_health_mail_plain_title 'UntranslatedFeature 中文标题')"
# A rejected heading cannot take its readable child lines with it; a bad
# metric row becomes an explained unknown instead of erasing the required table.
damaged_body="$later_body"$'\n**English heading**\n库存查询已恢复。'
damaged_body="${damaged_body/900 秒/raw English}"
damaged_body="${damaged_body/| 指标 | 当前六小时 | 前六小时 | 昨日同时段 |/| 指标 | 当前六小时 | English | 昨日同时段 |}"
isolated="$(maintainer_health_mail_output_contract "$damaged_body" "$now" isolate-lines)"
cleaned="$(jq -r '.body' <<< "$isolated")"
maintainer_health_mail_output_contract "$cleaned" "$now"
assert_contains 'bad heading preserves readable child' "$cleaned" '库存查询已恢复。'
assert_contains 'bad metric row becomes explained unknown' "$cleaned" '| 统计项目 | 数据待核实 | 数据待核实 | 数据待核实 |'
echo 'ALL PASS'
