#!/usr/bin/env python3
"""Shared work-order spend standards and lifetime spend calculations."""
from datetime import datetime, timedelta, timezone
import re


UNIT_STANDARDS = {
    # Fresh tokens (uncached input + output), cache reads excluded. Base: 165 of 816 delivered units
    # with a complete cache split (footer-only runs excluded), 2026-11-07; provisional until usage-capture lands.
    "tokens": ("worker fresh tokens per work order (cache reads excluded)", 600_000, 1_200_000),
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


# Ledger events that put a unit on hold (a predecessor, the supervisor) and the ones that release it.
HOLD_START = ("blocked-on", "supervisor-escalated", "supervisor-budget-park", "supervisor-park")
HOLD_END = ("unblocked", "supervisor-requeue")


def held_hours(unit, end):
    """Hours the unit sat on hold before `end`. A hold with no release event counts only while the
    unit is still in a held stage, so an unknown release event never wipes a unit's age."""
    # Stable sort on time only: a requeue and the next blocked-on can share a second, ledger order decides.
    events = sorted(((_ts(e.get("at")), e.get("stage")) for e in unit.get("history") or [] if _ts(e.get("at"))),
                    key=lambda event: event[0])
    total, start = 0.0, None
    for at, stage in events:
        if stage in HOLD_START and start is None:
            start = at
        elif stage in HOLD_END and start is not None:
            total += max(0.0, (min(at, end) - start).total_seconds())
            start = None
    if start is not None and unit.get("stage") in UNIT_HELD:
        total += max(0.0, (end - start).total_seconds())
    return total / 3600


def unit_spend(rows):
    """Lifetime worker fresh tokens and minutes per unit key. A run without a cache split (legacy
    footer or no usage record) adds no tokens; its minutes still count."""
    spend = {}
    for row in rows:
        unit = spend.setdefault(row["unit"], [0, 0.0])
        usage = row["usage"]
        unit[0] += usage.fresh if usage is not None and usage.fresh is not None else 0
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
            # Time on hold is waiting, not work: 10 of 11 units over the age bound on 2026-11-07 had
            # spent 71 to 430 h blocked or escalated and were judged the moment they were released.
            "age_hours": round(max(0.0, ((done or now) - _ts(hist[0]["at"])).total_seconds() / 3600
                                   - held_hours(unit, done or now)), 1) if hist else None,
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
