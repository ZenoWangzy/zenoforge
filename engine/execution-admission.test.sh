#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT
python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/execution-admission.test.py"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
poll_harness="$test_env_root/poll-harness"
mkdir -p "$poll_harness/execution-shim"
cp "$script_dir/execution-shim/systemd-run" "$poll_harness/execution-shim/systemd-run"
chmod +x "$poll_harness/execution-shim/systemd-run"
cat > "$poll_harness/execution-admission.py" <<'PY'
import os
import sys

with open(os.environ["SHIM_GUARD_CALLS"], "a", encoding="utf-8") as calls:
    calls.write(" ".join(sys.argv[1:]) + "\n")
sys.exit(75)
PY
cat > "$poll_harness/systemd-run-real" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$SHIM_NATIVE_ARGS"
SH
chmod +x "$poll_harness/systemd-run-real"
poll_shim="$poll_harness/execution-shim/systemd-run"
guard_calls="$poll_harness/guard.calls"
native_args="$poll_harness/native.args"
if env ZF_UNIT_PREFIX=vecta ZF_SYSTEMD_RUN_REAL="$poll_harness/systemd-run-real" \
  SHIM_GUARD_CALLS="$guard_calls" SHIM_NATIVE_ARGS="$native_args" \
  "$poll_shim" --user --unit=vecta-advisor-batch --collect -p RuntimeMaxSec=3600 \
  "$script_dir/run-advisor-batch.sh" --scheduled 123; then
  fresh_rc=0
else
  fresh_rc=$?
fi
if env ZF_UNIT_PREFIX=vecta ZF_SYSTEMD_RUN_REAL="$poll_harness/systemd-run-real" \
  SHIM_GUARD_CALLS="$guard_calls" SHIM_NATIVE_ARGS="$native_args" \
  "$poll_shim" --user --unit=vecta-advisor-batch --collect -p RuntimeMaxSec=3600 \
  "$script_dir/run-advisor-batch.sh" --poll-only --scheduled; then
  poll_rc=0
else
  poll_rc=$?
fi
[[ "$fresh_rc" == 75 ]] || { echo "execution-admission.test.sh: fresh batch should remain admission-gated (rc=$fresh_rc)" >&2; exit 1; }
[[ "$poll_rc" == 0 ]] || { echo "execution-admission.test.sh: poll-only batch must bypass execution admission (rc=$poll_rc)" >&2; exit 1; }
[[ "$(wc -l < "$guard_calls" | tr -d ' ')" == 1 ]] || { echo 'execution-admission.test.sh: poll-only batch entered the execution guard' >&2; exit 1; }
grep -Fxq -- '--poll-only' "$native_args"
! grep -Fxq -- 'run-unit' "$native_args"
echo 'execution-admission.test.sh: advisor batch poll bypass PASS'
