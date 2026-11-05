#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
sup="$test_env_root/supervisor"
mkdir -p "$sup/autopi/alerts" "$test_env_root/root"
cp "$script_dir/config.template.json" "$sup/autopi/config.json"
printf '{"units":[{"id":"issue-1","stage":"review","history":[]}]}' > "$sup/autopi/units.json"
printf '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$test_env_root/root" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" AUTOPI_TEST_LIBRARY_ONLY=true
unset GH_TOKEN GITHUB_TOKEN
source "$script_dir/scheduler.sh"
tick_prs_prime() { :; }
session_usage_for_id() { echo null; }
blocked_on_of() { :; }
cancel_unit_runs() { :; }
# The group leader exits before its child writes the report.
setsid bash -c 'bash -c '\''while [[ ! -e "$1/go" ]]; do sleep 0.05; done; printf "VERDICT: INPUT_INCOMPLETE\n" > "$1/report.md"'\'' _ "$1" & echo $! > "$1/backend.pid"' _ "$sup" < /dev/null > /dev/null 2>&1 &
pid=$!
backend=''
cleanup() { [[ -z "$backend" ]] || kill "$backend" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; }
trap cleanup EXIT
wait "$pid"
backend="$(cat "$sup/backend.pid")"
jq -n --argjson pid "$pid" '{workers:[{pid:$pid,pid_start:1,process_group:$pid,claim_owner:"test-owner",unit:"issue-1",type:"review",provider:"zcode",log:"worker.log",report:"report.md",started:"2026-11-04T00:00:00Z",harvested:false}]}' > "$WORKERS"
touch "$sup/worker.log"
harvest_workers
jq -e '.workers[0].harvested == false' "$WORKERS" >/dev/null || { echo 'live backend harvested as dead' >&2; exit 1; }
coord_scheduler_live_worker issue-1 '' || { echo 'live backend missed by dispatch guard' >&2; exit 1; }
refresh_live_worker_cache
[[ "$LIVE_WORKER_CACHE_TOTAL" == 1 ]] || { echo 'live backend missed by capacity cache' >&2; exit 1; }
claim="$(jq -cn --argjson pid "$pid" '{owner_kind:"scheduler-worker",owner:"test-owner",unit:"issue-1",stage:"review",pid:$pid,pid_start:1}')"
if coord_on_expire "$claim"; then echo 'live backend claim expired' >&2; exit 1; fi
jq -e '.units[0].history | all(.stage != "worker-no-output" and .stage != "fresh-session-retry")' "$UNITS" >/dev/null
recover_orphans
jq -e '.units[0].stage == "review"' "$UNITS" >/dev/null
: > "$sup/go"
for _ in {1..100}; do [[ -s "$sup/report.md" ]] && break; sleep 0.05; done
[[ -s "$sup/report.md" ]] || { echo 'backend did not write report' >&2; exit 1; }
for _ in {1..100}; do [[ "$(ps -p "$backend" -o stat= 2>/dev/null || :)" =~ ^[[:space:]]*Z ]] && break; ! kill -0 "$backend" 2>/dev/null && break; sleep 0.05; done
harvest_workers
jq -e '.workers[0].harvested == true' "$WORKERS" >/dev/null
jq -e '.units[0] | .stage == "blocked-external" and .review_report == "report.md" and all(.history[]; .stage != "worker-no-output" and .stage != "fresh-session-retry")' "$UNITS" >/dev/null
echo 'ok - late review report waits for backend and is harvested'

# Legacy stdout wrappers have a start identity but no group recorded.
bash -c 'exec -a harmless-wrapper sleep 600' &
legacy_pid=$!
backend="$legacy_pid"
legacy_start="$(coord_process_start_ticks "$legacy_pid")"
legacy="$(jq -cn --argjson pid "$legacy_pid" --argjson start "$legacy_start" '{pid:$pid,pid_start:$start,provider:"zcode"}')"
harvest_worker_alive "$legacy" || { echo 'live legacy wrapper missed' >&2; exit 1; }
kill "$legacy_pid"
wait "$legacy_pid" 2>/dev/null || :
backend=''
printf '{"units":[{"id":"issue-2","stage":"review","history":[]}]}' > "$UNITS"
jq -n --argjson pid "$legacy_pid" --argjson start "$legacy_start" '{workers:[{pid:$pid,pid_start:$start,claim_owner:"legacy-owner",unit:"issue-2",type:"review",provider:"zcode",log:"worker.log",report:"legacy.md",started:"2026-11-04T00:00:00Z",harvested:false}]}' > "$WORKERS"
claim="$(jq -cn --argjson pid "$legacy_pid" --argjson start "$legacy_start" '{owner_kind:"scheduler-worker",owner:"legacy-owner",unit:"issue-2",stage:"review",pid:$pid,pid_start:$start}')"
if coord_on_expire "$claim"; then echo 'legacy claim expired before recheck' >&2; exit 1; fi
harvest_workers
jq -e '.workers[0] | .harvested == false and .no_output_check_after > 0' "$WORKERS" >/dev/null
coord_scheduler_live_worker issue-2 '' || { echo 'legacy grace missed by dispatch guard' >&2; exit 1; }
printf 'VERDICT: INPUT_INCOMPLETE\n' > "$sup/legacy.md"
harvest_workers
jq -e '.workers[0].harvested == false' "$WORKERS" >/dev/null
NOW_EPOCH=$((NOW_EPOCH + 301))
harvest_workers
jq -e '.workers[0].harvested == true' "$WORKERS" >/dev/null
jq -e '.units[0] | .stage == "blocked-external" and all(.history[]; .stage != "worker-no-output" and .stage != "fresh-session-retry")' "$UNITS" >/dev/null
echo 'ok - legacy wrapper identity and late report grace'

printf '{"units":[{"id":"issue-3","stage":"review","history":[]}]}' > "$UNITS"
jq -n '{workers:[{pid:999999999,unit:"issue-3",type:"review",provider:"zcode",log:"worker.log",report:"missing.md",started:"2026-11-04T00:00:00Z",harvested:false}]}' > "$WORKERS"
harvest_workers
NOW_EPOCH=$((NOW_EPOCH + 301))
harvest_workers
jq -e '.workers[0].harvested == true' "$WORKERS" >/dev/null
jq -e '[.units[0].history[] | select(.stage == "worker-no-output")] | length == 1' "$UNITS" >/dev/null
echo 'ok - legacy missing output is counted after grace'

# A claim with no pid and no ledger entry: the tick died before launch (free it) or after launch but before coord_renew (keep it).
# The launch wrapper records the worker's own pid in worker-<unit>.pid before exec; expiry reads only that file.
pidfile="$(worker_pidfile issue-1)"
printf '{"workers":[]}' > "$WORKERS"
claim='{"owner_kind":"scheduler-worker","owner":"never-launched","unit":"issue-1","stage":"repair"}'
rm -f "$pidfile"
coord_on_expire "$claim" || { echo 'never-launched claim wedged after expiry' >&2; exit 1; }
# A non-dumpable worker (as Codex makes itself) hides its /proc cwd and fds from us; kill -0 must still see it.
python3 -c 'import ctypes,time; ctypes.CDLL(None).prctl(4, 0, 0, 0, 0); time.sleep(60)' < /dev/null > /dev/null 2>&1 &
undumpable=$!
trap 'kill "$undumpable" 2>/dev/null || :; cleanup' EXIT
for _ in $(seq 100); do readlink "/proc/$undumpable/cwd" >/dev/null 2>&1 || break; sleep 0.05; done
! readlink "/proc/$undumpable/cwd" >/dev/null 2>&1 || { echo 'test worker did not become non-dumpable' >&2; exit 1; }
echo "$undumpable" > "$pidfile"
if coord_on_expire "$claim"; then echo 'claim with a live non-dumpable worker expired' >&2; exit 1; fi
[[ -e "$pidfile" ]] || { echo 'live worker pidfile was removed' >&2; exit 1; }
kill "$undumpable"; wait "$undumpable" 2>/dev/null || :
coord_on_expire "$claim" || { echo 'claim stayed held after its worker exited' >&2; exit 1; }
[[ ! -e "$pidfile" ]] || { echo 'dead worker pidfile not removed' >&2; exit 1; }
# A group that outlives its leader keeps the claim, as harvest_worker_alive does: its children are still writing.
setsid bash -c 'sleep 60 & exit 0' < /dev/null > /dev/null 2>&1 &
leader=$!
wait "$leader" 2>/dev/null || :
[[ ! -d "/proc/$leader" ]] && kill -0 -- "-$leader" 2>/dev/null || { echo 'test group did not outlive its leader' >&2; exit 1; }
echo "$leader" > "$pidfile"
if coord_on_expire "$claim"; then kill -- "-$leader" 2>/dev/null || :; echo 'claim with a live worker group expired' >&2; exit 1; fi
kill -- "-$leader"
for _ in $(seq 100); do kill -0 -- "-$leader" 2>/dev/null || break; sleep 0.05; done
coord_on_expire "$claim" || { echo 'claim stayed held after the worker group exited' >&2; exit 1; }
for bad in abc '' 0 '12 34x'; do
  printf '%s' "$bad" > "$pidfile"
  if coord_on_expire "$claim"; then echo "malformed pidfile '$bad' freed the claim" >&2; exit 1; fi
done
# The sweep drops a dead worker's file and keeps a live one's, however old.
echo 2147483646 > "$pidfile"; echo $$ > "$(worker_pidfile issue-live)"; touch -d '3 days ago' "$(worker_pidfile issue-live)"
cleanup_tick > /dev/null 2>&1 || :
[[ ! -e "$pidfile" && -e "$(worker_pidfile issue-live)" ]] || { echo 'pidfile sweep removed a live file or kept a dead one' >&2; exit 1; }
rm -f "$(worker_pidfile issue-live)" "$pidfile"
saved_sup="$SUP"; SUP=''
if coord_on_expire "$claim"; then echo 'empty SUP freed the claim' >&2; exit 1; fi
SUP="$saved_sup"
printf '{bad' > "$WORKERS"
if coord_on_expire "$claim"; then echo 'unreadable ledger freed the claim' >&2; exit 1; fi
jq -n '{workers:[{claim_owner:"pidless",unit:"issue-1",type:"review",harvested:false}]}' > "$WORKERS"
if coord_on_expire '{"owner_kind":"scheduler-worker","owner":"pidless","unit":"issue-1","stage":"review"}'; then echo 'worker without pid expired' >&2; exit 1; fi
echo 'ok - pidless claim expires only when the unit pidfile proves no worker'
