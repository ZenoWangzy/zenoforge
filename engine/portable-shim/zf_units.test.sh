#!/usr/bin/env bash
set -euo pipefail
engine="$(cd -- "$(dirname -- "$BASH_SOURCE")/.." && pwd -P)"
source "$engine/test-env.sh"
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
echo 'zf_units.test.sh: PASS'
