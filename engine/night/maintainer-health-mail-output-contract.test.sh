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
tracker_fixture_id="$(printf '%s' "$TMPDIR/output-contract-tracker" | cksum | awk '{print 100000 + ($1 % 800000)}')"
mkdir -p "$AGENT_HOME/night" "$AGENT_HOME/metrics"

golden_body='一句话结论：做完 2 个、正式上线 1 个、等上线 3 个；没有告警。
需要你决定
- 库存预警阈值调到多少？——建议：先按默认值运行一周。
产出
- 做完（已合入主线）：过去一天 2 个（比昨天多 1 个，比上周同日少 1 个）；近 7 天 4 个（上一个 7 天 3 个）。
- 正式上线：过去一天 1 个（比昨天多 1 个）；近 7 天 1 个（上一个 7 天 0 个）。距上次上线 5 天。
变化
- 做完等上线的需求（未关闭）：现在 3 个（比昨天多 1 个，比上周同日多 3 个）。
质量
- 线上告警：过去一天 0 次，共 0 类。
- 撤回上线：过去一天 0 次。
资源
- 令牌用量：过去一天 1500（比昨天多 500）。'

maintainer_health_mail_output_contract "$golden_body" "$now"
echo 'ok - golden owner report passes the contract'

contract_rejects 'an empty body is refused' '' 'empty-body'
contract_rejects 'a missing conclusion line is refused' "$(tail -n +2 <<< "$golden_body")" 'conclusion'
contract_rejects 'a conclusion without a sentence is refused' \
  "${golden_body/一句话结论：做完 2 个、正式上线 1 个、等上线 3 个；没有告警。/一句话结论：}" 'conclusion'
contract_rejects 'a missing section is refused' "$(grep -v '^产出$' <<< "$golden_body")" 'missing-section'
contract_rejects 'a reordered section is refused' \
  "$(grep -v '^产出$' <<< "$golden_body" | sed 's/^质量$/产出\n质量/')" 'section-order'
contract_rejects 'an empty section is refused' \
  "$(grep -v '^- 令牌用量' <<< "$golden_body")" 'empty-section'
contract_rejects 'four decision lines are refused' \
  "${golden_body/先按默认值运行一周。/先按默认值运行一周。$'\n- 第二个问题——建议：按默认继续。\n- 第三个问题——建议：按默认继续。\n- 第四个问题——建议：按默认继续。'}" 'decision-limit'
filler_lines="$(printf -- '- 额外记录\n%.0s' {1..30})"
too_many_lines="${golden_body/需要你决定/$filler_lines$'\n需要你决定'}"
contract_rejects 'a report taller than one screen is refused' "$too_many_lines" 'one-screen'
contract_rejects 'an English word is refused' "$golden_body
- Channel Gateway 审批与飞书通知" 'ascii-text'
contract_rejects 'a tracker id is refused' "$golden_body
- 事项 #${tracker_fixture_id} 已上线" 'issue-id'
contract_rejects 'an epoch-derived date is refused' "${golden_body/一句话结论：做完/一句话结论：自1月1日起做完}" 'epoch-date'
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
assert_contains 'isolation keeps the readable neighbour' "$cleaned" '做完（已合入主线）'
maintainer_health_mail_output_contract "$cleaned" "$now"
echo 'ok - isolated report still passes the contract'

# The rendered HTML leads with the verdict and anomaly table, and only embeds charts
# backed by numeric compare facts. These assertions fail if the structured renderer is absent.
html_facts='{"report_day":"11-07","window":{"end":1794052800},"conclusion":{"reason":"做完 2 个、正式上线 1 个、等上线 3 个；没有告警"},"compare":{"charts":{"anomalies":[{"label":"合入","value":3.5,"standard":6.5,"unit":"个/小时","owner":"合入环节","cause":"原因未查明"}],"station_standards":[{"key":"merge","name":"合入","value":3.5,"healthy":6.5,"higher":true,"unit":"个/小时","status":"WARN"}],"period_comparison":{"periods":[{"key":"today","label":"今天"},{"key":"yesterday","label":"昨天"},{"key":"last_week","label":"上周同日"}],"metrics":[{"label":"合入","unit":"个","points":[{"period":"today","value":3},{"period":"yesterday","value":2},{"period":"last_week","value":4}]},{"label":"做完","unit":"个","points":[{"period":"today","value":2},{"period":"yesterday","value":1},{"period":"last_week","value":3}]},{"label":"正式上线","unit":"个","points":[{"period":"today","value":1},{"period":"yesterday","value":0},{"period":"last_week","value":2}]}]},"station_series":[{"key":"merge","name":"合入","unit":"个/小时","healthy":6.5,"higher":true,"points":[{"day":"2026-11-01","value":2},{"day":"2026-11-06","value":4},{"day":"2026-11-07","value":3.5}]}],"model_spend":[{"model":"codex:test","tokens":1000,"money_usd":0.25},{"model":"glm:test","tokens":2000,"money_usd":0.5}],"causes":[{"line":"station:merge","label":"合入","owner":"合入环节","cause":"原因未查明"}]}}}'
if ! declare -F maintainer_health_mail_build_html >/dev/null; then
  echo 'not ok - the owner report has a structured HTML renderer' >&2
  exit 1
fi
rendered="$(maintainer_health_mail_build_html "$html_facts" "$golden_body")"
html="$(jq -r '.html' <<< "$rendered")"
assert_contains 'HTML starts with the verdict' "$html" '一句话结论'
assert_contains 'the anomaly table names its five columns' "$html" '项目'
assert_contains 'the anomaly table includes its current value' "$html" '现值'
assert_contains 'the anomaly table includes the standard, owner and cause' "$html" '标准'
assert_contains 'the anomaly table includes an owner column' "$html" '负责人'
assert_contains 'the anomaly table includes a cause column' "$html" '原因'
assert_contains 'the anomaly row uses its compare fact value' "$html" '3.5 个/小时'
assert_contains 'the anomaly row uses its compare fact standard' "$html" '6.5 个/小时'
assert_contains 'the model table uses the named model fact' "$html" 'codex:test'
assert_contains 'the model table uses its token fact' "$html" '1000'
assert_contains 'the model table uses its cost fact' "$html" '0.25'
assert_contains 'the daily chart explains its period colors' "$html" '蓝色为今天，绿色为昨天，橙色为上周同日'
python3 - "$html" <<'PY'
from html.parser import HTMLParser
import sys

class Tables(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tables, self.table, self.row, self.cell = [], None, None, None
    def handle_starttag(self, tag, attrs):
        if tag == "table":
            self.table = []
        elif self.table is not None and tag == "tr":
            self.row = []
        elif self.row is not None and tag in ("th", "td"):
            self.cell = ""
    def handle_data(self, data):
        if self.cell is not None:
            self.cell += data
    def handle_endtag(self, tag):
        if tag in ("th", "td") and self.cell is not None:
            self.row.append(self.cell.strip())
            self.cell = None
        elif tag == "tr" and self.row is not None:
            self.table.append(self.row)
            self.row = None
        elif tag == "table" and self.table is not None:
            self.tables.append(self.table)
            self.table = None

tables = Tables()
tables.feed(sys.argv[1])
comparison = next((table for table in tables.tables
                   if table and table[0] == ["项目", "今天", "昨天", "上周同日"]), None)
assert comparison is not None and ["合入", "3", "2", "4"] in comparison
print("ok - the daily comparison shows merge counts for the three periods")
PY
assert_not_contains 'the daily comparison does not label a rate as a merge count' "$html" '合入速度'
assert_contains 'the model chart explains its two measures' "$html" '蓝色为令牌用量，橙色为调用金额'
if python3 -c 'import sys; s=sys.argv[1]; assert s.index("一句话结论") < s.index("<h2>异常情况</h2>") < s.index("<table")' "$html"; then
  echo 'ok - the verdict precedes the anomaly table'
else
  echo 'not ok - the verdict precedes the anomaly table' >&2
  exit 1
fi
assert_contains 'the station chart uses an inline CID' "$html" 'cid:owner-station-standard'
assert_contains 'the daily comparison chart uses an inline CID' "$html" 'cid:owner-daily-comparison'
assert_contains 'the seven-day chart uses an inline CID' "$html" 'cid:owner-station-trend'
assert_contains 'the model spend chart uses an inline CID' "$html" 'cid:owner-model-spend'
assert_contains 'untraced causes are stated without a guess' "$html" '原因未查明'
assert_eq 'all four chart images are attached' '4' "$(jq '.images | length' <<< "$rendered")"
empty_render="$(maintainer_health_mail_build_html '{"conclusion":{"reason":"产出记录读取失败"},"compare":{"charts":{}}}' '一句话结论：产出记录读取失败。')"
assert_eq 'unread chart sources do not produce placeholder images' '0' "$(jq '.images | length' <<< "$empty_render")"
unpriced_render="$(maintainer_health_mail_build_html '{"conclusion":{"reason":"产出记录读取失败"},"compare":{"charts":{"model_spend":[{"model":"glm:test","tokens":2000}]}}}' '一句话结论：产出记录读取失败。')"
unpriced_html="$(jq -r '.html' <<< "$unpriced_render")"
assert_contains 'an unpriced model still has a token chart' "$unpriced_html" 'glm:test'
assert_not_contains 'an unknown model cost is not rendered as zero' "$unpriced_html" '0.00'
assert_eq 'known tokens still produce a model chart when its cost is unreadable' '1' "$(jq '.images | length' <<< "$unpriced_render")"
python3 - "$unpriced_render" <<'PY'
import base64
import json
import struct
import sys
import zlib

images = json.loads(sys.argv[1])["images"]
png = base64.b64decode(next(image["data"] for image in images if image["cid"] == "owner-model-spend"))
offset, compressed = 8, bytearray()
while offset < len(png):
    size = struct.unpack(">I", png[offset:offset + 4])[0]
    kind = png[offset + 4:offset + 8]
    data = png[offset + 8:offset + 8 + size]
    if kind == b"IHDR":
        width, height = struct.unpack(">II", data[:8])
    elif kind == b"IDAT":
        compressed.extend(data)
    offset += size + 12
pixels = zlib.decompress(compressed)
stride = width * 3
orange = bytes((225, 145, 35))
assert all(all(row[x:x + 3] != orange for x in range(0, stride, 3))
           for y in range(height)
           for row in [pixels[y * (stride + 1) + 1:y * (stride + 1) + 1 + stride]])
print("ok - unreadable model cost has no orange zero-value bar")
PY

# The shared pre-send gate accepts the same report through the strict sender.
source "$SCRIPT_DIR/../notify.sh"
unknown_decision_body="${golden_body/- 库存预警阈值调到多少？——建议：先按默认值运行一周。/- 决定记录读取失败，本期无法列出。}"
maintainer_health_mail_output_contract "$unknown_decision_body" "$now"
assert_eq 'notify gate accepts decisions stated as unreadable' '' \
  "$(maintainer_mail_rejection_reason health '工厂日报 11-07：做完 2 个、正式上线 1 个' "$unknown_decision_body")"
body_with_env="${golden_body/需要你决定/$'ZF_HOME\n需要你决定'}"
body_with_path="${golden_body/需要你决定/$'\$HOME/private.log\n需要你决定'}"
body_with_sha="${golden_body/需要你决定/$'版本：b454fd00fa\n需要你决定'}"
assert_eq 'notify gate accepts the golden owner report' '' \
  "$(maintainer_mail_rejection_reason health '工厂日报 11-07：上线 2 个需求，有 1 件事等你' "$golden_body")"
assert_eq 'notify gate refuses a foreign subject' 'health-subject' \
  "$(maintainer_mail_rejection_reason health '工作进展简报' "$golden_body")"
assert_eq 'notify gate refuses a subject without a headline' 'health-subject' \
  "$(maintainer_mail_rejection_reason health '工厂日报 11-07' "$golden_body")"
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
assert_contains 'the readable report survives isolation' "$(cat "$AGENT_HOME/sent-body")" '做完（已合入主线）'
maintainer_health_mail_output_contract "$(cat "$AGENT_HOME/sent-body")" "$now"
echo 'ALL PASS'
