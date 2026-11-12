#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
bin=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(mktemp -d); trap 'rm -rf "$root" "$test_env_root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# gate <file> <avail_mb> <psi_full> <priority> <age_seconds> <cpu_busy>: prints admitted or refused.
# Loads the real box_has_room from the file. PSI some is fixed at 32 (the live value that used to block hotfix).
# LUNA_MIN=0 keeps the first tier out, and age and cpu are set so only the tier under test can admit.
gate() {
  local file=$1 d; d=$(mktemp -d -p "$root")
  printf 'MemAvailable: %s kB\n' "$(( $2 * 1024 ))" >"$d/meminfo"
  printf 'some avg10=32 avg60=35 avg300=36 total=1\nfull avg10=%s avg60=4 avg300=4.6 total=1\n' "$3" >"$d/psi"
  grep -Fq 'luna-capacity.sh' "$file" || fail "$(basename "$file") does not source shared capacity admission"
  (
    export LUNA_PROC_MEMINFO="$d/meminfo" LUNA_PROC_PSI_MEMORY="$d/psi" LUNA_PRIORITY="$4" LUNA_MIN=0 LUNA_MAX=10 LUNA_ADMIT_AVAIL_MB=3328
    export LUNA_AGE_ADMIT_SECONDS="$5" CPU_BUSY="$6"
    source "$bin/luna-capacity.sh"
    codex_runs() { echo 0; }
    cpu_busy() { echo "$CPU_BUSY"; }
    if box_has_room; then echo admitted; else echo refused; fi
  )
}
# expect <file> <avail_mb> <full> <priority> <age> <cpu> <want>
expect() {
  local got; got=$(gate "$1" "$2" "$3" "$4" "$5" "$6")
  [[ $got == "$7" ]] || fail "$(basename "$1") avail=$2 full=$3 prio=$4 age=$5 cpu=$6: got $got, want $7"
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
  expect "$f"  3000   0   normal   999999 0   refused  # normal below measured floor
  expect "$f"  3400  12   normal   999999 0   refused  # normal, full 12
  expect "$f"  6000   2   normal   999999 0   admitted # normal tier: cpu under target, full < 10, 5 GB free
  expect "$f"  6000   2   normal   999999 100 refused  # CPU-full with runs below cap
  expect "$f"  6000  12   normal   999999 0   refused  # normal, full 12
  expect "$f"  3400   0   normal        0 100  admitted # aging tier alone: cpu busy, aged, measured floor
  expect "$f"  6000  12   normal        0 100  refused  # aging, full 12
  wait_file_case "$f"
done
echo "ok - hotfix admits at 3 GB with full < 10; normal and aging admit at the 3328 MB floor with full < 10; full 12 refused; in luna and zc"
