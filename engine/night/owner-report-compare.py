#!/usr/bin/env python3
"""Owner report: station efficiency, daily snapshots, day and week comparison, and causes.

Subcommands (facts JSON on stdin where noted; every answer is JSON on stdout):
  station <runtime_dir> <now>                          rows from node-health.json and station-health.json, or null
  compare <snapshot_dir> <now> <repo_root> <owners>    facts -> {lines, station_lines, causes}
  write <snapshot_dir> <now>                           facts -> store today's snapshot unless one exists
  backfill <snapshot_dir> <T> <agent_home> <runtime>   facts at T -> store that day's snapshot unless one exists

A snapshot is one file per Beijing day: <snapshot_dir>/YYYY-MM-DD.json = {schema, day, at, figures}.
Nothing here guesses: a base that is absent drops that comparison, and a change nobody traced reads 未查明.
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

# A change is material when it moved at least this share of yesterday's figure (a base of zero counts any
# movement). Chosen 2026-11-07: below 30 % a daily count of ten moves by three on ordinary days.
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
# Files whose change between two days is named as context (never as the cause) beside an untraced station change.
PATH_HINTS = {"intake": r"intake", "triage": r"triage", "advisor": r"advisor", "implement": r"dispatch|worker-command|implement",
              "review": r"review", "repair": r"repair|self-check", "merge": r"merge", "ci": r"ci[-_]admission|/ci", "release": r"release"}
# key -> label, kind, unit (stations are added from STATIONS)
FIGURES = {"finished": ("做完", "count", "个"), "shipped": ("正式上线", "count", "个"), "incidents": ("线上告警", "count", "次"),
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
    quality = facts.get("quality") or {}
    put("incidents", quality.get("incidents_period"))
    put("rollbacks", quality.get("rollbacks"))
    spend = (facts.get("spend") or {}).get("day") or {}
    put("tokens", spend.get("tokens"))
    put("money", spend.get("money_usd"))
    for row in facts.get("stations") or []:
        put("station:" + row["key"], row["value"])
    return out


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


def landed(repo, since, until, pattern):
    """Commits on origin/main between two times that touched a file matching pattern; None if unreadable."""
    try:
        done = subprocess.run(["git", "-C", repo, "log", "origin/main", f"--since=@{int(since)}", f"--until=@{int(until)}",
                               "--name-only", "--format=%x01"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode != 0:
        return None
    commits = done.stdout.split("\x01")[1:]
    return sum(any(re.search(pattern, p) for p in c.splitlines() if p.strip()) for c in commits)


def compare(facts, directory, now, repo, owners_path):
    today = datetime.fromtimestamp(now, BEIJING)
    bases = {"昨天": read_snapshot(directory, (today - timedelta(days=1)).strftime("%Y-%m-%d")),
             "上周同日": read_snapshot(directory, (today - timedelta(days=7)).strftime("%Y-%m-%d"))}
    current = figures(facts)
    owners = load(owners_path) if owners_path else None
    owners = owners if isinstance(owners, dict) else {}
    stations = {r["key"]: r for r in facts.get("stations") or []}
    meta = dict(FIGURES)
    for key, name, metric_id, unit, phrase in STATIONS:
        meta["station:" + key] = (name, "count", unit)

    def clauses(key):
        kind, unit = meta[key][1:]
        return [f"比{name}{moved(kind, unit, current[key], base['figures'][key])}"
                for name, base in bases.items() if base and key in base["figures"]]

    lines, station_lines, material = [], [], []
    for key in meta:
        if key not in current or (key == "money" and current[key] == 0):
            continue
        said = clauses(key)
        yesterday = bases["昨天"]
        if yesterday and key in yesterday["figures"]:
            before, now_value = yesterday["figures"][key], current[key]
            change = abs(now_value - before)
            if (before == 0 and change > 0) or (before != 0 and change / abs(before) >= MATERIAL_CHANGE_RATIO):
                material.append((change / max(abs(before), 1), key))
        if key.startswith("station:"):
            r = stations[key[8:]]
            kind, unit = meta[key][1:]
            verdict = {"OK": "达标", "WARN": "偏离标准", "UNHEALTHY": "未达标"}.get(r["status"])
            text = (f"- {r['name']}：{r['phrase']}{amount(kind, unit, r['value'])}（标准{'至少' if r['higher'] else '不超过'} "
                    f"{amount(kind, unit, r['healthy'])}）" + (f"，{verdict}" if verdict else "")
                    + (f"，已停滞 {num(r['stall_hours'])} 小时" if r["stall_hours"] else ""))
            station_lines.append(text + ("；" + "，".join(said) if said else "") + "。")
        elif said:
            lines.append(f"- {meta[key][0]}：" + "，".join(said) + "。")
    if lines or any("；比" in s for s in station_lines):
        lines.insert(0, "- 对比说明：比昨天是环比，比上周同日是同比（同一个星期几）；没有去年的数据，所以没有按年的同比。"
                        "对比的是前几天同一时刻留下的日报记录，缺记录的那天不比较。")

    causes = []
    for _, key in sorted(material, reverse=True)[:MAX_CAUSE_LINES]:
        label, kind, unit = meta[key]
        before = bases["昨天"]["figures"][key]
        head = f"- {label}比昨天{moved(kind, unit, current[key], before)}："
        station = stations.get(key[8:]) if key.startswith("station:") else None
        note = owners.get(station["metric"]) if station else None
        subjects = [s for s in (plain(x) for x in (facts.get("quality") or {}).get("open_subjects") or []) if s]
        if note is not None:
            text = plain(note)
            causes.append(head + (f"已有人跟进，登记的说明是：{text}。" if text else "已有人在跟进，登记的原因没有写成平白中文，这里不转述。"))
        elif key == "incidents" and current[key] > before and subjects:
            causes.append(head + "线上有告警还没解决：" + "、".join(subjects[:2]) + "。")
        else:
            n = landed(repo, bases["昨天"]["at"], now, PATH_HINTS[key[8:]]) if station and repo else None
            causes.append(head + "未查明" + (f"（同期有 {n} 项改动合入了该环节的代码，尚未核实是否相关）" if n else "") + "。")
    return {"lines": lines, "station_lines": station_lines, "causes": causes}


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
