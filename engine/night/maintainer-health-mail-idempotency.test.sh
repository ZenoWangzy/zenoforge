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
body=$'一句话结论：正常——过去一天上线 0 个需求，没有线上事故，也没有待上线积压。\n\n今天上线了什么\n- 过去一天上线 0 个需求：没有新版本通过上线验证。\n\n进度\n- 新提出：过去一天 0 个；累计 0 个；目前在办共 0 个。\n- 已做完等上线：过去一天 0 个；当前共 0 个。\n- 已上线：过去一天 0 个；有记录以来共 0 个。\n\n效率\n- 近 7 天平均每天上线 0 个需求；上一个 7 天 0 个。\n- 需求从提出到上线：近 7 天中位无样本；上一个 7 天无样本。\n- 近 7 天工作时间：需求与工厂自身维护占比未测量。\n\n花费\n- 过去一天令牌用量未测量。\n- 金额没有完整记录，无法算出总花费。\n\n质量\n- 线上事故：过去一天 0 起；目前仍在处理 0 起。\n- 回滚：过去一天 0 次。\n- 已上线需求后来再出问题并返修：过去一天 0 起。\n\n需要你决定\n- 没有'
subject='工厂日报 11-07：上线 0 个需求，有 0 件事等你'
deliver() {
  maintainer_health_mail_deliver "$ledger" "$now" "$slot" "$subject" "$body" "$events"
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
assert_one_send 'cold-start initializer cannot erase a completed daily send'

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
assert_one_send 'two concurrent invocations and a same-day retry send once'
[[ "$(grep -c $'\tresult=attempted' "$NOTIFY_LOG_FILE")" -eq 1 ]] || {
  echo 'not ok - pre-send audit must say attempted, distinct from sent'; exit 1;
}
echo 'ok - one attempted audit and one sent audit describe one Gmail POST'
