#!/usr/bin/env bash
# Recurrence guards for the 2026-11-04 bell CPU work: bounded pending state,
# single-pass resolution marking, bell.log rotation, and the ci_protection
# shape check that keeps a silently empty python heredoc (a full /tmp makes
# bash fail the heredoc temp file while python still exits 0) away from
# jq --argjson ("invalid JSON text passed to --argjson", bell-loop.out).
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
unset AUTOPILOT_LOOP_UNIT

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
bell="$script_dir/bell.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/bell-scan-cost.XXXXXX")"
bin="$tmp/bin"
mkdir -p "$bin"
fixture_root="$tmp/repo"
mkdir -p "$fixture_root/engine/mac-autopilot" "$fixture_root/engine/night"
export MAC_AUTOPILOT_ROOT="$fixture_root"
trap 'rm -rf "$tmp"' EXIT

cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$bin/pkill" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$bin/timeout" <<'SH'
#!/usr/bin/env bash
[[ "$1" == --foreground ]] && exit 0 # platform_require's GNU-timeout probe (macOS)
shift $(( $# > 1 ? 1 : 0 ))
exec "$@"
SH
cat > "$bin/git" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == -C ]]; then shift 2; fi
case "$1" in
  ls-remote) printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\trefs/heads/main\n'; exit 0 ;;
  merge-base) exit 0 ;;
  remote) printf 'https://github.com/example-maintainer/example-repo.git\n'; exit 0 ;;
  *) exit 2 ;;
esac
SH
cat > "$bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BELL_SCAN_COST_GH_CALLS"
exit 1
SH
chmod +x "$bin/"*
export PATH="$bin:$PATH"
export BELL_SCAN_COST_GH_CALLS="$tmp/gh-calls.log"
export BELL_SUPERVISOR_DIR="$tmp/supervisor"
export AGENT_HOME="$tmp/agent-home"
export BELL_STALE_CI_DISABLE=1
mkdir -p "$BELL_SUPERVISOR_DIR" "$AGENT_HOME"

fresh_tick="$(python3 - <<'PY'
from datetime import datetime,timezone,timedelta
print((datetime.now(timezone.utc)-timedelta(seconds=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

# --- Scenario A: bounded pending, single-pass resolution, bell.log rotation ---
autopi="$tmp/autopi-a"
mkdir -p "$autopi/alerts"
printf '%s\n' '{"bell":{"enabled":true,"dedup_minutes":30},"incident":{"file_min_severity":"off"}}' > "$autopi/config.json"
printf 'window.DASH={};\n' > "$autopi/dashboard.data.js"
printf '[%s] tick done units=0 live=0 secs=1\n' "$fresh_tick" > "$autopi/scheduler.log"
touch "$autopi/scheduler.log"
printf '%s\n' '{"units":[]}' > "$autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$autopi/workers.json"

# 250 queued fixtures plus three resolvable entries at the front: the
# resolution pass runs before the tail cap, so resolved entries must survive
# as done/failed even though the queued fixtures around them are dropped.
pending_json="$(python3 - <<'PY'
import json
pending=[]
pending.append({"id":"1700000097-x-1","signature":"res-both","raw_signature":"res-both","severity":"high","summary":"res-both","evidence":"res-both","needs_supervisor":False,"status":"queued"})
pending.append({"id":"1700000098-x-1","signature":"res-failed","raw_signature":"res-failed","severity":"high","summary":"res-failed","evidence":"res-failed","needs_supervisor":False,"status":"queued"})
pending.append({"id":"1700000099-x-1","signature":"res-done","raw_signature":"res-done","severity":"high","summary":"res-done","evidence":"res-done","needs_supervisor":False,"status":"queued"})
for i in range(250):
    pending.append({"id":"17000001%03d-x-1"%i,"signature":"cap-fixture-%d"%i,"raw_signature":"cap-fixture-%d"%i,"severity":"medium","summary":"cap-fixture-%d"%i,"evidence":"cap-fixture-%d"%i,"needs_supervisor":False,"status":"queued"})
print(json.dumps(pending))
PY
)"
jq -n --argjson pending "$pending_json" \
  '{monitor_initialized:true,scheduler_lines:1,alert_mtimes:{},merge_events:{},signatures:{},pending:$pending}' \
  > "$autopi/bell-state.json"
cat > "$autopi/BELL-RESOLUTION.md" <<'MD'
## 2026-10-20T00:00:00Z event_id: 1700000098-x-1 status: failed
Signature: res-failed

fixture failure text

## 2026-10-20T00:01:00Z event_id: 1700000097-x-1 status: failed
Signature: res-both

fixture failure text that also appears later as complete

## 2026-10-20T00:02:00Z event_id: 1700000097-x-1 status: complete
Signature: res-both

fixture complete text

## 2026-10-20T00:03:00Z event_id: 1700000099-x-1 status: complete
Signature: res-done

fixture complete text
MD

# bell.log above the rotation cap; the keep-marker sits in the retained tail.
export BELL_LOG_MAX_BYTES=20000
python3 - "$autopi/bell.log" <<'PY'
import sys
with open(sys.argv[1],"w") as f:
    for i in range(300):
        f.write("[2026-10-01T00:%02d:%02dZ] medium sig=%064d event_id=1700000000-1-1 action=queue=append fixture padding\n" % (i // 60, i % 60, i))
    f.write("[2026-10-01T00:59:59Z] medium sig=rotation-keepme event_id=1700000000-1-1 action=fixture\n")
PY

BELL_AUTOPI_DIR="$autopi" bash "$bell" 2> "$tmp/a.stderr"
jq -e '[.pending[] | select(.status == "queued")] | length == 200' "$autopi/bell-state.json" >/dev/null || {
  echo 'bell-scan-cost.test.sh: queued pending entries are not capped at 200' >&2; exit 1
}
jq -e '[.pending[] | select(.status == "queued" and (.raw_signature == "cap-fixture-49"))] | length == 0' "$autopi/bell-state.json" >/dev/null || {
  echo 'bell-scan-cost.test.sh: the oldest queued entries were not dropped' >&2; exit 1
}
jq -e '[.pending[] | select(.raw_signature == "cap-fixture-50" or .raw_signature == "cap-fixture-249")] | length == 2' "$autopi/bell-state.json" >/dev/null || {
  echo 'bell-scan-cost.test.sh: the newest queued entries were not retained' >&2; exit 1
}
jq -e '[.pending[] | select(.id == "1700000097-x-1")][0].status == "done"' "$autopi/bell-state.json" >/dev/null || {
  echo 'bell-scan-cost.test.sh: an id marked both failed and complete must resolve as done (complete wins)' >&2; exit 1
}
jq -e '[.pending[] | select(.id == "1700000098-x-1")][0].status == "failed"' "$autopi/bell-state.json" >/dev/null || {
  echo 'bell-scan-cost.test.sh: failed resolution was not applied' >&2; exit 1
}
jq -e '[.pending[] | select(.id == "1700000099-x-1")][0].status == "done"' "$autopi/bell-state.json" >/dev/null || {
  echo 'bell-scan-cost.test.sh: complete resolution was not applied' >&2; exit 1
}
log_size="$(wc -c < "$autopi/bell.log" | awk '{print $1}')"
(( log_size <= BELL_LOG_MAX_BYTES )) || {
  echo 'bell-scan-cost.test.sh: bell.log was not capped' >&2; exit 1
}
head -n 1 "$autopi/bell.log" | grep -Fq 'bell.log rotated:' || {
  echo 'bell-scan-cost.test.sh: bell.log rotation marker missing' >&2; exit 1
}
grep -Fq 'rotation-keepme' "$autopi/bell.log" || {
  echo 'bell-scan-cost.test.sh: rotation dropped the retained tail' >&2; exit 1
}
if grep -q 'invalid JSON text' "$tmp/a.stderr"; then
  echo 'bell-scan-cost.test.sh: jq --argjson received invalid text' >&2; exit 1
fi
echo 'ok - pending capped, resolution applied in one pass, bell.log rotated'

# --- Scenario B: empty-but-successful ci_protection output must not reach --argjson ---
autopi_b="$tmp/autopi-b"
mkdir -p "$autopi_b/alerts"
cp "$autopi/config.json" "$autopi_b/config.json"
printf 'window.DASH={};\n' > "$autopi_b/dashboard.data.js"
printf '[%s] tick done units=0 live=0 secs=1\n' "$fresh_tick" > "$autopi_b/scheduler.log"
touch "$autopi_b/scheduler.log"
printf '%s\n' '{"units":[]}' > "$autopi_b/units.json"
printf '%s\n' '{"workers":[]}' > "$autopi_b/workers.json"
jq -n '{monitor_initialized:true,scheduler_lines:1,alert_mtimes:{},merge_events:{},signatures:{},pending:[]}' > "$autopi_b/bell-state.json"
jq -n '{schema:1,tick:"2026-11-04T00:00:00Z",main_head:"1111111111111111111111111111111111111111",prs:[],unfinished_runs:[],infra_runs:[],main_runs:{CI:[
  {databaseId:900001,headSha:"1111111111111111111111111111111111111111",status:"queued",createdAt:"2026-11-04T16:00:00Z"},
  {databaseId:900002,headSha:"2222222222222222222222222222222222222222",status:"queued",createdAt:"2026-11-04T16:01:00Z"},
  {databaseId:900003,headSha:"3333333333333333333333333333333333333333",status:"queued",createdAt:"2026-11-04T16:02:00Z"}
],"Pipeline suites":[]}}' > "$autopi_b/pr-run-snapshot.json"

# A python whose program comes from a heredoc prints nothing and exits 0: the
# exact shape of a failed heredoc temp file on a full /tmp (2026-11-04).
cat > "$bin/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-" ]]; then exit 0; fi
exec /usr/bin/python3 "$@"
SH
chmod +x "$bin/python3"

( export BELL_AUTOPI_DIR="$autopi_b"; unset BELL_STALE_CI_DISABLE
  bash "$bell" 2> "$tmp/b.stderr" )
grep -Fq 'stale-main-ci-protection-unknown' "$autopi_b/BELL-QUEUE.md" || {
  echo 'bell-scan-cost.test.sh: empty ci_protection output must keep the queue (protection-unknown)' >&2; exit 1
}
if grep -q 'invalid JSON text' "$tmp/b.stderr"; then
  echo 'bell-scan-cost.test.sh: empty ci_protection output reached jq --argjson' >&2; exit 1
fi
[[ ! -s "$BELL_SCAN_COST_GH_CALLS" ]] || {
  echo 'bell-scan-cost.test.sh: gh was called during an unknown-protection scan' >&2; exit 1
}
echo 'ok - empty ci_protection output reports protection-unknown without an argjson error'
