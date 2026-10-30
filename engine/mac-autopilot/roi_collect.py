#!/usr/bin/env python3
"""Collect finished unit-loop worker logs into the shared append-only ROI ledger."""
import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path

import roi_ledger
import usage_reader
import worker_cost


PROVIDERS = {"codex": "openai", "claude": "anthropic", "zcode": "z.ai"}


def _iso(value):
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _claude_usage(row, responses):
    start = row["start"]
    end = row.get("finished_at") or row["end"]
    total = usage_reader.Usage(0, 0, 0)
    for stamp, usage in responses:
        try:
            at = datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone(timezone.utc)
        except (AttributeError, ValueError):
            continue
        if start <= at <= end:
            total += usage
    return total if total.raw else None


def _units(runtime):
    try:
        with open(os.path.join(runtime, "units.json"), encoding="utf-8") as source:
            values = json.load(source).get("units") or []
    except (OSError, ValueError, AttributeError):
        values = []
    return {row.get("id"): row for row in values if isinstance(row, dict) and row.get("id")}


def _worker_event(row, units_by_id, host):
    ticket = worker_cost.ticket_of(row["unit"], units_by_id)
    tickets = [ticket] if isinstance(ticket, int) and ticket > 0 else []
    usage = row["usage"]
    footer = row["footer_tokens"]
    end = row.get("finished_at") or row["end"]
    model = row["model"] or None
    model_row = {
        "model": model,
        "provider": PROVIDERS.get(row["backend"]),
        "calls": 1,
        "input": usage.input if usage is not None else None,
        "cached": usage.cached if usage is not None else None,
        "cache_write": usage.cache_write if usage is not None else None,
        "output": usage.output if usage is not None else None,
        "reasoning": usage.reasoning if usage is not None else None,
        "tokens": usage.raw if usage is not None else footer,
        "source": row.get("usage_source") or (
            "worker-log" if usage is not None else ("codex-footer" if footer is not None else "missing")
        ),
        "complete": usage is not None and usage.cached is not None,
    }
    unit = {"family": "unit-loop", "stage": row["phase"], "key": row["unit"]}
    if row["backend"]:
        unit["backend"] = row["backend"]
    event_id = f"{host}:unit-loop:{row['log']}:unit-end"
    return {
        "schema_version": 1,
        "record_type": "event",
        "event_type": "unit-end",
        "event_id": event_id,
        "ts": _iso(end),
        "start_ts": _iso(row["start"]),
        "wall_s": round(max(0, (end - row["start"]).total_seconds()), 3),
        "host": host,
        "unit": unit,
        "tickets": tickets,
        "models": [model_row],
    }


def collect(home, supervisor=None, runtime=None):
    home = os.path.abspath(home)
    supervisor = supervisor or os.environ.get("MAC_AUTOPILOT_SUPERVISOR_DIR") \
        or os.path.join(home, "checkout", ".scratch-supervisor")
    runtime = runtime or os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR") or os.path.join(supervisor, "autopi")
    host = os.environ.get("ZF_HOST_ID") or "origin-wsl"
    units_by_id = _units(runtime)
    rows = worker_cost.run_rows(supervisor, finished_only=True)
    projects_root = os.environ.get("CLAUDE_PROJECTS_DIR") or os.path.expanduser("~/.claude/projects")
    clone_root = os.environ.get("MAC_AUTOPILOT_WT_ROOT") or os.path.join(home, "autopilot-wt")
    claude_responses = {}
    if os.path.isdir(projects_root):
        for row in rows:
            if row["backend"] != "claude" or row["usage"] is not None:
                continue
            unit = row["unit"]
            if unit not in claude_responses:
                try:
                    claude_responses[unit] = usage_reader.claude_unit_responses(projects_root, clone_root, unit)
                except usage_reader.Unavailable:
                    claude_responses[unit] = []
            row["usage"] = _claude_usage(row, claude_responses[unit])
            if row["usage"] is not None:
                row["usage_source"] = "claude-project"
    events = [_worker_event(row, units_by_id, host) for row in rows]
    result = roi_ledger.append_rows(home, events)
    return {"source_rows": len(rows), **result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", default=os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME")
                        or os.path.expanduser("~/.zenoforge"))
    parser.add_argument("--supervisor")
    parser.add_argument("--runtime")
    args = parser.parse_args()
    result = collect(args.home, args.supervisor, args.runtime)
    print("roi_collect: " + " ".join(f"{key}={value}" for key, value in result.items()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
