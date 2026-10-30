#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
tmp="$(mktemp -d)"
wrapper_pid=""
codex_pid=""
codex_sleep_pid=""
terminal_pid=""
terminal_sleep_pid=""
stale_pid=""
stale_sleep_pid=""
zcode_pid=""
churn_pid=""
churn_sleep_pid=""
budget_warn_pid=""
budget_warn_sleep_pid=""
budget_stop_pid=""
budget_stop_sleep_pid=""
budget_override_pid=""
budget_override_sleep_pid=""
cleanup() {
  for pid in "$budget_override_pid" "$budget_override_sleep_pid" "$budget_stop_pid" "$budget_stop_sleep_pid" \
    "$budget_warn_pid" "$budget_warn_sleep_pid" "$churn_pid" "$churn_sleep_pid" \
    "$zcode_pid" "$terminal_sleep_pid" "$terminal_pid" "$stale_sleep_pid" "$stale_pid" \
    "$codex_sleep_pid" "$codex_pid" "$wrapper_pid"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf -- "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/bin" "$tmp/home/night" "$tmp/home/spend"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/bin/gh"
PATH="$tmp/bin:$PATH"
export PATH CODEX_HOME="$tmp/codex"
H="$tmp/home"
NIGHT="$tmp/home/night"
ZF_AGENT_SPIN_THRESHOLD_SECONDS=2
source "$SCRIPT_DIR/hand-agent-watchdog.sh"

mkfifo "$tmp/control"
cat >"$tmp/wrapper.sh" <<'EOF'
#!/usr/bin/env bash
IFS= read -r _ < "$1"
bash -c 'printf codex > /proc/self/comm; sleep 300 & echo "$!" > "$2"; wait "$!"' _ "$2" "$3" &
echo "$!" > "$2"
wait
EOF
chmod +x "$tmp/wrapper.sh"
"$tmp/wrapper.sh" "$tmp/control" "$tmp/codex.pid" "$tmp/codex-sleep.pid" \
  >"$tmp/wrapper.log" 2>&1 &
wrapper_pid=$!

write_spend() {
  local tokens="$1" at="$2" issue="${3:-1999}" day previous_day
  day="$(date -u -d "@$at" +%F)"
  previous_day="$(date -u -d "@$((at - 86400))" +%F)"
  touch "$H/spend/$day.log" "$H/spend/$previous_day.log"
  printf '%s\tfixture\tcodex:test\t%s\tfixture\t%s\n' "$at" "$issue" "$tokens" >>"$H/spend/$day.log"
}

start_fake_codex() {
  local pid_file="$1"
  bash -c 'printf codex > /proc/self/comm; sleep 300 & echo "$!" > "$1"; wait "$!"' _ "$pid_file" \
    >/dev/null 2>&1 &
  FAKE_CODEX_PID=$!
  for _ in {1..3000}; do
    [[ "$(cat "/proc/$FAKE_CODEX_PID/comm" 2>/dev/null || true)" == codex && -s "$pid_file" ]] && break
    sleep 0.01
  done
  FAKE_CODEX_SLEEP_PID="$(cat "$pid_file" 2>/dev/null || true)"
}

identity=pipeline-implement-1999
state_file="$NIGHT/.codex-spin-$identity.json"
started_at="$(date +%s)"
write_spend 100 "$started_at"
hand_agent_codex_spin_status "$identity" "$wrapper_pid" "" "" "" 1999 test/repo "$started_at" >/dev/null

sleep 4
stale_progress=$(( $(date +%s) - 3 ))
jq --argjson progress "$stale_progress" '.progress_at = $progress' "$state_file" >"$state_file.tmp"
mv "$state_file.tmp" "$state_file"
printf 'start\n' >"$tmp/control"
for _ in {1..3000}; do [ -s "$tmp/codex.pid" ] && break; sleep 0.01; done
codex_pid="$(cat "$tmp/codex.pid")"
for _ in {1..3000}; do [ -s "$tmp/codex-sleep.pid" ] && break; sleep 0.01; done
codex_sleep_pid="$(cat "$tmp/codex-sleep.pid")"

selected_pid="$(hand_agent_pipeline_codex_pid "$wrapper_pid")"
[ "$selected_pid" = "$codex_pid" ] || {
  printf 'not ok - selected PID %s, expected active Codex child %s\n' "$selected_pid" "$codex_pid" >&2
  exit 1
}

now="$(date +%s)"
write_spend 200 "$now"
old_pid_result="$(hand_agent_codex_spin_status "$identity" "$wrapper_pid" "" "" "" 1999 test/repo "$now")"
[[ "$old_pid_result" == SPINNING$'\t'* ]] || {
  printf 'not ok - fixture did not reproduce wrapper-age false positive: %s\n' "$old_pid_result" >&2
  exit 1
}
child_result="$(hand_agent_codex_spin_status "$identity" "$selected_pid" "" "" "" 1999 test/repo "$now")"
[[ "$child_result" == WAITING$'\t'* ]] || {
  printf 'not ok - fresh Codex child inherited wrapper status: result=%s root=%s child=%s start=%s now=%s\n' \
    "$child_result" "$wrapper_pid" "$selected_pid" "$(hand_agent_process_started_at "$selected_pid")" "$now" >&2
  jq '{source,tokens,process_started_at,progress_at,marker_at,growth_at,sampled_at}' "$state_file" >&2
  exit 1
}

child_started_at="$(hand_agent_process_started_at "$selected_pid")"
spin_now=$((child_started_at + 3))
write_spend 300 "$spin_now"
spin_result="$(hand_agent_codex_spin_status "$identity" "$selected_pid" "" "" "" 1999 test/repo "$spin_now")"
[[ "$spin_result" == SPINNING$'\t'* ]] || {
  printf 'not ok - stale active Codex child escaped spin detection: %s\n' "$spin_result" >&2
  exit 1
}


progress_repo="$tmp/progress-repo"
mkdir -p "$progress_repo"
git -C "$progress_repo" init -q
git -C "$progress_repo" config user.email test@example.com
git -C "$progress_repo" config user.name test
printf 'baseline\n' > "$progress_repo/work.txt"
git -C "$progress_repo" add work.txt
git -C "$progress_repo" commit -qm baseline
progress_report="$tmp/progress-report.md"
printf 'agent is making progress\n' > "$progress_report"
progress_now="$(date +%s)"
hand_agent_codex_spin_status watchdog-progress "$selected_pid" "$progress_repo" "$progress_report" "" "" test/repo "$progress_now" >/dev/null
printf 'repository progress\n' > "$progress_repo/work.txt"
printf 'report append\n' >> "$progress_report"
progress_now="$(date +%s)"
progress_state="$(hand_agent_codex_spin_status watchdog-progress "$selected_pid" "$progress_repo" "$progress_report" "" "" test/repo "$progress_now")"
[[ "$progress_state" == PROGRESSING$'\t'* ]] || {
  printf 'not ok - progressing fixture was not classified PROGRESSING: %s\n' "$progress_state" >&2
  exit 1
}
hand_agent_watchdog_enforce progressing watchdog-progress "$wrapper_pid" "$progress_report" "$progress_state" "$progress_now"
hand_agent_pid_live "$selected_pid" || {
  echo "not ok - watchdog stopped a progressing Codex process" >&2
  exit 1
}
progress_later=$((progress_now + ZF_AGENT_SPIN_THRESHOLD_SECONDS * 2))
printf 'more repository progress\n' > "$progress_repo/work.txt"
printf 'more report progress\n' >> "$progress_report"
touch -d "@$progress_later" "$progress_report"
progress_state="$(hand_agent_codex_spin_status watchdog-progress "$selected_pid" "$progress_repo" "$progress_report" "" "" test/repo "$progress_later")"
[[ "$progress_state" == PROGRESSING$'\t'* ]] || {
  printf 'not ok - continued progress was not classified PROGRESSING: %s\n' "$progress_state" >&2
  exit 1
}
hand_agent_watchdog_enforce progressing watchdog-progress "$wrapper_pid" "$progress_report" "$progress_state" "$progress_later"
hand_agent_pid_live "$selected_pid" || {
  echo "not ok - watchdog stopped a Codex process that kept progressing" >&2
  exit 1
}

spin_report="$tmp/spinning-report.md"
spin_report_at=$((child_started_at + 3))
printf 'agent report before spin\n' > "$spin_report"
touch -d "@$spin_report_at" "$spin_report"
write_spend 100 "$spin_report_at" 2998
hand_agent_codex_spin_status watchdog-spin "$selected_pid" "" "$spin_report" "" 2998 test/repo "$spin_report_at" >/dev/null
spin_now=$((spin_report_at + ZF_AGENT_SPIN_THRESHOLD_SECONDS))
write_spend 100 "$spin_now" 2998
spin_result="$(hand_agent_codex_spin_status watchdog-spin "$selected_pid" "" "$spin_report" "" 2998 test/repo "$spin_now")"
[[ "$spin_result" == SPINNING$'\t'* ]] || {
  printf 'not ok - watchdog grace fixture was not classified SPINNING: %s\n' "$spin_result" >&2
  exit 1
}
hand_agent_watchdog_enforce spinning watchdog-spin "$wrapper_pid" "$spin_report" "$spin_result" "$spin_now"
hand_agent_pid_live "$selected_pid" || {
  echo "not ok - watchdog stopped spinner before its additional grace period" >&2
  exit 1
}
grace_now=$((spin_now + ZF_AGENT_SPIN_THRESHOLD_SECONDS - 1))
grace_result="$(hand_agent_codex_spin_status watchdog-spin "$selected_pid" "" "$spin_report" "" 2998 test/repo "$grace_now")"
hand_agent_watchdog_enforce spinning watchdog-spin "$wrapper_pid" "$spin_report" "$grace_result" "$grace_now"
hand_agent_pid_live "$selected_pid" || {
  echo "not ok - watchdog stopped spinner before the full grace period" >&2
  exit 1
}
stop_now=$((spin_now + ZF_AGENT_SPIN_THRESHOLD_SECONDS))
stop_result="$(hand_agent_codex_spin_status watchdog-spin "$selected_pid" "" "$spin_report" "" 2998 test/repo "$stop_now")"
hand_agent_watchdog_enforce spinning watchdog-spin "$wrapper_pid" "$spin_report" "$stop_result" "$stop_now"
for _ in {1..3000}; do
  hand_agent_pid_live "$selected_pid" || break
  sleep 0.01
done
if hand_agent_pid_live "$selected_pid"; then
  echo "not ok - watchdog left the spinning Codex PID alive" >&2
  exit 1
fi
[[ "$(sed -n '1p' "$spin_report")" == "STATUS: BLOCKED-ON spinning (watchdog stopped pid=$selected_pid after 200 tokens, 0 min without progress)" ]] || {
  printf 'not ok - spinner report was not marked blocked: %s\n' "$(sed -n '1p' "$spin_report")" >&2
  exit 1
}
grep -Fq 'agent report before spin' "$spin_report" || {
  echo "not ok - spinner report body was not preserved" >&2
  exit 1
}
grep -Fq "hand-agent-stopped name=spinning pid=$selected_pid tokens=200 reason=spinning" "$AGENT_HOME/supervisor-inbox" || {
  echo "not ok - spinner stop was not recorded in supervisor inbox" >&2
  exit 1
}

stale_report="$tmp/stale-terminal-report.md"
printf 'STATUS: DONE\nstale finished report\n' > "$stale_report"
stale_written_at="$(stat -c %Y -- "$stale_report")"
sleep 3
bash -c 'printf codex > /proc/self/comm; sleep 300 & echo "$!" > "$1"; wait' _ "$tmp/stale-sleep.pid" &
stale_pid=$!
for _ in {1..3000}; do
  [ -r "/proc/$stale_pid/comm" ] && [ "$(cat "/proc/$stale_pid/comm")" = codex ] && break
  sleep 0.01
done
stale_sleep_pid="$(cat "$tmp/stale-sleep.pid")"
stale_process_started_at="$(hand_agent_process_started_at "$stale_pid")"
[[ "$stale_written_at" -lt "$stale_process_started_at" ]] || {
  echo "not ok - stale report fixture was not older than process start" >&2
  exit 1
}
stale_now=$((stale_process_started_at + ZF_AGENT_SPIN_THRESHOLD_SECONDS))
stale_state=$'WAITING\t?\t0'
hand_agent_watchdog_enforce stale watchdog-stale "$stale_pid" "$stale_report" "$stale_state" "$stale_now"
hand_agent_pid_live "$stale_pid" || {
  echo "not ok - watchdog stopped agent for terminal report older than process start" >&2
  exit 1
}
[[ "$(sed -n '1p' "$stale_report")" == 'STATUS: DONE' ]] || {
  echo "not ok - stale terminal report was overwritten" >&2
  exit 1
}
grep -Fq "hand-agent-stopped name=stale pid=$stale_pid" "$AGENT_HOME/supervisor-inbox" && {
  echo "not ok - stale terminal report stop was recorded" >&2
  exit 1
}
kill "$stale_sleep_pid" "$stale_pid" 2>/dev/null || true
wait "$stale_sleep_pid" 2>/dev/null || true
wait "$stale_pid" 2>/dev/null || true
stale_pid=""
stale_sleep_pid=""
start_fake_codex "$tmp/churn-sleep.pid"
churn_pid="$FAKE_CODEX_PID"
churn_sleep_pid="$FAKE_CODEX_SLEEP_PID"
churn_report="$tmp/report-churn.md"
churn_started="$(hand_agent_process_started_at "$churn_pid")"
churn_first=$((churn_started + 3))
write_spend 100 "$churn_first" 2997
printf 'initial report line\n' > "$churn_report"
touch -d "@$churn_first" "$churn_report"
hand_agent_codex_spin_status watchdog-report-churn "$churn_pid" "" "$churn_report" "" 2997 test/repo "$churn_first" >/dev/null
churn_now=$((churn_started + 6))
printf 'report-only append\n' >> "$churn_report"
touch -d "@$churn_now" "$churn_report"
write_spend 200 "$churn_now" 2997
churn_state="$(hand_agent_codex_spin_status watchdog-report-churn "$churn_pid" "" "$churn_report" "" 2997 test/repo "$churn_now")"
[[ "$churn_state" == SPINNING$'\t'* ]] || {
  printf 'not ok - report-only churn reset spin timer: %s\n' "$churn_state" >&2
  exit 1
}
kill "$churn_pid" "$churn_sleep_pid" 2>/dev/null || true
wait "$churn_pid" 2>/dev/null || true
churn_pid=""; churn_sleep_pid=""
printf 'ok - report-only appends do not reset the spin timer\n'

HAND_AGENT_TOKEN_WARN=100
HAND_AGENT_TOKEN_STOP=200
start_fake_codex "$tmp/budget-warn-sleep.pid"
budget_warn_pid="$FAKE_CODEX_PID"
budget_warn_sleep_pid="$FAKE_CODEX_SLEEP_PID"
budget_report="$tmp/budget-report.md"
printf 'last report line\n' > "$budget_report"
budget_now="$(date +%s)"
budget_state=$'WAITING\t150\t0'
hand_agent_watchdog_enforce budget-warning budget-warning "$budget_warn_pid" "$budget_report" "$budget_state" "$budget_now" work
hand_agent_watchdog_enforce budget-warning budget-warning "$budget_warn_pid" "$budget_report" "$budget_state" "$budget_now" work
hand_agent_pid_live "$budget_warn_pid" || {
  echo 'not ok - WARN stopped the agent before STOP threshold' >&2
  exit 1
}
warning_count="$(grep -Fc 'hand-agent-token-budget name=budget-warning' "$AGENT_HOME/supervisor-inbox" 2>/dev/null || true)"
[[ "$warning_count" == 1 ]] \
  && grep -Fq 'tokens=150 runtime=' "$AGENT_HOME/supervisor-inbox" \
  && grep -Fq 'last_report=last report line' "$AGENT_HOME/supervisor-inbox" || {
  echo 'not ok - token WARN was not recorded once with runtime and last report line' >&2
  exit 1
}
printf 'ok - token WARN fires once with runtime and last report line\n'

start_fake_codex "$tmp/budget-stop-sleep.pid"
budget_stop_pid="$FAKE_CODEX_PID"
budget_stop_sleep_pid="$FAKE_CODEX_SLEEP_PID"
budget_stop_report="$tmp/budget-stop-report.md"
printf 'work remains\n' > "$budget_stop_report"
hand_agent_watchdog_enforce budget-stop budget-stop "$budget_stop_pid" "$budget_stop_report" $'WAITING\t250\t0' "$(date +%s)" work
for _ in {1..3000}; do
  hand_agent_pid_live "$budget_stop_pid" || break
  sleep 0.01
done
if hand_agent_pid_live "$budget_stop_pid"; then
  echo 'not ok - token STOP left agent alive' >&2
  exit 1
fi
[[ "$(sed -n '1p' "$budget_stop_report")" == 'STATUS: BLOCKED-ON token-budget (250)' ]] || {
  printf 'not ok - token STOP status missing: %s\n' "$(sed -n '1p' "$budget_stop_report")" >&2
  exit 1
}
grep -Fq "hand-agent-stopped name=budget-stop pid=$budget_stop_pid tokens=250 reason=token-budget" "$AGENT_HOME/supervisor-inbox" || {
  echo 'not ok - token STOP was not recorded' >&2
  exit 1
}
printf 'ok - token STOP terminates agent and marks report\n'

start_fake_codex "$tmp/budget-override-sleep.pid"
budget_override_pid="$FAKE_CODEX_PID"
budget_override_sleep_pid="$FAKE_CODEX_SLEEP_PID"
budget_override_report="$tmp/budget-override-report.md"
budget_override_brief="$tmp/budget-override-brief.md"
printf 'progress\n' > "$budget_override_report"
printf 'Token budget: 500\n' > "$budget_override_brief"
hand_agent_watchdog_enforce budget-override budget-override "$budget_override_pid" "$budget_override_report" $'WAITING\t250\t0' "$(date +%s)" work "$budget_override_brief"
hand_agent_pid_live "$budget_override_pid" || {
  echo 'not ok - brief override did not raise token STOP threshold' >&2
  exit 1
}
hand_agent_watchdog_enforce budget-override budget-override "$budget_override_pid" "$budget_override_report" $'WAITING\t501\t0' "$(date +%s)" work "$budget_override_brief"
for _ in {1..3000}; do
  hand_agent_pid_live "$budget_override_pid" || break
  sleep 0.01
done
if hand_agent_pid_live "$budget_override_pid"; then
  echo 'not ok - brief override did not stop agent above its raised budget' >&2
  exit 1
fi
[[ "$(sed -n '1p' "$budget_override_report")" == 'STATUS: BLOCKED-ON token-budget (501)' ]] || {
  echo 'not ok - brief override stop status is wrong' >&2
  exit 1
}
printf 'ok - rendered brief can raise token STOP budget\n'

# 2026-10-08 ruling no-hand-agent-token-cap: STOP=0 never stops, whatever the tokens or brief budget.
start_fake_codex "$tmp/budget-none-sleep.pid"
budget_none_pid="$FAKE_CODEX_PID"
budget_none_report="$tmp/budget-none-report.md"
printf 'progress\n' > "$budget_none_report"
HAND_AGENT_TOKEN_STOP=0 hand_agent_watchdog_enforce budget-none budget-none "$budget_none_pid" "$budget_none_report" $'WAITING\t999999\t0' "$(date +%s)" work "$budget_override_brief"
hand_agent_pid_live "$budget_none_pid" || {
  echo 'not ok - STOP=0 still stopped the agent' >&2
  exit 1
}
kill "$budget_none_pid" 2>/dev/null || true
printf 'ok - STOP=0 never stops an agent\n'

bash -c 'printf codex > /proc/self/comm; sleep 0.1; sleep 300 & echo "$!" > "$1"; wait' _ "$tmp/terminal-sleep.pid" &
terminal_pid=$!
for _ in {1..3000}; do
  [ -r "$tmp/terminal-sleep.pid" ] && [ -s "$tmp/terminal-sleep.pid" ] && break
  sleep 0.01
done
if [ ! -r "$tmp/terminal-sleep.pid" ] || [ ! -s "$tmp/terminal-sleep.pid" ]; then
  echo "not ok - terminal sleep PID file did not become readable within 30s" >&2
  exit 1
fi
terminal_comm="$(cat "/proc/$terminal_pid/comm" 2>/dev/null || true)"
[[ "$terminal_comm" == codex ]] || {
  printf 'not ok - terminal process %s comm never became codex within 30s (got %s)\n' \
    "$terminal_pid" "$terminal_comm" >&2
  exit 1
}
terminal_sleep_pid="$(cat "$tmp/terminal-sleep.pid")"
sleep 3
terminal_report="$tmp/terminal-report.md"
printf 'STATUS: DONE\nfinished report\n' > "$terminal_report"
terminal_written_at="$(stat -c %Y -- "$terminal_report")"
terminal_process_started_at="$(hand_agent_process_started_at "$terminal_pid")"
[[ "$terminal_written_at" -ge "$terminal_process_started_at" ]] || {
  echo "not ok - terminal report fixture was not written after process start" >&2
  exit 1
}
terminal_now=$((terminal_written_at + ZF_AGENT_SPIN_THRESHOLD_SECONDS))
terminal_state="$(hand_agent_codex_spin_status watchdog-terminal "$terminal_pid" "" "$terminal_report" "" "" test/repo "$terminal_now")"
hand_agent_watchdog_enforce terminal watchdog-terminal "$terminal_pid" "$terminal_report" "$terminal_state" "$terminal_now"
wait "$terminal_pid" 2>/dev/null || true
[[ "$(sed -n '1p' "$terminal_report")" == 'STATUS: DONE' ]] || {
  echo "not ok - terminal report was overwritten" >&2
  exit 1
}
grep -Fq "hand-agent-stopped name=terminal pid=$terminal_pid" "$AGENT_HOME/supervisor-inbox" \
  && grep -Fq "reason=finished-report" "$AGENT_HOME/supervisor-inbox" || {
  echo "not ok - stale terminal report stop was not recorded" >&2
  exit 1
}

sleep 300 &
zcode_pid=$!
zcode_report="$tmp/zcode-report.md"
printf 'STATUS: READY-TO-LAND\nzcode report\n' > "$zcode_report"
zcode_report_at="$(stat -c %Y -- "$zcode_report")"
zcode_now=$((zcode_report_at + ZF_AGENT_SPIN_THRESHOLD_SECONDS))
zcode_state=$'WAITING\t?\t0'
hand_agent_watchdog_enforce zcode zcode-watchdog "$zcode_pid" "$zcode_report" "$zcode_state" "$zcode_now" hand-zcode
for _ in {1..3000}; do
  hand_agent_pid_live "$zcode_pid" || break
  sleep 0.01
done
if hand_agent_pid_live "$zcode_pid"; then
  echo "not ok - watchdog did not stop exited-report zcode process" >&2
  exit 1
fi
[[ "$(sed -n '1p' "$zcode_report")" == 'STATUS: READY-TO-LAND' ]] || {
  echo "not ok - zcode READY-TO-LAND report was overwritten" >&2
  exit 1
}
grep -Fq "hand-agent-stopped name=zcode pid=$zcode_pid" "$AGENT_HOME/supervisor-inbox" \
  && grep -Fq "reason=finished-report" "$AGENT_HOME/supervisor-inbox" || {
  echo "not ok - zcode process exit was not recorded by hand-agent watchdog" >&2
  exit 1
}

printf 'ok - HEALTH uses active Codex and zcode PIDs and stops only after watchdog grace or stale terminal report\n'
