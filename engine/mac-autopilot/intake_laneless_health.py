"""Intake health for open product issues that have no lane label."""
import json, os
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
        "仅带 recut_children 的 tracker 按子票判断，路线图容器先排除；子票号与同一份开放 issue 列表匹配；结果缓存在 runtime，每 DEP_CHECK_SECONDS（默认 600 秒）最多请求一次"),
}

LANE_LABELS = frozenset({
    "needs-triage", "ready-for-agent", "on-hold", "awaiting-release", "needs-recut", "needs-info",
    "needs-advisor", "needs-owner", "ready-for-human", "awaiting-pipeline-sync", "hotfix", "finish-first",
})
# Roadmap labels mark planning containers even when sweep transitions also add tracker.
ROADMAP_CONTAINER_LABELS = frozenset({"roadmap-epic", "roadmap-theme", "roadmap"})
CONTAINER_LABELS = ROADMAP_CONTAINER_LABELS | {"tracker"}


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


def _tracker_has_open_children(agent_home, issue_number, open_issue_numbers):
    path = Path(agent_home) / "state" / f"{issue_number}.json"
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return False
    except (OSError, ValueError):
        return None
    if not isinstance(state, dict):
        return None
    if "recut_children" not in state:
        return False
    children = state["recut_children"]
    if not isinstance(children, list) or any(
        not isinstance(child, int) or isinstance(child, bool) or child <= 0 for child in children
    ):
        return None
    return any(child in open_issue_numbers for child in children)


def open_laneless_count(runtime, repo, now, gh_json, agent_home):
    """Count mature laneless product issues from a cached, paginated REST list read."""
    if not isinstance(repo, str) or not repo.strip():
        return None
    try:
        interval = max(0, int(os.environ.get("DEP_CHECK_SECONDS", "600")))
    except ValueError:
        interval = 600
    path = Path(runtime) / "intake-laneless-open-issues.json"
    now_epoch = int(now.timestamp())
    cached = _read_cache(path)
    checked_at = cached.get("checked_at")
    if cached.get("repo") == repo and isinstance(checked_at, int) and 0 <= now_epoch - checked_at < interval:
        count = cached.get("count")
        return count if isinstance(count, int) and not isinstance(count, bool) and count >= 0 else None

    # Persist the attempt before the network call too, so a failed request is not retried every tick.
    snapshot = {"repo": repo, "checked_at": now_epoch, "count": None}
    if not _write_cache(path, snapshot):
        return None
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    cutoff = now - timedelta(minutes=60)
    response = gh_json([
        "api", "--paginate", "--slurp", "--method", "GET",
        f"repos/{repo}/issues?state=open&per_page=100",
    ], 30)
    count = None
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
            for issue in open_issues:
                labels = issue.get("labels")
                if not isinstance(labels, list):
                    count = None
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
                if names.intersection(ROADMAP_CONTAINER_LABELS):
                    continue
                if names.intersection(LANE_LABELS):
                    continue
                if "tracker" in names.intersection(CONTAINER_LABELS):
                    has_open_children = _tracker_has_open_children(
                        agent_home, issue["number"], open_issue_numbers)
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
    return count if _write_cache(path, snapshot) else None
