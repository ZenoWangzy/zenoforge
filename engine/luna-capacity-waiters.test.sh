#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="$test_env_root/luna-capacity-waiters"
mkdir -p "$root" "$root/ready" "$root/home" "$root/head-slots" "$root/slots"
mkfifo "$root/slots/capacity-wake.fifo"
waiter_pids=()
cleanup() {
  local pid
  for pid in "${waiter_pids[@]}"; do kill "$pid" 2>/dev/null || :; done
  for pid in "${waiter_pids[@]}"; do wait "$pid" 2>/dev/null || :; done
  sleep 0.6
  rm -rf -- "$test_env_root"
}
trap cleanup EXIT
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
printf 'MemAvailable: 8192000 kB\n' > "$root/meminfo"
printf 'some avg10=0 avg60=0 avg300=0 total=0\nfull avg10=0 avg60=0 avg300=0 total=0\n' > "$root/psi"
printf '90\n' > "$root/cpu"
export LUNA_GATE_HOME="$root/home" LUNA_WORKER_SLICE_DIR="$root/no-slice"
export LUNA_PROC_MEMINFO="$root/meminfo" LUNA_PROC_PSI_MEMORY="$root/psi" LUNA_PROC_STAT="$root/proc-stat"
export LUNA_TEST_CPU_FILE="$root/cpu" LUNA_HEAD_COUNT_FILE="$root/head-count" LUNA_READY_DIR="$root/ready"
printf 'cpu 0 0 0 0 0 0 0 0\n' > "$LUNA_PROC_STAT"
export LUNA_PRIORITY=normal LUNA_MIN=0 LUNA_MAX=40 LUNA_ADMIT_AVAIL_MB=3328 LUNA_CPU_TARGET=85 LUNA_CPU_SAMPLE_INTERVAL=0.25
mkdir -p "$root/sampler-bin"
export LUNA_PROCESS_FORKS="$root/sampler-forks"
: > "$LUNA_PROCESS_FORKS"
: > "$LUNA_HEAD_COUNT_FILE"
cat > "$root/sampler-bin/head" <<'EOF'
#!/usr/bin/env bash
printf 'head\n' >> "$LUNA_PROCESS_FORKS"
count=0
read -r count < "$LUNA_HEAD_COUNT_FILE" || :
printf '%s\n' "$((count + 1))" > "$LUNA_HEAD_COUNT_FILE"
if (( count % 2 == 0 )); then
  printf 'cpu 0 0 0 0 0 0 0 0\n'
else
  read -r value < "$LUNA_TEST_CPU_FILE"
  idle=$((100 - value))
  printf 'cpu %s 0 0 %s 0 0 0 0\n' "$value" "$idle"
fi
EOF
cat > "$root/sampler-bin/mv" <<'EOF'
#!/usr/bin/env bash
printf 'mv\n' >> "$LUNA_PROCESS_FORKS"
exec /usr/bin/mv "$@"
EOF
cat > "$root/sampler-bin/sleep" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == 2 ]]; then
  printf 'sample-sleep\n' >> "$LUNA_PROCESS_FORKS"
  exec /usr/bin/sleep 0.01
fi
if [[ "${1:-}" == "$LUNA_CPU_SAMPLE_INTERVAL" ]]; then printf 'interval-sleep\n' >> "$LUNA_PROCESS_FORKS"; fi
exec /usr/bin/sleep "$@"
EOF
chmod +x "$root/sampler-bin/mv" "$root/sampler-bin/sleep" "$root/sampler-bin/head"
PATH="$root/sampler-bin:$PATH"
export PATH
cat > "$root/waiter.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$LUNA_CAPACITY_FILE"
slots="$1"
mkdir -p "$slots"
wait_f="$slots/wait-normal-$BASHPID"
printf '%s\n' "$EPOCHSECONDS" > "$wait_f"
luna_waiter_has_room "$slots" "$wait_f" normal 0 luna && exit 12
: > "$LUNA_READY_DIR/$BASHPID"
luna_waiter_sleep "$slots" 60
EOF
chmod +x "$root/waiter.sh"
export LUNA_CAPACITY_FILE="$engine/bin/luna-capacity.sh"
for i in {1..30}; do
  bash "$root/waiter.sh" "$root/slots" > "$root/waiter-$i.log" 2>&1 &
  waiter_pids+=("$!")
done
shopt -s nullglob
ready=()
for _ in {1..120}; do
  ready=("$root/ready"/*)
  ((${#ready[@]} == 30)) && break
  sleep 0.025
done
if (( ${#ready[@]} != 30 )); then
  for log in "$root"/waiter-*.log; do
    [[ -s "$log" ]] && { cat "$log" >&2; break; }
  done
  fail "${#ready[@]} of 30 simulated waiters reached the wait state"
fi
for _ in {1..120}; do
  [[ -s "$AGENT_HOME/locks/luna-host-cpu.sample" ]] && break
  sleep 0.025
done
[[ -s "$AGENT_HOME/locks/luna-host-cpu.sample" ]] || fail 'sampler did not publish the shared host CPU sample'
sleep 0.05
: > "$LUNA_HEAD_COUNT_FILE"
: > "$LUNA_PROCESS_FORKS"
sleep 1
for _ in {1..100}; do
  read -r head_count < "$LUNA_HEAD_COUNT_FILE"
  (( head_count % 2 == 0 )) && break
  sleep 0.01
done
mapfile -t sampler_forks < "$LUNA_PROCESS_FORKS"
read -r head_count < "$LUNA_HEAD_COUNT_FILE"
(( head_count % 2 == 0 )) || fail "CPU sampler made an incomplete /proc/stat pair with $head_count head calls"
samples=$((head_count / 2))
(( samples <= 6 )) || fail "30 simulated waiters caused $samples CPU samples in one simulated minute; want at most 6"
(( ${#sampler_forks[@]} <= 30 )) || fail "one simulated minute caused ${#sampler_forks[@]} sampler utility forks; want at most 30"
(( samples + ${#sampler_forks[@]} <= 36 )) || fail "30 simulated waiters caused more than 36 measured sampler forks in one simulated minute"
source "$LUNA_CAPACITY_FILE"
head_wait="$root/head-slots/wait-normal-$BASHPID"
printf '%s\n' "$((EPOCHSECONDS - 100))" > "$head_wait"
printf '50\n' > "$root/cpu"
admitted=0
for _ in {1..120}; do
  if luna_waiter_has_room "$root/head-slots" "$head_wait" normal 0 luna; then admitted=1; break; fi
  sleep 0.025
done
(( admitted == 1 )) || fail 'head waiter stayed blocked after the shared host CPU sample fell below target'
export LUNA_GATE_HOME="$root/high-cpu-home"
mkdir -p "$LUNA_GATE_HOME/locks" "$root/high-cpu-slots"
source "$LUNA_CAPACITY_FILE"
printf '%s 90\n' "$EPOCHSECONDS" > "$LUNA_CPU_BUSY_FILE"
high_head="$root/high-cpu-slots/wait-normal-$BASHPID"
printf '%s\n' "$((EPOCHSECONDS - 100))" > "$high_head"
mkfifo "$root/high-cpu-slots/capacity-wake.fifo"
export LUNA_BOX_ROOM_CALLS="$root/box-room-calls"
: > "$LUNA_BOX_ROOM_CALLS"
box_has_room() { printf 'called\n' >> "$LUNA_BOX_ROOM_CALLS"; return 1; }
for _ in {1..5}; do
  luna_waiter_has_room "$root/high-cpu-slots" "$high_head" normal 0 luna && fail 'high CPU head unexpectedly entered the full capacity check'
  luna_waiter_sleep "$root/high-cpu-slots" 0.01
done
[[ ! -s "$LUNA_BOX_ROOM_CALLS" ]] || fail 'high CPU head spawned a full capacity check on a retry'
source "$LUNA_CAPACITY_FILE"
printf '%s 50\n' "$EPOCHSECONDS" > "$LUNA_CPU_BUSY_FILE"
export LUNA_FORKS="$root/room-forks" LUNA_PROC_PSI_MEMORY="$root/psi-blocked"
printf 'some avg10=0 avg60=0 avg300=0 total=0\nfull avg10=20 avg60=20 avg300=20 total=0\n' > "$LUNA_PROC_PSI_MEMORY"
mkdir -p "$root/fork-bin"
cat > "$root/fork-bin/awk" <<'EOF'
#!/usr/bin/env bash
printf 'awk %s\n' "$BASHPID" >> "$LUNA_FORKS"
exec /usr/bin/awk "$@"
EOF
chmod +x "$root/fork-bin/awk"
PATH="$root/fork-bin:$PATH"
export PATH
: > "$LUNA_FORKS"
codex_runs() { printf 'codex_runs %s\n' "$BASHPID" >> "$LUNA_FORKS"; printf '0\n'; }
worker_scope_runs() { printf 'worker_scope_runs %s\n' "$BASHPID" >> "$LUNA_FORKS"; printf '0\n'; }
slice_cpu_max() { printf 'slice_cpu_max %s\n' "$BASHPID" >> "$LUNA_FORKS"; }
slice_cpu_run_cap() { printf 'slice_cpu_run_cap %s\n' "$BASHPID" >> "$LUNA_FORKS"; }
slice_cpu_floor_run_cap() { printf 'slice_cpu_floor_run_cap %s\n' "$BASHPID" >> "$LUNA_FORKS"; }
slice_room_mb() { printf 'slice_room_mb %s\n' "$BASHPID" >> "$LUNA_FORKS"; }
luna_run_cap() { printf 'luna_run_cap %s\n' "$BASHPID" >> "$LUNA_FORKS"; printf '40\n'; }
LUNA_WAIT_ROOM_CHECK_AT=""
start_seconds=$SECONDS
for _ in {1..60}; do
  luna_waiter_has_room "$root/high-cpu-slots" "$high_head" normal 0 luna || :
done
mapfile -t fork_calls < "$LUNA_FORKS"
(( ${#fork_calls[@]} == 9 )) || fail "60 blocked head polls spawned ${#fork_calls[@]} measured gate processes; want 9"
SECONDS=$((start_seconds + 30))
luna_waiter_has_room "$root/high-cpu-slots" "$high_head" normal 0 luna || :
mapfile -t fork_calls < "$LUNA_FORKS"
(( ${#fork_calls[@]} == 9 )) || fail 'blocked-check throttle expired before the 30-second backoff ceiling'
SECONDS=$((start_seconds + 31))
luna_waiter_has_room "$root/high-cpu-slots" "$high_head" normal 0 luna || :
mapfile -t fork_calls < "$LUNA_FORKS"
(( ${#fork_calls[@]} == 18 )) || fail "full capacity check did not refresh at 31 seconds: ${#fork_calls[@]} measured gate processes"
source "$LUNA_CAPACITY_FILE"
mkdir -p "$root/scan-bin" "$root/scan-slots" "$root/scan-ready" "$root/scan-done"
mkfifo "$root/scan-slots/capacity-wake.fifo"
export LUNA_POLL_COMMANDS="$root/poll-commands" LUNA_SCAN_READY_DIR="$root/scan-ready" LUNA_SCAN_DONE_DIR="$root/scan-done"
: > "$LUNA_POLL_COMMANDS"
cat > "$root/scan-bin/cat" <<'EOF'
#!/usr/bin/env bash
printf 'cat\n' >> "$LUNA_POLL_COMMANDS"
exec /usr/bin/cat "$@"
EOF
cat > "$root/scan-bin/stat" <<'EOF'
#!/usr/bin/env bash
printf 'stat\n' >> "$LUNA_POLL_COMMANDS"
exec /usr/bin/stat "$@"
EOF
cat > "$root/scan-bin/sleep" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" != 5 ]] || printf 'sleep\n' >> "$LUNA_POLL_COMMANDS"
exec /usr/bin/sleep "$@"
EOF
chmod +x "$root/scan-bin/cat" "$root/scan-bin/stat" "$root/scan-bin/sleep"
scan_head="$root/scan-slots/wait-normal-$BASHPID"
printf '%s\n' "$((EPOCHSECONDS - 100))" > "$scan_head"
cat > "$root/scan-waiter.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$LUNA_CAPACITY_FILE"
slots="$1"
wait_f="$slots/wait-normal-$BASHPID"
printf '%s\n' "$EPOCHSECONDS" > "$wait_f"
: > "$LUNA_SCAN_READY_DIR/$BASHPID"
for _ in {1..5}; do
  luna_waiter_has_room "$slots" "$wait_f" normal 0 luna && exit 13
  luna_waiter_sleep "$slots" 0.01
done
: > "$LUNA_SCAN_DONE_DIR/$BASHPID"
EOF
chmod +x "$root/scan-waiter.sh"
PATH="$root/scan-bin:$PATH"
export PATH
for i in {1..29}; do
  bash "$root/scan-waiter.sh" "$root/scan-slots" > "$root/scan-waiter-$i.log" 2>&1 &
  waiter_pids+=("$!")
done
scan_ready=()
for _ in {1..120}; do
  scan_ready=("$root/scan-ready"/*)
  ((${#scan_ready[@]} == 29)) && break
  sleep 0.025
done
(( ${#scan_ready[@]} == 29 )) || fail "${#scan_ready[@]} of 29 queued waiters reached the wait state"
scan_done=()
for _ in {1..120}; do
  scan_done=("$root/scan-done"/*)
  (( ${#scan_done[@]} == 29 )) && break
  sleep 0.025
done
(( ${#scan_done[@]} == 29 )) || fail "${#scan_done[@]} of 29 queued waiters completed five polls"
[[ ! -s "$LUNA_POLL_COMMANDS" ]] || fail "ticket polling spawned external commands: $(<"$LUNA_POLL_COMMANDS")"
[[ -p "$root/scan-slots/capacity-wake.fifo" ]] || fail 'ticket cleanup removed the shared wake FIFO'
luna_wait_backoff 0
first_delay=$LUNA_WAIT_DELAY
luna_wait_backoff 1
second_delay=$LUNA_WAIT_DELAY
(( first_delay >= 15 && second_delay >= first_delay )) || fail "waiter delays did not back off from at least 15 seconds: $first_delay then $second_delay"
printf 'PASS 30 waiters shared %s CPU samples and %s sampler utility forks in one simulated minute; blocked head checks used 9 measured gate processes once per 31 seconds, ticket scans stayed in-shell, and the head was admitted below target\n' "$samples" "${#sampler_forks[@]}"
