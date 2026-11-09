#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
unset AUTOPILOT_LOOP_UNIT

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
bell="$script_dir/bell.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/bell-test.XXXXXX")"
autopi="$tmp/autopi"
bin="$tmp/bin"
supervisor="$tmp/supervisor"
mkdir -p "$autopi/alerts" "$bin" "$supervisor"
fixture_root="$tmp/repo"
mkdir -p "$fixture_root/engine/mac-autopilot" "$fixture_root/engine/night"
export MAC_AUTOPILOT_ROOT="$fixture_root"
printf 'window.DASH={};\n' > "$autopi/dashboard.data.js"
trap 'rm -rf "$tmp"' EXIT

cat > "$autopi/config.json" <<'JSON'
{"bell":{"enabled":true,"dedup_minutes":30},"incident":{"file_min_severity":"off"}}
JSON
printf 'existing alert\n' > "$autopi/alerts/gate.md"
old_mtime="$(python3 - "$autopi/alerts/gate.md" <<'PY'
import os,sys
print(os.stat(sys.argv[1]).st_mtime_ns)
PY
)"
old_tick="$(python3 - <<'PY'
from datetime import datetime,timezone,timedelta
print((datetime.now(timezone.utc)-timedelta(minutes=7)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"
future_tick="2099-01-01T00:00:00Z"
printf '[%s] SLOW worker pid=123 unit=unit-worker 10min\n[%s] BUDGET-STOP token spent>100, unit=unit-budget not dispatched\n[%s] [pipeline suites] FAILED suite=engine/run-advisor-batch.test.sh exit_code=1\n' "$old_tick" "$old_tick" "$old_tick" > "$autopi/scheduler.log"
printf '[%s] tick done units=3 live=1 secs=200 slow: release_dependency_blocks=58s\n[%s] tick done future-stamp-fixture\n' "$old_tick" "$future_tick" >> "$autopi/scheduler.log"
touch -d "@$(( $(date +%s) - 420 ))" "$autopi/scheduler.log"
printf 'new alert line\n' >> "$autopi/alerts/gate.md"
printf '[%s] [pipeline suites] FAILED suite=engine/run-advisor-batch.test.sh exit_code=1\n' "$old_tick" >> "$autopi/alerts/gate.md"
cat > "$supervisor/advisor-verdicts-stale.json" <<'JSON'
[{"n":1,"priority":"P1","reason":"fixture","verdict":"FIX"},{"n":2,"verdict":"PASS"}]
JSON
python3 - "$supervisor/advisor-verdicts-stale.json" <<'PY'
import os,sys
os.utime(sys.argv[1], (1,1))
PY
dead_pid=99999999
jq -n --argjson pid "$dead_pid" '{
  units:[
    {id:"unit-worker",stage:"review",history:[]},
    {id:"unit-merge",stage:"repair-pending",history:[{stage:"merge-reverted",at:"2026-10-18T00:00:00Z",result:"Pipeline suites failure"}]},
    {id:"unit-budget",stage:"implement-pending",history:[]}
  ],
  workers:[{pid:$pid,unit:"unit-worker",type:"implement",log:"impl-worker.log",report:"impl-worker.md",harvested:false}]
}' > "$autopi/units.json"
jq -n --argjson pid "$dead_pid" '{workers:[{pid:$pid,unit:"unit-worker",type:"implement",log:"impl-worker.log",report:"impl-worker.md",harvested:false}]}' > "$autopi/workers.json"
jq -n --argjson old "$old_mtime" '{monitor_initialized:true,scheduler_lines:0,alert_mtimes:{"alerts/gate.md":$old},merge_events:{},signatures:{},pending:[]}' > "$autopi/bell-state.json"

cat > "$bin/pkill" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BELL_TEST_SYSTEMCTL_CALLS"
exit 0
SH
cat > "$bin/nohup" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$bin/notify-send" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BELL_TEST_NOTIFICATIONS"
SH
cat > "$bin/timeout" <<'SH'
#!/usr/bin/env bash
[[ "$1" == --foreground ]] && exit 0 # platform_require's GNU-timeout probe (macOS)
[[ "$1" == 8 ]] || exit 2
shift
exec "$@"
SH
cat > "$bin/git" <<'SH'
#!/usr/bin/env bash
if [[ -n "${BELL_TEST_CI_RUNS:-}" ]]; then
  [[ "$1" == -C ]] && shift 2
  case "$1" in
    ls-remote) printf '%s\trefs/heads/main\n' "$BELL_TEST_MAIN_SHA"; exit 0 ;;
    merge-base)
      if [[ "$3" == "${BELL_TEST_TRAIN_DURING_SCAN:-none}" ]]; then
        jq -n --arg sha "$3" '{status:"building",candidate:$sha,build_run:102}' > "$BELL_AUTOPI_DIR/release-train.json"
      fi
      [[ "$3" != "${BELL_TEST_UNRELATED_SHA:-none}" ]]; exit $? ;;
    *) exit 2 ;;
  esac
fi
case "${BELL_TEST_NETWORK:-green}" in
  down) printf 'remote: 502 Bad Gateway\n' >&2; exit 128 ;;
  timeout) printf 'fatal: Connection timed out\n' >&2; exit 128 ;;
  green) printf 'deadbeef\trefs/heads/main\n'; exit 0 ;;
  *) printf 'fatal: authentication failed\n' >&2; exit 128 ;;
esac
SH
cat > "$bin/journalctl" <<'SH'
#!/usr/bin/env bash
if [[ "${BELL_TEST_LOG_MODE:-short}" == flood ]]; then
  python3 - <<'PY'
import sys
sys.stdout.write('oom-kill ' + 'J' * 3000 + '\n')
PY
else
  printf 'oom-kill fixture trace 1\n'
fi
SH
cat > "$bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BELL_TEST_CLAUDE_CALLS"
printf 'classification: fixture event\n'
printf 'evidence: fixture paths inspected\n'
printf 'recommendation: no action performed\n'
SH
chmod +x "$bin/"*

export BELL_AUTOPI_DIR="$autopi"
export BELL_TEST_NOTIFICATIONS="$tmp/notifications.log"
export BELL_TEST_CLAUDE_CALLS="$tmp/claude-calls.log"
export BELL_TEST_SYSTEMCTL_CALLS="$tmp/systemctl-calls.log"
export BELL_SUPERVISOR_DIR="$supervisor"
export BELL_TEST_NETWORK=green
export BELL_STALE_CI_DISABLE=1
export PATH="$bin:$PATH"

# A stalled scheduler must not restart the systemd loop during an operator pause.
pause_autopi="$tmp/pause-autopi"
pause_agent="$tmp/pause-agent"
mkdir -p "$pause_autopi/alerts" "$pause_agent"
printf '%s\n' '{"bell":{"enabled":true},"incident":{"file_min_severity":"off"}}' > "$pause_autopi/config.json"
printf '%s\n' '{"units":[]}' > "$pause_autopi/units.json"
printf '%s\n' '{"caller":"operator","reason":"maintenance","issue":"1","provider":"manual","model":"manual","timestamp":"2026-10-01T00:00:00Z"}' > "$pause_agent/PAUSE"
BELL_AUTOPI_DIR="$pause_autopi" AGENT_HOME="$pause_agent" AUTOPILOT_LOOP_UNIT=fixture-loop.service bash "$bell"
if [[ -e "$BELL_TEST_SYSTEMCTL_CALLS" ]] && grep -Eq '^--user (restart|start) ' "$BELL_TEST_SYSTEMCTL_CALLS"; then
  echo 'bell.test.sh: restarted loop during operator pause' >&2; exit 1
fi
grep -Fq 'paused, not restarting' "$pause_autopi/BELL-QUEUE.md" || { echo 'bell.test.sh: missing pause message' >&2; exit 1; }
mv "$pause_agent/PAUSE" "$pause_agent/PAUSE.saved"
# Use a fresh event state to ensure the unpaused observation is recorded.
mv "$pause_autopi/bell-state.json" "$pause_autopi/bell-state.saved"
BELL_AUTOPI_DIR="$pause_autopi" AGENT_HOME="$pause_agent" AUTOPILOT_LOOP_UNIT=fixture-loop.service bash "$bell"
grep -Fxq -- '--user restart fixture-loop.service' "$BELL_TEST_SYSTEMCTL_CALLS" || { echo 'bell.test.sh: unpaused loop was not restarted' >&2; exit 1; }
mv "$BELL_TEST_SYSTEMCTL_CALLS" "$tmp/pause-systemctl-calls"

bash "$bell"
grep -Fq 'worker-died unit=unit-worker' "$autopi/BELL-QUEUE.md"
! grep -Fq 'tick done' "$autopi/BELL-QUEUE.md" || { echo 'bell.test.sh: a tick summary line was queued as an event' >&2; exit 1; }
grep -Fq 'log=impl-worker.log report=impl-worker.md' "$autopi/BELL-QUEUE.md"
grep -Fq "journalctl -k --since '-5 min' --no-pager" "$autopi/BELL-QUEUE.md"
grep -Fq 'oom-kill fixture trace 1' "$autopi/BELL-QUEUE.md"
grep -Fq "tail -n 120 '$supervisor/impl-worker.log'" "$autopi/BELL-QUEUE.md"
grep -Fq 'merge-reverted unit=unit-merge' "$autopi/BELL-QUEUE.md"
grep -Fq 'scheduler tick stale' "$autopi/BELL-QUEUE.md"
grep -Fq 'loop restart failed' "$autopi/BELL-QUEUE.md"
grep -Fq 'critical' "$autopi/bell.log"
grep -Fq 'alert changed: alerts/gate.md' "$autopi/BELL-QUEUE.md"
grep -Fq 'suite-flake:engine/run-advisor-batch.test.sh' "$autopi/BELL-QUEUE.md"
grep -Fq 'nightly_suite_paths' "$autopi/BELL-QUEUE.md"
grep -Fq 'run-ci-suites.sh --nightly' "$autopi/BELL-QUEUE.md"
grep -Fq 'verdicts-backlog-stale' "$autopi/BELL-QUEUE.md"
grep -Fq '1 unimported FIX item' "$autopi/BELL-QUEUE.md"
grep -Fq 'gh issue create --repo example-maintainer/example-repo' "$autopi/BELL-QUEUE.md"
grep -Fq -- '--label auto-filed --label bug --label needs-triage' "$autopi/BELL-QUEUE.md"
grep -Fq 'action=queue=append' "$autopi/bell.log"
# The retired bell.notify/bell.auto_supervisor keys: with neither key in the
# config, high and critical events neither notify nor start a supervisor.
[[ ! -e "$autopi/.bell-supervisor.lock" && ! -e "$autopi/BELL-SUPERVISOR.log" ]] || { echo 'bell.test.sh: a supervisor was started with no auto_supervisor key' >&2; exit 1; }
[[ ! -s "$BELL_TEST_NOTIFICATIONS" ]] || { echo 'bell.test.sh: a desktop notification was sent with no notify key' >&2; exit 1; }
[[ ! -s "$BELL_TEST_CLAUDE_CALLS" ]] || { echo 'bell.test.sh: a supervisor agent was launched with no auto_supervisor key' >&2; exit 1; }
queue_count="$(wc -l < "$autopi/BELL-QUEUE.md" | awk '{print $1}')"
log_count="$(wc -l < "$autopi/bell.log" | awk '{print $1}')"

# Re-observing the same dead worker and stale tick must not emit again.
bash "$bell"
[[ "$(wc -l < "$autopi/BELL-QUEUE.md" | awk '{print $1}')" == "$queue_count" ]]
[[ "$(wc -l < "$autopi/bell.log" | awk '{print $1}')" == "$log_count" ]]

# S6: the down signature deduplicates, while recovery bypasses a seeded
# matching dedup window and emits exactly once.
network_autopi="$tmp/network-autopi"
network_supervisor="$tmp/network-supervisor"
mkdir -p "$network_autopi/alerts" "$network_supervisor"
printf 'window.DASH={};\n' > "$network_autopi/dashboard.data.js"
cp "$autopi/config.json" "$network_autopi/config.json"
printf '%s\n' '{"units":[]}' > "$network_autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$network_autopi/workers.json"
printf '[%s] scheduler tick\n' "$old_tick" > "$network_autopi/scheduler.log"
jq -n '{monitor_initialized:true,scheduler_lines:1,alert_mtimes:{},merge_events:{},signatures:{},pending:[],network_down:false}' > "$network_autopi/bell-state.json"
export BELL_AUTOPI_DIR="$network_autopi"
export BELL_SUPERVISOR_DIR="$network_supervisor"
export BELL_TEST_NETWORK=down
bash "$bell"
grep -Fq 'network-down' "$network_autopi/BELL-QUEUE.md"
grep -Fq 'high ' "$network_autopi/BELL-QUEUE.md"
grep -Fq 'suites 裁决在此期间可能假阴性' "$network_autopi/BELL-QUEUE.md"
grep -Fq '重跑在跑的失败 run' "$network_autopi/BELL-QUEUE.md"
network_queue_count="$(wc -l < "$network_autopi/BELL-QUEUE.md" | awk '{print $1}')"
network_log_count="$(wc -l < "$network_autopi/bell.log" | awk '{print $1}')"
bash "$bell"
[[ "$(wc -l < "$network_autopi/BELL-QUEUE.md" | awk '{print $1}')" == "$network_queue_count" ]]
[[ "$(wc -l < "$network_autopi/bell.log" | awk '{print $1}')" == "$network_log_count" ]]
recovered_hash="$(printf 'network-recovered' | shasum -a 256 | awk '{print $1}')"
jq --arg h "$recovered_hash" '.signatures[$h]={last:4102444800,count:1,event_id:"seed"}' "$network_autopi/bell-state.json" > "$tmp/network-state.json"
mv "$tmp/network-state.json" "$network_autopi/bell-state.json"
export BELL_TEST_NETWORK=green
bash "$bell"
grep -Fq 'info ' "$network_autopi/BELL-QUEUE.md"
grep -Fq 'network-recovered' "$network_autopi/BELL-QUEUE.md"
recovery_queue_count="$(wc -l < "$network_autopi/BELL-QUEUE.md" | awk '{print $1}')"
bash "$bell"
[[ "$(wc -l < "$network_autopi/BELL-QUEUE.md" | awk '{print $1}')" == "$recovery_queue_count" ]]

# A separate clean fixture proves the second occurrence of a medium signature activates once.
repeat_autopi="$tmp/repeat-autopi"
mkdir -p "$repeat_autopi/alerts"
printf 'window.DASH={};\n' > "$repeat_autopi/dashboard.data.js"
cp "$autopi/config.json" "$repeat_autopi/config.json"
printf '%s\n' '{"units":[]}' > "$repeat_autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$repeat_autopi/workers.json"
repeat_tick="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf '[%s] BUDGET-STOP token spent>100, unit=unit-budget not dispatched\n' "$repeat_tick" > "$repeat_autopi/scheduler.log"
jq -n '{monitor_initialized:true,scheduler_lines:0,alert_mtimes:{},merge_events:{},signatures:{},pending:[]}' > "$repeat_autopi/bell-state.json"
export BELL_AUTOPI_DIR="$repeat_autopi"
bash "$bell"
[[ "$(wc -l < "$repeat_autopi/BELL-QUEUE.md" | awk '{print $1}')" == 1 ]]
repeat_log_count="$(wc -l < "$repeat_autopi/bell.log" | awk '{print $1}')"

printf '[%s] BUDGET-STOP token spent>100, unit=unit-budget not dispatched\n' "$repeat_tick" >> "$repeat_autopi/scheduler.log"
bash "$bell"
[[ "$(wc -l < "$repeat_autopi/BELL-QUEUE.md" | awk '{print $1}')" == 1 ]]
[[ "$(wc -l < "$repeat_autopi/bell.log" | awk '{print $1}')" == "$repeat_log_count" ]]

# S9: worker-death evidence is collected in the same beat and capped at 2 KB.
trunc_autopi="$tmp/trunc-autopi"
mkdir -p "$trunc_autopi/alerts"
printf 'window.DASH={};\n' > "$trunc_autopi/dashboard.data.js"
cp "$autopi/config.json" "$trunc_autopi/config.json"
printf '[%s] scheduler tick\n' "$old_tick" > "$trunc_autopi/scheduler.log"
jq -n --argjson pid "$dead_pid" '{units:[{id:"unit-trunc",stage:"review",history:[]}],workers:[{pid:$pid,unit:"unit-trunc",log:"impl.log",report:"impl.md",harvested:false}]}' > "$trunc_autopi/units.json"
jq -n --argjson pid "$dead_pid" '{workers:[{pid:$pid,unit:"unit-trunc",log:"impl.log",report:"impl.md",harvested:false}]}' > "$trunc_autopi/workers.json"
jq -n '{monitor_initialized:true,scheduler_lines:1,alert_mtimes:{},merge_events:{},signatures:{},pending:[],network_down:false}' > "$trunc_autopi/bell-state.json"
export BELL_AUTOPI_DIR="$trunc_autopi"
export BELL_TEST_LOG_MODE=flood
bash "$bell"
python3 - "$trunc_autopi/BELL-QUEUE.md" <<'PY'
import sys
text=open(sys.argv[1]).read()
marker='output (max 2048 bytes): '
line=next(line for line in text.splitlines() if 'worker-died unit=unit-trunc' in line)
payload=line.split(marker,1)[1]
assert len(payload.encode()) == 2048, len(payload.encode())
assert payload == 'oom-kill ' + 'J' * 2039
PY

# 已写出报告的已退出 worker 只是等待回收，不报 worker-died。
done_autopi="$tmp/done-autopi"; done_sup="$tmp/done-supervisor"
mkdir -p "$done_autopi/alerts" "$done_sup"
printf 'window.DASH={};\n' > "$done_autopi/dashboard.data.js"
cp "$trunc_autopi/config.json" "$done_autopi/config.json"
printf '[%s] scheduler tick\n' "$old_tick" > "$done_autopi/scheduler.log"
printf 'VERDICT: APPROVE\n' > "$done_sup/review-9.md"
jq -n --argjson pid "$dead_pid" '{units:[{id:"pr-9",stage:"review",history:[]}]}' > "$done_autopi/units.json"
jq -n --argjson pid "$dead_pid" '{workers:[{pid:$pid,unit:"pr-9",log:"review-9.worker.log",report:"review-9.md",harvested:false}]}' > "$done_autopi/workers.json"
jq -n '{monitor_initialized:true,scheduler_lines:1,alert_mtimes:{},merge_events:{},signatures:{},pending:[],network_down:false}' > "$done_autopi/bell-state.json"
BELL_AUTOPI_DIR="$done_autopi" BELL_SUPERVISOR_DIR="$done_sup" bash "$bell"
! grep -Fq 'worker-died' "$done_autopi/BELL-QUEUE.md" 2>/dev/null || { echo 'bell.test.sh: finished worker with a report reported as died' >&2; exit 1; }

# S12 uses complete, isolated GitHub and cancellation fixtures. Check-only must
# not cancel runs or modify any runtime file, even when the scheduler is stale.
unset AGENT_HOME
ci_autopi="$tmp/ci-autopi"
mkdir -p "$ci_autopi/alerts" "$tmp/ci-supervisor"
printf 'window.DASH={};\n' > "$ci_autopi/dashboard.data.js"
printf '%s\n' '{"bell":{"enabled":true},"incident":{"file_min_severity":"off"}}' > "$ci_autopi/config.json"
printf '%s\n' '{"units":[]}' > "$ci_autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$ci_autopi/workers.json"
printf '%s\n' '{"steps":[{"step":"release fixture","status":"done"}]}' > "$ci_autopi/release.json"
printf '[%s] scheduler tick\n' "$old_tick" > "$ci_autopi/scheduler.log"
touch -t 202001010000 "$ci_autopi/scheduler.log"
export BELL_AUTOPI_DIR="$ci_autopi" BELL_SUPERVISOR_DIR="$tmp/ci-supervisor"
export BELL_STALE_CI_DISABLE=0 BELL_TEST_NETWORK=green
export BELL_TEST_MAIN_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
old_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
batch_sha=cccccccccccccccccccccccccccccccccccccccc
base_sha=dddddddddddddddddddddddddddddddddddddddd
release_sha=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
export BELL_TEST_CI_RUNS="$tmp/ci-runs.json"
export BELL_TEST_CANCELED="$tmp/canceled.log"
cat > "$bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == "run view" ]]; then
  [[ "$3" != "${BELL_TEST_VIEW_FAIL_RUN:-none}" ]] || exit 1
  jq -c --argjson id "$3" --arg started "${BELL_TEST_STARTED_RUN:-}" \
    --arg jobs_run "${BELL_TEST_JOBS_RUN:-}" --arg omit_jobs "${BELL_TEST_OMIT_JOBS_RUN:-}" \
    --argjson jobs "${BELL_TEST_JOBS_JSON:-[]}" \
    '.[] | select(.databaseId==$id)
     | .jobs=[{status:"queued"}]
     | if (.databaseId|tostring)==$jobs_run then .jobs=$jobs else . end
     | if (.databaseId|tostring)==$omit_jobs then del(.jobs) else . end
     | if (.databaseId|tostring)==$started then .status="in_progress" else . end' "$BELL_TEST_CI_RUNS"
  exit
fi
exit 2
SH
cat > "$fixture_root/engine/night/main-ci-recovery.sh" <<'SH'
#!/usr/bin/env bash
[[ "$1" == cancel-run ]] || exit 2
printf '%s\n' "$2" >> "$BELL_TEST_CANCELED"
SH
chmod +x "$bin/gh"
ci_runs() {
  jq -n --arg main "$BELL_TEST_MAIN_SHA" --arg old "$old_sha" \
    --arg batch "$batch_sha" --arg base "$base_sha" --arg release "$release_sha" \
    '[
      {databaseId:101,headSha:$old,status:"queued",createdAt:"2026-10-19T01:00:00Z"},
      {databaseId:102,headSha:$batch,status:"pending",createdAt:"2026-10-19T02:00:00Z"},
      {databaseId:103,headSha:$base,status:"waiting",createdAt:"2026-10-19T03:00:00Z"},
      {databaseId:104,headSha:$release,status:"queued",createdAt:"2026-10-19T04:00:00Z"},
      {databaseId:105,headSha:$main,status:"queued",createdAt:"2026-10-19T05:00:00Z"},
      {databaseId:106,headSha:$old,status:"in_progress",createdAt:"2026-10-19T00:00:00Z"}
    ]' > "$BELL_TEST_CI_RUNS"
  publish_ci_snapshot
}
publish_ci_snapshot() { # what the scheduler writes each tick; bell reads run lists only from it
  ( source "$(dirname "$bell")/runtime-env.sh"; pr_run_snapshot_publish "$ci_autopi" "[]" "[]" "$(cat "$BELL_TEST_CI_RUNS")" "[]" "[]" "" )
}
assert_no_cancellations() {
  if [[ -s "$BELL_TEST_CANCELED" ]]; then
    echo "bell.test.sh: unexpected CI cancellation: $(cat "$BELL_TEST_CANCELED")" >&2
    exit 1
  fi
}
ci_runs
cp -R "$ci_autopi" "$tmp/check-only-before"
AUTOPILOT_LOOP_UNIT=fixture-loop.service bash "$bell" --check-only > "$tmp/check-only.out"
assert_no_cancellations
[[ ! -e "$BELL_TEST_SYSTEMCTL_CALLS" ]]
diff -qr "$ci_autopi" "$tmp/check-only-before" >/dev/null
grep -Fq 'check-only' "$tmp/check-only.out"

# The tick-start stamp may be old while scheduler.log was just written.
# Preserve the fresh-mtime signal so a slow tick cannot invoke a loop restart.
printf '[%s] scheduler tick\n' "$old_tick" > "$ci_autopi/scheduler.log"
bash "$bell"
rm -f "$BELL_TEST_CANCELED"
! grep -Fq 'scheduler tick stale' "$ci_autopi/BELL-QUEUE.md" 2>/dev/null || { echo 'bell.test.sh: a freshly written scheduler.log with an old tick-start stamp was judged stale' >&2; exit 1; }

# Without an active candidate, only a proven main ancestor may be canceled.
printf '%s\n' '{"units":[]}' > "$ci_autopi/units.json"
export BELL_TEST_UNRELATED_SHA="$release_sha"
# main can have a newer [skip ci] HEAD with no corresponding CI run.
export BELL_TEST_MAIN_SHA=ffffffffffffffffffffffffffffffffffffffff
bash "$bell"
[[ "$(cat "$BELL_TEST_CANCELED")" == $'101\n102\n103' ]]
rm -f "$BELL_TEST_CANCELED"
export BELL_TEST_MAIN_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# A lone waiting run has no newer waiting replacement; running runs stay.
jq 'map(select(.databaseId == 101 or .status == "in_progress"))' "$BELL_TEST_CI_RUNS" > "$tmp/no-replacement.json"
mv "$tmp/no-replacement.json" "$BELL_TEST_CI_RUNS"
publish_ci_snapshot
bash "$bell"
assert_no_cancellations
ci_runs

# Recheck waiting status immediately before cancellation: a newly started
# run stays even when it appeared queued in the list response.
export BELL_TEST_STARTED_RUN=101
bash "$bell"
[[ "$(cat "$BELL_TEST_CANCELED")" == $'102\n103' ]]
rm "$BELL_TEST_CANCELED"
unset BELL_TEST_STARTED_RUN

# GitHub can still report queued while a shard has started or completed.
# A successful jobs read is required; missing/unknown jobs are never zero work.
export BELL_TEST_JOBS_RUN=101
for job_status in in_progress completed; do
  export BELL_TEST_JOBS_JSON="$(jq -cn --arg status "$job_status" '[{status:"queued"},{status:$status}]')"
  bash "$bell"
  [[ "$(cat "$BELL_TEST_CANCELED")" == $'102\n103' ]]
  rm "$BELL_TEST_CANCELED"
done
for invalid_jobs in null '[{"status":"unknown"}]' '[{}]'; do
  export BELL_TEST_JOBS_JSON="$invalid_jobs"
  bash "$bell"
  assert_no_cancellations
done
unset BELL_TEST_JOBS_RUN BELL_TEST_JOBS_JSON
export BELL_TEST_OMIT_JOBS_RUN=101
bash "$bell"
assert_no_cancellations
unset BELL_TEST_OMIT_JOBS_RUN
export BELL_TEST_VIEW_FAIL_RUN=101
bash "$bell"
assert_no_cancellations
unset BELL_TEST_VIEW_FAIL_RUN
grep -Fq 'stale-main-ci-jobs-unknown' "$ci_autopi/BELL-QUEUE.md"

# Unreadable/malformed protection evidence and unbound manual release work
# hold automatic cancellation. No empty array default may erase this guard.
printf '{}\n' > "$ci_autopi/units.json"
bash "$bell"
assert_no_cancellations
printf '%s\n' '{"units":[]}' > "$ci_autopi/units.json"
printf '%s\n' '{"steps":[{"step":"real path acceptance","status":"pending"}]}' > "$ci_autopi/release.json"
bash "$bell"
assert_no_cancellations
grep -Fq 'stale-main-ci-protection-unknown' "$ci_autopi/BELL-QUEUE.md"
rm "$ci_autopi/release.json"
bash "$bell"
assert_no_cancellations
printf '%s\n' '{"steps":[{"step":"release fixture","status":"done"}]}' > "$ci_autopi/release.json"
rm -f "$ci_autopi/pr-run-snapshot.json"
bash "$bell"
assert_no_cancellations
grep -Fq 'stale-main-ci-verdict-unknown' "$ci_autopi/BELL-QUEUE.md"
publish_ci_snapshot

# A candidate retained during ancestry lookup is rechecked before cancel.
export BELL_TEST_TRAIN_DURING_SCAN="$old_sha"
bash "$bell"
[[ "$(cat "$BELL_TEST_CANCELED")" == $'102\n103' ]]
rm "$BELL_TEST_CANCELED"
unset BELL_TEST_TRAIN_DURING_SCAN
rm -f "$ci_autopi/release-train.json"
printf '%s\n' '{"units":[]}' > "$ci_autopi/units.json"

# A configured run-release state ledger provides real candidate identity.
export AGENT_HOME="$tmp/release-agent"
mkdir -p "$AGENT_HOME/state"
jq -n --arg sha "$old_sha" --arg head "$batch_sha" \
  '{release_candidate:{status:"selected",sha:$sha,head_sha:$head}}' > "$AGENT_HOME/state/42.json"
printf '%s\n' '{"steps":[{"step":"display-only release note","status":"pending"}]}' > "$ci_autopi/release.json"
bash "$bell"
[[ "$(cat "$BELL_TEST_CANCELED")" == '103' ]]
rm "$BELL_TEST_CANCELED"
printf '{bad\n' > "$AGENT_HOME/state/42.json"
bash "$bell"
assert_no_cancellations
unset AGENT_HOME

# release_train.sh is another authoritative publisher. Pending states retain
# the source candidate; build_run is an infra identity, not a the product CI run ID.
for train_status in building deploying held blocked-credentials deferred-busy; do
  jq -n --arg status "$train_status" --arg sha "$old_sha" \
    '{status:$status,candidate:$sha,build_run:102,released_sha:$sha,released_at:"2026-10-19T00:00:00Z"}' > "$ci_autopi/release-train.json"
  bash "$bell"
  [[ "$(cat "$BELL_TEST_CANCELED")" == $'102\n103' ]]
  rm "$BELL_TEST_CANCELED"
done

# Ended train attempts retain historical candidate/build_run fields. They must
# not keep unrelated main CI forever, even if the human checklist is stale.
for train_status in released failed built no-image-change; do
  jq -n --arg status "$train_status" --arg sha "$old_sha" \
    '{status:$status,candidate:$sha,build_run:102,released_sha:$sha,failed_sha:$sha}' > "$ci_autopi/release-train.json"
  bash "$bell"
  [[ "$(cat "$BELL_TEST_CANCELED")" == $'101\n102\n103' ]]
  rm "$BELL_TEST_CANCELED"
done

# Train and run-release ledgers combine their protections, while a started job
# remains protected even when its SHA is not retained by either release owner.
export AGENT_HOME="$tmp/release-agent"
jq -n --arg sha "$batch_sha" '{release_candidate:{status:"selected",sha:$sha}}' > "$AGENT_HOME/state/42.json"
jq -n --arg sha "$base_sha" '{status:"deploying",candidate:$sha,build_run:101}' > "$ci_autopi/release-train.json"
export BELL_TEST_JOBS_RUN=101 BELL_TEST_JOBS_JSON='[{"status":"completed"},{"status":"queued"}]'
bash "$bell"
assert_no_cancellations
jq '.status="released"' "$ci_autopi/release-train.json" > "$tmp/train-released.json"
mv "$tmp/train-released.json" "$ci_autopi/release-train.json"
bash "$bell"
[[ "$(cat "$BELL_TEST_CANCELED")" == '103' ]]
rm "$BELL_TEST_CANCELED"
unset AGENT_HOME BELL_TEST_JOBS_RUN BELL_TEST_JOBS_JSON

# The final candidate reread includes a train started after ancestry lookup.
export BELL_TEST_TRAIN_DURING_SCAN="$old_sha"
bash "$bell"
[[ "$(cat "$BELL_TEST_CANCELED")" == $'102\n103' ]]
rm "$BELL_TEST_CANCELED"
unset BELL_TEST_TRAIN_DURING_SCAN

# Unknown, malformed, or unbound active train records hold cancellation.
for invalid_train in '{"status":"unknown"}' '{"status":"building"}' '{bad'; do
  printf '%s\n' "$invalid_train" > "$ci_autopi/release-train.json"
  bash "$bell"
  assert_no_cancellations
done

# Check-only also leaves a valid train and the complete runtime byte-identical.
jq -n --arg sha "$old_sha" '{status:"building",candidate:$sha,build_run:102}' > "$ci_autopi/release-train.json"
cp -R "$ci_autopi" "$tmp/train-check-only-before"
bash "$bell" --check-only > "$tmp/train-check-only.out"
assert_no_cancellations
diff -qr "$ci_autopi" "$tmp/train-check-only-before" >/dev/null

# A medium bell event uses the real upsert helper: first sighting creates one
# incident issue, and a repeated event appends evidence to that open issue.
incident_autopi="$tmp/incident-autopi"
incident_supervisor="$tmp/incident-supervisor"
incident_bin="$tmp/incident-bin"
mkdir -p "$incident_autopi/alerts" "$incident_supervisor" "$incident_bin"
cat > "$incident_autopi/config.json" <<'JSON'
{"bell":{"enabled":true,"dedup_minutes":30}}
JSON
printf 'window.DASH={};\n' > "$incident_autopi/dashboard.data.js"
incident_tick="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf '[%s] tick done units=0 live=0\n' "$incident_tick" > "$incident_autopi/scheduler.log"
printf '%s\n' '{"units":[]}' > "$incident_autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$incident_autopi/workers.json"
cat > "$incident_supervisor/advisor-verdicts-stale.json" <<'JSON'
[{"n":1,"verdict":"FIX","reason":"fixture problem"}]
JSON
touch -d "@$(( $(date +%s) - 200000 ))" "$incident_supervisor/advisor-verdicts-stale.json"
jq -n '{monitor_initialized:true,scheduler_lines:1,alert_mtimes:{},merge_events:{},signatures:{},pending:[]}' \
  > "$incident_autopi/bell-state.json"
cat > "$incident_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$INCIDENT_GH_CALLS"
case "${1:-}:${2:-}" in
  label:list)
    while IFS= read -r label; do printf '%s\n' "$label"; done < "$INCIDENT_LABELS"
    ;;
  label:create)
    label="${3:?}"
    grep -qx -- "$label" "$INCIDENT_LABELS" || printf '%s\n' "$label" >> "$INCIDENT_LABELS"
    ;;
  api:--method)
    jq -c '[.]' "$INCIDENT_ISSUES"
    ;;
  api:repos/*/issues/*/sub_issues)
    echo '{}'
    ;;
  api:repos/*/issues/*)
    echo 501000
    ;;
  issue:create)
    title=""; body_file=""; previous=""; labels=()
    for arg in "$@"; do
      case "$previous" in
        --title) title="$arg" ;;
        --body-file) body_file="$arg" ;;
        --label) labels+=("$arg") ;;
      esac
      previous="$arg"
    done
    number="$(cat "$INCIDENT_NEXT_NUMBER")"
    printf '%s\n' "$((number + 1))" > "$INCIDENT_NEXT_NUMBER"
    labels_json="$(printf '%s\n' "${labels[@]}" | jq -R . | jq -s 'map({name:.})')"
    jq --argjson number "$number" --arg title "$title" --argjson labels "$labels_json" --rawfile body "$body_file" \
      '. + [{number:$number,title:$title,body:$body,state:"OPEN",labels:$labels}]' "$INCIDENT_ISSUES" > "$INCIDENT_ISSUES.tmp"
    mv "$INCIDENT_ISSUES.tmp" "$INCIDENT_ISSUES"
    printf 'https://github.com/test/repo/issues/%s\n' "$number"
    ;;
  issue:view)
    jq -ce --argjson number "${3:?}" '[.[] | select(.number==$number)][0]' "$INCIDENT_ISSUES"
    ;;
  issue:edit)
    echo '{}'
    ;;
  issue:comment)
    number="${3:?}"; body_file=""; previous=""
    for arg in "$@"; do
      [[ "$previous" != --body-file ]] || body_file="$arg"
      previous="$arg"
    done
    jq -cn --argjson number "$number" --rawfile body "$body_file" '{number:$number,body:$body}' >> "$INCIDENT_COMMENTS"
    ;;
  *) echo "unexpected incident-test gh call: $*" >&2; exit 91 ;;
esac
SH
chmod +x "$incident_bin/gh"
cat > "$incident_bin/timeout" <<'SH'
#!/usr/bin/env bash
while [[ "${1:-}" == --foreground || "${1:-}" == --kill-after=* ]]; do shift; done
[[ "${1:-}" =~ ^[0-9]+s?$ ]] && shift
exec "$@"
SH
chmod +x "$incident_bin/timeout"
printf 'ready-for-agent\n' > "$tmp/incident-labels"
printf '[]\n' > "$tmp/incident-issues.json"
: > "$tmp/incident-comments.jsonl"
: > "$tmp/incident-gh-calls.log"
printf '6100\n' > "$tmp/incident-next-number"
export INCIDENT_LABELS="$tmp/incident-labels" INCIDENT_ISSUES="$tmp/incident-issues.json"
export INCIDENT_COMMENTS="$tmp/incident-comments.jsonl" INCIDENT_GH_CALLS="$tmp/incident-gh-calls.log"
export INCIDENT_NEXT_NUMBER="$tmp/incident-next-number"
cat > "$tmp/incident-roadmap.json" <<'JSON'
{"roots":[{"number":900,"title":"the product roadmap","state":"open","labels":["roadmap"],"children":[{"number":910,"title":"开发流水线与运行稳定","state":"open","milestone":"开发流水线与运行稳定","labels":["roadmap-theme"],"children":[{"number":912,"title":"Incident intake","state":"open","labels":["roadmap-epic"],"children":[]}]}]}]}
JSON
export BELL_AUTOPI_DIR="$incident_autopi" BELL_SUPERVISOR_DIR="$incident_supervisor"
export MAC_AUTOPILOT_ROOT="$MAC_AUTOPILOT_ENV_ROOT" ZF_ENGINE_DIR="$MAC_AUTOPILOT_ENV_ROOT/engine"
export ZF_REPO_DIR="$MAC_AUTOPILOT_ENV_ROOT" ZF_REPO=test/repo ZF_GH_REPO=test/repo
export ZF_ISSUE_LOCK_DIR="$tmp/incident-locks" AGENT_HOME="$tmp/incident-agent"
export ZF_ROADMAP_TREE_CACHE_FILE="$tmp/incident-roadmap.json"
export PATH="$incident_bin:$PATH" BELL_TEST_NETWORK=green BELL_STALE_CI_DISABLE=1
bash "$bell" > "$tmp/incident-first.out" 2>&1
[[ "$(jq 'length' "$INCIDENT_ISSUES")" == 1 ]] || {
  echo 'bell.test.sh: medium incident event did not create exactly one issue' >&2
  cat "$tmp/incident-first.out" "$incident_autopi/bell-state.json" "$incident_autopi/bell.log" "$INCIDENT_GH_CALLS" >&2
  exit 1
}
jq -e '.[0].body | contains("<!-- vecta-incident-class:verdicts-backlog-stale -->")
  and contains("First seen:") and contains("Occurrence count: 1") and contains("advisor FIX backlog")' \
  "$INCIDENT_ISSUES" >/dev/null
jq -e '.[0].labels | any(.name=="incident") and any(.name=="pipeline-system") and any(.name=="ready-for-agent")' \
  "$INCIDENT_ISSUES" >/dev/null
grep -Fxq incident "$INCIDENT_LABELS"
grep -Fxq pipeline-system "$INCIDENT_LABELS"
bash "$bell"
[[ "$(jq 'length' "$INCIDENT_ISSUES")" == 1 ]]
[[ "$(wc -l < "$INCIDENT_COMMENTS" | tr -d ' ')" == 1 ]]
jq -se '.[0].number == 6100 and (.[0].body | contains("Occurrence count: 2") and contains("advisor FIX backlog"))' \
  "$INCIDENT_COMMENTS" >/dev/null
[[ "$(grep -c '^issue create ' "$INCIDENT_GH_CALLS")" == 1 ]]
grep -Fq 'incident filed class=verdicts-backlog-stale count=2' "$incident_autopi/bell.log"

watch_home="$tmp/advisor-watch-home"
mkdir -p "$watch_home/logs"
watch_now="$(python3 -c 'import time; print(int(time.time()))')"
watch_old="$(python3 - "$watch_now" <<'PY'
from datetime import datetime, timezone
import sys
print(datetime.fromtimestamp(int(sys.argv[1]) - 1860, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"
jq -n --argjson started "$((watch_now - 1860))" '{job:{job_id:"advisor-batch-fixture",started_at:$started}}' > "$watch_home/advisor-batch.json"
jq -n --arg at "$watch_old" '{recorded_at:$at}' > "$watch_home/logs/advisor-batch-fixture.result.json"
python3 "$script_dir/advisor-batch-watchdog.py" "$watch_home" "$watch_now"
[[ "$(grep -c 'ADVISOR-BATCH-NO-RESULT' "$watch_home/logs/head-watch.alerts")" == 1 ]]
python3 "$script_dir/advisor-batch-watchdog.py" "$watch_home" "$watch_now"
[[ "$(grep -c 'ADVISOR-BATCH-NO-RESULT' "$watch_home/logs/head-watch.alerts")" == 1 ]]
watch_recent="$(python3 - "$watch_now" <<'PY'
from datetime import datetime, timezone
import sys
print(datetime.fromtimestamp(int(sys.argv[1]) - 1740, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"
jq -n --arg at "$watch_recent" '{recorded_at:$at}' > "$watch_home/logs/advisor-batch-fixture.result.json"
python3 "$script_dir/advisor-batch-watchdog.py" "$watch_home" "$watch_now"
[[ "$(grep -c 'ADVISOR-BATCH-NO-RESULT' "$watch_home/logs/head-watch.alerts")" == 1 ]]

empty_watch_home="$tmp/advisor-watch-empty"
mkdir -p "$empty_watch_home/logs"
jq -n --argjson started "$((watch_now - 1740))" '{job:{job_id:"advisor-batch-empty-history",started_at:$started}}' > "$empty_watch_home/advisor-batch.json"
python3 "$script_dir/advisor-batch-watchdog.py" "$empty_watch_home" "$watch_now"
[[ ! -e "$empty_watch_home/logs/head-watch.alerts" ]]
jq -n --argjson started "$((watch_now - 1860))" '{job:{job_id:"advisor-batch-empty-history",started_at:$started}}' > "$empty_watch_home/advisor-batch.json"
python3 "$script_dir/advisor-batch-watchdog.py" "$empty_watch_home" "$watch_now"
[[ "$(grep -c 'ADVISOR-BATCH-NO-RESULT' "$empty_watch_home/logs/head-watch.alerts")" == 1 ]]

echo 'bell.test.sh: PASS'
