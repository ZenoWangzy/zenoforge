#!/usr/bin/env bash

# Requirement output and waiting-stock facts for the owner report.

# maintainer_health_mail_ladder_facts <home> <now>
# Requirement output and the waiting stock, from the founder ladder and GitHub.
# The ladder is the supervisor-inbox trail (lines "founder-req #N <from> → <to>",
# one per stage change) plus founder-req-stage.json (the stage held now).
# - finished: a requirement counts on the day its delivering pull request merged
#   (the pipeline's `merged` metric events name the pull request; GitHub gives
#   the merge time). Counted for the last day and the day before, the last 7
#   days and the 7 before; a period that starts before the trail's first line
#   is null, since the ladder cannot vouch for it.
# - shipped: first stage change to 上线, from the trail.
# - stock: requirements held at 进 main whose issue is still open, now, a day ago
#   and a week ago on the same basis: merged before then, not yet shipped, and
#   open then (a closed issue is out of the stock from its close time).
# One bounded GitHub read (pull request merge times and issue state in one
# query). If it fails, finished and stock are null and the renderer drops them.
# {finished:{day,prev_day,week,prev_week}|null, shipped:{...}, stock:{now,day_ago,week_ago}} or null without a trail.
maintainer_health_mail_ladder_facts() {
  local home="$1" now="$2"
  python3 - "$home" "$now" "${REPO:-}" <<'PY'
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

home, now, repo = sys.argv[1], int(sys.argv[2]), sys.argv[3]
DAY = 86400
LADDER = {"新增": -1, "提出": 0, "热修生效": 1, "进 main": 2, "上线": 3, "真人验收": 4}
pattern = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) (?:founder-req )+#([1-9]\d*) ([^：]+)：")

def epoch(stamp):
    return int(datetime.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp())

rows = []
try:
    with open(os.path.join(home, "supervisor-inbox"), encoding="utf-8", errors="replace") as source:
        for line in source:
            match = pattern.match(line)
            steps = match.group(3).split(" → ") if match else []
            if len(steps) != 2 or steps[0] not in LADDER or steps[1] not in LADDER:
                continue
            rows.append((epoch(match.group(1)), int(match.group(2)), LADDER[steps[0]], LADDER[steps[1]]))
except (OSError, ValueError):
    pass
if not rows:
    print("null")
    raise SystemExit(0)
first_seen = min(row[0] for row in rows)

def first_reached(level):
    reached = {}
    for at, issue, was, to in rows:
        if was < level <= to and at < reached.get(issue, now + 1):
            reached[issue] = at
    return reached

def periods(times):
    def count(start, end):
        return sum(start <= at < end for at in times) if start >= first_seen else None
    return {"day": count(now - DAY, now), "prev_day": count(now - 2 * DAY, now - DAY),
            "week": count(now - 7 * DAY, now), "prev_week": count(now - 14 * DAY, now - 7 * DAY)}

shipped_at = first_reached(3)
result = {"finished": None, "shipped": periods(sorted(shipped_at.values())),
          "stock": {"now": None, "day_ago": None, "week_ago": None}}

def read_stages():
    try:
        with open(os.path.join(home, "founder-req-stage.json"), encoding="utf-8") as source:
            stages = json.load(source)
    except (OSError, ValueError):
        return None
    if isinstance(stages, dict) and all(isinstance(v, int) and not isinstance(v, bool) for v in stages.values()):
        return {int(k): v for k, v in stages.items()}
    return None

def pipeline_prs(stages):
    """{issue: [(pull request number, recorded time)]} for requirements past the main line, last 16 days only."""
    cutoff, prs, old = now - 16 * DAY, {}, set()
    months = {datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m") for t in (cutoff, now)}
    for month in months:
        try:
            with open(os.path.join(home, "metrics", f"efficiency-{month}.jsonl"), encoding="utf-8", errors="replace") as source:
                for line in source:
                    if '"merged"' not in line:
                        continue
                    try:
                        row = json.loads(line)
                        issue, number, at = int(row["issue"]), int(row["pr_number"]), epoch(row["ts"])
                    except (ValueError, KeyError, TypeError):
                        continue
                    if row.get("event_type") != "merged" or stages.get(issue, 0) < 2:
                        continue
                    if at < cutoff:
                        old.add(issue)
                    else:
                        prs.setdefault(issue, set()).add(number)
        except OSError:
            pass
    return prs, old

def github(prs, issues):
    """{(kind, number): node} from one bounded query, or None. Missing pull requests come back null."""
    owner, _, name = repo.partition("/")
    if not owner or not name:
        return None
    fields = [f"p{n}: pullRequest(number: {n}) {{ mergedAt }}" for n in sorted(prs)]
    fields += [f"i{n}: issue(number: {n}) {{ state closedAt }}" for n in sorted(issues)]
    query = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { " + " ".join(fields) + " } }"
    try:
        done = subprocess.run(["gh", "api", "graphql", "-F", f"owner={owner}", "-F", f"name={name}", "-f", f"query={query}"],
                              capture_output=True, text=True, timeout=30)
        node = json.loads(done.stdout)["data"]["repository"]
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
        return None
    return node if isinstance(node, dict) else None

stages = read_stages()
if stages is not None:
    prs, old = pipeline_prs(stages)
    waiting = {n for n, v in stages.items() if v == 2}
    recent_ship = {n for n, at in shipped_at.items() if stages.get(n, 0) >= 3 and at >= now - 7 * DAY}
    wanted = {n for n, v in stages.items() if v >= 2 and n in prs}
    node = github({pr for n in wanted for pr in prs[n]}, waiting | recent_ship)
    if node is not None:
        merged = {}
        for n in wanted:
            times = [epoch(node[f"p{pr}"]["mergedAt"]) for pr in prs[n] if isinstance(node.get(f"p{pr}"), dict) and node[f"p{pr}"].get("mergedAt")]
            if times:
                merged[n] = min(times)
        for n in old:
            merged[n] = 0  # merged before any period shown
        trail = first_reached(2)
        # A waiting requirement with no merge record at all was already on the main line when the trail began.
        for n in waiting | recent_ship:
            merged.setdefault(n, trail.get(n, 0))
        result["finished"] = periods([t for n, t in merged.items() if stages.get(n, 0) >= 2 and t > 0])

        def held_at(moment):
            total = 0
            for n in waiting | recent_ship:
                if merged[n] >= moment or (n in recent_ship and shipped_at[n] < moment):
                    continue
                issue = node[f"i{n}"]
                closed = issue.get("closedAt")
                if issue.get("state") == "OPEN" or (closed and epoch(closed) >= moment):
                    total += 1
            return total
        if all(isinstance(node.get(f"i{n}"), dict) for n in waiting | recent_ship):
            result["stock"] = {"now": held_at(now),
                               "day_ago": held_at(now - DAY) if now - DAY >= first_seen else None,
                               "week_ago": held_at(now - 7 * DAY) if now - 7 * DAY >= first_seen else None}
print(json.dumps(result, separators=(",", ":")))
PY
}
