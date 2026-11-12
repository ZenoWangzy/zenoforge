#!/usr/bin/env bash
# unit_signals.py: per-unit overturned/repair/rereview/reverted signals; missing evidence is null, not pass or fail.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
command -v python3 >/dev/null || { echo "unit_signals.test.sh: python3 is required" >&2; exit 1; }
python3 "$script_dir/unit_signals.test.py" || { echo 'unit_signals.test.sh: signal fixtures failed' >&2; exit 1; }
echo 'ok - unit signal fixtures'
