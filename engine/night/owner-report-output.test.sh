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
mkdir -p "$home/night" "$home/metrics" "$home/logs" "$home/checkout/.scratch-supervisor/autopi"
maintainer_health_mail_ensure_ledger "$home/night/founder-health-mail.json" "$now"
: > "$home/logs/head-watch.alerts"
# No formal release for days: the release log ends well before the window.
printf '%s\n' '[2026-10-23T01:57:55Z] RELEASED sha=edb19d6e4 images=service' \
  > "$home/checkout/.scratch-supervisor/autopi/release-train.log"
# Merged work in the window is recorded as `merged` events; no `stage-entered awaiting-release` row exists.
cat > "$home/metrics/efficiency-2026-11.jsonl" <<'EOF'
{"record_type":"event","event_type":"merged","issue":900001,"pr_number":"7001","delivery_path":"product-release","ts":"2026-11-07T03:00:00Z"}
{"record_type":"event","event_type":"merged","issue":900002,"pr_number":"7002","delivery_path":"product-release","ts":"2026-11-07T04:00:00Z"}
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

[[ "$body" == *'- 做完（已合入主线）：过去一天 2 个'* ]] || fail 'finished work in the window is counted, not zero'
[[ "$body" == *'现在 3 个（比昨天多 2 个'* ]] || fail 'the stock growth is stated beside the finished count'
[[ "$body" == *'一句话结论：做完 2 个、正式上线 0 个、等上线 3 个；没有告警。'* ]] || fail 'the conclusion leads with finished, shipped and waiting'
[[ "$body" != *'已做完等上线：过去一天 0 个'* ]] || fail 'the false zero line is gone'
maintainer_health_mail_output_contract "$body" "$now" || fail 'the body meets the mail contract'
printf 'ok - merged work with a growing waiting stock never reads as zero\n'

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
