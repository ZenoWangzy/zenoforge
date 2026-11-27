#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
base="$test_env_root/browser-lock-health"
runtime="$base/runtime"
mkdir -p "$runtime" "$base/agent"
export AGENT_HOME="$base/agent" ZF_HOME="$base/agent" ZF_CONFIG_ROOT="$base/config/.zenoforge"
export MAC_AUTOPILOT_RUNTIME_DIR="$runtime" WEB_SESSION_LEASE_FILE="$base/browser.lock"
export ZF_CDP_BROWSER_LEASE_METRICS_FILE="$runtime/proof-browser-runs.jsonl" PYTHONPATH="$script_dir"
mkdir -p "$ZF_CONFIG_ROOT/mac-autopilot"
proof="$base/proof.json"
flock -x "$WEB_SESSION_LEASE_FILE" sleep 1 &
holder="$!"
sleep 0.05
if "$engine_dir/cdp-browser-lease.sh" --nonblocking true >/dev/null 2>&1; then
  echo 'nonblocking lease unexpectedly acquired while held' >&2
  exit 1
else
  busy_status="$?"
  [[ "$busy_status" -eq 75 ]] || { printf 'nonblocking lease exit=%s, want 75\n' "$busy_status" >&2; exit 1; }
fi
"$engine_dir/cdp-browser-lease.sh" -- python3 -c 'import json,sys,time; time.sleep(.1); json.dump({"source_sha":"sample","features":[]},open(sys.argv[1],"w"))' "$proof" --json "$proof"
wait "$holder"
jq -e '.source_sha == "sample" and .lock_wait_ms >= 100 and .run_ms >= 80' "$proof" >/dev/null
jq -e 'type == "object" and .lock_wait_ms >= 100 and .run_ms >= 80' "$ZF_CDP_BROWSER_LEASE_METRICS_FILE" >/dev/null
jq -se 'length == 1' "$ZF_CDP_BROWSER_LEASE_METRICS_FILE" >/dev/null
python3 - "$base" <<'PY'
import json, os, sys
root = sys.argv[1]
for name, waits in (("long", [6000] * 20), ("none", [0] * 20), ("small", [6000] * 3)):
    folder = os.path.join(root, name)
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "proof-browser-runs.jsonl"), "w") as out:
        for wait in waits:
            out.write(json.dumps({"completed_at": "2026-11-27T11:30:00Z", "lock_wait_ms": wait, "run_ms": 250}) + "\n")
PY
small_output=""
for name in long none small; do
  folder="$base/$name"
  result="$folder/node-health.json"
  output="$(ZF_CDP_BROWSER_LEASE_METRICS_FILE="$folder/proof-browser-runs.jsonl" MAC_AUTOPILOT_RUNTIME_DIR="$folder" python3 "$script_dir/node_health.py" --runtime "$folder" --audit "$base/audit.jsonl" --hours 5 --now 2026-11-27T12:00:00Z --json "$result" 2>&1)"
  [[ -n "$output" ]] || { echo "node_health.py printed no scorecard for $name" >&2; exit 1; }
  [[ "$name" != small ]] || small_output="$output"
done
jq -e '[.metrics[] | select(.id | startswith("delivery.proof_browser_")) | .status] | length == 3 and all(. == "UNHEALTHY")' "$base/long/node-health.json" >/dev/null
jq -e '[.metrics[] | select(.id | startswith("delivery.proof_browser_")) | .status] | length == 3 and all(. == "OK")' "$base/none/node-health.json" >/dev/null
jq -e '[.metrics[] | select(.id | startswith("delivery.proof_browser_")) | .status] | length == 3 and all(. == "LOW-N")' "$base/small/node-health.json" >/dev/null
[[ "$small_output" == *"LOW-N"* ]]
echo 'proof-browser-health.test.sh: PASS'
