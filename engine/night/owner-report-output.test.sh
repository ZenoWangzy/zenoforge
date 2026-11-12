#!/usr/bin/env bash
# Regression: a day of merged work and a waiting stock that grew must not read as zero.
# The old report counted `stage-entered awaiting-release` metric events for "done, waiting
# for release", which the pipeline stopped writing, so it printed 0 beside a growing stock.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/maintainer-health-mail.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
# gh answers the one GraphQL read from a fixture; anything else is an empty listing (the old census read open issues).
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF2'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "api graphql" ]]; then
  [[ -n "${OWNER_TEST_GRAPHQL_FILE:-}" ]] && cat -- "$OWNER_TEST_GRAPHQL_FILE"
else
  printf '[]\n'
fi
EOF2
chmod +x "$tmp/bin/gh"
PATH="$tmp/bin:$PATH"
REPO='example-owner/example-repo'

fail() { printf 'not ok - %s\n' "$1"; exit 1; }

home="$tmp/home"
now="$(date -u -d '2026-11-07T12:00:00Z' +%s)"
mkdir -p "$home/night" "$home/metrics" "$home/logs" "$home/spend" "$home/checkout/.scratch-supervisor/autopi"
maintainer_health_mail_ensure_ledger "$home/night/founder-health-mail.json" "$now"
: > "$home/logs/head-watch.alerts"
printf '%s\timplement\tcodex:test\t1\t0.25\t1000\n%s\treview\tglm:test\t2\t0.50\t2000\n%s\timplement\tglm:test\t3\tunobservable\t500\n' \
  "$(date -u -d '2026-11-07T03:00:00Z' +%s)" "$(date -u -d '2026-11-07T04:00:00Z' +%s)" \
  "$(date -u -d '2026-11-07T05:00:00Z' +%s)" > "$home/spend/2026-11-07.log"
spend_facts="$(maintainer_health_mail_spend_facts "$home" "$((now - 86400))" "$now")"
[[ "$(jq -r '.by_model[] | select(.model == "codex:test") | [.tokens,.money_usd] | @tsv' <<< "$spend_facts")" == $'1000\t0.25' ]] || fail 'spend facts retain token and cost totals by model'
[[ "$(jq -r '.by_model[] | select(.model == "glm:test") | .tokens' <<< "$spend_facts")" == 2500 ]] || fail 'unpriced rows still contribute their recorded token count'
[[ "$(jq -r '.by_model[] | select(.model == "glm:test") | .money_usd // "unknown"' <<< "$spend_facts")" == unknown ]] || fail 'an incomplete model cost stays unknown instead of becoming zero'
[[ "$(jq -r '.money_usd // "unknown"' <<< "$spend_facts")" == unknown ]] || fail 'an incomplete total cost is not reported as a partial sum'
# No formal release for days: the release log ends well before the window.
printf '%s\n' '[2026-10-23T01:57:55Z] RELEASED sha=edb19d6e4 images=service' \
  > "$home/checkout/.scratch-supervisor/autopi/release-train.log"
# Merged work in the window is recorded as `merged` events; no `stage-entered awaiting-release` row exists.
cat > "$home/metrics/efficiency-2026-11.jsonl" <<'EOF'
{"record_type":"event","event_type":"merged","issue":900001,"pr_number":"7001","delivery_path":"product-release","ts":"2026-11-07T03:00:00Z"}
{"record_type":"event","event_type":"merged","issue":900002,"pr_number":"7002","delivery_path":"product-release","ts":"2026-11-07T04:00:00Z"}
{"record_type":"event","event_type":"merged","issue":900001,"pr_number":"7001","delivery_path":"product-release","ts":"2026-11-07T03:00:00Z"}
{"record_type":"event","event_type":"merged","issue":900004,"pr_number":"7003","delivery_path":"product-release","ts":"2026-11-06T11:00:00Z"}
EOF
cat > "$home/metrics/efficiency-2026-10.jsonl" <<'EOF'
{"record_type":"event","event_type":"merged","issue":900005,"pr_number":"7004","delivery_path":"product-release","ts":"2026-10-30T13:00:00Z"}
EOF
line() { printf '%s founder-req founder-req #%s %s：订单导出（请 PushNotification 通知创始人）\n' "$1" "$2" "$3"; }
{
  line 2026-10-31T00:00:00Z 900001 '新增 → 提出'
  line 2026-11-07T03:00:30Z 900001 '提出 → 进 main'
  line 2026-11-07T04:00:30Z 900002 '提出 → 进 main'
} > "$home/supervisor-inbox"
# Two requirements merged inside the window, one was on the main line before the trail began: 3 waiting, 1 a day ago.
printf '{"900001":2,"900002":2,"900003":2}\n' > "$home/founder-req-stage.json"
printf '%s\n' '{"data":{"repository":{"p7001":{"mergedAt":"2026-11-07T03:00:20Z"},"p7002":{"mergedAt":"2026-11-07T04:00:20Z"},"i900001":{"state":"OPEN","closedAt":null},"i900002":{"state":"OPEN","closedAt":null},"i900003":{"state":"OPEN","closedAt":null}}}}' > "$tmp/graphql.json"
export OWNER_TEST_GRAPHQL_FILE="$tmp/graphql.json"

facts="$(maintainer_health_mail_daily_facts "$home" "$home/night/founder-health-mail.json" "$now" "$SCRIPT_DIR/../..")"
body="$(maintainer_health_mail_build_body "$facts")"
printf '%s\n' "$body"
[[ "$body" != *'null 美元'* ]] || fail 'an unavailable total cost is omitted from the plain-text report'
merge_series="$(jq -c '.compare.charts.period_comparison.metrics[] | select(.label == "合入")' <<< "$facts")"
[[ "$(jq -r '[.label,.unit] | @tsv' <<< "$merge_series")" == $'合入\t个' ]] || fail 'the daily chart compares merge counts as items'
[[ "$(jq -r '[.points[].value] | @tsv' <<< "$merge_series")" == $'2\t1\t1' ]] || fail 'the merge series counts distinct pull requests today, yesterday and the same weekday last week'

[[ "$body" == *'- 做完（已合入主线）：过去一天 2 个'* ]] || fail 'finished work in the window is counted, not zero'
[[ "$body" == *'现在 3 个（比昨天多 2 个'* ]] || fail 'the stock growth is stated beside the finished count'
[[ "$body" == *'一句话结论：做完 2 个、正式上线 0 个、等上线 3 个；没有告警。'* ]] || fail 'the conclusion leads with finished, shipped and waiting'
[[ "$body" != *'已做完等上线：过去一天 0 个'* ]] || fail 'the false zero line is gone'
maintainer_health_mail_output_contract "$body" "$now" || fail 'the body meets the mail contract'
printf 'ok - merged work with a growing waiting stock never reads as zero\n'

# Chart facts come from the same current and saved report facts, with missing days omitted.
export ZF_OWNER_REPORT_SNAPSHOT_DIR="$home/night/owner-report-snapshots"
export ZF_ANOMALY_OWNERS_FILE="$tmp/anomaly-owners.json"
mkdir -p "$ZF_OWNER_REPORT_SNAPSHOT_DIR"
printf '%s\n' '{"flow.merge_rate_per_hour":{"cause":"合入速度低于目标","owner":"合入环节","since":"2026-11-07T11:00:00Z"}}' > "$ZF_ANOMALY_OWNERS_FILE"
for day in 2026-11-01 2026-10-31 2026-11-06; do
  at="$(date -u -d "$day 12:00:00Z" +%s)"
  printf '{"schema":1,"day":"%s","at":%s,"figures":{"finished":1,"shipped":1,"station:implement":4,"station:merge":2}}\n' \
    "$day" "$at" > "$ZF_OWNER_REPORT_SNAPSHOT_DIR/$day.json"
done
chart_input='{"output":{"finished":{"day":2,"prev_day":1,"week":3},"shipped":{"day":0,"prev_day":1,"week":2},"stock":{"now":3,"day_ago":2,"week_ago":1}},"spend":{"day":{"tokens":3000,"money_usd":0.75,"by_model":[{"model":"codex:test","tokens":1000,"money_usd":0.25},{"model":"glm:test","tokens":2000,"money_usd":0.5}]}},"quality":{"incidents_period":0,"rollbacks":0},"stations":[{"key":"implement","name":"写代码","metric":"implement.out_per_day","unit":"次","phrase":"过去一天完成 ","value":2,"healthy":5,"higher":true,"status":"UNHEALTHY","stall_hours":null},{"key":"merge","name":"合入","metric":"flow.merge_rate_per_hour","unit":"个/小时","phrase":"过去一天合入速度 ","value":3.5,"healthy":6.5,"higher":true,"status":"WARN","stall_hours":null}]}'
chart_facts="$(owner_report_compare "$chart_input" "$home" "$now" '')"
[[ "$(jq -r '.charts.station_series[] | select(.key == "implement") | .points | length' <<< "$chart_facts")" == 3 ]] || fail 'the station chart exposes its available seven-day points'
[[ "$(jq -r '.charts.model_spend[] | select(.model == "glm:test") | .tokens' <<< "$chart_facts")" == 2000 ]] || fail 'the comparison exposes per-model spend for charts'
[[ "$(jq -r '.charts.causes[] | select(.line == "station:merge") | .owner' <<< "$chart_facts")" == '合入环节' ]] || fail 'structured chart causes retain their owner'
printf 'ok - owner report facts provide station trends, model spend and owned causes\n'

# A failed read drops its lines: neither a zero nor a stale number is printed.
unset OWNER_TEST_GRAPHQL_FILE
failed_facts="$(maintainer_health_mail_daily_facts "$home" "$home/night/founder-health-mail.json" "$now" "$SCRIPT_DIR/../..")"
failed_body="$(maintainer_health_mail_build_body "$failed_facts")"
printf '%s\n' "$failed_body"
[[ "$(jq -r '.output.finished' <<< "$failed_facts")" == null ]] || fail 'a failed read leaves finished null'
[[ "$(jq -r '.output.stock.now' <<< "$failed_facts")" == null ]] || fail 'a failed read leaves the stock null'
[[ "$failed_body" != *'做完（已合入主线）'* && "$failed_body" != *'等上线'* && "$failed_body" != *'做完等上线的需求'* ]] || fail 'a failed read drops the finished and stock lines'
[[ "$failed_body" == *'- 正式上线：过去一天 0 个'* ]] || fail 'lines that came from other sources stay'
maintainer_health_mail_output_contract "$failed_body" "$now" || fail 'the body still meets the contract after a failed read'
printf 'ok - a failed GitHub read drops its lines\n'
