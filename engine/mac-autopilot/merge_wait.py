"""Health row merge.green_to_merge_max_min: last required check completed to merge, max over merged PRs in 24 h, both lanes."""
import json
import os
import re
import time
from datetime import datetime, timedelta, timezone

WINDOW_HOURS = 24
PAGES = 40  # 25 PRs a page (50 and 100 hit GitHub 504s, measured 2026-11-13); past 1,000 the read is NO-DATA, not cut short
TIMEOUT = 90  # total seconds for the whole read, retries included; 30 s was spent by one 504 page plus its retry (28.5 s, 11-13 03:35Z)
LAST_GOOD = "merge-wait-last-good.json"  # next to node-health.json: the last successful read, kept while the PR read fails
# Only the fields this row needs. It stays apart from pr_census: the census asks for the merge time and commit alone,
# because a wide query (reviews, commits) blanked its whole 30-day window on PRs over 100 commits (#646).
QUERY = ("query($q:String!,$after:String){search(query:$q,type:ISSUE,first:25,after:$after){"
         "pageInfo{hasNextPage endCursor} nodes{... on PullRequest{number mergedAt labels(first:20){nodes{name}} "
         "head:commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){totalCount "
         "nodes{... on CheckRun{name completedAt}}}}}}}}}}}")
CRITERIA = {"merge.green_to_merge_max_min": ("ci+merge", "last required check -> merged, max min, both lanes, 24 h", 15, 60, False)}
MEANING = {"merge.green_to_merge_max_min": "三个必需检查最后完成到合入的最长等待（全部合入的 PR，近 24 小时，按车道拆分写入 details）：等待要控制在分钟级，超过小时的要查根因。"}
SOURCE = {"merge.green_to_merge_max_min": "GitHub check-runs：required-pr-checks.json 三个检查的最晚 completedAt → PR mergedAt（merge_wait.py 自己的 24 小时窄查询，分页；读失败或被截断时沿用 24 小时内的上一次成功读数，details 写 stale_age_min 与失败类型 failure（rate-limit / 504 / timeout），没有可用旧值才是 NO-DATA；旧值存在运行目录的 merge-wait-last-good.json）；依据 factory-speed 的 pr-wait 报告与 2026-11-07 合并等待裁决"}


def _ts(value):
    try:
        return datetime.strptime(str(value)[:20], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def failure_kind(text):
    """rate-limit, a 5xx code such as 504, or error, from gh's stderr or a GraphQL errors body."""
    text = str(text)
    if re.search(r"rate.?limit", text, re.I):
        return "rate-limit"
    code = re.search(r"\b(50\d)\b", text)
    return code.group(1) if code else "error"


def _page(gh_json, args, deadline, fail=None):
    """One GraphQL page of search results; one retry on a failed call, both attempts inside the deadline.
    A failure's kind goes into fail["kind"]: gh_json may answer {"gh_failure": kind} (node_health does), None gives "error"."""
    kind = "timeout"  # the deadline ran out before another attempt
    for _ in range(2):
        left = deadline - time.monotonic()
        if left <= 0:
            break
        page = gh_json(args, left)
        search = ((page or {}).get("data") or {}).get("search") if isinstance(page, dict) else None
        if isinstance(search, dict):
            return search
        kind = (page.get("gh_failure") or (failure_kind(page["errors"]) if page.get("errors") else None) or "error") if isinstance(page, dict) else "error"
    if fail is not None:
        fail["kind"] = kind
    return None


def fetch(repo, cutoff, gh_json, timeout=TIMEOUT, fail=None):
    """Merged PRs since cutoff (YYYY-MM-DD) as number, mergedAt, labels, checks; None when a page fails twice, the pages run out, or the timeout is spent (kind in fail["kind"])."""
    deadline, rows, after = time.monotonic() + timeout, [], None
    for _ in range(PAGES):
        args = ["api", "graphql", "-f", f"query={QUERY}", "-f", f"q=repo:{repo} is:pr is:merged merged:>={cutoff}"]
        if after:
            args += ["-f", f"after={after}"]
        search = _page(gh_json, args, deadline, fail)
        if search is None:
            return None
        for node in search.get("nodes") or []:
            if not isinstance(node, dict) or node.get("number") is None:
                continue
            contexts = ((((((node.get("head") or {}).get("nodes") or [{}])[0]).get("commit") or {})
                         .get("statusCheckRollup") or {}).get("contexts") or {})
            checks = None if contexts.get("totalCount", 0) > 100 else contexts.get("nodes") or []  # None: no check data
            rows.append({"number": node["number"], "mergedAt": node.get("mergedAt"), "checks": checks,
                         "labels": [x.get("name") for x in (node.get("labels") or {}).get("nodes") or []]})
        info = search.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            return rows
        after = info.get("endCursor")
    if fail is not None:
        fail["kind"] = "pages-exhausted"
    return None


def green_to_merge(pr_rows, required, now):
    """Max minutes from the last required check to merge over both lanes; lanes and no-data PRs go to details."""
    if pr_rows is None or not required:
        return None, {"reason": "PR read truncated or failed, or required-pr-checks.json unavailable"}
    since = now - timedelta(hours=WINDOW_HOURS)
    lanes, no_data = {"factory": [], "session-owned": []}, 0
    for pr in pr_rows:
        merged = _ts(pr.get("mergedAt"))
        if merged is None or not since <= merged <= now:
            continue
        latest = {}
        for check in pr.get("checks") or []:
            at = _ts(check.get("completedAt")) if check.get("name") in required else None
            if at and (check["name"] not in latest or at > latest[check["name"]]):
                latest[check["name"]] = at
        if len(latest) < len(required):
            no_data += 1
            continue
        lane = "session-owned" if "session-owned" in (pr.get("labels") or []) else "factory"
        lanes[lane].append((round((merged - max(latest.values())).total_seconds() / 60, 1), pr["number"]))
    factory_max = max(lanes["factory"], default=None)
    session_max = max(lanes["session-owned"], default=None)
    overall = max(lanes["factory"] + lanes["session-owned"], default=None)
    return (overall[0] if overall else None), {
        "window_hours": WINDOW_HOURS, "factory_n": len(lanes["factory"]), "session_owned_n": len(lanes["session-owned"]),
        "no_check_data": no_data, "factory_max_pr": factory_max[1] if factory_max else None,
        "session_owned_max_min": session_max[0] if session_max else None,
        "session_owned_max_pr": session_max[1] if session_max else None}


def _last_good(path, now):
    """(value, details) of the last good read when it still falls inside the 24 h window, else None; details carry its age."""
    try:
        saved = json.load(open(path))
        age = (now - _ts(saved["at"])).total_seconds() / 60
        if saved["value"] is not None and 0 <= age <= WINDOW_HOURS * 60:
            return saved["value"], {**(saved.get("details") or {}), "stale": True, "stale_age_min": round(age, 1)}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        pass
    return None


def collect(repo, now, here, gh_json, last_good_path=None):
    """(metrics, details) for node_health: the row's value, and the lane split. A failed read keeps the last good value with its age."""
    try:
        required = json.load(open(os.path.join(here, "required-pr-checks.json"))).get("required")
    except (OSError, ValueError):
        required = None
    fail = {}
    rows = fetch(repo, (now - timedelta(hours=WINDOW_HOURS)).strftime("%Y-%m-%d"), gh_json, fail=fail)
    value, details = green_to_merge(rows, required, now)
    if rows is None:
        details["failure"] = fail.get("kind", "error")
        kept = _last_good(last_good_path, now) if last_good_path else None
        if kept:
            return {"merge.green_to_merge_max_min": kept[0]}, {**kept[1], "failure": details["failure"]}
    elif last_good_path and required:
        try:
            tmp = f"{last_good_path}.tmp"
            with open(tmp, "w") as out:
                json.dump({"at": f"{now:%Y-%m-%dT%H:%M:%SZ}", "value": value, "details": details}, out)
            os.replace(tmp, last_good_path)
        except OSError:
            pass
    return {"merge.green_to_merge_max_min": value}, details
