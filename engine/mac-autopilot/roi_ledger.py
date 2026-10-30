#!/usr/bin/env python3
"""Append-only unit cost ledger and price table reader for the pipeline ROI reports."""
import fcntl
import gzip
import json
import os
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path


EVENT_TYPES = frozenset(("unit-end", "ci-run-end", "gh-quota"))
MODEL_COUNTERS = ("input", "cached", "cache_write", "output", "reasoning", "tokens")


def _timestamp(value):
    if not isinstance(value, str):
        raise ValueError("event timestamp must be a string")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("event timestamp must include a timezone")
    return parsed.astimezone(timezone.utc)


def _open_text(path):
    return gzip.open(path, "rt", encoding="utf-8") if str(path).endswith(".gz") \
        else open(path, encoding="utf-8")


def validate_event(event):
    if not isinstance(event, dict) or event.get("schema_version") != 1 or event.get("record_type") != "event":
        raise ValueError("expected a schema_version 1 event")
    if event.get("event_type") not in EVENT_TYPES:
        raise ValueError(f"unknown event type: {event.get('event_type')!r}")
    if not isinstance(event.get("event_id"), str) or not event["event_id"]:
        raise ValueError("event_id is required")
    if not isinstance(event.get("host"), str) or not event["host"]:
        raise ValueError("host is required")
    _timestamp(event.get("ts"))
    if event["event_type"] == "unit-end":
        if not isinstance(event.get("unit"), dict) or not isinstance(event.get("tickets"), list):
            raise ValueError("unit-end requires unit and tickets")
        if not isinstance(event.get("models"), list):
            raise ValueError("unit-end requires models")
        for model in event["models"]:
            if not isinstance(model, dict):
                raise ValueError("model counters must be objects")
            for name in MODEL_COUNTERS:
                value = model.get(name)
                if value is not None and (type(value) is not int or value < 0):
                    raise ValueError(f"invalid {name} token count")
    return event


def ledger_path(home, ts):
    month = _timestamp(ts).strftime("%Y-%m")
    return Path(home) / "metrics" / f"units-{month}.jsonl"


def _rows(path):
    if not path.exists():
        return
    with _open_text(path) as source:
        for line in source:
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict):
                yield value


def append_rows(home, events):
    """Append changed event IDs under the efficiency-ledger flock protocol (last row wins)."""
    grouped = defaultdict(list)
    for event in events:
        validate_event(event)
        grouped[ledger_path(home, event["ts"])].append(event)

    appended = unchanged = 0
    written_paths = []
    for path, batch in sorted(grouped.items(), key=lambda item: str(item[0])):
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(path.parent, 0o700)
        lock_fd = os.open(str(path) + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            os.fchmod(lock_fd, 0o600)
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            previous = {row["event_id"]: row for row in _rows(path) if isinstance(row.get("event_id"), str)}
            changed = []
            for event in batch:
                if previous.get(event["event_id"]) == event:
                    unchanged += 1
                    continue
                changed.append(event)
                previous[event["event_id"]] = event
            if changed:
                file_fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)
                try:
                    os.fchmod(file_fd, 0o600)
                    with os.fdopen(file_fd, "a", encoding="utf-8") as output:
                        file_fd = -1
                        for event in changed:
                            output.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
                finally:
                    if file_fd >= 0:
                        os.close(file_fd)
                appended += len(changed)
                written_paths.append(str(path))
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)
    return {"appended": appended, "unchanged": unchanged, "files": written_paths}


def read_events(home):
    """Read monthly JSONL files and resolve re-emitted rows by event_id, last row wins."""
    metrics = Path(home) / "metrics"
    if not metrics.is_dir():
        return []
    latest = {}
    paths = sorted(metrics.glob("units-*.jsonl")) + sorted(metrics.glob("units-*.jsonl.gz"))
    for path in paths:
        for event in _rows(path):
            if event.get("record_type") == "event" and event.get("schema_version") == 1:
                validate_event(event)
                latest[event["event_id"]] = event
    return list(latest.values())


def load_prices(default_path, local_path=None):
    with open(default_path, encoding="utf-8") as source:
        table = json.load(source)
    if local_path and os.path.isfile(local_path):
        with open(local_path, encoding="utf-8") as source:
            override = json.load(source)
        models = dict(table.get("models") or {})
        models.update(override.get("models") or {})
        table.update({key: value for key, value in override.items() if key != "models"})
        table["models"] = models
    if table.get("schema") != "zenoforge-roi-prices/v1" or not isinstance(table.get("models"), dict):
        raise ValueError("unsupported ROI price table")
    return table
