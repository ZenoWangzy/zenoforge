"""Shared cancellation audit (actions-run-cancellations.jsonl): per-run causes and park counts for node_health.py.

A park is one cancel_unit_runs call. It cancels every open PR run of a branch in a loop, so its audit rows land
seconds apart. The row carries no PR or head field, so parks are counted per repo from those bursts.
"""
import json
from datetime import datetime, timezone

# shortcut: a park is a burst of parked rows at most 60 s apart (2026-11 audit: 3-14 s inside a park, 106 s+ between parks), upgrade when the audit row carries a park or head id
PARK_GAP_SECONDS = 60


def _at(value):
    try:
        return datetime.strptime(str(value)[:20], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def read_cancel_audit(path, repo):
    """Read shared cancel-cause records for this repo; None means the source is unavailable."""
    try:
        rows = []
        with open(path, errors="replace") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict) or not row.get("when") or not row.get("run_id"):
                    continue
                if row.get("repo") and row["repo"] != repo:
                    continue
                rows.append(row)
        return rows
    except OSError:
        return None


def cancel_reason(reason):
    text = str(reason or "").split(";", 1)[0].strip().lower()
    if text == "ci deferred":
        return "deferred"
    if text == "ci wip":
        return "slot_wait"
    if text.startswith("repair dispatched"):
        return "repair"
    if text.startswith("tests already red"):
        return "tests_red"
    if text.startswith("review requested changes"):
        return "review_changes"
    if text.startswith("review blocked"):
        return "review_blocked"
    if text.startswith("parked"):
        return "parked"
    if text == "superseded by newer main head":
        return "superseded"
    if text == "ci hold":
        return "priority_hold"
    return "other"


def audited_cancel_reasons(records, since, until):
    """Latest non-empty cause per run in a window; duplicate API attempts remain one M1 run."""
    if records is None:
        return None
    by_run = {}
    for index, row in enumerate(records):
        at = _at(row.get("when"))
        if not at or not since <= at <= until:
            continue
        key = (row.get("repo") or "", str(row["run_id"]))
        previous = by_run.get(key)
        reason = row.get("reason") or (previous[2] if previous else "")
        if previous is None or (at, index) >= (previous[0], previous[1]):
            by_run[key] = (at, index, reason)
    return [cancel_reason(reason) for _, _, reason in by_run.values()]


def park_count(records, since, until):
    """Parks in a window: rows whose cause is parked (own reason, else the run's last one), split per repo where the gap exceeds PARK_GAP_SECONDS."""
    if records is None:
        return None
    rows = sorted(((at, row) for row in records if (at := _at(row.get("when"))) and since <= at <= until),
                  key=lambda item: item[0])
    last, last_park, parks = {}, {}, 0
    for at, row in rows:
        repo = row.get("repo") or ""
        key = (repo, str(row["run_id"]))
        reason = row.get("reason") or last.get(key, "")
        if row.get("reason"):
            last[key] = row["reason"]
        if cancel_reason(reason) != "parked":
            continue
        previous = last_park.get(repo)
        if previous is None or (at - previous).total_seconds() > PARK_GAP_SECONDS:
            parks += 1
        last_park[repo] = at
    return parks


def cancel_metrics(records, since, until):
    counts = audited_cancel_reasons(records, since, until)
    ids = {
        "deferred": "ci.cancel_deferred_per_day",
        "slot_wait": "ci.cancel_slot_wait_per_day",
        "repair": "ci.cancel_repair_per_day",
        "tests_red": "ci.cancel_tests_red_per_day",
        "review_changes": "ci.cancel_review_changes_per_day",
        "review_blocked": "ci.cancel_review_blocked_per_day",
        "parked": "ci.cancel_parked_per_day",
        "superseded": "ci.cancel_superseded_per_day",
        "other": "ci.cancel_other_per_day",
    }
    if counts is None:
        return {metric: None for metric in ids.values()}, None
    hours = (until - since).total_seconds() / 3600
    per_day = {metric: 0 for metric in ids.values()}
    if hours <= 0:
        return {metric: None for metric in ids.values()}, 0
    for cause in counts:
        if cause in ids and cause != "parked":  # parked counts parks, not runs
            per_day[ids[cause]] += 24 / hours
    per_day[ids["parked"]] = park_count(records, since, until) * 24 / hours
    return per_day, counts.count("priority_hold")
