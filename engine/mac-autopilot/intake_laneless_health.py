"""Intake health for open product issues that have no lane, priority, or route label."""
import json, os, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

CRITERIA = {
    "intake.laneless_open_issues": (
        "intake", "open product issues without a lane label after 60 min", 0, 1, False),
}
MEANING = {
    "intake.laneless_open_issues": (
        "创建超过 60 分钟、仍开放且没有处理车道标签的产品工单数；路线图容器及仍有开放重切子票的父项不计入。"),
}
SOURCE = {
    "intake.laneless_open_issues": (
        "GitHub REST GET issues?state=open&per_page=100，用 --paginate 读完所有页；读取失败为 NO-DATA。"
        "tracker 按 recut_children 与 GitHub 原生子票判断（读取失败按仍有开放子票处理），路线图容器先排除；子票号与同一份开放 issue 列表匹配；结果缓存在 runtime，每 DEP_CHECK_SECONDS（默认 600 秒）最多请求一次"),
}

LANE_LABELS = frozenset({
    "needs-triage", "ready-for-agent", "on-hold", "awaiting-release", "needs-recut", "needs-info",
    "needs-advisor", "needs-owner", "ready-for-human", "awaiting-pipeline-sync", "hotfix", "finish-first",
})
# Roadmap labels mark planning containers even when sweep transitions also add tracker.
ROADMAP_CONTAINER_LABELS = frozenset({"roadmap-epic", "roadmap-theme", "roadmap"})
CONTAINER_LABELS = ROADMAP_CONTAINER_LABELS | {"tracker"}
PRIORITY_ROUTE_ID = "intake.priority_route_missing"
DEFAULT_PRIORITY_ROUTE_PREFIXES = {"priority": "priority:", "route": "route:"}


def _read_cache(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_cache(path, value):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(json.dumps(value), encoding="utf-8")
        os.replace(tmp, path)
        return True
    except OSError:
        try:
            tmp.unlink()
        except (OSError, UnboundLocalError):
            pass
        return False


def _native_sub_issue_open(gh_json, repo, issue_number):
    """True when GitHub lists an open native sub-issue, or when that read cannot prove there is none."""
    try:
        pages = gh_json(["api", "--paginate", "--slurp", "--method", "GET",
                         f"repos/{repo}/issues/{issue_number}/sub_issues?per_page=100"], 30)
    except Exception:
        pages = None
    children = [child for page in pages for child in page] if isinstance(pages, list) and all(
        isinstance(page, list) for page in pages) else None
    if children is None or any(not isinstance(child, dict) or child.get("state") not in ("open", "closed")
                                for child in children):
        print(f"intake-laneless: sub-issue read unavailable for #{issue_number}; keeping it out of laneless",
              file=sys.stderr)
        return True
    return any(child["state"] == "open" for child in children)


def _tracker_has_open_children(agent_home, issue_number, open_issue_numbers, gh_json, repo):
    path = Path(agent_home) / "state" / f"{issue_number}.json"
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        state = {}
    except (OSError, ValueError):
        return None
    if not isinstance(state, dict):
        return None
    children = state.get("recut_children")
    if children is not None:
        if not isinstance(children, list) or any(
            not isinstance(child, int) or isinstance(child, bool) or child <= 0 for child in children
        ):
            return None
        if any(child in open_issue_numbers for child in children):
            return True
    return _native_sub_issue_open(gh_json, repo, issue_number)


def _priority_route_config(runtime):
    config = _read_cache(Path(runtime) / "config.json")
    intake = config.get("intake_priority")
    intake = intake if isinstance(intake, dict) else {}
    labels = intake.get("labels")
    labels = labels if isinstance(labels, dict) else {}
    prefixes = {
        key: value if isinstance(value, str) and value else DEFAULT_PRIORITY_ROUTE_PREFIXES[key]
        for key, value in ((key, labels.get(key)) for key in DEFAULT_PRIORITY_ROUTE_PREFIXES)
    }
    live_at = intake.get("live_at")
    if not live_at:
        # Unset cutover: every issue is backlog and the row never turns red.
        return prefixes, None, True
    try:
        cutoff = datetime.fromisoformat(live_at.replace("Z", "+00:00"))
        if cutoff.tzinfo is None:
            cutoff = cutoff.replace(tzinfo=timezone.utc)
        cutoff = cutoff.astimezone(timezone.utc)
    except (AttributeError, TypeError, ValueError):
        return prefixes, None, False
    return prefixes, cutoff, True


def _open_issue_snapshot(runtime, repo, now, gh_json, agent_home):
    if not isinstance(repo, str) or not repo.strip():
        return None
    try:
        interval = max(0, int(os.environ.get("DEP_CHECK_SECONDS", "600")))
    except ValueError:
        interval = 600
    path = Path(runtime) / "intake-laneless-open-issues.json"
    now_epoch = int(now.timestamp())
    prefixes, priority_cutoff, priority_valid = _priority_route_config(runtime)
    config_key = {"prefixes": prefixes, "live_at": priority_cutoff.isoformat() if priority_cutoff else None,
                  "valid": priority_valid}
    cached = _read_cache(path)
    checked_at = cached.get("checked_at")
    if (cached.get("repo") == repo and isinstance(checked_at, int) and not isinstance(checked_at, bool)
            and 0 <= now_epoch - checked_at < interval
            and cached.get("priority_route_config") == config_key
            and "priority_route" in cached):
        return cached

    # Persist the attempt before the network call too, so a failed request is not retried every tick.
    snapshot = {"repo": repo, "checked_at": now_epoch, "count": None,
                "priority_route": None, "priority_route_config": config_key}
    if not _write_cache(path, snapshot):
        return None
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    cutoff = now - timedelta(minutes=60)
    try:
        response = gh_json([
            "api", "--paginate", "--slurp", "--method", "GET",
            f"repos/{repo}/issues?state=open&per_page=100",
        ], 30)
    except Exception:
        response = None
    count = None
    priority_route = None
    if isinstance(response, list) and response and all(isinstance(page, list) for page in response):
        open_issues = []
        for page in response:
            for issue in page:
                if not isinstance(issue, dict):
                    open_issues = None
                    break
                if "pull_request" in issue:
                    continue
                if issue.get("state") != "open":
                    open_issues = None
                    break
                number = issue.get("number")
                if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
                    open_issues = None
                    break
                open_issues.append(issue)
            if open_issues is None:
                break
        if open_issues is not None:
            open_issue_numbers = {issue["number"] for issue in open_issues}
            count = 0
            priority_route = ({"live_at": config_key["live_at"],
                               "active": {"priority": 0, "route": 0},
                               "backlog": {"priority": 0, "route": 0}}
                              if priority_valid else None)
            for issue in open_issues:
                labels = issue.get("labels")
                if not isinstance(labels, list):
                    count = priority_route = None
                    break
                names = set()
                for label in labels:
                    name = label if isinstance(label, str) else label.get("name") if isinstance(label, dict) else None
                    if not isinstance(name, str):
                        count = None
                        break
                    names.add(name)
                if count is None:
                    break
                if priority_route is not None:
                    try:
                        created_at = datetime.fromisoformat(issue["created_at"].replace("Z", "+00:00"))
                        if created_at.tzinfo is None:
                            created_at = created_at.replace(tzinfo=timezone.utc)
                        bucket = ("active" if priority_cutoff is not None
                                  and created_at.astimezone(timezone.utc) >= priority_cutoff else "backlog")
                    except (AttributeError, KeyError, TypeError, ValueError):
                        priority_route = None
                    if priority_route is not None:
                        for key, prefix in prefixes.items():
                            if not any(name.startswith(prefix) for name in names):
                                priority_route[bucket][key] += 1
                if names.intersection(ROADMAP_CONTAINER_LABELS):
                    continue
                if names.intersection(LANE_LABELS):
                    continue
                if "tracker" in names.intersection(CONTAINER_LABELS):
                    has_open_children = _tracker_has_open_children(
                        agent_home, issue["number"], open_issue_numbers, gh_json, repo)
                    if has_open_children is None:
                        count = None
                        break
                    if has_open_children:
                        continue
                try:
                    created_at = datetime.fromisoformat(issue["created_at"].replace("Z", "+00:00"))
                    if created_at.tzinfo is None:
                        created_at = created_at.replace(tzinfo=timezone.utc)
                except (KeyError, TypeError, ValueError):
                    count = None
                    break
                if created_at <= cutoff:
                    count += 1
    snapshot["count"] = count
    snapshot["priority_route"] = priority_route
    return snapshot if _write_cache(path, snapshot) else None


def open_laneless_count(runtime, repo, now, gh_json, agent_home):
    """Count mature laneless product issues from a cached, paginated REST list read."""
    snapshot = _open_issue_snapshot(runtime, repo, now, gh_json, agent_home)
    count = snapshot.get("count") if isinstance(snapshot, dict) else None
    return count if isinstance(count, int) and not isinstance(count, bool) and count >= 0 else None


def open_priority_route_counts(runtime, repo, now, gh_json, agent_home):
    """Count missing priority and route prefixes from the laneless row's cached issue read."""
    snapshot = _open_issue_snapshot(runtime, repo, now, gh_json, agent_home)
    counts = snapshot.get("priority_route") if isinstance(snapshot, dict) else None
    if not isinstance(counts, dict):
        return None
    for bucket in ("active", "backlog"):
        values = counts.get(bucket)
        if not isinstance(values, dict) or any(
            not isinstance(values.get(key), int) or isinstance(values.get(key), bool) or values[key] < 0
            for key in ("priority", "route")
        ):
            return None
    return counts


def add_front_priority_data(front, now, runtime, repo, run, root, agent_home, front_std, front_values):
    """Add the priority/route intake health row using the cached laneless issue read."""
    def gh_json(command, timeout):
        return json.loads(run(["gh", *command], timeout, cwd=root))

    try:
        counts = open_priority_route_counts(runtime, repo, datetime.fromtimestamp(now, timezone.utc), gh_json, agent_home)
    except Exception as error:
        counts = None
        front.setdefault("errors", {})["intake_priority"] = str(error).strip()[:240]
    front["priority_route"] = counts
    if counts is None:
        front.setdefault("errors", {}).setdefault("intake_priority", "GitHub issue labels or intake cutover unavailable")
    total = counts["active"]["priority"] + counts["active"]["route"] if counts is not None else None
    front_std(PRIORITY_ROUTE_ID, "Issues without priority", 0, 1, False, "missing labels",
              "Open issues created after intake priority went live that lack a priority or route label; older open issues are shown separately as backlog.",
              "GitHub REST GET issues?state=open&per_page=100; shared paginated intake issue cache")
    front_values[PRIORITY_ROUTE_ID] = total
