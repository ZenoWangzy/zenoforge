#!/usr/bin/env bash
# Queue row 906: every scheduler model worker runs behind the same engine/bin/install-guard PATH shim the
# session workers already have (bin/zc, bin/luna), so an unsafe install or a whole-suite test run is refused
# and a configured test goes to the test host, never this host. The PATH is set once in dispatch(), for
# every provider and every type; direct-main keeps its harder test blocker ahead of the guard.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/dispatch-install-guard"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$fixture/agent"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false' \
  "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[{"id":"fixture-pr","lane":"pr"},{"id":"fixture-dm","lane":"direct-main"}]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
WORKERS="$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date +%s)"
SCHED_LOCK_HELD=true
DRY_RUN=0
ROOT="$fixture/repo"
SUP="$fixture/supervisor"
A="$fixture/agent"
# A pinned engine resolves its binaries the way a deployed one does; the shim must be this checkout's.
export ZF_ENGINE_DIR="$engine_dir"

fail() { echo "dispatch-install-guard.test.sh: $*" >&2; exit 1; }

build_codex_command() { CODEX_COMMAND=(true); WORKER_STDOUT_REPORT=0; CODEX_MODE=fresh; CODEX_PATH_REASON=fixture; CODEX_SESSION_ID=""; CODEX_USAGE_START='{}'; }
worker_write_guard_env() { :; }
worker_pidfile() { printf '%s\n' "$fixture/worker.pid"; }
coord_unit_key() { printf 'unit:%s\n' "$1"; }
coord_new_owner() { printf 'fixture\n'; }
coord_acquire() { return 0; }
coord_assert_owned() { return 0; }
coord_scheduler_live_worker() { return 1; }
coord_renew() { return 0; }
captured_launch=()
worker_scope_launch() { captured_launch=("$@"); WORKER_SCOPE_PID=$$; WORKER_SCOPE_PID_START=1; WORKER_SCOPE_LAUNCHER_PID=$$; }

dispatch_path_word() { # -> the PATH=<...> word of the last worker environment; rc 1 when absent
  local arg
  for arg in "${captured_launch[@]}"; do
    [[ "$arg" == PATH=* ]] && { printf '%s\n' "$arg"; return 0; }
  done
  return 1
}
dispatch_case() { # type provider unit log -> rc 0 = dispatched, path_word set
  local rc=0
  dispatch "$1" codex high "$3" "$4" report.md prompt "" "$ROOT" "" "" "$2" || rc=$?
  (( rc == 0 )) || fail "dispatch $1/$2 returned $rc"
  path_word="$(dispatch_path_word)" || fail "dispatch $1/$2: worker environment carries no PATH"
}

guard_first="PATH=$engine_dir/bin/install-guard:"
dispatch_case implement codex fixture-pr impl-codex.log
[[ "$path_word" == "$guard_first"* ]] || fail "implement/codex: install-guard not first on the worker PATH: $path_word"
impl_path_word="$path_word"
dispatch_case implement zcode fixture-pr impl-zcode.log
[[ "$path_word" == "$guard_first"* ]] || fail "implement/zcode: install-guard not first on the worker PATH: $path_word"
[[ "$path_word" == "$impl_path_word" ]] || fail "implement workers of two providers got different PATH words"
dispatch_case implement claude fixture-pr impl-claude.log
[[ "$path_word" == "$guard_first"* ]] || fail "implement/claude: install-guard not first on the worker PATH: $path_word"
echo "ok - implement workers (codex, zcode, claude) get install-guard first on PATH"

# Step 2 of row 906: reviewers run read-only, git has no wrapper and a read-only node or bash call passes
# through the guard, so they share one PATH instead of a second rule.
dispatch_case review codex fixture-pr review.log
[[ "$path_word" == "$guard_first"* ]] || fail "review: install-guard not first on the worker PATH: $path_word"
[[ "$path_word" == "$impl_path_word" ]] || fail "review worker PATH differs from the implement worker PATH"
dispatch_case rereview codex fixture-pr rereview.log
[[ "$path_word" == "$guard_first"* ]] || fail "rereview: install-guard not first on the worker PATH: $path_word"
echo "ok - review and rereview workers share the same PATH"

# env(1) applies assignments left to right, so direct-main rebuilds the word instead of appending a second one.
dispatch_case implement codex fixture-dm impl-dm.log
[[ "$path_word" == "PATH=$engine_dir/non-product-test-shim:$engine_dir/bin/install-guard:"* ]] \
  || fail "direct-main: test blocker no longer ahead of install-guard on the worker PATH: $path_word"
echo "ok - direct-main keeps its test blocker ahead of install-guard"

# (c) The dispatched PATH itself must refuse a whole-suite run and route a selected test to the configured
# host; the real tool behind the shim must never run.
workdir="$fixture/worktree"; mkdir -p "$workdir" "$fixture/realbin"
cat > "$fixture/realbin/vitest" <<'SH'
#!/bin/sh
printf 'LOCAL vitest' >> "$FAKE_LOG"
printf ' %s' "$@" >> "$FAKE_LOG"
printf '\n' >> "$FAKE_LOG"
SH
chmod +x "$fixture/realbin/vitest"
cat > "$fixture/test-exec" <<'SH'
#!/bin/sh
printf 'HOST %s' "$1" >> "$RUNNER_LOG"
shift
for arg do printf ' %s' "$arg" >> "$RUNNER_LOG"; done
printf '\n' >> "$RUNNER_LOG"
SH
chmod +x "$fixture/test-exec"
mkdir -p "$fixture/config-root"
printf '{"engine":{"test_exec":"%s"}}\n' "$fixture/test-exec" > "$fixture/config-root/config.json"
export FAKE_LOG="$fixture/local.log" RUNNER_LOG="$fixture/host.log"
export WORKER_SCRATCH_ROOT="$fixture/scratch"
mkdir -p "$WORKER_SCRATCH_ROOT/tmp/dispatch-install-guard"
export TMPDIR="$WORKER_SCRATCH_ROOT/tmp/dispatch-install-guard"
worker_path_value="${impl_path_word#PATH=}" # = <install-guard>:<this suite's PATH>
suite_env=(env "PATH=$engine_dir/bin/install-guard:$fixture/realbin:${worker_path_value#*:}" "ZF_CONFIG_ROOT=$fixture/config-root")
: > "$FAKE_LOG"; : > "$RUNNER_LOG"
rc=0
(cd "$workdir" && "${suite_env[@]}" vitest run) >"$fixture/out" 2>"$fixture/err" || rc=$?
[[ "$rc" == 64 ]] || fail "whole-suite vitest run through the worker PATH returned $rc, want refusal 64"
grep -Fxq 'zenoforge: whole-suite test run refused for luna workers (head ruling 2026-11-20): name the test files you changed and their related tests, e.g. `pnpm vitest run path/to/x.test.ts`. CI runs the full suite.' "$fixture/err" \
  || fail 'whole-suite refusal message missing from the worker stderr'
[[ ! -s "$FAKE_LOG" ]] || fail 'whole-suite command reached the real vitest'
[[ ! -s "$RUNNER_LOG" ]] || fail 'whole-suite command was sent to the test host'
grep -q '^suite-guard refused ' "$TMPDIR/suite-guard.log" || fail 'refusal was not counted in the suite-guard log'
: > "$FAKE_LOG"; : > "$RUNNER_LOG"
(cd "$workdir" && "${suite_env[@]}" vitest run pkg.test.ts) >"$fixture/out" 2>"$fixture/err" \
  || fail 'selected vitest run through the worker PATH failed'
grep -Fxq "HOST $workdir -- vitest run pkg.test.ts" "$RUNNER_LOG" || fail 'the configured test host did not receive the selected test'
[[ ! -s "$FAKE_LOG" ]] || fail 'selected test ran the real vitest locally'
echo "ok - whole-suite runs are refused and counted; selected tests reach the configured test host"

echo "dispatch-install-guard.test.sh: pass (worker PATH starts at $engine_dir/bin/install-guard)"
