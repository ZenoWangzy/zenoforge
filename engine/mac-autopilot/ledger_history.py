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


def _read_dict(path):
    try:
        value = json.load(open(path))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def closed_units_open_issues(runtime, agent_home, units):
    """Issue ids intake's terminal skip hides: candidates whose units all ended, handoff consumed; None without a census."""
    rows = _read_dict(os.path.join(runtime, "intake-candidates.json")).get("rows")
    if rows is None:
        return None
    ended = ("merged", "landed", "closed", "done", "wontfix", "duplicate")
    found = []
    for row in rows.splitlines():
        n = row.split("\t", 1)[0]
        if not n.isdigit():
            continue
        own = [u for u in units if u.get("issue") == int(n) or u.get("branch") == f"agent/issue-{n}"]
        state = _read_dict(os.path.join(agent_home, "state", f"{n}.json"))
        episode = (state.get("scheduler_handoff") or {}).get("episode") if state.get("state") == "ready-for-agent" else None
        if own and all(u.get("stage") in ended and (not episode or u.get("hold_handoff_episode") == episode) for u in own):
            found.append(int(n))
    return found
