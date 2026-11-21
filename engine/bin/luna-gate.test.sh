#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
bin=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$bin/../mac-autopilot/scheduler.d/self-check.sh"
root=$(mktemp -d); ticket_pid=""; reload_pid=""; trap '[[ -z "${ticket_pid:-}" ]] || { kill "$ticket_pid" 2>/dev/null || :; wait "$ticket_pid" 2>/dev/null || :; }; [[ -z "${reload_pid:-}" ]] || { kill "$reload_pid" 2>/dev/null || :; wait "$reload_pid" 2>/dev/null || :; }; rm -rf -- "$root" "$test_env_root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export LUNA_WORKER_SLICE_DIR="$root/no-slice" # cases below must not read the host's live worker slice

# gate <file> <avail_mb> <psi_full> <priority> <age_seconds> <cpu_busy> [runs]: prints admission and any refusal reason.
# Loads the real box_has_room from the file. PSI some is fixed at 32 (the live value that used to block hotfix).
# LUNA_MIN=0 keeps the first tier out, and age and cpu are set so only the tier under test can admit.
gate() {
  local file=$1 d runs="${7:-0}"; d=$(mktemp -d -p "$root")
  printf 'MemAvailable: %s kB\n' "$(( $2 * 1024 ))" >"$d/meminfo"
  printf 'some avg10=32 avg60=35 avg300=36 total=1\nfull avg10=%s avg60=4 avg300=4.6 total=1\n' "$3" >"$d/psi"
  grep -Fq 'luna-capacity.sh' "$file" || fail "$(basename "$file") does not source shared capacity admission"
  (
    export LUNA_PROC_MEMINFO="$d/meminfo" LUNA_PROC_PSI_MEMORY="$d/psi" LUNA_PRIORITY="$4" LUNA_MIN=0 LUNA_MAX=10 LUNA_ADMIT_AVAIL_MB=3328 MOCK_RUNS="$runs"
    export LUNA_AGE_ADMIT_SECONDS="$5" CPU_BUSY="$6"
    source "$bin/luna-capacity.sh"
    codex_runs() { echo "$MOCK_RUNS"; }
    cpu_busy() { echo "$CPU_BUSY"; }
    if box_has_room; then echo admitted; else printf 'refused|%s\n' "${BOX_ROOM_WHY:-}"; fi
  )
}
# expect <file> <avail_mb> <full> <priority> <age> <cpu> <want>
expect() {
  local got status; got=$(gate "$1" "$2" "$3" "$4" "$5" "$6" "${8:-0}"); status="${got%%|*}"
  [[ $status == "$7" ]] || fail "$(basename "$1") avail=$2 full=$3 prio=$4 age=$5 cpu=$6: got $got, want $7"
  [[ -z "${9:-}" || "$got" == "$7|${9}" ]] || fail "$(basename "$1") reason: got $got, want $7|${9}"
}
wait_file_case() {
  local f=$1 scratch="$root/$(basename "$1").scratch" slots="$root/$(basename "$1").slots" pid
  mkdir -p "$scratch" "$slots"; printf 'MemAvailable: 1024 kB\n' >"$root/meminfo"; printf 'some avg10=32 avg60=35 avg300=36 total=1\nfull avg10=12 avg60=12 avg300=12 total=1\n' >"$root/psi"; : >"$root/prompt"
  env WORKER_SCRATCH_ROOT="$scratch" LUNA_SLOTS="$slots" LUNA_PRIORITY=opt LUNA_MIN=0 LUNA_MAX=0 LUNA_PROC_MEMINFO="$root/meminfo" LUNA_PROC_PSI_MEMORY="$root/psi" "$f" gate "$root" "$root/prompt" &
  pid=$!
  for _ in {1..100}; do
    [[ -e "$slots/wait-opt-$pid" ]] && { kill "$pid"; wait "$pid" 2>/dev/null || :; return; }
    if [[ -e "$scratch/tmp/luna-slots/wait-opt-$pid" ]]; then kill "$pid"; wait "$pid" 2>/dev/null || :; fail "$(basename "$f") ignored LUNA_SLOTS"; fi
    kill -0 "$pid" 2>/dev/null || { wait "$pid" || :; fail "$(basename "$f") exited before publishing a wait file"; }
    sleep .05
  done
  kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; fail "$(basename "$f") did not publish wait file in LUNA_SLOTS"
}

for f in "$bin/luna" "$bin/zc"; do
  d="$root/cleanup-$(basename "$f")"; mkdir -p "$d/out"; : >"$d/wait"; : >"$d/out/gate-wait"; ( wait_f="$d/wait"; out="$d/out"; eval "$(awk '/^chain_exit_trap\(\)/,/^}/; /^chain_exit_trap /' "$f")" )
  [[ ! -e "$d/wait" && ! -e "$d/out/gate-wait" ]] || fail "$(basename "$f") did not clear gate markers on exit"
  #            file avail full prio   age  cpu want
  expect "$f"  4600   2   hotfix   999999 0   admitted # hotfix tier: 3 GB floor, full < 10
  expect "$f"  4600  12   hotfix   999999 0   refused  # full 12: refused for every tier
  expect "$f"  2500   2   hotfix   999999 0   refused  # hotfix below 3 GB
  expect "$f"  3400   0   normal   999999 0   admitted # normal tier: measured floor, full < 10
  expect "$f"  3000   0   normal   999999 0   refused 0 "runs 0/10 avail 3000MB full 0" # normal below measured floor
  expect "$f"  6000   0   normal        0 0   refused 10 "runs 10/10 avail 6000MB full 0" # normal at run cap
  expect "$f"  3400  12   normal   999999 0   refused  # normal, full 12
  expect "$f"  6000   2   normal   999999 0   admitted # normal tier: cpu under target, full < 10, 5 GB free
  expect "$f"  6000   2   normal   999999 100 refused  # CPU-full with runs below cap
  expect "$f"  6000  12   normal   999999 0   refused  # normal, full 12
  expect "$f"  3400   0   normal        0 100  admitted # aging tier alone: cpu busy, aged, measured floor
  expect "$f"  6000  12   normal        0 100  refused  # aging, full 12
  wait_file_case "$f"
done
cache_reason_case() (
  local mem="$root/cache-meminfo" psi="$root/cache-psi" expected="runs 0/10 avail 3000MB full 0"
  printf 'MemAvailable: 3072000 kB\n' > "$mem"
  printf 'some avg10=0 avg60=0 avg300=0 total=0\nfull avg10=0 avg60=0 avg300=0 total=0\n' > "$psi"
  export LUNA_PROC_MEMINFO="$mem" LUNA_PROC_PSI_MEMORY="$psi" LUNA_MIN=0 LUNA_MAX=10 LUNA_ADMIT_AVAIL_MB=3328 LUNA_CPU_TARGET=101
  source "$bin/luna-capacity.sh"
  codex_runs() { echo 0; }
  cpu_busy() { echo 0; }
  declare -A TICK_PRIORITY_ADMISSION_CACHE=()
  TICK_DISPATCH_PENDING_ACTIVE=true
  if priority_admission_has_room normal 0; then fail 'low-memory admission unexpectedly opened'; fi
  [[ "${BOX_ROOM_WHY:-}" == "$expected" ]] || fail "initial admission reason: got ${BOX_ROOM_WHY:-}, want $expected"
  printf 'MemAvailable: 6144000 kB\n' > "$mem"
  if priority_admission_has_room normal 0; then fail 'cached low-memory admission unexpectedly reopened'; fi
  [[ "${BOX_ROOM_WHY:-}" == "$expected" ]] || fail "cached admission reason: got ${BOX_ROOM_WHY:-}, want $expected"
)
cache_reason_case
# The CPU sample (2 s) is reused within LUNA_CPU_SAMPLE_TTL seconds; the memory check still reads fresh each call.
cpu_sample_reuse_case() (
  local mem="$root/reuse-meminfo" psi="$root/reuse-psi" samples="$root/reuse-samples"
  printf 'MemAvailable: 6144000 kB\n' > "$mem"
  printf 'some avg10=0 avg60=0 avg300=0 total=0\nfull avg10=0 avg60=0 avg300=0 total=0\n' > "$psi"
  export LUNA_PROC_MEMINFO="$mem" LUNA_PROC_PSI_MEMORY="$psi" LUNA_PRIORITY=normal LUNA_AGE_ADMIT_SECONDS=1200 LUNA_MIN=0 LUNA_MAX=10 LUNA_ADMIT_AVAIL_MB=3328 LUNA_CPU_TARGET=85 LUNA_CPU_SAMPLE_TTL=10
  unset LUNA_CPU_BUSY_AT LUNA_CPU_BUSY_VALUE
  source "$bin/luna-capacity.sh"
  codex_runs() { echo 0; }
  cpu_busy() { echo x >> "$samples"; echo 50; }
  samples_taken() { if [[ -f "$samples" ]]; then wc -l < "$samples"; else echo 0; fi; }
  SECONDS=100
  box_has_room 0 || fail 'first call refused'
  SECONDS=105
  box_has_room 0 || fail 'call within the TTL refused'
  [[ "$(samples_taken)" == 1 ]] || fail "cpu_busy ran $(samples_taken) times within the TTL, want 1"
  printf 'MemAvailable: 1024 kB\n' > "$mem"
  SECONDS=106
  if box_has_room 0; then fail 'low memory admitted within the TTL: memory must stay fresh'; fi
  printf 'MemAvailable: 6144000 kB\n' > "$mem"
  SECONDS=111
  box_has_room 0 || fail 'call after the TTL refused'
  [[ "$(samples_taken)" == 2 ]] || fail "cpu_busy ran $(samples_taken) times after the TTL, want 2"
)
cpu_sample_reuse_case
# Worker slice budget (11-19): one worker peak must fit under memory.high, for every tier including hotfix.
slice_budget_case() (
  local mem="$root/slice-meminfo" psi="$root/slice-psi" sl="$root/slice"
  mkdir -p "$sl"; echo 3221225472 > "$sl/memory.high"
  printf 'MemAvailable: 6144000 kB\n' > "$mem"
  printf 'some avg10=0 avg60=0 avg300=0 total=0\nfull avg10=0 avg60=0 avg300=0 total=0\n' > "$psi"
  export LUNA_PROC_MEMINFO="$mem" LUNA_PROC_PSI_MEMORY="$psi" LUNA_MIN=2 LUNA_MAX=10 LUNA_ADMIT_AVAIL_MB=3328 LUNA_CPU_TARGET=101 LUNA_WORKER_SLICE_DIR="$sl"
  source "$bin/luna-capacity.sh"
  codex_runs() { echo 0; }
  cpu_busy() { echo 0; }
  echo $(( 2400 * 1048576 )) > "$sl/memory.current"
  if LUNA_PRIORITY=hotfix box_has_room 0; then fail 'a start with 672 MB left under the slice high was admitted'; fi
  [[ "$BOX_ROOM_WHY" == 'worker slice 672MB left under memory.high < 1200MB worker peak backend=- source=default' ]] || fail "slice reason: $BOX_ROOM_WHY"
  echo $(( 1000 * 1048576 )) > "$sl/memory.current"
  box_has_room 0 || fail "a start with 2072 MB left under the slice high was refused: $BOX_ROOM_WHY"
  echo max > "$sl/memory.high"
  box_has_room 0 || fail 'memory.high=max must not refuse'
)
slice_budget_case

ticket_admission_cases() {
  local slots="$root/ticket-slots" hotfix normal now old_file new_file stale_file stale_pid log
  mkdir -p "$slots"
  source "$bin/luna-capacity.sh"
  box_calls=0
  box_has_room() { box_calls=$((box_calls + 1)); return 0; }
  now=$(date +%s)

  hotfix="$slots/wait-hotfix-$$"; normal="$slots/wait-normal-$$"
  printf '%s\n' "$((now - 30))" > "$hotfix"; printf '%s\n' "$((now - 20))" > "$normal"
  log="$root/ticket-yields.log"; : > "$log"; unset LUNA_WAIT_LOG_AT
  if luna_waiter_has_room "$slots" "$normal" normal 0 2>>"$log"; then fail 'ordinary waiter passed a live hotfix ticket'; fi
  [[ "${LUNA_WAIT_AHEAD:-}" == "${hotfix##*/}" && "$box_calls" == 0 ]] || fail "hotfix ticket did not block before capacity check: ahead=${LUNA_WAIT_AHEAD:-} calls=$box_calls"
  if luna_waiter_has_room "$slots" "$normal" normal 0 2>>"$log"; then fail 'ordinary waiter passed a live hotfix ticket on a later poll'; fi
  [[ "$(wc -l < "$log")" == 1 ]] || fail 'ticket yield was not logged exactly once within a minute'
  grep -Fq "waiter=${normal##*/} ahead=${hotfix##*/}" "$log" || fail 'ticket yield log omitted waiter keys'

  rm -rf -- "$slots"; mkdir -p "$slots"
  sleep 30 & ticket_pid=$!
  old_file="$slots/wait-normal-$ticket_pid"; new_file="$slots/wait-normal-$$"
  printf '%s\n' "$((now - 30))" > "$old_file"; printf '%s\n' "$((now - 20))" > "$new_file"
  box_calls=0
  luna_waiter_has_room "$slots" "$old_file" normal 0 || fail 'older ordinary waiter did not win'
  [[ "$box_calls" == 1 ]] || fail "older waiter did not reach capacity check: calls=$box_calls"
  if luna_waiter_has_room "$slots" "$new_file" normal 0; then fail 'younger ordinary waiter passed an older ticket'; fi
  [[ "${LUNA_WAIT_AHEAD:-}" == "${old_file##*/}" && "$box_calls" == 1 ]] || fail "older ticket did not block younger waiter: ahead=${LUNA_WAIT_AHEAD:-} calls=$box_calls"
  kill "$ticket_pid" 2>/dev/null || :; wait "$ticket_pid" 2>/dev/null || :; ticket_pid=""

  rm -rf -- "$slots"; mkdir -p "$slots"
  stale_pid=$(($(cat /proc/sys/kernel/pid_max) + 1))
  stale_file="$slots/wait-hotfix-$stale_pid"; normal="$slots/wait-normal-$$"
  printf '%s\n' "$((now - 30))" > "$stale_file"; printf '%s\n' "$((now - 20))" > "$normal"
  box_calls=0
  luna_waiter_has_room "$slots" "$normal" normal 0 || fail 'stale hotfix ticket blocked ordinary waiter'
  [[ ! -e "$stale_file" && "$box_calls" == 1 ]] || fail 'stale hotfix ticket was not dropped before admission'

  rm -rf -- "$slots"; mkdir -p "$slots"
  hotfix="$slots/wait-hotfix-$$"; printf '%s\n' "$now" > "$hotfix"; box_calls=0
  luna_waiter_has_room "$slots" "$hotfix" hotfix 0 || fail 'uncontended hotfix waiter was refused'
  [[ "$box_calls" == 1 ]] || fail "uncontended hotfix did not reach capacity check: calls=$box_calls"
}
ticket_admission_cases
write_gate_version() {
  local version="$2" result="$3" file="$1/engine/bin/luna-capacity.sh"
  mkdir -p "${file%/*}"
  cp "$bin/luna-capacity.sh" "$file"
  cat >> "$file" <<EOF
luna_waiter_has_room() {
  printf '%s\\n' '$version' >> "\$LUNA_GATE_CALLS"
  return $result
}
EOF
}
install_reload_stubs() {
  local d="$root/reload-bin"; mkdir -p "$d"
  cat > "$d/codex" <<'EOF'
#!/usr/bin/env bash
printf 'started\n' >> "$LUNA_STARTED"
EOF
  cat > "$d/systemd-run" <<'EOF'
#!/usr/bin/env bash
while (($#)); do [[ "$1" == -- ]] && { shift; exec "$@"; }; shift; done
exit 90
EOF
  cat > "$d/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$d/codex" "$d/systemd-run" "$d/systemctl"
  RELOAD_STUB_BIN="$d"
}
wait_for_lines() {
  local file="$1" count="$2" lines
  for _ in {1..200}; do
    if [[ -f "$file" ]]; then
      lines=$(wc -l < "$file")
      (( lines >= count )) && return 0
    fi
    sleep .01
  done
  return 1
}
wait_for_file() {
  local file="$1"
  for _ in {1..200}; do [[ -e "$file" ]] && return 0; sleep .01; done
  return 1
}
start_gate_waiter() {
  local case_root="$1" key="$2"
  env AGENT_HOME="$case_root/agent" LUNA_GATE_CALLS="$case_root/calls" LUNA_STARTED="$case_root/started" \
    WORKER_SCRATCH_ROOT="$case_root/scratch" LUNA_SLOTS="$case_root/slots" LUNA_WAIT_SECONDS=.1 \
    PATH="$RELOAD_STUB_BIN:$PATH" "$bin/luna" "$key" "$case_root" "$case_root/prompt" \
    >"$case_root/waiter.log" 2>&1 &
  reload_pid=$!
}
prepare_gate_case() {
  local case_root="$1"
  mkdir -p "$case_root/agent" "$case_root/scratch" "$case_root/slots"
  printf 'Reply with one word.\n' > "$case_root/prompt"
}
live_gate_reload_case() {
  local case_root="$root/reload-success" engine_a="$root/reload-success/engine-versions/A/engine" \
    engine_b="$root/reload-success/engine-versions/B/engine" resolved_b
  prepare_gate_case "$case_root"; install_reload_stubs
  write_gate_version "${engine_a%/engine}" A 1
  write_gate_version "${engine_b%/engine}" B 0
  ln -s "$engine_a" "$case_root/agent/engine-live"
  start_gate_waiter "$case_root" reload-success
  wait_for_lines "$case_root/calls" 1 || fail 'luna did not call version A gate'
  [[ -z "$(cat "$case_root/started" 2>/dev/null || :)" ]] || fail 'version A unexpectedly started the run'
  ln -sfn "$engine_b" "$case_root/agent/engine-live"
  wait_for_file "$case_root/started" || fail 'luna did not start after the live gate changed to B'
  wait "$reload_pid" || fail 'luna failed after the live gate admitted the run'; reload_pid=""
  [[ "$(cat "$case_root/calls")" == $'A\nB' ]] || fail "luna did not admit on the first poll after reloading B: $(cat "$case_root/calls")"
  resolved_b=$(readlink -f -- "$engine_b/bin/luna-capacity.sh")
  grep -Fq "luna: gate reloaded from $resolved_b" "$case_root/waiter.log" || fail 'luna did not log the resolved B gate path'
}
broken_live_gate_case() {
  local case_root="$root/reload-broken" engine_a="$root/reload-broken/engine-versions/A/engine" \
    engine_b="$root/reload-broken/engine-versions/B/engine"
  prepare_gate_case "$case_root"
  write_gate_version "${engine_a%/engine}" A 1
  mkdir -p "$engine_b/bin"
  cat > "$engine_b/bin/luna-capacity.sh" <<'EOF'
luna_waiter_has_room() { printf 'broken\n' >> "$LUNA_GATE_CALLS"; return 0; }
false
EOF
  ln -s "$engine_a" "$case_root/agent/engine-live"
  start_gate_waiter "$case_root" reload-broken
  wait_for_lines "$case_root/calls" 1 || fail 'luna did not call version A gate before the broken reload'
  ln -sfn "$engine_b" "$case_root/agent/engine-live"
  wait_for_lines "$case_root/calls" 2 || fail 'luna did not continue calling A after B failed to source'
  kill -0 "$reload_pid" 2>/dev/null || fail 'luna exited after the live gate failed to source'
  [[ "$(cat "$case_root/calls")" == $'A\nA' ]] || fail "broken B replaced A gate functions: $(cat "$case_root/calls")"
  [[ ! -e "$case_root/started" ]] || fail 'broken B admitted the run'
  kill "$reload_pid" 2>/dev/null || :; wait "$reload_pid" 2>/dev/null || :; reload_pid=""
}
live_gate_reload_case
broken_live_gate_case
for f in "$bin/luna" "$bin/zc"; do
  case "${f##*/}" in luna) gate_backend=luna ;; *) gate_backend=zc ;; esac
  grep -Fq "if luna_waiter_has_room \"\$slots\" \"\$wait_f\" \"\$prio\" \"\$SECONDS\" $gate_backend; then" "$f" || fail "$(basename "$f") does not use ticket-ordered admission naming its backend"
  grep -Fq 'luna_reload_live_gate' "$f" || fail "$(basename "$f") does not reload the live gate"
  grep -Fq 'sleep "${LUNA_WAIT_SECONDS:-30}"' "$f" || fail "$(basename "$f") does not use the waiter sleep override"
done
echo "ok - ticket admission orders hotfix before normal and older waiters before newer ones; stale tickets drop; uncontended hotfix admitted"

remote_root="$root/fake-remote"
local_root="$root/remote-fallback"
mkdir -p "$remote_root/proc/pressure" "$remote_root/home" "$local_root/bin" "$local_root/scratch/tmp"
printf '0.1 0.1 0.1 1/1 1\n' > "$remote_root/proc/loadavg"
printf 'MemAvailable: 4194304 kB\n' > "$remote_root/proc/meminfo"
printf 'some avg10=20 avg60=61 avg300=61 total=1\n' > "$remote_root/proc/pressure/cpu"
printf 'MemAvailable: 6144000 kB\n' > "$local_root/meminfo"
printf 'some avg10=0 avg60=0 avg300=0 total=0\nfull avg10=0 avg60=0 avg300=0 total=0\n' > "$local_root/psi"
cat > "$local_root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ ${1:-} == -o ]]; do shift 2; done
shift
cd "$ZF_TEST_REMOTE_ROOT"
export HOME="$ZF_TEST_REMOTE_ROOT/home" ZF_WORKER_REMOTE_PROC_ROOT="$ZF_TEST_REMOTE_ROOT/proc"
exec bash -c "$*"
EOF
cat > "$local_root/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while (($#)) && [[ $1 != -- ]]; do shift; done
[[ ${1:-} == -- ]] && shift
exec "$@"
EOF
cat > "$local_root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$local_root/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
while (($#)); do
  if [[ $1 == -o && $# -gt 1 ]]; then output=$2; shift 2; else shift; fi
done
printf '%s\n' '{"type":"local.event"}'
printf 'local fallback\n' > "$output"
EOF
chmod +x "$local_root/bin/ssh" "$local_root/bin/systemd-run" "$local_root/bin/systemctl" "$local_root/bin/codex"
mkdir -p "$local_root/home" "$local_root/agent-home" "$local_root/worktree"
git -C "$local_root/worktree" init -q
git -C "$local_root/worktree" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
: > "$local_root/prompt"
env HOME="$local_root/home" AGENT_HOME="$local_root/agent-home" PATH="$local_root/bin:/usr/bin:/bin" \
  WORKER_SCRATCH_ROOT="$local_root/scratch" ZF_WORKER_HOST=remote-one ZF_WORKER_REMOTE_ROOT="$remote_root/root" \
  ZF_TEST_REMOTE_ROOT="$remote_root" ZF_WORKER_SSH_CONNECT_TIMEOUT=1 LUNA_MIN=2 \
  LUNA_PROC_MEMINFO="$local_root/meminfo" LUNA_PROC_PSI_MEMORY="$local_root/psi" \
  LUNA_WORKER_SLICE_DIR="$local_root/no-slice" "$bin/luna" fallback "$local_root/worktree" "$local_root/prompt" \
  > "$local_root/stdout" 2> "$local_root/stderr"
grep -Fq 'CPU PSI some avg60 61 is above 60' "$local_root/stderr" || fail 'remote refusal did not report the CPU PSI reason'
grep -Fq 'falling back to local capacity gate' "$local_root/stderr" || fail 'remote refusal did not fall back to local admission'
grep -Fq 'local.event' "$local_root/scratch/luna/fallback/events.jsonl" || fail 'local worker did not run after remote refusal'
[[ ! -e "$remote_root/root/fallback" ]] || fail 'remote refusal created a remote clone'
echo 'ok - remote gate refusal reports its reason and falls back when local capacity admits'
