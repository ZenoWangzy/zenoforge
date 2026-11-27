import json, os, time
from pathlib import Path

CRITERIA = {
    "gh_budget.graphql_used_per_hour": ("github", "GraphQL points used in the current hourly window", 600, 2500, False),
    "gh_budget.rest_used_per_hour": ("github", "REST requests used in the current hourly window", 2000, 3500, False),
}
MEANING = {
    "gh_budget.graphql_used_per_hour": "GitHub GraphQL points used in the current rate-limit hour; over 2,500 alerts.",
    "gh_budget.rest_used_per_hour": "GitHub REST requests used in the current rate-limit hour; over 3,500 alerts.",
}
SOURCE = {
    "gh_budget.graphql_used_per_hour": "AGENT_HOME/metrics/gh-budget-YYYY-MM.jsonl, latest rate_limit sample",
    "gh_budget.rest_used_per_hour": "AGENT_HOME/metrics/gh-budget-YYYY-MM.jsonl, latest rate_limit sample",
}


def _read(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _epoch(now):
    if now is None:
        return int(time.time())
    return int(now.timestamp()) if hasattr(now, "timestamp") else int(now)


def collect(agent_home, now=None):
    result = {metric: None for metric in CRITERIA}
    sample = _read(Path(agent_home) / "state" / "gh-budget.latest.json")
    sampled_epoch = sample.get("sampled_epoch")
    resources = sample.get("resources")
    current = _epoch(now)
    if type(sampled_epoch) is not int or current < sampled_epoch or current - sampled_epoch > 120 or not isinstance(resources, dict):
        return result
    for resource, metric in (("graphql", "gh_budget.graphql_used_per_hour"), ("core", "gh_budget.rest_used_per_hour")):
        values = resources.get(resource)
        used = values.get("used") if isinstance(values, dict) else None
        if type(used) is int and used >= 0:
            result[metric] = used
    return result


def hourly_rollup(agent_home):
    rollups = _read(Path(agent_home) / "state" / "gh-budget-hourly.latest.json")
    result = {}
    for resource in ("graphql", "rest"):
        row = rollups.get(resource)
        if isinstance(row, dict) and type(row.get("reset")) is int and type(row.get("used")) is int:
            result[resource] = {"reset": row["reset"], "used": row["used"], "sampled_at": row.get("sampled_at")}
    return result
