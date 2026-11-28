"""Shared loader for the scheduler unit ledger including retired (terminal) units.

The scheduler retires terminal-stage units out of the hot units.json into
units-archive.json (retire_terminal_units); nothing is ever deleted. Metrics,
dashboards and issue/PR dedupe need that history, so they read both files:
units.json first (its row is the fresher copy when an id briefly exists in
both places), then the archive. Duplicate ids collapse to the live row.
"""
import json
import os
import re
from contextlib import nullcontext
from datetime import datetime, timedelta, timezone

LEDGER_FILES = ("units.json", "units-archive.json")
SCHEDULER_LINE_RE = re.compile(r"^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\]")
SCHEDULER_FUTURE_TOLERANCE = timedelta(seconds=300)


def scheduler_log_lines(path, now):
    """Read scheduler rows, skipping stamps over five minutes ahead; return rows and the skip count."""
    rows, future_stamped = [], 0
    try:
        with open(path, errors="ignore") as source:
            for raw in source:
                match = SCHEDULER_LINE_RE.match(raw)
                if match:
                    try:
                        at = datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                    except ValueError:
                        at = None
                    if at and at > now + SCHEDULER_FUTURE_TOLERANCE:
                        future_stamped += 1
                        continue
                rows.append(raw)
    except OSError:
        return None, 0
    return rows, future_stamped


def latest_scheduler_tick(path, now):
    """Return the newest retained scheduler timestamp, or an empty string."""
    rows, _ = scheduler_log_lines(path, now)
    tick = ""
    for raw in rows or []:
        match = SCHEDULER_LINE_RE.match(raw)
        if match:
            tick = match.group(1)
    return tick


RELEASE_CLOSER_RE = re.compile(r"release-closer: deployed=([0-9a-f]{7,40}) closed=\[([0-9,\s]*)\](?: surface_covered=(true|false))?")
_SCHEDULER_ROWS_UNSET = object()


def _scheduler_event_time(raw):
    if not raw.startswith("["):
        return None
    try:
        return datetime.strptime(raw[1:21], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def release_acceptances(runtime, now=None, scheduler_rows=_SCHEDULER_ROWS_UNSET):
    """Read batch close events from event notes and the filtered scheduler log."""
    now = now or datetime.now(timezone.utc)
    scheduler_path = os.path.join(runtime, "scheduler.log")
    paths = [os.path.join(runtime, "alerts", "events.md"), scheduler_path]
    events, surface_events, seen = [], [], set()
    found_source = False
    for path in paths:
        try:
            if path == scheduler_path:
                rows = scheduler_rows
                if rows is _SCHEDULER_ROWS_UNSET:
                    rows, _ = scheduler_log_lines(path, now)
                if rows is None:
                    continue
                source = nullcontext(rows)
            else:
                source = open(path, errors="ignore")
            with source as lines:
                found_source = True
                for raw in lines:
                    match = RELEASE_CLOSER_RE.search(raw)
                    at = _scheduler_event_time(raw)
                    if not at or at > now + SCHEDULER_FUTURE_TOLERANCE:
                        continue
                    if not match:
                        continue
                    for number in re.findall(r"\d+", match.group(2)):
                        event = {"issue": int(number), "sha": match.group(1), "at": at.strftime("%Y-%m-%dT%H:%M:%SZ")}
                        if match.group(3) is not None:
                            event["surface_covered"] = match.group(3) == "true"
                            event["surface_covered_at"] = event["at"]
                            surface_events.append(event)
                        key = (event["issue"], event["sha"], event["at"])
                        if key not in seen:
                            seen.add(key)
                            events.append(event)
                        elif match.group(3) is not None:
                            existing = next(existing for existing in events if
                                            (existing["issue"], existing["sha"], existing["at"]) == key)
                            existing["surface_covered"] = event["surface_covered"]
                            existing["surface_covered_at"] = event["surface_covered_at"]
        except OSError:
            continue
    surface_by_release = {}
    for event in surface_events:
        key = (event["issue"], event["sha"])
        if key not in surface_by_release or event["at"] >= surface_by_release[key]["at"]:
            surface_by_release[key] = event
    surface_event_ids = {id(event) for event in surface_events}
    events = [event for event in events if id(event) not in surface_event_ids]
    for key, surface_event in surface_by_release.items():
        matches = [event for event in events if (event["issue"], event["sha"]) == key]
        if matches:
            target = max(matches, key=lambda event: event["at"])
            target["surface_covered"] = surface_event["surface_covered"]
            target["surface_covered_at"] = surface_event["surface_covered_at"]
        else:
            events.append(surface_event)
    return events if found_source else None


def uncovered_closes_7d(events, now):
    if events is None:
        return None
    since = now - timedelta(days=7)
    counted = {}
    for event in events:
        covered = event.get("surface_covered")
        if not isinstance(covered, bool):
            continue
        try:
            at = datetime.strptime(event.get("surface_covered_at") or event.get("at", ""), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except (TypeError, ValueError):
            continue
        if not since <= at <= now:
            continue
        counted[(event.get("issue"), event.get("sha"))] = (at, covered)
    if not counted:
        return None
    return sum(not covered for _, covered in counted.values())


def uncovered_closes_line(value):
    return f"uncovered closes (7d): {value if value is not None else 'NO-DATA'}"


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
    """Repair runs that followed a merge conflict in [since, now]: one per (unit, first write-start after the conflict).
    Two conflict events in one second (merge-tree sweep + "CI cannot start") share their repair and count once."""
    count = 0
    for unit in units:
        events = [(e.get("stage") or "", parse(e.get("at"))) for e in unit.get("history") or []]
        repairs = set()
        for i, (stage, at) in enumerate(events):
            if stage == "merge-conflict" and at and since <= at <= now:
                repairs.add(next((j for j in range(i + 1, len(events)) if events[j][0] == "write-start"), None))
        count += len(repairs - {None})
    return count


REVIEW_VERDICTS = ("review-approve", "review-request-changes", "review-block")
ID = "review.open_to_first_review_p90_min"
CRITERIA = {ID: ("review", "PR opened -> first review verdict minutes p90, 7 d (incl. waiting)", 60, 180, False)}
MEANING = {ID: "PR 开出到第一个评审结论的 p90 分钟，滚动 7 天，还在等第一次评审的 PR 按已等时间计：founder 合并前的真实等待，含评审员不可用、评审进程崩溃、停在 supervisor 路径的时间。"}
SOURCE = {ID: "units.json 每个 pr-opened → 之后第一个 review-approve / review-request-changes / review-block；停在 review-pending 的最新 PR 按 now 计"}
ROUND_ID = "review.rounds_per_merged"
REJECTION_ID = "review.first_round_rejections"
REJECTION_CAUSES = ("evidence", "format", "scope", "defect", "unknown")
CRITERIA.update({
    ROUND_ID: ("review", "review rounds per merged unit, 7 d", 1.32, 2.28, False),
    REJECTION_ID: ("review", "first-round rejections over 7 d", 0, -1, True),
})
MEANING.update({
    ROUND_ID: "过去 7 天合并单元的评审结论轮数总和 ÷ 合并单元数，含没有评审轮的合并单元。",
    REJECTION_ID: "过去 7 天首次评审被打回或阻塞的数量；detail 按 evidence、format、scope、defect、unknown 拆分，无法识别的原因保留为 unknown。",
})
SOURCE.update({
    ROUND_ID: "units.json 与 units-archive.json 去重后的 merged / landed 单元和合并前 review-approve / review-request-changes / review-block 事件；滚动 7 天。",
    REJECTION_ID: "units.json 与 units-archive.json 去重后的首条 review-approve / review-request-changes / review-block 事件时间与其 history.reason；滚动 7 天。",
})


def _review_events(unit, parse):
    events = []
    for index, event in enumerate(unit.get("history") or []):
        at = parse(event.get("at"))
        stage = event.get("stage") or event.get("ev") or ""
        if at and stage in REVIEW_VERDICTS:
            events.append((at, index, stage, event))
    return sorted(events)


def _rejection_cause(reason):
    value = str(reason or "").strip().casefold()
    if re.search(r"\b(?:scope|spec)\b", value):
        return "scope"
    for cause in REJECTION_CAUSES[:-1]:
        if re.search(rf"\b{cause}\b", value):
            return cause
    return "unknown"


def delivery_review_metrics(units, merged_units_30d, now, parse, include_rolling=False):
    cycles, approvals = [], []
    for unit, merged_at in merged_units_30d:
        reviews = sorted((at, event.get("stage")) for event in unit.get("history") or []
                         if event.get("stage") in REVIEW_VERDICTS and (at := parse(event.get("at"))) and at <= merged_at)
        approvals.append(sum(stage == "review-approve" for _, stage in reviews))
        first_approval = next((index for index, (_, stage) in enumerate(reviews) if stage == "review-approve"), None)
        if first_approval is not None:
            cycles.append(first_approval + 1)

    result = {"values": {
        "delivery.cycles_to_pass_30d": sum(cycles) / len(cycles) if cycles else None,
        "delivery.approvals_per_merge_30d": sum(approvals) / len(approvals) if approvals else None,
    }, "details": {}}
    if not include_rolling:
        return result

    since = now - timedelta(days=7)
    merged_units = [(unit, merged_at) for unit, merged_at in merged_units_30d if since <= merged_at <= now]
    round_count = sum(sum(at <= merged_at for at, _, _, _ in _review_events(unit, parse))
                      for unit, merged_at in merged_units)
    rejections = dict.fromkeys(REJECTION_CAUSES, 0)
    first_reviews = [events[0] for unit in units if (events := _review_events(unit, parse)) and since <= events[0][0] <= now]
    for _, _, stage, event in first_reviews:
        if stage != "review-approve":
            rejections[_rejection_cause(event.get("reason"))] += 1
    result["values"].update({ROUND_ID: round_count / len(merged_units) if merged_units else None,
                             REJECTION_ID: sum(rejections.values())})
    result["details"].update({
        "merged_units_7d": len(merged_units),
        "review_rounds_7d": round_count,
        "first_round_review_units_7d": len(first_reviews),
        "first_round_rejections": rejections,
    })
    return result


def first_review_waits(units, now, ts, window_hours=None):
    """Minutes from each pr-opened to its first review verdict over 7 days; a PR still in review-pending counts its age."""
    since, waits = now - (timedelta(hours=window_hours) if window_hours else timedelta(days=7)), []
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


UNCHANGED = "repair.unchanged_head_token_pct"
CLASSIFIED = ("changed", "unchanged", "unchanged-expected")
CRITERIA[UNCHANGED] = ("review-loop", "fresh tokens of repair runs that left the PR head unchanged, % of classified repair runs, 24 h", 5, 15, False)
MEANING[UNCHANGED] = "过去 24 小时内，返工运行里「PR head 没有变化」的那些花掉的新鲜 token 占全部已判定返工运行新鲜 token 的比例。跑完什么都没推出去的返工照样花 token，但不算交付；越低越好。head 判不出的运行（无 PR、没记起点、读不到远端）不计入，没有任何已判定的运行时读 NO-DATA，不读 0。「预期不变」的运行（已批准 head 上 CI 红后的返工、经确认的空发现回合）算已判定但不算浪费。"
SOURCE[UNCHANGED] = "units.json（含 units-archive.json）单元历史里 repair-delivered / repair-no-push 事件的 head_class 与 fresh_tokens（harvest 写入：派发时记的 PR head 对比结束时 origin 分支 head），事件时间固定滚动 24h；没有 head_class 的旧事件不读"


def unchanged_head_token_pct(units, now, ts, window_hours=None):
    """Share of fresh tokens spent on repair runs whose PR head did not move; None while no run in the window is classified."""
    since, spent, wasted = now - timedelta(hours=window_hours or 24), 0, 0
    for u in units:
        for h in u.get("history") or []:
            tokens, at = h.get("fresh_tokens"), ts(h.get("at"))
            if h.get("stage") in ("repair-delivered", "repair-no-push") and h.get("head_class") in CLASSIFIED \
                    and isinstance(tokens, int) and at and since <= at <= now:
                spent += tokens
                wasted += tokens if h["head_class"] == "unchanged" else 0
    return 100 * wasted / spent if spent else None


def metrics(units, now, ts, window_hours=None, sample_counts=None):
    waits = sorted(first_review_waits(units, now, ts, window_hours))
    if sample_counts is not None:
        sample_counts[ID] = len(waits)
    return {ID: waits[min(len(waits) - 1, int(round(.9 * (len(waits) - 1))))] if waits else None,
            UNCHANGED: unchanged_head_token_pct(units, now, ts, window_hours)}
