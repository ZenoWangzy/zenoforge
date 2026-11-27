#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "$BASH_SOURCE")/.." && pwd -P)"
fail() { echo "zf_units.test.sh: $*" >&2; exit 1; }
source_shims="$(cd -- "$(dirname -- "$BASH_SOURCE")" && pwd -P)"
shim_dir="$test_env_root/portable-shim"
golden_dir="$source_shims/golden"
mkdir -p "$shim_dir"
for command_name in systemd-run systemctl journalctl; do
  [[ -x "$source_shims/$command_name" ]] || fail "missing executable shim: $command_name"
  cp "$source_shims/$command_name" "$shim_dir/$command_name"
done
cat > "$shim_dir/zf_units.py" <<'PY'
import json
import os
import pathlib
import sys

command = sys.argv[1]
arguments = sys.argv[2:]
if command != os.environ["ZF_SHIM_EXPECTED_COMMAND"]:
    raise SystemExit(98)
if arguments != json.loads(os.environ["ZF_SHIM_EXPECTED_ARGS"]):
    raise SystemExit(99)
sys.stdout.write(pathlib.Path(os.environ["ZF_SHIM_GOLDEN_FILE"]).read_text())
raise SystemExit(int(os.environ["ZF_SHIM_STATUS"]))
PY
contract_case() {
  local command_name=$1 golden=$2 expected_status=$3 expected_args rc=0
  local actual="$test_env_root/actual.out"
  shift 3
  expected_args="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")"
  ZF_SHIM_EXPECTED_COMMAND="$command_name" ZF_SHIM_EXPECTED_ARGS="$expected_args" ZF_SHIM_GOLDEN_FILE="$golden_dir/$golden" ZF_SHIM_STATUS="$expected_status" "$shim_dir/$command_name" "$@" > "$actual" || rc=$?
  [[ $rc == "$expected_status" ]] || fail "$command_name returned $rc, expected $expected_status"
  cmp -s "$actual" "$golden_dir/$golden" || fail "$command_name output differs from $golden"
}
contract_case systemd-run empty.out 0 --user --unit=zf-contract --collect --quiet -p RuntimeMaxSec=600 -p MemoryMax=512M -p MemorySwapMax=0 -p CPUWeight=1000 -p OOMPolicy=continue -p WorkingDirectory="$test_env_root" -E TOKEN=value -- true
contract_case systemd-run empty.out 7 --user --wait --pipe -- bash -c 'exit 7'
contract_case systemd-run empty.out 0 --user --scope --quiet --unit zf-contract-scope -p CPUWeight=10 -- true
contract_case systemctl active.out 0 --user is-active zf-contract.service
contract_case systemctl inactive.out 3 --user is-active zf-missing.service
contract_case systemctl show.out 0 --user show -p ActiveState -p SubState -p MainPID -p InvocationID -p Result -p ExecMainCode -p ExecMainStatus -p ActiveEnterTimestamp -p LastTriggerUSec --value zf-contract.service
contract_case systemctl list-units.out 0 --user list-units --state=active --no-legend --plain 'zf-*'
contract_case systemctl empty.out 0 --user daemon-reload
contract_case systemctl empty.out 0 --user start zf-contract.service
contract_case systemctl empty.out 0 --user stop zf-contract.service
contract_case systemctl empty.out 0 --user restart zf-contract.service
contract_case systemctl status.out 0 --user status zf-contract.service
contract_case systemctl empty.out 0 --user reset-failed
contract_case systemctl list-timers.out 0 --user list-timers
contract_case systemctl enabled.out 0 --user is-enabled zf-contract.timer
contract_case systemctl empty.out 0 --user enable zf-contract.timer
contract_case systemctl unit.out 0 --user cat zf-contract.timer
contract_case journalctl cat.out 0 --user -u zf-contract.service -n 5 --since @1700000000 -o cat --grep=warning --no-pager
contract_case journalctl short-unix.out 0 --user -u zf-contract.service -n 5 --since @1700000000 -o short-unix --grep=warning --no-pager
contract_case journalctl empty.out 1 -k --since @1700000000
actual="$test_env_root/actual.out"
contract_empty() {
  local rc=0 command_name="$1"
  "$@" > "$actual" || rc=$?
  [[ $rc == 0 ]] || fail "$command_name returned $rc, expected 0"
  cmp -s "$actual" "$source_shims/golden/empty.out" || fail "$command_name output differs from empty golden"
}
unit_name=zf-lifecycle-test
contract_empty "$source_shims/systemd-run" --user --unit "$unit_name" -- python3 -c 'import time; time.sleep(0.5)'
"$source_shims/systemctl" --user is-active "$unit_name.service" > "$actual"
cmp -s "$actual" "$source_shims/golden/active.out" || fail 'started unit is not active'
inactive_rc=0
for attempt in {1..50}; do
  "$source_shims/systemctl" --user is-active "$unit_name.service" > "$actual" || inactive_rc=$?
  [[ $inactive_rc == 3 ]] && break
  inactive_rc=0
  sleep 0.1
done
[[ $inactive_rc == 3 ]] || fail 'finished unit remains active'
cmp -s "$actual" "$source_shims/golden/inactive.out" || fail 'inactive output differs from golden'
fixture_dir="$test_env_root/fixture"
mkdir -p "$fixture_dir"
export ZF_SYSTEMD_UNIT_DIR="$fixture_dir"
cat > "$fixture_dir/zf-contract.service" <<'UNIT'
[Unit]
Description=Contract fixture
UNIT
cat > "$fixture_dir/zenoforge-contract.timer" <<'UNIT'
[Timer]
OnUnitActiveSec=60s
UNIT
cat > "$fixture_dir/zf-contract.timer" <<'UNIT'
[Timer]
OnUnitActiveSec=60s
UNIT
contract_name=zf-contract
contract_empty "$source_shims/systemd-run" --user --unit "$contract_name" -- python3 -c 'import time; time.sleep(3)'
contract_meta="$AGENT_HOME/run/units/$contract_name/meta.json"
python3 - "$contract_meta" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
record = json.loads(path.read_text())
record.update({
    "MainPID": 4701,
    "InvocationID": "6c36fa65e9304a17a1b38e592b090f10",
    "Result": "success",
    "ExecMainCode": "exited",
    "ExecMainStatus": 0,
    "ActiveEnterTimestamp": "Mon 2026-11-02 12:34:56 UTC",
    "LastTriggerUSec": "",
})
path.write_text(json.dumps(record) + "\n")
PY
"$source_shims/systemctl" --user show -p ActiveState -p SubState -p MainPID -p InvocationID -p Result -p ExecMainCode -p ExecMainStatus -p ActiveEnterTimestamp -p LastTriggerUSec --value "$contract_name.service" > "$actual"
cmp -s "$actual" "$source_shims/golden/show.out" || fail 'show output differs from golden'
"$source_shims/systemctl" --user list-units --state=active --no-legend --plain 'zf-*' > "$actual"
cmp -s "$actual" "$source_shims/golden/list-units.out" || fail 'list-units output differs from golden'
"$source_shims/systemctl" --user status "$contract_name.service" > "$actual"
cmp -s "$actual" "$source_shims/golden/status.out" || fail 'status output differs from golden'
(cd "$test_env_root" && "$source_shims/systemctl" --user cat zenoforge-contract.timer) > "$actual"
cmp -s "$actual" "$source_shims/golden/unit.out" || fail 'cat output differs from golden'
ZF_TIMERS=loop "$source_shims/systemctl" --user is-enabled zf-contract.timer > "$actual"
cmp -s "$actual" "$source_shims/golden/enabled.out" || fail 'is-enabled output differs from golden'
ZF_TIMERS=loop "$source_shims/systemctl" --user list-timers > "$actual"
cmp -s "$actual" "$source_shims/golden/list-timers.out" || fail 'list-timers output differs from golden'
log_dir="$AGENT_HOME/logs/units"
mkdir -p "$log_dir"
log_file="$log_dir/$contract_name.log"
printf '%s\n' 'contract output' > "$log_file"
python3 - "$log_file" <<'PY'
import os
import sys

os.utime(sys.argv[1], (1793622896, 1793622896))
PY
"$source_shims/journalctl" --user -u "$contract_name.service" -n 5 --since @1700000000 -o cat --grep=contract --no-pager > "$actual"
cmp -s "$actual" "$source_shims/golden/cat.out" || fail 'journalctl cat output differs from golden'
"$source_shims/journalctl" --user -u "$contract_name.service" -n 5 --since @1700000000 -o short-unix --grep=contract --no-pager > "$actual"
cmp -s "$actual" "$source_shims/golden/short-unix.out" || fail 'journalctl short-unix output differs from golden'
stop_name=zf-stop-test
"$source_shims/systemd-run" --user --unit "$stop_name" -- python3 -c 'import time; time.sleep(5)'
contract_empty "$source_shims/systemctl" --user stop "$stop_name.service"
stop_rc=0
"$source_shims/systemctl" --user is-active "$stop_name.service" > "$actual" || stop_rc=$?
[[ $stop_rc == 3 ]] || fail 'systemctl stop left the unit active'
kernel_rc=0
"$source_shims/journalctl" -k --since @1700000000 > "$actual" || kernel_rc=$?
[[ $kernel_rc == 1 ]] || fail "journalctl -k returned $kernel_rc, expected 1"
cmp -s "$actual" "$source_shims/golden/empty.out" || fail 'journalctl -k produced output'
contract_empty env ZF_TIMERS=loop "$source_shims/systemctl" --user daemon-reload
contract_empty env ZF_TIMERS=loop "$source_shims/systemctl" --user enable zf-contract.timer
contract_empty env ZF_TIMERS=loop "$source_shims/systemctl" --user start zf-contract.timer
contract_empty env ZF_TIMERS=loop "$source_shims/systemctl" --user restart zf-contract.timer
fake_bin="$test_env_root/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/launchctl" <<'LAUNCHCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ZF_LAUNCHCTL_LOG"
LAUNCHCTL
chmod +x "$fake_bin/launchctl"
launchctl_log="$test_env_root/launchctl.log"
contract_empty env "PATH=$fake_bin:$PATH" "ZF_LAUNCHCTL_LOG=$launchctl_log" ZF_TIMERS=launchd "$source_shims/systemctl" --user daemon-reload
grep -Fq 'bootout gui/' "$launchctl_log" || fail 'daemon-reload did not unload generated plists'
grep -Fq 'bootstrap gui/' "$launchctl_log" || fail 'daemon-reload did not load generated plists'
PATH="$fake_bin:$PATH" ZF_LAUNCHCTL_LOG="$launchctl_log" ZF_TIMERS=launchd "$source_shims/systemctl" --user is-enabled zf-contract.timer > "$actual"
cmp -s "$actual" "$source_shims/golden/enabled.out" || fail 'launchd is-enabled output differs from golden'
contract_empty env "PATH=$fake_bin:$PATH" "ZF_LAUNCHCTL_LOG=$launchctl_log" ZF_TIMERS=launchd "$source_shims/systemctl" --user start zf-contract.timer
contract_empty env "PATH=$fake_bin:$PATH" "ZF_LAUNCHCTL_LOG=$launchctl_log" ZF_TIMERS=launchd "$source_shims/systemctl" --user restart zf-contract.timer
grep -Fq 'kickstart gui/' "$launchctl_log" || fail 'timer start did not call launchctl'
grep -Fq 'kickstart -k gui/' "$launchctl_log" || fail 'timer restart did not call launchctl'
scope_rc=0
"$source_shims/systemd-run" --user --scope --unit zf-scope-test -- python3 -c 'raise SystemExit(7)' > "$actual" || scope_rc=$?
[[ $scope_rc == 7 ]] || fail "scope returned $scope_rc, expected 7"
cmp -s "$actual" "$source_shims/golden/empty.out" || fail 'scope output differs from empty golden'
wait_rc=0
"$source_shims/systemd-run" --user --wait --pipe -- python3 -c 'raise SystemExit(7)' > "$actual" || wait_rc=$?
[[ $wait_rc == 7 ]] || fail "wait returned $wait_rc, expected 7"
cmp -s "$actual" "$source_shims/golden/empty.out" || fail 'wait output differs from empty golden'
scope_name=zf-scope-live
"$source_shims/systemd-run" --user --scope --unit "$scope_name" -- python3 -c 'import time; time.sleep(0.5)' &
scope_launcher=$!
scope_list_found=0
for attempt in {1..30}; do
  "$source_shims/systemctl" --user list-units --type=scope --no-legend --plain "$scope_name.scope" > "$actual"
  if grep -Fq "$scope_name.scope" "$actual"; then
    scope_list_found=1
    break
  fi
  sleep 0.02
done
[[ $scope_list_found == 1 ]] || fail 'scope unit is missing from list-units'
wait "$scope_launcher"
runtime_name=zf-runtime-test
contract_empty env ZF_STOP_GRACE_SEC=0.1 "$source_shims/systemd-run" --user --unit "$runtime_name" -p RuntimeMaxSec=0.2s -- python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(5)'
runtime_inactive_rc=0
for attempt in {1..40}; do
  "$source_shims/systemctl" --user is-active "$runtime_name.service" > "$actual" || runtime_inactive_rc=$?
  [[ $runtime_inactive_rc == 3 ]] && break
  runtime_inactive_rc=0
  sleep 0.1
done
[[ $runtime_inactive_rc == 3 ]] || fail 'RuntimeMaxSec did not stop the unit'
runtime_result="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Result"])' "$AGENT_HOME/run/units/$runtime_name/meta.json")"
[[ $runtime_result == timeout ]] || fail "RuntimeMaxSec result was $runtime_result"
monitor_name=zf-monitor-test
marker="$test_env_root/monitor-child-finished"
contract_empty env "ZF_MARKER=$marker" "$source_shims/systemd-run" --user --unit "$monitor_name" -- python3 -c 'import os,pathlib,time; time.sleep(0.3); pathlib.Path(os.environ["ZF_MARKER"]).touch(); time.sleep(0.5)'
monitor_pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["MonitorPID"])' "$AGENT_HOME/run/units/$monitor_name/meta.json")"
[[ "$monitor_pid" =~ ^[1-9][0-9]*$ ]] || fail "monitor PID was $monitor_pid"
kill -9 "$monitor_pid"
for attempt in {1..20}; do
  [[ -e "$marker" ]] && break
  sleep 0.1
done
[[ -e "$marker" ]] || fail 'child stopped with the monitor'
"$source_shims/systemctl" --user is-active "$monitor_name.service" > "$actual"
cmp -s "$actual" "$source_shims/golden/active.out" || fail 'unit became inactive when the monitor was killed'
monitor_inactive_rc=0
for attempt in {1..40}; do
  "$source_shims/systemctl" --user is-active "$monitor_name.service" > "$actual" || monitor_inactive_rc=$?
  [[ $monitor_inactive_rc == 3 ]] && break
  monitor_inactive_rc=0
  sleep 0.1
done
[[ $monitor_inactive_rc == 3 ]] || fail 'unit stayed active after its child exited'
collect_name=zf-collect-test
contract_empty "$source_shims/systemd-run" --user --unit "$collect_name" --collect -- python3 -c 'import time; time.sleep(0.3)'
collect_dir="$AGENT_HOME/run/units/$collect_name"
for attempt in {1..40}; do
  [[ ! -e "$collect_dir" ]] && break
  sleep 0.1
done
[[ ! -e "$collect_dir" ]] || fail '--collect left a finished unit record'
fast_collect=zf-fast-collect-test
contract_empty "$source_shims/systemd-run" --user --unit "$fast_collect" --collect --quiet -p RuntimeMaxSec=600 -p MemoryMax=512M -p MemorySwapMax=0 -p CPUWeight=1000 -p OOMPolicy=continue -p WorkingDirectory="$test_env_root" -E TOKEN=value -- true
for attempt in {1..40}; do
  [[ ! -e "$AGENT_HOME/run/units/$fast_collect" ]] && break
  sleep 0.1
done
[[ ! -e "$AGENT_HOME/run/units/$fast_collect" ]] || fail '--collect left the fast unit record'
contract_empty "$source_shims/systemctl" --user start "$contract_name.service"
contract_empty "$source_shims/systemctl" --user restart "$contract_name.service"
contract_empty "$source_shims/systemctl" --user reset-failed
echo 'zf_units.test.sh: PASS'
