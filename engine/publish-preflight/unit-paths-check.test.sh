#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
trap 'rm -rf -- "$test_env_root"' EXIT
t="$test_env_root/unit-paths"
mkdir -p "$t/base/engine/lib.d" "$t/new/engine/lib.d" "$t/units"
touch "$t/base/engine/launcher.sh" "$t/base/engine/index-helper.sh" "$t/base/engine/kept.sh" "$t/new/engine/kept.sh" "$t/base/engine/local-fallback.sh"
printf '%s\n' \
  "ExecStart=:/bin/bash -c 'exec \"\${e:-%h/.agent/checkout/scripts/agent}/launcher.sh\"'" \
  'ExecStartPre=/bin/bash %h/.agent/engine-live/kept.sh' \
  "ExecStartPost=:/bin/bash -c 'exec node \"\${e:-%h/.agent/checkout/scripts/agent}/bridge.mjs\"'" \
  > "$t/units/a.service"
touch "$t/base/engine/bridge.mjs"
# A unit that runs a host-owned copy does not require the engine file.
echo 'ExecStart=/bin/bash %h/.agent/host-ops/scripts/agent/local-fallback.sh' > "$t/units/b.service"
echo 'h="$(zf_host_ops_file "scripts/agent/index-helper.sh" "${_AGENT_LIB_DIR}/index-helper.sh")"' > "$t/new/engine/lib.d/g.sh"
echo 'local entry_fallback="${ZF_ENGINE_DIR:-$ROOT/engine}/local-exec.py"' >> "$t/new/engine/lib.d/g.sh"
touch "$t/base/engine/local-exec.py"
out=$(bash "$here/unit-paths-check.sh" "$t/base" "$t/new" "$t/units" 2>&1) && { echo "FAIL: expected non-zero"; exit 1; }
grep -q 'unit path: launcher.sh' <<<"$out" && grep -q 'unit path: bridge.mjs' <<<"$out" \
  && grep -q 'host-ops fallback: index-helper.sh' <<<"$out" && grep -q 'host-ops fallback: local-exec.py' <<<"$out" \
  || { echo "FAIL: $out"; exit 1; }
grep -qE 'kept.sh|local-fallback.sh' <<<"$out" && { echo "FAIL: false positive: $out"; exit 1; }
touch "$t/new/engine/launcher.sh" "$t/new/engine/index-helper.sh" "$t/new/engine/bridge.mjs" "$t/new/engine/local-exec.py"
bash "$here/unit-paths-check.sh" "$t/base" "$t/new" "$t/units" >/dev/null || { echo "FAIL: restored build flagged"; exit 1; }
echo "unit-paths-check.test.sh: PASS"
