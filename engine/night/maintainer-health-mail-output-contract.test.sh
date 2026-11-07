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

contract_rejects() {
  local label="$1" body="$2" want="$3" errors
  if errors="$(maintainer_health_mail_output_contract "$body" "$now")"; then
    printf 'not ok - %s passed the contract\n' "$label" >&2
    exit 1
  fi
  assert_contains "$label names the rule" "$errors" "$want"
}

now="$(date -u -d '2026-11-07T16:00:00Z' +%s)"
mkdir -p "$AGENT_HOME/night" "$AGENT_HOME/metrics"

golden_body='一句话结论：正常——过去一天 2 个需求上线，无线上事故。

今天上线了什么
- 「订单导出」：用户可以把订单导出成表格（11月7日 07:33上线）
- 「库存提醒」：库存低于阈值时用户会收到提醒（11月6日 22:10上线）

进度
- 新提出：过去一天 3 个；累计 48 个；目前在办共 12 个。
- 已做完等上线：过去一天 1 个；当前共 2 个。
- 已上线：过去一天 2 个；有记录以来共 31 个。

效率
- 近 7 天平均每天上线 0.7 个需求；上一个 7 天 1.1 个。
- 需求从提出到上线：近 7 天中位 2.4 天；上一个 7 天 3.1 天。
- 近 7 天已分类工作时间：需求 72%；工厂自身维护 28%；另有 0.4 小时未分类。

花费
- 过去一天令牌用量 1234.6 万；每个上线需求平均 617.3 万令牌。
- 金额没有完整记录，无法算出总花费。

质量
- 线上事故：过去一天 0 起；目前仍在处理 0 起。
- 回滚：过去一天 0 次。
- 已上线需求后来再出问题并返修：过去一天 1 起。

需要你决定
- 库存预警阈值调到多少？——建议：先按默认值运行一周。'

maintainer_health_mail_output_contract "$golden_body" "$now"
echo 'ok - golden owner report passes the contract'

contract_rejects 'an empty body is refused' '' 'empty-body'
contract_rejects 'a missing conclusion line is refused' "$(tail -n +2 <<< "$golden_body")" 'conclusion'
contract_rejects 'a conclusion without a known level is refused' \
  "${golden_body/一句话结论：正常——/一句话结论：还行——}" 'conclusion'
contract_rejects 'a missing section is refused' "$(grep -v '^效率$' <<< "$golden_body")" 'missing-section'
contract_rejects 'a reordered section is refused' \
  "$(grep -v '^今天上线了什么$' <<< "$golden_body" | sed 's/^效率$/今天上线了什么\n效率/')" 'section-order'
contract_rejects 'an empty section is refused' \
  "$(grep -v '^- 过去一天令牌用量\|^- 金额没有完整记录' <<< "$golden_body")" 'empty-section'
contract_rejects 'four decision lines are refused' \
  "$golden_body
- 第二个问题——建议：按默认继续。
- 第三个问题——建议：按默认继续。
- 第四个问题——建议：按默认继续。" 'decision-limit'
contract_rejects 'an English word is refused' "$golden_body
- Channel Gateway 审批与飞书通知" 'ascii-text'
contract_rejects 'a tracker id is refused' "$golden_body
- 事项 #3451 已上线" 'issue-id'
contract_rejects 'an epoch-derived date is refused' "${golden_body/一句话结论：正常——/一句话结论：正常——自1月1日起}" 'epoch-date'
contract_rejects 'an iso timestamp is refused' "$golden_body
- 上线时间 2026-11-07T08:00:00Z" 'iso-date'
contract_rejects 'an unreadable release date is refused' "$golden_body
- 上线时间待核实" 'epoch-date'
if errors="$(maintainer_health_mail_output_contract "$golden_body" 0)"; then
  echo 'not ok - an unreadable report date passed the contract' >&2
  exit 1
fi
assert_contains 'unreadable report epoch is rejected' "$errors" 'epoch-date'

# isolate-lines drops only the offending line and keeps the report sendable.
isolated="$(maintainer_health_mail_output_contract "$golden_body
- 内部诊断：Channel Gateway retry pending" "$now" isolate-lines)"
cleaned="$(jq -r '.body' <<< "$isolated")"
assert_not_contains 'isolation drops the unsafe line' "$cleaned" 'Channel Gateway'
assert_contains 'isolation keeps the readable neighbour' "$cleaned" '用户可以把订单导出成表格'
maintainer_health_mail_output_contract "$cleaned" "$now"
echo 'ok - isolated report still passes the contract'

# The shared pre-send gate accepts the same report through the strict sender.
source "$SCRIPT_DIR/../notify.sh"
body_with_env="${golden_body/需要你决定/$'ZF_HOME\n需要你决定'}"
body_with_path="${golden_body/需要你决定/$'\$HOME/private.log\n需要你决定'}"
body_with_sha="${golden_body/需要你决定/$'版本：b454fd00fa\n需要你决定'}"
assert_eq 'notify gate accepts the golden owner report' '' \
  "$(maintainer_mail_rejection_reason health '工厂日报 11-07：上线 2 个需求，有 1 件事等你' "$golden_body")"
assert_eq 'notify gate refuses a foreign subject' 'health-subject' \
  "$(maintainer_mail_rejection_reason health '工作进展简报' "$golden_body")"
assert_eq 'notify gate refuses an empty digest' 'health-sections' \
  "$(maintainer_mail_rejection_reason health '工厂日报 11-07：上线 0 个需求，有 0 件事等你' '- 没有')"
assert_eq 'notify gate refuses environment names' 'body-internal' \
  "$(maintainer_mail_rejection_reason health '工厂日报 11-07：上线 0 个需求，有 0 件事等你' "$body_with_env")"
assert_eq 'notify gate refuses file paths' 'body-internal' \
  "$(maintainer_mail_rejection_reason health '工厂日报 11-07：上线 0 个需求，有 0 件事等你' "$body_with_path")"
assert_eq 'notify gate refuses long SHAs' 'body-internal' \
  "$(maintainer_mail_rejection_reason health '工厂日报 11-07：上线 0 个需求，有 0 件事等你' "$body_with_sha")"
assert_eq 'notify gate refuses a roster recipient' 'health-recipient' \
  "$(_pre_send_mail_rejection_for_recipients health '工厂日报 11-07：上线 0 个需求，有 0 件事等你' "$golden_body" reporter-recipient)"

# The MIME renderer carries the origin headers for the owner report too.
raw_mail="$(build_gmail_raw_message 'maintainer-recipient' '工厂日报 11-07：上线 2 个需求，有 1 件事等你' "$golden_body" '' '100-200-301')"
python3 - "$raw_mail" <<'PY'
import base64
import sys
from email import policy
from email.parser import BytesParser

message = BytesParser(policy=policy.default).parsebytes(base64.urlsafe_b64decode(sys.argv[1]))
assert message['X-Zenoforge-Agent-Mailer'] == 'zf-pipeline-v1'
assert message['X-Zenoforge-Agent-Mailer-ID'] == '100-200-301'
print('ok - owner report MIME carries origin and notify.log correlation headers')
PY

# deliver() isolates a poisoned line, marks it reported, and still sends once.
sent=0
export DRY_RUN=0
notify_maintainer_health() {
  sent=$((sent + 1))
  printf '%s\n' "$2" > "$AGENT_HOME/sent-body"
}
ledger="$AGENT_HOME/night/founder-health-mail.json"
maintainer_health_mail_ensure_ledger "$ledger" "$now"
maintainer_health_mail_deliver "$ledger" "$now" 20261108 '工厂日报 11-07：上线 2 个需求，有 1 件事等你' \
  "$golden_body
- 内部诊断：deploy STUCK detail=x=y" '[{"key":"fixture:change","created_at":1794067200}]'
assert_eq 'one owner report send' '1' "$sent"
assert_not_contains 'the poisoned line never reaches transport' "$(cat "$AGENT_HOME/sent-body")" 'detail=x=y'
assert_contains 'the readable report survives isolation' "$(cat "$AGENT_HOME/sent-body")" '订单导出'
maintainer_health_mail_output_contract "$(cat "$AGENT_HOME/sent-body")" "$now"
echo 'ALL PASS'
