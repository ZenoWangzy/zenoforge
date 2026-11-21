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

# Per-backend worker peak (queue row 881): no samples keep the flat 1200; a backend's own recorded p90 replaces it
# for that backend only; an explicit LUNA_WORKER_PEAK_MB wins; a missing memory.peak at scope end records nothing.
store="$AGENT_HOME/locks/execution-memory-peaks-backend.jsonl"
unset LUNA_WORKER_PEAK_MB
record_peak() { # <backend> <scope> <mb>: one ended worker scope fixture with that cgroup peak
  mkdir -p "$worker_slice/$2.scope"
  printf '%s\n' "$(( $3 * 1048576 ))" > "$worker_slice/$2.scope/memory.peak"
  luna_record_scope_peak "$1" "$2"
}
slice_room_set() { # <mb>: leave <mb> under the 10 GiB memory.high, no scopes running
  make_n_scopes 0
  printf '10737418240\n' > "$worker_slice/memory.high"
  printf '%s\n' "$(( (10240 - $1) * 1048576 ))" > "$worker_slice/memory.current"
}

# (a) no samples: a known backend keeps the flat 1200 default; a backend-less ask holds at the interim 800.
rm -f -- "$store"
printf 'max 100000\n' > "$root/cgroup/zf.slice/cpu.max"
slice_room_set 300
read -r estimate estimate_source <<< "$(worker_peak_mb)"
if [[ "$estimate" == 800 && "$estimate_source" == interim ]]; then
  printf 'PASS no samples keeps the interim 800MB peak for a backend-less ask\n'
else
  printf 'FAIL backend-less estimate without samples: got %s %s\n' "$estimate" "$estimate_source"
  failures=$((failures + 1))
fi
if box_has_room 0 zc; then
  printf 'FAIL no samples admits with only 300MB left under memory.high\n'
  failures=$((failures + 1))
elif [[ "$BOX_ROOM_WHY" == 'worker slice 300MB left under memory.high < 1200MB worker peak backend=zc source=default' ]]; then
  printf 'PASS no samples keeps the flat 1200MB peak as the default\n'
else
  printf 'FAIL no-sample refusal did not name the default: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi

# (b) each backend uses its own recorded p90; luna's 340MB p90 rises to the 512MB floor.
rm -f -- "$store"
for mb in 600 620 640 660 680 700 720 740 760 780; do record_peak zc "luna-zc-peak-$mb" "$mb"; done
for mb in 300 320 340; do record_peak luna "luna-peak-$mb" "$mb"; done
read -r estimate estimate_source <<< "$(worker_peak_mb zc)"
if [[ "$estimate" == 760 && "$estimate_source" == measured ]]; then
  printf 'PASS zc p90 of ten samples is the ninth: 760\n'
else
  printf 'FAIL zc estimate: got %s %s\n' "$estimate" "$estimate_source"
  failures=$((failures + 1))
fi
read -r estimate estimate_source <<< "$(worker_peak_mb luna)"
if [[ "$estimate" == 512 && "$estimate_source" == measured ]]; then
  printf 'PASS luna keeps its own 340MB p90 raised to the 512MB floor\n'
else
  printf 'FAIL luna estimate: got %s %s\n' "$estimate" "$estimate_source"
  failures=$((failures + 1))
fi
read -r estimate estimate_source <<< "$(worker_peak_mb)"
if [[ "$estimate" == 800 && "$estimate_source" == interim ]]; then
  printf 'PASS a backend-less ask holds at the interim 800, not the higher measured p90\n'
else
  printf 'FAIL backend-less estimate with samples: got %s %s\n' "$estimate" "$estimate_source"
  failures=$((failures + 1))
fi
slice_room_set 700
if box_has_room 0 zc; then
  printf 'FAIL 700MB left under a zc p90 of 760 was admitted\n'
  failures=$((failures + 1))
elif [[ "$BOX_ROOM_WHY" == 'worker slice 700MB left under memory.high < 760MB worker peak backend=zc source=measured' ]]; then
  printf 'PASS zc refusal names its own measured p90\n'
else
  printf 'FAIL zc measured refusal: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi
if box_has_room 0 luna; then
  printf 'PASS luna admits at 700MB left with its own floored 512MB estimate\n'
else
  printf 'FAIL luna admits at 700MB left with its own estimate: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi

# (c) an explicit LUNA_WORKER_PEAK_MB wins over recorded samples.
if LUNA_WORKER_PEAK_MB=800 box_has_room 0 zc; then
  printf 'FAIL explicit LUNA_WORKER_PEAK_MB=800 admits at 700MB left\n'
  failures=$((failures + 1))
elif [[ "$BOX_ROOM_WHY" == 'worker slice 700MB left under memory.high < 800MB worker peak backend=zc source=set' ]]; then
  printf 'PASS explicit LUNA_WORKER_PEAK_MB=800 wins over the zc samples\n'
else
  printf 'FAIL explicit-override refusal: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi

# (d) the head acceptance for this row: 971MB left, zc p90 of 400 (512 after the floor), the gate admits; the
# scheduler dispatch hold (no backend) starts run-p workers whose peaks are not recorded (701/1216/2049MB on 11-21),
# so it holds at the interim 800 instead of a measured p90.
rm -f -- "$store"
record_peak zc luna-zc-peak-400 400
read -r estimate estimate_source <<< "$(worker_peak_mb)"
if [[ "$estimate" == 800 && "$estimate_source" == interim ]]; then
  printf 'PASS a backend-less ask with zc samples of 400 keeps the interim 800MB peak\n'
else
  printf 'FAIL backend-less estimate with zc samples: got %s %s\n' "$estimate" "$estimate_source"
  failures=$((failures + 1))
fi
slice_room_set 971
if box_has_room 0 zc; then
  printf 'PASS 971MB left with a zc p90 of 400 admits an implement worker\n'
else
  printf 'FAIL 971MB left with a zc p90 of 400 refused: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi
if box_has_room 0; then
  printf 'PASS the dispatch hold admits at 971MB left under the interim 800MB peak\n'
else
  printf 'FAIL the dispatch hold refused at 971MB left: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi
slice_room_set 700
if box_has_room 0; then
  printf 'FAIL the dispatch hold admits with only 700MB left under the interim 800MB peak\n'
  failures=$((failures + 1))
elif [[ "$BOX_ROOM_WHY" == 'worker slice 700MB left under memory.high < 800MB worker peak backend=- source=interim' ]]; then
  printf 'PASS the dispatch hold refusal at 700MB left names the interim peak\n'
else
  printf 'FAIL dispatch hold refusal did not name the interim peak: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi

# Row 894: the scheduler's run-p worker scopes record their peaks as backend sched; the dispatch hold (no backend)
# keeps the interim 800 until 5 sched samples exist, then uses their p90 with the 512MB floor; luna/zc rows do not
# move it and an explicit LUNA_WORKER_PEAK_MB still wins.
rm -f -- "$store"
for mb in 600 700 800 900; do record_peak sched "sched-peak-$mb" "$mb"; done
read -r estimate estimate_source <<< "$(worker_peak_mb)"
if [[ "$estimate" == 800 && "$estimate_source" == interim ]]; then
  printf 'PASS four sched samples still hold the dispatch hold at the interim 800MB peak\n'
else
  printf 'FAIL dispatch hold with four sched samples: got %s %s\n' "$estimate" "$estimate_source"
  failures=$((failures + 1))
fi
record_peak sched sched-peak-1000 1000
read -r estimate estimate_source <<< "$(worker_peak_mb)"
if [[ "$estimate" == 1000 && "$estimate_source" == measured ]]; then
  printf 'PASS five sched samples give their own p90: the fifth of five sorted is the largest, 1000\n'
else
  printf 'FAIL dispatch hold with five sched samples: got %s %s\n' "$estimate" "$estimate_source"
  failures=$((failures + 1))
fi
for mb in 1100 1200 1300 1400 1500; do record_peak sched "sched-peak-$mb" "$mb"; done
record_peak zc zc-noise-peak 100
read -r estimate estimate_source <<< "$(worker_peak_mb)"
if [[ "$estimate" == 1400 && "$estimate_source" == measured ]]; then
  printf 'PASS the sched p90 of ten samples is the ninth: 1400, and a zc row does not move it\n'
else
  printf 'FAIL dispatch hold with ten sched samples plus a zc row: got %s %s\n' "$estimate" "$estimate_source"
  failures=$((failures + 1))
fi
slice_room_set 1000
if box_has_room 0; then
  printf 'FAIL the dispatch hold admitted at 1000MB left under a measured sched p90 of 1400\n'
  failures=$((failures + 1))
elif [[ "$BOX_ROOM_WHY" == 'worker slice 1000MB left under memory.high < 1400MB worker peak backend=- source=measured' ]]; then
  printf 'PASS the dispatch hold refusal names the measured sched p90\n'
else
  printf 'FAIL dispatch hold measured refusal: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi
if LUNA_WORKER_PEAK_MB=700 box_has_room 0; then
  printf 'PASS an explicit LUNA_WORKER_PEAK_MB=700 admits at 1000MB left over ten sched samples\n'
else
  printf 'FAIL explicit override over sched samples: %s\n' "$BOX_ROOM_WHY"
  failures=$((failures + 1))
fi
rm -f -- "$store"
for mb in 300 310 320 330 340; do record_peak sched "sched-peak-$mb" "$mb"; done
read -r estimate estimate_source <<< "$(worker_peak_mb)"
if [[ "$estimate" == 512 && "$estimate_source" == measured ]]; then
  printf 'PASS the 340MB sched p90 of five small samples rises to the 512MB floor\n'
else
  printf 'FAIL floored sched estimate: got %s %s\n' "$estimate" "$estimate_source"
  failures=$((failures + 1))
fi

# (e) a missing memory.peak at scope end records nothing and changes no exit status.
rm -f -- "$store"
mkdir -p "$worker_slice/luna-ended.scope" # the cgroup dir may be reaped already, or lack memory.peak
luna_record_scope_peak luna luna-ended
record_rc=$?
luna_record_scope_peak zc luna-gone
if [[ "$record_rc" == 0 && ! -e "$store" ]]; then
  printf 'PASS a missing memory.peak records nothing and keeps exit status 0\n'
else
  printf 'FAIL missing memory.peak: rc=%s store=%s\n' "$record_rc" "$([[ -e "$store" ]] && echo present || echo absent)"
  failures=$((failures + 1))
fi

# (f) row 894: systemd reaps the cgroup the moment the run ends, so the wrapper samples memory.peak while the scoped
# pid lives; the last sample still records after the cgroup directory is gone. No readable memory.peak at any time
# records nothing and changes no exit status.
rm -f -- "$store" "$root/peak-sample" "$root/peak-none"
mkdir -p "$worker_slice/luna-live.scope"
printf '734003200\n' > "$worker_slice/luna-live.scope/memory.peak" # 700 MB
sleep 60 & live_pid=$!
luna_watch_scope_peak luna-live "$live_pid" "$root/peak-sample" &
sampler_pid=$!
sampled=''
for _ in {1..50}; do
  if [[ -s "$root/peak-sample" ]]; then read -r sampled < "$root/peak-sample"; break; fi
  sleep 0.1
done
if [[ "$sampled" == 734003200 ]]; then
  printf 'PASS the sampler reads memory.peak while the scope lives\n'
else
  printf 'FAIL the sampler read no peak while the scope lived: %s\n' "${sampled:-none}"
  failures=$((failures + 1))
fi
live_rc=0
kill "$live_pid" 2>/dev/null || :
wait "$live_pid" 2>/dev/null || live_rc=$?
rm -rf -- "$worker_slice/luna-live.scope" # the cgroup dies with the run
read -r sampled < "$root/peak-sample"
luna_record_scope_peak luna luna-live "$sampled"
if [[ "$live_rc" == 143 && "$(jq -s 'length == 1 and .[0].backend == "luna" and .[0].memory_peak_mb == 700' "$store" 2>/dev/null)" == true ]]; then
  printf 'PASS a sample read while the scope lived records after the cgroup went away, run rc %s untouched\n' "$live_rc"
else
  printf 'FAIL the alive-read sample did not survive the cgroup: rc=%s rows=%s\n' "$live_rc" "$(jq -s length "$store" 2>/dev/null || echo none)"
  failures=$((failures + 1))
fi
kill "$sampler_pid" 2>/dev/null || :
wait "$sampler_pid" 2>/dev/null || :
mkdir -p "$worker_slice/luna-empty.scope" # never has a readable memory.peak
sleep 1 & live_pid=$!
luna_watch_scope_peak luna-empty "$live_pid" "$root/peak-none" &
sampler_pid=$!
wait "$live_pid" # rc 0: nothing below may disturb it
read -r unsampled < "$root/peak-none" 2>/dev/null || unsampled=''
luna_record_scope_peak luna luna-empty "$unsampled"
record_rc=$?
if [[ "$record_rc" == 0 && "$(jq -s length "$store" 2>/dev/null || echo 0)" == 1 ]]; then
  printf 'PASS no readable memory.peak at any time appends nothing and keeps exit status 0\n'
else
  printf 'FAIL no-peak scope: recorder rc=%s store rows=%s\n' "$record_rc" "$(jq -s length "$store" 2>/dev/null || echo '?')"
  failures=$((failures + 1))
fi
kill "$sampler_pid" 2>/dev/null || :
wait "$sampler_pid" 2>/dev/null || :

(( failures == 0 )) || exit 1
