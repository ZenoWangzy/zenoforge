#!/usr/bin/env bash
# harvest_scope_stop: harvest stops a finished worker's own run-p scope when processes are left in it; never a live leader's.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
sup="$test_env_root/supervisor"
mkdir -p "$sup/autopi/alerts" "$test_env_root/root" "$test_env_root/bin"
cp "$script_dir/config.template.json" "$sup/autopi/config.json"
printf '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$test_env_root/root" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" AUTOPI_TEST_LIBRARY_ONLY=true
unset GH_TOKEN GITHUB_TOKEN
source "$script_dir/scheduler.sh"
tick_prs_prime() { :; }
session_usage_for_id() { echo null; }
blocked_on_of() { :; }
cancel_unit_runs() { :; }

# Stub systemctl: records its arguments; the real user manager is never touched.
calls="$test_env_root/systemctl.calls"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$calls" > "$test_env_root/bin/systemctl"
chmod +x "$test_env_root/bin/systemctl"
export PATH="$test_env_root/bin:$PATH"
export HARVEST_CGROUP_ROOT="$test_env_root/cgroup"
scope=run-p4242-i1.scope
# The real layout (worker-scope.sh --slice=zf-workers.slice, nested in zf.slice); an app.slice fixture hid row 986.
procs="$HARVEST_CGROUP_ROOT/user.slice/user-$UID.slice/user@$UID.service/zf.slice/zf-workers.slice/$scope/cgroup.procs"
mkdir -p "${procs%/*}"

fail() { echo "harvest-scope-stop.test.sh: $*" >&2; exit 1; }
: > "$LOG"

# A finished review worker: its leader has exited and its report is on disk, so harvest_workers finishes it.
dead_pid="$(bash -c 'exit 0' & echo $!)"; wait "$dead_pid" 2>/dev/null || :
seed_finished() { # leftover-pids-content
  printf '%s' "$1" > "$procs"
  printf 'VERDICT: INPUT_INCOMPLETE\n' > "$sup/report.md"
  touch "$sup/worker.log"
  printf '{"units":[{"id":"issue-1","stage":"review","history":[]}]}' > "$UNITS"
  jq -n --argjson pid "$dead_pid" --arg scope "$scope" --arg wd "$test_env_root" \
    '{workers:[{pid:$pid,pid_start:1,process_group:$pid,claim_owner:"test-owner",unit:"issue-1",type:"review",provider:"zcode",log:"worker.log",report:"report.md",started:"2026-11-14T00:00:00Z",scope:$scope,workdir:$wd}]}' > "$WORKERS"
  : > "$calls"; : > "$LOG"
}

# 1. Leftover pid in a finished worker's scope: one stop call and the log line.
seed_finished "4343
"
harvest_workers
jq -e '.workers[0].harvested == true' "$WORKERS" >/dev/null || fail 'dead worker was not harvested'
[[ "$(wc -l < "$calls")" == 1 ]] || fail "expected one systemctl call, got $(wc -l < "$calls")"
grep -Fxq -- "--user stop $scope" "$calls" || fail 'systemctl was not asked to stop the worker scope'
grep -Fq "harvest scope stop unit=issue-1 scope=$scope leftover=1 rc=0" "$LOG" || fail 'no harvest scope stop log line with leftover=1'
echo 'ok - harvested worker with leftover pid: one stop and leftover=1 logged'

# 2. Empty scope: no stop call.
seed_finished ""
harvest_workers
jq -e '.workers[0].harvested == true' "$WORKERS" >/dev/null || fail 'dead worker was not harvested (empty scope)'
[[ ! -s "$calls" ]] || fail 'empty scope was stopped'
! grep -q 'harvest scope stop' "$LOG" || fail 'empty scope logged a stop'
echo 'ok - empty scope: no stop call'

# 3. Live leader: harvest_scope_stop never stops its scope, even with a process in it.
sleep 60 & live_pid=$!
trap 'kill "$live_pid" 2>/dev/null || :; rm -rf "$test_env_root"' EXIT
live_start="$(coord_process_start_ticks "$live_pid")"
printf '%s\n' "$live_pid" > "$procs"
: > "$calls"
live="$(jq -cn --argjson pid "$live_pid" --argjson start "$live_start" --arg scope "$scope" \
  '{pid:$pid,pid_start:$start,process_group:$pid,unit:"issue-1",scope:$scope}')"
harvest_scope_stop "$live"
[[ ! -s "$calls" ]] || fail 'live leader scope was stopped'
echo 'ok - live leader: no stop call'
