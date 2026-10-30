#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
unset AUTOPILOT_LOOP_UNIT AGENT_HOME

# Bell fixtures have their own repo/runtime and no external side effects.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
bell="$script_dir/bell.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
autopi="$tmp/autopi"
fixture_root="$tmp/repo"
bin="$tmp/bin"
mkdir -p "$autopi/alerts" "$fixture_root/engine/mac-autopilot" "$bin" "$tmp/supervisor"
cat > "$autopi/config.json" <<'JSON'
{"bell":{"enabled":true,"notify":false,"auto_supervisor":false,"dedup_minutes":30}}
JSON
touch -t 202001010000 "$autopi/dashboard.data.js"
printf '[%s] scheduler tick\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$autopi/scheduler.log"
printf '%s\n' '{"units":[]}' > "$autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$autopi/workers.json"
cat > "$bin/git" <<'SH'
#!/usr/bin/env bash
[[ "$1" == -C ]] && shift 2
case "$1" in
  ls-remote) printf 'deadbeef\trefs/heads/main\n' ;;
  merge-base) exit 0 ;;
  *) exit 2 ;;
esac
SH
cat > "$bin/timeout" <<'SH'
#!/usr/bin/env bash
[[ "$1" == --foreground ]] && exit 0 # platform_require's GNU-timeout probe (macOS)
[[ "$1" == 8 ]] || exit 2
shift
exec "$@"
SH
for command in gh pkill nohup osascript notify-send claude systemctl; do
  cat > "$bin/$command" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$BELL_TEST_UNEXPECTED_ACTIONS"
exit 99
SH
done
chmod +x "$bin/"*

export MAC_AUTOPILOT_ROOT="$fixture_root" BELL_AUTOPI_DIR="$autopi" BELL_SUPERVISOR_DIR="$tmp/supervisor"
export BELL_TEST_UNEXPECTED_ACTIONS="$tmp/unexpected-actions.log" BELL_STALE_CI_DISABLE=1
export PATH="$bin:$PATH"
bash "$bell"
jq -e '[.pending[].raw_signature] == ["dashboard-data-stale"]' "$autopi/bell-state.json" >/dev/null
grep -Fq 'dashboard-data-stale' "$autopi/BELL-QUEUE.md"
count="$(wc -l < "$autopi/BELL-QUEUE.md" | awk '{print $1}')"

bash "$bell"   # The same stale heartbeat deduplicates.
[[ "$(wc -l < "$autopi/BELL-QUEUE.md" | awk '{print $1}')" == "$count" ]]
# S12 keeps running runs, queued runs with started shards, and each workflow's
# newest waiting run. Candidate records and replacement SHAs prove obsolescence.
s12="$tmp/s12"; mkdir -p "$s12/autopi/alerts" "$s12/root/engine/night" "$s12/root/engine/mac-autopilot" "$s12/bin" "$s12/supervisor"
cp "$autopi/config.json" "$s12/autopi/config.json"
printf '[%s] scheduler tick\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$s12/autopi/scheduler.log"
printf '%s\n' '{"units":[]}' > "$s12/autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$s12/autopi/workers.json"
printf '%s\n' '{"steps":[]}' > "$s12/autopi/release.json"
printf 'window.DASH={};\n' > "$s12/autopi/dashboard.data.js"
cat > "$s12/root/engine/night/main-ci-recovery.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$S12_CANCELS"
SH
cat > "$s12/ci.json" <<'JSON'
[
  {"databaseId":1,"headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","status":"in_progress","createdAt":"2026-10-19T01:00:00Z"},
  {"databaseId":7,"headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","status":"queued","createdAt":"2026-10-19T01:30:00Z"},
  {"databaseId":2,"headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","status":"queued","createdAt":"2026-10-19T02:00:00Z"},
  {"databaseId":3,"headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"queued","createdAt":"2026-10-19T03:00:00Z"},
  {"databaseId":4,"headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"completed","createdAt":"2026-10-19T04:00:00Z"}
]
JSON
cat > "$s12/suites.json" <<'JSON'
[
  {"databaseId":5,"headSha":"cccccccccccccccccccccccccccccccccccccccc","status":"pending","createdAt":"2026-10-19T01:00:00Z"},
  {"databaseId":6,"headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"pending","createdAt":"2026-10-19T02:00:00Z"}
]
JSON
cat > "$s12/bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == "run view" ]]; then
  jq -s -c --argjson id "$3" 'add | .[] | select(.databaseId==$id)
    | .jobs=(if .databaseId==2 then [{status:"completed"},{status:"in_progress"},{status:"queued"}] else [{status:"queued"}] end)' "$S12_CI_RUNS" "$S12_SUITES_RUNS"
  exit
fi
exit 2
SH
chmod +x "$s12/bin/gh"
# bell reads run lists only from the scheduler snapshot
( source "$(dirname "$bell")/runtime-env.sh"; pr_run_snapshot_publish "$s12/autopi" "[]" "[]" "$(cat "$s12/ci.json")" "$(cat "$s12/suites.json")" "[]" "" )
export S12_CI_RUNS="$s12/ci.json" S12_SUITES_RUNS="$s12/suites.json"
S12_CANCELS="$s12/cancels" BELL_STALE_CI_DISABLE=0 MAC_AUTOPILOT_ROOT="$s12/root" BELL_AUTOPI_DIR="$s12/autopi" BELL_SUPERVISOR_DIR="$s12/supervisor" PATH="$s12/bin:$PATH" bash "$bell" --check-only >/dev/null
[[ ! -e "$s12/cancels" ]] || { echo "S12 cancelled runs in --check-only: $(cat "$s12/cancels")" >&2; exit 1; }
S12_CANCELS="$s12/cancels" BELL_STALE_CI_DISABLE=0 MAC_AUTOPILOT_ROOT="$s12/root" BELL_AUTOPI_DIR="$s12/autopi" BELL_SUPERVISOR_DIR="$s12/supervisor" PATH="$s12/bin:$PATH" bash "$bell"
[[ "$(cat "$s12/cancels" | tr '\n' ' ')" == "cancel-run 7 cancel-run 5 " ]] || { echo "S12 cancelled the wrong runs: $(cat "$s12/cancels" 2>/dev/null)" >&2; exit 1; }
# 配置里的 false 必须生效（jq // 会把 false 当缺省）：auto_supervisor:false 时绝不起调查锁。
[[ ! -e "$autopi/.bell-supervisor.lock" && ! -e "$s12/autopi/.bell-supervisor.lock" && ! -e "$autopi/BELL-SUPERVISOR.log" ]] || { echo 'auto_supervisor:false ignored' >&2; exit 1; }
# 慢 tick（夹具里唯一可能的事件就是 stale tick）：日志超过 6 分钟没新行，但 tick 锁的持有进程还活着 → 不判 stale、不重启；锁没了才判 stale
st="$tmp/slow-tick"; mkdir -p "$st/alerts" "$st/.scheduler.lock"; cp "$autopi/config.json" "$st/config.json"
# Keep dashboard heartbeat evidence healthy so only the slow tick can raise this fixture.
cp "$s12/autopi/units.json" "$s12/autopi/workers.json" "$s12/autopi/release.json" "$s12/autopi/dashboard.data.js" "$st/"
printf '[2020-01-01T00:00:00Z] tick done units=1 live=1\n' > "$st/scheduler.log"
touch -t 202001010000 "$st/scheduler.log"
echo "$$" > "$st/.scheduler.lock/pid"
BELL_AUTOPI_DIR="$st" bash "$bell" --check-only > "$st/out" 2>&1 || :
! grep -q '^candidate severity=high' "$st/out" || { echo 'slow tick with a live lock holder was judged stale' >&2; exit 1; }
rm -rf "$st/.scheduler.lock"
BELL_AUTOPI_DIR="$st" bash "$bell" --check-only > "$st/out" 2>&1 || :
grep -q '^candidate severity=high' "$st/out" || { echo 'tick with no lock holder not judged stale' >&2; exit 1; }


rm "$autopi/dashboard.data.js"
bash "$bell"
grep -Fq 'dashboard-data-missing' "$autopi/BELL-QUEUE.md"
[[ ! -e "$BELL_TEST_UNEXPECTED_ACTIONS" ]]
echo 'bell-drift-sigs.test.sh: PASS'
