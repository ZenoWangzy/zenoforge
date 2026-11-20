"""Annotate intake candidate rows: auto-filed flag, ready-since time, aging (issue_intake.aging_hours)."""
import json, os, sys, time
from datetime import datetime, timezone
import founder_reqs


def epoch(value):
    try:
        stamp = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if stamp.tzinfo is None:
            stamp = stamp.replace(tzinfo=timezone.utc)
        return int(stamp.timestamp())
    except (ValueError, TypeError, OverflowError):
        return 0


def ready_since(row, state_dir):
    if not any(label.get("name") == "ready-for-agent" for label in row.get("labels", []) if isinstance(label, dict)):
        return 0
    try:
        with open(os.path.join(state_dir, str(row.get("number")) + ".json"), encoding="utf-8") as state_file:
            state = json.load(state_file)
        return epoch(state.get("state_changed_at")) if state.get("state") == "ready-for-agent" else 0
    except (OSError, json.JSONDecodeError, TypeError, AttributeError):
        return 0


def main():
    rows = json.load(sys.stdin)
    prefix = founder_reqs.configured_anomaly_prefix()
    state_dir = os.path.join(os.environ.get("AGENT_HOME", os.path.expanduser("~/.zenoforge")), "state")
    hours = os.environ.get("INTAKE_AGING_HOURS", "")
    hours = int(hours) if hours.isdigit() else 75
    now = int(time.time())
    for row in rows:
        row["_auto_filed"] = founder_reqs.is_auto_filed_ticket(row, prefix)
        row["_ready_since_epoch"] = ready_since(row, state_dir) or epoch(row.get("updatedAt") or row.get("updated_at") or row.get("createdAt")) or now
        labelled_ready = any(isinstance(l, dict) and l.get("name") == "ready-for-agent" for l in row.get("labels", []))
        row["_aged"] = row.get("lane") == "pr" and labelled_ready and now - row["_ready_since_epoch"] > hours * 3600
    json.dump(rows, sys.stdout, separators=(",", ":"))


if __name__ == "__main__":
    main()
