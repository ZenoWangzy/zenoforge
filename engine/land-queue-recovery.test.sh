#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
queue_script="${LAND_QUEUE_TEST_SCRIPT:-$root/engine/land-queue.sh}"
trap 'rm -rf -- "$test_env_root"' EXIT
export ZF_LAND_QUEUE_DIR="$test_env_root/queue" ZF_EGRESS_PROXY=http://127.0.0.1:3128
export RECOVERY_START_LOG="$test_env_root/starts" RECOVERY_ACTIVE_UNITS="$test_env_root/active-units"
: > "$RECOVERY_ACTIVE_UNITS"
mkdir -p "$ZF_LAND_QUEUE_DIR/requests" "$test_env_root/wt"
: > "$RECOVERY_START_LOG"
cat > "$test_env_bin/systemctl" <<'EOF'
#!/bin/bash
if [[ "$*" == *list-units* ]]; then
  cat "$RECOVERY_ACTIVE_UNITS"
  exit 0
fi
if [[ "$*" == *is-active* ]]; then
  grep -Fq "${!#}.service " "$RECOVERY_ACTIVE_UNITS"
  exit $?
fi
exit 0
EOF
cat > "$test_env_bin/systemd-run" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in --unit=*) printf '%s\n' "${arg#--unit=}" >> "$RECOVERY_START_LOG" ;; esac
done
EOF
cat > "$test_env_bin/uptime" <<'EOF'
#!/bin/bash
date -d '2 hours ago' '+%Y-%m-%d %H:%M:%S'
EOF
chmod +x "$test_env_bin/systemctl" "$test_env_bin/systemd-run" "$test_env_bin/uptime"
python3 - "$ZF_LAND_QUEUE_DIR" "$test_env_root" <<'FIXTURE'
import json, pathlib, sys
queue, tmp = map(pathlib.Path, sys.argv[1:])
for i in range(1, 1001):
    state = ['failed', 'cancelled', 'landed'][i % 3]
    row = {'ticket': f'{i:020}', 'state': state, 'hand_owner_handoff': 'done',
           'post_land_verdict': {'outcome': 'green'}, 'post_land_conclusion_recorded': True}
    (queue / 'requests' / f'{i:020}.json').write_text(json.dumps(row))
for i in [1001, 1002, 1003]:
    row = {'ticket': f'{i:020}', 'state': 'queued', 'retry_after_epoch': 1 if i < 1003 else 9999999999,
           'owner': f'hand-{i}', 'worktree': str(tmp / 'wt'), 'report': str(tmp / 'report'),
           'plan_package': 'land-recovery'}
    (queue / 'requests' / f'{i:020}.json').write_text(json.dumps(row))
(tmp / 'report').write_text('STATUS: DONE\n')
FIXTURE
start_ms=$(( ${EPOCHREALTIME/./} / 1000 ))
if ! timeout 30 bash "$queue_script" recover > "$test_env_root/recover.log" 2>&1; then # wall-clock-allow: reproduce the tick's explicit 30-second recovery budget
  cat "$test_env_root/recover.log" >&2
  echo 'FAIL recovery exceeded tick budget or failed with 1000 terminal requests' >&2
  exit 1
fi
elapsed_ms=$(( ${EPOCHREALTIME/./} / 1000 - start_ms ))
grep -Fxq 'started=2 errors=0' "$test_env_root/recover.log" || { cat "$test_env_root/recover.log"; exit 1; }
printf 'zf-land-direct-main-%020d\n' 1002 1001 > "$test_env_root/expected"
cmp "$test_env_root/expected" "$RECOVERY_START_LOG"
printf 'PASS 1000 terminal requests: due retries start in %s ms\n' "$elapsed_ms"

export ZF_LAND_QUEUE_DIR="$test_env_root/queue"
printf 'zf-land-direct-main-%020d\n' 1002 1001 > "$test_env_root/expected"
: > "$RECOVERY_START_LOG"

# Even a slow interrupted-push recovery cannot starve due retries.
# Load actual functions, substituting only slow network recovery.
: > "$RECOVERY_START_LOG"
export QUEUE_SCRIPT="$queue_script"
export RECOVERY_SLOW_FIFO="$test_env_root/slow-maintenance"
mkfifo "$RECOVERY_SLOW_FIFO"
if timeout 10 bash -c '
  source <(sed '\''/^case "${1:-}" in/,$d'\'' "$QUEUE_SCRIPT")
  SCRIPT_DIR="$(dirname -- "$QUEUE_SCRIPT")"
  queue_recover_direct_pending() { read -r unused < "$RECOVERY_SLOW_FIFO"; }
  queue_recover
' > "$test_env_root/slow.log" 2>&1; then
  echo 'FAIL slow maintenance fixture did not time out' >&2; exit 1
else
  status=$?
  [[ "$status" == 124 ]] || { cat "$test_env_root/slow.log"; exit 1; }
fi
cmp "$test_env_root/expected" "$RECOVERY_START_LOG"
echo 'PASS due retries start before timeout in later maintenance'

# Corrupt/empty historical records report errors without hiding good due work.
printf '{broken\n' > "$ZF_LAND_QUEUE_DIR/requests/00000000000000000001.json"
: > "$ZF_LAND_QUEUE_DIR/requests/00000000000000000002.json"
: > "$RECOVERY_START_LOG"
if timeout 30 bash "$queue_script" recover > "$test_env_root/corrupt.log" 2>&1; then # wall-clock-allow: corrupt history must retain the tick's recovery budget
  echo 'FAIL corrupt history silently succeeded' >&2; exit 1
fi
grep -Fq 'started=2 errors=2' "$test_env_root/corrupt.log"
cmp "$test_env_root/expected" "$RECOVERY_START_LOG"
echo 'PASS corrupt and empty history counted without starving due recovery'

# Unconcluded landed ranges are concluded in place; recovery starts no unit for them.
python3 - "$ZF_LAND_QUEUE_DIR" "$test_env_root" <<'RANGES'
import json, pathlib, sys
queue, tmp = map(pathlib.Path, sys.argv[1:])
for i in [1, 2]:
    (queue / 'requests' / f'{i:020}.json').unlink()
for i in [1001, 1002, 1003]:
    (queue / 'requests' / f'{i:020}.json').unlink(missing_ok=True)
for i in range(2000, 2300):
    row = {'ticket': f'{i:020}', 'state': 'landed', 'hand_owner_handoff': 'done',
           'owner': 'hand-cohort', 'worktree': str(tmp / 'wt'), 'report': str(tmp / 'report'),
           'plan_package': 'land-recovery'}
    (queue / 'requests' / f'{i:020}.json').write_text(json.dumps(row))
RANGES
: > "$RECOVERY_START_LOG"
timeout 30 bash "$queue_script" recover > "$test_env_root/landed.log" 2>&1 || { # wall-clock-allow: regression for the observed 30-second live tick timeout
  cat "$test_env_root/landed.log"; echo 'FAIL range-less landed history exceeds tick budget'; exit 1
}
grep -Fxq 'started=0 errors=0' "$test_env_root/landed.log"
[[ ! -s "$RECOVERY_START_LOG" ]] || { echo 'FAIL recovery started a unit for landed history'; exit 1; }
for phase in scan retries verifiers running direct conclusions owners complete; do
  grep -Fq "stage=$phase" "$test_env_root/landed.log" || { echo "FAIL missing progress $phase"; exit 1; }
done
printf 'PASS 300 range-less landed requests start no unit\n'
