"""Flow rows for the oldest never-started ready-for-agent issue and the oldest supervisor-review unit.

Kept out of node_health.py, which is at its size-ratchet baseline."""
import os

CRITERIA = {
    "flow.ready_unstarted_age_hours": ("flow", "oldest ready-for-agent issue no unit has started, hours since it became ready", 4, 24, False),
    "flow.supervisor_review_oldest_hours": ("flow", "oldest unit in supervisor-review, hours since it entered the stage", 2, 4, False),
}
MEANING = {
    "flow.ready_unstarted_age_hours": "ready-for-agent 但从未开工（无单元）的 issue 中最老的一张，自进入 ready-for-agent 起的小时数。高 = 票躺在候选里没人接，派发没碰到它。",
    "flow.supervisor_review_oldest_hours": "supervisor-review 阶段最老的一张单，自进入该阶段起的小时数。高 = 等 supervisor 决定的单长期没人定，去单元表找 id。",
}
SOURCE = {
    "flow.ready_unstarted_age_hours": "intake-candidates.json 候选 issue 中，无单元且 state/N.json 仍为 ready-for-agent 的，取 now − state_changed_at 的最大值；没有候选快照时为空，无此类 issue 时为 0",
    "flow.supervisor_review_oldest_hours": "units.json 在途单中 stage 为 supervisor-review 的，取 now − 最后事件时间 的最大值（wip_age 同口径）",
}


def ready_unstarted_age(runtime, agent_home, units, now, ts, read_json):
    """Oldest ready-for-agent issue that no unit has started (census row, no unit, state still ready-for-agent).

    Age runs from state_changed_at, the time the issue entered ready-for-agent. None without a census."""
    rows = read_json(os.path.join(runtime, "intake-candidates.json")).get("rows")
    if rows is None:
        return None
    oldest = 0.0
    for row in rows.splitlines():
        n = row.split("\t", 1)[0]
        if not n.isdigit() or any(u.get("issue") == int(n) or u.get("branch") == f"agent/issue-{n}" for u in units):
            continue
        state = read_json(os.path.join(agent_home, "state", f"{n}.json"))
        since = ts(state.get("state_changed_at"))
        if state.get("state", "ready-for-agent") == "ready-for-agent" and since:
            oldest = max(oldest, (now - since).total_seconds() / 3600)
    return round(oldest, 1)


def supervisor_review_oldest(wip_rows):
    """Age of the oldest unit in supervisor-review, from the wip_age rows (same clock as the stage p90)."""
    rows = [r for r in wip_rows if r["stage"] == "supervisor-review" and r["oldest"]]
    return rows[0]["oldest"][0]["age_hours"] if rows else None
