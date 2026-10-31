#!/usr/bin/env bash
set -euo pipefail

worker_source=$(realpath "${1:-$(dirname "$0")/worker}")
test_root=$(mktemp -d)
cleanup() {
  local pid_file pid
  while IFS= read -r pid_file; do
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [[ $pid =~ ^[0-9]+$ ]] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    sleep 0.1
    kill -KILL -- "-$pid" 2>/dev/null || true
  done < <(find "$test_root" -name backend-run.pid -type f 2>/dev/null)
  rm -rf "$test_root"
}
trap cleanup EXIT

worker_script=$worker_source
if ! grep -q 'WORKER_SCRATCH_ROOT' "$worker_source"; then
  worker_script="$test_root/worker.compat"
  sed "s|^S=$HOME/src/target-repo/\.scratch; d=|S=\"\$WORKER_SCRATCH_ROOT\"; d=|" "$worker_source" > "$worker_script"
  chmod +x "$worker_script"
fi

make_fake_backends() {
  local bin=$1
  mkdir -p "$bin"
  cat > "$bin/fake-backend" <<'BACKEND'
#!/usr/bin/env bash
set -uo pipefail
backend=${0##*/}
key=$1 cwd=$2 prompt=$3
scratch=${WORKER_SCRATCH_ROOT:?}
d="$scratch/luna/$key"
mkdir -p "$d"
if [[ $backend == zc ]]; then mode=${FAKE_ZC_MODE:-success}; else mode=${FAKE_LUNA_MODE:-success}; fi
if [[ $backend == luna ]]; then
  printf '%s\n' "${CODEX_MODEL:-gpt-6-luna}" >> "$d/models"
  cat "$prompt" >> "$d/briefs"
  printf '%s\n' "${4:-}" >> "$d/schemas"
fi
if [[ $mode == capacity && ${CODEX_MODEL:-gpt-6-luna} != "${FAKE_CAPACITY_MODEL:-gpt-6.1-terra}" ]]; then mode=success; fi
if [[ $mode == capacity_fatal ]]; then
  if [[ ${CODEX_MODEL:-gpt-6-luna} == gpt-6.1-terra ]]; then mode=capacity_always; else mode=fatal; fi
fi
if [[ $mode == builtin_info ]]; then
  printf 'ZCode Built-in missing\n' >> "$d/stderr.log"
  sleep 0.3
  mode=success
fi
[[ $mode == gated ]] && { sleep 3; mode=success; }   # queued at the capacity gate past the stall threshold
echo $$ > "$d/codex.pid"   # real backends write it once past the capacity gate
case "$mode" in
  hang|builtin_noise)
    : > "$d/events.jsonl"
    printf 'partial from %s\n' "$backend" > "$cwd/.partial-from-$backend"
    bash -c 'trap '\''touch "$1"; exit 143'\'' TERM; while :; do read -r -t 0.05 _ || true; done' _ "$d/hang-child-terminated" &
    echo $! > "$d/hang-child.pid"
    trap 'touch "$d/hang-terminated"; wait; exit 143' TERM
    while :; do
      if [[ $mode == builtin_noise ]]; then
        printf 'ZCode Built-in synced\n' >> "$d/stderr.log"
      else
        printf 'scheduler skipped (not-due)\n' >> "$d/stderr.log"
      fi
      read -r -t 0.05 _ || true
    done
    ;;
  fatal)
    printf 'AI_APICallError: provider request failed (isRetryable: true)\n' >> "$d/stderr.log"
    printf 'AI_APICallError: provider request failed again\n' >> "$d/stderr.log"
    read -r -t 5 _ || true
    exit 1
    ;;
  capacity|capacity_always)
    printf '{"error":"Selected model is at capacity"}\n' > "$d/events.jsonl"
    exit 1
    ;;
  capacity_success)
    printf '{"info":"Selected model is at capacity"}\n' > "$d/events.jsonl"
    exit 0
    ;;
  builtin_fail)
    printf 'ZCode Built-in missing\n' >> "$d/stderr.log"
    exit 1
    ;;
  fatal_quota)
    printf 'AI request failed: insufficient_quota, rate limit exceeded\n' >> "$d/stderr.log"
    read -r -t 5 _ || true
    exit 1
    ;;
  turn_failed)
    # 10-28 factory-mainfix r1 shape: partial worktree edit, terminal stderr line, turn.failed event, rc=1, no last.md.
    printf 'partial from %s\n' "$backend" > "$cwd/.partial-from-$backend"
    printf 'ZCode Built-in skipped (not-due)\n' >> "$d/stderr.log"
    printf 'Error: Turn execution failed (traceId: f10131b8-1bfa-45ea-8206-15e350355079)\n' >> "$d/stderr.log"
    printf '%s\n' '{"type":"turn.failed","error":{"message":"Turn execution failed"}}' > "$d/events.jsonl"
    exit 1
    ;;
  fail)
    printf 'fake backend task failure\n' > "$d/stderr.log"
    printf '1\n' > "$d/rc"
    exit 1
    ;;
  success)
    if [[ $backend == luna && -e "$cwd/.partial-from-zc" ]]; then
      printf 'partial preserved\n' > "$cwd/fallback-saw-partial"
    fi
    printf 'response event\n' > "$d/events.jsonl"
    {
      printf 'success from %s\n' "$backend"
      cat "$prompt"
    } > "$d/last.md"
    printf '0\n' > "$d/rc"
    exit 0
    ;;
  *) printf 'unknown fake mode: %s\n' "$mode" >&2; exit 64 ;;
esac
BACKEND
  chmod +x "$bin/fake-backend"
  ln -sf fake-backend "$bin/zc"
  ln -sf fake-backend "$bin/luna"
}
# The worker finds its backends beside itself; the scratch root has no bin/ (10-30 rc=127 on every dispatch).
make_fake_backends "$test_root/bin"
cp "$worker_script" "$test_root/bin/worker"; worker_script="$test_root/bin/worker"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_file_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }

run_case() {
  local name=$1 expected_rc=$2 zc_mode=$3 luna_mode=$4 stall_seconds=$5 timeout_seconds=$6
  local initial_backend=${7:-zc}
  local initial_model=${8:-gpt-6-luna} history=${10:-}
  local root="$test_root/$name/.scratch" wt="$test_root/$name/worktree" prompt="$test_root/$name/brief.md"
  local key=${9:-test-$name} d rc schema=''
  mkdir -p "$root/tmp" "$root/luna" "$wt"
  git -C "$wt" init -q
  git -C "$wt" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
  printf 'same brief for both backends\n' > "$prompt"
  if [[ $name == capacity ]]; then
    schema="$test_root/$name/schema.json"
    printf '{"type":"object"}\n' > "$schema"
  fi
  d="$root/luna/$key"
  mkdir -p "$d"
  [[ -z $history ]] || printf '%s\n' "$history" > "$root/luna/rounds.log"

  if timeout --signal=TERM --kill-after=1 "${WORKER_TEST_RUN_TIMEOUT:-$timeout_seconds}" \
    env CODEX_MODEL="$initial_model" WORKER_SCRATCH_ROOT="$root" WORKER_BACKEND="$initial_backend" \
      WORKER_STALL_SECONDS="$stall_seconds" WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
      FAKE_ZC_MODE="$zc_mode" FAKE_LUNA_MODE="$luna_mode" \
      bash "$worker_script" "$key" "$wt" "$prompt" "$schema" > "$test_root/$name.stdout" 2> "$test_root/$name.stderr"; then
    rc=0
  else
    rc=$?
  fi
  if [[ $rc != "$expected_rc" ]]; then
    fail "$name returned rc=$rc, expected rc=$expected_rc (details: $test_root/$name.stderr)"
  fi
  CASE_DIR=$d
}

run_case capacity 0 success capacity 8 4 luna gpt-6.1-terra
[[ $(cat "$CASE_DIR/models") == $'gpt-6.1-terra\ngpt-6-luna' ]] || fail 'terra capacity did not retry on default exactly once'
assert_file_contains "$CASE_DIR/stderr.log" 'model-fallback gpt-6.1-terra -> default'
[[ $(wc -l < "$CASE_DIR/briefs") == 2 ]] || fail 'fallback did not reuse the brief'
[[ $(sort -u "$CASE_DIR/briefs") == 'same brief for both backends' ]] || fail 'fallback changed the brief'
[[ $(wc -l < "$CASE_DIR/schemas") == 2 ]] || fail 'fallback did not preserve schema argument'
[[ $(sort -u "$CASE_DIR/schemas") == "$test_root/capacity/schema.json" ]] || fail 'fallback changed the schema path'
[[ ! -e $CASE_DIR/failover && $(cat "$CASE_DIR/backend") == luna ]] || fail 'capacity fallback switched backend'
[[ $(wc -l < "${CASE_DIR%/*}/rounds.log") == 1 ]] || fail 'one worker invocation recorded more than one round'
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z test-capacity gpt-6-luna rc=0$' "${CASE_DIR%/*}/rounds.log" || fail 'round log has wrong timestamp, key, model or rc'
printf 'PASS terra capacity -> default, same brief/unit, one round logged\n'

FAKE_CAPACITY_MODEL=gpt-6.1-sol run_case sol-capacity 0 success capacity 8 4 luna gpt-6.1-sol
[[ $(cat "$CASE_DIR/models") == $'gpt-6.1-sol\ngpt-6-luna' ]] || fail 'sol capacity did not fall back to default'
assert_file_contains "$CASE_DIR/stderr.log" 'model-fallback gpt-6.1-sol -> default'
run_case capacity-limit 1 success capacity_always 8 4 luna gpt-6.1-terra
[[ $(cat "$CASE_DIR/models") == $'gpt-6.1-terra\ngpt-6-luna' ]] || fail 'capacity retry was not limited to one'
assert_file_contains "${CASE_DIR%/*}/rounds.log" 'test-capacity-limit gpt-6-luna rc=1'
run_case default-capacity 1 success capacity_always 8 4 luna
[[ $(cat "$CASE_DIR/models") == gpt-6-luna ]] || fail 'default model retried without a next model'
run_case capacity-success 0 success capacity_success 8 4 luna gpt-6.1-terra
[[ $(cat "$CASE_DIR/models") == gpt-6.1-terra ]] || fail 'capacity text on rc=0 triggered fallback'
run_case ordinary-failure 1 success fail 8 4 luna gpt-6.1-terra
[[ $(cat "$CASE_DIR/models") == gpt-6.1-terra ]] || fail 'ordinary failure triggered model fallback'
run_case capacity-health 0 success capacity_fatal 8 4 luna gpt-6.1-terra
[[ $(cat "$CASE_DIR/models") == $'gpt-6.1-terra\ngpt-6-luna' ]] || fail 'model fallback was skipped before health failover'
[[ $(cat "$CASE_DIR/backend") == zc ]] || fail 'fatal model retry did not preserve health failover'
assert_file_contains "$CASE_DIR/stderr.log" 'model-fallback gpt-6.1-terra -> default'
printf 'PASS terra/sol -> default; retries bounded and limited to nonzero capacity failures\n'

history=$'2026-10-27T00:00:00Z go1-3861 gpt-6.1-terra rc=1\n2026-10-27T01:00:00Z go2-3861 gpt-6.1-terra rc=75'
run_case escalated 0 success success 8 4 luna gpt-6.1-terra go3-3861 "$history"
[[ $(cat "$CASE_DIR/models") == gpt-6.1-terra ]] || fail 'two failed rounds did not start directly on terra'
assert_file_contains "${CASE_DIR%/*}/rounds.log" 'go3-3861 gpt-6.1-terra rc=0'
history=$'2026-10-27T00:00:00Z go1-3861 gpt-6.1-terra rc=1\n2026-10-27T01:00:00Z go2-3861 gpt-6.1-terra rc=0\n2026-10-27T02:00:00Z go2-13861 gpt-6.1-terra rc=1'
run_case un-escalated 0 success success 8 4 luna gpt-6.1-terra go3-3861 "$history"
[[ $(cat "$CASE_DIR/models") == gpt-6.1-terra ]] || fail 'successful or other-ticket rounds counted as failures'
printf 'PASS escalation counts only nonzero rounds for the same ticket\n'

run_case hang 0 hang success 2 8
hang_dir=$CASE_DIR
assert_file_contains "$hang_dir/failover" 'no progress'
[[ -f $hang_dir/hang-terminated ]] || fail 'hang backend process group did not receive TERM'
[[ -f $hang_dir/hang-child-terminated ]] || fail 'hang backend child process did not receive group TERM'
[[ -f "$test_root/hang/worktree/.partial-from-zc" ]] || fail 'partial worktree edit was lost'
[[ -f "$test_root/hang/worktree/fallback-saw-partial" ]] || fail 'fallback did not reuse the same worktree'
[[ $(cat "$hang_dir/backend") == luna ]] || fail 'hang case did not finish on luna'
[[ -f "$test_root/hang/.scratch/tmp/zc-breaker" ]] || fail 'hang did not open the zc breaker'
assert_file_contains "$hang_dir/last.md" 'same brief for both backends'
printf 'PASS hang -> failover after threshold; process group stopped; partial worktree preserved\n'

root="$test_root/hang/.scratch"
wt="$test_root/hang/worktree"
prompt="$test_root/hang/brief.md"
key=test-after-zc-breaker
timeout 4 env -u WORKER_BACKEND WORKER_SCRATCH_ROOT="$root" WORKER_STALL_SECONDS=8 WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
  FAKE_ZC_MODE=success FAKE_LUNA_MODE=success bash "$worker_script" "$key" "$wt" "$prompt" \
  > "$test_root/after-zc-breaker.stdout" 2> "$test_root/after-zc-breaker.stderr"
[[ $(cat "$root/luna/$key/backend") == luna ]] || fail 'new automatic job ignored the open zc breaker'
printf 'PASS new jobs avoid zc while its breaker is open\n'

run_case gated 0 gated success 1 8
[[ ! -e $CASE_DIR/failover && $(cat "$CASE_DIR/backend") == zc ]] || fail 'waiting at the capacity gate was treated as a stall'
printf 'PASS waiting at the capacity gate is not a stall\n'

run_case fatal 0 fatal success 8 4
fatal_dir=$CASE_DIR
assert_file_contains "$fatal_dir/failover" 'repeated AI_APICallError'
[[ -f "$test_root/fatal/.scratch/tmp/zc-breaker" ]] || fail 'fatal pattern did not open the zc breaker'
[[ $(cat "$fatal_dir/backend") == luna ]] || fail 'fatal case did not finish on luna'
assert_file_contains "$fatal_dir/briefs" 'Resume after backend failover'
printf 'PASS fatal stderr pattern -> immediate failover\n'

run_case builtin 0 builtin_info success 8 4
builtin_dir=$CASE_DIR
[[ ! -e $builtin_dir/failover && $(cat "$builtin_dir/backend") == zc ]] || fail 'Built-in missing informational line caused failover'
run_case builtin-failure 1 builtin_fail success 8 4
[[ ! -e $CASE_DIR/failover ]] || fail 'Built-in missing was classified as fatal'
run_case builtin-noise 0 builtin_noise success 2 8
assert_file_contains "$CASE_DIR/failover" 'no progress'
printf 'PASS Built-in lines are neither fatal nor meaningful progress\n'

run_case quota 0 fatal_quota success 8 4
quota_dir=$CASE_DIR
assert_file_contains "$quota_dir/failover" 'authentication or quota error'
[[ $(cat "$quota_dir/backend") == luna ]] || fail 'quota case did not finish on luna'
printf 'PASS auth/quota stderr pattern -> immediate failover\n'

run_case turn-failed 0 turn_failed success 8 4
turn_dir=$CASE_DIR
assert_file_contains "$turn_dir/failover" 'backend=zc failed; next=luna; reason=fatal stderr pattern: Turn execution failed'
[[ $(cat "$turn_dir/backend") == luna ]] || fail 'Turn execution failed did not fail over to luna'
[[ $(cat "$turn_dir/rc") == 0 ]] || fail 'Turn execution failed failover did not succeed'
[[ -f "$test_root/turn-failed/worktree/.partial-from-zc" ]] || fail 'Turn execution failed lost the partial worktree edit'
[[ -f "$test_root/turn-failed/worktree/fallback-saw-partial" ]] || fail 'luna fallback did not continue in the zc worktree'
[[ -f "$test_root/turn-failed/.scratch/tmp/zc-breaker" ]] || fail 'Turn execution failed did not open the zc breaker'
assert_file_contains "$turn_dir/last.md" 'success from luna'
printf 'PASS zc Turn execution failed -> luna failover with reason; partial worktree preserved\n'

run_case success 0 success success 2 6
success_dir=$CASE_DIR
[[ ! -e $success_dir/failover ]] || fail 'successful first backend recorded an unexpected failover'
[[ ! -e "$test_root/success/.scratch/tmp/zc-breaker" ]] || fail 'successful run opened the zc breaker'
[[ $(cat "$success_dir/backend") == zc ]] || fail 'successful run changed backend'
printf 'PASS success -> no failover\n'

run_case double 75 fatal fail 8 4
double_dir=$CASE_DIR
[[ $(cat "$double_dir/rc") == 75 ]] || fail 'double failure did not write rc=75'
assert_file_contains "${double_dir%/*}/rounds.log" 'test-double gpt-6-luna rc=75'
assert_file_contains "$double_dir/failover" 'repeated AI_APICallError'
assert_file_contains "$double_dir/failover" 'luna exited rc=1'
printf 'PASS both backends fail -> rc=75 with clear reason\n'

run_case luna-fatal 0 success fatal 8 4 luna
luna_dir=$CASE_DIR
assert_file_contains "$luna_dir/failover" 'repeated AI_APICallError'
[[ $(cat "$luna_dir/backend") == zc ]] || fail 'luna failure did not fail over to zc'
[[ -f "$test_root/luna-fatal/.scratch/tmp/luna-breaker" ]] || fail 'luna failure did not open the luna breaker'
printf 'PASS luna failure -> zc failover and luna breaker\n'

root="$test_root/luna-fatal/.scratch"
wt="$test_root/luna-fatal/worktree"
prompt="$test_root/luna-fatal/brief.md"
key=test-after-luna-breaker
timeout 4 env -u WORKER_BACKEND WORKER_SCRATCH_ROOT="$root" WORKER_STALL_SECONDS=8 WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
  FAKE_ZC_MODE=success FAKE_LUNA_MODE=success bash "$worker_script" "$key" "$wt" "$prompt" \
  > "$test_root/after-breaker.stdout" 2> "$test_root/after-breaker.stderr"
[[ $(cat "$root/luna/$key/backend") == zc ]] || fail 'unset WORKER_BACKEND did not route around the open luna breaker'
printf 'PASS unset backend routes around the open luna breaker\n'
rm -f "$root/tmp/luna-breaker"; touch "$root/tmp/zc-breaker"; key=test-zc-breaker
timeout 4 env -u WORKER_BACKEND WORKER_SCRATCH_ROOT="$root" WORKER_STALL_SECONDS=8 WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
  FAKE_ZC_MODE=success FAKE_LUNA_MODE=success bash "$worker_script" "$key" "$wt" "$prompt" >/dev/null 2>&1
[[ $(cat "$root/luna/$key/backend") == luna ]] || fail 'open zc breaker did not route to luna'
printf 'PASS open zc breaker routes to luna\n'

# Simulate lw stop: the worker and backend have different sessions/process groups.
root="$test_root/term/.scratch"; wt="$test_root/term/worktree"; prompt="$test_root/term/brief.md"; key=test-term
mkdir -p "$root/tmp" "$root/luna/$key" "$wt"
printf 'stop this backend\n' > "$prompt"
d="$root/luna/$key"
setsid env WORKER_SCRATCH_ROOT="$root" WORKER_BACKEND=luna CODEX_MODEL=gpt-6.1-terra \
  WORKER_STALL_SECONDS=60 WORKER_HEALTH_INTERVAL_SECONDS=0.05 FAKE_LUNA_MODE=hang \
  bash "$worker_script" "$key" "$wt" "$prompt" > "$test_root/term.stdout" 2> "$test_root/term.stderr" &
worker_pid=$!
for ((i=0; i<200; i++)); do
  [[ ! -s $d/hang-child.pid ]] || break
  sleep 0.05
done
[[ -s $d/backend-run.pid && -s $d/hang-child.pid ]] || fail 'TERM fixture never started backend and child'
backend_pid=$(cat "$d/backend-run.pid"); child_pid=$(cat "$d/hang-child.pid")
[[ $worker_pid != "$backend_pid" ]] || fail 'backend was not in a separate session'
kill -TERM -- "-$worker_pid"
term_rc=0; wait "$worker_pid" || term_rc=$?
[[ $term_rc == 143 ]] || fail "TERM worker returned $term_rc instead of 143"
kill -0 "$backend_pid" 2>/dev/null && fail 'orphaned backend survived worker TERM'
kill -0 "$child_pid" 2>/dev/null && fail 'backend child survived worker TERM'
[[ -f $d/hang-terminated && -f $d/hang-child-terminated ]] || fail 'TERM did not reach entire backend group'
assert_file_contains "$root/luna/rounds.log" 'test-term gpt-6.1-terra rc=143'
printf 'PASS worker TERM stops backend session and child, logs rc=143\n'
