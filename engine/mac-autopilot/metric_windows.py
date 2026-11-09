"""Short-window readings for scorecard metrics whose source is an event cohort."""

from datetime import timedelta


DELIVERY_METRICS = (
    "delivery.issue_to_accept_p50_7d_hours", "delivery.issue_to_accept_p95_7d_hours",
    "delivery.issue_to_accept_p50_30d_hours", "delivery.issue_to_accept_p95_30d_hours",
    "delivery.revert_rate_30d_pct", "delivery.incident_rate_30d_pct",
    "delivery.cycles_to_pass_30d", "delivery.approvals_per_merge_30d",
    "delivery.unlinked_units_30d", "delivery.unlinked_incidents_30d",
)
WINDOWS = ((1, "1h"), (6, "6h"), (24, "24h"), (168, "7d"), (720, "30d"))
LEDGER_WINDOWS = WINDOWS[:4]
LEDGER_ZERO_COUNTS = frozenset(("workers.deaths", "ci.precheck_setup_failures",
    "supervisor.arbiter_dispatches_24h", "supervisor.cap_default_24h", "supervisor.repeat_guard_24h",
    "supervisor.token_parks_24h", "supervisor.spend_ledger_blind"))
LEDGER_SNAPSHOTS = frozenset(("supervisor.stop_loss_same_failure_parked",))
SNAPSHOT_METRICS = frozenset(("supervisor.stop_loss_same_failure_parked", "workers.local_test_db",
    "host.prereqs_missing", "host.stale_worktrees", "intake.closed_units_open_issues", "engine.follow_lag_hours",
    "workorders.over_standard", "ci.held_ready_pct", "flow.wip_age_stage_p90_hours", "flow.wait_stage_p90_hours",
    "flow.wait_stage_units", "release.hours_waiting", "release.hotpatch_blockers", "pipeline.orphan_prs",
    "mechanism.silent", "advisor.last_answer_age_hours"))


def _has_samples(metric, result):
    value = result["values"].get(metric)
    if value is None:
        return False
    details = result["details"]
    if metric in ("delivery.unlinked_units_30d", "delivery.unlinked_incidents_30d",
                  "delivery.incident_rate_30d_pct", "delivery.revert_rate_30d_pct"):
        return (details.get("accepted_units_30d") or 0) > 0
    if metric in ("delivery.cycles_to_pass_30d", "delivery.approvals_per_merge_30d"):
        return (details.get("merged_units_30d") or 0) > 0
    return True


def ledger(calculate, units, now):
    """Re-score ledger-backed metrics over shorter cohorts without changing their bounds."""
    periods = {hours: calculate(units, now - timedelta(hours=hours), now, window_hours=hours)
               for hours, _ in LEDGER_WINDOWS}
    previous = calculate(units, now - timedelta(hours=2), now - timedelta(hours=1), window_hours=1)
    result = {}
    for metric in periods[1]:
        if metric in LEDGER_SNAPSHOTS:
            continue
        value = lambda doc: doc.get(metric)
        has = lambda doc: value(doc) is not None and not (metric in LEDGER_ZERO_COUNTS and value(doc) == 0)
        candidates = LEDGER_WINDOWS[:2] if metric == "supervisor.spend_ledger_blind" else LEDGER_WINDOWS
        short = next(((hours, label) for hours, label in candidates if has(periods[hours])), None)
        current, prior = periods[1], previous
        trend = None
        if has(current) and has(prior):
            delta = round(value(current) - value(prior), 2)
            trend = {"delta": delta, "direction": "up" if delta > 0 else "down" if delta < 0 else "flat"}
        result[metric] = {"value_1h": value(periods[short[0]]) if short else None,
                          "trend_1h": trend, "short_window": short[1] if short else None}
    return result


def delivery(calculate, args):
    """Compute short cohorts from the same loaded delivery records as the standard values."""
    now = args[5]
    periods = {hours: calculate(*args, window_hours=hours) for hours, _ in WINDOWS}
    previous_args = (*args[:5], now - timedelta(hours=1), *args[6:])
    previous = calculate(*previous_args, window_hours=1)
    result = {}
    for metric in DELIVERY_METRICS:
        limit = 168 if metric.endswith("_7d_hours") else 720
        short = next(((hours, label) for hours, label in WINDOWS[:4 if limit == 168 else 5]
                      if _has_samples(metric, periods[hours])), None)
        current, prior = periods[1], previous
        trend = None
        if _has_samples(metric, current) and _has_samples(metric, prior):
            delta = round(current["values"][metric] - prior["values"][metric], 2)
            trend = {"delta": delta, "direction": "up" if delta > 0 else "down" if delta < 0 else "flat"}
        result[metric] = {"value_1h": periods[short[0]]["values"][metric] if short else None,
                          "trend_1h": trend, "short_window": short[1] if short else None}
    return result


def fill(metrics, windows, criteria, sources, default_hours):
    """Keep existing point-in-time/long-window readings explicit when no shorter sampler exists."""
    for metric, value in metrics.items():
        if metric in windows:
            continue
        text = " ".join((metric, criteria.get(metric, (None, ""))[1] or "", sources.get(metric, ""))).lower()
        if metric in SNAPSHOT_METRICS:
            label = "now"
        elif "30d" in text or "30 d" in text:
            label = "30d"
        elif "7d" in text or "7 d" in text:
            label = "7d"
        elif "48h" in text or "48 h" in text:
            label = "48h"
        elif "24h" in text or "24 h" in text or "per day" in text or "per 24 h" in text:
            label = "24h"
        elif "6h" in text or "6 h" in text:
            label = "6h"
        else:
            label = f"{default_hours:g}h"
        windows[metric] = {"value_1h": value, "trend_1h": None, "short_window": label if value is not None else None}
    return windows
