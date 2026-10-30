"""Dashboard data for recently finished workers and the factory's trend over time.
Reuses the worker ROI ledger (roi_ledger.read_events) and the per-ticket rollup (roi_rollup.tickets_report);
nothing is estimated: a day with no data is None. Cost in dollars is left out because most rows are unpriced."""
import calendar, json, os, re, statistics, time
from datetime import datetime, timedelta, timezone

import roi_ledger

OK_STAGES = {"merged", "landed", "done"}
BAD_STAGES = {"parked", "blocked-external", "needs-human", "supervisor-review"}
# (epoch, label) fixed history that no directory records; later pin bumps come from engine-versions mtimes
LINE_B_FLIP = ("2026-10-30T12:00:00Z", "Line B 切换：引擎改由 Zenoforge 构建")


def _epoch(iso):
    try: return calendar.timegm(time.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S"))
    except Exception: return None


def _event_tokens(event):
    vals = [m.get("tokens") for m in event.get("models") or []]
    return sum(v for v in vals if isinstance(v, int)) if vals and all(isinstance(v, int) for v in vals) else None


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


def trend(events, tickets_report, units, versions_dir, days=14, now=None, max_workers=None):
    now = now or datetime.now(timezone.utc)
    day_list = [(now - timedelta(days=days - 1 - i)).strftime("%Y-%m-%d") for i in range(days)]
    idx = {d: i for i, d in enumerate(day_list)}
    outcome_of = {t["ticket"]: t.get("outcome") for t in tickets_report.get("tickets", [])}
    merged = [[] for _ in day_list]
    for t in tickets_report.get("tickets", []):
        if t.get("outcome") == "landed" and (t.get("landed_at") or "")[:10] in idx: merged[idx[t["landed_at"][:10]]].append(t)
    tok_all, tok_waste, tok_seen, wall_day = [0] * days, [0] * days, [False] * days, [0.0] * days
    for e in events:
        if e.get("event_type") != "unit-end" or e["ts"][:10] not in idx: continue
        wall_day[idx[e["ts"][:10]]] += e.get("wall_s") or 0
        tk = _event_tokens(e)
        if tk is None: continue
        i = idx[e["ts"][:10]]; tok_all[i] += tk; tok_seen[i] = True
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
    # The daily ROI line. Spend is tokens (most rows are unpriced); "accepted" is the landed count, a proxy until acceptance is counted per day.
    avail = [min(86400, now.timestamp() - _epoch(d + "T00:00:00Z")) for d in day_list]
    per_acc = [round(tok_all[i] / len(merged[i])) if merged[i] and tok_seen[i] else None for i in range(days)]
    daily = [
        {"id": "spend", "label": "花费（token，未折美元）", "better": "down", "fmt": "tok", "values": [tok_all[i] if tok_seen[i] else None for i in range(days)]},
        {"id": "accepted", "label": "合入单（代替验收数）", "better": "up", "fmt": "n", "values": [len(m) for m in merged]},
        {"id": "lead_p50", "label": "交付时长 p50", "better": "down", "fmt": "h", "values": [med([t["lead_hours"] for t in m if t.get("lead_hours") is not None]) for m in merged]},
        {"id": "idle", "label": "worker 空闲 %", "better": "down", "fmt": "pct",
         "values": [round(max(0, 100 - 100 * wall_day[i] / (max_workers * avail[i])), 1) if max_workers and avail[i] > 0 and wall_day[i] else None for i in range(days)]},
        {"id": "per_accepted", "label": "每张合入单花费", "better": "down", "fmt": "tok", "values": per_acc},
    ]
    marks = [{"epoch": int(_epoch(LINE_B_FLIP[0])), "label": LINE_B_FLIP[1]}] + _versions(versions_dir)
    return {"days": day_list, "series": series, "milestones": marks, "daily": daily,
            "retro": [day_list[i] for i in rising_runs(per_acc)]}


def retro_line(t, day):
    """One inbox line when spend per accepted rose on 3 consecutive days ending at `day`; None otherwise."""
    if day not in t["retro"]: return None
    i = t["days"].index(day); v = next(x for x in t["daily"] if x["id"] == "per_accepted")["values"][i - 2:i + 1]
    return f"roi-retro 日期={day} 每张合入单花费连续 3 天上升（token）：{v[0]} → {v[1]} → {v[2]}，按规则开复盘"


def collect(home, units, live_units, versions_dir, cache_path, now=None, traffic=None, max_workers=None):
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
    out["trend"] = trend(events, rep, units, versions_dir, now=now, max_workers=max_workers)
    return out


if __name__ == "__main__":
    # factory_trend.py retro <agent_home> <YYYY-MM-DD>: prints the retro line when the rule fires for that day (daily-perf-report.sh)
    import sys, roi_rollup
    _, cmd, home, day = sys.argv
    end = datetime.strptime(day, "%Y-%m-%d").replace(hour=23, minute=59, tzinfo=timezone.utc)
    rep = json.loads(json.dumps(roi_rollup.tickets_report(home, days=14), default=str))
    line = retro_line(trend(list(roi_ledger.read_events(home)), rep, [], "/nonexistent", now=end), day)
    if line: print(line)
