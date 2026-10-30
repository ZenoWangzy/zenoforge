#!/usr/bin/env python3
"""autopilot 定时体检：把台账、worker 记录与 scheduler.log 压成一页效率报告（确定性、只读）。

用法: health_report.py [--hours N] [--runtime DIR]
默认读 MAC_AUTOPILOT_RUNTIME_DIR（或 <root>/.scratch-supervisor/autopi）。供 supervisor 每 5 小时体检，
输出只含需要判断的数字：各环节吞吐/耗时/token、失败类型、卡住的单元、合并与门禁。
"""
import argparse, json, os, re, statistics, subprocess, sys
from datetime import datetime, timezone, timedelta

LINE_RE = re.compile(r"^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\] (.*)$")
HARVEST_RE = re.compile(r"harvest unit=(\S+) type=(\S+) verdict=(\S+) .*?tokens=(\d+)")
WORK_STAGES = ("review", "rereview", "repair", "implement")
STUCK_MINUTES = {"review-pending": 60, "rereview-pending": 60, "repair-pending": 60, "implement-pending": 120,
                 "ready-to-merge": 120, "supervisor-review": 0, "blocked-external": 0}


def ts(value):
    try:
        return datetime.strptime(value[:20], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None


def pct(values, q):
    if not values:
        return "-"
    values = sorted(values)
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))]


def main():
    here = os.path.dirname(os.path.realpath(__file__))
    default_runtime = os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR") or (
        os.path.join(here.split("/autopi-versions/", 1)[0], "autopi") if "/autopi-versions/" in here else
        here if here.endswith("/.scratch-supervisor/autopi")
        else os.path.join(os.path.dirname(os.path.dirname(here)), ".scratch-supervisor", "autopi"))
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=float, default=5)
    ap.add_argument("--runtime", default=default_runtime)
    ap.add_argument("--now", help="ISO time (tests)")
    args = ap.parse_args()
    a = args.runtime
    now = ts(args.now) if args.now else datetime.now(timezone.utc)
    since = now - timedelta(hours=args.hours)

    units = json.load(open(os.path.join(a, "units.json")))["units"]
    workers = json.load(open(os.path.join(a, "workers.json")))["workers"]
    lines = []
    log = os.path.join(a, "scheduler.log")
    if os.path.exists(log):
        for raw in open(log, errors="ignore"):
            m = LINE_RE.match(raw.rstrip("\n"))
            if m and (t := ts(m.group(1))) and t >= since:
                lines.append((t, m.group(2)))

    # ---- 各环节：耗时（派发→回收）、token、结果 ----
    harvests = []
    for t, msg in lines:
        m = HARVEST_RE.search(msg)
        if m:
            harvests.append((t, m.group(1), m.group(2), m.group(3), int(m.group(4))))
    per_type = {k: {"n": 0, "mins": [], "tokens": [], "verdicts": {}} for k in WORK_STAGES}
    for t, unit, wtype, verdict, tokens in harvests:
        slot = per_type.setdefault(wtype, {"n": 0, "mins": [], "tokens": [], "verdicts": {}})
        slot["n"] += 1
        slot["tokens"].append(tokens)
        slot["verdicts"][verdict] = slot["verdicts"].get(verdict, 0) + 1
        started = [ts(w.get("started")) for w in workers
                    if w.get("unit") == unit and w.get("type") == wtype and ts(w.get("started")) and ts(w.get("started")) <= t]
        if started:
            slot["mins"].append(int((t - max(started)).total_seconds() // 60))

    def count(pattern):
        return sum(1 for _, msg in lines if re.search(pattern, msg))

    print(f"autopilot health {now:%Y-%m-%dT%H:%MZ} window={args.hours:g}h")
    print("drift check: STRATEGY.md 'Maintainer intents' — fix the most UNHEALTHY node in the scorecard below first; "
          "name the intent and the metric each change serves")
    stages = {}
    for u in units:
        stages[u.get("stage")] = stages.get(u.get("stage"), 0) + 1
    print("stages: " + " ".join(f"{k}={v}" for k, v in sorted(stages.items())))
    live = sum(1 for w in workers if not w.get("harvested"))
    print(f"workers: unharvested={live} dispatched={count(r'^dispatch mode=')} "
          f"capacity-skips={count(r'skip dispatch .*capacity')} ticks={count(r'^tick done')}")
    print("stage            runs  wall-min p50/p90  tokens p50   outcomes")
    for k, s in per_type.items():
        if not s["n"]:
            continue
        outcomes = " ".join(f"{v}={n}" for v, n in sorted(s["verdicts"].items()))
        print(f"  {k:<14} {s['n']:>4}  {pct(s['mins'], .5):>5}/{pct(s['mins'], .9):<5}   "
              f"{pct(s['tokens'], .5):>9}   {outcomes}")
    print(f"failures: no-output={count(r'WASTE zero-output pid')} provider-cooldowns={count(r'cooling down')} "
          f"repair-no-push={count(r'repair-no-push')} loop-breaker={count(r'loop-breaker')} "
          f"stuck-kills={count(r'STUCK-KILL')} escalations={count(r'^supervisor-review unit')}")
    print(f"merge: issued={count(r'^merge issued')} merged={count(r'merged after Pipeline suites success|^merged PR#')} "
          f"reverted={count(r'repair-pending after merge revert')} skipped-checks={count(r'checks red or pending')}")

    # 门禁只在 scheduler 写 "merge lane held" 时算 hold；scheduler 只在状态变化时写 GATE 行，
    # 所以最后一行 hold 只在 scheduler 仍在出 tick 时才代表「现在还 held」。scheduler 停了/暂停了(PAUSE)，
    # 末段 hold 只算到最后一次评估拍，不再把停摆之后的时间记成 held。
    gate = os.path.join(a, "alerts", "gate.md")
    held = 0.0
    held_now = False
    if os.path.exists(gate):
        events = []
        for raw in open(gate, errors="ignore"):
            m = LINE_RE.match(raw.rstrip("\n"))
            if m and (t := ts(m.group(1))) and "GATE " in m.group(2) and " main=" in m.group(2):
                events.append((t, "merge lane held" in m.group(2)))
        # 暂停（PAUSE）的拍只收割/验证，不评估合并车道：同一拍内 "paused by" 与 "tick done" 同戳，剔除后才算评估过门禁的拍。
        paused = {t for t, msg in lines if msg.startswith("paused by")}
        ticks = [t for t, msg in lines if msg.startswith("tick done") and t not in paused]
        last_tick = max(ticks) if ticks else None
        state_held, last = False, since
        for t, is_held in events:
            if t < since:
                state_held = is_held
                continue
            if state_held:
                held += (t - last).total_seconds()
            state_held, last = is_held, t
        if state_held:
            held_now = last_tick is not None and (now - last_tick) <= timedelta(minutes=30)
            end = now if held_now else (last_tick if last_tick and last_tick > last else last)
            held += (end - last).total_seconds()
    if held > 0:
        print(f"gate: held {held / 3600:.1f}h of {args.hours:g}h" + (" (current)" if held_now else ""))

    cooldown = os.path.join(a, "cooldown.json")
    if os.path.exists(cooldown):
        active = {p: u for p, u in json.load(open(cooldown)).items() if u > now.timestamp()}
        if active:
            print("cooldown active: " + " ".join(f"{p}(until {datetime.fromtimestamp(u, timezone.utc):%H:%MZ})" for p, u in active.items()))

    stuck = []
    for u in units:
        st = u.get("stage")
        if st not in STUCK_MINUTES:
            continue
        hist = u.get("history") or []
        entered = ts(hist[-1].get("at")) if hist else None
        age = int((now - entered).total_seconds() // 60) if entered else None
        if STUCK_MINUTES[st] == 0 or (age is not None and age >= STUCK_MINUTES[st]):
            stuck.append((st, u["id"], age, (u.get("note") or "")[:90]))
    if stuck:
        print("attention:")
        for st, uid, age, note in sorted(stuck):
            print(f"  {uid:<14} {st:<18} {'' if age is None else str(age) + 'm':>6}  {note}")

    # 各环节对照 NODE-HEALTH.md 的健康标准打分（node_health.py 与本脚本同目录同步）。
    scorer = os.path.join(os.path.dirname(os.path.realpath(__file__)), "node_health.py")
    if os.path.exists(scorer):
        sys.stdout.flush()
        # 与 scheduler 同一运行环境（runtime-env.sh：PGTEST_URL 等）打分；直接跑会把 workers.local_test_db 误报为 0。
        env_sh = os.path.join(os.path.dirname(scorer), "runtime-env.sh")
        cmd = [sys.executable, scorer, "--runtime", a, "--hours", f"{args.hours:g}"] + (["--now", args.now] if args.now else [])
        if os.path.exists(env_sh):
            cmd = ["bash", "-c", 'source "$0" >/dev/null 2>&1; exec "$@"', env_sh] + cmd
        subprocess.run(cmd, check=False)


if __name__ == "__main__":
    main()
