"""Shared loader for the scheduler unit ledger including retired (terminal) units.

The scheduler retires terminal-stage units out of the hot units.json into
units-archive.json (retire_terminal_units); nothing is ever deleted. Metrics,
dashboards and issue/PR dedupe need that history, so they read both files:
units.json first (its row is the fresher copy when an id briefly exists in
both places), then the archive. Duplicate ids collapse to the live row.
"""
import json
import os
from datetime import timedelta

LEDGER_FILES = ("units.json", "units-archive.json")


def load_units(runtime_dir):
    """Runtime dir -> full unit list across the live ledger and the retirement archive."""
    by_id = {}
    for name in LEDGER_FILES:
        try:
            with open(os.path.join(runtime_dir, name), encoding="utf-8") as source:
                units = json.load(source).get("units") or []
        except (OSError, ValueError, AttributeError):
            continue
        for unit in units:
            if isinstance(unit, dict) and unit.get("id"):
                by_id.setdefault(unit["id"], unit)
    return list(by_id.values())


def live_ledger_readable(runtime_dir):
    """True when units.json parses with a units list; load_units reads a missing ledger as empty."""
    try:
        return isinstance(json.load(open(os.path.join(runtime_dir, LEDGER_FILES[0]), encoding="utf-8")).get("units"), list)
    except (OSError, ValueError, AttributeError):
        return False


def _read_dict(path):
    try:
        value = json.load(open(path))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def closed_units_open_issues(runtime, agent_home, units):
    """Issue ids intake's terminal skip hides: candidates whose units all ended, handoff consumed; None without a census."""
    rows = _read_dict(os.path.join(runtime, "intake-candidates.json")).get("rows")
    if rows is None:
        return None
    ended = ("merged", "landed", "closed", "done", "wontfix", "duplicate")
    found = []
    for row in rows.splitlines():
        n = row.split("\t", 1)[0]
        if not n.isdigit():
            continue
        own = [u for u in units if u.get("issue") == int(n) or u.get("branch") == f"agent/issue-{n}"]
        state = _read_dict(os.path.join(agent_home, "state", f"{n}.json"))
        if state.get("state", "ready-for-agent") != "ready-for-agent":  # the census is older than a merge: awaiting-release is not hidden
            continue
        episode = (state.get("scheduler_handoff") or {}).get("episode")
        if own and all(u.get("stage") in ended and (not episode or u.get("hold_handoff_episode") == episode) for u in own):
            found.append(int(n))
    return found


def conflict_repairs(units, since, now, parse):
    """Merge conflicts in [since, now] that a repair run followed: a later write-start in the same unit."""
    count = 0
    for unit in units:
        events = [(e.get("stage") or "", parse(e.get("at"))) for e in unit.get("history") or []]
        for i, (stage, at) in enumerate(events):
            if stage == "merge-conflict" and at and since <= at <= now and any(s == "write-start" for s, _ in events[i + 1:]):
                count += 1
    return count


REVIEW_VERDICTS = ("review-approve", "review-request-changes", "review-block")
ID = "review.open_to_first_review_p90_min"
CRITERIA = {ID: ("review", "PR opened -> first review verdict minutes p90, 7 d (incl. waiting)", 60, 180, False)}
MEANING = {ID: "PR 开出到第一个评审结论的 p90 分钟，滚动 7 天，还在等第一次评审的 PR 按已等时间计：founder 合并前的真实等待，含评审员不可用、评审进程崩溃、停在 supervisor 路径的时间。"}
SOURCE = {ID: "units.json 每个 pr-opened → 之后第一个 review-approve / review-request-changes / review-block；停在 review-pending 的最新 PR 按 now 计"}


def first_review_waits(units, now, ts):
    """Minutes from each pr-opened to its first review verdict over 7 days; a PR still in review-pending counts its age."""
    since, waits = now - timedelta(days=7), []
    for u in units:
        kinds = sorted((ts(h["at"]), h.get("stage") or "") for h in u.get("history") or [] if ts(h.get("at")))
        opens = [i for i, (_, k) in enumerate(kinds) if k == "pr-opened"]
        for n, i in enumerate(opens):
            end = opens[n + 1] if n + 1 < len(opens) else len(kinds)
            verdict = next((t for t, k in kinds[i + 1:end] if k in REVIEW_VERDICTS), None)
            if verdict and since <= verdict <= now:
                waits.append((verdict - kinds[i][0]).total_seconds() / 60)
            elif not verdict and end == len(kinds) and u.get("stage") == "review-pending":
                waits.append((now - kinds[i][0]).total_seconds() / 60)
    return waits


def metrics(units, now, ts):
    waits = sorted(first_review_waits(units, now, ts))
    return {ID: waits[min(len(waits) - 1, int(round(.9 * (len(waits) - 1))))] if waits else None}
