#!/usr/bin/env python3
"""Emit one head-watch alert when a persisted advisor batch stops producing results."""

from datetime import datetime, timezone
import glob
import json
import re
import sys
from pathlib import Path


STALE_AFTER_SECONDS = 30 * 60
JOB_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")


def parse_recorded_at(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def parse_job_started_at(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        return datetime.fromtimestamp(value, timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None


def latest_result(log_dir):
    newest = None
    for name in glob.glob(str(log_dir / "advisor-batch-*.result.json")):
        try:
            with open(name, encoding="utf-8") as stream:
                value = json.load(stream)
            recorded = parse_recorded_at(value.get("recorded_at")) if isinstance(value, dict) else None
        except (OSError, ValueError):
            continue
        if recorded is not None and (newest is None or recorded > newest):
            newest = recorded
    return newest


def emit_if_stale(agent_home, now):
    try:
        with open(agent_home / "advisor-batch.json", encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, ValueError):
        return False
    job = state.get("job") if isinstance(state, dict) else None
    job_id = job.get("job_id") if isinstance(job, dict) else None
    if not isinstance(job_id, str) or not JOB_ID_RE.fullmatch(job_id):
        return False

    log_dir = agent_home / "logs"
    last_result = latest_result(log_dir)
    job_started = parse_job_started_at(job.get("started_at")) if isinstance(job, dict) else None
    baselines = [timestamp for timestamp in (last_result, job_started) if timestamp is not None]
    if not baselines:
        return False
    last_activity = max(baselines)
    age_seconds = int(now.timestamp() - last_activity.timestamp())
    if age_seconds <= STALE_AFTER_SECONDS:
        return False

    last_result_text = last_result.strftime("%Y-%m-%dT%H:%M:%SZ") if last_result else "none"
    key = f"key=advisor-batch-no-result:{job_id}:{last_result_text}"
    alert_file = log_dir / "head-watch.alerts"
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        if alert_file.exists() and key in alert_file.read_text(encoding="utf-8", errors="replace"):
            return False
        stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
        with alert_file.open("a", encoding="utf-8") as stream:
            stream.write(
                f"{stamp} ADVISOR-BATCH-NO-RESULT age_min={age_seconds // 60} "
                f"job_id={job_id} last_result_at={last_result_text} {key}\n"
            )
    except OSError as error:
        print(f"advisor-batch-watchdog: could not append head-watch alert ({type(error).__name__})", file=sys.stderr)
        return False
    return True


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: advisor-batch-watchdog.py AGENT_HOME [NOW_EPOCH]", file=sys.stderr)
        return 2
    agent_home = Path(argv[1])
    now = datetime.fromtimestamp(int(argv[2]), timezone.utc) if len(argv) == 3 else datetime.now(timezone.utc)
    emit_if_stale(agent_home, now)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
