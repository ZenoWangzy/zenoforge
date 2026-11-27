import json, os, time
from datetime import datetime, timezone

CADENCE_FILES = {
    "units": "units.json",
    "workers": "workers.json",
    "ci_live": "pr-run-snapshot.json",
    "node_health": "node-health.json",
    "stations": "station-health.json",
    "merge_wait": "merge-wait-last-good.json",
    "delivery_rows": "delivery-rows-last-good.json",
}
WINDOW_SECONDS = {"merge_wait": 86400, "delivery_rows": 86400}


def _read(path):
    try:
        with open(path, encoding="utf-8") as source:
            value = json.load(source)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _epoch(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            return None
        return parsed.timestamp()
    except (OverflowError, ValueError):
        return None


def _iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _timestamp(doc, path, *keys):
    for key in keys:
        value = _epoch(doc.get(key))
        if value is not None:
            return _iso(value), value
    try:
        value = os.path.getmtime(path)
        return _iso(value), value
    except OSError:
        return None, None


def _tick_gap(doc):
    metrics = doc.get("metrics") or []
    if not isinstance(metrics, list):
        return None
    row = next((metric for metric in metrics if isinstance(metric, dict) and metric.get("id") == "scheduler.tick_gap_p50"), None)
    value = row.get("value") if isinstance(row, dict) else None
    return float(value) if isinstance(value, (int, float)) and value >= 30 else None


def read_sources(runtime_dir, now=None, tick_seconds=120, paused_since=None):
    now = time.time() if now is None else float(now)
    node_path = os.path.join(runtime_dir, CADENCE_FILES["node_health"])
    node = _read(node_path)
    configured = float(tick_seconds) if isinstance(tick_seconds, (int, float)) and tick_seconds >= 30 else 120.0
    interval = max(configured, _tick_gap(node) or configured)
    scheduler_window = max(900.0, interval * 2)
    pause = bool(paused_since)
    result = {}
    for name, filename in CADENCE_FILES.items():
        path = os.path.join(runtime_dir, filename)
        doc = node if name == "node_health" else _read(path)
        fields = {
            "ci_live": ("tick",),
            "node_health": ("generated_at", "generated"),
            "stations": ("at",),
            "merge_wait": ("at",),
            "delivery_rows": ("at",),
        }.get(name, ())
        if name == "ci_live" and doc.get("schema") != 1:
            at, epoch = None, None
        else:
            at, epoch = _timestamp(doc, path, *fields)
        window = WINDOW_SECONDS.get(name, scheduler_window)
        age = None if epoch is None else max(0, int(now - epoch))
        result[name] = {
            "at": at,
            "age_s": age,
            "window_s": int(window),
            "stale": age is None or age >= window,
            "paused": pause and name in ("units", "workers", "ci_live", "node_health", "stations"),
            "paused_since": paused_since if pause and name in ("units", "workers", "ci_live", "node_health", "stations") else None,
        }
    return result


def annotate_standards(standards, sources):
    data = dict(standards) if isinstance(standards, dict) else {}
    metrics = data.get("metrics")
    if not isinstance(metrics, list):
        return data
    rows = []
    for metric in metrics:
        if not isinstance(metric, dict):
            rows.append(metric)
            continue
        row = dict(metric)
        key = "delivery_rows" if str(row.get("id") or "").startswith("delivery.") else "merge_wait" if row.get("id") == "merge.green_to_merge_max_min" else "node_health"
        source = sources.get(key) or {}
        row["source_at"] = row.get("source_at") or row.get("data_at") or source.get("at")
        row["source_name"] = {"delivery_rows": "交付台账", "merge_wait": "合并等待", "node_health": "健康评分"}[key]
        row["source_stale"] = bool(source.get("stale"))
        row["source_paused"] = bool(source.get("paused"))
        row["source_paused_since"] = source.get("paused_since")
        rows.append(row)
    data["metrics"] = rows
    return data
