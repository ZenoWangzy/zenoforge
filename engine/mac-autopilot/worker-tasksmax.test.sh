#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/test-env.sh"
task_root="$test_env_root/worker-tasksmax"
fake_bin="$task_root/bin"
mkdir -p "$fake_bin"
export TASK_ROOT="$task_root" SCOPE_CALLS="$task_root/systemd-run.calls"
declare -a ALL_WORKER_PIDS=() ALL_LAUNCHER_PIDS=()

cat > "$fake_bin/systemd-run" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf '%s\n' BEGIN
  printf '%s\n' "$@"
  printf '%s\n' END
} >> "$SCOPE_CALLS"
if [[ "${SYSTEMD_RUN_STUB_FAIL:-}" == probe && " $* " == *' /usr/bin/true '* ]]; then
  exit 27
fi
if [[ "${SYSTEMD_RUN_STUB_FAIL:-}" == launch && " $* " != *' /usr/bin/true '* ]]; then
  exit 31
fi
while (($#)); do
  if [[ "$1" == -- ]]; then
    shift
    exec "$@"
  fi
  shift
done
exit 97
SH
chmod +x "$fake_bin/systemd-run"
PATH="$fake_bin:$PATH"
export PATH

cat > "$task_root/fake-worker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$WORKER_ACTUAL_PID_FILE"
sleep 60 &
printf '%s\n' "$!" > "$WORKER_CHILD_PID_FILE"
wait
SH
chmod +x "$task_root/fake-worker"

say() { printf '%s\n' "$*" >> "$task_root/scheduler.log"; }
alive() { kill -0 "$1" 2>/dev/null; }
source "$script_dir/scheduler.d/worker-scope.sh"
source "$script_dir/scheduler.d/harvest-workers.sh"

fail() { printf 'worker-tasksmax.test.sh: %s\n' "$*" >&2; exit 1; }
for launch_file in dispatch.sh evals-arbiter.sh land-lane.sh; do
  grep -Fq 'worker_scope_launch' "$script_dir/scheduler.d/$launch_file" \
    || fail "$launch_file bypasses the bounded worker launcher"
done
grep -Fq 'source "$HERE/scheduler.d/worker-scope.sh"' "$script_dir/scheduler.sh" \
  || fail 'scheduler.sh does not load the bounded worker launcher'
cleanup() {
  local i
  for ((i=0; i<${#ALL_WORKER_PIDS[@]}; i++)); do
    stuck_worker_stop "${ALL_WORKER_PIDS[i]}" 2>/dev/null || true
    wait "${ALL_LAUNCHER_PIDS[i]}" 2>/dev/null || true
  done
}
trap cleanup EXIT
reset_tick() {
  WORKER_SCOPE_PREPARED=false
  WORKER_SCOPE_WARNED=false
  WORKER_SCOPE_MODE=''
  WORKER_SCOPE_SYSTEMD_RUN=''
  WORKER_SCOPE_PID=''
  WORKER_SCOPE_LAUNCHER_PID=''
  : > "$task_root/scheduler.log"
  : > "$SCOPE_CALLS"
}
start_worker() {
  local label="$1" launcher="$2"; shift 2
  local pid_file="$task_root/$label.pid" worker_pid_file="$task_root/$label.actual.pid" child_pid_file="$task_root/$label.child.pid"
  rm -f "$pid_file" "$worker_pid_file" "$child_pid_file"
  worker_scope_launch "$pid_file" "$task_root" "$task_root/$label.log" "$launcher" -- \
    env "WORKER_ACTUAL_PID_FILE=$worker_pid_file" "WORKER_CHILD_PID_FILE=$child_pid_file" "$task_root/fake-worker"
  [[ "$WORKER_SCOPE_PID" =~ ^[1-9][0-9]*$ ]] || fail "$label did not return a worker PID: $WORKER_SCOPE_PID"
  for _ in {1..100}; do [[ -s "$child_pid_file" ]] && break; sleep 0.02; done
  [[ -s "$worker_pid_file" && -s "$child_pid_file" ]] || fail "$label worker tree did not start"
  [[ "$(cat "$worker_pid_file")" == "$WORKER_SCOPE_PID" ]] || fail "$label recorded PID is not the worker process"
  TEST_WORKER_PID="$WORKER_SCOPE_PID"
  TEST_LAUNCHER_PID="$WORKER_SCOPE_LAUNCHER_PID"
  TEST_CHILD_PID="$(cat "$child_pid_file")"
  ALL_WORKER_PIDS+=("$TEST_WORKER_PID")
  ALL_LAUNCHER_PIDS+=("$TEST_LAUNCHER_PID")
}
stop_worker() {
  local pid="$1" launcher_pid="$2" child_pid="$3" i state
  stuck_worker_stop "$pid"
  wait "$launcher_pid" 2>/dev/null || true
  for ((i=0; i<100; i++)); do
    if [[ ! -r "/proc/$child_pid/stat" ]]; then return 0; fi
    state="$(awk '{print $3}' "/proc/$child_pid/stat" 2>/dev/null || true)"
    [[ "$state" == Z ]] && return 0
    sleep 0.02
  done
  fail "kill-tree did not stop descendant $child_pid for worker $pid"
}

CFG='{"engine":{"worker_tasks_max":3456}}'
reset_tick
start_worker configured setsid
grep -Fxq 'TasksMax=3456' "$SCOPE_CALLS" || fail 'worker command was not wrapped with configured TasksMax'
grep -Fq "$task_root/fake-worker" "$SCOPE_CALLS" || fail 'systemd-run did not receive the worker command'
workers_json="$(jq -cn --argjson pid "$TEST_WORKER_PID" '{workers:[{pid:$pid}]}')"
recorded_pid="$(jq -r '.workers[0].pid' <<<"$workers_json")"
[[ "$(ps -o pgid= -p "$recorded_pid" | tr -d ' ')" == "$recorded_pid" ]] \
  || fail 'recorded worker PID is not the process-group leader used by kill-tree'
stop_worker "$recorded_pid" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
printf '%s\n' 'PASS configured TasksMax wraps the worker and its recorded PID kills the process tree'

CFG='{}'
reset_tick
start_worker defaulted setsid
grep -Fxq 'TasksMax=2000' "$SCOPE_CALLS" || fail 'missing config key did not use the 2000 default'
stop_worker "$TEST_WORKER_PID" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
[[ "$(jq -r '.engine.worker_tasks_max' "$script_dir/config.template.json")" == 2000 ]] \
  || fail 'config.template.json does not set engine.worker_tasks_max to 2000'
printf '%s\n' 'PASS worker task limit defaults to 2000'

worker_scope_systemd_run_path() { return 1; }
CFG='{"engine":{"worker_tasks_max":2000}}'
reset_tick
start_worker missing-one setsid
missing_pid_one="$TEST_WORKER_PID" missing_launcher_one="$TEST_LAUNCHER_PID" missing_child_one="$TEST_CHILD_PID"
start_worker missing-two setsid
[[ ! -s "$SCOPE_CALLS" ]] || fail 'missing systemd-run unexpectedly invoked a scope'
[[ "$(grep -c '^worker scope unavailable:' "$task_root/scheduler.log")" == 1 ]] \
  || fail 'missing systemd-run did not log exactly once for the tick'
stop_worker "$missing_pid_one" "$missing_launcher_one" "$missing_child_one"
stop_worker "$TEST_WORKER_PID" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
printf '%s\n' 'PASS missing systemd-run falls back unchanged and logs once per tick'

worker_scope_systemd_run_path() { type -P systemd-run; }
export SYSTEMD_RUN_STUB_FAIL=probe
reset_tick
start_worker failed setsid
[[ "$WORKER_SCOPE_MODE" == unavailable ]] || fail 'failed systemd-run probe did not disable scopes for the tick'
[[ "$(grep -c '^worker scope unavailable:' "$task_root/scheduler.log")" == 1 ]] \
  || fail 'failed systemd-run did not log one fallback line'
stop_worker "$TEST_WORKER_PID" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
unset SYSTEMD_RUN_STUB_FAIL
printf '%s\n' 'PASS failed systemd-run falls back unchanged'

export SYSTEMD_RUN_STUB_FAIL=launch
reset_tick
start_worker launch-failed setsid
[[ "$WORKER_SCOPE_MODE" == unavailable ]] || fail 'failed worker scope launch did not disable scopes for the tick'
[[ "$(grep -c '^worker scope unavailable:' "$task_root/scheduler.log")" == 1 ]] \
  || fail 'failed worker scope launch did not log one fallback line'
stop_worker "$TEST_WORKER_PID" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
unset SYSTEMD_RUN_STUB_FAIL
printf '%s\n' 'PASS failed worker scope launch falls back unchanged'

CFG='{"engine":{"worker_tasks_max":0}}'
reset_tick
start_worker disabled setsid
[[ ! -s "$SCOPE_CALLS" ]] || fail 'worker_tasks_max=0 invoked systemd-run'
[[ ! -s "$task_root/scheduler.log" ]] || fail 'disabled scopes logged an unavailable warning'
stop_worker "$TEST_WORKER_PID" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
printf '%s\n' 'PASS worker_tasks_max=0 disables scopes'

# precheck.sh (PR-controlled tests) goes through the scope, and the PID harvest polls is the precheck process itself.
source "$script_dir/scheduler.d/ci-admission.sh"
A="$task_root" SUP="$task_root" HERE="$task_root"
printf '#!/usr/bin/env bash\necho "PRECHECK: PASS $*"\n' > "$task_root/precheck.sh"
ensure_clone() { echo "$task_root"; }
js() { jq -Rn --arg v "$1" '$v'; }
set_unit() { PRECHECK_UNIT_SET="$*"; }
CFG='{"engine":{"worker_tasks_max":2468}}'
reset_tick
precheck_launch u1 214 deadbeef
grep -Fxq 'TasksMax=2468' "$SCOPE_CALLS" && grep -Fq "$task_root/precheck.sh" "$SCOPE_CALLS" || fail 'precheck.sh bypasses the TasksMax scope'
[[ "$PRECHECK_UNIT_SET" == *".precheck_pid=$WORKER_SCOPE_PID"* ]] || fail 'precheck_pid is not the launched precheck PID'
for _ in {1..100}; do [[ "$(head -1 "$task_root/precheck-u1.out" 2>/dev/null)" == 'PRECHECK: PASS'* ]] && break; sleep 0.02; done
[[ "$(head -1 "$task_root/precheck-u1.out")" == "PRECHECK: PASS $task_root 214 deadbeef" ]] || fail 'scoped precheck did not get its arguments or output file'
wait "$WORKER_SCOPE_LAUNCHER_PID" 2>/dev/null || true
printf '%s\n' 'PASS precheck runs inside the worker scope and records its PID'

# A worker that dies right after start still hands back its start identity (read before the worker ran).
CFG='{"engine":{"worker_tasks_max":2000}}'
reset_tick
worker_scope_launch "$task_root/dead.pid" "$task_root" "$task_root/dead.log" setsid -- true
wait "$WORKER_SCOPE_LAUNCHER_PID" 2>/dev/null || true
[[ "$WORKER_SCOPE_PID" =~ ^[1-9][0-9]*$ && "$WORKER_SCOPE_PID_START" =~ ^[0-9]+$ ]] || fail "dead-at-once worker lost its identity: '$WORKER_SCOPE_PID' '$WORKER_SCOPE_PID_START'"
printf '%s\n' 'PASS a worker that dies at once still returns its start identity'

# A scope whose TasksMax refused forks (pids.events max>0) says so in the worker log and the scheduler log.
wait_for_line() { # file pattern
  for _ in {1..150}; do grep -Fq -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
LOG="$task_root/scheduler.log"
export WORKER_SCOPE_EVENTS_FILE="$task_root/pids.events"
CFG='{"engine":{"worker_tasks_max":77}}'
reset_tick
printf 'max 0\n' > "$WORKER_SCOPE_EVENTS_FILE"
start_worker quiet setsid
sleep 1.5
! grep -Fq 'TasksMax=77 reached' "$task_root/quiet.log" || fail 'a scope with no refused forks reported a TasksMax hit'
stop_worker "$TEST_WORKER_PID" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
reset_tick
printf 'low 0\nmax 4\n' > "$WORKER_SCOPE_EVENTS_FILE"
start_worker hit setsid
wait_for_line "$task_root/hit.log" '[worker-scope] TasksMax=77 reached (4 refused forks)' || fail 'worker log lacks the TasksMax hit line'
wait_for_line "$LOG" "worker-tasksmax-hit pid=$TEST_WORKER_PID tasksmax=77 refused_forks=4 log=hit.log" \
  || fail 'scheduler log lacks the worker-tasksmax-hit line'
[[ "$(grep -c 'TasksMax=77 reached' "$task_root/hit.log")" == 1 ]] || fail 'TasksMax hit was reported more than once'
stop_worker "$TEST_WORKER_PID" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
unset WORKER_SCOPE_EVENTS_FILE
printf '%s\n' 'PASS a refused fork is reported once as a worker failure in the worker and scheduler logs'

# Real systemd scope, real kernel limit: a fork loop stops at TasksMax, the worker ends, the log says why.
PATH="${PATH#"$fake_bin:"}"
worker_scope_systemd_run_path() { type -P systemd-run; }
if type -P systemd-run >/dev/null && systemd-run --user --scope --quiet -p TasksMax=100 -- true >/dev/null 2>&1; then
  CFG='{"engine":{"worker_tasks_max":30}}'
  reset_tick
  worker_scope_launch "$task_root/real.pid" "$task_root" "$task_root/real.log" setsid -- \
    python3 -c 'import subprocess,sys
n=0
try:
    while n < 80:
        subprocess.Popen(["sleep", "3"]); n += 1
except OSError:
    pass
sys.exit(1 if n < 80 else 0)'
  real_pid="$WORKER_SCOPE_PID"; ALL_WORKER_PIDS+=("$real_pid"); ALL_LAUNCHER_PIDS+=("$WORKER_SCOPE_LAUNCHER_PID")
  wait_for_line "$task_root/real.log" '[worker-scope] TasksMax=30 reached' || fail 'real scope: no TasksMax hit line in the worker log'
  wait_for_line "$LOG" 'worker-tasksmax-hit' || fail 'real scope: no worker-tasksmax-hit line in the scheduler log'
  for _ in {1..100}; do alive "$real_pid" || break; sleep 0.1; done
  ! alive "$real_pid" || fail 'real scope: the worker did not end'
  printf '%s\n' 'PASS real scope: a fork loop is stopped at TasksMax and logged as a worker failure'
else
  printf '%s\n' 'SKIP real scope: systemd-run --user --scope unavailable'
fi
