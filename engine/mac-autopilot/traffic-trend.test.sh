#!/usr/bin/env bash
# traffic_trend.py: the dashboard's today history and 14-day daily trend, read from metrics/traffic-<UTC day>.jsonl.
# Fixture: three readable days (one with a trailing blank line, one with a coverage gap), one day whose last line is
# malformed, one missing day. The malformed and missing days drop out and nothing raises.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "traffic-trend.test.sh: $*" >&2; exit 1; }
metrics="$AGENT_HOME/metrics"; mkdir -p "$metrics"
day() { date -u -d "-$1 days" +%Y-%m-%d; }
# one sampler line; $1 rx bytes, $2 tx bytes, $3 coverage JSON
row() { jq -cn --argjson rx "$1" --argjson tx "$2" --argjson cov "$3" \
  '{sampled_epoch:1, gb_per_hour:0.5, daily:{rx_bytes:$rx, tx_bytes:$tx, wire_bytes:($rx+$tx), categories:{}, category_rx_bytes:{models:($rx*0.75), git:($rx*0.25)}, category_tx_bytes:{}, coverage:$cov}}'; }

row 1000000000 100000000 '"full"' > "$metrics/traffic-$(day 0).jsonl"
row 5000000000 1000000000 '"full"' >> "$metrics/traffic-$(day 0).jsonl"
# coverage values below are synthetic: the sampler's real daily coverage schema is not in this repo (PR body, open point).
row 4000000000 1000000000 '{"gaps":1}' > "$metrics/traffic-$(day 1).jsonl"
printf '\n' >> "$metrics/traffic-$(day 1).jsonl"
row 2000000000 500000000 '"full"' > "$metrics/traffic-$(day 4).jsonl"
printf '{"daily":' > "$metrics/traffic-$(day 2).jsonl"

python3 - "$script_dir" "$AGENT_HOME" "$(day 4)" "$(day 1)" "$(day 0)" <<'PY' || fail "traffic_trend readers gave unexpected output"
import sys
sys.path.insert(0, sys.argv[1])
import traffic_trend as t
agent_home, d4, d1, d0 = sys.argv[2:6]

days = t.days(agent_home)
assert [d["day"] for d in days] == [d4, d1, d0], days
assert abs(days[0]["rx_gb"] - 2.0) < 1e-9 and abs(days[0]["tx_gb"] - 0.5) < 1e-9, days[0]
assert abs(days[1]["rx_gb"] - 4.0) < 1e-9 and days[1]["partial"] is True, days[1]
assert abs(days[2]["rx_gb"] - 5.0) < 1e-9 and abs(days[2]["tx_gb"] - 1.0) < 1e-9, days[2]
assert abs(days[2]["category_rx_gb"]["models"] - 3.75) < 1e-9 and days[2]["partial"] is False, days[2]

hist = t.history(agent_home)
assert len(hist) == 2 and hist[0]["gbh"] == 0.5, hist

import os
empty = os.path.join(agent_home, "no-metrics")
assert t.days(empty) == [] and t.history(empty) == []
PY

echo "traffic-trend.test.sh: ok"
