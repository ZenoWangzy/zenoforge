#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tmp="$test_env_root/canary"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT

fail() { echo "engine-canary.test.sh: $*" >&2; exit 1; }

make_swap() { # fixture name old id new id
  local name="$1" old_id="$2" new_id="$3"
  CF_OLD_ID="$old_id"
  CF_NEW_ID="$new_id"
  CF_ROOT="$tmp/$name"
  CF_TARGET="$CF_ROOT/target"
  CF_AGENT="$CF_ROOT/agent"
  CF_SUP="$CF_AGENT/supervisor"
  CF_RUNTIME="$CF_SUP/autopi"
  CF_LOADAVG="$CF_ROOT/proc/loadavg"
  CF_MEMORY_PRESSURE="$CF_ROOT/proc/pressure/memory"
  mkdir -p "$CF_TARGET" "$CF_RUNTIME" "$CF_ROOT/proc/pressure" \
    "$CF_AGENT/engine-versions/$old_id/engine/mac-autopilot" \
    "$CF_AGENT/engine-versions/$new_id/engine/mac-autopilot"
  cat > "$CF_AGENT/engine-versions/$old_id/engine/lib.sh" <<'LIB'
supervisor_inbox_append_once() { printf '%s\n' "$2" >> "$AGENT_HOME/supervisor-inbox"; }
LIB
  ln -s "$CF_AGENT/engine-versions/$new_id/engine" "$CF_AGENT/engine-live"
  ln -s "$CF_AGENT/engine-versions/$new_id/engine/mac-autopilot" "$CF_SUP/autopi-live"
  printf '{"engine":{"canary_ticks":2}}\n' > "$CF_RUNTIME/config.json"
  : > "$CF_RUNTIME/scheduler.log"
  : > "$CF_RUNTIME/loop.out"
  write_load 5.00 0.00
}

canary() {
  AGENT_HOME="$CF_AGENT" ZF_REPO_DIR="$CF_TARGET" MAC_AUTOPILOT_ROOT="$CF_TARGET" \
    MAC_AUTOPILOT_SUPERVISOR_DIR="$CF_SUP" MAC_AUTOPILOT_RUNTIME_DIR="$CF_RUNTIME" \
    ZF_CANARY_PROC_LOADAVG="$CF_LOADAVG" ZF_CANARY_PROC_MEMORY_PRESSURE="$CF_MEMORY_PRESSURE" \
    ZF_CANARY_CPU_COUNT=12 ZF_CANARY_LOAD_HOLD=12 ZF_CANARY_CHRONIC_HOURS=6 \
    bash "$here/engine-canary.sh" "$@"
}

record_swap() {
  canary record-swap "$CF_OLD_ID" "$CF_NEW_ID" \
    "$CF_AGENT/engine-versions/$CF_OLD_ID/engine" "$CF_AGENT/engine-versions/$CF_NEW_ID/engine" \
    "$CF_AGENT/engine-versions/$CF_OLD_ID/engine/mac-autopilot" "$CF_AGENT/engine-versions/$CF_NEW_ID/engine/mac-autopilot"
}

write_load() { # load5 psi-full-avg60
  printf '0.00 %s 0.00 1/100 12345\n' "$1" > "$CF_LOADAVG"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=%s avg300=0.00 total=0\n' "$2" \
    > "$CF_MEMORY_PRESSURE"
}

tick() { # optional signature
  local now
  canary tick-begin
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ -n "${1:-}" ]]; then
    printf '[%s] %s\n' "$now" "$1" >> "$CF_RUNTIME/scheduler.log"
  fi
  printf '[%s] tick done units=0\n' "$now" >> "$CF_RUNTIME/scheduler.log"
  canary tick-complete
}

live_engine() { readlink -e "$CF_AGENT/engine-live"; }

# A REFILL-TIMEOUT under fixture load 30 on 12 CPUs is held with its host evidence.
make_swap high-load old new
record_swap
write_load 30.00 0.00
tick 'REFILL-TIMEOUT refill tick killed after 300s'
[[ "$(live_engine)" == "$CF_AGENT/engine-versions/new/engine" ]] || fail 'high-load timeout rolled back the swap'
[[ "$(jq -r '.status' "$CF_AGENT/engine-versions/.swap-record.json")" == held-host-load ]] || fail 'high-load timeout was not held'
[[ "$(jq -r '.hold_evidence[-1].load5 == 30' "$CF_AGENT/engine-versions/.swap-record.json")" == true ]] || fail 'hold did not record load5'
[[ "$(jq -r '.hold_evidence[-1].cpus' "$CF_AGENT/engine-versions/.swap-record.json")" == 12 ]] || fail 'hold did not record CPU count'
grep -Fq 'CANARY-HOLD host load 30.00/12 on REFILL-TIMEOUT' "$CF_RUNTIME/scheduler.log" || fail 'host hold scheduler line missing'

# Full memory pressure at the threshold also holds a timeout when CPU load is low.
make_swap high-memory-pressure old new
record_swap
write_load 5.00 10.00
tick 'REFILL-TIMEOUT refill tick killed after 300s'
[[ "$(live_engine)" == "$CF_AGENT/engine-versions/new/engine" ]] || fail 'memory pressure timeout rolled back the swap'
[[ "$(jq -r '.status' "$CF_AGENT/engine-versions/.swap-record.json")" == held-host-load ]] || fail 'memory pressure timeout was not held'

# The same novel timeout at load 5 remains an immediate rollback.
make_swap low-load old new
record_swap
tick 'REFILL-TIMEOUT refill tick killed after 300s'
[[ "$(live_engine)" == "$CF_AGENT/engine-versions/old/engine" ]] || fail 'low-load timeout did not roll back'
[[ "$(jq -r '.status' "$CF_AGENT/engine-versions/.swap-record.json")" == rolled-back ]] || fail 'low-load rollback state missing'
[[ "$(jq -r '.rollback_evidence.host_load.load5 == 5' "$CF_AGENT/engine-versions/.swap-record.json")" == true ]] || fail 'rollback did not record load evidence'

# A pack-only swap with only rulings.json changed cannot attribute the timeout to executable behavior.
make_swap data-only 'samebase-oldpack' 'samebase-newpack'
git -C "$CF_TARGET" init -q -b main
git -C "$CF_TARGET" config user.name fixture
git -C "$CF_TARGET" config user.email fixture@example.invalid
mkdir -p "$CF_TARGET/.zenoforge/build/pack/state"
printf '{"rules":[]}\n' > "$CF_TARGET/.zenoforge/build/pack/state/rulings.json"
git -C "$CF_TARGET" add .
git -C "$CF_TARGET" commit -qm old-pack
old_pack_ref="$(git -C "$CF_TARGET" rev-parse HEAD)"
printf '{"rules":["new"]}\n' > "$CF_TARGET/.zenoforge/build/pack/state/rulings.json"
git -C "$CF_TARGET" add .
git -C "$CF_TARGET" commit -qm new-pack
new_pack_ref="$(git -C "$CF_TARGET" rev-parse HEAD)"
printf 'pack_sha=%s:.zenoforge/build/pack\n' "$old_pack_ref" > "$CF_AGENT/engine-versions/samebase-oldpack/BUILD-INFO"
printf 'pack_sha=%s:.zenoforge/build/pack\n' "$new_pack_ref" > "$CF_AGENT/engine-versions/samebase-newpack/BUILD-INFO"
record_swap
tick 'REFILL-TIMEOUT refill tick killed after 300s'
[[ "$(live_engine)" == "$CF_AGENT/engine-versions/samebase-newpack/engine" ]] || fail 'data-only timeout rolled back the swap'
[[ "$(jq -r '.pack_change.classification' "$CF_AGENT/engine-versions/.swap-record.json")" == data-only ]] || fail 'pack source diff was not classified data-only'

# After a host hold, a repeat after load recovers is evidence against the swap and rolls it back.
make_swap hold-then-repeat old new
record_swap
write_load 30.00 0.00
tick 'REFILL-TIMEOUT refill tick killed after 300s'
write_load 5.00 0.00
tick 'REFILL-TIMEOUT refill tick killed after 300s'
[[ "$(live_engine)" == "$CF_AGENT/engine-versions/old/engine" ]] || fail 'repeated timeout after load recovery did not roll back'
[[ "$(jq -r '.rollback_evidence.reason' "$CF_AGENT/engine-versions/.swap-record.json")" == repeated-after-host-hold ]] || fail 'rollback did not name the recovered-load repeat evidence'

# With no recent baseline signatures or tick rows, a scheduler signature from four hours ago is chronic.
make_swap chronic old new
old_stamp="$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '[%s] REFILL-TIMEOUT refill tick killed after 300s\n' "$old_stamp" >> "$CF_RUNTIME/scheduler.log"
record_swap
[[ "$(jq -r 'any(.baseline_signatures[]; . == "REFILL-TIMEOUT")' "$CF_AGENT/engine-versions/.swap-record.json")" == true ]] \
  || fail 'four-hour-old timeout was not added to a thin baseline'
tick 'REFILL-TIMEOUT refill tick killed after 300s'
[[ "$(live_engine)" == "$CF_AGENT/engine-versions/new/engine" ]] || fail 'chronic four-hour-old timeout rolled back the swap'

echo 'engine-canary.test.sh: PASS'
