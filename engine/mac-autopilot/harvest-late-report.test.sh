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

# A live ZCode worker whose log ends in its turn error and has been quiet for 60 s is stopped and counted as a zero-output death.
hung_case() { # last log line, log age in seconds before NOW_EPOCH -> starts a live worker for issue-4 and runs harvest
  printf '{"units":[{"id":"issue-4","stage":"review","history":[]}]}' > "$UNITS"
  printf 'earlier output\n%s\n\n' "$1" > "$sup/hung.log"; touch -d "@$((NOW_EPOCH - $2))" "$sup/hung.log"
  rm -f "$sup/hung.md"
  setsid sleep 600 < /dev/null > /dev/null 2>&1 &
  hung_pid=$!; backend="$hung_pid"
  jq -n --argjson pid "$hung_pid" --argjson start "$(coord_process_start_ticks "$hung_pid")" '{workers:[{pid:$pid,pid_start:$start,process_group:$pid,unit:"issue-4",type:"review",provider:"zcode",log:"hung.log",report:"hung.md",started:"2026-11-04T00:00:00Z",harvested:false}]}' > "$WORKERS"
  harvest_workers
}
turn_error='Error: Turn execution failed (traceId: abc123)'
hung_case "$turn_error" 300
for _ in $(seq 50); do kill -0 "$hung_pid" 2>/dev/null || break; sleep 0.1; done
! kill -0 "$hung_pid" 2>/dev/null || { echo 'hung worker was not stopped' >&2; exit 1; }
jq -e '.workers[0].harvested == true' "$WORKERS" >/dev/null
jq -e '[.units[0].history[] | select(.stage == "worker-no-output")] | length == 1' "$UNITS" >/dev/null
grep -q "stopping hung worker unit=issue-4 pid=$hung_pid reason=zcode-turn-failed" "$LOG" || { echo 'no say line for the hung worker' >&2; exit 1; }
wait "$hung_pid" 2>/dev/null || :; backend=''
for case in "$turn_error|30" 'Reading the file next|300'; do
  hung_case "${case%%|*}" "${case#*|}"
  kill -0 "$hung_pid" 2>/dev/null || { echo "worker was stopped for: $case" >&2; exit 1; }
  jq -e '.workers[0].harvested == false and (.units[0].history | all(.stage != "worker-no-output"))' <<<"$(jq -s '{workers: .[0].workers, units: .[1].units}' "$WORKERS" "$UNITS")" >/dev/null
  kill "$hung_pid"; wait "$hung_pid" 2>/dev/null || :; backend=''
done
echo 'ok - hung ZCode worker is stopped only when its log ends in the turn error and is quiet'

# A recorded non-product test-guard refusal is an outcome, not a worker death.
guard_marker='non-product-test-guard: refused unit=issue-guard command=bash reason=test-file recorded=1'
guard_run() { # log path mode [keep-history] [head] [worker-type] → harvest one guarded worker
  local guard_file="$sup/$1.guard-refusals" target worker_type="${5:-review}" attempt
  case "$2" in
    json) jq -cn --arg text "$guard_marker"$'\n' '{type:"assistant",message:{content:[{type:"text",text:$text}]}}' > "$sup/$1" ;;
    tool-result) jq -cn --arg text "$guard_marker"$'\n' '{type:"tool_result",content:[{type:"text",text:$text}]}' > "$sup/$1" ;;
    file) printf 'reviewer read harvest-late-report.test.sh: %s\n' "$guard_marker" > "$sup/$1" ;;
    bash|python3)
      : > "$sup/$1"
      target="$script_dir/harvest-late-report.test.sh"; [[ "$2" != python3 ]] || target="$sup/guard.test.py"
      env ZF_NON_PRODUCT_UNIT=1 ZF_PIPELINE_UNIT=issue-guard "ZF_NON_PRODUCT_GUARD_FILE=$guard_file" \
        "$script_dir/../non-product-test-shim/$2" "$target" >/dev/null 2>&1 || [[ "$?" == 78 ]] || { echo "test shim did not refuse $2 test-file" >&2; exit 1; }
      ;;
    *) printf '%s\n' "$guard_marker" > "$sup/$1" ;;
  esac
  rm -f "$sup/guard.md" "$sup/guard.md.partial"
  [[ "${3:-reset}" == keep ]] || jq -n '{units:[{id:"issue-guard",stage:"review",lane:"direct-main",history:[]}]}' > "$UNITS"
  if [[ "$worker_type" == repair ]]; then
    attempt="${1##*/}"
    set_unit issue-guard "$(STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)" hist write-start '[]') | .history[-1].work_type=\"repair\" | .history[-1].attempt=$(js "$attempt") | .stage=\"repair\""
  fi
  jq -n --arg log "$1" --arg head "${4:-}" --arg type "$worker_type" '{workers:[{pid:999999999,unit:"issue-guard",type:$type,provider:"fixture",log:$log,report:"guard.md",sha:$head,started:"2026-11-04T00:00:00Z",harvested:false}]}' > "$WORKERS"
  harvest_workers
}

# bash/sh -c scripts are opaque to the outer shim; commands launched inside
# those scripts still resolve through PATH and keep their own test guard.
shim_dir="$script_dir/../non-product-test-shim"
shim_work="$sup/non-product-shim-command"
shim_guard="$sup/non-product-shim-command.guard-refusals"
shim_output="$sup/non-product-shim-command.output"
mkdir -p "$shim_work/a"
printf 'shim-readable\n' > "$shim_work/a/x.test.mjs"
printf '#!/usr/bin/env bash\nexit 0\n' > "$shim_work/a/x.test.sh"
git -C "$shim_work" init -q
printf 'export PATH=%q:"$PATH"\n' "$shim_dir" > "$HOME/.bash_profile"
shim_run() {
  local output="$1"
  shift
  (cd "$shim_work" && env ZF_NON_PRODUCT_UNIT=1 ZF_PIPELINE_UNIT=issue-shim \
    "ZF_NON_PRODUCT_GUARD_FILE=$shim_guard" "PATH=$shim_dir:$PATH" "$@") > "$output" 2>&1
}
shim_home="$sup/non-product-shim-login-home"
shim_profile_bin="$sup/non-product-shim-login-bin"
shim_login_bash_output="$sup/non-product-shim-login-bash.output"
shim_login_sh_output="$sup/non-product-shim-login-sh.output"
shim_login_elc_output="$sup/non-product-shim-login-elc.output"
shim_login_separated_output="$sup/non-product-shim-login-separated.output"
shim_login_long_output="$sup/non-product-shim-login-long.output"
shim_login_nonlogin_output="$sup/non-product-shim-nonlogin.output"
mkdir -p "$shim_home" "$shim_profile_bin"
printf '#!/bin/sh\nprintf "REAL-NODE\\n"\nexit 0\n' > "$shim_profile_bin/node"
chmod +x "$shim_profile_bin/node"
printf 'export PATH=%q:"$PATH"\n' "$shim_profile_bin" > "$shim_home/.profile"
shim_run_home_path() {
  local output="$1" home="$2" path="$3"
  shift 3
  (cd "$shim_work" && env "HOME=$home" ZF_NON_PRODUCT_UNIT=1 ZF_PIPELINE_UNIT=issue-shim \
    "ZF_NON_PRODUCT_GUARD_FILE=$shim_guard" "PATH=$path" "$@") > "$output" 2>&1
}
shim_run_home() {
  local output="$1" home="$2"
  shift 2
  shim_run_home_path "$output" "$home" "$shim_dir:$PATH" "$@"
}
shim_login_bash_status=0
shim_run_home "$shim_login_bash_output" "$shim_home" "$shim_dir/bash" -lc 'node a/x.test.mjs' || shim_login_bash_status=$?
shim_login_sh_status=0
shim_run_home "$shim_login_sh_output" "$shim_home" "$shim_dir/sh" -lc 'node a/x.test.mjs' || shim_login_sh_status=$?
shim_sh_login_supported=1
if [[ "$shim_login_sh_status" != 78 ]] && grep -Eiq 'illegal option.*-l|bad option.*-l' "$shim_login_sh_output"; then
  shim_sh_login_supported=0
  shim_login_sh_status=0
  shim_run_home "$shim_login_sh_output" "$shim_home" "$shim_dir/sh" -c 'node a/x.test.mjs' || shim_login_sh_status=$?
fi
shim_login_elc_status=0
shim_run_home "$shim_login_elc_output" "$shim_home" "$shim_dir/bash" -elc 'node a/x.test.mjs' || shim_login_elc_status=$?
shim_login_separated_status=0
shim_run_home "$shim_login_separated_output" "$shim_home" "$shim_dir/bash" -l -c 'node a/x.test.mjs' || shim_login_separated_status=$?
shim_login_long_status=0
shim_run_home "$shim_login_long_output" "$shim_home" "$shim_dir/bash" --login -c 'node a/x.test.mjs' || shim_login_long_status=$?
shim_login_nonlogin_status=0
shim_run_home_path "$shim_login_nonlogin_output" "$shim_home" "$shim_profile_bin:$shim_dir:$PATH" \
  "$shim_dir/bash" -c 'node a/x.test.mjs' || shim_login_nonlogin_status=$?
shim_login_git_status=0
shim_run_home "$shim_output" "$shim_home" "$shim_dir/bash" -lc 'git add a/x.test.mjs' || shim_login_git_status=$?
shim_login_sed_status=0
shim_run_home "$shim_output" "$shim_home" "$shim_dir/bash" -lc 'sed -n 1p a/x.test.mjs' || shim_login_sed_status=$?
login_guard_failed=0
shim_assert_login_guard() {
  local label="$1" status="$2" command="$3" output="$4"
  if [[ "$status" != 78 ]] || ! grep -Fq "command=$command reason=test-file" "$output" || grep -Fq 'REAL-NODE' "$output"; then
    echo "login shim case $label failed (rc=$status)" >&2
    cat "$output" >&2
    login_guard_failed=1
  fi
}
shim_assert_login_guard 'bash -lc' "$shim_login_bash_status" node "$shim_login_bash_output"
shim_sh_label='sh -c fallback'
[[ "$shim_sh_login_supported" == 0 ]] || shim_sh_label='sh -lc'
shim_assert_login_guard "$shim_sh_label" "$shim_login_sh_status" node "$shim_login_sh_output"
shim_assert_login_guard 'bash -elc' "$shim_login_elc_status" node "$shim_login_elc_output"
shim_assert_login_guard 'bash -l -c' "$shim_login_separated_status" node "$shim_login_separated_output"
shim_assert_login_guard 'bash --login -c' "$shim_login_long_status" node "$shim_login_long_output"
[[ "$shim_login_git_status" == 0 ]] || { echo "bash -lc staging a test file with the profile fixture failed (rc=$shim_login_git_status)" >&2; exit 1; }
[[ "$shim_login_sed_status" == 0 ]] || { echo "bash -lc reading a test file with the profile fixture failed (rc=$shim_login_sed_status)" >&2; exit 1; }
[[ "$shim_login_nonlogin_status" == 0 ]] && grep -Fq 'REAL-NODE' "$shim_login_nonlogin_output" \
  || { cat "$shim_login_nonlogin_output" >&2; echo "non-login bash -c was rewritten (rc=$shim_login_nonlogin_status)" >&2; exit 1; }
echo "login shim reproduction rcs: bash -lc=$shim_login_bash_status sh=$shim_login_sh_status bash -elc=$shim_login_elc_status bash -l -c=$shim_login_separated_status bash --login -c=$shim_login_long_status; non-login bash -c=$shim_login_nonlogin_status; sh_login_supported=$shim_sh_login_supported"
[[ "$login_guard_failed" == 0 ]] || exit 1
shim_status=0
shim_run "$shim_output" "$shim_dir/bash" -lc 'git add a/x.test.mjs' || shim_status=$?
[[ "$shim_status" == 0 ]] || { cat "$shim_output" >&2; echo "bash -lc staging a test file was refused (rc=$shim_status)" >&2; exit 1; }
shim_status=0
shim_run "$shim_output" "$shim_dir/bash" -lc 'sed -n 1p a/x.test.mjs' || shim_status=$?
[[ "$shim_status" == 0 ]] || { cat "$shim_output" >&2; echo "bash -lc reading a test file with sed was refused (rc=$shim_status)" >&2; exit 1; }
shim_status=0
shim_run "$shim_output" "$shim_dir/sh" -c 'cat a/x.test.mjs' || shim_status=$?
[[ "$shim_status" == 0 ]] || { cat "$shim_output" >&2; echo "sh -c reading a test file with cat was refused (rc=$shim_status)" >&2; exit 1; }
shim_status=0
shim_run "$shim_output" "$shim_dir/bash" a/x.test.sh || shim_status=$?
[[ "$shim_status" == 78 ]] && grep -Fq 'command=bash reason=test-file' "$shim_output" \
  || { cat "$shim_output" >&2; echo "direct bash test execution was not refused as test-file (rc=$shim_status)" >&2; exit 1; }
shim_status=0
shim_run "$shim_output" "$shim_dir/bash" -lc 'node a/x.test.mjs' || shim_status=$?
[[ "$shim_status" == 78 ]] && grep -Fq 'command=node reason=test-file' "$shim_output" \
  || { cat "$shim_output" >&2; echo "nested node test execution was not refused by the node shim (rc=$shim_status)" >&2; exit 1; }
echo 'ok - bash/sh -c scripts skip outer test-file scanning while nested commands stay guarded'

guard_run guard-first.log bash
jq -e '.units[0] | .stage == "review-pending" and ([.history[] | select(.stage == "worker-guard-refused" and (.result | startswith("command=bash reason=test-file")))] | length == 1) and ([.history[] | select(.stage == "worker-no-output")] | length == 0)' "$UNITS" >/dev/null \
  || { echo 'guard refusal was not recorded as an explicit worker outcome' >&2; exit 1; }
jq -e '.workers[0].harvested == true' "$WORKERS" >/dev/null \
  || { echo 'guard refusal was counted as a worker death or left unharvested' >&2; exit 1; }

guard_run reviewer-output.log tool-result keep
jq -e '([.units[0].history[] | select(.stage == "worker-guard-refused")] | length == 1) and ([.units[0].history[] | select(.stage == "worker-no-output")] | length == 1)' "$UNITS" >/dev/null \
  || { echo 'tool_result marker without a shim refusal file was not counted as worker-no-output' >&2; exit 1; }

delivered_guard_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
jq -n --arg head "$delivered_guard_head" '{units:[{id:"issue-guard",stage:"rereview-pending",lane:"direct-main",history:[{stage:"repair-delivered",head:$head}]}]}' > "$UNITS"
guard_run guard-delivered-first.log bash keep "$delivered_guard_head" rereview
guard_run guard-delivered-second.log python3 keep "$delivered_guard_head" rereview
jq -e --arg head "$delivered_guard_head" '.units[0] | .stage == "rereview-pending" and ([.history[] | select(.stage == "worker-guard-refused" and .head == $head)] | length == 2) and ([.history[] | select(.stage == "supervisor-escalated")] | length == 0)' "$UNITS" >/dev/null \
  || { echo "guard refusals overrode a delivered repair on the same head: $(jq -c '.units[0]' "$UNITS")" >&2; exit 1; }
delivered_repair="$(jq -cn '{history:[]}' | jq -c "$(repair_run_filter issue-guard unknown - 0 /dev/null /dev/null "$delivered_guard_head")")"
jq -e --arg head "$delivered_guard_head" '.stage == "rereview-pending" and .history[-1].stage == "repair-delivered" and .history[-1].head == $head' <<<"$delivered_repair" >/dev/null \
  || { echo 'repair delivery did not record its head for matching later guard refusals' >&2; exit 1; }

jq -n '{units:[{id:"issue-guard",stage:"review",lane:"direct-main",history:[]}]}' > "$UNITS"
guard_run guard-repeat-first.log bash keep
guard_run guard-repeat-second.log python3 keep
jq -e '.units[0] | .stage == "review-pending" and ([.history[] | select(.stage == "worker-guard-refused")] | length == 2) and any(.history[]; .stage == "worker-guard-refused" and (.result | startswith("command=bash reason=test-file"))) and any(.history[]; .stage == "worker-guard-refused" and (.result | startswith("command=python3 reason=test-file"))) and ([.history[] | select(.stage == "supervisor-escalated")] | length == 0) and all(.history[]; .stage != "worker-no-output")' "$UNITS" >/dev/null \
  || { echo 'the second same-head guard refusal escalated instead of requeueing' >&2; exit 1; }
guard_run guard-repeat-third.log bash keep
jq -e '.units[0] | .stage == "supervisor-review" and ([.history[] | select(.stage == "worker-guard-refused")] | length == 3) and ([.history[] | select(.stage == "supervisor-escalated")] | length == 1) and any(.history[]; .stage == "supervisor-escalated" and ((.result // "") | contains("test-shim refusal loop"))) and all(.history[]; .stage != "worker-no-output")' "$UNITS" >/dev/null \
  || { echo "alternating guard refusals did not reach the supervisor: $(jq -c '.units[0]' "$UNITS")" >&2; exit 1; }

git -C "$MAC_AUTOPILOT_ROOT" init -q -b main
git -C "$MAC_AUTOPILOT_ROOT" -c user.name='Test' -c user.email='test@example.invalid' commit --allow-empty -qm 'direct-main refusal base one'
refusal_head="$(git -C "$MAC_AUTOPILOT_ROOT" rev-parse --verify HEAD)"
jq -n --arg head "$refusal_head" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{units:[{id:"issue-guard",stage:"repair-pending",lane:"direct-main",history:[
  {stage:"write-start",work_type:"repair",attempt:"before-ruling.worker.log"},
  {stage:"supervisor-requeue",at:$now}
]}]}' > "$UNITS"
guard_run guard-repair-first.log bash keep "$refusal_head" repair
guard_repair_budget_unchanged() {
  local label="$1" expected_stage="${2:-repair-pending}" expected_escalations="${3:-0}" unit rounds stop_loss budget
  unit="$(jq -c '.units[0]' "$UNITS")"
  rounds="$(repair_rounds_since_ruling "$unit")"
  stop_loss="$(effective_write_starts_since_ruling "$unit" '["supervisor-requeue"]' | jq 'length')"
  budget="$(ticket_budget_reason "$unit")"
  [[ "$(jq -r '.stage' <<<"$unit")" == "$expected_stage" && "$rounds" == 0 && "$stop_loss" == 0 \
    && -z "$budget" \
    && "$(jq -r '[.history[] | select(.stage=="supervisor-escalated")] | length' <<<"$unit")" == "$expected_escalations" \
    && "$(jq -r '[.history[] | select(.stage=="hard-escalation")] | length' <<<"$unit")" == 0 ]] \
    || { echo "guard refusal $label spent a round/budget or did not requeue: $unit (repair=$rounds stop-loss=$stop_loss reason=$budget)" >&2; exit 1; }
}
guard_repair_budget_unchanged first
guard_run guard-repair-second.log bash keep "$refusal_head" repair
guard_repair_budget_unchanged second
guard_run guard-repair-third.log bash keep "$refusal_head" repair
jq -e '.units[0] | .stage == "supervisor-review" and ([.history[] | select(.stage == "worker-guard-refused")] | length == 3) and ([.history[] | select(.stage == "supervisor-escalated")] | length == 1) and any(.history[]; .stage == "supervisor-escalated" and ((.result // "") | contains("test-shim refusal loop")))' "$UNITS" >/dev/null \
  || { echo 'third same-head repair refusal did not escalate as a test-shim refusal loop' >&2; exit 1; }
guard_repair_budget_unchanged third supervisor-review 1

next_refusal_head="$(git -C "$MAC_AUTOPILOT_ROOT" -c user.name='Test' -c user.email='test@example.invalid' commit --allow-empty -qm 'direct-main refusal base two' && git -C "$MAC_AUTOPILOT_ROOT" rev-parse --verify HEAD)"
jq -n --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{units:[{id:"issue-guard",stage:"repair-pending",lane:"direct-main",history:[{stage:"supervisor-requeue",at:$now}]}]}' > "$UNITS"
guard_run guard-repair-old-head.log bash keep "$refusal_head" repair
guard_run guard-repair-new-head-first.log bash keep "$next_refusal_head" repair
guard_repair_budget_unchanged 'head change first refusal'
guard_run guard-repair-new-head-second.log python3 keep "$next_refusal_head" repair
guard_repair_budget_unchanged 'head change second refusal'
guard_run guard-repair-new-head-third.log bash keep "$next_refusal_head" repair
jq -e --arg head "$next_refusal_head" '.units[0] | .stage == "supervisor-review" and ([.history[] | select(.stage == "worker-guard-refused" and .head == $head)] | length == 3) and any(.history[]; .stage == "supervisor-escalated" and ((.result // "") | contains("test-shim refusal loop")))' "$UNITS" >/dev/null \
  || { echo 'refusals on different heads were combined or the third refusal on the new head did not escalate' >&2; exit 1; }

# A supervisor ruling starts the refusal count over: three refusals before it and one after must not park, and a park names the refused test path.
jq -n '{units:[{id:"issue-guard",stage:"repair-pending",lane:"direct-main",history:[]}]}' > "$UNITS"
guard_run guard-ruled-first.log bash keep "$next_refusal_head" repair
guard_run guard-ruled-second.log bash keep "$next_refusal_head" repair
guard_run guard-ruled-third.log bash keep "$next_refusal_head" repair
jq -e '.units[0] | .stage == "supervisor-review" and any(.history[]; .stage == "supervisor-escalated" and ((.result // "") | contains("path=") and contains("harvest-late-report.test.sh")))' "$UNITS" >/dev/null \
  || { echo "third refusal did not park with the refused test path: $(jq -c '.units[0]' "$UNITS")" >&2; exit 1; }
jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.units[0].stage = "repair-pending" | .units[0].history += [{stage:"supervisor-requeue",at:$now}]' "$UNITS" > "$UNITS.ruled" && mv "$UNITS.ruled" "$UNITS"
guard_run guard-ruled-fourth.log bash keep "$next_refusal_head" repair
jq -e '.units[0] | .stage == "repair-pending" and ([.history[] | select(.stage == "worker-guard-refused")] | length == 4) and ([.history[] | select(.stage == "supervisor-escalated")] | length == 1)' "$UNITS" >/dev/null \
  || { echo "one refusal after a supervisor ruling parked again: $(jq -c '.units[0]' "$UNITS")" >&2; exit 1; }

guard_review_rule="$(lane_rule direct-main test-head)"
[[ "$guard_review_rule" == *'评审阶段不得运行测试命令'* && "$guard_review_rule" == *'测试文件可只读检查'* && "$guard_review_rule" == *'Focused 检查在 land 后的 Pipeline 运行'* && "$guard_review_rule" == *'test evidence: not run, post-land'* ]] \
  || { echo 'direct-main review does not tell reviewers to inspect tests without running them' >&2; exit 1; }
echo 'ok - test-guard outcomes, repeated refusals, and direct-main review evidence'
