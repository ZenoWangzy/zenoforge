#!/usr/bin/env bash
# Fixture transport only: exercise the real digest claim and send audit.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture_root="$(mktemp -d)"
trap 'rm -rf -- "$fixture_root"' EXIT
export AGENT_HOME="$fixture_root/home" DRY_RUN=0
mkdir -p "$AGENT_HOME/night"
source "$SCRIPT_DIR/../notify.sh"
agent_epoch() { date +%s; }
source "$SCRIPT_DIR/maintainer-health-mail.sh"
cat > "$fixture_root/gcloud" <<'GCLOUD'
#!/usr/bin/env bash
printf 'fixture-token'
GCLOUD
chmod +x "$fixture_root/gcloud"
export ZF_GCLOUD_BIN="$fixture_root/gcloud"
_maintainer_email() { printf 'maintainer@fixture.invalid\n'; }
gmail_curl() {
  printf 'POST\n' >> "$fixture_root/posts"
  printf '{"id":"fixture-message","threadId":"fixture-thread"}\n200'
}
ledger="$AGENT_HOME/night/founder-health-mail.json"
now=1791803400
slot="$(maintainer_health_mail_slot_key "$now")"
events='[{"key":"fixture:change","created_at":1791803400}]'
body=$'**结论：** 本次有 1 项新变化。\n时间均为协调世界时。\n\n**效率（最近六小时）**\n| 指标 | 当前六小时 | 前六小时 | 昨日同时段 |\n| --- | ---: | ---: | ---: |\n| 调度一轮耗时 | 样本待补 | 样本待补 | 样本待补 |\n| 自动检查浪费占比 | 样本待补 | 样本待补 | 样本待补 |\n| 主干检查通过率 | 样本待补 | 样本待补 | 样本待补 |\n| 上线后复核有效率 | 样本待补 | 样本待补 | 样本待补 |\n| 派活失败次数 | 样本待补 | 样本待补 | 样本待补 |\n| 重复派活 | 样本待补 | 样本待补 | 样本待补 |\n| 提交失败次数 | 样本待补 | 样本待补 | 样本待补 |\n| 系统自动开单 / 关单 | 样本待补 | 样本待补 | 样本待补 |\n\n**上线情况：**\n最近六小时没有上线：没有新版本通过上线验证。\n\n**事项变化**\n订单页面已恢复。'
deliver() {
  maintainer_health_mail_deliver "$ledger" "$now" "$slot" '工作进展简报' "$body" "$events"
}
assert_one_send() {
  [[ "$(wc -l < "$fixture_root/posts")" -eq 1 ]] || {
    echo "not ok - $1: $(wc -l < "$fixture_root/posts") Gmail POSTs"; exit 1;
  }
  [[ "$(grep -c $'\tresult=sent' "$NOTIFY_LOG_FILE")" -eq 1 ]]
  echo "ok - $1"
}

# Pause a cold-start initializer after its existence check. Another worker
# creates the ledger and sends before the paused initializer publishes.
mkfifo "$fixture_root/ready" "$fixture_root/release"
exec {ready_fd}<>"$fixture_root/ready"
exec {release_fd}<>"$fixture_root/release"
(
  mktemp() {
    command mktemp "$@"
    printf 'ready\n' >&"$ready_fd"
    IFS= read -r -t 10 -u "$release_fd"
  }
  maintainer_health_mail_ensure_ledger "$ledger" "$now"
  unset -f mktemp
  deliver
) &
initializer_pid=$!
IFS= read -r -t 10 -u "$ready_fd"
maintainer_health_mail_ensure_ledger "$ledger" "$now"
deliver
printf 'release\n' >&"$release_fd"
wait "$initializer_pid"
exec {ready_fd}>&-
exec {release_fd}>&-
assert_one_send 'cold-start initializer cannot erase a completed six-hour send'

# Same-slot concurrent workers plus a later retry share the durable claim.
rm -f -- "$ledger" "$fixture_root/posts" "$NOTIFY_LOG_FILE"
maintainer_health_mail_ensure_ledger "$ledger" "$now"
deliver &
first_pid=$!
deliver &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
deliver
assert_one_send 'two concurrent invocations and a same-hour retry send once'
[[ "$(grep -c $'\tresult=attempted' "$NOTIFY_LOG_FILE")" -eq 1 ]] || {
  echo 'not ok - pre-send audit must say attempted, distinct from sent'; exit 1;
}
echo 'ok - one attempted audit and one sent audit describe one Gmail POST'
