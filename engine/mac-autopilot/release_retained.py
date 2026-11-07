"""Release retained: a release that reached production but failed acceptance under FIX-FORWARD.

run-release.sh appends `release-retained: deployed=<sha> tracker=#<n|none> held=[<ticket ids>]` to alerts/events.md
when it keeps the deploy after an acceptance regression. Production changed, but no ticket closed. Only a later
`release-closer` line closes a held ticket, so this line never prefixes `release-closer` and never counts as acceptance.

Rows (provisional bounds, maintainer to confirm): `release.hours_acceptance_failed` is the age of the oldest retained
deploy that still holds a ticket no later release-closer line closed. `release.hours_waiting` counts only batches
not yet deployed, so a batch whose deploy was retained reads 0 there.
"""
import os, re

import release_age

METRIC = "release.hours_acceptance_failed"
CRITERIA = {METRIC: ("release", "hours since the oldest deploy whose acceptance failed and still holds tickets", 24, 72, False)}
MEANING = {METRIC: "已经上线、但验收没过的发布，最早一个还压着未关闭的票，已经过去多少小时；0 表示没有。票由后续发布的验收关闭。"}
SOURCE = {METRIC: "alerts/events.md 的 release-retained 行（held 列表）对照之后的 release-closer 行；不读 release-train.json"}
RETAINED_RE = re.compile(r"^\[(\S+)\] release-retained: deployed=([0-9a-f]{7,40}) tracker=#(\d+|none) held=\[([0-9,\s]*)\]")
CLOSER_RE = re.compile(r"^\[(\S+)\] release-closer: deployed=[0-9a-f]+ closed=\[([0-9,\s]*)\]")


def _ids(text):
    return [int(n) for n in re.findall(r"\d+", text)]


def read(runtime):
    """([(at, sha, held ids)], [(at, closed ids)]) from alerts/events.md, or None when it cannot be read."""
    retained, closed = [], []
    try:
        with open(os.path.join(runtime, "alerts", "events.md"), errors="ignore") as source:
            for raw in source:
                if m := RETAINED_RE.match(raw):
                    if at := release_age._ts(m.group(1)):
                        retained.append((at, m.group(2), _ids(m.group(4))))
                elif m := CLOSER_RE.match(raw):
                    if at := release_age._ts(m.group(1)):
                        closed.append((at, _ids(m.group(2))))
    except OSError:
        return None
    return retained, closed


def held_tickets(retained, closed):
    """{issue: at of its oldest retained deploy} for tickets no later release-closer line closed."""
    held = {}
    for at, _, ids in sorted(retained, key=lambda r: r[0]):
        for issue in ids:
            held.setdefault(issue, at)
    return {i: at for i, at in held.items() if not any(c_at > at and i in c_ids for c_at, c_ids in closed)}


def held_at(runtime):
    """{issue: ISO time of its oldest unresolved retained deploy}; empty when events.md cannot be read."""
    events = read(runtime)
    held = held_tickets(*events) if events else {}
    return {i: at.strftime("%Y-%m-%dT%H:%M:%SZ") for i, at in held.items()}


def collect(metrics, runtime, now, waiting_since=None):
    """Score METRIC (None = no data, 0 = nothing held) and zero release.hours_waiting once the batch was deployed."""
    events = read(runtime)
    if events is None:
        metrics[METRIC] = None
        return
    retained, closed = events
    held = held_tickets(retained, closed)
    metrics[METRIC] = max(0.0, (now - min(held.values())).total_seconds() / 3600) if held else 0.0
    if waiting_since and metrics.get("release.hours_waiting") is not None \
            and any(at >= waiting_since for at, _, _ in retained):
        metrics["release.hours_waiting"] = 0
