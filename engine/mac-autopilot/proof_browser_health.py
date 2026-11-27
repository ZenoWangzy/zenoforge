import json
import math
import os
from datetime import datetime, timezone
from pathlib import Path

SAMPLES_FILE = "proof-browser-runs.jsonl"
REVIEW_WAIT_THRESHOLD_MS = 1000
LOCK_WAIT_P50 = "delivery.proof_browser_lock_wait_p50_ms"
LOCK_WAIT_P90 = "delivery.proof_browser_lock_wait_p90_ms"
WAIT_OVER_THRESHOLD = "delivery.proof_browser_wait_over_review_threshold_pct"
CRITERIA = {
    LOCK_WAIT_P50: ("delivery", "proof browser lock wait p50 ms", 100, 1000, False),
    LOCK_WAIT_P90: ("delivery", "proof browser lock wait p90 ms", 1000, 5000, False),
    WAIT_OVER_THRESHOLD: ("delivery", "proof runs over one second browser wait %", 5, 20, False),
}
MEANING = {
    LOCK_WAIT_P50: "Typical time a product proof waits for the shared browser",
    LOCK_WAIT_P90: "Long-tail time a product proof waits for the shared browser",
    WAIT_OVER_THRESHOLD: "Proof runs whose shared-browser wait exceeds one second",
}
SOURCE = {metric: SAMPLES_FILE for metric in CRITERIA}
LOW_N_METRICS = frozenset(CRITERIA)

def _sample_path(runtime, agent_home):
    configured = os.environ.get("ZF_CDP_BROWSER_LEASE_METRICS_FILE")
    candidates = (
        configured,
        os.path.join(runtime, SAMPLES_FILE) if runtime else None,
        os.path.join(agent_home, "logs", SAMPLES_FILE) if agent_home else None,
    )
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    return next((candidate for candidate in candidates if candidate), None)

def _completed_at(value):
    if not isinstance(value, str):
        return None
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(timezone.utc)

def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0

def _samples(path, since, now):
    if not path:
        return []
    values = []
    try:
        with open(path, encoding="utf-8") as source:
            for line in source:
                try:
                    row = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if not isinstance(row, dict):
                    continue
                at = _completed_at(row.get("completed_at") or row.get("at"))
                wait = row.get("lock_wait_ms")
                run = row.get("run_ms")
                if at and since <= at <= now and _number(wait) and _number(run):
                    values.append(float(wait))
    except OSError:
        return []
    return values

def _percentile(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))] if values else None

def collect(runtime, agent_home, since, now, sample_counts=None, percentile=None):
    percentile = percentile or _percentile
    waits = _samples(_sample_path(runtime, agent_home), since, now)
    count = len(waits)
    if sample_counts is not None:
        sample_counts.update({metric: count for metric in CRITERIA})
    return {
        LOCK_WAIT_P50: percentile(waits, 0.5),
        LOCK_WAIT_P90: percentile(waits, 0.9),
        WAIT_OVER_THRESHOLD: 100 * sum(wait > REVIEW_WAIT_THRESHOLD_MS for wait in waits) / count if count else None,
    }
