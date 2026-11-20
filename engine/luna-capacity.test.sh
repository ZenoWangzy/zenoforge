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
export LUNA_PROC_MEMINFO="$root/proc/meminfo"
export LUNA_PROC_PSI_MEMORY="$root/proc/pressure/memory"
export LUNA_RUNS_HARD_CAP=10 LUNA_MIN=1 LUNA_MAX=10
export LUNA_ADMIT_AVAIL_MB=3328 LUNA_WORKER_PEAK_MB=1200
export LUNA_CPU_BUSY_AT="$SECONDS" LUNA_CPU_BUSY_VALUE=0
unset WORKER_CPU_PER_RUN
source "$engine/bin/luna-capacity.sh"

failures=0
make_scopes() {
  rm -rf -- "$worker_slice"/luna-*.scope "$worker_slice"/zc-*.scope
  mkdir -p "$worker_slice/luna-session.scope" "$worker_slice/luna-pipeline.scope" \
    "$worker_slice/zc-agent.scope" "$worker_slice/luna-extra.scope"
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

(( failures == 0 )) || exit 1
