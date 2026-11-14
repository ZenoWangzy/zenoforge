#!/usr/bin/env bash
# A scope that never writes the worker pid file must neither hang the dispatch tick nor let an unscoped second worker start.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
task_root="$test_env_root/worker-scope-start-timeout"
fake_bin="$task_root/bin"
mkdir -p "$fake_bin"
export SCOPE_STUB_PID_FILE="$task_root/scope-stub.pid" SYSTEMCTL_CALLS="$task_root/systemctl.calls"
fail() { printf 'worker-scope-start-timeout.test.sh: %s\n' "$*" >&2; exit 1; }

# Stub scope: records its pid and never writes the worker pid file, so the launch waits until something ends it.
cat > "$fake_bin/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$SCOPE_STUB_PID_FILE"
exec sleep 300
SH
# Stub stop: records the call and ends the stub scope, as a real stop ends the scope's processes.
cat > "$fake_bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_CALLS"
kill "$(cat "$SCOPE_STUB_PID_FILE")" 2>/dev/null || :
SH
chmod +x "$fake_bin/systemd-run" "$fake_bin/systemctl"
PATH="$fake_bin:$PATH"
export PATH

export AUTOPI_TEST_LIBRARY_ONLY=true
export MAC_AUTOPILOT_ROOT="$task_root/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$task_root/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$task_root/supervisor/autopi"
mkdir -p "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR/alerts"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false' \
  "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
# Real worker_scope_of_pid reads /proc cgroups of a run-p scope; the stub scope has none, so name it here.
worker_scope_of_pid() { printf 'run-p%s-i1.scope\n' "$1"; }

WORKER_SCOPE_PREPARED=true WORKER_SCOPE_MODE=scope WORKER_SCOPE_SYSTEMD_RUN="$fake_bin/systemd-run"
WORKER_TASKS_MAX=2000 WORKER_SCOPE_START_TIMEOUT=1

# Case 1: the launch returns failure within the bound, makes one stop call, and starts no unscoped worker.
marker="$task_root/unscoped-worker.started"
rm -f -- "$marker" "$SCOPE_STUB_PID_FILE" "$SYSTEMCTL_CALLS" "$task_root/timeout.pid"
start=$SECONDS rc=0
worker_scope_launch "$task_root/timeout.pid" "$task_root" "$task_root/timeout.log" setsid -- bash -c ': > "$1"' _ "$marker" || rc=$?
waited=$((SECONDS - start))
[[ "$rc" == 3 ]] || fail "timed-out scope start returned $rc, expected 3"
(( waited < 8 )) || fail "timed-out scope start took ${waited}s with a 1s bound"
[[ "$(wc -l < "$SYSTEMCTL_CALLS" | tr -d ' ')" == 1 ]] || fail "expected one stop call, got: $(cat "$SYSTEMCTL_CALLS" 2>/dev/null)"
grep -Eq '^--user stop run-p[0-9]+-i1\.scope$' "$SYSTEMCTL_CALLS" || fail "stop call is not the scope name: $(cat "$SYSTEMCTL_CALLS")"
sleep 1.5
[[ ! -e "$marker" ]] || fail 'an unscoped second worker started after the scope timed out'
[[ ! -e "$task_root/timeout.pid" ]] || fail 'timed-out launch left its pid file'
if kill -0 "$(cat "$SCOPE_STUB_PID_FILE")" 2>/dev/null; then fail 'stub scope survived the stop'; fi
printf 'PASS scope start timeout fails the launch in %ss, stops the scope once, starts no unscoped worker\n' "$waited"

# Case 2: dispatch turns that failure into a non-started unit: claim released, no worker row, the unit stays pending.
dispatch_fixture="$task_root/dispatch"
mkdir -p "$dispatch_fixture/agent" "$dispatch_fixture/supervisor/autopi"
ROOT="$task_root/repo" A="$dispatch_fixture/agent" SUP="$dispatch_fixture/supervisor" AGENT_HOME="$dispatch_fixture/agent"
LOG="$dispatch_fixture/scheduler.log" UNITS="$dispatch_fixture/units.json" WORKERS="$dispatch_fixture/workers.json" STAMP=2026-11-14T14:30:00Z
printf '%s\n' '{"units":[{"id":"issue-449001","issue":449001,"lane":"pr","stage":"implement-pending"}]}' > "$UNITS"
printf '%s\n' '{"workers":[]}' > "$WORKERS"
: > "$LOG"
CODEX_MODE=exec CODEX_PATH_REASON=fixture CODEX_SESSION_ID=fixture CODEX_USAGE_START=0
build_codex_command() { CODEX_COMMAND=(true); }; worker_write_guard_env() { :; }
worker_pidfile() { printf '%s\n' "$dispatch_fixture/worker.pid"; }; coord_scheduler_live_worker() { return 1; }
coord_issue_key() { printf 'issue:%s\n' "$1"; }; coord_new_owner() { printf 'fixture\n'; }
coord_acquire() { return 0; }; coord_assert_owned() { return 0; }
released=''; coord_release() { released="$1 $2"; }
scheduler_clear_canary_after_failed_start() { :; }
worker_scope_launch() { WORKER_SCOPE_TIMEOUT_SCOPE=run-p9-i1.scope WORKER_SCOPE_WAITED=20; return 3; }
status=0
dispatch implement codex high issue-449001 worker.log report.md prompt || status=$?
[[ "$status" == 1 ]] || fail "dispatch returned $status after a scope start timeout, expected 1"
[[ "$released" == 'issue:449001 fixture' ]] || fail "claim not released after the timeout: '$released'"
grep -Fq 'worker scope start timeout unit=issue-449001 scope=run-p9-i1.scope waited=20s' "$LOG" \
  || fail "timeout line missing from scheduler log: $(cat "$LOG")"
[[ "$(jq '.workers | length' "$WORKERS")" == 0 ]] || fail 'a worker row was written for a launch that never started'
printf '%s\n' 'PASS dispatch releases the claim on a scope start timeout, logs it, and writes no worker row'
