#!/usr/bin/env python3
"""Per-run fresh-token records for the unit ledger (the token spend gate reads them).

A finished worker log becomes one record on its unit (`spend_runs`), measured by the same code the
dashboard uses: worker_cost.measure + attach_provider_usage give the row, workorder_cost.unit_spend
turns it into fresh tokens. The gate's lifetime sum and `workorders` tokens therefore agree.

  spend_ledger.py sweep <supervisor-dir> <units.json> [limit]
      JSON lines {"unit": id, "run": {...}} for finished logs not yet recorded, at most `limit`.
"""
import glob
import json
import os
import sys

import worker_cost
import workorder_cost


def phase_of(row):
    return "self-fix" if row["self_fix"] else row["phase"]


def new_runs(sup, units, limit=25):
    """(unit id, record) for finished logs no unit carries yet, oldest first, at most `limit`. A log whose unit is not in
    the ledger is skipped before it is read, so it costs nothing per tick. Baselines chain over every log of the units that
    have something to record, recorded ones included and in start order: a resumed run takes its predecessor's counters
    from the previous log, whichever tick recorded that one."""
    seen = {r.get("log") for u in units for r in u.get("spend_runs") or [] if isinstance(r, dict)}
    index = worker_cost.units_index(units)
    by_log = worker_cost._read_workers(sup)
    logs = []
    for path in glob.glob(os.path.join(sup, "*.worker.log")):
        name = os.path.basename(path)
        worker = by_log.get(name)
        match = worker_cost.LOG_RE.match(name)
        if not match or (worker is not None and worker.get("harvested") is not True):
            continue  # not a worker log, or a worker still running
        key = (worker or {}).get("unit") or worker_cost.UNIT_KEY_RE.sub("", match.group(2))
        if key in index or f"pr-{key}" in index:
            logs.append((path, name, worker, key))
    open_keys = {key for _, name, _, key in logs if name not in seen}
    rows = [worker_cost.measure(path, worker) for path, _, worker, key in logs if key in open_keys]
    rows = [row for row in rows if row is not None]
    rows.sort(key=lambda row: row["start"])
    worker_cost._chain_baselines(rows)
    rows = [row for row in rows if row["log"] not in seen][:limit]
    if rows:
        worker_cost.attach_provider_usage(rows, units)
    out = []
    for row in rows:
        unit = index.get(row["unit"]) or index[f"pr-{row['unit']}"]
        out.append((unit["id"], {
            "log": row["log"], "start": row["start"].strftime("%Y-%m-%dT%H:%M:%SZ"), "phase": phase_of(row),
            "backend": row["backend"] or "unknown", "minutes": round(row["minutes"], 1),
            # unit_spend is the dashboard's own function: a run with no cache split adds 0 there and here.
            "fresh_tokens": workorder_cost.unit_spend([row])[row["unit"]][0],
            # raw = input + output, the dashboard's raw column; None when the run's usage cannot be read
            "raw_tokens": row["usage"].raw if row["usage"] is not None else None}))
    return out


def main(argv):
    if len(argv) >= 3 and argv[0] == "sweep":
        with open(argv[2], encoding="utf-8") as source:
            units = json.load(source).get("units") or []
        for unit, run in new_runs(argv[1], units, int(argv[3]) if len(argv) > 3 else 25):
            print(json.dumps({"unit": unit, "run": run}, separators=(",", ":")))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
