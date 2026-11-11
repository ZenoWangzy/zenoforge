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
        "创建超过 60 分钟、仍开放且没有处理车道标签的产品工单数；路线图容器不计入。"),
}
SOURCE = {
    "intake.laneless_open_issues": (
        "GitHub REST GET issues?state=open&per_page=100，用 --paginate 读完所有页；读取失败为 NO-DATA。"
        "结果缓存在 runtime，每 DEP_CHECK_SECONDS（默认 600 秒）最多请求一次"),
}

LANE_LABELS = frozenset({
    "needs-triage", "ready-for-agent", "on-hold", "awaiting-release", "needs-recut", "needs-info",
    "needs-advisor", "needs-owner", "ready-for-human", "awaiting-pipeline-sync", "hotfix",
})
# Roadmap labels mark planning containers, not product issues that can enter an intake lane.
CONTAINER_LABELS = frozenset({"roadmap-epic", "roadmap-theme", "roadmap"})


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


def open_laneless_count(runtime, repo, now, gh_json):
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
        count = 0
        for page in response:
            for issue in page:
                if not isinstance(issue, dict):
                    count = None
                    break
                if "pull_request" in issue:
                    continue
                if issue.get("state") != "open":
                    count = None
                    break
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
                if names.intersection(CONTAINER_LABELS) or names.intersection(LANE_LABELS):
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
            if count is None:
                break
    snapshot["count"] = count
    return count if _write_cache(path, snapshot) else None
