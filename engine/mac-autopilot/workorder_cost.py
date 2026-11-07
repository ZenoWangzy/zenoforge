#!/usr/bin/env python3
"""Shared work-order spend standards and lifetime spend calculations."""
from datetime import datetime, timedelta, timezone
import re


UNIT_STANDARDS = {
    "tokens": ("worker tokens per work order", 14_000_000, 28_000_000),
    "worker_minutes": ("worker minutes per work order", 90, 240),
    "rounds": ("request-changes rounds", 2, 5),
    "age_hours": ("hours from entry to merged (open: until now)", 24, 72),
}
UNIT_DONE = ("merged", "landed", "done", "closed")
# Stages the factory cannot progress: waiting on a predecessor, an external decision or the supervisor.
UNIT_HELD = ("blocked-external", "parked", "supervisor-review")


def _ts(value):
    try:
        return datetime.strptime(str(value)[:20], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def unit_spend(rows):
    """Lifetime worker tokens (raw) and minutes per unit key, from the shared cost rows."""
    spend = {}
    for row in rows:
        unit = spend.setdefault(row["unit"], [0, 0.0])
        usage, footer = row["usage"], row["footer_tokens"]
        unit[0] += footer if footer is not None else (usage.raw if usage is not None else 0)
        unit[1] += row["minutes"]
    return spend


def recent_units(rows, since):
    """Unit keys whose worker ran inside the window (a run still going at `since` counts)."""
    return {row["unit"] for row in rows if row["start"] + timedelta(minutes=row["minutes"]) >= since}


def work_orders(units, spend, now, recent=None):
    """Each unit's spend against UNIT_STANDARDS; `over` lists the bug bounds an open unit has passed.

    A held unit (UNIT_HELD) is judged only on spend inside the window: `recent` holds the unit keys
    that ran there, so lifetime spend from before it was held never counts. None skips that rule."""
    out = []
    for unit in units:
        keys = {key for key in (unit.get("id"), str(unit.get("pr") or ""),
                                f"issue-{unit['issue']}" if unit.get("issue") else "") if key}
        keys.add(re.sub(r"^pr-", "", unit.get("id", "")))
        hist = [entry for entry in unit.get("history") or [] if _ts(entry.get("at"))]
        done = next((_ts(entry["at"]) for entry in hist if entry.get("stage") in ("merged", "landed")), None)
        value = {
            "tokens": sum(spend.get(key, [0, 0])[0] for key in keys),
            "worker_minutes": round(sum(spend.get(key, [0, 0])[1] for key in keys)),
            "rounds": sum(1 for entry in hist if entry.get("stage") == "review-request-changes"),
            "age_hours": round(((done or now) - _ts(hist[0]["at"])).total_seconds() / 3600, 1) if hist else None,
        }
        open_unit = unit.get("stage") not in UNIT_DONE
        # Held units age by design, not by defect: a stack child waits on its predecessor
        # (blocked-external), a parked unit on an external decision (stop-loss, supervisor
        # hold, main-red) and a supervisor-review unit on the supervisor. The age bound only
        # judges units the factory could progress; the spend bounds judge a held unit only if
        # it spent inside the window.
        held = unit.get("stage") in UNIT_HELD
        quiet = held and recent is not None and not keys & recent
        over = [key for key, (_, _, bug) in UNIT_STANDARDS.items()
                if open_unit and value[key] is not None and value[key] >= bug
                and not (held and key == "age_hours") and not quiet]
        out.append({"id": unit.get("id"), "stage": unit.get("stage"), **value, "over": over})
    return out
