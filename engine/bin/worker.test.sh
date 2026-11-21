#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

worker_source=$(realpath "${1:-$(dirname "$0")/worker}")
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
test_root=$(mktemp -d)
cleanup() {
  local pid_file pid waited
  local -a watched=() alive
  while IFS= read -r pid_file; do
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [[ $pid =~ ^[0-9]+$ ]] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    sleep 0.1
    kill -KILL -- "-$pid" 2>/dev/null || true
    watched+=("$pid")
  done < <(find "$test_root" -name backend-run.pid -type f 2>/dev/null)
  for pid_file in "$test_root"/fake-remote-*/scopes/*.pid; do
    [[ -f $pid_file ]] || continue
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ $pid =~ ^[0-9]+$ ]] && kill -TERM "$pid" 2>/dev/null; then watched+=("$pid"); fi
  done
  mapfile -t -O "${#watched[@]}" watched < <(jobs -p)
  # rm once raced a process still writing under test_root (main runs 44932375273 and 44941210617: every case
  # green, exit 1, "Directory not empty"). Wait for what was signalled and the test's own jobs first; if the
  # retry still loses, name what is left so the next red run names the writer.
  waited=0
  while (( waited < 5 )); do
    alive=()
    for pid in "${watched[@]}"; do kill -0 "$pid" 2>/dev/null && alive+=("$pid"); done
    ((${#alive[@]})) || break
    watched=("${alive[@]}")
    sleep 0.1
    waited=$((waited + 1))
  done
  if ! rm -rf -- "$test_root" "$test_env_root"; then
    sleep 0.2
    if ! rm -rf -- "$test_root" "$test_env_root"; then
      find "$test_root" | head || true
      exit 1
    fi
  fi
}
trap 'cleanup; rm -rf -- "$test_env_root"' EXIT
mkdir -p "$test_root/home" "$test_root/agent-home"
export HOME="$test_root/home" AGENT_HOME="$test_root/agent-home"
export ZF_WORKER_HOST=local
mkdir -p "$test_root/config-root" "$test_root/lib.d"
cp "$script_dir/../config.sh" "$test_root/config.sh"
cp "$script_dir/../lib.d/worker-remote-handoff.sh" "$test_root/lib.d/worker-remote-handoff.sh"
cat > "$test_root/thread-budget.sh" <<'EOF'
agent_thread_budget() { :; }
EOF
cat > "$test_root/lib.d/worker-output-cap.sh" <<'EOF'
worker_output_cap_chars() { printf '30000\n'; }
EOF

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
if [[ $backend == luna && ${FAKE_REMOTE_LUNA:-0} == 1 ]]; then exec "$REAL_LUNA_SCRIPT" "$@"; fi
if [[ $backend == zc && ${FAKE_REMOTE_ZC:-0} == 1 ]]; then exec "$REAL_ZC_SCRIPT" "$@"; fi
if [[ $backend == zc ]]; then mode=${FAKE_ZC_MODE:-success}; else mode=${FAKE_LUNA_MODE:-success}; fi
if [[ $backend == zc && ${FAKE_REAL_ZC:-0} == 1 ]]; then exec "$REAL_ZC_SCRIPT" "$@"; fi
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
if [[ $mode == models_manager_401 ]]; then
  printf 'codex_models_manager: failed to refresh available models: unexpected status 401\n' >> "$d/stderr.log"
  sleep 0.3
  mode=success
fi
if [[ $mode == router_noise ]]; then  # 11-13: a tool error echoing the worker's own patch text is not a quota error
  printf '%s\n' '2026-11-13T23:06:51.939982Z ERROR codex_core::tools::router: error=apply_patch verification failed: Failed to find expected lines' \
    "        if grep -Fq 'API rate limit already exceeded' \"\$log\"; then" '          : > "$rate_limit_signal"  # 429 unauthorized quota exceeded' >> "$d/stderr.log"
  sleep 0.3
  mode=success
fi
if [[ $mode == db_locked* ]]; then
  # 11-21 queue 899: every zcode process shares one sqlite db; a locked turn is transient contention. The stray 429
  # usage line is what made the real verdict fatal, so the retry must ride the same fatal path. db_locked:2 fails twice.
  db_locked_times=${mode#db_locked}; db_locked_times=${db_locked_times#:}
  [[ $db_locked_times =~ ^[0-9]+$ ]] || db_locked_times=1
  db_locked_count=$(($(cat "$scratch/tmp/db-locked-$key.count" 2>/dev/null || echo 0) + 1))
  printf '%s\n' "$db_locked_count" > "$scratch/tmp/db-locked-$key.count"
  if (( db_locked_count <= db_locked_times )); then
    printf '%s\n' '{"type":"turn.failed","error":{"code":"ERR_SQLITE_ERROR","message":"database is locked"}}' > "$d/events.jsonl"
    printf '%s\n' '{"type":"usage","detail":"window 429 of the 5h quota"}' >> "$d/events.jsonl"
    exit 1
  fi
  mode=success
fi
if [[ $mode == auth_turn_failed ]]; then
  printf 'codex_models_manager: failed to refresh available models: unexpected status 401\n' >> "$d/stderr.log"
  printf '%s\n' '{"type":"turn.failed","error":{"code":"authentication_error","message":"Authentication failed: token expired (401)"}}' > "$d/events.jsonl"
  exit 1
fi
if [[ $mode == model_not_found ]]; then
  printf '%s\n' '{"type":"turn.failed","error":{"code":"model_not_found","message":"The requested model is not supported"}}' > "$d/events.jsonl"
  exit 1
fi
[[ $mode == gated ]] && { sleep 7; mode=success; }   # queued at the capacity gate past the stall threshold
[[ $mode == hang || $mode == builtin_noise || $mode == queued ]] || echo $$ > "$d/codex.pid"   # real backends write it once past the capacity gate
case "$mode" in
  hang|builtin_noise)
    : > "$d/events.jsonl"
    printf 'partial from %s\n' "$backend" > "$cwd/.partial-from-$backend"
    bash -c 'trap '\''touch "$1"; exit 143'\'' TERM; touch "$2"; while :; do read -r -t 0.05 _ || true; done' _ "$d/hang-child-terminated" "$d/hang-child-ready" &
    echo $! > "$d/hang-child.pid"
    trap 'touch "$d/hang-terminated"; wait; exit 143' TERM
    while [[ ! -e $d/hang-child-ready ]]; do read -r -t 0.05 _ || true; done
    echo $$ > "$d/codex.pid"
    while :; do
      if [[ $mode == builtin_noise ]]; then
        printf 'ZCode Built-in synced\n' >> "$d/stderr.log"
      else
        printf 'scheduler skipped (not-due)\n' >> "$d/stderr.log"
      fi
      read -r -t 0.05 _ || true
    done
    ;;
  queued)
    # Never passes the capacity gate: no codex.pid, no events (2026-11-07 vecta-roll-count sat 14 min like this).
    trap 'exit 143' TERM
    while :; do read -r -t 0.05 _ || true; done
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
cp "$script_dir/worker-remote.py" "$test_root/bin/worker-remote.py"
chmod +x "$test_root/bin/worker-remote.py"
cp "$worker_script" "$test_root/bin/worker"; worker_script="$test_root/bin/worker"
cp "$script_dir/zc" "$test_root/bin/real-zc"
cat > "$test_root/bin/luna-capacity.sh" <<'EOF'
box_has_room() { return 0; }
EOF
cat > "$test_root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$test_root/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
while (($#)) && [[ $1 != -- ]]; do shift; done
[[ ${1:-} == -- ]] && shift
exec "$@"
EOF
chmod +x "$test_root/bin/systemctl" "$test_root/bin/systemd-run"
cat > "$test_root/bin/zf-stop" <<'EOF'
#!/usr/bin/env bash
exec bash "$ZF_TEST_WORKER_STOP_SCRIPT" "$@"
EOF
chmod +x "$test_root/bin/zf-stop"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_file_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }

run_case() {
  local name=$1 expected_rc=$2 zc_mode=$3 luna_mode=$4 stall_seconds=$5 timeout_seconds=$6
  local initial_backend=${7-zc}
  local initial_model=${8:-gpt-6-luna} history=${10:-}
  local gate_queue_seconds=${12:-}
  local zc_available=${13:-yes}
  local breaker=${14:-}
  local -a queue_override=() zcode_override=()
  [[ -z $gate_queue_seconds ]] || queue_override=(WORKER_GATE_QUEUE_SECONDS="$gate_queue_seconds")
  local root="$test_root/$name/.scratch" wt="$test_root/$name/worktree" prompt="$test_root/$name/brief.md"
  local agent_home="$test_root/$name/agent-home" home="$test_root/$name/home" hold=${11:-}
  local key=${9:-test-$name} d rc schema=''
  mkdir -p "$root/tmp" "$root/luna" "$wt" "$agent_home" "$home"
  if [[ $zc_available == yes ]]; then
    mkdir -p "$root/zc-src/bin"
    printf '#!/bin/sh\nexit 0\n' > "$root/zc-src/bin/zcode"
    chmod +x "$root/zc-src/bin/zcode"
    zcode_override=(ZF_ZCODE_BIN="$root/zc-src/bin/zcode")
  fi
  if [[ $hold == active ]]; then
    printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$agent_home/zcode-exhausted-until"
  elif [[ $hold == luna ]]; then
    printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$agent_home/codex-exhausted-until"
  fi
  [[ -z $breaker ]] || touch "$root/tmp/${breaker}-breaker"
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
    env -u WORKER_GATE_QUEUE_SECONDS -u ZF_ZCODE_BIN -u ZCODE_BIN HOME="$home" AGENT_HOME="$agent_home" \
      ZF_ENGINE_DIR="$test_root" ZF_CONFIG_ROOT="$test_root/config-root" PATH="$test_root/bin:/usr/bin:/bin" \
      CODEX_MODEL="$initial_model" WORKER_SCRATCH_ROOT="$root" WORKER_BACKEND="$initial_backend" \
      WORKER_STALL_SECONDS="$stall_seconds" WORKER_HEALTH_INTERVAL_SECONDS=0.05 "${zcode_override[@]}" \
      FAKE_ZC_MODE="$zc_mode" FAKE_LUNA_MODE="$luna_mode" "${queue_override[@]}" \
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

run_prompt_case() {
  local name=$1 prompt=$2 home=$3 expected_rc=$4
  local root="$test_root/$name/.scratch" agent_home="$test_root/$name/agent-home" rc=0
  mkdir -p "$root/tmp" "$home" "$agent_home"
  if timeout --signal=TERM --kill-after=1 "${WORKER_TEST_RUN_TIMEOUT:-10}" \
    env HOME="$home" AGENT_HOME="$agent_home" CODEX_MODEL=gpt-6-luna \
      WORKER_SCRATCH_ROOT="$root" WORKER_BACKEND=luna \
      WORKER_STALL_SECONDS=8 WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
      FAKE_ZC_MODE=success FAKE_LUNA_MODE=success \
      bash "$worker_script" "$name" "$test_root" "$prompt" \
      > "$test_root/$name.stdout" 2> "$test_root/$name.stderr"; then
    rc=0
  else
    rc=$?
  fi
  [[ $rc == "$expected_rc" ]] || fail "$name returned rc=$rc, expected rc=$expected_rc (details: $test_root/$name.stderr)"
}

run_auto_pick() {
  local name=$1 root=$2 wt=$3 prompt=$4 home=$5 agent_home=$6 rc
  local path=${7:-$test_root/bin:/usr/bin:/bin} run_real_zc=${8:-0} zcode_bin=${9:-}
  local -a zcode_override=()
  [[ -z $zcode_bin ]] || zcode_override=(ZF_ZCODE_BIN="$zcode_bin")
  if timeout --signal=TERM --kill-after=1 5 \
    env -u WORKER_BACKEND -u WORKER_GATE_QUEUE_SECONDS -u ZF_ZCODE_BIN -u ZCODE_BIN \
      HOME="$home" AGENT_HOME="$agent_home" ZF_ENGINE_DIR="$test_root" ZF_CONFIG_ROOT="$test_root/config-root" \
      PATH="$path" FAKE_REAL_ZC="$run_real_zc" REAL_ZC_SCRIPT="$test_root/bin/real-zc" \
      ZCODE_STUB_RAN="$test_root/$name.zcode-ran" \
      ZCODE_PROBE_LOG="$test_root/$name.probe-log" "${zcode_override[@]}" \
      WORKER_SCRATCH_ROOT="$root" WORKER_STALL_SECONDS=8 WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
      FAKE_ZC_MODE=success FAKE_LUNA_MODE=success \
      bash "$worker_script" "$name" "$wt" "$prompt" \
      > "$test_root/$name.stdout" 2> "$test_root/$name.stderr"; then
    :
  else
    rc=$?
    fail "$name returned rc=$rc, expected rc=0 (details: $test_root/$name.stderr)"
  fi
}

auto_root="$test_root/auto-missing-zc/.scratch"
auto_home="$test_root/auto-missing-zc/home"
auto_agent_home="$test_root/auto-missing-zc/agent-home"
auto_worktree="$test_root/auto-missing-zc/worktree"
auto_prompt="$test_root/auto-missing-zc/brief.md"
mkdir -p "$auto_root/tmp" "$auto_root/luna" "$auto_home" "$auto_agent_home" "$auto_worktree"
git -C "$auto_worktree" init -q
git -C "$auto_worktree" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
printf 'same brief for both backends\n' > "$auto_prompt"
[[ ! -e "$auto_root/zc-src" && ! -e "$auto_agent_home/zcode-exhausted-until" &&
   ! -e "$auto_root/tmp/zc-breaker" && ! -e "$auto_root/tmp/luna-breaker" ]] || fail 'missing zc fixture has a zc install, hold marker, or breaker file'
missing_zc_picks=''
for pick in 1 2 3 4; do
  name="auto-missing-zc-$pick"
  run_auto_pick "$name" "$auto_root" "$auto_worktree" "$auto_prompt" "$auto_home" "$auto_agent_home"
  picked=$(cat "$auto_root/luna/$name/backend")
  missing_zc_picks+="${missing_zc_picks:+,}$picked"
done
[[ $missing_zc_picks == luna,luna,luna,luna ]] || fail "automatic picks chose $missing_zc_picks with zcode missing; expected luna every time"
for pick in 1 2 3 4; do
  name="auto-missing-zc-$pick"
  [[ $(wc -l < "$test_root/$name.stderr") == 1 ]] || fail "$name did not print exactly one missing-zcode reroute line"
  assert_file_contains "$test_root/$name.stderr" "worker: zcode executable not runnable: $auto_root/zc-src/bin/zcode (probe rc=127); using luna instead of zc"
done
printf 'PASS automatic picks avoid non-runnable zcode and print the probe rc\n'

stub_root="$test_root/auto-stub-zc/.scratch"
mkdir -p "$stub_root/zc-src/bin" "$stub_root/tmp" "$stub_root/luna"
cat > "$stub_root/zc-src/bin/zcode" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then printf 'probe\n' >> "$ZCODE_PROBE_LOG"; exit 0; fi
exit 0
EOF
chmod +x "$stub_root/zc-src/bin/zcode"
run_auto_pick auto-stub-zc "$stub_root" "$auto_worktree" "$auto_prompt" "$auto_home" "$auto_agent_home" \
  "$test_root/bin:/usr/bin:/bin" 0 "$stub_root/zc-src/bin/zcode"
[[ $(cat "$stub_root/luna/auto-stub-zc/backend") == zc &&
   $(cat "$stub_root/luna/auto-stub-zc/attempt-backend") == zc ]] || fail 'automatic pick did not choose executable zcode again'
run_auto_pick auto-stub-zc "$stub_root" "$auto_worktree" "$auto_prompt" "$auto_home" "$auto_agent_home" \
  "$test_root/bin:/usr/bin:/bin" 0 "$stub_root/zc-src/bin/zcode"
[[ $(wc -l < "$test_root/auto-stub-zc.probe-log") == 1 ]] || fail 'same-boot worker call ran the zcode probe more than once'
printf 'PASS automatic pick chooses runnable zcode and reuses its same-boot probe\n'

shim_root="$test_root/auto-shim-missing-target"
shim_worker_root="$shim_root/.scratch"
shim_home="$shim_root/home"
shim_agent_home="$shim_root/agent-home"
mkdir -p "$shim_worker_root/tmp" "$shim_worker_root/luna" "$shim_home" "$shim_agent_home" "$shim_root/bin"
cat > "$shim_root/bin/zcode" <<EOF
#!/bin/sh
printf 'probe\\n' >> "\$ZCODE_PROBE_LOG"
exec "$shim_root/missing-target" "\$@"
EOF
chmod +x "$shim_root/bin/zcode"
run_auto_pick auto-shim-missing-target "$shim_worker_root" "$auto_worktree" "$auto_prompt" "$shim_home" "$shim_agent_home" \
  "$test_root/bin:/usr/bin:/bin" 0 "$shim_root/bin/zcode"
[[ $(cat "$shim_worker_root/luna/auto-shim-missing-target/backend") == luna &&
   $(cat "$shim_worker_root/luna/auto-shim-missing-target/rc") == 0 ]] || fail 'missing-target shim did not fall back to luna successfully'
assert_file_contains "$test_root/auto-shim-missing-target.stderr" \
  "worker: zcode executable not runnable: $shim_root/bin/zcode (probe rc=127); using luna instead of zc"
run_auto_pick auto-shim-missing-target "$shim_worker_root" "$auto_worktree" "$auto_prompt" "$shim_home" "$shim_agent_home" \
  "$test_root/bin:/usr/bin:/bin" 0 "$shim_root/bin/zcode"
[[ $(wc -l < "$test_root/auto-shim-missing-target.probe-log") == 1 ]] || fail 'cached failed probe ran the shim more than once'
[[ $(grep -c 'WORKER-ZCODE-UNRUNNABLE' "$shim_agent_home/logs/head-watch.alerts") == 1 ]] || fail 'unrunnable configured zcode did not alert exactly once per boot'
printf 'PASS missing-target shim routes to luna, caches rc=127, and alerts once per boot\n'

# 11-21 queue 884: a cached failed probe must not stand for the whole boot after zcode is reinstalled.
stale_case="$test_root/zc-stale-cache"
stale_root="$stale_case/.scratch"; stale_wt="$stale_case/worktree"; stale_prompt="$stale_case/brief.md"
stale_home="$stale_case/home"; stale_agent_home="$stale_case/agent-home"
stale_zcode="$stale_root/zc-src/bin/zcode"; stale_probe_log="$test_root/zc-stale-cache.probe-log"
stale_cache="$stale_root/tmp/zc-runnable"; stale_alerts="$stale_agent_home/logs/head-watch.alerts"
mkdir -p "$stale_root/tmp" "$stale_root/luna" "$stale_root/zc-src/bin" "$stale_home" "$stale_agent_home" "$stale_wt"
git -C "$stale_wt" init -q
git -C "$stale_wt" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
printf 'stale cache brief\n' > "$stale_prompt"
write_stale_zcode() {  # $1 = the --version probe's exit code, $2 = stub path (default $stale_zcode); rewriting refreshes the mtime
  local exe=${2:-$stale_zcode}
  cat > "$exe" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == --version ]]; then printf 'probe\n' >> "\$ZCODE_PROBE_LOG"; exit $1; fi
exit 0
EOF
  chmod +x "$exe"
}
run_explicit_zc() {
  local name=$1 zcode_bin=${2:-$stale_zcode}
  timeout --signal=TERM --kill-after=1 8 \
    env -u WORKER_GATE_QUEUE_SECONDS -u ZCODE_BIN HOME="$stale_home" AGENT_HOME="$stale_agent_home" \
      ZF_ENGINE_DIR="$test_root" ZF_CONFIG_ROOT="$test_root/config-root" PATH="$test_root/bin:/usr/bin:/bin" \
      CODEX_MODEL=gpt-6-luna WORKER_SCRATCH_ROOT="$stale_root" WORKER_BACKEND=zc \
      ZF_ZCODE_BIN="$zcode_bin" ZCODE_PROBE_LOG="$stale_probe_log" \
      WORKER_STALL_SECONDS=8 WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
      FAKE_ZC_MODE=success FAKE_LUNA_MODE=success \
      bash "$worker_script" "$name" "$stale_wt" "$stale_prompt" \
      > "$test_root/$name.stdout" 2> "$test_root/$name.stderr" || fail "$name returned nonzero (details: $test_root/$name.stderr)"
}
write_stale_zcode 127
run_explicit_zc zc-stale-reroute
stale_d="$stale_root/luna/zc-stale-reroute"
[[ $(cat "$stale_d/backend") == luna ]] || fail 'broken zcode did not reroute an explicit zc run to luna'
[[ $(wc -l < "$stale_probe_log") == 1 ]] || fail 'the first failing run did not probe exactly once'
[[ $(wc -l < "$test_root/zc-stale-reroute.stderr") == 1 ]] || fail 'explicit reroute printed more than one stderr line'
assert_file_contains "$test_root/zc-stale-reroute.stderr" "worker: zcode executable not runnable: $stale_zcode (probe rc=127); using luna instead of zc"
assert_file_contains "$stale_d/placement.log" "backend=zc rerouted to luna; reason=zcode executable not runnable: $stale_zcode (probe rc=127)"
[[ $(grep -c 'WORKER-ZCODE-UNRUNNABLE' "$stale_alerts") == 1 ]] || fail 'the first failing probe did not alert exactly once'
printf 'PASS explicit zc reroute records the reason in the run directory and alerts once\n'

touch "$stale_cache"  # keep the young failure under the 300 s expiry bound even if the runner stalls between runs
run_explicit_zc zc-stale-fresh
[[ $(cat "$stale_root/luna/zc-stale-fresh/backend") == luna ]] || fail 'a young cached failure did not keep routing to luna'
[[ $(wc -l < "$stale_probe_log") == 1 ]] || fail 'a young cached failure was probed again'
[[ $(grep -c 'WORKER-ZCODE-UNRUNNABLE' "$stale_alerts") == 1 ]] || fail 'a young cached failure wrote another alert'
printf 'PASS a fresh cached failure stands while the executable is unchanged\n'

touch -d '1 hour ago' "$stale_cache"; touch "$stale_zcode"  # the failure predates a change to the executable
run_explicit_zc zc-stale-refail
[[ $(cat "$stale_root/luna/zc-stale-refail/backend") == luna ]] || fail 'a still-broken changed executable did not reroute to luna'
[[ $(wc -l < "$stale_probe_log") == 2 ]] || fail 'an expired cached failure was not probed exactly once more'
[[ $(grep -c 'WORKER-ZCODE-UNRUNNABLE' "$stale_alerts") == 1 ]] || fail 'a failing probe twice in one boot wrote a second alert'
printf 'PASS an expired failure is probed again and still alerts only once per boot\n'

write_stale_zcode 0; touch -d '1 hour ago' "$stale_cache"  # reinstalled and working: the failure predates it
run_explicit_zc zc-stale-reinstalled
[[ $(cat "$stale_root/luna/zc-stale-reinstalled/backend") == zc &&
   $(cat "$stale_root/luna/zc-stale-reinstalled/attempt-backend") == zc ]] || fail 'a reinstalled working zcode was not probed again after the cached failure'
[[ $(wc -l < "$stale_probe_log") == 3 ]] || fail 'the reinstalled executable was not probed exactly once more'
printf 'PASS a cached failure expires when the executable is newer than the probe\n'

run_explicit_zc zc-stale-success-cached
[[ $(cat "$stale_root/luna/zc-stale-success-cached/backend") == zc ]] || fail 'a cached successful probe did not keep zc'
[[ $(wc -l < "$stale_probe_log") == 3 ]] || fail 'a cached successful probe was repeated in the same boot'
printf 'PASS a cached successful probe is not repeated in the same boot\n'

# Round 2: a package unpack can keep the archive's mtimes, so a reinstall can leave the executable older than the cached
# failure; a failure older than 300 s must expire even then. Second stub path: the first path's success cache stands for
# the whole boot, so a fresh failure needs a different argv key.
stale_zcode2="$stale_root/zc-src/bin/zcode2"
write_stale_zcode 127 "$stale_zcode2"
run_explicit_zc zc-stale-unpack-failure "$stale_zcode2"
[[ $(cat "$stale_root/luna/zc-stale-unpack-failure/backend") == luna ]] || fail 'the fresh second-path failure did not route to luna'
[[ $(wc -l < "$stale_probe_log") == 4 ]] || fail 'the second-path failing run did not probe exactly once'
[[ $(grep -c 'WORKER-ZCODE-UNRUNNABLE' "$stale_alerts") == 1 ]] || fail 'the second-path failing probe wrote another alert in the same boot'
write_stale_zcode 0 "$stale_zcode2"; touch -d '2 hours ago' "$stale_zcode2"; touch -d '1 hour ago' "$stale_cache"
run_explicit_zc zc-stale-unpack-retry "$stale_zcode2"
[[ $(cat "$stale_root/luna/zc-stale-unpack-retry/backend") == zc &&
   $(cat "$stale_root/luna/zc-stale-unpack-retry/attempt-backend") == zc ]] ||
  fail 'a failure older than 300 s with an executable older than the cache did not expire'
[[ $(wc -l < "$stale_probe_log") == 5 ]] || fail 'the time-expired cached failure was not probed exactly once more'
printf 'PASS a cached failure older than 300 s expires even when the executable is older than the cache\n'

path_root="$test_root/auto-path-zc/.scratch"
path_zcode_bin="$test_root/auto-path-zcode-bin"
mkdir -p "$path_root/tmp" "$path_root/luna" "$path_zcode_bin"
cat > "$path_zcode_bin/zcode" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then printf 'probe\n' >> "$ZCODE_PROBE_LOG"; exit 0; fi
touch "$ZCODE_STUB_RAN"
printf '%s\n' '{"type":"result","response":"PATH zcode stub ran"}'
EOF
chmod +x "$path_zcode_bin/zcode"
[[ ! -e "$path_root/zc-src" ]] || fail 'PATH zcode fixture unexpectedly has a zc-src bundle'
run_auto_pick auto-path-zc "$path_root" "$auto_worktree" "$auto_prompt" "$auto_home" "$auto_agent_home" \
  "$test_root/bin:$path_root/bin:$path_zcode_bin:/usr/bin:/bin" 1
[[ $(cat "$path_root/luna/auto-path-zc/backend") == zc &&
   $(cat "$path_root/luna/auto-path-zc/attempt-backend") == zc ]] || fail 'automatic pick did not choose PATH zcode'
[[ -f "$test_root/auto-path-zc.zcode-ran" ]] || fail 'bin/zc did not run the PATH zcode stub'
assert_file_contains "$path_root/luna/auto-path-zc/last.md" 'PATH zcode stub ran'
printf 'PASS automatic pick resolves PATH zcode and bin/zc runs it without a bundle\n'

run_case explicit-zc-hold 0 success success 8 4 zc gpt-6-luna '' '' active
[[ $(cat "$CASE_DIR/backend") == luna && $(cat "$CASE_DIR/attempt-backend") == luna ]] || fail 'explicit zc ignored the active quota hold'
[[ $(wc -l < "$test_root/explicit-zc-hold.stderr") == 1 ]] || fail 'explicit zc hold did not write exactly one stderr line'
[[ $(cat "$test_root/explicit-zc-hold.stderr") == 'worker: zcode quota hold active; using luna instead of zc' ]] || fail 'explicit zc hold wrote the wrong stderr line'
printf 'PASS explicit zc uses luna during the quota hold\n'

run_case luna-hold 75 success fatal 8 4 luna gpt-6-luna '' '' active
[[ $(cat "$CASE_DIR/rc") == 75 ]] || fail 'luna failure during quota hold did not write rc=75'
[[ $(cat "$CASE_DIR/backend") == luna && $(cat "$CASE_DIR/attempt-backend") == luna ]] || fail 'luna failure during quota hold started zc'
assert_file_contains "$CASE_DIR/failover" 'backend=zc skipped; reason=zcode quota hold active'
assert_file_contains "$CASE_DIR/failover" 'rc=75 reason=both backends failed: luna:'
printf 'PASS luna failure during quota hold exhausts both backends without starting zc\n'

# 11-21 queue 899 (1a): a fatal zc verdict must not start luna while Codex is held by a marker file.
run_case zc-failover-luna-held 75 fatal_quota success 8 4 zc gpt-6-luna '' '' luna
zc_luna_held_dir=$CASE_DIR
[[ $(cat "$zc_luna_held_dir/rc") == 75 ]] || fail 'zc failure with luna held did not write rc=75'
[[ $(cat "$zc_luna_held_dir/backend") == zc && $(cat "$zc_luna_held_dir/attempt-backend") == zc ]] || fail 'a marker-held luna was started after a zc failure'
assert_file_contains "$zc_luna_held_dir/failover" 'backend=luna skipped; reason=codex quota hold active'
assert_file_contains "$zc_luna_held_dir/failover" 'rc=75 reason=both backends failed: zc: fatal stderr pattern: authentication or quota error; luna: codex quota hold active'
printf 'PASS a fatal zc verdict does not start a marker-held luna\n'

# 11-21 queue 899 (2): a fresh zc breaker file alone is another task's verdict, not a hold; the requested zc run stays.
run_case zc-breaker-file-only 0 success success 8 4 zc gpt-6-luna '' '' luna '' yes zc
zc_breaker_dir=$CASE_DIR
[[ $(cat "$zc_breaker_dir/backend") == zc && $(cat "$zc_breaker_dir/attempt-backend") == zc ]] || fail 'a breaker-only zc run was rerouted or failed over'
assert_file_contains "$zc_breaker_dir/placement.log" 'backend=zc kept; reason=zc breaker file only, no quota or availability hold'
printf 'PASS a zc breaker file alone keeps the requested zc run on zc\n'

run_case explicit-zc-no-hold 0 success success 8 4 zc
[[ $(cat "$CASE_DIR/backend") == zc && $(cat "$CASE_DIR/attempt-backend") == zc ]] || fail 'explicit zc changed backend without a quota hold'
printf 'PASS explicit zc stays on zc without a quota hold\n'

run_case explicit-zc-missing 0 success success 8 4 zc gpt-6-luna '' '' '' '' no
[[ $(cat "$CASE_DIR/backend") == luna && $(cat "$CASE_DIR/attempt-backend") == luna ]] || fail 'explicit zc started without its executable'
[[ $(wc -l < "$test_root/explicit-zc-missing.stderr") == 1 ]] || fail 'explicit missing zc did not print exactly one reroute line'
[[ $(cat "$test_root/explicit-zc-missing.stderr") == "worker: zcode executable not runnable: $test_root/explicit-zc-missing/.scratch/zc-src/bin/zcode (probe rc=127); using luna instead of zc" ]] || fail 'explicit missing zc wrote the wrong reroute line'
printf 'PASS explicit zc reroutes to luna when its executable is missing\n'

run_case luna-failover-missing-zc 75 success fatal 8 4 luna gpt-6-luna '' '' '' '' no
[[ $(cat "$CASE_DIR/backend") == luna && $(cat "$CASE_DIR/attempt-backend") == luna ]] || fail 'luna failover started missing zc'
assert_file_contains "$CASE_DIR/failover" "backend=zc skipped; reason=zcode executable not runnable: $test_root/luna-failover-missing-zc/.scratch/zc-src/bin/zcode (probe rc=127)"
[[ $(wc -l < "$test_root/luna-failover-missing-zc.stderr") == 1 ]] || fail 'missing-zc failover did not print exactly one reason line'
assert_file_contains "$test_root/luna-failover-missing-zc.stderr" "zcode executable not runnable: $test_root/luna-failover-missing-zc/.scratch/zc-src/bin/zcode (probe rc=127)"
printf 'PASS luna failover skips missing zcode\n'

run_case agent-home-marker 0 success success 8 4 '' gpt-6-luna '' '' active
[[ $(cat "$CASE_DIR/backend") == luna && $(cat "$CASE_DIR/attempt-backend") == luna ]] || fail 'worker did not find the quota marker under AGENT_HOME'
[[ ! -e "$test_root/agent-home-marker/home/.zenoforge/zcode-exhausted-until" ]] || fail 'AGENT_HOME marker fixture also had a HOME marker'
printf 'PASS quota marker is resolved under AGENT_HOME\n'

missing_rc=0
env HOME="$test_root/missing-home" WORKER_SCRATCH_ROOT="$test_root/missing/.scratch" WORKER_BACKEND=luna \
  bash "$worker_script" test-missing "$test_root" 'brief text, not a path' > /dev/null 2> "$test_root/missing.stderr" || missing_rc=$?
[[ $missing_rc == 2 ]] || fail "missing prompt file returned rc=$missing_rc, expected 2"
assert_file_contains "$test_root/missing.stderr" 'worker: prompt file not found: brief text, not a path'
printf 'PASS a prompt that is not a file fails with rc=2\n'

brief_home="$test_root/session-home"
brief_prompt="$brief_home/.zenoforge/briefs/deny.md"
mkdir -p "${brief_prompt%/*}"
cat > "$brief_prompt" <<'BRIEF'
Issue: #6039
STOP: use the existing main behavior for unknown products.
BRIEF
run_prompt_case brief-missing-existing-path "$brief_prompt" "$brief_home" 2
assert_file_contains "$test_root/brief-missing-existing-path.stderr" 'worker: brief lacks "Existing path: <file:line of how main already handles the nearest sibling case>" (or "Existing path: none, <why>")'
printf 'PASS a session brief without Existing path fails with rc=2\n'

brief_prompt="$brief_home/.zenoforge/briefs/allow.md"
cat > "$brief_prompt" <<'BRIEF'
Issue: #6039
STOP: use the existing main behavior for unknown products.
Existing path: receipt-document-entry.ts:3405 new-SKU on confirm
BRIEF
run_prompt_case brief-with-existing-path "$brief_prompt" "$brief_home" 0
[[ $(cat "$test_root/brief-with-existing-path/.scratch/luna/brief-with-existing-path/backend") == luna ]] || fail 'valid session brief did not reach the backend'
printf 'PASS a session brief with Existing path reaches the backend\n'

outside_prompt="$test_root/outside-brief-path/prompt.md"
mkdir -p "${outside_prompt%/*}"
cat > "$outside_prompt" <<'PROMPT'
Issue: generated workflow prompt
STOP: continue the existing workflow.
PROMPT
run_prompt_case outside-session-brief "$outside_prompt" "$brief_home" 0
[[ $(cat "$test_root/outside-session-brief/.scratch/luna/outside-session-brief/backend") == luna ]] || fail 'prompt outside the session brief paths did not reach the backend'
printf 'PASS a prompt outside the session brief paths needs no Existing path\n'

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
timeout 4 env -u WORKER_BACKEND ZF_ZCODE_BIN="$root/zc-src/bin/zcode" WORKER_SCRATCH_ROOT="$root" \
  WORKER_STALL_SECONDS=8 WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
  FAKE_ZC_MODE=success FAKE_LUNA_MODE=success bash "$worker_script" "$key" "$wt" "$prompt" \
  > "$test_root/after-zc-breaker.stdout" 2> "$test_root/after-zc-breaker.stderr"
[[ $(cat "$root/luna/$key/backend") == luna ]] || fail 'new automatic job ignored the open zc breaker'
printf 'PASS new jobs avoid zc while its breaker is open\n'

# The stall bound must exceed one health pass under host load (a pass that took over 1s read the first output after the gate as a stall).
run_case gated 0 gated success 5 25
[[ ! -e $CASE_DIR/failover && $(cat "$CASE_DIR/backend") == zc ]] || fail 'waiting at the capacity gate was treated as a stall'
printf 'PASS waiting at the capacity gate is not a stall\n'

run_case fatal 0 fatal success 8 4
fatal_dir=$CASE_DIR
assert_file_contains "$fatal_dir/failover" 'repeated AI_APICallError'
[[ -f "$test_root/fatal/.scratch/tmp/zc-breaker" ]] || fail 'fatal pattern did not open the zc breaker'
[[ $(cat "$fatal_dir/backend") == luna ]] || fail 'fatal case did not finish on luna'
assert_file_contains "$fatal_dir/briefs" 'Resume after backend failover'
printf 'PASS fatal stderr pattern -> immediate failover\n'

LUNA_AGE_ADMIT_SECONDS=0 run_case late-gate-session 0 gated success 5 25 zc gpt-6-luna '' '' '' 20
late_gate_dir=$CASE_DIR
[[ -s "$late_gate_dir/codex.pid" && $(cat "$late_gate_dir/rc") == 0 && ! -e "$late_gate_dir/failover" ]] || fail 'session gate override did not wait through late admission'
printf 'PASS session gate override admits after the default bound\n'
LUNA_AGE_ADMIT_SECONDS=0 run_case late-gate-default 75 gated success 1 10 zc gpt-6-luna
[[ $(cat "$CASE_DIR/rc") == 75 ]] || fail 'unset gate queue override changed the default timeout'
printf 'PASS unset session gate override keeps the default timeout\n'
for invalid_queue_seconds in 0 -5 abc 99999999999999999999; do
  LUNA_AGE_ADMIT_SECONDS=0 run_case "late-gate-invalid-$invalid_queue_seconds" 75 gated success 1 10 zc gpt-6-luna '' '' '' "$invalid_queue_seconds"
  [[ $(cat "$CASE_DIR/rc") == 75 ]] || fail "invalid queue override $invalid_queue_seconds did not keep the default timeout"
done
printf 'PASS invalid session gate overrides keep the default timeout\n'

LUNA_AGE_ADMIT_SECONDS=0 run_case queued 75 queued success 1 8
queued_dir=$CASE_DIR
assert_file_contains "$queued_dir/failover" 'queued at the capacity gate'
assert_file_contains "$test_root/queued.stderr" 'worker: queued at the capacity gate'
[[ $(cat "$queued_dir/rc") == 75 && $(cat "$queued_dir/attempt-backend") == zc ]] || fail 'queue timeout did not end rc=75 on the first backend'
[[ ! -e "$test_root/queued/.scratch/tmp/zc-breaker" ]] || fail 'queue timeout opened the provider breaker'
printf 'PASS never passing the capacity gate fails fast with a named reason\n'
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
# 11-21 queue 899 (4): the matching line is quoted beside the reason, and the failed attempt's stderr survives
# under a per-attempt name even though the next attempt rewrites stderr.log.
assert_file_contains "$quota_dir/failover" 'evidence=stderr.log: AI request failed: insufficient_quota, rate limit exceeded'
quota_stderr_copy=''
for f in "$quota_dir"/stderr.zc.*.log; do [[ -f $f ]] && quota_stderr_copy=$f; done
[[ -n $quota_stderr_copy ]] || fail 'the failed zc attempt kept no per-attempt stderr copy'
assert_file_contains "$quota_stderr_copy" 'insufficient_quota'
[[ $(cat "$quota_dir/backend") == luna ]] || fail 'quota case did not finish on luna'
printf 'PASS auth/quota stderr pattern -> immediate failover with kept evidence\n'

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

# 11-21 queue 899 (5): a locked zcode database is transient contention, not a provider failure: retry zc once,
# touch no breaker, never start luna; a second locked failure gives up rc=75.
run_case zc-locked-retry 0 db_locked success 8 60 zc
locked_dir=$CASE_DIR
[[ $(cat "$locked_dir/rc") == 0 && $(cat "$locked_dir/backend") == zc && $(cat "$locked_dir/attempt-backend") == zc ]] ||
  fail 'a locked-database zc run did not retry zc to success'
[[ ! -e "$test_root/zc-locked-retry/.scratch/tmp/zc-breaker" ]] || fail 'a locked database opened the zc breaker'
assert_file_contains "$locked_dir/failover" 'locked database: waiting to retry zc'
assert_file_contains "$locked_dir/last.md" 'success from zc'
printf 'PASS a locked database retries zc once and touches no breaker\n'

run_case zc-locked-twice 75 db_locked:2 success 8 60 zc
locked_twice_dir=$CASE_DIR
[[ $(cat "$locked_twice_dir/rc") == 75 ]] || fail 'two locked failures did not end rc=75'
[[ $(cat "$locked_twice_dir/backend") == zc && $(cat "$locked_twice_dir/attempt-backend") == zc ]] || fail 'two locked failures started luna'
[[ ! -e "$test_root/zc-locked-twice/.scratch/tmp/zc-breaker" ]] || fail 'two locked failures opened the zc breaker'
assert_file_contains "$locked_twice_dir/failover" 'locked database twice: giving up'
assert_file_contains "$locked_twice_dir/failover" 'rc=75 reason=both backends failed: zc: fatal event pattern: turn.failed; zc retry after locked database: fatal event pattern: turn.failed'
printf 'PASS two locked failures give up rc=75 with no luna start and no breaker\n'

run_case models-manager-401 0 success models_manager_401 8 4 luna
[[ $(cat "$CASE_DIR/backend") == luna ]] || fail 'models_manager refresh 401 was treated as fatal'
[[ ! -e $CASE_DIR/failover ]] || fail 'models_manager refresh 401 started backend failover'
run_case router-tool-error-echo 0 success router_noise 8 4 luna
[[ $(cat "$CASE_DIR/backend") == luna ]] || fail 'a codex tool error echoing rate-limit text was treated as a quota error'
[[ ! -e $CASE_DIR/failover ]] || fail 'a codex tool error echo started backend failover'
printf 'PASS models_manager refresh 401 is ignored without hiding other fatal turn events\n'

run_case auth-turn-failed 0 success auth_turn_failed 8 4 luna
assert_file_contains "$CASE_DIR/failover" 'reason=fatal event pattern: turn.failed'
[[ $(cat "$CASE_DIR/backend") == zc ]] || fail 'authentication turn.failed did not trigger backend failover'
printf 'PASS authentication turn.failed remains fatal after filtering models_manager stderr\n'

history=$'2026-11-09T00:00:00Z go1-9169 gpt-6-luna rc=1\n2026-11-09T01:00:00Z go2-9169 gpt-6-luna rc=75'
run_case terra-cache 1 success model_not_found 8 4 luna gpt-6-luna go3-9169 "$history"
[[ $(cat "$CASE_DIR/models") == gpt-6.1-terra ]] || fail 'the first eligible escalation did not try terra'
model_cache="${CASE_DIR%/*}/model-not-found.cache"
assert_file_contains "$model_cache" 'gpt-6.1-terra'
cache_expiry=$(awk -F '\t' '$1 == "gpt-6.1-terra" { print $2 }' "$model_cache")
cache_now=$(date +%s)
[[ $cache_expiry =~ ^[0-9]+$ ]] || fail 'unsupported-model cache has no numeric expiry'
(( cache_expiry > cache_now && cache_expiry <= cache_now + 86400 )) || fail 'unsupported-model cache expiry is not within 24 hours'
run_case terra-cache 0 success success 8 4 luna gpt-6-luna go4-9169 "$history"
[[ $(cat "$CASE_DIR/models") == gpt-6-luna ]] || fail 'a cached model_not_found did not suppress terra escalation'
printf 'PASS model_not_found caches terra for 24 hours and suppresses later escalation\n'

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
timeout 4 env -u WORKER_BACKEND ZF_ZCODE_BIN="$root/zc-src/bin/zcode" WORKER_SCRATCH_ROOT="$root" \
  WORKER_STALL_SECONDS=8 WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
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
# codex.pid is written after the fake installed its TERM trap and its child touched hang-child-ready;
# TERM before that kills them by default, with no marker, and looks like a lost signal.
deadline=$((SECONDS + 30))
until [[ -s $d/codex.pid && -s $d/backend-run.pid && -s $d/hang-child.pid && -e $d/hang-child-ready ]] || (( SECONDS >= deadline )); do
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

make_fake_remote() {
  local remote=$1
  mkdir -p "$remote/proc/pressure" "$remote/bin" "$remote/home" "$remote/scopes" "$remote/roots"
  printf '0.1 0.1 0.1 1/1 1\n' > "$remote/proc/loadavg"
  printf 'processor : 0\nprocessor : 1\nprocessor : 2\nprocessor : 3\n' > "$remote/proc/cpuinfo"
  printf 'MemAvailable: 16777216 kB\n' > "$remote/proc/meminfo"
  printf 'some avg10=10 avg60=20 avg300=20 total=1\n' > "$remote/proc/pressure/cpu"
  cat > "$test_root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
connect_timeout=15
while [[ ${1:-} == -o ]]; do
  [[ ${2:-} != ConnectTimeout=* ]] || connect_timeout=${2#ConnectTimeout=}
  shift 2
done
host=${1:-}; shift || true
if [[ $host == unreachable ]]; then sleep "$connect_timeout"; exit 255; fi
remote=${ZF_TEST_REMOTE_ROOT:?}
cd "$remote"
export HOME="$remote/home" PATH="$remote/bin:/usr/bin:/bin"
export ZF_WORKER_REMOTE_PROC_ROOT="$remote/proc" ZF_TEST_REMOTE_ROOT="$remote"
export FAKE_REMOTE_CODEX_MODE="${ZF_TEST_REMOTE_CODEX_MODE:-success}"
unset ZCODE_BIN ZF_ZCODE_BIN   # a real ssh sends no caller env: the remote side resolves its own zcode
exec bash -c "$*"
EOF
  chmod +x "$test_root/bin/ssh"
  cat > "$remote/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
unit=
while (($#)); do
  case "$1" in
    --unit=*) unit=${1#--unit=} ;;
    --) shift; mkdir -p "$ZF_TEST_REMOTE_ROOT/scopes"; printf '%s\n' "$$" > "$ZF_TEST_REMOTE_ROOT/scopes/$unit.pid"; exec "$@" ;;
  esac
  shift
done
exit 2
EOF
  cat > "$remote/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ZF_TEST_REMOTE_ROOT/systemctl.log"
# The remote side always calls --user (its account is never root: the probe refuses uid 0).
[[ ${1:-} != --user ]] || shift
action=${1:-}; unit=${3:-${2:-}}; unit=${unit%.scope}
pidfile="$ZF_TEST_REMOTE_ROOT/scopes/$unit.pid"
case "$action" in
  stop) pid=$(cat "$pidfile" 2>/dev/null || true); [[ ! $pid =~ ^[0-9]+$ ]] || kill -TERM "$pid" 2>/dev/null || true ;;
  is-active) pid=$(cat "$pidfile" 2>/dev/null || true); [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null ;;
  *) exit 0 ;;
esac
EOF
  cat > "$remote/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
# The probe's backend check runs `codex login status` (worker-remote.py BACKEND_CHECKS); answer it before the
# run-shaped parsing, or a hang-mode stub would touch the run markers and hang the check itself.
if [[ ${1:-} == login && ${2:-} == status ]]; then exit 0; fi
output=
while (($#)); do
  if [[ $1 == -o && $# -gt 1 ]]; then output=$2; shift 2; else shift; fi
done
printf '%s\n' '{"type":"remote.event"}'
[[ -z $output ]] || printf 'remote last message\n' > "$output"
if [[ ${FAKE_REMOTE_CODEX_MODE:-success} == hang ]]; then
  touch "$ZF_TEST_REMOTE_ROOT/remote-codex-started"
  trap 'touch "$ZF_TEST_REMOTE_ROOT/remote-codex-stopped"; exit 143' TERM INT
  while :; do printf '%s\n' '{"type":"remote.progress"}'; read -r -t 0.05 _ || true; done
fi
EOF
  chmod +x "$remote/bin/systemd-run" "$remote/bin/systemctl" "$remote/bin/codex"
  cat > "$remote/bin/zcode" <<'EOF'
#!/usr/bin/env bash
# The probe's cheap check runs `zcode --version` and its login check sends one tiny prompt (worker-remote.py
# run_login_probe; a real `zcode --version` returns 0 with no login, so only a turn.completed stream proves it);
# a real run emits the stream-json close line bin/zc turns into last.md.
if [[ ${1:-} == --version ]]; then exit 0; fi
prompt=
while (($#)); do
  if [[ $1 == --prompt && $# -gt 1 ]]; then prompt=$2; shift 2; else shift; fi
done
if [[ $prompt == 'Reply with exactly: ok' ]]; then
  printf '%s\n' "$prompt" >> "$ZF_TEST_REMOTE_ROOT/zcode-probe.log"
  printf '%s\n' '{"type":"turn.completed"}'
  exit 0
fi
printf '%s\n' '{"type":"result","response":"remote zc stub ran"}'
EOF
  chmod +x "$remote/bin/zcode"
  cat > "$test_root/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
while (($#)); do
  if [[ $1 == -o && $# -gt 1 ]]; then output=$2; shift 2; else shift; fi
done
printf '%s\n' '{"type":"local.event"}'
printf 'local fallback\n' > "$output"
EOF
  chmod +x "$test_root/bin/codex"
}

remote_case="$test_root/remote-sync"; remote_root="$test_root/fake-remote-sync"
remote_scratch="$remote_case/.scratch"; remote_worktree="$remote_case/worktree"; remote_prompt="$remote_case/brief.md"
remote_home="$remote_case/home"; remote_agent_home="$remote_case/agent-home"
mkdir -p "$remote_scratch/tmp" "$remote_scratch/luna" "$remote_worktree" "$remote_home" "$remote_agent_home"
make_fake_remote "$remote_root"
git -C "$remote_worktree" init -q
git -C "$remote_worktree" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
printf 'remote sync brief\n' > "$remote_prompt"
remote_timeout=0
timeout --signal=TERM --kill-after=1 12 env ZF_WORKER_HOST=unreachable HOME="$remote_home" AGENT_HOME="$remote_agent_home" \
  ZF_ENGINE_DIR="$test_root" ZF_CONFIG_ROOT="$test_root/config-root" PATH="$test_root/bin:/usr/bin:/bin" \
  ZF_WORKER_HOSTS="remote-one" ZF_WORKER_REMOTE_ROOT="$remote_root/roots" ZF_TEST_REMOTE_ROOT="$remote_root" \
  ZF_WORKER_SSH_CONNECT_TIMEOUT=1 ZF_WORKER_SYNC_INTERVAL_SECONDS=0.05 WORKER_BACKEND=luna \
  WORKER_SCRATCH_ROOT="$remote_scratch" WORKER_STALL_SECONDS=8 WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
  FAKE_REMOTE_LUNA=1 REAL_LUNA_SCRIPT="$script_dir/luna" CODEX_MODEL=gpt-6-luna \
  bash "$worker_script" remote-sync "$remote_worktree" "$remote_prompt" \
  > "$remote_case.stdout" 2> "$remote_case.stderr" || remote_timeout=$?
[[ $remote_timeout == 0 ]] || fail "remote run returned rc=$remote_timeout (details: $remote_case.stderr)"
remote_dir="$remote_scratch/luna/remote-sync"
assert_file_contains "$remote_dir/events.jsonl" 'remote.event'
assert_file_contains "$remote_dir/last.md" 'remote last message'
[[ $(cat "$remote_dir/rc") == 0 && -s "$remote_dir/codex.pid" ]] || fail 'remote run did not sync rc and codex.pid'
assert_file_contains "$remote_root/systemctl.log" 'set-property --runtime zf-remote.slice CPUWeight=20'
printf 'PASS remote run syncs events, last.md, rc and codex.pid\n'

unreachable_case="$test_root/remote-unreachable"; unreachable_root="$test_root/fake-remote-unreachable"
unreachable_scratch="$unreachable_case/.scratch"; unreachable_worktree="$unreachable_case/worktree"
unreachable_prompt="$unreachable_case/brief.md"; unreachable_home="$unreachable_case/home"
unreachable_agent_home="$unreachable_case/agent-home"
mkdir -p "$unreachable_scratch/tmp" "$unreachable_scratch/luna" "$unreachable_worktree" "$unreachable_home" "$unreachable_agent_home"
make_fake_remote "$unreachable_root"
git -C "$unreachable_worktree" init -q
git -C "$unreachable_worktree" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
printf 'unreachable host brief\n' > "$unreachable_prompt"
printf 'MemAvailable: 6144000 kB\n' > "$unreachable_case/meminfo"
printf 'some avg10=0 avg60=0 avg300=0 total=0\nfull avg10=0 avg60=0 avg300=0 total=0\n' > "$unreachable_case/psi"
remote_timeout=0
timeout --signal=TERM --kill-after=1 6 env HOME="$unreachable_home" AGENT_HOME="$unreachable_agent_home" \
  ZF_ENGINE_DIR="$test_root" ZF_CONFIG_ROOT="$test_root/config-root" PATH="$test_root/bin:/usr/bin:/bin" \
  ZF_WORKER_HOST=unreachable ZF_WORKER_REMOTE_ROOT="$unreachable_root/roots" ZF_TEST_REMOTE_ROOT="$unreachable_root" \
  ZF_WORKER_SSH_CONNECT_TIMEOUT=1 ZF_WORKER_SYNC_INTERVAL_SECONDS=0.05 WORKER_BACKEND=luna \
  WORKER_SCRATCH_ROOT="$unreachable_scratch" WORKER_STALL_SECONDS=8 WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
  LUNA_MIN=2 LUNA_PROC_MEMINFO="$unreachable_case/meminfo" LUNA_PROC_PSI_MEMORY="$unreachable_case/psi" \
  LUNA_WORKER_SLICE_DIR="$unreachable_case/no-slice" FAKE_REMOTE_LUNA=1 REAL_LUNA_SCRIPT="$script_dir/luna" \
  bash "$worker_script" remote-unreachable "$unreachable_worktree" "$unreachable_prompt" \
  > "$unreachable_case.stdout" 2> "$unreachable_case.stderr" || remote_timeout=$?
[[ $remote_timeout == 0 ]] || fail "unreachable host run returned rc=$remote_timeout (details: $unreachable_case.stderr)"
[[ ! -e "$unreachable_root/roots/remote-unreachable" ]] || fail 'unreachable host started a remote clone'
assert_file_contains "$unreachable_scratch/luna/remote-unreachable/events.jsonl" 'local.event'
printf 'PASS unreachable host is skipped promptly and local capacity runs the worker\n'

stop_case="$test_root/remote-stop"; stop_root="$test_root/fake-remote-stop"
stop_scratch="$stop_case/.scratch"; stop_worktree="$stop_case/worktree"; stop_prompt="$stop_case/brief.md"
stop_home="$stop_case/home"; stop_agent_home="$stop_case/agent-home"
mkdir -p "$stop_scratch/tmp" "$stop_scratch/luna" "$stop_worktree" "$stop_home" "$stop_agent_home"
make_fake_remote "$stop_root"
git -C "$stop_worktree" init -q
git -C "$stop_worktree" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
printf 'stop remote brief\n' > "$stop_prompt"
env HOME="$stop_home" AGENT_HOME="$stop_agent_home" ZF_ENGINE_DIR="$test_root" ZF_CONFIG_ROOT="$test_root/config-root" \
  PATH="$test_root/bin:/usr/bin:/bin" ZF_WORKER_HOST=remote-one ZF_WORKER_REMOTE_ROOT="$stop_root/roots" \
  ZF_TEST_REMOTE_ROOT="$stop_root" ZF_TEST_REMOTE_CODEX_MODE=hang ZF_WORKER_SSH_CONNECT_TIMEOUT=1 \
  ZF_WORKER_SYNC_INTERVAL_SECONDS=0.05 WORKER_BACKEND=luna WORKER_SCRATCH_ROOT="$stop_scratch" \
  WORKER_STALL_SECONDS=60 WORKER_HEALTH_INTERVAL_SECONDS=0.05 FAKE_REMOTE_LUNA=1 \
  REAL_LUNA_SCRIPT="$script_dir/luna" CODEX_MODEL=gpt-6-luna timeout --signal=TERM --kill-after=1 15 \
  bash "$worker_script" remote-stop "$stop_worktree" "$stop_prompt" > "$stop_case.stdout" 2> "$stop_case.stderr" &
stop_worker_pid=$!
deadline=$((SECONDS + 12))
until [[ -e "$stop_root/remote-codex-started" && -s "$stop_scratch/luna/remote-stop/remote.scope" ]] || (( SECONDS >= deadline )); do sleep 0.05; done
[[ -e "$stop_root/remote-codex-started" ]] || fail 'remote stop fixture did not start Codex'
stop_rc=0
env WORKER_SCRATCH_ROOT="$stop_scratch" ZF_WORKER_STOP_QUIET=0.1 ZF_TEST_WORKER_STOP_SCRIPT="$script_dir/worker-stop" \
  ZF_TEST_REMOTE_ROOT="$stop_root" PATH="$test_root/bin:/usr/bin:/bin" zf-stop remote-stop \
  > "$stop_case.stop.stdout" 2> "$stop_case.stop.stderr" || stop_rc=$?
[[ $stop_rc == 0 && -e "$stop_root/remote-codex-stopped" ]] || fail 'zf-stop did not stop the remote run'
assert_file_contains "$stop_root/systemctl.log" '--user stop zf-remote-'
wait "$stop_worker_pid" 2>/dev/null || :
printf 'PASS zf-stop stops the remote scope\n'

# The probe refuses a host whose backend is unusable, whose load5 is over its core count, or whose ssh
# user is root; choose then falls back to local (the host probe owns backend + load + root checks).
refuse_case="$test_root/remote-probe-refuse"; refuse_root="$test_root/fake-remote-refuse"
mkdir -p "$refuse_case"
make_fake_remote "$refuse_root"
refuse_choose() {
  local name=$1 backend=$2
  env PATH="$test_root/bin:/usr/bin:/bin" ZF_WORKER_REMOTE_ROOT="$refuse_root/roots" \
    ZF_TEST_REMOTE_ROOT="$refuse_root" ZF_WORKER_HOST=host-a \
    python3 "$test_root/bin/worker-remote.py" choose "$backend" > "$refuse_case/$name.out" 2> "$refuse_case/$name.err" || true
}
rm -f "$refuse_root/bin/zcode"
refuse_choose missing-backend zc
[[ $(cat "$refuse_case/missing-backend.out") == local ]] || fail 'choose did not fall back to local without zcode'
assert_file_contains "$refuse_case/missing-backend.err" 'skipping host-a: zc backend unusable: zcode not found on the remote host'
printf '#!/bin/sh\nexit 3\n' > "$refuse_root/bin/zcode"
chmod +x "$refuse_root/bin/zcode"
refuse_choose version-fails zc
[[ $(cat "$refuse_case/version-fails.out") == local ]] || fail 'choose did not fall back to local when zcode --version fails'
assert_file_contains "$refuse_case/version-fails.err" 'skipping host-a: zc backend unusable: timeout 10 zcode --version returned rc=3'
make_fake_remote "$refuse_root"
printf '9.5 9.5 9.5 1/1 1\n' > "$refuse_root/proc/loadavg"
refuse_choose high-load zc
[[ $(cat "$refuse_case/high-load.out") == local ]] || fail 'choose did not fall back to local above the load bound'
assert_file_contains "$refuse_case/high-load.err" 'skipping host-a: load5 9.5 is above 4 cores x 1'
printf '0.1 0.1 0.1 1/1 1\n' > "$refuse_root/proc/loadavg"
mkdir -p "$refuse_root/proc/self"
printf 'Uid:\t0\t0\t0\t0\n' > "$refuse_root/proc/self/status"
refuse_choose root-user zc
[[ $(cat "$refuse_case/root-user.out") == local ]] || fail 'choose did not fall back to local for a root remote user'
assert_file_contains "$refuse_case/root-user.err" 'skipping host-a: remote user is root'
rm -rf "$refuse_root/proc/self"
refuse_choose admitted zc
[[ $(cat "$refuse_case/admitted.out") == host-a ]] || fail 'choose did not select a usable host with a runnable zcode'
assert_file_contains "$refuse_case/admitted.err" 'worker-host: selected'
# The run-side probe (command_run, the second probe) writes its refusal to the run's placement.log too.
printf '9.5 9.5 9.5 1/1 1\n' > "$refuse_root/proc/loadavg"
refuse_run_rc=0
env PATH="$test_root/bin:/usr/bin:/bin" ZF_WORKER_REMOTE_ROOT="$refuse_root/roots" \
  ZF_TEST_REMOTE_ROOT="$refuse_root" ZF_WORKER_HOST=host-a WORKER_SCRATCH_ROOT="$refuse_case/scratch" \
  python3 "$test_root/bin/worker-remote.py" run host-a refuse-load "$refuse_case" /dev/null '' zc \
  >/dev/null 2>"$refuse_case/load-run.err" || refuse_run_rc=$?
[[ $refuse_run_rc == 75 ]] || fail "load-refused run returned rc=$refuse_run_rc instead of 75"
assert_file_contains "$refuse_case/scratch/luna/refuse-load/placement.log" \
  'worker-host: skipping host-a: load5 9.5 is above 4 cores x 1'
printf '0.1 0.1 0.1 1/1 1\n' > "$refuse_root/proc/loadavg"
printf 'PASS probe refuses a missing backend, load5 over cores and a root user; choose falls back to local, and a refused run logs the reason to placement.log\n'

# WORKER_BACKEND=zc with an admitted host hands off to the helper: the remote side starts bin/zc, whose
# zcode stub result syncs back as last.md/events/rc/codex.pid beside the placement record.
zc_remote_case="$test_root/remote-zc"; zc_remote_root="$test_root/fake-remote-zc"
zc_scratch="$zc_remote_case/.scratch"; zc_worktree="$zc_remote_case/worktree"; zc_prompt_file="$zc_remote_case/brief.md"
zc_home="$zc_remote_case/home"; zc_agent_home="$zc_remote_case/agent-home"
mkdir -p "$zc_scratch/tmp" "$zc_scratch/luna" "$zc_scratch/zc-src/bin" "$zc_worktree" "$zc_home" "$zc_agent_home"
make_fake_remote "$zc_remote_root"
printf '#!/bin/sh\nexit 0\n' > "$zc_scratch/zc-src/bin/zcode"
chmod +x "$zc_scratch/zc-src/bin/zcode"
git -C "$zc_worktree" init -q
git -C "$zc_worktree" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
printf 'remote zc brief\n' > "$zc_prompt_file"
zc_remote_rc=0
timeout --signal=TERM --kill-after=1 15 env ZF_WORKER_HOST=remote-one HOME="$zc_home" AGENT_HOME="$zc_agent_home" \
  ZF_ENGINE_DIR="$test_root" ZF_CONFIG_ROOT="$test_root/config-root" PATH="$test_root/bin:/usr/bin:/bin" \
  ZF_ZCODE_BIN="$zc_scratch/zc-src/bin/zcode" \
  ZF_WORKER_REMOTE_ROOT="$zc_remote_root/roots" ZF_TEST_REMOTE_ROOT="$zc_remote_root" \
  ZF_WORKER_SSH_CONNECT_TIMEOUT=1 ZF_WORKER_SYNC_INTERVAL_SECONDS=0.05 WORKER_BACKEND=zc \
  WORKER_SCRATCH_ROOT="$zc_scratch" WORKER_STALL_SECONDS=8 WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
  FAKE_REMOTE_ZC=1 REAL_ZC_SCRIPT="$script_dir/zc" \
  bash "$worker_script" remote-zc "$zc_worktree" "$zc_prompt_file" \
  > "$zc_remote_case.stdout" 2> "$zc_remote_case.stderr" || zc_remote_rc=$?
[[ $zc_remote_rc == 0 ]] || fail "remote zc run returned rc=$zc_remote_rc (details: $zc_remote_case.stderr)"
zc_dir="$zc_scratch/luna/remote-zc"
assert_file_contains "$zc_dir/last.md" 'remote zc stub ran'
assert_file_contains "$zc_dir/events.jsonl" '"type":"result"'
[[ $(cat "$zc_dir/rc") == 0 && -s "$zc_dir/codex.pid" ]] || fail 'remote zc run did not sync rc and codex.pid'
[[ $(cat "$zc_dir/remote.host") == remote-one ]] || fail 'remote zc run did not record the chosen host'
assert_file_contains "$zc_dir/placement.log" 'worker-host: selected'
assert_file_contains "$zc_remote_root/systemctl.log" 'set-property --runtime zf-remote.slice CPUWeight=20'
printf 'PASS WORKER_BACKEND=zc with an admitted host hands off and starts bin/zc on the remote side\n'

# `zcode --version` returns 0 on a host where zcode is installed but not logged in, so the zc probe proves the login
# with one prompt. A stub whose prompt answers turn.failed refuses the host: the skipping line names the probe, the
# run falls back to the local zc lane, and no zc breaker file appears (a refused probe is not a zc failure).
login_refused_case="$test_root/zc-login-refused"; login_refused_root="$test_root/fake-remote-zc-login-refused"
login_refused_scratch="$login_refused_case/.scratch"; login_refused_worktree="$login_refused_case/worktree"
login_refused_prompt="$login_refused_case/brief.md"; login_refused_home="$login_refused_case/home"
login_refused_agent_home="$login_refused_case/agent-home"
mkdir -p "$login_refused_scratch/tmp" "$login_refused_scratch/luna" "$login_refused_scratch/zc-src/bin" \
  "$login_refused_worktree" "$login_refused_home" "$login_refused_agent_home"
make_fake_remote "$login_refused_root"
cat > "$login_refused_root/bin/zcode" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then exit 0; fi
printf '%s\n' '{"type":"turn.failed","error":{"code":"authentication_error","message":"Authentication failed (401)"}}'
EOF
chmod +x "$login_refused_root/bin/zcode"
printf '#!/bin/sh\nexit 0\n' > "$login_refused_scratch/zc-src/bin/zcode"
chmod +x "$login_refused_scratch/zc-src/bin/zcode"
git -C "$login_refused_worktree" init -q
git -C "$login_refused_worktree" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
printf 'refused login brief\n' > "$login_refused_prompt"
login_refused_rc=0
timeout --signal=TERM --kill-after=1 15 env ZF_WORKER_HOST=zc-login-refused HOME="$login_refused_home" \
  AGENT_HOME="$login_refused_agent_home" ZF_ENGINE_DIR="$test_root" ZF_CONFIG_ROOT="$test_root/config-root" \
  PATH="$test_root/bin:/usr/bin:/bin" ZF_ZCODE_BIN="$login_refused_scratch/zc-src/bin/zcode" \
  ZF_WORKER_REMOTE_ROOT="$login_refused_root/roots" ZF_TEST_REMOTE_ROOT="$login_refused_root" \
  ZF_WORKER_SSH_CONNECT_TIMEOUT=1 ZF_WORKER_SYNC_INTERVAL_SECONDS=0.05 WORKER_BACKEND=zc \
  WORKER_SCRATCH_ROOT="$login_refused_scratch" WORKER_STALL_SECONDS=8 WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
  FAKE_ZC_MODE=success \
  bash "$worker_script" zc-login-refused "$login_refused_worktree" "$login_refused_prompt" \
  > "$login_refused_case.stdout" 2> "$login_refused_case.stderr" || login_refused_rc=$?
[[ $login_refused_rc == 0 ]] || fail "login-refused run returned rc=$login_refused_rc (details: $login_refused_case.stderr)"
login_refused_dir="$login_refused_scratch/luna/zc-login-refused"
[[ $(cat "$login_refused_dir/backend") == zc ]] || fail 'a refused login probe did not keep the run on the zc lane'
assert_file_contains "$login_refused_dir/placement.log" \
  'worker-host: skipping zc-login-refused: zcode login probe failed (turn.failed)'
assert_file_contains "$login_refused_dir/last.md" 'success from zc'
[[ ! -e "$login_refused_scratch/tmp/zc-breaker" ]] || fail 'a refused login probe wrote the zc breaker file'
printf 'PASS a login probe that answers turn.failed refuses the host, runs locally and writes no breaker\n'

# A passed login probe is cached per host (15 minutes): the choose probe and the run-side probe of one launch, plus
# a whole second launch inside the window, send exactly one prompt (the stub counts every prompt it answers).
login_ok_case="$test_root/zc-login-cache"; login_ok_root="$test_root/fake-remote-zc-login-cache"
login_ok_scratch="$login_ok_case/.scratch"; login_ok_worktree="$login_ok_case/worktree"
login_ok_prompt="$login_ok_case/brief.md"; login_ok_home="$login_ok_case/home"; login_ok_agent_home="$login_ok_case/agent-home"
mkdir -p "$login_ok_scratch/tmp" "$login_ok_scratch/luna" "$login_ok_scratch/zc-src/bin" \
  "$login_ok_worktree" "$login_ok_home" "$login_ok_agent_home"
make_fake_remote "$login_ok_root"
printf '#!/bin/sh\nexit 0\n' > "$login_ok_scratch/zc-src/bin/zcode"
chmod +x "$login_ok_scratch/zc-src/bin/zcode"
git -C "$login_ok_worktree" init -q
git -C "$login_ok_worktree" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
printf 'cached login brief\n' > "$login_ok_prompt"
for key in zc-login-cache-a zc-login-cache-b; do
  login_ok_rc=0
  timeout --signal=TERM --kill-after=1 15 env ZF_WORKER_HOST=zc-login-ok HOME="$login_ok_home" \
    AGENT_HOME="$login_ok_agent_home" ZF_ENGINE_DIR="$test_root" ZF_CONFIG_ROOT="$test_root/config-root" \
    PATH="$test_root/bin:/usr/bin:/bin" ZF_ZCODE_BIN="$login_ok_scratch/zc-src/bin/zcode" \
    ZF_WORKER_REMOTE_ROOT="$login_ok_root/roots" ZF_TEST_REMOTE_ROOT="$login_ok_root" \
    ZF_WORKER_SSH_CONNECT_TIMEOUT=1 ZF_WORKER_SYNC_INTERVAL_SECONDS=0.05 WORKER_BACKEND=zc \
    WORKER_SCRATCH_ROOT="$login_ok_scratch" WORKER_STALL_SECONDS=8 WORKER_HEALTH_INTERVAL_SECONDS=0.05 \
    FAKE_REMOTE_ZC=1 REAL_ZC_SCRIPT="$script_dir/zc" \
    bash "$worker_script" "$key" "$login_ok_worktree" "$login_ok_prompt" \
    > "$login_ok_case.$key.stdout" 2> "$login_ok_case.$key.stderr" || login_ok_rc=$?
  [[ $login_ok_rc == 0 ]] || fail "cached-login run $key returned rc=$login_ok_rc (details: $login_ok_case.$key.stderr)"
done
[[ $(wc -l < "$login_ok_root/zcode-probe.log") == 1 ]] || fail 'the login prompt was not sent exactly once inside the cache window'
[[ $(awk '{print $2}' "$login_ok_scratch/tmp/zc-login/zc-login-ok") == ok ]] || fail 'the passed login probe was not cached'
assert_file_contains "$login_ok_scratch/luna/zc-login-cache-b/last.md" 'remote zc stub ran'
assert_file_contains "$login_ok_scratch/luna/zc-login-cache-b/placement.log" 'worker-host: selected'
printf 'PASS a passed login probe is cached: two launches, choose plus run-side probes, one prompt\n'
