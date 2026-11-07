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
body=$'一句话结论：做完 0 个、正式上线 0 个、等上线 0 个；没有告警。\n产出\n- 做完（已合入主线）：过去一天 0 个（前一天 0 个）；近 7 天 0 个。\n- 正式上线：过去一天 0 个（前一天 0 个）；近 7 天 0 个。\n需要你决定\n- 没有'
subject='工厂日报 11-07：做完 0 个、正式上线 0 个'
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
