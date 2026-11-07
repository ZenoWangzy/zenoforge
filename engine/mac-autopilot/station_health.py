#!/usr/bin/env python3
"""Per-station health: throughput, idle and stall time, from local files only (stateless, no gh calls).

A station is stalled when work waits in its named input buffer and nothing has left it for longer than its
bound; a paused pipeline reports PAUSED and raises nothing. Intake that took nothing on purpose (target met, marker
`intake-held-since`) reports HELD, not STALLED, until the hold is 2 x its bound old. See "Stations" in NODE-HEALTH.md.
"""
import argparse, glob, json, os, re
from datetime import datetime, timedelta, timezone

import ledger_history
from node_health import pct, ts

STATIONS = ("intake", "triage", "advisor", "implement", "review", "repair", "merge", "ci", "release")
# Minutes without an out event, while work waits, before a station is STALLED: 2 x the p90 gap between out events,
# rounded up to 10 (NODE-HEALTH.md "Stations" has the measured gaps). Runtime config `station_health.stall_minutes` overrides.
DEFAULT_STALL_MINUTES = {"intake": 90, "triage": 360, "advisor": 810, "implement": 60, "review": 60, "repair": 90,
                         "merge": 150, "ci": 100, "release": 950}
UNIT_BUFFER = {"implement-pending": "implement", "review-pending": "review", "rereview-pending": "review",
               "repair-pending": "repair", "ready-to-merge": "merge"}
STATE_BUFFER = {"needs-triage": "triage", "needs-advisor": "advisor"}
UNIT_OUT = {"review-approve": "review", "review-request-changes": "review", "review-block": "review",
            "merged": "merge", "landed": "merge", "ci-ready": "ci", "ci-wip-start": "ci",
            "hold-handoff": "intake"}  # a handoff re-enters an existing unit: its first row was the original intake
# `release-closer: deployed=<sha, any length> closed=[issue, ...]`, one out per closed issue.
RELEASE_RE = re.compile(r"^\[(\S+)\] release-closer: deployed=[0-9a-f]+ closed=\[([0-9,\s]*)\]")
WORK_OUT = {"implement": "implement", "repair": "repair"}
# The live line is `dispatch claim=owned issue=N mode=.. reason=.. pid=P type=T unit=U`; older logs had no claim/issue/reason.
DISPATCH_RE = re.compile(r"^\[(\S+)\] dispatch .*?\btype=(review|rereview)\b.*?\bunit=(\S+)")


def minutes(a, b):
    return (a - b).total_seconds() / 60


def history(unit):
    rows = [(ts(h.get("at")), h) for h in unit.get("history") or [] if isinstance(h, dict) and h.get("stage")]
    return sorted(((t, h) for t, h in rows if t), key=lambda r: r[0])


def read_states(agent_home):
    for path in glob.glob(os.path.join(agent_home, "state", "*.json")):
        try:
            with open(path) as source:
                state = json.load(source)
        except (OSError, ValueError):
            continue
        if isinstance(state, dict) and os.path.basename(path)[:-5].isdigit():
            yield int(os.path.basename(path)[:-5]), state


def waiting(units, states):
    """station -> list of times each waiting item entered its buffer (None when unknown)."""
    out = {s: [] for s in STATIONS}
    has_unit = set()
    for u in units:
        m = re.fullmatch(r"issue-(\d+)", str(u.get("id")))
        has_unit |= {int(m.group(1))} if m else set()
        has_unit |= {u["issue"]} if isinstance(u.get("issue"), int) else set()
        rows = history(u)
        entered = rows[-1][0] if rows else None
        if u.get("ci_wip_wait") and u.get("stage") == "ready-to-merge":
            out["ci"].append(entered)  # a unit waiting for a CI slot is the CI buffer, not the merge buffer
        elif u.get("stage") in UNIT_BUFFER:
            out[UNIT_BUFFER[u["stage"]]].append(entered)
    for n, st in states:
        kind = st.get("state")
        if kind in STATE_BUFFER:
            out[STATE_BUFFER[kind]].append(ts(st.get("state_changed_at")))
        elif kind == "awaiting-release" and st.get("deploy_state") != "deployed":
            out["release"].append(ts(st.get("state_changed_at")))
        elif kind == "ready-for-agent" and n not in has_unit:
            out["intake"].append(ts(st.get("state_changed_at")))
    return out


def outs(units, runtime, agent_home):
    """station -> sorted [(time, count)] of items that left the station."""
    ev = {s: [] for s in STATIONS}
    for u in units:
        rows = history(u)
        if rows:
            ev["intake"].append((rows[0][0], 1))
        started = None
        for t, h in rows:
            if h["stage"] == "write-start":
                started = h.get("work_type")
            elif h["stage"] == "write-end" and started in WORK_OUT:
                ev[WORK_OUT[started]].append((t, 1))
            elif h["stage"] in UNIT_OUT:
                ev[UNIT_OUT[h["stage"]]].append((t, 1))
    for path in glob.glob(os.path.join(agent_home, "logs", "triage-triage-batch-*.log")):
        try:
            applied = re.search(r"^applied_count=(\d+)$", open(path, errors="ignore").read(), re.M)
            when = datetime.fromtimestamp(os.path.getmtime(path), timezone.utc)
        except OSError:
            continue
        if applied and int(applied.group(1)):
            ev["triage"].append((when, int(applied.group(1))))
    for path in glob.glob(os.path.join(agent_home, "logs", "advisor-batch-*.result.json")):
        try:
            with open(path) as source:
                r = json.load(source)
        except (OSError, ValueError):
            continue
        if isinstance(r, dict) and r.get("outcome") == "completed" and (ts(r.get("recorded_at")) and r.get("applied_count")):
            ev["advisor"].append((ts(r["recorded_at"]), int(r["applied_count"])))
    for name in ("alerts/events.md", "scheduler.log"):
        try:
            for raw in open(os.path.join(runtime, name), errors="ignore"):
                m = RELEASE_RE.match(raw)
                if m and ts(m.group(1)) and (n := len(re.findall(r"\d+", m.group(2)))):
                    ev["release"].append((ts(m.group(1)), n))
        except OSError:
            continue
    return {s: sorted(v, key=lambda x: x[0]) for s, v in ev.items()}


def admission_gaps(units, runtime, since):
    """Minutes an item sat before a worker took it: the history entry before write-start / ci-ready, and for review
    the latest entry before the dispatch line in scheduler.log. Review had no start event before this."""
    gaps = {"implement": [], "repair": [], "ci": [], "review": []}
    by_unit = {}
    for u in units:
        rows = history(u)
        by_unit[u.get("id")] = rows
        for i, (t, h) in enumerate(rows):
            if i and t >= since and h["stage"] == "write-start" and h.get("work_type") in WORK_OUT:
                gaps[WORK_OUT[h["work_type"]]].append(minutes(t, rows[i - 1][0]))
            elif i and t >= since and h["stage"] == "ci-ready":
                gaps["ci"].append(minutes(t, rows[i - 1][0]))
    try:
        lines = open(os.path.join(runtime, "scheduler.log"), errors="ignore")
    except OSError:
        lines = []
    for raw in lines:
        m = DISPATCH_RE.match(raw)
        t = m and ts(m.group(1))
        if not t or t < since:
            continue
        before = [x for x, _ in by_unit.get(m.group(3), []) if x <= t]
        if before:
            gaps["review"].append(minutes(t, before[-1]))
    return {k: {"n": len(v), "p50": pct(v, .5), "p90": pct(v, .9)} for k, v in gaps.items()}


def station_rows(wait, ev, now, bounds, paused, held_since=None):
    rows = {}
    for s in STATIONS:
        times = wait[s]
        known = [t for t in times if t]
        oldest = max((minutes(now, t) for t in known), default=None)
        events = ev[s]
        last = events[-1][0] if events else None
        count = lambda h: sum(c for t, c in events if t >= now - timedelta(hours=h))
        # Idle time before the oldest waiting item arrived is not a stall: cap by that item's wait.
        stall = 0.0
        if times:
            stall = min(minutes(now, last) if last else float("inf"), oldest if oldest is not None else float("inf"))
            stall = 0.0 if stall == float("inf") else max(stall, 0.0)
        status = "PAUSED" if paused else "STALLED" if times and stall > bounds[s] else "OK"
        # Held is measured from the hold's start, so a long hold cannot hide a real stop.
        if s == "intake" and status == "STALLED" and held_since and minutes(now, held_since) < 2 * bounds[s]:
            status = "HELD"
        rows[s] = {"waiting": len(times), "oldest_wait_min": None if oldest is None else round(oldest, 1),
                   "out_1h": count(1), "out_24h": count(24),
                   "last_out": last.strftime("%Y-%m-%dT%H:%M:%SZ") if last else None,
                   "stall_min": round(stall, 1), "stall_bound_min": bounds[s], "status": status}
    return rows


def render(doc):
    head = f"STATIONS {doc['at']} {'PAUSED' if doc['paused'] else ''}".rstrip()
    lines = [head, f"{'station':<10}{'status':<9}{'wait':>5}{'oldest':>8}{'out1h':>6}{'out24h':>7}{'stall':>8}{'bound':>7}  last-out"]
    for s, r in doc["stations"].items():
        old = "-" if r["oldest_wait_min"] is None else f"{r['oldest_wait_min']:.0f}m"
        lines.append(f"{s:<10}{r['status']:<9}{r['waiting']:>5}{old:>8}{r['out_1h']:>6}{r['out_24h']:>7}"
                     f"{r['stall_min']:>7.0f}m{r['stall_bound_min']:>6}m  {r['last_out'] or '-'}")
    lines.append("admission gap before a worker takes the item, minutes (24h): " + "; ".join(
        f"{k} n={g['n']} p50={'-' if g['p50'] is None else round(g['p50'], 1)} p90={'-' if g['p90'] is None else round(g['p90'], 1)}"
        for k, g in doc["admission_gaps"].items()))
    return "\n".join(lines) + "\n"


def alert(runtime, doc, now):
    stalled = [s for s, r in doc["stations"].items() if r["status"] == "STALLED"]
    path = os.path.join(runtime, "alerts", "node-health.md")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    hour = f"[{now:%Y-%m-%dT%H}"
    try:
        seen = [l for l in open(path, errors="ignore") if l.startswith(hour)]
    except OSError:
        seen = []
    with open(path, "a") as out:
        for s in stalled:
            if any(f"STATION-STALLED station={s} " in l for l in seen):
                continue
            r = doc["stations"][s]
            out.write(f"[{now:%Y-%m-%dT%H:%M:%SZ}] STATION-STALLED station={s} waiting={r['waiting']} stall-min={r['stall_min']:.0f} "
                      f"bound-min={r['stall_bound_min']} last-out={r['last_out'] or 'never'} (see NODE-HEALTH.md Stations)\n")


def main():
    agent_home = os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME") or os.path.expanduser("~/.zenoforge")
    ap = argparse.ArgumentParser()
    ap.add_argument("--runtime", required=True)
    ap.add_argument("--agent-home", default=agent_home)
    ap.add_argument("--pause-file", default=os.environ.get("AUTOPILOT_PAUSE_FILE") or os.path.join(agent_home, "PAUSE"))
    ap.add_argument("--now")
    ap.add_argument("--alert", action="store_true")
    args = ap.parse_args()
    now = ts(args.now) if args.now else datetime.now(timezone.utc)
    try:
        cfg = json.load(open(os.path.join(args.runtime, "config.json"))).get("station_health") or {}
    except (OSError, ValueError, AttributeError):
        cfg = {}
    bounds = dict(DEFAULT_STALL_MINUTES)
    bounds.update({k: v for k, v in (cfg.get("stall_minutes") or {}).items() if k in bounds and isinstance(v, (int, float))})
    units = ledger_history.load_units(args.runtime)
    try:
        held_since = ts(open(os.path.join(args.runtime, "intake-held-since")).read().strip())
    except OSError:
        held_since = None
    paused = os.path.exists(args.pause_file)
    doc = {"at": f"{now:%Y-%m-%dT%H:%M:%SZ}", "paused": paused,
           "stations": station_rows(waiting(units, list(read_states(args.agent_home))), outs(units, args.runtime, args.agent_home),
                                    now, bounds, paused, held_since),
           "admission_gaps": admission_gaps(units, args.runtime, now - timedelta(hours=24))}
    for name, body in (("station-health.json", json.dumps(doc, ensure_ascii=False)), ("station-health.txt", render(doc))):
        tmp = os.path.join(args.runtime, name + ".tmp")
        with open(tmp, "w") as out:
            out.write(body)
        os.replace(tmp, os.path.join(args.runtime, name))
    if args.alert and not paused:
        alert(args.runtime, doc, now)


if __name__ == "__main__":
    main()
