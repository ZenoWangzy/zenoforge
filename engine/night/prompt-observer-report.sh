#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 -B - "$script_dir" <<'PY'
import hashlib
import json
import os
from decimal import Decimal, InvalidOperation
from pathlib import Path
import re
import sys

night_dir = Path(sys.argv[1])
sys.path.insert(0, str(night_dir.parent / "mac-autopilot"))

import factory_trend
import ledger_history
import roi_rollup
from unit_signals import unit_signals


runtime = os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR")
if not runtime or not ledger_history.live_ledger_readable(runtime):
    print("prompt-observer-report: readable MAC_AUTOPILOT_RUNTIME_DIR units.json is required", file=sys.stderr)
    sys.exit(2)

rate_text = os.environ.get("PROMPT_OBSERVER_SAMPLE_RATE") or "1"
minimum_text = os.environ.get("PROMPT_OBSERVER_MIN_SAMPLES") or "5"
try:
    sample_rate = Decimal(rate_text)
except InvalidOperation:
    sample_rate = Decimal("NaN")
if not sample_rate.is_finite() or not Decimal(0) <= sample_rate <= Decimal(1):
    print("prompt-observer-report: PROMPT_OBSERVER_SAMPLE_RATE must be between 0 and 1", file=sys.stderr)
    sys.exit(64)
if not re.fullmatch(r"[1-9][0-9]*", minimum_text):
    print("prompt-observer-report: PROMPT_OBSERVER_MIN_SAMPLES must be a positive integer", file=sys.stderr)
    sys.exit(64)
minimum = int(minimum_text)

agent_home = os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME") or str(Path.home() / ".zenoforge")
report_path = Path(os.environ.get("PROMPT_OBSERVER_REPORT") or Path(agent_home) / "night/prompt-observer-report.jsonl")
ledger_paths = { (Path(runtime) / name).resolve() for name in ledger_history.LEDGER_FILES }
if report_path.resolve() in ledger_paths:
    print("prompt-observer-report: report path must not overwrite a unit ledger", file=sys.stderr)
    sys.exit(64)

repo = os.environ.get("ZF_REPO_DIR") or str(night_dir.parent.parent)
reverted = roi_rollup._reverted_shas(repo)
groups = {}
finding_groups = {}
threshold = int(sample_rate * (1 << 256))
for unit in ledger_history.load_units(runtime):
    unit_id = unit.get("id")
    if unit.get("stage") not in factory_trend.TERMINAL_UNIT_STAGES or not isinstance(unit_id, str):
        continue
    # Hash sampling keeps the selected cohort stable as new units arrive.
    if int.from_bytes(hashlib.sha256(unit_id.encode()).digest(), "big") >= threshold:
        continue
    result = unit_signals(unit, reverted)
    for finding_group in result.get("disproved_findings", []):
        key = (finding_group["prompt"], finding_group["prompt_version"])
        group = finding_groups.setdefault(key, {"disproved": 0, "total": 0, "unit_ids": set()})
        group["disproved"] += finding_group["disproved"]
        group["total"] += finding_group["total"]
        group["unit_ids"].add(unit_id)
    stage, prompt = result.get("stage"), result.get("prompt")
    if not isinstance(stage, str) or not isinstance(prompt, str) or not prompt:
        continue
    group = groups.setdefault((stage, prompt), {"scores": [], "unit_ids": []})
    signals = result.get("signals", {}).values()
    known = [signal for signal in signals if signal is not None]
    if known:
        # True signals are adverse; nulls are omitted, and each unit contributes one equal-weight score.
        group["scores"].append(1 - sum(known) / len(known))
        group["unit_ids"].append(unit_id)

rows = []
for (stage, prompt), group in sorted(groups.items(), key=lambda item: (item[0][0] or "", item[0][1] or "")):
    row = {"stage": stage, "prompt": prompt, "sample_size": len(group["scores"])}
    if row["sample_size"] < minimum:
        row["status"] = "insufficient-data"
    else:
        row["score"] = sum(group["scores"]) / row["sample_size"]
    row["unit_ids"] = sorted(group["unit_ids"])
    rows.append(row)

for (prompt, prompt_version), group in sorted(finding_groups.items()):
    share = group["disproved"] / group["total"]
    unit_ids = sorted(group["unit_ids"])
    row = {
        "stage": "review",
        "prompt": prompt,
        "prompt_version": prompt_version,
        "sample_size": len(unit_ids),
        "disproved_findings": {"disproved": group["disproved"], "total": group["total"]},
        "disproved_share": share,
        "unit_ids": unit_ids,
    }
    if row["sample_size"] < minimum:
        row["status"] = "insufficient-data"
    else:
        row["score"] = 1 - share
    rows.append(row)

rows.sort(key=lambda row: (row["stage"], row["prompt"], row.get("prompt_version", "")))

content = "".join(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n" for row in rows)
report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(content, encoding="utf-8")
sys.stdout.write(content)
PY
