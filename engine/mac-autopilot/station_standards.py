#!/usr/bin/env python3
"""Station standards: time, tokens and throughput for every station (NODE-HEALTH.md "Station standards").

Pure over data the caller already read (units, worker runs, station out events); no gh call. node_health.main()
calls collect() each tick. Every bound in CRITERIA is measured from live data: its window and sample count are in
NODE-HEALTH.md. A dimension a station cannot be measured on is listed in EXCEPTIONS with its reason, never faked.
"""
import glob, os, re
from datetime import datetime, timedelta, timezone

STATIONS = ("intake", "triage", "advisor", "implement", "review", "repair", "merge", "ci", "release")
WINDOW_HOURS = 24
TRIAGE_LOG_RE = re.compile(r"^(tokens_used|issue_sample_size)=(\d+)$", re.M)
# Gap events: the time from the unit's previous ledger event to this one (the same admission gap station_health uses).
GAP_EVENTS = {"merge": ("merged", "landed"), "ci": ("ci-ready",)}
RUN_NODE = {"implement": "implement", "review": "review", "repair": "repair"}
NO_MODEL = "no model call in its script (grep of the station script finds none), so no token count exists"

# station -> dimension -> metric id (CRITERIA) or None when EXCEPTIONS explains why.
MATRIX = {
    "intake":    {"time": None, "tokens": None, "throughput": "intake.out_per_day"},
    "triage":    {"time": None, "tokens": "triage.tokens_per_issue_p50", "throughput": "triage.out_per_day"},
    "advisor":   {"time": "advisor.last_answer_age_hours", "tokens": None, "throughput": "advisor.out_per_day"},
    "implement": {"time": "implement.wall_p50", "tokens": "implement.tokens_p50", "throughput": "implement.out_per_day"},
    "review":    {"time": "review.wall_p50", "tokens": "review.tokens_p50", "throughput": "review.out_per_day"},
    "repair":    {"time": "repair.wall_p50", "tokens": "repair.tokens_p50", "throughput": "repair.out_per_day"},
    "merge":     {"time": "merge.wait_p50_min", "tokens": None, "throughput": "flow.merge_rate_per_hour"},
    "ci":        {"time": "ci.admission_p50_min", "tokens": None, "throughput": "ci.out_per_day"},
    "release":   {"time": "release.hours_waiting", "tokens": None, "throughput": None},
}
# Pipeline steps that no station covers (the node map). Each cell is a metric in CRITERIA or a documented exception.
PIPELINE = {
    "approve": {"time": "ci.approve_to_ship_p50", "tokens": None, "throughput": "approve.out_per_day"},
    "rereview": {"time": "rereview.wall_p50", "tokens": "rereview.tokens_p50", "throughput": "rereview.runs_per_day"},
    "pr_ci": {"time": None, "tokens": None, "throughput": None},
    "postsubmit": {"time": "delivery.oldest_merged_not_live_hours", "tokens": None, "throughput": None},
}
EXCEPTIONS = {
    ("release", "throughput"): "points at release.hours_since_release (release-age branch, #635, not merged here): release cadence is scored there, with no separate bound in this file",
    ("pr_ci", "time"): "not measured by node_health: the CI run wall time needs the GitHub Actions run API (a gh call), which this tick does not make; NODE-HEALTH holds only a hand measurement from 2026-10-20",
    ("pr_ci", "throughput"): "not measured: no local record counts CI runs; ci.out_per_day counts the station's admissions, not completed runs",
    ("pr_ci", "tokens"): NO_MODEL + " (PR CI workflow)",
    ("postsubmit", "throughput"): "not measured: no local record counts Postsubmit runs on main; main merges are counted by flow.merge_rate_per_hour",
    ("postsubmit", "tokens"): NO_MODEL + " (Postsubmit workflow)",
    ("approve", "tokens"): "approval is a review verdict with no model call of its own",
    ("approve", "time"): "ci.approve_to_ship_p50 is the approve time (approve to merged, CI included)",
    ("intake", "time"): "not measured: state/N.json keeps only the current state_changed_at, so an issue's time as ready-for-agent is lost once it leaves",
    ("intake", "tokens"): NO_MODEL + " (intake.sh)",
    ("triage", "time"): "not measured: state files keep only the current state, so an issue's entry time into needs-triage is lost; batch logs record counts only",
    ("advisor", "tokens"): "not measured: advisor-batch result JSON has no token field",
    ("merge", "tokens"): NO_MODEL + " (merge-prep.sh, merge-pr)",
    ("ci", "tokens"): NO_MODEL + " (ci-admission.sh)",
    ("release", "tokens"): NO_MODEL + " (run-release.sh)",
}

# metric id: (node, description, healthy bound, unhealthy bound, higher_is_better). Filled from NODE-HEALTH.md.
CRITERIA = {
    "intake.out_per_day":  ("intake", "intake items out per 24 h", 37, 25, True),
    "triage.out_per_day":  ("triage", "triage issues applied per 24 h", 9, 5, True),
    "triage.tokens_per_issue_p50": ("triage", "triage tokens per issue p50", 152000, 210000, False),
    "advisor.out_per_day": ("advisor", "advisor rulings applied per 24 h", 3, 2, True),
    "implement.tokens_p50": ("implement", "implement worker tokens per run p50", 392000, 555000, False),
    "implement.out_per_day": ("implement", "implement write-ends per 24 h", 51, 12, True),
    "review.tokens_p50":   ("review", "review worker tokens per run p50", 258000, 324000, False),
    "review.out_per_day":  ("review", "review verdicts per 24 h", 48, 37, True),
    "repair.tokens_p50":   ("repair", "repair worker tokens per run p50", 230000, 307000, False),
    "repair.out_per_day":  ("repair", "repair write-ends per 24 h", 34, 19, True),
    "merge.wait_p50_min":  ("merge", "merge wait: previous event to merged, minutes p50", 31, 41, False),
    "ci.admission_p50_min": ("ci", "CI wait: previous event to ci-ready, minutes p50", 0, 17, False),
    "ci.out_per_day":      ("ci", "CI slots admitted per 24 h", 28, 13, True),
    # Pipeline steps outside the stations (PIPELINE). Bounds are filled from the measurement in NODE-HEALTH.md.
    "approve.out_per_day": ("approve", "review approvals per 24 h", 35, 30, True),
    "rereview.wall_p50": ("rereview", "rereview run minutes p50", 13, 17, False),
    "rereview.tokens_p50": ("rereview", "rereview worker tokens per run p50", 200000, 200000, False),
    "rereview.runs_per_day": ("rereview", "rereview worker runs started per 24 h", 35, 10, True),
}
MEANING = {
    "approve.out_per_day": "Review approvals in 24 h: how many units cleared review.",
    "rereview.runs_per_day": "Rereview worker runs started in 24 h: the rework loop's re-review load.",
    "rereview.wall_p50": "Median minutes of a rereview run: the time a re-review takes.",
    "rereview.tokens_p50": "Median worker tokens per rereview run.",
    "intake.out_per_day": "Issues that left intake (first unit event) in 24 h: the intake station's throughput.",
    "triage.out_per_day": "Issues the triage batches applied in 24 h: the triage station's throughput.",
    "triage.tokens_per_issue_p50": "Median triage model tokens per issue in a batch; a rise means each issue costs more to triage.",
    "advisor.out_per_day": "Advisor rulings applied in 24 h: the advisor station's throughput.",
    "implement.tokens_p50": "Median worker tokens per implement run; a rise means each unit costs more to build.",
    "implement.out_per_day": "Implement write-ends in 24 h: the implement station's throughput.",
    "review.tokens_p50": "Median worker tokens per review run.",
    "review.out_per_day": "Review verdicts (approve, request changes, block) in 24 h: the review station's throughput.",
    "repair.tokens_p50": "Median worker tokens per repair run.",
    "repair.out_per_day": "Repair write-ends in 24 h: the repair station's throughput.",
    "merge.wait_p50_min": "Median minutes from a unit's previous ledger event to merged or landed: the merge station's own time.",
    "ci.admission_p50_min": "Median minutes from a unit's previous ledger event to ci-ready: the CI station's own queue time.",
    "ci.out_per_day": "CI slots admitted in 24 h (ci-ready and ci-wip-start): the CI station's throughput.",
}
SOURCE = {
    "intake.out_per_day": "7 daily counts to 2026-11-07T13:13Z (24 h windows): p25 37, p10 25; healthy p25, unhealthy p10",
    "triage.out_per_day": "7 daily counts: p25 9, p10 5",
    "triage.tokens_per_issue_p50": "7 d: 91 triage batch logs (tokens_used / issue_sample_size): p75 151,725, p90 209,961 (rounded up)",
    "advisor.out_per_day": "7 daily counts: p25 3, p10 2",
    "implement.tokens_p50": "7 d: 557 implement runs with measured tokens: p75 391,729, p90 554,952 (rounded up)",
    "implement.out_per_day": "7 daily counts: p25 51, p10 12",
    "review.tokens_p50": "7 d: 24 review runs with measured tokens (small n): p75 257,372, p90 323,831 (rounded up)",
    "review.out_per_day": "7 daily counts: p25 48, p10 37",
    "repair.tokens_p50": "7 d: 292 repair runs with measured tokens: p75 229,149, p90 306,942 (rounded up)",
    "repair.out_per_day": "7 daily counts: p25 34, p10 19",
    "merge.wait_p50_min": "7 d: 221 merged/landed events, previous event to merge: p75 30.8, p90 41.0 min (rounded up)",
    "ci.admission_p50_min": "7 d: 342 ci-ready events, previous event to ci-ready: p75 0.0, p90 16.1 min (rounded up)",
    "ci.out_per_day": "7 daily counts: p25 28, p10 13",
    "approve.out_per_day": "7 daily counts of review-approve events: p25 35, p10 30",
    "rereview.runs_per_day": "7 daily counts of rereview worker runs from worker cost rows: p25 35, p10 10",
    "rereview.wall_p50": "7 d ending 2026-11-09T17:58Z: 450 rereview runs with output, minutes p75 11.9, p90 15.8 (rounded up)",
    "rereview.tokens_p50": "7 d ending 2026-11-09T17:58Z: 18 rereview runs with measured tokens: p75 270,358, p90 301,796. Healthy equals unhealthy, so no WARN band",
}


def _pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))] if values else None


def _ts(value):
    try:
        return datetime.strptime(str(value)[:20], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _history(unit):
    rows = [(_ts(h.get("at")), h) for h in unit.get("history") or [] if isinstance(h, dict) and h.get("stage")]
    return sorted(((t, h) for t, h in rows if t), key=lambda r: r[0])


def gap_samples(units, since, now, events):
    """Minutes from the previous ledger event to each event named in `events` inside the window."""
    out = []
    for unit in units:
        rows = _history(unit)
        for i, (t, h) in enumerate(rows):
            if i and since <= t <= now and h["stage"] in events:
                out.append((t - rows[i - 1][0]).total_seconds() / 60)
    return out


def run_tokens(runs, node):
    """Measured worker tokens per run of one node; `runs` is already windowed by the caller."""
    return [r["tokens"] for r in runs if r["node"] == node and r["tokens"] is not None]


def triage_tokens_per_issue(agent_home, since, now):
    """Triage batch logs: tokens_used / issue_sample_size per batch, by the log's mtime (as station outs read it)."""
    out = []
    for path in glob.glob(os.path.join(agent_home, "logs", "triage-triage-batch-*.log")):
        try:
            when = datetime.fromtimestamp(os.path.getmtime(path), timezone.utc)
            text = open(path, errors="ignore").read()
        except OSError:
            continue
        if not since <= when <= now:
            continue
        found = dict(TRIAGE_LOG_RE.findall(text))
        if found.get("tokens_used") and int(found.get("issue_sample_size", 0)) > 0:
            out.append(int(found["tokens_used"]) / int(found["issue_sample_size"]))
    return out


def event_times(units, names):
    """Times of every ledger event named in `names`, across all units."""
    return [t for unit in units for t, h in _history(unit) if h["stage"] in names]


def count_between(times, since, now):
    return sum(1 for t in times if since <= t <= now)


def out_count(events, now, hours=WINDOW_HOURS):
    since = now - timedelta(hours=hours)
    return sum(c for t, c in events if since <= t <= now)


def _window_values(until, hours, units, runs, runtime, agent_home, cost_rows, outs):
    since = until - timedelta(hours=hours)
    scale = 24 / hours
    values, samples = {}, {}
    for station in STATIONS:
        events = [(t, c) for t, c in outs[station] if since <= t <= until]
        key = f"{station}.out_per_day"
        values[key], samples[key] = sum(c for _, c in events) * scale, len(events)
    for key, event_names in (("merge.wait_p50_min", GAP_EVENTS["merge"]),
                             ("ci.admission_p50_min", GAP_EVENTS["ci"])):
        rows = gap_samples(units, since, until, event_names)
        values[key], samples[key] = _pct(rows, .5), len(rows)
    if cost_rows:
        from node_health import worker_runs
        window_runs = worker_runs(cost_rows, since, until)
    else:
        window_runs = [r for r in runs if since <= r["start"] <= until]
    for station, node in RUN_NODE.items():
        rows = run_tokens(window_runs, node)
        key = f"{station}.tokens_p50"
        values[key], samples[key] = _pct(rows, .5), len(rows)
    rows = triage_tokens_per_issue(agent_home, since, until)
    values["triage.tokens_per_issue_p50"], samples["triage.tokens_per_issue_p50"] = _pct(rows, .5), len(rows)
    approvals = [t for t in event_times(units, ("review-approve",)) if since <= t <= until]
    values["approve.out_per_day"], samples["approve.out_per_day"] = len(approvals) * scale, len(approvals)
    rereviews = [r for r in cost_rows if r["phase"] == "rereview" and since <= r["start"] <= until]
    values["rereview.runs_per_day"], samples["rereview.runs_per_day"] = len(rereviews) * scale, len(rereviews)
    for key, rows in (("rereview.wall_p50", [r["minutes"] for r in window_runs if r["node"] == "rereview" and r["output"]]),
                      ("rereview.tokens_p50", run_tokens(window_runs, "rereview"))):
        values[key], samples[key] = _pct(rows, .5), len(rows)
    return values, samples


def collect(now, units, runs, runtime, agent_home, cost_rows=()):
    """The station metric values for one tick: time and tokens over 24 h, throughput per 24 h."""
    import station_health  # lazy: station_health imports node_health, which imports this module
    return _window_values(now, WINDOW_HOURS, units, runs, runtime, agent_home, cost_rows,
                          station_health.outs(units, runtime, agent_home))[0]


def collect_windows(now, units, runs, runtime, agent_home, cost_rows=()):
    """Short readings and one-hour change from the same station event, log and worker records."""
    import station_health
    outs = station_health.outs(units, runtime, agent_home)
    periods = {hours: _window_values(now, hours, units, runs, runtime, agent_home, cost_rows, outs)
               for hours in (1, 6, 24)}
    previous = _window_values(now - timedelta(hours=1), 1, units, runs, runtime, agent_home, cost_rows, outs)
    result = {}
    for key in CRITERIA:
        short = next((hours for hours in (1, 6, 24) if periods[hours][1][key] and periods[hours][0][key] is not None), None)
        current, prior = periods[1][0][key], previous[0][key]
        trend = None
        if periods[1][1][key] and previous[1][key] and current is not None and prior is not None:
            delta = round(current - prior, 2)
            trend = {"delta": delta, "direction": "up" if delta > 0 else "down" if delta < 0 else "flat"}
        result[key] = {"value_1h": periods[short][0][key] if short else None,
                       "trend_1h": trend, "short_window": f"{short}h" if short else None,
                       "sample_n": periods[24][1][key]}
    return result


def samples(now, hours, units, runs, agent_home, runtime):
    """Raw per-item samples over `hours` (for measuring bounds): time and token lists, and daily out counts."""
    import station_health
    since = now - timedelta(hours=hours)
    outs = station_health.outs(units, runtime, agent_home)
    raw = {"merge.wait_p50_min": gap_samples(units, since, now, GAP_EVENTS["merge"]),
           "ci.admission_p50_min": gap_samples(units, since, now, GAP_EVENTS["ci"]),
           "triage.tokens_per_issue_p50": triage_tokens_per_issue(agent_home, since, now)}
    for station, node in RUN_NODE.items():
        raw[f"{station}.tokens_p50"] = run_tokens(runs, node)
    return raw, outs
