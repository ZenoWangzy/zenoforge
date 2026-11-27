#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
unset ZF_CDP_BROWSER_LEASE_METRICS_FILE
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
grep -Fq "python3 engine/mac-autopilot/proof_browser_run.py --json <proof-path> -- node scripts/e2e/yangfeng-regression/verify-feature.mjs" "$script_dir/scheduler.d/dispatch-queue.sh"
base="$test_env_root/proof-browser-health"
runtime="$base/runtime"
mkdir -p "$base/bin" "$runtime" "$base/agent"
export AGENT_HOME="$base/agent" ZF_HOME="$base/agent" ZF_CONFIG_ROOT="$base/config/.zenoforge"
export MAC_AUTOPILOT_RUNTIME_DIR="$runtime" ZF_CDP_BROWSER_LEASE_SCRIPT="$base/bin/lease"
export FAKE_LEASE_WAIT_SECONDS=0.12 PYTHONPATH="$script_dir"
cat > "$ZF_CDP_BROWSER_LEASE_SCRIPT" <<'LEASE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -- ]] || exit 64
shift
sleep "${FAKE_LEASE_WAIT_SECONDS:-0.12}"
exec "$@"
LEASE
chmod +x "$ZF_CDP_BROWSER_LEASE_SCRIPT"
proof="$base/proof.json"
python3 "$script_dir/proof_browser_run.py" --json "$proof" -- python3 -c 'import json,sys,time; time.sleep(.12); json.dump({"source_sha":"sample","features":[]}, open(sys.argv[1], "w"))' "$proof"
python3 - "$proof" "$runtime/proof-browser-runs.jsonl" <<'PY'
import json
import sys
from pathlib import Path

proof = json.loads(Path(sys.argv[1]).read_text())
records = [json.loads(line) for line in Path(sys.argv[2]).read_text().splitlines()]
assert proof["source_sha"] == "sample"
assert proof["lock_wait_ms"] >= 80
assert proof["run_ms"] >= 80
assert len(records) == 1
assert records[0]["lock_wait_ms"] == proof["lock_wait_ms"]
assert records[0]["run_ms"] == proof["run_ms"]
PY
mkdir -p "$base/bin"
cat > "$base/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '[]\n'
GH
chmod +x "$base/bin/gh"
python3 - "$base" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
for name, wait, count in (("long", 6000, 20), ("none", 0, 20), ("small", 6000, 3)):
    folder = root / name
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / "proof-browser-runs.jsonl").open("w", encoding="utf-8") as output:
        for _ in range(count):
            output.write(json.dumps({"completed_at": "2026-11-27T11:30:00Z",
                                     "lock_wait_ms": wait, "run_ms": 250}) + "\n")
PY
python3 - "$base/long" <<'PY'
import sys
from datetime import datetime, timezone
import proof_browser_health

now = datetime(2026, 11, 27, 12, tzinfo=timezone.utc)
values = proof_browser_health.collect(sys.argv[1], sys.argv[1], now.replace(hour=0), now)
assert values[proof_browser_health.LOCK_WAIT_P50] == 6000
assert values[proof_browser_health.LOCK_WAIT_P90] == 6000
assert values[proof_browser_health.WAIT_OVER_THRESHOLD] == 100
PY
small_output=""
for name in long none small; do
  folder="$base/$name"
  output="$(PATH="$base/bin:$PATH" ZF_REPO=example/repo MAC_AUTOPILOT_RUNTIME_DIR="$folder" \
    python3 "$script_dir/node_health.py" --runtime "$folder" --audit "$base/audit.jsonl" \
      --hours 5 --now 2026-11-27T12:00:00Z --json "$folder/node-health.json" 2>&1)"
  [[ -n "$output" ]] || { printf 'node_health.py printed no scorecard for %s\n' "$name" >&2; exit 1; }
  [[ "$name" != small ]] || small_output="$output"
done
jq -e '[.metrics[] | select(.id | startswith("delivery.proof_browser_")) | .status] | length == 3 and all(. == "UNHEALTHY")' "$base/long/node-health.json" >/dev/null
jq -e '[.metrics[] | select(.id | startswith("delivery.proof_browser_")) | .status] | length == 3 and all(. == "OK")' "$base/none/node-health.json" >/dev/null
jq -e '[.metrics[] | select(.id | startswith("delivery.proof_browser_")) | .status] | length == 3 and all(. == "LOW-N")' "$base/small/node-health.json" >/dev/null
jq -e '[.metrics[] | select(.id | startswith("delivery.proof_browser_")) | .sample_n] | length == 3 and all(. == 3)' "$base/small/node-health.json" >/dev/null
[[ "$small_output" == *"LOW-N"* ]]
echo 'proof-browser-health.test.sh: PASS'
