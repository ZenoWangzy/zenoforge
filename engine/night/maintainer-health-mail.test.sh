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
if [[ "${1:-} ${2:-}" == "api graphql" ]]; then
  [ -z "${MAINTAINER_TEST_GRAPHQL_FILE:-}" ] || cat -- "$MAINTAINER_TEST_GRAPHQL_FILE"
elif [[ " $* " == *" --label ready-for-agent "* ]] && [ -n "${MAINTAINER_TEST_READY_QUEUE_FILE:-}" ]; then
  cat -- "$MAINTAINER_TEST_READY_QUEUE_FILE"
elif [[ " $* " == *" --state open "* ]] && [ -n "${MAINTAINER_TEST_OPEN_FILE:-}" ]; then
  cat -- "$MAINTAINER_TEST_OPEN_FILE"
else
  printf '[]\n'
fi
EOF2
chmod +x "$test_bin/systemctl" "$test_bin/gh"
PATH="$test_bin:$PATH"
export PATH
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

# A fixture home on the founder ladder: three requirements merge inside the day
# (one of them ships), one the day before, one earlier in the week and is then
# closed; a release log, spend rows of both meters, and a calm ledger.
facts_home="$tmp/facts"
facts_now="$(date -u -d '2026-11-07T16:00:00Z' +%s)"
REPO='example-owner/example-repo'
mkdir -p "$facts_home/night" "$facts_home/state" "$facts_home/metrics" "$facts_home/spend" \
  "$facts_home/checkout/.scratch-supervisor/autopi" "$facts_home/logs"
maintainer_health_mail_ensure_ledger "$facts_home/night/founder-health-mail.json" "$facts_now"
fixture_issue_seed="$(printf '%s' "$facts_home" | cksum | awk '{print 100000 + ($1 % 800000)}')"
fixture_issue_shipped="$fixture_issue_seed"
fixture_issue_waiting="$((fixture_issue_seed + 1))"
fixture_issue_prev_day="$((fixture_issue_seed + 2))"
fixture_issue_late="$((fixture_issue_seed + 3))"
fixture_issue_closed="$((fixture_issue_seed + 4))"
fixture_issue_new="$((fixture_issue_seed + 5))"
# The release train log is stale on purpose (a hand release leaves it behind) and is not read; the
# last deploy comes from the Deployment read, stubbed here. The head-watch log holds the alerts.
printf '%s\n' '[2026-10-23T01:57:55Z] RELEASED sha=edb19d6e4 images=admin-console' \
  '[2026-11-02T06:30:00Z] RELEASED sha=123456789 images=fleet-gateway' \
  > "$facts_home/checkout/.scratch-supervisor/autopi/release-train.log"
: > "$facts_home/logs/head-watch.alerts"
{
  ladder_line() { printf '%s founder-req founder-req #%s %s：订单导出（请 PushNotification 通知创始人）\n' "$1" "$2" "$3"; }
  ladder_line 2026-10-30T01:00:00Z "$fixture_issue_new" '新增 → 提出'
  ladder_line 2026-11-06T10:00:30Z "$fixture_issue_prev_day" '提出 → 进 main'
  ladder_line 2026-11-06T20:00:30Z "$fixture_issue_late" '提出 → 进 main'
  ladder_line 2026-11-07T02:00:30Z "$fixture_issue_shipped" '提出 → 进 main'
  ladder_line 2026-11-07T03:00:30Z "$fixture_issue_waiting" '提出 → 进 main'
  ladder_line 2026-11-07T06:30:00Z "$fixture_issue_shipped" '进 main → 上线'
  # The live inbox has lines cut inside a UTF-8 character; readers must skip them, not stop.
  printf '2026-11-03T09:00:00Z founder-req founder-req #%s 新增 → 提出：残缺\xe7\x9a\n' "$fixture_issue_late"
} > "$facts_home/supervisor-inbox"
jq -cn --argjson shipped "$fixture_issue_shipped" --argjson waiting "$fixture_issue_waiting" --argjson prev "$fixture_issue_prev_day" \
  --argjson late "$fixture_issue_late" --argjson closed "$fixture_issue_closed" --argjson new "$fixture_issue_new" \
  '{($shipped|tostring):3,($waiting|tostring):2,($prev|tostring):2,($late|tostring):2,($closed|tostring):2,($new|tostring):0}' \
  > "$facts_home/founder-req-stage.json"
# The pipeline's merged events name each delivering pull request; GitHub gives the merge time and the issue state.
for row in "$fixture_issue_shipped:11" "$fixture_issue_waiting:12" "$fixture_issue_prev_day:13" "$fixture_issue_late:14" "$fixture_issue_closed:15"; do
  printf '{"record_type":"event","event_type":"merged","issue":%s,"pr_number":"%s","ts":"2026-11-07T00:00:00Z"}\n' "${row%%:*}" "${row##*:}"
done > "$facts_home/metrics/efficiency-2026-11.jsonl"
jq -cn --argjson s "$fixture_issue_shipped" --argjson w "$fixture_issue_waiting" --argjson p "$fixture_issue_prev_day" \
  --argjson l "$fixture_issue_late" --argjson c "$fixture_issue_closed" '
  {data:{repository:{
    p11:{mergedAt:"2026-11-07T02:00:00Z"}, p12:{mergedAt:"2026-11-07T03:00:00Z"}, p13:{mergedAt:"2026-11-06T10:00:00Z"},
    p14:{mergedAt:"2026-11-06T20:00:00Z"}, p15:{mergedAt:"2026-11-02T10:00:00Z"},
    ("i\($s)"):{state:"OPEN",closedAt:null}, ("i\($w)"):{state:"OPEN",closedAt:null}, ("i\($p)"):{state:"OPEN",closedAt:null},
    ("i\($l)"):{state:"OPEN",closedAt:null}, ("i\($c)"):{state:"CLOSED",closedAt:"2026-11-07T08:00:00Z"}}}}' > "$tmp/graphql.json"
MAINTAINER_TEST_GRAPHQL_FILE="$tmp/graphql.json"
export MAINTAINER_TEST_GRAPHQL_FILE
# Token rows carry no price and priced rows carry no tokens: two meters.
{
  printf '%s\timplement\t模型\t%s\t\t12225851\n' "$(date -u -d '2026-11-07T13:50:00Z' +%s)" "$fixture_issue_shipped"
  printf '%s\tadvisor-batch\t顾问\t%s\t0.5\t\n' "$(date -u -d '2026-11-07T10:00:00Z' +%s)" "$fixture_issue_shipped"
} > "$facts_home/spend/2026-11-07.log"
printf '%s\timplement\t模型\t%s\t\t1000\n' "$(date -u -d '2026-11-06T10:00:00Z' +%s)" "$fixture_issue_shipped" > "$facts_home/spend/2026-11-06.log"
maintainer_health_mail_last_deploy() { date -u -d '2026-11-02T06:30:00Z' +%s; }
facts="$(maintainer_health_mail_daily_facts "$facts_home" "$facts_home/night/founder-health-mail.json" "$facts_now" "$SCRIPT_DIR/../..")"
assert_eq 'three requirements merged in the last day' '3' "$(jq -r '.output.finished.day' <<< "$facts")"
assert_eq 'the day before counts apart from the last day' '1' "$(jq -r '.output.finished.prev_day' <<< "$facts")"
assert_eq 'the week counts every requirement merged in it' '5' "$(jq -r '.output.finished.week' <<< "$facts")"
assert_eq 'a week before the trail began is not counted as zero' 'null' "$(jq -r '.output.finished.prev_week' <<< "$facts")"
assert_eq 'one requirement shipped in the last day' '1' "$(jq -r '.output.shipped.day' <<< "$facts")"
assert_eq 'the waiting stock counts open requirements held at the main line' '3' "$(jq -r '.output.stock.now' <<< "$facts")"
assert_eq 'the stock a day ago includes the issue closed since, and not the day merges' '2' "$(jq -r '.output.stock.day_ago' <<< "$facts")"
assert_eq 'the stock a week ago is what had merged before then' '0' "$(jq -r '.output.stock.week_ago' <<< "$facts")"
assert_eq 'last deploy is the Deployment time, not the stale RELEASED line' "$(date -u -d '2026-11-02T06:30:00Z' +%s)" "$(jq -r '.last_deploy_at' <<< "$facts")"
assert_eq 'token rows sum on their own meter' '12225851' "$(jq -r '.spend.day.tokens' <<< "$facts")"
assert_eq 'priced rows sum on their own meter' '0.5' "$(jq -r '.spend.day.money_usd' <<< "$facts")"
assert_eq 'the day before has its own spend' '1000' "$(jq -r '.spend.prev_day.tokens' <<< "$facts")"
assert_eq 'report day is the Beijing date' '11-08' "$(jq -r '.report_day' <<< "$facts")"
assert_eq 'the conclusion leads with output, then production' '做完 3 个、正式上线 1 个、等上线 3 个；没有告警' "$(jq -r '.conclusion.reason' <<< "$facts")"

facts_body="$(maintainer_health_mail_build_body "$facts")"
maintainer_health_mail_output_contract "$facts_body" "$facts_now"
assert_contains 'body leads with finished work against the previous periods' "$facts_body" '- 做完（已合入主线）：过去一天 3 个（比昨天多 2 个）；近 7 天 5 个。'
assert_contains 'body states what shipped and the days since the last deploy' "$facts_body" '- 正式上线：过去一天 1 个（比昨天多 1 个）；近 7 天 1 个。距上次上线 5 天。'
assert_contains 'body states how the waiting stock moved' "$facts_body" '现在 3 个（比昨天多 1 个，比上周同日多 3 个）。'
assert_contains 'body states tokens in ten-thousands against the day before' "$facts_body" '- 令牌用量：过去一天 1222.6 万（比昨天多 1222.5 万）。'
assert_contains 'body states priced calls apart from tokens' "$facts_body" '按美元计价的调用：过去一天 0.5 美元'
assert_contains 'body states no decisions wait' "$facts_body" '- 没有'
assert_not_contains 'body no longer reports post-merge fixes' "$facts_body" '返修'
for filler in 未测量 未核实 待核实 至少记录 未分类 未能核对 出事了; do
  assert_not_contains "body carries no $filler filler" "$facts_body" "$filler"
done
assert_contains 'subject counts finished and shipped requirements' "$(maintainer_health_mail_subject "$facts")" '工厂日报 11-08：做完 3 个、正式上线 1 个'
assert_not_contains 'subject drops the decision clause when nothing waits' "$(maintainer_health_mail_subject "$facts")" '件事等你'

# A failed GitHub read drops the lines that depend on it and prints no zero in their place.
unset MAINTAINER_TEST_GRAPHQL_FILE
failed_facts="$(maintainer_health_mail_daily_facts "$facts_home" "$facts_home/night/founder-health-mail.json" "$facts_now" "$SCRIPT_DIR/../..")"
failed_body="$(maintainer_health_mail_build_body "$failed_facts")"
maintainer_health_mail_output_contract "$failed_body" "$facts_now"
assert_eq 'a failed read leaves finished unread' 'null' "$(jq -r '.output.finished' <<< "$failed_facts")"
assert_eq 'a failed read leaves the stock unread' 'null' "$(jq -r '.output.stock.now' <<< "$failed_facts")"
assert_not_contains 'a failed read drops the finished line' "$failed_body" '做完（已合入主线）'
assert_not_contains 'a failed read drops the change section' "$failed_body" '等上线的需求'
assert_contains 'a failed read keeps the shipped line from the trail' "$failed_body" '- 正式上线：过去一天 1 个'
assert_contains 'a failed read keeps the conclusion to what was read' "$failed_body" '一句话结论：正式上线 1 个；没有告警。'
export MAINTAINER_TEST_GRAPHQL_FILE="$tmp/graphql.json"

# A failed Deployment read drops the age clause; the stale RELEASED line is never used as a fallback.
maintainer_health_mail_last_deploy() { :; }
no_deploy_facts="$(maintainer_health_mail_daily_facts "$facts_home" "$facts_home/night/founder-health-mail.json" "$facts_now" "$SCRIPT_DIR/../..")"
no_deploy_body="$(maintainer_health_mail_build_body "$no_deploy_facts")"
maintainer_health_mail_output_contract "$no_deploy_body" "$facts_now"
assert_eq 'a failed deploy read leaves the deploy time unread' 'null' "$(jq -r '.last_deploy_at' <<< "$no_deploy_facts")"
assert_not_contains 'a failed deploy read prints no age clause' "$no_deploy_body" '距上次'
assert_contains 'a failed deploy read keeps the shipped counts' "$no_deploy_body" '- 正式上线：过去一天 1 个（比昨天多 1 个）；近 7 天 1 个。'
maintainer_health_mail_last_deploy() { printf 'not a time\n'; }
assert_eq 'an unreadable deploy time is also dropped' 'null' "$(jq -r '.last_deploy_at' <<< "$(maintainer_health_mail_daily_facts "$facts_home" "$facts_home/night/founder-health-mail.json" "$facts_now" "$SCRIPT_DIR/../..")")"

# End to end through the release_age.py entry: GitHub Deployments served by a fake gh on PATH.
# The newest sha has a stale RELEASED line (2026-10-23 in the fixture trail) and a newer Deployment; the Deployment wins.
source "$SCRIPT_DIR/maintainer-health-mail.sh"
mkdir -p "$tmp/fakebin" "$tmp/gh"
cat > "$tmp/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[[ "${FAKE_GH_FAIL:-}" != 1 && "$1" == api ]] || exit 1
case "$2" in
  repos/*/deployments/*/statuses) id="${2#*/deployments/}"; cat "$FAKE_GH_DIR/status-${id%/statuses}.json" ;;
  repos/*/deployments\?*) cat "$FAKE_GH_DIR/deployments.json" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/fakebin/gh"
deploy_sha="$(printf 'a%.0s' {1..40})"
printf '[{"id":7,"sha":"%s","created_at":"2026-11-02T06:30:00Z","payload":{}}]\n' "$deploy_sha" > "$tmp/gh/deployments.json"
printf '[{"state":"success","created_at":"2026-11-02T06:31:00Z"}]\n' > "$tmp/gh/status-7.json"
e2e_repo="maintainer/example"
e2e_deploy="$(PATH="$tmp/fakebin:$PATH" FAKE_GH_DIR="$tmp/gh" ZF_REPO="$e2e_repo" RELEASE_TRAIN_REPO="$e2e_repo" maintainer_health_mail_last_deploy)"
assert_eq 'the CLI entry gives the Deployment time, not the stale RELEASED line' "$(date -u -d '2026-11-02T06:30:00Z' +%s)" "$e2e_deploy"
e2e_fail="$(PATH="$tmp/fakebin:$PATH" FAKE_GH_DIR="$tmp/gh" FAKE_GH_FAIL=1 ZF_REPO="$e2e_repo" RELEASE_TRAIN_REPO="$e2e_repo" maintainer_health_mail_last_deploy)"
assert_eq 'a failed Deployment read through the CLI entry prints nothing' '' "$e2e_fail"

# An empty home leaves every figure out instead of inventing one.
empty_home="$tmp/empty"
mkdir -p "$empty_home/night" "$empty_home/state"
printf '%s\n' 'not a ledger yet' > "$empty_home/night/founder-health-mail.json"
assert_eq 'an empty trail has no ladder facts' 'null' "$(maintainer_health_mail_ladder_facts "$empty_home" "$facts_now")"
empty_facts="$(maintainer_health_mail_daily_facts "$empty_home" "$empty_home/night/founder-health-mail.json" "$facts_now" "$SCRIPT_DIR/../..")"
empty_body="$(maintainer_health_mail_build_body "$empty_facts")"
maintainer_health_mail_output_contract "$empty_body" "$facts_now"
assert_contains 'empty home says the output cannot be counted' "$empty_body" '需求进度记录读取失败，产出无法统计'
assert_not_contains 'empty home prints no spend section' "$empty_body" '令牌'
assert_contains 'empty home says decisions could not be read' "$empty_body" '决定记录读取失败，本期无法列出'
assert_contains 'empty home subject names the unread output' "$(maintainer_health_mail_subject "$empty_facts")" '产出记录读取失败'

# Watch alerts less than 30 minutes apart are one production episode.
watch_home="$tmp/watch"
mkdir -p "$watch_home/logs"
printf '%s\n' '2026-11-07T06:00:00Z PROD-DB-TIMEOUT first' '2026-11-07T06:20:00Z PROD-DB-TIMEOUT same' \
  '2026-11-07T08:00:00Z PROD-DB-TIMEOUT later' > "$watch_home/logs/head-watch.alerts"
watch_start="$(date -u -d '2026-11-07T00:00:00Z' +%s)"
watch_end="$(date -u -d '2026-11-08T00:00:00Z' +%s)"
assert_eq 'two clusters of alerts make two episodes' '2' \
  "$(maintainer_health_mail_watch_episodes "$watch_home" "$watch_start" "$watch_end" "$(date -u -d '2026-11-07T09:00:00Z' +%s)" | jq -r '.period')"
assert_eq 'a pause in alerts is not counted as an episode alerting now' '0' \
  "$(maintainer_health_mail_watch_episodes "$watch_home" "$watch_start" "$watch_end" "$(date -u -d '2026-11-07T09:00:00Z' +%s)" | jq -r '.alerting')"
assert_eq 'the last alert age is whole hours' '1' \
  "$(maintainer_health_mail_watch_episodes "$watch_home" "$watch_start" "$watch_end" "$(date -u -d '2026-11-07T09:00:00Z' +%s)" | jq -r '.hours_since_last')"
assert_eq 'an episode alerting within 30 minutes is alerting' '1' \
  "$(maintainer_health_mail_watch_episodes "$watch_home" "$watch_start" "$watch_end" "$(date -u -d '2026-11-07T08:10:00Z' +%s)" | jq -r '.alerting')"

# Alerts with the same first word and the same message (digits aside) are one class.
class_home="$tmp/classes"
mkdir -p "$class_home/logs"
class_start="$(date -u -d '2026-11-07T00:00:00Z' +%s)"
class_end="$(date -u -d '2026-11-08T00:00:00Z' +%s)"
class_facts() { # prints the watch episodes then the classes the quality facts carry
  maintainer_health_mail_quality_facts "$facts_home/night/founder-health-mail.json" "$class_home" "$class_start" "$class_end" "$SCRIPT_DIR/../.." | jq -c '[.incidents_period, .alert_classes]'
}
printf '%s\n' '2026-11-07T06:00:00Z PROD-DB-TIMEOUT svc-a connection timed out count=6' \
  '2026-11-07T08:00:00Z PROD-DB-TIMEOUT svc-a connection timed out count=14' > "$class_home/logs/head-watch.alerts"
assert_eq 'two alerts with one signature are 2 times in 1 class' '[2,1]' "$(class_facts)"
printf '%s\n' '2026-11-07T10:00:00Z PROD-DB-TIMEOUT svc-b connection timed out count=3' >> "$class_home/logs/head-watch.alerts"
assert_eq 'a different first word makes a second class' '[3,2]' "$(class_facts)"
printf '%s\n' '2026-11-07T12:00:00Z PROD-DB-TIMEOUT svc-a pool exhausted count=3' >> "$class_home/logs/head-watch.alerts"
assert_eq 'a different message makes a third class' '[4,3]' "$(class_facts)"
printf '%s\n' '2026-11-07T14:00:00Z PROD-DB-TIMEOUT' >> "$class_home/logs/head-watch.alerts"
assert_eq 'an alert with no readable signature leaves the class count unread' '[5,null]' "$(class_facts)"
class_body() { # <times> <classes|null>
  maintainer_health_mail_build_body "$(jq -c --argjson n "$1" --argjson k "$2" '.quality.incidents_period=$n | .quality.alert_classes=$k' <<< "$facts")"
}
assert_contains 'two signatures print 共 2 类' "$(class_body 8 2)" '- 线上告警：过去一天 8 次，共 2 类。'
assert_contains 'one signature prints 共 1 类' "$(class_body 8 1)" '- 线上告警：过去一天 8 次，共 1 类。'
assert_not_contains 'an unread class count drops the class part' "$(class_body 8 null)" '共'
assert_contains 'the conclusion names the alert count' "$(maintainer_health_mail_conclusion_facts "$(jq -c '.output' <<< "$facts")" '{"incidents_period":8}')" '；8 次告警'
for word in 事故 起; do
  assert_not_contains "the alert body never says $word" "$(class_body 8 2)" "$word"
done

# The conclusion escalates: open incident beats risk beats normal.
conclusion_home="$tmp/conclusion"
mkdir -p "$conclusion_home/night"
conclusion_ledger="$conclusion_home/night/founder-health-mail.json"
fixture_incident_issue=$((fixture_issue_seed + 10))
maintainer_health_mail_ensure_ledger "$conclusion_ledger" 1000
maintainer_health_mail_incident_open "$conclusion_ledger" "$fixture_incident_issue" '线上服务中断' '服务中断。' \
  '用户暂时无法使用。' '正在恢复服务。' "$facts_now" "$((facts_now - 3600))" 1 >/dev/null
mkdir -p "$conclusion_home/logs"
: > "$conclusion_home/logs/head-watch.alerts"
open_facts="$(maintainer_health_mail_daily_facts "$conclusion_home" "$conclusion_ledger" "$facts_now" "$SCRIPT_DIR/../..")"
assert_contains 'an outage in the ledger is the alert clause after output' "$(jq -r '.conclusion.reason' <<< "$open_facts")" '1 次告警'
assert_contains 'quality section counts the alerts but cannot class a ledger incident' \
  "$(maintainer_health_mail_build_body "$open_facts")" '- 线上告警：过去一天 1 次。'
assert_contains 'subject still names the report during an outage' \
  "$(maintainer_health_mail_subject "$open_facts")" '工厂日报'

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
assert_eq 'decision lines are capped at three' '3' "$(sed -n '/^需要你决定$/,/^产出$/p' <<< "$decision_body" | grep -c '^- ')"
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
cadence_day1="$(date -u -d '2026-11-07T01:10:00Z' +%s)"
cadence_day1_late="$((cadence_day1 + 1200))"
cadence_day2="$(date -u -d '2026-11-08T01:10:00Z' +%s)"
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
{"report_day":"11-07","conclusion":{"reason":"做完 0 个、正式上线 0 个、等上线 0 个；没有告警"},"window":{"end":1793683200},"output":{"finished":{"day":0,"prev_day":0,"week":0,"prev_week":null},"shipped":{"day":0,"prev_day":0,"week":0,"prev_week":null},"stock":{"now":0,"day_ago":0,"week_ago":null}},"last_deploy_at":null,"spend":{"day":null,"prev_day":null},"quality":{"incidents_period":0,"incidents_open":0,"open_subjects":[],"rollbacks":0},"decisions":{"items":[],"total":0,"incomplete":0}}
FIX
maintainer_health_mail_output_contract "$(maintainer_health_mail_build_body "$(cat "$retry_facts_file")")" 1793683200
(
  maintainer_health_mail_daily_facts() {
    printf 'built\n' >> "$retry_home/builds"
    if [ "$(wc -l < "$retry_home/builds")" -eq 1 ]; then return 1; fi
    cat "$retry_facts_file"
  }
  retry_now="$(date -u -d '2026-11-07T01:05:00Z' +%s)"
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
  retry_now="$(date -u -d '2026-11-07T01:05:00Z' +%s)"
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
  retry_now="$(date -u -d '2026-11-07T01:05:00Z' +%s)"
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

# A recurrence that exists only as a fragment beside the registry file is counted, by the resolved path and by the override file.
printf '{"incidents":[]}\n' > "$incident_config"
mkdir -p "${incident_config%.json}.d"
printf '{"incidents":[{"id":"fragment-recurrence","date":"2026-09-29","recurs_of":"root","class":"fragment-class"}]}\n' \
  > "${incident_config%.json}.d/fragment-recurrence.json"
fragment_metric="$(ZF_REPO_DIR="$tmp/config" ZF_CONFIG_ROOT="$tmp/config/.zenoforge" \
  ZF_ENGINE_DIR="$SCRIPT_DIR/.." maintainer_health_mail_measure \
    "$metric_home" '2026-09-29' "$metric_now" "$action_repo")"
override_metric="$(AGENT_INCIDENT_GUARDS_FILE="$incident_config" ZF_ENGINE_DIR="$SCRIPT_DIR/.." \
  maintainer_health_mail_measure "$metric_home" '2026-09-29' "$metric_now" "$action_repo")"
for fragment_json in "$fragment_metric" "$override_metric"; do
  jq -e '.recurrences_day == 1 and .recurrence_categories == ["fragment-class"]' <<< "$fragment_json" >/dev/null || {
    echo "not ok - health measure did not read a fragment-only incident guard: $fragment_json" >&2
    exit 1
  }
done
echo 'ok - health measure reads fragment-only incident guards'
echo 'ALL PASS'
