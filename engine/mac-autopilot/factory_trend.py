"""Dashboard data for recently finished workers and the factory's trend over time.
Reuses the worker ROI ledger (roi_ledger.read_events) and per-ticket cost calculation (roi_rollup._model_cost).
Unpriced records stay visible; null-model OpenAI costs are shown separately as estimates."""
import calendar, json, os, re, statistics, subprocess, time
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import roi_ledger
import roi_rollup

OK_STAGES = {"merged", "landed", "done"}
BAD_STAGES = {"parked", "blocked-external", "needs-human", "supervisor-review"}
# (epoch, label) fixed history that no directory records; later pin bumps come from engine-versions mtimes
LINE_B_FLIP = ("2026-10-30T12:00:00Z", "Line B 切换：引擎改由 Zenoforge 构建")
ACCEPTED_UNIT_STAGES = {"closed", "merged", "landed", "done"}
TERMINAL_UNIT_STAGES = ACCEPTED_UNIT_STAGES | {"wontfix", "duplicate"}


def _epoch(iso):
    try: return calendar.timegm(time.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S"))
    except Exception: return None


def _event_tokens(event):
    vals = [m.get("tokens") for m in event.get("models") or []]
    return sum(v for v in vals if isinstance(v, int)) if vals and all(isinstance(v, int) for v in vals) else None


def _event_cost(event, prices):
    """Return (priced USD, estimated USD, unpriced model rows) for one ledger event."""
    models = event.get("models") or []
    known, estimated, unpriced = Decimal(0), Decimal(0), 0
    if not models:
        return known, estimated, 1
    for model in models:
        if not isinstance(model, dict):
            unpriced += 1
            continue
        provider = model.get("provider")
        name = model.get("model")
        is_estimated = name is None and provider == "openai"
        if is_estimated:
            name = "gpt-6-luna"
        price = (prices.get("models") or {}).get(name) if isinstance(name, str) else None
        if not isinstance(provider, str) or not provider or not isinstance(price, dict) \
                or price.get("provider") != provider:
            unpriced += 1
            continue
        cost = roi_rollup._model_cost({**model, "model": name}, prices)
        if cost is None:
            unpriced += 1
            continue
        known += cost
        if is_estimated:
            estimated += cost
    return known, estimated, unpriced


def accepted_requirement(released, issue_state, unit_clean, workspace_clean):
    """Founder ruling: "已验收的需求就是tickets release了，并且清理好工作区了，该关的该清理的都做好了，恢复如初了。就验收了。"""
    return bool(released and issue_state == "CLOSED" and unit_clean and workspace_clean)


def _history_terminal_at(unit):
    stages = {"merged", "landed", "closed", "done", "issue-closed", "live-event-closed", "pr-merged"}
    history = [h for h in unit.get("history") or [] if h.get("stage") in stages and _epoch(h.get("at")) is not None]
    if not history and unit.get("stage") in ACCEPTED_UNIT_STAGES:
        history = [h for h in unit.get("history") or [] if _epoch(h.get("at")) is not None][-1:]
    return max((h["at"] for h in history), default=None)


def _branch_present(branch, refs):
    return bool(branch and any(ref == branch or ref.endswith("/" + branch) for ref in refs))


def accepted_requirements(release_events, units, worktrees, branch_refs, cleanup_times=None):
    """Issues whose release-close event and final unit/workspace state satisfy the founder ruling."""
    cleanup_times = cleanup_times or {"units": {}, "branches": {}}
    by_issue = {}
    for unit in units:
        if isinstance(unit.get("issue"), int):
            by_issue.setdefault(unit["issue"], []).append(unit)
    releases = {}
    for event in release_events or []:
        issue, at = event.get("issue"), event.get("at")
        if isinstance(issue, int) and _epoch(at) is not None:
            releases.setdefault(issue, []).append(at)

    accepted = []
    for issue, issue_releases in releases.items():
        issue_units = by_issue.get(issue) or []
        if not issue_units:
            continue
        release_at = min(issue_releases)
        released = True  # release-closer's `closed=[...]` rows are post-release closure evidence
        unit_clean = all(u.get("stage") in TERMINAL_UNIT_STAGES for u in issue_units)
        workspace_clean = worktrees is not None and branch_refs is not None and all(
            u.get("id") not in worktrees and not _branch_present(u.get("branch"), branch_refs)
            for u in issue_units
        )
        if not accepted_requirement(released, "CLOSED", unit_clean, workspace_clean):
            continue

        times = [release_at]
        for unit in issue_units:
            times.extend(value for value in (
                _history_terminal_at(unit),
                (cleanup_times.get("units") or {}).get(unit.get("id")),
                (cleanup_times.get("branches") or {}).get(unit.get("branch")),
            ) if _epoch(value) is not None)
        accepted.append({"issue": issue, "at": max(times)})
    return accepted


def _cleanup_times(runtime):
    """Latest logged worktree and branch removals, including the one rotated scheduler log."""
    out = {"units": {}, "branches": {}}
    for path in (os.path.join(runtime, "scheduler.log"), os.path.join(runtime, "scheduler.log.1")):
        try:
            with open(path, encoding="utf-8", errors="ignore") as source:
                lines = source.readlines()
        except OSError:
            continue
        for raw in lines:
            if len(raw) < 22 or not raw.startswith("[") or _epoch(raw[1:21]) is None:
                continue
            at = raw[1:21]
            worktree = re.search(r"cleanup worktree .*/wt-([^/\s]+)\s*$", raw)
            branch = re.search(r"cleanup local branch (\S+) \(upstream gone\)", raw)
            if worktree:
                key = worktree.group(1)
                out["units"][key] = max(at, out["units"].get(key, ""))
            if branch:
                key = branch.group(1)
                out["branches"][key] = max(at, out["branches"].get(key, ""))
    return out


def _workspace_snapshot(units, worktree_root, repo_root):
    worktrees = set()
    for unit in units:
        key = str(unit.get("id")) if unit.get("id") is not None else None
        if key and any(os.path.isdir(path) for path in (
            os.path.join(worktree_root, "wt-" + key), os.path.join("/tmp", "wt-" + key)
        )):
            worktrees.add(key)
    try:
        result = subprocess.run(
            ["git", "-C", repo_root, "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"],
            capture_output=True, text=True, timeout=15,
        )
        if result.returncode:
            return worktrees, None
        return worktrees, set(result.stdout.split())
    except (OSError, subprocess.TimeoutExpired):
        return worktrees, None


def outcome(stage):
    return "ok" if stage in OK_STAGES else "bad" if stage in BAD_STAGES else "none" if stage == "closed" else "run"


def archive(events, units, live_units, limit=12, traffic=None):
    """Newest finished worker runs: ticket, kind, backend, wall seconds, tokens, outcome of the work order they belong to."""
    by_id = {u.get("id"): u for u in units}
    rows = []
    for e in sorted((e for e in events if e.get("event_type") == "unit-end"), key=lambda e: e["ts"], reverse=True):
        key = (e.get("unit") or {}).get("key")
        if key in live_units: continue
        u = by_id.get(key) or {}
        tk = [t for t in e.get("tickets") or [] if isinstance(t, int)]
        m = re.search(r"\d{3,5}", str(key))
        rows.append({"task": (u.get("title") or key or "")[:60], "issue": u.get("issue") or (tk[0] if tk else int(m[0]) if m else None), "pr": u.get("pr"),
                     "kind": (e["unit"] or {}).get("stage"), "backend": (e["unit"] or {}).get("backend") or "",
                     "rx": ((traffic or {}).get("wt:" + str(key)) or {}).get("rx"), "tx": ((traffic or {}).get("wt:" + str(key)) or {}).get("tx"),
                     "wall_s": e.get("wall_s"), "tokens": _event_tokens(e), "end_epoch": _epoch(e["ts"]),
                     "outcome": outcome(u.get("stage")), "stage": u.get("stage") or "", "tip": f"{key} · {e['ts']}"})
        if len(rows) >= limit: break
    return rows


def _versions(dir_):
    out = []
    try: names = os.listdir(dir_)
    except OSError: return out
    for n in names:
        a, _, b = n.partition("-")
        if len(a) == 12 and len(b) == 12 and os.path.isdir(os.path.join(dir_, n, "engine")):
            out.append({"epoch": int(os.path.getmtime(os.path.join(dir_, n))), "label": f"引擎换版 zenoforge {a[:7]} · example {b[:7]}"})
    return sorted(out, key=lambda m: m["epoch"])


def rising_runs(values, n=3):
    """Indices of the days that end a run of n consecutive non-null values, each strictly above the one before."""
    return [i for i in range(n - 1, len(values))
            if all(v is not None for v in values[i - n + 1:i + 1]) and all(a < b for a, b in zip(values[i - n + 1:i], values[i - n + 2:i + 1]))]


def trend(events, tickets_report, units, versions_dir, days=14, now=None, max_workers=None, prices=None, accepted=None):
    now = now or datetime.now(timezone.utc)
    prices = prices or roi_ledger.load_prices(roi_rollup.PRICE_FILE)
    day_list = [(now - timedelta(days=days - 1 - i)).strftime("%Y-%m-%d") for i in range(days)]
    idx = {d: i for i, d in enumerate(day_list)}
    outcome_of = {t["ticket"]: t.get("outcome") for t in tickets_report.get("tickets", [])}
    merged = [[] for _ in day_list]
    for t in tickets_report.get("tickets", []):
        if t.get("outcome") == "landed" and (t.get("landed_at") or "")[:10] in idx: merged[idx[t["landed_at"][:10]]].append(t)
    accepted_day = [0] * days
    accepted_issues = set()
    for row in accepted or []:
        issue, at = row.get("issue"), row.get("at")
        day = (at or "")[:10]
        if isinstance(issue, int) and issue not in accepted_issues and day in idx:
            accepted_day[idx[day]] += 1
            accepted_issues.add(issue)
    tok_all, tok_waste, wall_day = [0] * days, [0] * days, [0.0] * days
    usd_day, estimated_usd_day, unpriced_day, spend_seen = [Decimal(0)] * days, [Decimal(0)] * days, [0] * days, [False] * days
    cost_rows_seen = [False] * days
    for e in events:
        if e.get("event_type") != "unit-end" or e["ts"][:10] not in idx: continue
        i = idx[e["ts"][:10]]
        wall_day[i] += e.get("wall_s") or 0
        cost_rows_seen[i] = True
        cost, estimated_cost, unpriced = _event_cost(e, prices)
        usd_day[i] += cost
        estimated_usd_day[i] += estimated_cost
        unpriced_day[i] += unpriced
        spend_seen[i] = spend_seen[i] or bool((e.get("models") or []) and unpriced < len(e.get("models") or []))
        tk = _event_tokens(e)
        if tk is None: continue
        tok_all[i] += tk
        ts = e.get("tickets") or []
        if ts and all(outcome_of.get(x) in ("closed-unmerged", "reverted") for x in ts): tok_waste[i] += tk
    first = [[0, 0] for _ in day_list]
    for u in units:
        for h in u.get("history") or []:
            if h.get("stage") in ("review-approve", "review-request-changes", "review-block"):
                if (h.get("at") or "")[:10] in idx:
                    first[idx[h["at"][:10]]][1] += 1; first[idx[h["at"][:10]]][0] += h["stage"] == "review-approve"
                break
    med = lambda xs: round(statistics.median(xs), 2) if xs else None
    series = [
        {"id": "merged", "label": "合入 / 天", "better": "up", "fmt": "n", "values": [len(m) for m in merged]},
        {"id": "wall", "label": "每张合入单的 worker 时长", "better": "down", "fmt": "h",
         "values": [med([t["wall_s"] / 3600 for t in m if t.get("wall_s")]) for m in merged]},
        {"id": "tokens", "label": "每张合入单的 token", "better": "down", "fmt": "tok",
         "values": [round(sum(t["tokens"] for t in m if t.get("tokens")) / n) if (n := sum(1 for t in m if t.get("tokens"))) else None for m in merged]},
        {"id": "waste", "label": "浪费占比（未合入单的 token）", "better": "down", "fmt": "pct",
         "values": [round(100 * w / a, 1) if a else None for w, a in zip(tok_waste, tok_all)]},
        {"id": "first_pass", "label": "一次评审通过率", "better": "up", "fmt": "pct",
         "values": [round(100 * a / b, 1) if b else None for a, b in first]},
    ]
    # The daily ROI line. Unpriced model rows remain visible beside API-list USD totals.
    avail = [min(86400, now.timestamp() - _epoch(d + "T00:00:00Z")) for d in day_list]
    spend = [round(float(usd_day[i]), 8) if spend_seen[i] else None for i in range(days)]
    estimates = [round(float(estimated_usd_day[i]), 8) if spend_seen[i] else None for i in range(days)]
    unpriced = [unpriced_day[i] if cost_rows_seen[i] else None for i in range(days)]
    per_acc = [round(spend[i] / accepted_day[i], 8) if spend[i] is not None and accepted_day[i] else None for i in range(days)]
    daily = [
        {"id": "spend", "label": "花费（美元）", "better": "down", "fmt": "usd", "values": spend},
        {"id": "estimated_usd", "label": "估算花费（美元）", "better": "down", "fmt": "usd", "values": estimates},
        {"id": "unpriced", "label": "未定价模型记录", "better": "down", "fmt": "n", "values": unpriced},
        {"id": "accepted", "label": "已验收需求", "better": "up", "fmt": "n", "values": accepted_day},
        {"id": "lead_p50", "label": "交付时长 p50", "better": "down", "fmt": "h", "values": [med([t["lead_hours"] for t in m if t.get("lead_hours") is not None]) for m in merged]},
        {"id": "idle", "label": "worker 空闲 %", "better": "down", "fmt": "pct",
         "values": [round(max(0, 100 - 100 * wall_day[i] / (max_workers * avail[i])), 1) if max_workers and avail[i] > 0 and wall_day[i] else None for i in range(days)]},
        {"id": "per_accepted", "label": "每条已验收需求花费", "better": "down", "fmt": "usd", "values": per_acc},
    ]
    marks = [{"epoch": int(_epoch(LINE_B_FLIP[0])), "label": LINE_B_FLIP[1]}] + _versions(versions_dir)
    return {"days": day_list, "series": series, "milestones": marks, "daily": daily,
            "retro": [day_list[i] for i in rising_runs(per_acc)]}


def retro_line(t, day):
    """One inbox line when USD per accepted requirement rose on 3 consecutive days ending at `day`; None otherwise."""
    if day not in t["retro"]: return None
    i = t["days"].index(day); v = next(x for x in t["daily"] if x["id"] == "per_accepted")["values"][i - 2:i + 1]
    money = lambda amount: f"${amount:.6f}" if abs(amount) < 0.01 else f"${amount:.2f}"
    return f"roi-retro 日期={day} 每条已验收需求花费连续 3 天上升（美元）：{' → '.join(money(amount) for amount in v)}，按规则开复盘"


def collect(home, units, live_units, versions_dir, cache_path, now=None, traffic=None, max_workers=None,
            runtime=None, worktree_root=None, repo_root=None):
    """Archive + trend; the per-ticket rollup shells out to GitHub once, so its result is cached for 15 minutes."""
    events = [e for e in roi_ledger.read_events(home)]
    out = {"archive": archive(events, units, live_units, limit=60, traffic=traffic)}
    try:
        if time.time() - os.path.getmtime(cache_path) < 900:
            rep = json.load(open(cache_path))
        else: raise OSError
    except (OSError, ValueError):
        import roi_rollup
        rep = json.loads(json.dumps(roi_rollup.tickets_report(home, days=14), default=str))
        with open(cache_path + ".tmp", "w") as f: json.dump(rep, f)
        os.replace(cache_path + ".tmp", cache_path)
    prices = roi_ledger.load_prices(roi_rollup.PRICE_FILE, os.path.join(home, "roi-prices.local.json"))
    runtime = runtime or os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR") \
        or os.path.join(home, "checkout", ".scratch-supervisor", "autopi")
    worktree_root = worktree_root or os.environ.get("MAC_AUTOPILOT_WT_ROOT") \
        or os.path.join(home, "autopilot-wt")
    repo_root = repo_root or os.environ.get("MAC_AUTOPILOT_ROOT") or os.path.join(home, "checkout")
    import node_health
    releases = node_health.release_acceptances(runtime) or []
    worktrees, branch_refs = _workspace_snapshot(units, worktree_root, repo_root)
    accepted = accepted_requirements(releases, units, worktrees, branch_refs, _cleanup_times(runtime))
    out["trend"] = trend(events, rep, units, versions_dir, now=now, max_workers=max_workers,
                         prices=prices, accepted=accepted)
    return out


if __name__ == "__main__":
    # factory_trend.py retro <agent_home> <YYYY-MM-DD>: prints the retro line when the rule fires for that day (daily-perf-report.sh)
    import sys, roi_rollup
    _, cmd, home, day = sys.argv
    end = datetime.strptime(day, "%Y-%m-%d").replace(hour=23, minute=59, tzinfo=timezone.utc)
    rep = json.loads(json.dumps(roi_rollup.tickets_report(home, days=14), default=str))
    line = retro_line(trend(list(roi_ledger.read_events(home)), rep, [], "/nonexistent", now=end), day)
    if line: print(line)
