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
# The old census read open issues through gh; an empty listing lets it print its stock.
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nprintf "[]\\n"\n' > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
PATH="$tmp/bin:$PATH"
post_land_mttr_summary() { jq -cn '{summary:{count:0},bounds:{meaning:""}}'; }

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
{"record_type":"event","event_type":"merged","issue":900001,"pr_number":"1","delivery_path":"product-release","ts":"2026-11-07T03:00:00Z"}
{"record_type":"event","event_type":"merged","issue":900002,"pr_number":"2","delivery_path":"product-release","ts":"2026-11-07T04:00:00Z"}
EOF
line() { printf '%s founder-req founder-req #%s %s：订单导出（请 PushNotification 通知创始人）\n' "$1" "$2" "$3"; }
{
  line 2026-10-31T00:00:00Z 900001 '新增 → 提出'
  line 2026-11-07T03:00:30Z 900001 '提出 → 进 main'
  line 2026-11-07T04:00:30Z 900002 '提出 → 进 main'
} > "$home/supervisor-inbox"
# Two requirements held at the main line since the window began, one before it: 3 waiting, 1 a day ago.
printf '{"900001":2,"900002":2,"900003":2}\n' > "$home/founder-req-stage.json"

facts="$(maintainer_health_mail_daily_facts "$home" "$home/night/founder-health-mail.json" "$now" "$SCRIPT_DIR/../..")"
body="$(maintainer_health_mail_build_body "$facts")"
printf '%s\n' "$body"

[[ "$body" == *'- 做完（已合入主线）：过去一天 2 个'* ]] || fail 'finished work in the window is counted, not zero'
[[ "$body" == *'现在 3 个，比一天前多 2 个'* ]] || fail 'the stock growth is stated beside the finished count'
[[ "$body" == *'有风险——过去一天做完 2 个需求、上线 0 个，等上线的需求从 1 个涨到 3 个'* ]] || fail 'finished but unshipped work is flagged as a pile-up'
[[ "$body" != *'已做完等上线：过去一天 0 个'* ]] || fail 'the false zero line is gone'
maintainer_health_mail_output_contract "$body" "$now" || fail 'the body meets the mail contract'
printf 'ok - merged work with a growing waiting stock never reads as zero\n'
