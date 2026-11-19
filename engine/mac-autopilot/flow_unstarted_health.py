"""Age metrics for unstarted ready-for-agent issues and supervisor-review units."""
import base64
import binascii
import json
import math
import os
from datetime import datetime, timezone

READY = "intake.oldest_never_started_rfa_hours"
REVIEW = "supervisor.oldest_review_hours"
CACHE_MAX_AGE_SECONDS = 600
STARTED_STAGES = {"implement", "review-pending", "review", "rereview-pending", "rereview",
                  "repair-pending", "repair", "supervisor-review", "ready-to-merge", "merged", "landed"}

CRITERIA = {
    READY: ("intake", "oldest never-started ready-for-agent issue age, hours", 24, 24.1, False),
    REVIEW: ("supervisor", "oldest unit currently in supervisor-review, hours", 4, 4.1, False),
}
MEANING = {
    READY: "最老的开放 ready-for-agent 工单（账本里没有开工记录），按 GitHub 创建时间计龄；24 小时以内健康，超过 24 小时不健康。",
    REVIEW: "当前处于 supervisor-review 的工作单中，按单元历史的最后事件时间计量该阶段时长；4 小时以内健康，超过 4 小时不健康。",
}
SOURCE = {
    READY: "fresh (≤10 min) intake-candidates.json rows and embedded issue createdAt, excluding issues with a units.json / units-archive.json start event; no GitHub call",
    REVIEW: "current units.json rows at stage supervisor-review; time from the latest history event, matching flow.wip_age_stage_p90_hours",
}


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as source:
            value = json.load(source)
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def _time(value):
    if not isinstance(value, str):
        return None
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if stamp.tzinfo is None:
        return None
    return stamp.astimezone(timezone.utc)


def _age_hours(started_at, now):
    age = (now - started_at).total_seconds() / 3600
    if age < 0:
        return None
    # Keep exact boundaries healthy; any elapsed time beyond one is rounded up to the next tenth.
    return math.ceil(age * 10 - 1e-9) / 10


def _issue_number(unit):
    issue = unit.get("issue")
    if isinstance(issue, int) and not isinstance(issue, bool) and issue > 0:
        return issue
    for value in (unit.get("id"), unit.get("branch")):
        if not isinstance(value, str):
            continue
        if value.startswith("agent/issue-"):
            value = value[len("agent/"):]
        if value.startswith("issue-") and value[6:].isdigit():
            return int(value[6:])
    return None


def _started_issues(units):
    started = set()
    for unit in units:
        if not isinstance(unit, dict):
            continue
        history = unit.get("history") or []
        if not isinstance(history, list):
            return None
        issue = _issue_number(unit)
        if issue is None:
            continue
        if unit.get("stage") in STARTED_STAGES or any(
            isinstance(event, dict) and event.get("stage") in ("write-start", "implement-started")
            for event in history
        ):
            started.add(issue)
    return started


def oldest_ready_age(runtime, units, now, ledger_ok):
    """Largest issue createdAt age in the fresh intake snapshot; missing evidence stays NO-DATA."""
    if not ledger_ok:
        return None
    doc = _read_json(os.path.join(runtime, "intake-candidates.json"))
    if not doc or doc.get("schema") not in (4, 5) or not isinstance(doc.get("created_at"), (int, float)) \
            or isinstance(doc.get("created_at"), bool) or not isinstance(doc.get("rows"), str):
        return None
    now_epoch = now.timestamp()
    if not 0 <= now_epoch - doc["created_at"] <= CACHE_MAX_AGE_SECONDS:
        return None
    started = _started_issues(units)
    if started is None:
        return None
    oldest = None
    for row in doc["rows"].splitlines():
        fields = row.split("\t")
        if len(fields) < 5 or not fields[0].isdigit() or int(fields[0]) <= 0 or not fields[1]:
            return None
        try:
            labels = json.loads(fields[3])
        except ValueError:
            return None
        if not isinstance(labels, list) or any(not isinstance(label, str) for label in labels):
            return None
        issue_number = int(fields[0])
        if "ready-for-agent" not in labels or issue_number in started:
            continue
        try:
            issue = json.loads(base64.b64decode(fields[4], validate=True))
        except (ValueError, TypeError, binascii.Error, UnicodeDecodeError):
            return None
        if not isinstance(issue, dict) or type(issue.get("number")) is not int or issue["number"] != issue_number:
            return None
        state = issue.get("state")
        if not isinstance(state, str) or state.casefold() not in ("open", "closed"):
            return None
        if state.casefold() != "open":
            continue
        created = _time(issue.get("createdAt"))
        if created is None:
            return None
        age = _age_hours(created, now)
        if age is None:
            return None
        oldest = age if oldest is None else max(oldest, age)
    return oldest


def oldest_review_age(units, now, ledger_ok):
    """Oldest current supervisor-review stage age using the existing WIP last-event clock."""
    if not ledger_ok:
        return None
    ages = []
    for unit in units:
        if not isinstance(unit, dict) or unit.get("stage") != "supervisor-review":
            continue
        history = unit.get("history") or []
        if not isinstance(history, list):
            return None
        times = [_time(event.get("at")) for event in history if isinstance(event, dict)]
        times = [stamp for stamp in times if stamp is not None]
        entered = max(times) if times else None
        if entered is None:
            return None
        age = _age_hours(entered, now)
        if age is None:
            return None
        ages.append(age)
    return max(ages) if ages else None


def collect(runtime, units, now, ledger_ok):
    return {READY: oldest_ready_age(runtime, units, now, ledger_ok),
            REVIEW: oldest_review_age(units, now, ledger_ok)}
