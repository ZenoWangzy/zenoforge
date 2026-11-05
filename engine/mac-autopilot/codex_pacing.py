#!/usr/bin/env python3
"""Snapshot and project the Codex primary weekly quota window."""

from __future__ import annotations

import argparse
import glob
import json
import math
import os
import tempfile
from datetime import datetime, timedelta, timezone


UTC = timezone.utc


def parse_datetime(value):
    """Parse an ISO timestamp or Unix epoch as UTC; invalid values are unknown."""
    if isinstance(value, datetime):
        return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(value, UTC)
        except (OverflowError, OSError, ValueError):
            return None
    if not isinstance(value, str) or not value.strip():
        return None
    value = value.strip()
    if value.isdecimal():
        try:
            return datetime.fromtimestamp(int(value), UTC)
        except (OverflowError, OSError, ValueError):
            return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed.astimezone(UTC)


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def parse_quota_event(record):
    """Return one token_count event's primary quota sample, or None if unusable."""
    if not isinstance(record, dict) or record.get("type") != "event_msg":
        return None
    payload = record.get("payload")
    if not isinstance(payload, dict) or payload.get("type") != "token_count":
        return None
    info = payload.get("info")
    limits = info.get("rate_limits") if isinstance(info, dict) else None
    primary = limits.get("primary") if isinstance(limits, dict) else None
    if not isinstance(primary, dict):
        return None
    used = primary.get("used_percent")
    event_at = parse_datetime(record.get("timestamp"))
    if not _number(used) or not 0 <= used <= 100 or event_at is None:
        return None

    resets_at = parse_datetime(primary.get("resets_at"))
    if resets_at is None:
        resets_in = primary.get("resets_in_seconds")
        if not _number(resets_in) or resets_in < 0:
            return None
        resets_at = event_at + timedelta(seconds=resets_in)
    return {"at": event_at, "used_percent": float(used), "resets_at": resets_at}


def _reverse_lines(path, chunk_size=65536):
    """Yield a JSONL file's lines newest first without loading its history into memory."""
    with open(path, "rb") as source:
        position = source.seek(0, os.SEEK_END)
        partial = b""
        while position:
            start = max(0, position - chunk_size)
            source.seek(start)
            block = source.read(position - start)
            pieces = (block + partial).split(b"\n")
            if start:
                partial = pieces[0]
                complete = pieces[1:]
            else:
                partial = b""
                complete = pieces
            for line in reversed(complete):
                yield line
            position = start
        if partial:
            yield partial


def _records_newest_first(path, cutoff):
    for line in _reverse_lines(path):
        try:
            record = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if not isinstance(record, dict):
            continue
        at = parse_datetime(record.get("timestamp"))
        if at is not None and at < cutoff:
            break
        yield record


def read_session_events(sessions_dir, now=None, window_hours=6, max_age_seconds=900):
    """Read recent primary quota events, skipping old files and old JSONL prefixes."""
    now = parse_datetime(now) or datetime.now(UTC)
    window_hours = float(window_hours) if _number(window_hours) and window_hours > 0 else 6.0
    max_age_seconds = int(max_age_seconds) if _number(max_age_seconds) and max_age_seconds >= 0 else 900
    cutoff = now - timedelta(hours=window_hours, seconds=max_age_seconds + 300)
    cutoff_epoch = cutoff.timestamp()
    root = os.fspath(sessions_dir)
    for path in glob.iglob(os.path.join(root, "**", "*.jsonl"), recursive=True):
        try:
            if os.stat(path).st_mtime < cutoff_epoch:
                continue
            for record in _records_newest_first(path, cutoff):
                sample = parse_quota_event(record)
                if sample is not None:
                    yield sample
        except OSError:
            continue


def _iso(value):
    return value.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def build_snapshot(events, window_hours=6, captured_at=None):
    """Build the latest quota snapshot and same-reset burn rate from parsed samples or JSONL records."""
    window_hours = float(window_hours) if _number(window_hours) and window_hours > 0 else 6.0
    captured_at = parse_datetime(captured_at) or datetime.now(UTC)
    parsed = []
    for event in events:
        if isinstance(event, dict) and isinstance(event.get("at"), datetime):
            sample = event
        else:
            sample = parse_quota_event(event)
        if sample is not None:
            parsed.append(sample)

    if not parsed:
        return {
            "used_percent": None,
            "resets_at": None,
            "observed_at": None,
            "burn_rate_percent_per_hour": None,
            "burn_window_hours": window_hours,
            "captured_at": _iso(captured_at),
        }

    parsed.sort(key=lambda sample: (sample["at"], sample["used_percent"]))
    latest = parsed[-1]
    window_start = latest["at"] - timedelta(hours=window_hours)
    history = [
        sample
        for sample in parsed
        if sample["resets_at"] == latest["resets_at"]
        and window_start <= sample["at"] <= latest["at"]
    ]
    # Multiple sessions can persist an identical sample at the same second. Keep the maximum at
    # each timestamp so file traversal order cannot change the burn estimate.
    by_time = {}
    for sample in history:
        key = sample["at"].timestamp()
        by_time[key] = max(by_time.get(key, 0.0), sample["used_percent"])
    samples = sorted(by_time.items())
    rate = 0.0
    if len(samples) >= 2:
        elapsed_hours = (samples[-1][0] - samples[0][0]) / 3600
        if elapsed_hours > 0:
            rate = max(0.0, (samples[-1][1] - samples[0][1]) / elapsed_hours)

    return {
        "used_percent": latest["used_percent"],
        "resets_at": _iso(latest["resets_at"]),
        "observed_at": _iso(latest["at"]),
        "burn_rate_percent_per_hour": round(rate, 6),
        "burn_window_hours": window_hours,
        "captured_at": _iso(captured_at),
    }


def evaluate_snapshot(snapshot, now=None, max_age_seconds=900, threshold_percent=100):
    """Project remaining usage to reset; stale, missing, and invalid data is unknown and never holds."""
    now = parse_datetime(now) or datetime.now(UTC)
    if not _number(max_age_seconds) or max_age_seconds < 0:
        max_age_seconds = 900
    if not _number(threshold_percent) or threshold_percent < 0:
        threshold_percent = 100
    result = {
        "status": "unknown",
        "hold": False,
        "projected_percent": None,
        "used_percent": None,
        "resets_at": None,
    }
    if not isinstance(snapshot, dict):
        return result
    used = snapshot.get("used_percent")
    rate = snapshot.get("burn_rate_percent_per_hour")
    observed_at = parse_datetime(snapshot.get("observed_at"))
    resets_at = parse_datetime(snapshot.get("resets_at"))
    if (
        not _number(used)
        or not 0 <= used <= 100
        or not _number(rate)
        or rate < 0
        or observed_at is None
        or resets_at is None
        or observed_at > now
        or (now - observed_at).total_seconds() > max_age_seconds
        or resets_at <= now
    ):
        return result
    hours_to_reset = (resets_at - now).total_seconds() / 3600
    projected = float(used) + float(rate) * hours_to_reset
    result.update(
        {
            "status": "fresh",
            "hold": projected > threshold_percent,
            "projected_percent": round(projected, 2),
            "used_percent": float(used),
            "resets_at": _iso(resets_at),
        }
    )
    return result


def should_hold_dispatch(decision, unit, provider):
    """Whether this dispatch should be held by a fresh projected Codex overrun."""
    if provider != "codex" or not isinstance(decision, dict) or decision.get("hold") is not True:
        return False
    if not isinstance(unit, dict):
        return True
    labels = unit.get("labels")
    labels = labels if isinstance(labels, list) else []
    hotfix = (
        unit.get("hotpatch") is True
        or unit.get("priority") == "hotfix"
        or any(isinstance(label, str) and label.lower() == "hotfix" for label in labels)
    )
    return not hotfix


def _write_snapshot(path, snapshot):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".codex-pacing.", dir=parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(snapshot, output, separators=(",", ":"), sort_keys=True)
            output.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def _read_snapshot(path):
    try:
        with open(path, encoding="utf-8") as source:
            value = json.load(source)
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def main(argv=None):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("--sessions-dir", required=True)
    snap.add_argument("--output", required=True)
    snap.add_argument("--window-hours", type=float, default=6)
    snap.add_argument("--max-age-seconds", type=int, default=900)
    snap.add_argument("--threshold-percent", type=float, default=100)
    snap.add_argument("--now", type=float)
    evaluate = sub.add_parser("evaluate")
    evaluate.add_argument("--snapshot", required=True)
    evaluate.add_argument("--max-age-seconds", type=int, default=900)
    evaluate.add_argument("--threshold-percent", type=float, default=100)
    evaluate.add_argument("--now", type=float)
    args = parser.parse_args(argv)
    now = parse_datetime(args.now) if args.now is not None else datetime.now(UTC)
    if args.command == "snapshot":
        samples = read_session_events(
            args.sessions_dir, now=now, window_hours=args.window_hours, max_age_seconds=args.max_age_seconds
        )
        snapshot = build_snapshot(samples, window_hours=args.window_hours, captured_at=now)
        try:
            _write_snapshot(args.output, snapshot)
        except OSError:
            print(json.dumps({"status": "unknown", "hold": False, "projected_percent": None,
                              "used_percent": None, "resets_at": None}, separators=(",", ":")))
            return 0
    else:
        snapshot = _read_snapshot(args.snapshot)
    decision = evaluate_snapshot(
        snapshot, now=now, max_age_seconds=args.max_age_seconds, threshold_percent=args.threshold_percent
    )
    print(json.dumps(decision, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
