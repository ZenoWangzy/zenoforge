"""Collect and summarize the ready-for-agent issue queue."""
import json
import os


CLASS_INFO = {
    "tracker": ("前置跟踪票", "跟踪票交付或相关 PR 合入后自动继续。"),
    "no-blocker-recorded": ("未记录前置", "没有可等待的前置事项；下次调度会恢复派发。"),
    "chain-on-ready-issue": ("依赖另一张待实现票", "前置票交付后自动继续；链尾开始实现后会逐级释放。"),
    "blocker-state-unavailable": ("前置状态文件缺失", "缺少本地状态文件；前置票在 GitHub 交付或关闭后自动继续。"),
    "other-predecessor": ("等待前置交付", "前置票交付或关闭后自动继续；确认无法交付时转自动裁决。"),
    "waiting-predecessor": ("等待前置交付", "前置票交付后自动继续；确认无法交付时转自动裁决。"),
    "recut-refused-unpushed": ("拆票被未推送改动挡住", "仲裁上限内自动派回原单元提交改动；触顶时按默认路由停放。"),
    "ticket-stop-loss": ("达到单票止损", "票据更新或预算提高后自动恢复一次派发。"),
    "recut-children": ("等待拆出的子票", "所有子票交付后自动完成父票。"),
    "dep-dead-repeat": ("前置票重复失效", "只有前置票之后确实交付才会自动解除；无法交付时保持终止停放。"),
    "repair-breaker": ("连续修复未产出提交", "自动仲裁重新评估；可继续修复或重拆，仍受仲裁上限约束。"),
    "supervisor-arbitration-cap": ("等待终局自动裁决", "调度器继续终局裁决并按结果恢复、重拆或停放。"),
    "supervisor-cap-triage-reask": ("重问一次终局裁决", "调度器自动重问一次；仍无效时采用默认路由。"),
    "supervisor-cap-founder": ("等待停损暂挂解除", "停损暂挂自动结束后，调度器恢复一次仲裁；暂挂未结束时继续停放。"),
    "supervisor-cap-exhausted": ("自动仲裁预算耗尽", "已按默认路由停放；不会再消耗仲裁轮次。"),
    "token-hard-park": ("达到硬令牌上限", "永久停放；没有自动释放事件。"),
    "main-red": ("主线检查失败", "主线上的相同检查通过后自动恢复并重新检查。"),
    "session-owned": ("由现有会话持有", "持有该 PR 的会话合入或关闭 PR 后继续。"),
    "supervisor-budget": ("仲裁预算耗尽", "已按自动默认决策停放；不再消耗仲裁轮次。"),
    "other-parked": ("其他停放", "暂未识别自动解除事件；此类目前不能保证会自行恢复。"),
}


def _cache_get(path, now, max_age):
    try:
        with open(path, encoding="utf-8") as stream:
            cached = json.load(stream).get("github")
    except (OSError, ValueError, AttributeError):
        return None, None
    if isinstance(cached, dict) and isinstance(cached.get("stages"), list) and isinstance(cached.get("fetched_epoch"), (int, float)):
        age = now - cached["fetched_epoch"]
        if 0 <= age < max_age:
            return cached, age
    return None, None


def _fetch_ready_numbers(run, root):
    issues = json.loads(run(["gh", "issue", "list", "--state", "open", "--label", "ready-for-agent", "--limit", "1000", "--json", "number"], 30, cwd=root))
    if not isinstance(issues, list):
        raise RuntimeError("GitHub ready issue list is not an array")
    return [item["number"] for item in issues if isinstance(item, dict) and isinstance(item.get("number"), int) and not isinstance(item.get("number"), bool)]


def _write_cache(path, cached):
    try:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as out:
            json.dump({"github": cached}, out, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError:
        pass


def github_stages(now, front_stages, cache_path, root, run, error, cache_seconds=300, stale_seconds=1800):
    cached, age = _cache_get(cache_path, now, cache_seconds)
    if cached:
        ready_numbers, ready_error = cached.get("ready_issue_numbers"), None
        if not isinstance(ready_numbers, list):
            try:
                ready_numbers = _fetch_ready_numbers(run, root)
                _write_cache(cache_path, dict(cached, ready_issue_numbers=ready_numbers))
            except Exception as ex:
                ready_numbers, ready_error = None, error(ex)
        return cached["stages"], ready_numbers, {"cached": True, "stale": False, "age_s": int(age), "error": None, "ready_error": ready_error}
    try:
        query = ("query($owner:String!,$name:String!){repository(owner:$owner,name:$name){" +
                 "".join(f'a{i}:issues(states:OPEN,labels:["{row[0]}"],first:10,orderBy:{{field:UPDATED_AT,direction:ASC}})'
                         "{totalCount nodes{number title createdAt updatedAt}} " for i, row in enumerate(front_stages)) + "}}")
        payload = json.loads(run(["gh", "api", "graphql", "-F", "owner={owner}", "-F", "name={repo}", "-f", "query=" + query], 30))
        repo = ((payload or {}).get("data") or {}).get("repository") if isinstance(payload, dict) else None
        if not isinstance(repo, dict):
            first = ((payload.get("errors") or [{}])[0].get("message") if isinstance(payload, dict) else None) or "GitHub 返回无数据"
            raise RuntimeError(str(first)[:200])
        stages = []
        for i, row in enumerate(front_stages):
            block = repo.get(f"a{i}") or {}
            node = (block.get("nodes") or [None])[0] or {}
            stages.append({"label": row[0], "count": block.get("totalCount"),
                           "oldest": {"number": node.get("number"), "created_at": node.get("createdAt"), "updated_at": node.get("updatedAt")} if node else None,
                           "items": [{"number": n.get("number"), "title": (n.get("title") or "")[:60], "updated_at": n.get("updatedAt")} for n in block.get("nodes") or []]})
        if all(stage["count"] is None for stage in stages):
            raise RuntimeError("GitHub 返回的阶段计数为空")
        ready_numbers = _fetch_ready_numbers(run, root)
        fresh = {"fetched_epoch": now, "stages": stages, "ready_issue_numbers": ready_numbers}
        _write_cache(cache_path, fresh)
        return stages, ready_numbers, {"cached": False, "stale": False, "age_s": 0, "error": None, "ready_error": None}
    except Exception as ex:
        stale, age = _cache_get(cache_path, now, stale_seconds)
        if stale:
            return stale["stages"], stale.get("ready_issue_numbers"), {"cached": True, "stale": True, "age_s": int(age), "error": error(ex), "ready_error": None}
        raise


def _issue_number(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def _blocked_class(unit, ready_numbers, read_json, agent_home):
    blocker = _issue_number(unit.get("blocked_on"))
    if blocker is None:
        return "no-blocker-recorded"
    if blocker in ready_numbers:
        return "chain-on-ready-issue"
    state = read_json(os.path.join(agent_home, "state", f"{blocker}.json")) or {}
    if not state:
        return "blocker-state-unavailable"
    if state.get("state") == "tracker":
        return "tracker"
    return "other-predecessor"


def _parked_class(unit):
    reason = unit.get("parked_reason")
    if reason in CLASS_INFO:
        return reason
    if reason in (None, "") and _issue_number(unit.get("blocked_on")):
        return "waiting-predecessor"
    return "other-parked"


def summarize(total, ready_issue_numbers, units, read_json, agent_home):
    """Return the ready queue split; count each issue once even if it has duplicate units."""
    if (not isinstance(total, int) or isinstance(total, bool) or total < 0
            or not isinstance(ready_issue_numbers, list)):
        return None
    issue_numbers = [_issue_number(value) for value in ready_issue_numbers]
    ready_numbers = set(issue_numbers)
    if None in ready_numbers or len(issue_numbers) != total or len(ready_numbers) != total:
        return None
    held = {}
    active = set()
    for unit in units:
        issue = _issue_number(unit.get("issue"))
        if issue not in ready_numbers:
            continue
        stage = unit.get("stage")
        if stage == "blocked-external":
            key = _blocked_class(unit, ready_numbers, read_json, agent_home)
        elif stage == "parked":
            key = _parked_class(unit)
        else:
            active.add(issue)
            continue
        held.setdefault(issue, key)
    active.difference_update(held)
    counts = {}
    for key in held.values():
        counts[key] = counts.get(key, 0) + 1
    classes = [{"key": key, "name": CLASS_INFO[key][0], "count": counts[key], "reason": CLASS_INFO[key][1]}
               for key in CLASS_INFO if counts.get(key)]
    held_count = len(held)
    active_count = len(active)
    return {"total": total, "dispatchable": total - held_count - active_count,
            "active": active_count, "held": held_count, "classes": classes}


def add_front_data(front, now, ready_total, front_stages, cache_path, root, run, error,
                   cache_seconds, stale_seconds, units, read_json, agent_home, front_std, front_values):
    """Attach the ready queue split and its health metric to the front dashboard."""
    _, ready_numbers, meta = github_stages(now, front_stages, cache_path, root, run, error, cache_seconds, stale_seconds)
    ready = summarize(ready_total, ready_numbers, units, read_json, agent_home)
    front["ready_queue"] = ready
    if ready is None:
        front["errors"]["ready_queue"] = meta.get("ready_error") or "ready issue labels unavailable"
    front_std("ready_queue.dispatchable", "待实现可派发票数量", 60, 150, False, "个",
              "ready 标签下没有现有单元、阻塞或停放的开放票数；这是可以新开工的积压。",
              "GitHub ready issue list 与 units.json 的派发状态拆分")
    front_values["ready_queue.dispatchable"] = ready.get("dispatchable") if ready else None
