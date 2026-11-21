#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT

engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="$test_env_root/luna-capacity"
worker_slice="$root/cgroup/zf.slice/zf-workers.slice"
mkdir -p "$worker_slice" "$root/proc/pressure"
printf '200000 100000\n' > "$root/cgroup/zf.slice/cpu.max"
printf '10737418240\n' > "$worker_slice/memory.high"
printf '0\n' > "$worker_slice/memory.current"
printf 'MemAvailable: 8192000 kB\n' > "$root/proc/meminfo"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$root/proc/pressure/memory"

export LUNA_WORKER_SLICE_DIR="$worker_slice"
export LUNA_SLOTS="$root/slots"
export LUNA_PROC_MEMINFO="$root/proc/meminfo"
export LUNA_PROC_PSI_MEMORY="$root/proc/pressure/memory"
export LUNA_PROC_UPTIME="$root/proc/uptime"
export LUNA_RUNS_HARD_CAP=10 LUNA_MIN=1 LUNA_MAX=10
export LUNA_ADMIT_AVAIL_MB=3328 LUNA_WORKER_PEAK_MB=1200
export LUNA_CPU_BUSY_AT="$SECONDS" LUNA_CPU_BUSY_VALUE=0
unset LUNA_PRIORITY WORKER_CPU_PER_RUN WORKER_CPU_PER_RUN_EST WORKER_CPU_FLOOR
mkdir -p "$LUNA_SLOTS"
source "$engine/bin/luna-capacity.sh"

failures=0
make_scopes() {
  rm -rf -- "$worker_slice"/luna-*.scope "$worker_slice"/zc-*.scope
  mkdir -p "$worker_slice/luna-session.scope" "$worker_slice/luna-pipeline.scope" \
    "$worker_slice/zc-agent.scope" "$worker_slice/luna-extra.scope"
}
make_n_scopes() {
  local n
  rm -rf -- "$worker_slice"/luna-*.scope "$worker_slice"/zc-*.scope
  for ((n=0; n<$1; n++)); do mkdir -p "$worker_slice/luna-test-$n.scope"; done
}
prime_cpu_sample() {
  local current=$1 previous=$2
  printf '7000 %s -\n' "$previous" > "$LUNA_SLOTS/zf-slice-cpu.sample"
  printf 'usage_usec %s\n' "$current" > "$worker_slice/cpu.stat"
  printf '100.00 0.00\n' > "$LUNA_PROC_UPTIME"
}

make_scopes
if box_has_room; then
  printf 'FAIL cpu.max 200000 100000 rejects 4 of 4 worker scopes: admitted\n'
  failures=$((failures + 1))
elif [[ "$BOX_ROOM_WHY" != *'CPU quota'* || "$BOX_ROOM_WHY" != *'200000/100000'* ]]; then
  printf 'FAIL cpu quota defer names the quota: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
else
  printf 'PASS cpu.max 200000 100000 rejects 4 worker scopes: %s\n' "$BOX_ROOM_WHY"
fi

rm -rf -- "$worker_slice/luna-extra.scope"
if box_has_room; then
  printf 'PASS cpu.max 200000 100000 admits 3 of 4 worker scopes\n'
else
  printf 'FAIL cpu.max 200000 100000 admits 3 of 4 worker scopes: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi

make_scopes
# 11-20: a production hotfix waited at "worker scopes 4/4" with 6.4 GB free; hotfix crosses the scope cap, not the memory floor.
if LUNA_PRIORITY=hotfix box_has_room; then
  printf 'PASS hotfix crosses the 4 of 4 worker scope cap\n'
else
  printf 'FAIL hotfix crosses the 4 of 4 worker scope cap: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=12.00 avg60=0.00 avg300=0.00 total=0\n' > "$root/proc/pressure/memory"
if LUNA_PRIORITY=hotfix box_has_room; then
  printf 'FAIL hotfix under full memory pressure is refused: admitted\n'
  failures=$((failures + 1))
else
  printf 'PASS hotfix under full memory pressure is refused\n'
fi
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$root/proc/pressure/memory"
printf '10737418240\n' > "$worker_slice/memory.current"
if LUNA_PRIORITY=hotfix box_has_room; then
  printf 'FAIL hotfix without worker slice room is refused: admitted\n'
  failures=$((failures + 1))
else
  printf 'PASS hotfix without worker slice room is refused: %s\n' "$BOX_ROOM_WHY"
fi
printf '0\n' > "$worker_slice/memory.current"

make_scopes
printf 'max 100000\n' > "$root/cgroup/zf.slice/cpu.max"
if box_has_room; then
  printf 'PASS cpu.max max 100000 skips the CPU bound\n'
else
  printf 'FAIL cpu.max max 100000 skips the CPU bound: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi

printf '200000 100000\n' > "$root/cgroup/zf.slice/cpu.max"
make_scopes
prime_cpu_sample 15000000 0
if box_has_room; then
  printf 'PASS four scopes using 0.5 CPU under a 2 CPU quota admit a fifth\n'
else
  printf 'FAIL four scopes using 0.5 CPU under a 2 CPU quota admit a fifth: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi

make_n_scopes 1
prime_cpu_sample 57000000 0
if box_has_room; then
  printf 'FAIL measured 1.9 of 2 CPUs refuses another run: admitted\n'
  failures=$((failures + 1))
elif [[ "$BOX_ROOM_WHY" == 'zf-workers.slice cpu used 1.90/2 CPUs, est +0.25 per run' ]]; then
  printf 'PASS measured 1.9 of 2 CPUs refuses another run: %s\n' "$BOX_ROOM_WHY"
else
  printf 'FAIL measured CPU refusal names measured usage: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi

make_scopes
rm -f -- "$LUNA_SLOTS/zf-slice-cpu.sample"
printf 'usage_usec 0\n' > "$worker_slice/cpu.stat"
if box_has_room; then
  printf 'FAIL no previous CPU sample falls back to the flat four-scope rule: admitted\n'
  failures=$((failures + 1))
elif [[ "$BOX_ROOM_WHY" == *'worker scopes 4/4'* ]]; then
  printf 'PASS no previous CPU sample falls back to the flat rule: %s\n' "$BOX_ROOM_WHY"
else
  printf 'FAIL no previous CPU sample did not use the flat rule: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi

make_n_scopes 13
prime_cpu_sample 0 0
if box_has_room; then
  printf 'FAIL the 0.15 CPU floor caps scopes at 13 under a 2 CPU quota: admitted\n'
  failures=$((failures + 1))
elif [[ "$BOX_ROOM_WHY" == 'zf-workers.slice cpu used 0.00/2 CPUs, est +0.25 per run' ]]; then
  printf 'PASS the 0.15 CPU floor caps scopes at 13 under a 2 CPU quota\n'
else
  printf 'FAIL CPU floor refusal names measured usage: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi

# Callers poll more often than every 30 s: a poll before the first measurement must keep the baseline.
make_scopes
prime_cpu_sample 0 0
printf '80.00 0.00\n' > "$LUNA_PROC_UPTIME"
printf 'usage_usec 5000000\n' > "$worker_slice/cpu.stat"
box_has_room || true
printf '100.00 0.00\n' > "$LUNA_PROC_UPTIME"
printf 'usage_usec 15000000\n' > "$worker_slice/cpu.stat"
if box_has_room; then
  printf 'PASS a poll before the first measurement keeps the 30 s baseline\n'
else
  printf 'FAIL a poll before the first measurement reset the baseline: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi

# The scheduler, batch, release and bell load in zf.slice (1.30 of 1.5 CPUs) must not close the gate: only worker use counts.
make_n_scopes 0
printf '150000 100000\n' > "$root/cgroup/zf.slice/cpu.max"
prime_cpu_sample 0 0
printf 'usage_usec 39000000\n' > "$root/cgroup/zf.slice/cpu.stat"
if box_has_room; then
  printf 'PASS zf.slice 1.30 of 1.5 CPUs of non-worker load with no worker admits a run\n'
else
  printf 'FAIL zf.slice 1.30 of 1.5 CPUs of non-worker load with no worker admits a run: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi

# Workers using the whole 1.5 CPU budget are refused.
make_n_scopes 3
prime_cpu_sample 45000000 0
if box_has_room; then
  printf 'FAIL workers using 1.50 of 1.5 CPUs refuse another run: admitted\n'
  failures=$((failures + 1))
elif [[ "$BOX_ROOM_WHY" == 'zf-workers.slice cpu used 1.50/1.5 CPUs, est +0.25 per run' ]]; then
  printf 'PASS workers using 1.50 of 1.5 CPUs refuse another run: %s\n' "$BOX_ROOM_WHY"
else
  printf 'FAIL workers using 1.50 of 1.5 CPUs refusal names worker usage: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi

(( failures == 0 )) || exit 1
