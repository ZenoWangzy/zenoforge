"""Shared loader for the scheduler unit ledger including retired (terminal) units.

The scheduler retires terminal-stage units out of the hot units.json into
units-archive.json (retire_terminal_units); nothing is ever deleted. Metrics,
dashboards and issue/PR dedupe need that history, so they read both files:
units.json first (its row is the fresher copy when an id briefly exists in
both places), then the archive. Duplicate ids collapse to the live row.
"""
import json
import os

LEDGER_FILES = ("units.json", "units-archive.json")


def load_units(runtime_dir):
    """Runtime dir -> full unit list across the live ledger and the retirement archive."""
    by_id = {}
    for name in LEDGER_FILES:
        try:
            with open(os.path.join(runtime_dir, name), encoding="utf-8") as source:
                units = json.load(source).get("units") or []
        except (OSError, ValueError, AttributeError):
            continue
        for unit in units:
            if isinstance(unit, dict) and unit.get("id"):
                by_id.setdefault(unit["id"], unit)
    return list(by_id.values())
