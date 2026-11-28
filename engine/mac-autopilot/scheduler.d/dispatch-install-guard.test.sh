#!/usr/bin/env bash
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
# dispatch() reads WORKER_SCOPE_MODE after the launch; only the live tick's worker_scope_prepare sets it.
WORKER_SCOPE_MODE=''

dispatch_path_word() { # -> the PATH=<...> word of the last worker environment; rc 1 when absent
  local arg
  for arg in "${captured_launch[@]}"; do
    [[ "$arg" == PATH=* ]] && { printf '%s\n' "$arg"; return 0; }
  done
  return 1
}
dispatch_test_policy_word() {
  local arg
  for arg in "${captured_launch[@]}"; do
    [[ "$arg" == ZF_TESTS_CI_ONLY=* ]] && { printf '%s\n' "$arg"; return 0; }
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
[[ "$(dispatch_test_policy_word)" == ZF_TESTS_CI_ONLY=1 ]] || fail 'implement/codex: PR CI-only test policy missing from worker environment'
impl_path_word="$path_word"
dispatch_case implement zcode fixture-pr impl-zcode.log
[[ "$path_word" == "$guard_first"* ]] || fail "implement/zcode: install-guard not first on the worker PATH: $path_word"
[[ "$path_word" == "$impl_path_word" ]] || fail "implement workers of two providers got different PATH words"
dispatch_case implement claude fixture-pr impl-claude.log
[[ "$path_word" == "$guard_first"* ]] || fail "implement/claude: install-guard not first on the worker PATH: $path_word"
echo "ok - implement workers (codex, zcode, claude) get install-guard first on PATH"

dispatch_case repair codex fixture-pr repair-codex.log
[[ "$(dispatch_test_policy_word)" == ZF_TESTS_CI_ONLY=1 ]] || fail 'repair/codex: PR CI-only test policy missing from worker environment'
echo 'ok - repair workers receive the PR CI-only test policy'

dispatch_case review codex fixture-pr review.log
[[ "$path_word" == "$guard_first"* ]] || fail "review: install-guard not first on the worker PATH: $path_word"
[[ "$path_word" == "$impl_path_word" ]] || fail "review worker PATH differs from the implement worker PATH"
dispatch_case rereview codex fixture-pr rereview.log
[[ "$path_word" == "$guard_first"* ]] || fail "rereview: install-guard not first on the worker PATH: $path_word"
echo "ok - review and rereview workers share the same PATH"

printf '%s\n' '{"workers":[]}' > "$WORKERS"
review_prompt="$fixture/review-contract.md"
printf 'review prompt v1\n' > "$review_prompt"
REVIEW_CONTRACT_MD="$review_prompt"
version_a="$(sha256sum -- "$review_prompt" | cut -d' ' -f1)"
dispatch_case review codex fixture-pr review-v1.log
[[ "$(jq -r '.workers[-1].prompt_version // empty' "$WORKERS")" == "$version_a" ]] \
  || fail 'review worker did not record the effective review prompt version'
printf 'review prompt v2\n' > "$review_prompt"
version_b="$(sha256sum -- "$review_prompt" | cut -d' ' -f1)"
dispatch_case rereview codex fixture-pr rereview-v2.log
[[ "$(jq -r '.workers[-1].prompt_version // empty' "$WORKERS")" == "$version_b" && "$version_a" != "$version_b" ]] \
  || fail 'rereview worker did not record its changed effective review prompt version'
WORKER_DOCS_FILE="$fixture/worker-docs.json"
PRODUCT_LANE_SKILLS="$fixture/product-lane-skills.txt"
printf '{"skipped_docs":["skip-v1"],"on_demand_docs":[],"boundary_selectors":[]}' > "$WORKER_DOCS_FILE"
printf 'skills-v1\n' > "$PRODUCT_LANE_SKILLS"
printf 'project rules v1\n' > "$ROOT/CLAUDE.md"
unset IMPLEMENTATION_PROMPT_VERSION
dispatch_case implement codex fixture-pr implement-prompt-version.log
implementation_version="$(jq -r '.workers[-1].prompt_version // empty' "$WORKERS")"
[[ "$(jq -r '.workers[-1].prompt // empty' "$WORKERS")" == 'engine/mac-autopilot/scheduler.d/dispatch-queue.sh' &&
  "$(jq -r '.workers[-1].prompt_stage // empty' "$WORKERS")" == implement &&
  "$implementation_version" =~ ^[0-9a-f]{64}$ ]] \
  || fail 'implementation worker did not record its prompt builder identity and version'
printf '{"skipped_docs":["skip-v2"],"on_demand_docs":[],"boundary_selectors":[]}' > "$WORKER_DOCS_FILE"
unset IMPLEMENTATION_PROMPT_VERSION
dispatch_case implement codex fixture-pr implement-worker-docs-v2.log
implementation_version_b="$(jq -r '.workers[-1].prompt_version // empty' "$WORKERS")"
[[ "$implementation_version" != "$implementation_version_b" ]] || fail 'worker docs change did not change the implementation prompt version'
printf 'project rules v2\n' > "$ROOT/CLAUDE.md"
unset IMPLEMENTATION_PROMPT_VERSION
dispatch_case implement codex fixture-pr implement-project-rules-v2.log
implementation_version_c="$(jq -r '.workers[-1].prompt_version // empty' "$WORKERS")"
[[ "$implementation_version_b" != "$implementation_version_c" ]] || fail 'project instructions change did not change the implementation prompt version'
printf 'skills-v2\n' > "$PRODUCT_LANE_SKILLS"
unset IMPLEMENTATION_PROMPT_VERSION
dispatch_case implement codex fixture-pr implement-product-skills-v2.log
implementation_version_d="$(jq -r '.workers[-1].prompt_version // empty' "$WORKERS")"
[[ "$implementation_version_c" != "$implementation_version_d" ]] || fail 'product skill map change did not change the implementation prompt version'

# env(1) applies assignments left to right, so direct-main rebuilds the word instead of appending a second one.
dispatch_case implement codex fixture-dm impl-dm.log
[[ "$path_word" == "PATH=$engine_dir/non-product-test-shim:$engine_dir/bin/install-guard:"* ]] \
  || fail "direct-main: test blocker no longer ahead of install-guard on the worker PATH: $path_word"
echo "ok - direct-main keeps its test blocker ahead of install-guard"

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
suite_env=(env "PATH=$engine_dir/bin/install-guard:$fixture/realbin:${worker_path_value#*:}" "ZF_CONFIG_ROOT=$fixture/config-root" ZF_TESTS_CI_ONLY=1)
: > "$FAKE_LOG"; : > "$RUNNER_LOG"
rc=0
(cd "$workdir" && "${suite_env[@]}" vitest run) >"$fixture/out" 2>"$fixture/err" || rc=$?
[[ "$rc" == 64 ]] || fail "whole-suite vitest run through the worker PATH returned $rc, want refusal 64"
grep -Fxq 'zenoforge: worker tests are run by PR CI; do not run test files, suites, or local receipt commands' "$fixture/err" \
  || fail 'whole-suite PR CI refusal message missing from the worker stderr'
[[ ! -s "$FAKE_LOG" ]] || fail 'whole-suite command reached the real vitest'
[[ ! -s "$RUNNER_LOG" ]] || fail 'whole-suite command was sent to the test host'
grep -q '^suite-guard refused ' "$TMPDIR/suite-guard.log" || fail 'refusal was not counted in the suite-guard log'
: > "$FAKE_LOG"; : > "$RUNNER_LOG"
(cd "$workdir" && "${suite_env[@]}" vitest run pkg.test.ts) >"$fixture/out" 2>"$fixture/err" && fail 'selected test run was not refused' || rc=$?
[[ "$rc" == 64 ]] || fail "selected test run returned $rc, want refusal 64"
grep -Fxq 'zenoforge: worker tests are run by PR CI; do not run test files, suites, or local receipt commands' "$fixture/err" \
  || fail 'selected-test PR CI refusal message missing from the worker stderr'
[[ ! -s "$FAKE_LOG" && ! -s "$RUNNER_LOG" ]] || fail 'selected test reached a local runner or test host'
rc=0
(cd "$workdir" && "${suite_env[@]}" bash "$engine_dir/../tools/test-receipt.sh" true) >"$fixture/out" 2>"$fixture/err" || rc=$?
[[ "$rc" == 64 ]] || fail "local test receipt command returned $rc, want refusal 64"
[[ ! -s "$FAKE_LOG" && ! -s "$RUNNER_LOG" ]] || fail 'test receipt command reached a local runner or test host'
echo 'ok - test files, suites, and local receipt commands are refused for implement/repair workers'

echo "dispatch-install-guard.test.sh: pass (worker PATH starts at $engine_dir/bin/install-guard)"
