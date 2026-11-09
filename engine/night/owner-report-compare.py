#!/usr/bin/env python3
"""Owner report: station efficiency, daily snapshots, day and week comparison, and causes.

Subcommands (facts JSON on stdin where noted; every answer is JSON on stdout):
  station <runtime_dir> <now>                          rows from node-health.json and station-health.json, or null
  compare <snapshot_dir> <now> <repo_root> <owners>    facts -> readable lines and structured chart facts
  spend <agent_home> <start> <end>                    recorded totals by model, or null
  merges <agent_home> <now>                          product merge counts for three report periods
  write <snapshot_dir> <now>                           facts -> store today's snapshot unless one exists
  backfill <snapshot_dir> <T> <agent_home> <runtime>   facts at T -> store that day's snapshot unless one exists

A snapshot is one file per Beijing day: <snapshot_dir>/YYYY-MM-DD.json = {schema, day, at, figures}.
Missing comparisons are dropped; a cause without evidence reads 原因未查明.
"""
import json
import glob
import os
import re
import sys
from datetime import datetime, timedelta, timezone

# A change is material when it moved at least this share of yesterday's figure (a base of zero counts any
# movement). PROVISIONAL: a first value chosen 2026-11-07, not measured; below 30 % a daily count of ten moves
# by three on ordinary days. Tune it once a few weeks of snapshots show how much a normal day moves.
MATERIAL_CHANGE_RATIO = 0.3
MAX_CAUSE_LINES = 4
STATION_FRESH_SECONDS = 6 * 3600
DAY = 86400
BEIJING = timezone(timedelta(hours=8))

# key, name, node-health metric id, unit, phrase before the figure. The standard is the metric's own healthy bound.
STATIONS = [
    ("intake", "取件", "intake.out_per_day", "个", "过去一天接手 "),
    ("triage", "分诊", "triage.out_per_day", "个", "过去一天处理 "),
    ("advisor", "顾问裁定", "advisor.out_per_day", "个", "过去一天裁定 "),
    ("implement", "写代码", "implement.out_per_day", "次", "过去一天完成 "),
    ("review", "评审", "review.out_per_day", "次", "过去一天给出结论 "),
    ("repair", "返工", "repair.out_per_day", "次", "过去一天完成 "),
    ("merge", "合入", "flow.merge_rate_per_hour", "个/小时", "过去一天合入速度 "),
    ("ci", "自动检查", "ci.out_per_day", "次", "过去一天放行 "),
    ("release", "发布", "release.hours_waiting", "小时", "当前这批已等 "),
]
# The one table that ties a report line to rows of anomaly-owners.json (the head's plain-Chinese note per scorecard metric).
# A row is {"cause": plain-Chinese note, "owner": who, "since": ISO 8601 UTC}; its cause prints only while since is at most 24 h before
# the report time (and at most 5 min after it, for clock skew). An older row, a since more than 5 min ahead, a row with no parseable
# since and a bare string (undated) all print 原因超过一天没有更新 instead.
# Line key -> row ids, first match first; a line prints the notes of the rows that exist, verbatim, at most two.
# Lines with no row (finished, rollbacks, money, intake, triage, advisor, review) read 未查明; scorecard rows with no line:
# scheduler.tick_gap_p50, scheduler.merge_pass_gap_min, scheduler.harvest_gap_p50, delivery.unlinked_units_30d, delivery.issue_to_accept_p50_30d_hours, delivery.issue_to_accept_p95_30d_hours.
OWNER_ROWS = {
    "shipped": ["delivery.merged_not_live", "delivery.issue_to_accept_p50_7d_hours", "delivery.issue_to_accept_p95_7d_hours"],
    "stock": ["flow.wait_stage_p90_hours", "delivery.merged_not_live"],
    "incidents": ["delivery.unlinked_incidents_30d"],
    "tokens": ["workorders.ticket_tokens_p90", "workorders.over_standard"],
    "station:implement": ["merge.conflict_repairs_per_day"],
    "station:repair": ["loop.rework_token_pct", "repair.unchanged_head_token_pct"],
    "station:merge": ["flow.merge_rate_per_hour"],
    "station:ci": ["ci.red_after_approve_pct", "ci.shared_append_rebase_conflict_pct"],
    "station:release": ["release.hours_waiting", "delivery.merged_not_live"],
}
# key -> label, kind, unit (stations are added from STATIONS)
FIGURES = {"finished": ("做完", "count", "个"), "shipped": ("正式上线", "count", "个"), "stock": ("做完等上线的需求", "count", "个"),
           "incidents": ("线上告警", "count", "次"),
           "rollbacks": ("撤回上线", "count", "次"), "tokens": ("令牌用量", "tokens", ""), "money": ("按美元计价的调用", "usd", "美元")}


def load(path):
    try:
        with open(path, encoding="utf-8") as source:
            return json.load(source)
    except (OSError, ValueError):
        return None


def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def parse_utc(stamp):
    try:
        return int(datetime.strptime(str(stamp)[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp())
    except ValueError:
        return None


def beijing_day(epoch):
    return datetime.fromtimestamp(epoch, BEIJING).strftime("%Y-%m-%d")


def num(v):
    return str(int(v)) if float(v).is_integer() else f"{v:.1f}"


def amount(kind, unit, v):
    if kind == "tokens":
        return f"{round(v / 1000) / 10:g} 万" if v >= 10000 else num(v)
    if kind == "usd":
        return f"{v:g} 美元"
    return f"{num(v)} {unit}"


def moved(kind, unit, now, base):
    d = now - base
    if d == 0:
        return "没有变化"
    shown = amount(kind, unit, abs(d))
    if re.match(r"^0(\.0)? ", shown) or shown == "0":
        return "几乎没有变化"
    return ("多 " if d > 0 else "少 ") + shown


def station_facts(runtime, now):
    health = load(os.path.join(runtime, "node-health.json"))
    if not isinstance(health, dict) or not isinstance(health.get("metrics"), list):
        return None
    made = parse_utc(health.get("generated"))
    if made is None or not 0 <= now - made <= STATION_FRESH_SECONDS:
        return None
    metrics = {m.get("id"): m for m in health["metrics"] if isinstance(m, dict)}
    live = load(os.path.join(runtime, "station-health.json"))
    live_at = parse_utc(live.get("at")) if isinstance(live, dict) else None
    live = live.get("stations") if live_at is not None and 0 <= now - live_at <= STATION_FRESH_SECONDS and isinstance(live.get("stations"), dict) else {}
    rows = []
    for key, name, metric_id, unit, phrase in STATIONS:
        m = metrics.get(metric_id)
        if not isinstance(m, dict) or not is_number(m.get("value")) or not is_number(m.get("healthy")):
            continue
        row = live.get(key) if isinstance(live.get(key), dict) else {}
        stalled = row.get("status") == "STALLED" and is_number(row.get("stall_min"))
        rows.append({"key": key, "name": name, "metric": metric_id, "unit": unit, "phrase": phrase, "value": m["value"],
                     "healthy": m["healthy"], "higher": m.get("higher_is_better") is True, "status": m.get("status"),
                     "stall_hours": round(row["stall_min"] / 60, 1) if stalled else None})
    return rows or None


def figures(facts):
    out = {}

    def put(key, value):
        if is_number(value):
            out[key] = value
    output = facts.get("output") or {}
    put("finished", (output.get("finished") or {}).get("day"))
    put("shipped", (output.get("shipped") or {}).get("day"))
    put("stock", (output.get("stock") or {}).get("now"))
    quality = facts.get("quality") or {}
    put("incidents", quality.get("incidents_period"))
    put("rollbacks", quality.get("rollbacks"))
    spend = (facts.get("spend") or {}).get("day") or {}
    put("tokens", spend.get("tokens"))
    put("money", spend.get("money_usd"))
    for row in facts.get("stations") or []:
        put("station:" + row["key"], row["value"])
    return out


def spend_facts(home, start, end):
    """Sum recorded token and price meters; explicit unobservable costs stay unknown."""
    first = datetime.fromtimestamp(start, timezone.utc).strftime("%Y-%m-%d")
    last = datetime.fromtimestamp(max(start, end - 1), timezone.utc).strftime("%Y-%m-%d")
    paths = sorted(path for path in glob.glob(os.path.join(home, "spend", "????-??-??.log"))
                   if first <= os.path.basename(path)[:10] <= last)
    tokens, money, rows, models, money_complete, money_seen = 0, 0.0, 0, {}, True, False
    try:
        for path in paths:
            with open(path, encoding="utf-8") as source:
                for line in source:
                    fields = line.rstrip("\r\n").split("\t")
                    if not fields[0].isdigit() or not start <= int(fields[0]) < end:
                        continue
                    rows += 1
                    model = fields[2].strip() if len(fields) > 2 else ""
                    split = models.setdefault(model, {"model": model, "tokens": 0, "_money_usd": 0.0,
                                                      "_money_complete": True, "_money_seen": False}) if model else None
                    count = int(fields[5]) if len(fields) > 5 and fields[5].isdigit() else 0
                    tokens += count
                    if split is not None:
                        split["tokens"] += count
                    try:
                        raw_price = fields[4].strip() if len(fields) > 4 else ""
                        price = float(raw_price) if raw_price else None
                    except (ValueError, OverflowError):
                        price = None
                    if price is not None and 0 <= price < float("inf"):
                        money_seen = True
                        money += price
                        if split is not None:
                            split["_money_seen"] = True
                            split["_money_usd"] += price
                    elif raw_price:
                        money_complete = False
                        if split is not None:
                            split["_money_complete"] = False
    except OSError:
        return None
    if not rows:
        return None
    by_model = sorted(models.values(), key=lambda row: (-row["tokens"], -row["_money_usd"], row["model"]))
    for row in by_model:
        complete, seen = row.pop("_money_complete"), row.pop("_money_seen")
        if complete and seen:
            row["money_usd"] = round(row.pop("_money_usd"), 2)
        else:
            row.pop("_money_usd")
    return {"tokens": tokens, "money_usd": round(money, 2) if money_complete and money_seen else None,
            "by_model": by_model}


def merge_counts(home, now):
    """Count distinct product pull requests merged in the report's three 24-hour periods."""
    periods = {"today": (now - DAY, now), "yesterday": (now - 2 * DAY, now - DAY),
               "last_week": (now - 8 * DAY, now - 7 * DAY)}

    def month_for(at):
        return datetime.fromtimestamp(at, timezone.utc).strftime("%Y-%m")

    needed = {month_for(at) for start, end in periods.values() for at in (start, end - 1)}
    loaded, events = {}, {}
    for month in sorted(needed):
        path = os.path.join(home, "metrics", f"efficiency-{month}.jsonl")
        month_events, saw_record, invalid = {}, False, False
        try:
            with open(path, encoding="utf-8") as source:
                for line in source:
                    if not line.strip():
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        invalid = True
                        break
                    if not isinstance(row, dict):
                        invalid = True
                        break
                    saw_record = True
                    if (row.get("record_type") != "event" or row.get("event_type") != "merged"
                            or row.get("delivery_path") != "product-release"):
                        continue
                    at = parse_utc(row.get("ts"))
                    number = row.get("pr_number")
                    if isinstance(number, int) and not isinstance(number, bool) and number > 0:
                        number = str(number)
                    if at is None or not isinstance(number, str) or not re.fullmatch(r"[1-9][0-9]*", number):
                        invalid = True
                        break
                    month_events[number] = min(at, month_events.get(number, at))
        except OSError:
            invalid = True
        loaded[month] = saw_record and not invalid
        events.update(month_events)

    result = {}
    for key, (start, end) in periods.items():
        months = {month_for(at) for at in (start, end - 1)}
        result[key] = (sum(start <= at < end for at in events.values())
                       if all(loaded.get(month, False) for month in months) else None)
    return result


def snapshot_path(directory, day):
    return os.path.join(directory, day + ".json")


def read_snapshot(directory, day):
    doc = load(snapshot_path(directory, day))
    if not isinstance(doc, dict) or doc.get("schema") != 1 or not isinstance(doc.get("figures"), dict) or not is_number(doc.get("at")):
        return None
    return {"at": doc["at"], "figures": {k: v for k, v in doc["figures"].items() if is_number(v)}}


def store_snapshot(directory, at, figs):
    """Write the day's file once; an existing day is never replaced. Returns stored|exists|empty."""
    if not figs:
        return "empty"
    os.makedirs(directory, mode=0o700, exist_ok=True)
    day = beijing_day(at)
    tmp = snapshot_path(directory, f".{day}.{os.getpid()}.tmp")
    with open(tmp, "w", encoding="utf-8") as out:
        json.dump({"schema": 1, "day": day, "at": at, "figures": figs}, out, ensure_ascii=False, sort_keys=True)
    try:
        os.link(tmp, snapshot_path(directory, day))
        return "stored"
    except FileExistsError:
        return "exists"
    finally:
        os.unlink(tmp)


def plain(text):
    """The owner-readable part of a free-text note: ticket numbers and long hashes dropped; empty unless Chinese only."""
    text = re.sub(r"\s+", " ", re.sub(r"[0-9a-fA-F]{7,}", "", re.sub(r"#\s*[0-9]+", "", str(text)))).strip()
    return text if re.search(r"[一-龥]", text) and not re.search(r"[A-Za-z]", text) else ""


def printable(text):
    """True when a note may go into the mail as written: Chinese, no Latin letters, no tracker id, no date, one line."""
    return (isinstance(text, str) and bool(re.search(r"[一-龥]", text)) and "\n" not in text
            and not re.search(r"[A-Za-z#]|[0-9]{4}-[0-9]{2}-[0-9]{2}|1970|1月1日", text))


# A cause row the worker wrote is printed only if this code accepts it (never on the worker's say-so): basis "read", a plain-Chinese
# cause with no wording of mere timing, and evidence that names what was read (a file path, a metric id or a line count) together with
# at least one number it shows (times and dates do not count). The row may carry no address or tracker id.
TIMING_WORDS = re.compile(r"同期|同一时间|同时|时间上|恰好|碰巧|之后不久|前后|先后")
SOURCE = re.compile(r"(?:~|/)[\w.\-/]+|\b[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+\b|\d+ ?(?:lines|行)")
CAUSES_SWITCH = "ZF_OWNER_REPORT_CAUSES"  # must be exactly "on"; off by default, landing leaves it off


def valid_cause_row(row):
    """The cause text of an acceptable worker row, else None."""
    if not isinstance(row, dict) or row.get("basis") != "read":
        return None
    cause, evidence = row.get("cause"), row.get("evidence")
    if not isinstance(evidence, str) or not printable(cause) or len(cause) > 80 or TIMING_WORDS.search(cause):
        return None
    if re.search(r"@|#[0-9]", evidence):
        return None
    stripped = re.sub(r"[0-9]{4}-[0-9]{2}-[0-9]{2}(?:T[0-9:]+Z?)?|\b[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?\b", "", evidence)
    if not SOURCE.search(stripped) or not re.search(r"[0-9]", SOURCE.sub("", stripped)):
        return None
    return cause.strip().rstrip("。")


def worker_causes(day):
    """{line key: cause} from the day's causes file, only behind the switch; {} when off, absent or unreadable."""
    if os.environ.get(CAUSES_SWITCH) != "on":
        return {}
    directory = os.environ.get("ZF_OWNER_REPORT_CAUSES_DIR") or os.path.expanduser("~/.zenoforge/state/work")
    doc = load(os.path.join(directory, f"owner-report-causes-{day}.json"))
    rows = doc.get("rows") if isinstance(doc, dict) and doc.get("day") == day else None
    out = {}
    for row in rows if isinstance(rows, list) else []:
        text = valid_cause_row(row)
        if text and isinstance(row.get("line"), str):
            out.setdefault(row["line"], text)
    return out


STALE_CAUSE = "原因超过一天没有更新"


def fresh_note(row, now):
    """The note text of an owners row: the cause of a dict row dated within a day of now, else STALE_CAUSE (bare strings are undated)."""
    if not isinstance(row, dict):
        return STALE_CAUSE
    try:
        since = datetime.fromisoformat(str(row.get("since")).replace("Z", "+00:00"))
        since = since if since.tzinfo else since.replace(tzinfo=timezone.utc)
        age = now - since.timestamp()
    except ValueError:
        return STALE_CAUSE
    return row.get("cause") if -300 <= age <= DAY else STALE_CAUSE  # a since over 5 min ahead of now is undated; less is clock skew


def owner_cause(owners, key, now):
    """(rows found, text): the notes of the rows mapped to this line; None when no mapped row exists. now is epoch seconds."""
    notes = []
    for row in OWNER_ROWS.get(key, []):
        note = fresh_note(owners[row], now) if row in owners else None
        if row in owners and note not in notes:
            notes.append(note)
    if not notes:
        return None
    safe = [n.strip() for n in notes if printable(n)][:2]
    return "；".join(safe) if safe else "已登记原因，但内容含不能直接发送的字符，没有转述"


def cause_owner(owners, key, now, worker, subjects):
    """Return a recorded Chinese cause and owner, or say explicitly that either is unknown."""
    causes, names = [], []
    for row_id in OWNER_ROWS.get(key, []):
        row = owners.get(row_id)
        if not isinstance(row, dict):
            continue
        note = fresh_note(row, now)
        cause, owner = plain(note), plain(row.get("owner"))
        if note != STALE_CAUSE and printable(note) and cause and cause not in causes:
            causes.append(cause.rstrip("。"))
            if owner and owner not in names:
                names.append(owner)
    if causes:
        return {"owner": "、".join(names) or "未登记", "cause": "；".join(causes[:2])}
    if key in worker:
        return {"owner": "未登记", "cause": worker[key]}
    if key == "incidents" and subjects:
        return {"owner": "未登记", "cause": "线上有告警还没解决：" + "、".join(subjects[:2])}
    return {"owner": "未登记", "cause": "原因未查明"}


def compare(facts, directory, now, repo, owners_path):
    today = datetime.fromtimestamp(now, BEIJING)
    snaps = {"昨天": read_snapshot(directory, (today - timedelta(days=1)).strftime("%Y-%m-%d")),
             "上周同日": read_snapshot(directory, (today - timedelta(days=7)).strftime("%Y-%m-%d"))}
    current = figures(facts)
    # Where a day has no snapshot, the same figure one day (or seven days) back from the report's own records is the base.
    o = facts.get("output") or {}
    spend_prev = (facts.get("spend") or {}).get("prev_day") or {}
    fallback = {"昨天": {"finished": (o.get("finished") or {}).get("prev_day"), "shipped": (o.get("shipped") or {}).get("prev_day"),
                         "stock": (o.get("stock") or {}).get("day_ago"), "tokens": spend_prev.get("tokens"), "money": spend_prev.get("money_usd")},
                "上周同日": {"stock": (o.get("stock") or {}).get("week_ago")}}

    def base_value(name, key):
        snap = snaps[name]
        if snap and key in snap["figures"]:
            return snap["figures"][key]
        value = fallback[name].get(key)
        return value if is_number(value) else None

    owners = load(owners_path) if owners_path else None
    owners = owners if isinstance(owners, dict) else {}
    stations = {r["key"]: r for r in facts.get("stations") or []}
    meta = dict(FIGURES)
    for key, name, metric_id, unit, phrase in STATIONS:
        meta["station:" + key] = (name, "count", unit)

    inline, station_lines, material = {}, [], []
    for key in meta:
        if key not in current or (key == "money" and current[key] == 0):
            continue
        kind, unit = meta[key][1:]
        said = [f"比{name}{moved(kind, unit, current[key], v)}" for name in snaps if (v := base_value(name, key)) is not None]
        yesterday = base_value("昨天", key)
        if yesterday is not None:
            change = abs(current[key] - yesterday)
            if (yesterday == 0 and change > 0) or (yesterday != 0 and change / abs(yesterday) >= MATERIAL_CHANGE_RATIO):
                material.append((change / max(abs(yesterday), 1), key))
        if key.startswith("station:"):
            r = stations[key[8:]]
            verdict = {"OK": "达标", "WARN": "偏离标准", "UNHEALTHY": "未达标"}.get(r["status"])
            text = (f"- {r['name']}：{r['phrase']}{amount(kind, unit, r['value'])}（标准{'至少' if r['higher'] else '不超过'} "
                    f"{amount(kind, unit, r['healthy'])}）" + (f"，{verdict}" if verdict else "")
                    + (f"，已停滞 {num(r['stall_hours'])} 小时" if r["stall_hours"] else ""))
            station_lines.append(text + ("；" + "，".join(said) if said else "") + "。")
        elif said:
            inline[key] = "，".join(said)
    note = ""
    if inline or any("；比" in line for line in station_lines):
        note = ("- 对比说明：比昨天是环比，比上周同日是同比（同一个星期几）；没有去年的数据，所以没有按年的同比；"
                "缺记录的那天不比较。")

    causes, changes, cause_rows = [], [], []
    worker = worker_causes(today.strftime("%Y-%m-%d"))
    subjects = [s for s in (plain(x) for x in (facts.get("quality") or {}).get("open_subjects") or []) if s]
    for _, key in sorted(material, reverse=True)[:MAX_CAUSE_LINES]:
        label, kind, unit = meta[key]
        yesterday = base_value("昨天", key)
        head = f"- {label}比昨天{moved(kind, unit, current[key], yesterday)}："
        changes.append({"line": key, "label": label, "now": amount(kind, unit, current[key]), "yesterday": amount(kind, unit, yesterday),
                        "change": moved(kind, unit, current[key], yesterday), "scorecard_rows": OWNER_ROWS.get(key, [])})
        cause = cause_owner(owners, key, now, worker, subjects)
        causes.append(head + cause["cause"] + "。")
        cause_rows.append({"line": key, "label": label, **cause})

    station_standards, anomalies, station_series = [], [], []
    days = [(today - timedelta(days=offset)).strftime("%Y-%m-%d") for offset in range(6, -1, -1)]
    history = {day: read_snapshot(directory, day) for day in days[:-1]}
    for key, name, _, unit, _ in STATIONS:
        row = stations.get(key)
        if not row or not is_number(row.get("value")) or not is_number(row.get("healthy")):
            continue
        standard = {"key": key, "name": name, "value": row["value"], "healthy": row["healthy"],
                    "higher": row["higher"], "unit": unit, "status": row.get("status")}
        station_standards.append(standard)
        if row.get("status") in ("WARN", "UNHEALTHY"):
            anomalies.append({"line": "station:" + key, "label": name, "value": row["value"], "standard": row["healthy"],
                              "unit": unit, **cause_owner(owners, "station:" + key, now, worker, subjects)})
        points = []
        for day in days:
            value = current.get("station:" + key) if day == days[-1] else (history.get(day) or {}).get("figures", {}).get("station:" + key)
            if is_number(value):
                points.append({"day": day, "value": value})
        if points:
            station_series.append({**standard, "points": points})

    periods = [{"key": "today", "label": "今天"}, {"key": "yesterday", "label": "昨天"},
               {"key": "last_week", "label": "上周同日"}]
    chart_metrics = []
    for key, label, unit, values in (
            ("merges", "合入", "个", [(facts.get("merges") or {}).get(period) for period in ("today", "yesterday", "last_week")]),
            ("finished", "做完", "个", [current.get("finished"), base_value("昨天", "finished"), base_value("上周同日", "finished")]),
            ("shipped", "正式上线", "个", [current.get("shipped"), base_value("昨天", "shipped"), base_value("上周同日", "shipped")])):
        points = [{"period": period["key"], "value": value} for period, value in zip(periods, values) if is_number(value)]
        if points:
            chart_metrics.append({"key": key, "label": label, "unit": unit, "points": points})
    spend = (facts.get("spend") or {}).get("day") or {}
    model_spend = [row for row in spend.get("by_model", []) if isinstance(row, dict)
                   and isinstance(row.get("model"), str) and row["model"]
                   and any(is_number(row.get(field)) for field in ("tokens", "money_usd"))]
    charts = {"anomalies": anomalies, "station_standards": station_standards, "station_series": station_series,
              "period_comparison": {"periods": periods, "metrics": chart_metrics},
              "model_spend": model_spend, "causes": cause_rows}
    return {"inline": inline, "note": note, "station_lines": station_lines, "causes": causes,
            "material": changes, "charts": charts}


def station_counts_at(agent_home, runtime, at):
    """Items out of each station in the 24 h before `at`, re-derived from the unit ledger and logs (nothing is written)."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mac-autopilot"))
    import ledger_history
    import station_health
    units = ledger_history.load_units(runtime)
    stop = datetime.fromtimestamp(at, timezone.utc)
    start = stop - timedelta(hours=24)
    first = min((t for u in units for t, _ in station_health.history(u)), default=None)
    if first is None or first > start:
        return {}  # the ledger does not reach back to this day: a count of zero would be a guess
    events = station_health.outs(units, runtime, agent_home)
    counts = {}
    for key, _, _, _, _ in STATIONS:
        if key == "release":
            continue  # hours the current batch has waited cannot be rebuilt for a past day
        n = sum(c for t, c in events.get(key, []) if start <= t < stop)
        counts["station:" + key] = n / 24 if key == "merge" else n
    return counts


def main(argv):
    cmd = argv[1]
    if cmd == "station":
        print(json.dumps(station_facts(argv[2], int(argv[3])), ensure_ascii=False, separators=(",", ":")))
    elif cmd == "compare":
        print(json.dumps(compare(json.load(sys.stdin), argv[2], int(argv[3]), argv[4], argv[5]), ensure_ascii=False, separators=(",", ":")))
    elif cmd == "spend":
        print(json.dumps(spend_facts(argv[2], int(argv[3]), int(argv[4])), ensure_ascii=False, separators=(",", ":")))
    elif cmd == "merges":
        print(json.dumps(merge_counts(argv[2], int(argv[3])), ensure_ascii=False, separators=(",", ":")))
    elif cmd == "write":
        print(store_snapshot(argv[2], int(argv[3]), figures(json.load(sys.stdin))))
    elif cmd == "backfill":
        at = int(argv[3])
        figs = figures(json.load(sys.stdin))
        try:
            figs.update(station_counts_at(argv[4], argv[5], at))
        except Exception as error:  # a ledger that cannot be read leaves the station rows out, not wrong
            print(f"station rows not rebuilt: {type(error).__name__}", file=sys.stderr)
        print(store_snapshot(argv[2], at, figs))
    else:
        raise SystemExit(f"unknown command {cmd}")


if __name__ == "__main__":
    main(sys.argv)
