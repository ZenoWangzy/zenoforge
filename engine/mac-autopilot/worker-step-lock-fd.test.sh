#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
task_root="$test_env_root/worker-step-lock-fd"
fake_bin="$task_root/bin"
mkdir -p "$fake_bin" "$task_root/agent"
A="$task_root/agent"
lock_file="$A/.tick-step-dispatch_pending.lock"
LOCK_TEST_WORKER_PID=''
LOCK_TEST_LAUNCHER_PID=''

fail() { printf 'worker-step-lock-fd.test.sh: %s\n' "$*" >&2; exit 1; }
say() { :; }

cat > "$fake_bin/systemd-run" <<'SH'
#!/usr/bin/env bash
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

source "$script_dir/scheduler.d/tick-steps.sh"
source "$script_dir/scheduler.d/worker-scope.sh"

cleanup() {
  [[ "$LOCK_TEST_WORKER_PID" =~ ^[1-9][0-9]*$ ]] && kill "$LOCK_TEST_WORKER_PID" 2>/dev/null || :
  [[ "$LOCK_TEST_LAUNCHER_PID" =~ ^[1-9][0-9]*$ ]] && kill "$LOCK_TEST_LAUNCHER_PID" 2>/dev/null || :
  [[ "$LOCK_TEST_LAUNCHER_PID" =~ ^[1-9][0-9]*$ ]] && wait "$LOCK_TEST_LAUNCHER_PID" 2>/dev/null || :
}
trap cleanup EXIT

assert_no_lock_fd() {
  local pid="$1" link target
  for link in "/proc/$pid/fd/"*; do
    target="$(readlink "$link" 2>/dev/null || true)"
    [[ "$target" != "$lock_file" ]] || fail "worker $pid inherited $lock_file via $link"
  done
}

launch_long_worker() {
  local case_root="$1" marker="$1/worker.pid"
  worker_scope_launch "$case_root/scope.pid" "$case_root" "$case_root/worker.log" setsid -- \
    bash -c 'printf "%s\n" "$BASHPID" > "$1"; exec sleep 60' _ "$marker"
  for _ in {1..200}; do [[ -s "$marker" ]] && break; sleep 0.02; done
  [[ -s "$marker" ]] || fail "${LOCK_TEST_MODE}: worker did not start"
  LOCK_TEST_WORKER_PID="$(<"$marker")"
  LOCK_TEST_LAUNCHER_PID="$WORKER_SCOPE_LAUNCHER_PID"
  [[ "$LOCK_TEST_WORKER_PID" =~ ^[1-9][0-9]*$ ]] || fail "${LOCK_TEST_MODE}: invalid worker pid '$LOCK_TEST_WORKER_PID'"
  kill -0 "$LOCK_TEST_WORKER_PID" 2>/dev/null || fail "${LOCK_TEST_MODE}: worker $LOCK_TEST_WORKER_PID is not running"
  assert_no_lock_fd "$LOCK_TEST_WORKER_PID"
}

for LOCK_TEST_MODE in scope direct; do
  case_root="$task_root/$LOCK_TEST_MODE"
  mkdir -p "$case_root"
  worker_scope_systemd_run_path() {
    [[ "$LOCK_TEST_MODE" == scope ]] || return 1
    type -P systemd-run
  }
  WORKER_SCOPE_PREPARED=false
  WORKER_SCOPE_WARNED=false
  LOCK_TEST_WORKER_PID=''
  LOCK_TEST_LAUNCHER_PID=''
  tick_step_lock_run dispatch_pending launch_long_worker "$case_root"
  kill -0 "$LOCK_TEST_WORKER_PID" 2>/dev/null || fail "${LOCK_TEST_MODE}: worker did not outlive the step"
  assert_no_lock_fd "$LOCK_TEST_WORKER_PID"
  flock -n "$lock_file" true || fail "${LOCK_TEST_MODE}: worker still holds the step lock after the step returned"
  printf 'PASS %s worker has no step-lock fd and does not hold the lock after the step returns\n' "$LOCK_TEST_MODE"
  cleanup
  LOCK_TEST_WORKER_PID=''
  LOCK_TEST_LAUNCHER_PID=''
done
