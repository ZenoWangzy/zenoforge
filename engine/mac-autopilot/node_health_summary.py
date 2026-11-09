"""Console summaries shared by node_health after the scorecard rows."""


def print_summary(metrics, spend, bad, host_missing, closed_open):
    # The waste share alone cannot say WHERE the minutes went; the per-reason minutes from
    # ci-spend.json name the source, so a new one is visible without re-deriving it (2026-11-03).
    if metrics.get("ci.waste_runner_pct") is not None and isinstance(spend.get("by_reason"), dict) and spend["by_reason"]:
        print("  ci waste by reason (min): " + "  ".join(f"{key}={value:.0f}" for key, value in sorted(spend["by_reason"].items())))
    cancel_waste = spend.get("cancel_audit_min_by_reason")
    if metrics.get("ci.waste_runner_pct") is not None and isinstance(cancel_waste, dict):
        order = ("deferred", "slot_wait", "repair_dispatched", "superseded_main_head",
                 "review_blocked", "parked", "other")
        print("  ci waste by cancel reason (min): " + "  ".join(f"{key}={cancel_waste.get(key, 0):.0f}" for key in order))
    print("unhealthy nodes: " + (", ".join(sorted({row[0] for row in bad})) or "none"))
    if host_missing:
        print("host missing: " + "; ".join(host_missing))
    if closed_open:
        print("closed units under open issues: " + " ".join(f"#{number}" for number in closed_open))
