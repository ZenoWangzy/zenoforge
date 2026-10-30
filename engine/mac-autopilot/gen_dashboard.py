#!/usr/bin/env python3
"""the product Mac autopilot dashboard 数据生成；低频对账会登记观测到的生产状态。"""
import json, os, glob, time, subprocess, calendar, re, sys
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
import worker_cost

_HERE = os.path.dirname(os.path.realpath(__file__))
_DEFAULT_ROOT = (_HERE.split("/.scratch-supervisor/autopi-versions/", 1)[0] if "/.scratch-supervisor/autopi-versions/" in _HERE else
                 _HERE[: -len("/.scratch-supervisor/autopi")] if _HERE.endswith("/.scratch-supervisor/autopi")
                 else os.path.dirname(os.path.dirname(_HERE)))
ROOT = os.environ.get("MAC_AUTOPILOT_ROOT", _DEFAULT_ROOT)
SUP = os.environ.get("MAC_AUTOPILOT_SUPERVISOR_DIR", os.path.join(ROOT, ".scratch-supervisor"))
A = os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR", os.path.join(SUP, "autopi"))

units = json.load(open(f"{A}/units.json"))["units"]
workers = json.load(open(f"{A}/workers.json"))["workers"]
cfg = json.load(open(f"{A}/config.json"))
release = json.load(open(f"{A}/release.json")) if os.path.exists(f"{A}/release.json") else {}
SESSION_TZ = os.environ.get("SESSION_TZ", "America/Los_Angeles")
SESSION_TIMEZONE = ZoneInfo(SESSION_TZ)
today = datetime.now(SESSION_TIMEZONE).date()
today_text = today.isoformat()
yesterday_text = (today - timedelta(days=1)).isoformat()

def session_date_of(timestamp):
    if not isinstance(timestamp, str):
        return None
    try:
        parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            return None
        return parsed.astimezone(SESSION_TIMEZONE).date().isoformat()
    except (OverflowError, ValueError):
        return None

# ---- 昨日与今日的 session 成本（估算） ----
SESSION_ROOT = os.path.expanduser(os.environ.get("CODEX_SESSIONS_DIR", "~/.codex/sessions"))
MODEL_PRICING = {
    # OpenAI API standard text-token list prices, USD per million tokens.
    "gpt-6-luna": {"in": 0.10, "cached": 0.01, "out": 0.50},
    "gpt-5.6-terra": {"in": 2.00, "cached": 0.20, "out": 12.00},
}
DEFAULT_PRICING = MODEL_PRICING["gpt-6-luna"]
DEFAULT_PRICING_NOTE = (
    "默认参考 OpenAI API 标准文本 token 公价作等值估算（美元/百万 token；"
    "GPT-6 Luna 输入/缓存/输出 $0.10/$0.01/$0.50，"
    "GPT-5.6 Terra $2/$0.20/$12）；不是 Codex/ChatGPT 订阅账单。"
    "config.pricing 可覆盖单价。输入价按扣除缓存后的 token 计算；"
    "未计大上下文加价、处理档位、缓存写入或工具调用费用。"
)
pricing = cfg.get("pricing") if isinstance(cfg.get("pricing"), dict) else {}

def as_int(value):
    try: return max(0, int(value or 0))
    except (TypeError, ValueError): return 0

def read_session(path):
    models = []
    input_total = cached = output = 0
    with open(path, encoding="utf-8", errors="ignore") as source:
        for line in source:
            try: event = json.loads(line)
            except ValueError: continue
            payload = event.get("payload") or {}
            if event.get("type") == "turn_context":
                model = str(payload.get("model") or "")
                if model and model not in models:
                    models.append(model)
            if event.get("type") != "event_msg" or payload.get("type") != "token_count":
                continue
            usage = (payload.get("info") or {}).get("total_token_usage") or {}
            input_total = as_int(usage.get("input_tokens"))
            cached = min(input_total, as_int(usage.get("cached_input_tokens")))
            output = as_int(usage.get("output_tokens"))
    # Codex reports cached input as a subset of input_tokens. Price it in its
    # own category while counting total tokens as input+output, matching budget.
    mixed_model = len(models) > 1
    return {"model": "mixed" if mixed_model else (models[0] if models else "unknown"),
            "models": models, "mixed_model": mixed_model,
            "in": input_total - cached, "cached": cached,
            "out": output, "tokens_total": input_total + output}

def load_cost_cache(path):
    try:
        with open(path, encoding="utf-8") as source:
            value = json.load(source)
        if value.get("version") == 3 and isinstance(value.get("files"), dict):
            return value["files"]
    except (OSError, ValueError, AttributeError):
        pass
    return {}

def write_cost_cache(path, cache):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as output:
        json.dump({"version": 3, "files": cache}, output, ensure_ascii=False, separators=(",", ":"))
        output.write("\n")
    os.replace(temporary, path)

cost_cache_path = os.environ.get("MAC_AUTOPILOT_COST_CACHE", os.path.join(SUP, ".cost_cache.json"))
previous_cost_cache = load_cost_cache(cost_cache_path)
current_cost_cache = {}
session_rows = []
for day_text in (yesterday_text, today_text):
    day_dir = os.path.join(SESSION_ROOT, *day_text.split("-"))
    for path in sorted(glob.glob(os.path.join(day_dir, "rollout-*.jsonl"))):
        try: stat = os.stat(path)
        except OSError: continue
        cached_entry = previous_cost_cache.get(path) or {}
        stamp = {"mtime_ns": stat.st_mtime_ns, "size": stat.st_size}
        if cached_entry.get("mtime_ns") == stamp["mtime_ns"] and cached_entry.get("size") == stamp["size"]:
            usage = cached_entry.get("usage") or {}
        else:
            try: usage = read_session(path)
            except OSError: continue
        current_cost_cache[path] = {**stamp, "usage": usage}
        model = usage.get("model", "unknown")
        configured_prices = pricing.get(model)
        fallback_prices = pricing.get("default")
        unpriced_model = not isinstance(configured_prices, dict) and model not in MODEL_PRICING
        if usage.get("mixed_model"):
            # Session totals are cumulative, so a mixed-model session cannot be
            # priced accurately by assigning the whole total to one model.
            dollars = None
            unpriced_model = True
        else:
            prices = configured_prices if isinstance(configured_prices, dict) else MODEL_PRICING.get(model)
            if not isinstance(prices, dict):
                prices = fallback_prices if isinstance(fallback_prices, dict) else DEFAULT_PRICING
            rates = {key: float(prices.get(key, DEFAULT_PRICING[key]) or 0) for key in DEFAULT_PRICING}
            dollars = sum(usage[key] / 1_000_000 * rates[key] for key in DEFAULT_PRICING)
        session_id_match = re.search(r"([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\.jsonl$", path)
        session_rows.append({"date": day_text, "session_id": session_id_match.group(1) if session_id_match else os.path.basename(path),
                             **usage, "dollars": dollars, "unpriced_model": unpriced_model})
write_cost_cache(cost_cache_path, current_cost_cache)
try:
    budget = json.load(open(f"{A}/budget.json"))
except (OSError, ValueError):
    budget = {"date": today_text, "total": 0}
real_daily_tokens = int(budget.get("total", 0) or 0)

unit_ids = {str(u.get("id")) for u in units if u.get("id")}
unit_by_log = {str(w.get("log")): str(w.get("unit")) for w in workers if w.get("log") and w.get("unit")}
sid_units = {}
for log_path in glob.glob(os.path.join(SUP, "*.worker.log")):
    log_name = os.path.basename(log_path)
    unit = unit_by_log.get(log_name)
    stem = log_name[:-len(".worker.log")] if log_name.endswith(".worker.log") else log_name
    if unit is None and stem.startswith("review-"):
        suffix = stem[len("review-"):]
        match = re.match(r"(\d+)(?:-r\d*)?$", suffix)
        candidate = f"pr-{match.group(1)}" if match else suffix
        if candidate in unit_ids: unit = candidate
    if unit is None and stem.startswith("impl-"):
        suffix = stem[len("impl-"):]
        match = re.match(r"(\d+)-fix(?:-.*)?$", suffix)
        candidates = [suffix, f"pr-{match.group(1)}" if match else ""]
        if suffix.isdigit(): candidates.append(f"pr-{suffix}")
        unit = next((candidate for candidate in candidates if candidate in unit_ids), None)
    try:
        with open(log_path, encoding="utf-8", errors="ignore") as source:
            log_text = source.read()
    except OSError:
        continue
    if not unit: continue
    # legacy worker 日志带 "session id:" 页脚；--json 日志的 session id 在 thread.started 事件里
    session_ids = set(re.findall(r"session id: ([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})", log_text))
    session_ids |= set(re.findall(r'"thread_id":"([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})"', log_text))
    for session_id in session_ids:
        sid_units.setdefault(session_id, set()).add(unit)

by_model = {}
by_unit = {}
for session in session_rows:
    model = session["model"]
    model_row = by_model.setdefault(model, {"model": model, "sessions": 0, "tokens": 0, "dollars": 0.0,
                                            "unestimated_sessions": 0, "unpriced_model": session["unpriced_model"]})
    model_row["sessions"] += 1
    model_row["tokens"] += session["tokens_total"]
    if session["dollars"] is None:
        model_row["unestimated_sessions"] += 1
    else:
        model_row["dollars"] += session["dollars"]
    unit_candidates = sid_units.get(session["session_id"], set())
    unit = next(iter(unit_candidates)) if len(unit_candidates) == 1 else "unattributed"
    unit_row = by_unit.setdefault(unit, {"unit": unit, "sessions": 0, "dollars": 0.0, "unestimated_sessions": 0})
    unit_row["sessions"] += 1
    if session["dollars"] is None:
        unit_row["unestimated_sessions"] += 1
    else:
        unit_row["dollars"] += session["dollars"]

for row in by_model.values():
    if row["sessions"] == row["unestimated_sessions"]:
        row["dollars"] = None
for row in by_unit.values():
    if row["sessions"] == row["unestimated_sessions"]:
        row["dollars"] = None

def day_cost(day_text):
    selected = [row for row in session_rows if row["date"] == day_text]
    return {"sessions": len(selected), "tokens": sum(row["tokens_total"] for row in selected),
            # 计费口径：未命中缓存的输入 + 输出；缓存读几乎免费，不该把预算条撑到 2966%
            "billable": sum(row.get("in", 0) + row.get("out", 0) for row in selected),
            "dollars": sum(row["dollars"] for row in selected if row["dollars"] is not None),
            "unestimated_sessions": sum(row["dollars"] is None for row in selected)}

unpriced_models = sorted(model for model, row in by_model.items() if row["unpriced_model"] and model != "mixed")
pricing_note = str(cfg.get("pricing_note") or DEFAULT_PRICING_NOTE)
if unpriced_models:
    pricing_note += " 未配置单价模型：" + "、".join(unpriced_models) + "（使用 pricing.default 或内置默认单价）。"
unestimated_sessions = sum(row["dollars"] is None for row in session_rows)
if unestimated_sessions:
    pricing_note += f" {unestimated_sessions} 个混合模型 session 因累计 token 无法按模型拆分，未计入金额汇总。"
cost_data = {
    "yesterday": day_cost(yesterday_text), "today": day_cost(today_text),
    "by_model": sorted(by_model.values(), key=lambda row: row["dollars"] if row["dollars"] is not None else -1, reverse=True),
    "top_sessions": [
        {"session_id": row["session_id"], "unit": (next(iter(sid_units.get(row["session_id"], set()))) if len(sid_units.get(row["session_id"], set())) == 1 else "unattributed"),
         "model": row["model"], "models": row.get("models", []), "mixed_model": row.get("mixed_model", False),
         "tokens": row["tokens_total"], "dollars": row["dollars"], "unpriced_model": row["unpriced_model"]}
        for row in sorted(session_rows, key=lambda item: item["dollars"] if item["dollars"] is not None else -1, reverse=True)[:10]
    ],
    "per_unit": sorted(by_unit.values(), key=lambda row: row["dollars"] if row["dollars"] is not None else -1, reverse=True),
    "pricing_note": pricing_note, "unpriced_models": unpriced_models,
    "unestimated_sessions": unestimated_sessions,
    "budget_tokens": real_daily_tokens, "budget_date": budget.get("date"),
    "budget_status": budget.get("status", "unavailable"),
    "budget_incomplete_sessions": budget.get("incomplete_sessions", [])
    if isinstance(budget.get("incomplete_sessions", []), list) else [],
    "budget_tokens_match": day_cost(today_text)["tokens"] == real_daily_tokens if budget.get("date") == today_text else False,
}

TYPE_MODEL = {"review": cfg["models"]["review"][0], "rereview": cfg["models"]["review"][0],
              "implement": cfg["models"]["implement"][0], "repair": cfg["models"]["implement"][0],
              "triage": cfg["models"]["triage"][0]}

def alive(pid):
    try:
        pid = int(pid)
        if pid <= 0: return False
        os.kill(pid, 0); return True
    except Exception: return False

def tokens_of(log):
    try:
        lines = open(f"{SUP}/{log}", errors="ignore").read().splitlines()
        for i, l in enumerate(lines):
            if "tokens used" in l and i + 1 < len(lines):
                return int(lines[i+1].replace(",", "").strip() or 0)
        # --json 日志：末次累计 turn.completed 的新鲜 token（与旧页脚 blended 口径一致）
        fresh = None
        for l in lines:
            try: event = json.loads(l)
            except ValueError: continue
            if isinstance(event, dict) and event.get("type") == "turn.completed":
                usage = event.get("usage") or {}
                if isinstance(usage.get("input_tokens"), int) and isinstance(usage.get("output_tokens"), int):
                    cached = usage.get("cached_input_tokens")
                    fresh = usage["input_tokens"] - cached + usage["output_tokens"] if isinstance(cached, int) else None
        return fresh or 0
    except Exception: pass
    return 0

def gh(args):
    try:
        return json.loads(subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60).stdout or "[]")
    except Exception:
        return []

# 在岗员工此刻在做什么：codex 日志里最后一段 "codex" 自述 + 最后一条 exec 命令。
def activity_of(log):
    try:
        path = f"{SUP}/{log}"
        with open(path, "rb") as stream:
            stream.seek(max(0, os.path.getsize(path) - 60000))
            lines = stream.read().decode(errors="ignore").splitlines()
    except OSError:
        return {}
    say = cmd = ""
    # --json 日志：最后的 agent_message / command_execution 事件就是自述与命令
    for line in lines:
        try: event = json.loads(line)
        except ValueError: continue
        item = event.get("item") if isinstance(event, dict) else None
        if not (isinstance(item, dict) and event.get("type") == "item.completed"):
            continue
        if item.get("type") == "command_execution" and item.get("command"):
            cmd = re.sub(r"^/bin/(ba)?sh -lc ", "", str(item["command"]))
        if item.get("type") == "agent_message" and item.get("text"):
            say = str(item["text"])
    if say or cmd:
        return {"say": say[:240], "cmd": cmd[:200]}
    markers = ("exec", "codex", "thinking", "tokens used")
    for i in range(len(lines) - 1, -1, -1):
        line = lines[i].strip()
        if not cmd and line == "exec" and i + 1 < len(lines):
            cmd = re.sub(r"^/bin/(ba)?sh -lc ", "", lines[i + 1].strip())
            cmd = re.sub(r"\s+in /\S+$", "", cmd).strip("\"'")
        if not say and line == "codex":
            chunk = []
            for nxt in lines[i + 1:i + 8]:
                if nxt.strip() in markers or nxt.startswith("hook:") or re.match(r"\s*(succeeded|exited|failed) in \d", nxt):
                    break
                chunk.append(nxt.strip())
            say = " ".join(x for x in chunk if x)
        if say and cmd:
            break
    return {"say": say[:240], "cmd": cmd[:200]}

# ---- worker 台账（agent 维度：模型/产出/耗时/token） ----
wl = []
for w in workers:
    t = tokens_of(w.get("log", ""))
    el = None
    if w.get("started"):
        try: el = int((time.time() - calendar.timegm(time.strptime(w["started"][:19], "%Y-%m-%dT%H:%M:%S"))) // 60)
        except Exception: pass
    wl.append({**w, "alive": alive(w["pid"]), "tokens": t, "elapsed_min": el,
               "model": TYPE_MODEL.get(w.get("type"), "-"),
               "output": w.get("report", "-") if (os.path.exists(f"{SUP}/{w.get('report','')}") and os.path.getsize(f"{SUP}/{w.get('report','')}") > 0) else ""})
    if wl[-1]["alive"]:
        wl[-1]["activity"] = activity_of(w.get("log", ""))

# ---- 网络流量（engine/network-traffic.py monitor 每 60 秒写一次结果） ----
AGENT_HOME = os.environ.get("AGENT_HOME") or os.path.expanduser("~/.zenoforge")
def read_json(path):
    try:
        with open(path) as stream:
            return json.load(stream)
    except (OSError, ValueError):
        return None

def current_pause():
    path = os.path.join(AGENT_HOME, "PAUSE")
    if not os.path.exists(path):
        return None
    state = read_json(path) or {}
    return {"since": state.get("timestamp"), "reason": state.get("reason")}

traffic_last = read_json(os.path.join(AGENT_HOME, "night/network-traffic-last-result.json")) or {}
traffic_budget = read_json(os.path.join(AGENT_HOME, "state/traffic-budget.json")) or {}
traffic_history = []
try:
    utc_day = datetime.now(ZoneInfo("UTC")).strftime("%Y-%m-%d")
    with open(os.path.join(AGENT_HOME, f"metrics/traffic-{utc_day}.jsonl")) as stream:
        for line in stream.read().splitlines()[-180:]:
            row = json.loads(line)
            traffic_history.append({"t": row.get("sampled_epoch"), "gbh": row.get("gb_per_hour")})
except (OSError, ValueError):
    pass
traffic_daily = traffic_last.get("daily") or {}
traffic = {
    "installed": bool(traffic_budget),
    "status": traffic_last.get("status") or ("STARTING" if traffic_budget else "NOT-INSTALLED"),
    "sampled_epoch": traffic_last.get("sampled_epoch"),
    "gb_per_hour": traffic_last.get("gb_per_hour"),
    "category_gb_per_hour": traffic_last.get("category_gb_per_hour") or {},
    "today_gb": (traffic_daily.get("wire_bytes") or 0) / 1e9 if traffic_daily.get("wire_bytes") is not None else None,
    "today_category_gb": {k: v / 1e9 for k, v in (traffic_daily.get("categories") or {}).items() if isinstance(v, (int, float))},
    "budget": {k: traffic_budget.get(k) for k in ("gb_per_hour", "gb_per_day", "category_gb_per_hour", "category_gb_per_day")},
    "detail": (traffic_last.get("detail") or "")[:300],
    "history": traffic_history,
}

# ---- worker 成本账（worker_cost.py：单元 / ticket / 阶段 / 后端 + 最近 24h + eval 栏） ----
# 无状态：每拍从 worker 事件流重读一遍，同一文件重读不重复计数；eval 用 runner 自己的 results.json。
cost_rows = worker_cost.run_rows(SUP)
cost_ledger = worker_cost.aggregate(cost_rows, units, time.time())
cost_ledger["eval"] = worker_cost.eval_costs(os.path.join(AGENT_HOME, "eval"), time.time())

# ---- GitHub 总量 ----
# PR 与 run 事实来自 scheduler 每拍发布的快照（pr-run-snapshot.json）：缺失、格式错或分区为 null 都是"不可用"，不当成零。
_pr_run_snapshot = read_json(f"{A}/pr-run-snapshot.json")
def snapshot_section(*path):
    node = _pr_run_snapshot if isinstance(_pr_run_snapshot, dict) and _pr_run_snapshot.get("schema") == 1 else None
    for key in path:
        node = node.get(key) if isinstance(node, dict) else None
    return node if isinstance(node, list) else None
issues_open = gh(["issue", "list", "--state", "open", "--limit", "300", "--json", "number,labels"])
prs_open = snapshot_section("prs") or []
prs_merged_today = gh(["pr", "list", "--state", "merged", "--limit", "30", "--json", "number,mergedAt"])
merged_today = [p["number"] for p in prs_merged_today
                if session_date_of(p.get("mergedAt")) == today_text]
needs_triage = sum(1 for i in issues_open if any(l.get("name") == "needs-triage" for l in i.get("labels", [])))

# ---- suites / CI 门禁 ----
# 与合并门禁同口径：最新一个已完成且非取消的 run 是裁决；更新的 run 在跑时另标"进行中"。
def main_verdict(workflow):
    runs = (snapshot_section("main_runs", workflow) or [])[:10]
    if not runs:
        return "unknown"
    verdict = next((r.get("conclusion") for r in runs
                    if r.get("status") == "completed" and r.get("conclusion") not in (None, "", "cancelled")), None) or "unknown"
    return verdict + ("（新一轮进行中）" if runs[0].get("status") != "completed" else "")
suites = main_verdict("Pipeline suites")
ci = main_verdict("CI")

# ---- CI 现状（每拍）：runner、排队、WIP 等待、热修挡板。健康线在 node-health.json 的 ci_standards（node_health.py）----
def runner_pool(r):
    labels = set(r.get("labels") or [])
    if "cihost-ci-postsubmit" in labels:
        return "Postsubmit"
    if labels & {"cihost-ci", "cihost-ci-light", "cihost-ci-priority", "zf-suites"}:
        return "PR"
    if "cihost-ci-main" in labels:
        return "main 专用"
    if r.get("name", "").startswith("zf-mac"):
        return "Mac"
    return "其他"
runners = gh(["api", "repos/{owner}/{repo}/actions/runners?per_page=100", "--jq",
              "[.runners[] | {name, status, busy, labels: [.labels[].name]}]"])
runners = runners if isinstance(runners, list) else []
pools = {}
for r in runners:
    pool = pools.setdefault(runner_pool(r), {"total": 0, "online": 0, "busy": 0})
    pool["total"] += 1
    pool["online"] += r.get("status") == "online"
    pool["busy"] += bool(r.get("busy")) and r.get("status") == "online"
def run_count(status):
    unfinished = snapshot_section("unfinished_runs")
    return None if unfinished is None else sum(1 for r in unfinished if r.get("status") == status)
queued_runs, running_runs = run_count("queued"), run_count("in_progress")
pr_pools = [pools["PR"]] if "PR" in pools else []
pr_online = sum(p["online"] for p in pr_pools)
ready_units = [u for u in units if u.get("stage") == "ready-to-merge"]
ci_live = {
    "pools": pools,
    "values": {
        "runners_online": sum(p["online"] for p in pools.values()) if runners else None,
        "pr_runner_busy_pct": round(100 * sum(p["busy"] for p in pr_pools) / pr_online) if pr_online and queued_runs else None,
        "queued_runs": queued_runs,
        "wip_waiting": sum(1 for u in ready_units if u.get("ci_wip_wait")),
    },
    "running_runs": running_runs,
    "ready": len(ready_units),
    "hotpatch_ready": sum(1 for u in ready_units if u.get("hotpatch")),
    "spend": read_json(f"{A}/ci-spend.json") or {},
}

# 控制旋钮：每个旋钮管什么、现在的值。改法：让 CTO 通过 PR 修改 config.template.json。
KNOBS = [
    ("max_workers", "同时在岗的 AI 员工数（开发、返工、评审共用）。", None),
    ("issue_intake.max_ready", "等待合并的单元超过它就暂停接新 issue，先把在制品清掉。", 30),
    ("batch_max", "合并车道每拍最多合并几个。", 4),
    ("loop_breaker_rounds", "连续打回几轮触发一次仲裁评审，再不收敛交 supervisor。", 5),
    ("auto_merge", "自动合并开关。", None),
    ("focus_mode", "all = 全部推进；release = 只推发布路径。", "all"),
    ("tick_seconds", "调度一拍的间隔（秒）。", 120),
    ("models.implement", "开发 / 返工用的模型。", None),
    ("models.review", "质检用的模型。", None),
]
def knob_value(path, default):
    value = cfg
    for part in path.split("."):
        value = value.get(part) if isinstance(value, dict) else None
    return default if value is None else value
knobs = [{"key": k, "value": knob_value(k, d), "meaning": m} for k, m, d in KNOBS]

# ---- CI/CD 尾部：infra 构建与生产部署 ----
infra_runs = (snapshot_section("infra_runs") or [])[:3]
def ssh_out(cmd):
    try:
        return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "cihost", cmd],
                              capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return ""
# 部署事实来自 GitHub Deployment。低频主机对账仍看容器的运行镜像和 compose 发布层；发现与最近记录不符时，把观测写成新的 production Deployment。
RELEASE_DIR_RE = r"/releases/[^/\s,]*?-([0-9a-f]{7,40})/"
def sha_epoch(sha):
    try:
        out = subprocess.run(["git", "-C", ROOT, "show", "-s", "--format=%ct", sha],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        return int(out) if out else None
    except Exception:
        return None
def sha_date(sha):
    e = sha_epoch(sha)
    return time.strftime("%Y-%m-%d", time.gmtime(e)) if e else None
DEPLOYMENT_REPO = os.environ.get("RELEASE_TRAIN_REPO") or os.environ.get("ZF_REPO", "")
DEPLOYMENT_READER = os.path.join(_HERE, "..", "production-deployment-read.sh")
deployment_records = []
deployment_readable = False
try:
    result = subprocess.run(["bash", DEPLOYMENT_READER, DEPLOYMENT_REPO], capture_output=True,
                            text=True, timeout=660)
    if result.returncode == 0:
        deployment_records = json.loads(result.stdout or "[]")
        deployment_readable = isinstance(deployment_records, list)
        if not deployment_readable:
            deployment_records = []
except (OSError, ValueError, subprocess.TimeoutExpired):
    pass

def full_sha(sha):
    try:
        out = subprocess.run(["git", "-C", ROOT, "rev-parse", "--verify", f"{sha}^{{commit}}"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        return out if re.fullmatch(r"[0-9a-f]{40}", out) else None
    except Exception:
        return None

def deployment_images(records):
    digests, sources = {}, {}
    for record in records:
        payload = record.get("payload") or {}
        images = payload.get("images") or {}
        image_shas = payload.get("image_shas") or {}
        fallback = payload.get("sha") or record.get("sha")
        if not isinstance(images, dict):
            continue
        for name, digest in images.items():
            if name in digests or not isinstance(digest, str):
                continue
            source = full_sha(image_shas.get(name) or fallback or "")
            if source:
                digests[name] = digest
                sources[name] = source
    return digests, sources

recorded_digests, recorded_sources = deployment_images(deployment_records)
observed_pairs = {}
RECONCILIATION_MARKER = os.path.join(A, "production-reconciliation-checked")
RECONCILIATION_INTERVAL_SECONDS = 1800  # How often the host is compared with the newest production Deployment record.
try:
    reconciliation_due = time.time() - os.path.getmtime(RECONCILIATION_MARKER) >= RECONCILIATION_INTERVAL_SECONDS
except OSError:
    reconciliation_due = True
if reconciliation_due and deployment_readable and deployment_records:
    inspect_output = ssh_out("docker ps -q | xargs -r docker inspect --format '{{.Image}} "
                              "{{.Config.Image}} {{index .Config.Labels \"com.docker.compose.project.config_files\"}}'")
    for line in inspect_output.splitlines():
        digest, _, rest = line.partition(" ")
        image, _, chain = rest.partition(" ")
        layers = [full_sha(x) for x in re.findall(RELEASE_DIR_RE, chain)]
        layers = [x for x in layers if x and sha_epoch(x)]  # compose overlays are appended per deploy: the last layer is what the container runs
        if not layers or not digest:
            continue
        name = re.sub(r"[:@].*$", "", image.split("/", 1)[-1])
        observed_pairs.setdefault(name, []).append((layers[-1], digest))
    try:
        with open(RECONCILIATION_MARKER, "w", encoding="utf-8") as marker:
            marker.write(str(int(time.time())))
    except OSError:
        pass
observed_sources, observed_digests = {}, {}
for name, pairs in observed_pairs.items():
    source, digest = min(pairs, key=lambda pair: sha_epoch(pair[0]))
    observed_sources[name] = source
    observed_digests[name] = digest

def record_reconciliation():
    if not deployment_readable or not deployment_records or not observed_sources:
        return None
    changed = any(recorded_sources.get(name) != source or recorded_digests.get(name) != observed_digests.get(name)
                  for name, source in observed_sources.items())
    if not changed:
        return None
    sha = max(observed_sources.values(), key=sha_epoch)
    body = {
        "ref": sha, "environment": "production", "auto_merge": False, "required_contexts": [],
        "payload": {"sha": sha, "images": observed_digests, "image_shas": observed_sources,
                    "reconciled": True},
    }
    try:
        created = subprocess.run(["gh", "api", f"repos/{DEPLOYMENT_REPO}/deployments", "--input", "-"],
                                input=json.dumps(body), capture_output=True, text=True, timeout=35)
        if created.returncode != 0:
            raise RuntimeError((created.stderr or "create failed").strip()[:200])
        deployment_id = json.loads(created.stdout or "{}").get("id")
        if not isinstance(deployment_id, int):
            raise RuntimeError("create returned no deployment id")
        status = subprocess.run(["gh", "api", f"repos/{DEPLOYMENT_REPO}/deployments/{deployment_id}/statuses",
                                 "-f", "state=success", "-f", "environment=production",
                                 "-f", "description=reconciled production state"],
                                capture_output=True, text=True, timeout=35)
        if status.returncode != 0:
            raise RuntimeError((status.stderr or "success status failed").strip()[:200])
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"gen_dashboard: production reconciliation record write failed: {exc}", file=sys.stderr)
        return None
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    return {"sha": sha, "success_at": now, "payload": body["payload"]}

reconciled = record_reconciliation()
if reconciled:
    deployment_records.insert(0, reconciled)
_, image_deployed = deployment_images(deployment_records)
dep = sorted(((sha_epoch(x), x) for x in set(image_deployed.values())), reverse=True)
if dep:
    deployed_through = (sha_date(dep[0][1]), dep[0][1])
elif deployment_records:
    latest_sha = full_sha(deployment_records[0].get("sha") or "")
    deployed_through = (sha_date(latest_sha), latest_sha) if latest_sha else (None, None)
else:
    deployed_through = (None, None)

# ---- worktree / branch ----
wt_root = cfg.get("worktree_root") or os.path.join(os.path.expanduser("~"), ".zenoforge", "autopilot-wt")
tmp_wts = sorted(d for d in glob.glob(os.path.join(wt_root, "wt-*")) + glob.glob("/tmp/wt-pr*") if os.path.isdir(d))
try:
    branches = subprocess.run(["git", "-C", ROOT, "branch", "--format", "%(refname:short)"],
                              capture_output=True, text=True, timeout=15).stdout.split()
except Exception:
    branches = []

# ---- 环节漏斗 + 效率 ----
funnel = {}
for u in units:
    funnel[u["stage"]] = funnel.get(u["stage"], 0) + 1
first_pass = sum(1 for u in units for h in u.get("history", []) if h.get("result") == "APPROVE")
rc = sum(1 for u in units for h in u.get("history", []) if h.get("result") == "REQUEST-CHANGES")
def stage_minutes(u):
    h = u.get("history") or []
    if not h: return None
    try:
        t0 = calendar.timegm(time.strptime(h[0]["at"][:19], "%Y-%m-%dT%H:%M:%S"))
        return int((time.time() - t0) // 60)
    except Exception: return None
def stage_times(u):
    h = u.get("history") or []
    ts = []
    try:
        import calendar as _c
        pts = [_c.timegm(time.strptime(x["at"][:19], "%Y-%m-%dT%H:%M:%S")) for x in h]
        for i, x in enumerate(h):
            end = pts[i+1] if i+1 < len(pts) else time.time()
            ts.append({"stage": x["stage"], "min": int((end - pts[i]) // 60)})
    except Exception:
        pass
    return ts
for u in units:
    u["stage_times"] = stage_times(u)

# ---- 工作单旅程：在哪一步、时间花在干活还是等待、是否已上线 ----
WAIT_READY = ("approve", "ci-red", "carried", "land-retry", "merge-issued", "land-issued", "unblock", "unfreeze")
END_MARKS = ("merged", "landed", "closed", "obsolete", "supervisor-close", "pr-closed")
def is_ancestor(sha, tip):
    return bool(sha and tip) and subprocess.run(["git", "-C", ROOT, "merge-base", "--is-ancestor", sha, tip],
                                                capture_output=True, timeout=10).returncode == 0
# 改动只有在它碰到的每个镜像都发布到含它的版本后才算上线。按最新镜像判会把旧镜像里的改动当成已上线：2026-10-21
# 一个镜像一发布，看板就显示"0 项已合并待发布"，实际另一镜像停在 10-18，27 个改动没上线。
# packages/<名> 对应同名镜像；没有可见镜像的包（共享库、运行时包）按最旧的已部署镜像判。
_touched = {}
def touched_packages(sha):
    if sha not in _touched:
        try:
            out = subprocess.run(["git", "-C", ROOT, "show", "--name-only", "--format=", sha],
                                 capture_output=True, text=True, timeout=10).stdout
        except Exception:
            out = ""
        _touched[sha] = {f.split("/")[1] for f in out.split() if f.startswith("packages/") and f.count("/") >= 2}
    return _touched[sha]
def is_released(sha):
    if not sha or not dep:
        return False
    pkgs = touched_packages(sha)
    targets = {image_deployed[p] for p in pkgs if p in image_deployed}
    if pkgs - set(image_deployed):
        targets.add(dep[-1][1])
    return all(is_ancestor(sha, t) for t in (targets or {deployed_through[1]}))
def journey(u, now):
    marks = [(epoch_of(h.get("at", "")), h.get("stage") or h.get("ev") or "") for h in u.get("history") or []]
    marks = [m for m in marks if m[0]]
    split = {"work": 0, "ready": 0, "supervisor": 0}
    end = now
    for i, (t, st) in enumerate(marks):
        if st in END_MARKS:
            end = t
            break
        nxt = marks[i + 1][0] if i + 1 < len(marks) else now
        bucket = ("supervisor" if st == "supervisor-escalated"
                  else "ready" if any(k in st for k in WAIT_READY) else "work")
        split[bucket] += max(0, nxt - t) // 60
    stage = u.get("stage", "")
    last = marks[-1][1] if marks else ""
    sha = u.get("merge_sha") or u.get("land_sha")
    if stage == "landed":
        status = "live"          # 流水线脚本：main 就是它的发布
    elif stage == "merged":
        status = "reverted" if last == "merge-reverted" else "released" if is_released(sha) else "awaiting-release"
    elif stage in ("closed", "done"):
        status = "closed"
    elif stage == "blocked-external":
        status = "blocked"       # 等前置 issue 交付后自动恢复，不是等主管
    elif stage == "parked":
        status = "parked"       # supervisor 裁决搁置（#4369）：不等人，也不派工
    elif stage == "supervisor-review" or stage == "needs-human":
        status = "waiting"
    elif stage in ("ready-to-merge", "landing"):
        status = "merge"
    elif stage.startswith(("review", "rereview", "repair")):
        status = "check"
    else:
        status = "develop"
    return {"status": status, "age_min": int(max(0, end - marks[0][0]) // 60) if marks else 0,
            "since_min": int(max(0, now - marks[-1][0]) // 60) if marks else 0,
            "split_min": {k: int(v) for k, v in split.items()},
            "rounds": sum(1 for _, st in marks if st in ("review-request-changes", "review-block"))}
eff_units = [{"id": u["id"], "age_min": stage_minutes(u), "tokens": u.get("tokens", 0)} for u in units]

alerts = []
for f in sorted(glob.glob(f"{A}/alerts/*.md"), key=os.path.getmtime)[-12:]:
    alerts += [l for l in open(f, errors="ignore").read().splitlines() if l.strip()][-3:]

def epoch_of(value):
    try:
        parsed = time.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")
        return calendar.timegm(parsed)
    except Exception:
        return None

if cfg.get("focus_mode", "all") == "release":
    merge_epochs = [epoch_of(h.get("at", "")) for u in units for h in u.get("history", [])
                    if h.get("stage") in ("merged", "landed")]
    merge_epochs = [value for value in merge_epochs if value is not None]
    if merge_epochs:
        last_merge_epoch = max(merge_epochs)
    else:
        unit_starts = [epoch_of((u.get("history") or [{}])[0].get("at", "")) for u in units]
        unit_starts = [value for value in unit_starts if value is not None]
        last_merge_epoch = min(unit_starts) if unit_starts else time.time()
    if time.time() - last_merge_epoch > 7200:
        alerts.append("[focus] bottleneck: release mode has had no merged unit for over 2 hours; inspect the release gate and critical queue")

for u in units:
    u["journey"] = journey(u, time.time())
merged_count = sum(1 for u in units if u.get("stage") in ("merged", "landed"))

# ---- 前段：收单 → triage → advisor → 实现队列 → 发布等待 ----
# 只读。每一块各自 try：GitHub 或 lib.sh 出错只让那一块显示"数据不可用"，其余照常。每个数字的健康线 / 不健康线
# 写在 front.standards（结构同 ci_standards），状态在 front.status，看板只负责画。
# GitHub 计数缓存 5 分钟（缓存文件在 dashboard.data.js 旁边）；失败时最多沿用 30 分钟前的缓存并标注。
dashboard_output = os.environ.get("MAC_AUTOPILOT_DASHBOARD_OUTPUT", f"{A}/dashboard.data.js")
FRONT_CACHE_PATH = os.environ.get("MAC_AUTOPILOT_FRONT_CACHE",
                                  os.path.join(os.path.dirname(os.path.abspath(dashboard_output)), "front-cache.json"))
FRONT_CACHE_SECONDS, FRONT_STALE_SECONDS = 300, 1800
# (label, 名称, 数量健康, 数量不健康, 滞留小时健康, 滞留小时不健康, 含义)；顺序即流水线顺序（docs/agents/issue-pipeline.md "Chain"）。
# 初值：triage / advisor 每 5 分钟一拍，积压应在几小时内清空；ready-for-agent 按约 2 天 / 5 天产能；
# 等人回复和等 PR 落地的阶段允许以天计。数字不对就改这里和 NODE-HEALTH.md，不要放宽判断。
FRONT_STAGES = [
    ("needs-triage", "待分诊", 10, 30, 6, 24, "新 issue 等 triage 批处理。积压久 = triage 没在跑或每批处理太少。"),
    ("finish-first", "先等已有 PR", 20, 50, 48, 120, "已有 PR 覆盖同一范围，等它落地后回到待分诊。久 = 那个 PR 卡住了。"),
    ("needs-info", "等提单人回复", 10, 30, 72, 168, "等提单人回答问题（人的时间，允许以天计）。久 = 该催或关。"),
    ("needs-advisor", "待顾问裁决", 10, 30, 12, 48, "分诊 / 实现判断不了的票等 advisor 批处理裁决。久 = 顾问批处理没产出。"),
    ("needs-recut", "待拆票", 5, 15, 24, 72, "顾问判定过大，等拆成子票。"),
    ("ready-for-agent", "待实现队列", 60, 150, 168, 336, "已就绪、等 autopilot 接单实现的票（约 2 天 / 5 天产能）。久 = 低优先级被饿死或接单口径过窄。"),
    ("awaiting-release", "已合并等发布", 40, 80, 24, 72, "代码已合并、还没有生产验收证据的票。久 = 发布列车挡住了或验收没跑。"),
    ("awaiting-pipeline-sync", "直落等入库", 3, 10, 2, 12, "非产品票的提交已推送，等流水线检出看到它。久 = 同步停了。"),
]
FRONT_ADVISOR_FAIL = ("job-failed", "job-timeout", "prompt-quarantined", "model-config-blocked",
                      "browser-unavailable", "persistence-retry", "selection-incomplete")
front_standards, front_values, front_na = {}, {}, set()

def front_std(key, desc, healthy, unhealthy, higher, unit, meaning, source):
    front_standards[key] = {"desc": desc, "healthy": healthy, "unhealthy": unhealthy, "higher_is_better": higher,
                            "unit": unit, "meaning": meaning, "source": source}

def front_judge(value, sd):
    if value is None or not sd:
        return "NO-DATA"
    if (value >= sd["healthy"]) if sd["higher_is_better"] else (value <= sd["healthy"]):
        return "OK"
    if (value <= sd["unhealthy"]) if sd["higher_is_better"] else (value >= sd["unhealthy"]):
        return "UNHEALTHY"
    return "WARN"

def front_error(ex):
    text = (str(ex).strip().splitlines() or [type(ex).__name__])[-1]
    return (type(ex).__name__ + ": " + text)[:240]

def front_hours_since(epoch, now):
    return None if epoch is None else round(max(0, now - epoch) / 3600, 1)

def front_run(argv, timeout, **kw):
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, **kw)
    if proc.returncode != 0:
        raise RuntimeError(f"{argv[0]} exit {proc.returncode}: " + ((proc.stderr or "").strip().splitlines() or [""])[-1][:200])
    return proc.stdout

def front_unit_active(pattern):
    """正在运行的 systemd 用户单元名（按通配符）；systemctl 不可用返回 None。"""
    try:
        out = subprocess.run(["systemctl", "--user", "list-units", pattern, "--state=active", "--no-legend", "--plain"],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return None
    return [line.split()[0] for line in out.splitlines() if line.strip()]

def front_cache_get(now, max_age):
    cached = (read_json(FRONT_CACHE_PATH) or {}).get("github")
    if isinstance(cached, dict) and isinstance(cached.get("stages"), list) and isinstance(cached.get("fetched_epoch"), (int, float)):
        age = now - cached["fetched_epoch"]
        if 0 <= age < max_age:
            return cached, age
    return None, None

def front_github_stages(now):
    cached, age = front_cache_get(now, FRONT_CACHE_SECONDS)
    if cached:
        return cached["stages"], {"cached": True, "stale": False, "age_s": int(age), "error": None}
    try:
        query = ("query($owner:String!,$name:String!){repository(owner:$owner,name:$name){" +
                 "".join(f'a{i}:issues(states:OPEN,labels:["{row[0]}"],first:1,orderBy:{{field:UPDATED_AT,direction:ASC}})'
                         "{totalCount nodes{number createdAt updatedAt}} " for i, row in enumerate(FRONT_STAGES)) + "}}")
        payload = json.loads(front_run(["gh", "api", "graphql", "-F", "owner={owner}", "-F", "name={repo}", "-f", "query=" + query], 30))
        repo = ((payload or {}).get("data") or {}).get("repository") if isinstance(payload, dict) else None
        if not isinstance(repo, dict):
            first = ((payload.get("errors") or [{}])[0].get("message") if isinstance(payload, dict) else None) or "GitHub 返回无数据"
            raise RuntimeError(str(first)[:200])
        stages = []
        for i, row in enumerate(FRONT_STAGES):
            block = repo.get(f"a{i}") or {}
            node = (block.get("nodes") or [None])[0] or {}
            stages.append({"label": row[0], "count": block.get("totalCount"),
                           "oldest": {"number": node.get("number"), "created_at": node.get("createdAt"), "updated_at": node.get("updatedAt")} if node else None})
        if all(s["count"] is None for s in stages):
            raise RuntimeError("GitHub 返回的阶段计数为空")
        try:
            tmp = FRONT_CACHE_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as out:
                json.dump({"github": {"fetched_epoch": now, "stages": stages}}, out, ensure_ascii=False)
            os.replace(tmp, FRONT_CACHE_PATH)
        except OSError:
            pass
        return stages, {"cached": False, "stale": False, "age_s": 0, "error": None}
    except Exception as ex:
        stale, age = front_cache_get(now, FRONT_STALE_SECONDS)
        if stale:
            return stale["stages"], {"cached": True, "stale": True, "age_s": int(age), "error": front_error(ex)}
        raise

def front_stage_rows(now):
    raw, meta = front_github_stages(now)
    by_label = {s["label"]: s for s in raw}
    rows = []
    for label, name, c_ok, c_bad, i_ok, i_bad, meaning in FRONT_STAGES:
        s = by_label.get(label) or {}
        oldest, count = s.get("oldest"), s.get("count")
        idle = 0 if count == 0 else front_hours_since(epoch_of(oldest.get("updated_at") or "") if oldest else None, now)
        rows.append({"label": label, "name": name, "count": count, "oldest": oldest, "idle_hours": idle})
        front_std(f"stage.{label}.count", f"{name}（{label}）数量", c_ok, c_bad, False, "个", meaning,
                  "GitHub GraphQL：该标签的开放 issue 数")
        front_std(f"stage.{label}.idle_hours", f"{name}最久滞留", i_ok, i_bad, False, "小时",
                  "该阶段里最久没动的那张票，距上次更新多久（label 变化或评论都会刷新，是时间下限）。" + meaning,
                  "GitHub GraphQL：该标签下 updatedAt 最早的 issue")
        front_values[f"stage.{label}.count"] = count
        front_values[f"stage.{label}.idle_hours"] = idle
    return rows, meta

def front_advisor_snapshot():
    script = ('source engine/lib.sh >/dev/null 2>&1 || { echo "cannot source engine/lib.sh" >&2; exit 3; }\n'
              "set -o pipefail\n"
              "advisor_batch_job_json | jq -c '{job_id, started_at, input_bytes, members: [.members[]? | .issue]}' || exit 4\n"
              "echo ---\n"
              "advisor_batch_state_read | jq -c '[.deferred_issue_ids[]?]' || exit 4\n"
              'echo "${LOG_DIR:-}"\n')
    job_text, _, rest = front_run(["bash", "-c", script], 30, cwd=ROOT).partition("---\n")
    deferred_text, _, log_dir = rest.partition("\n")
    job = json.loads(job_text) if job_text.strip() else None
    return job, json.loads(deferred_text or "[]"), log_dir.strip()

def front_advisor_results(log_dir):
    """批处理每拍写一个 advisor-batch-<时间>.result.json（outcome / applied_count）；今日失败数、最后一次裁决都从它来。"""
    names = sorted(glob.glob(os.path.join(log_dir, "advisor-batch-*.result.json")), reverse=True)[:800]
    out = {"ticks_today": 0, "failures_today": 0, "applied_today": 0, "outcomes_today": {}, "last_tick_at": None,
           "last_outcome": None, "last_ruling_at": None, "last_ruling_applied": None, "log_since": None, "files": len(names)}
    for path in names:
        result = read_json(path)
        if not isinstance(result, dict):
            continue
        at = result.get("recorded_at")
        out["log_since"] = at or out["log_since"]
        if out["last_tick_at"] is None:
            out["last_tick_at"], out["last_outcome"] = at, result.get("outcome")
        applied = as_int(result.get("applied_count"))
        if applied and out["last_ruling_at"] is None:
            out["last_ruling_at"], out["last_ruling_applied"] = at, applied
        if session_date_of(at) == today_text:
            outcome = str(result.get("outcome") or "unknown")
            out["ticks_today"] += 1
            out["applied_today"] += applied
            out["outcomes_today"][outcome] = out["outcomes_today"].get(outcome, 0) + 1
            if outcome in FRONT_ADVISOR_FAIL or as_int(result.get("exit_code")):
                out["failures_today"] += 1
    return out

def front_advisor_panel(now, waiting):
    job, deferred, log_dir = front_advisor_snapshot()
    log_dir = log_dir or os.path.join(AGENT_HOME, "logs")
    results = front_advisor_results(log_dir)
    units_active = front_unit_active("zf-web-advisor-provider-*")
    job_age_min = round((now - job["started_at"]) / 60, 1) if job and isinstance(job.get("started_at"), (int, float)) else None
    last_ruling = epoch_of(results["last_ruling_at"] or "")
    since_epoch = epoch_of(results["log_since"] or "")
    # 积压为 0 时没有"久未裁决"这回事（不判）；没有任何裁决记录时，以日志起点为下限。
    lag_known = last_ruling is not None
    lag = front_hours_since(last_ruling if lag_known else since_epoch, now)
    if waiting == 0:
        front_na.add("advisor.ruling_lag_hours")
    panel = {
        "job": ({"job_id": job.get("job_id"), "started_epoch": job.get("started_at"), "age_min": job_age_min,
                 "input_bytes": job.get("input_bytes"), "members": job.get("members") or [],
                 "worker_active": (any(str(job.get("job_id")) in name for name in units_active) if units_active is not None else None)}
                if job else None),
        "deferred": deferred, "waiting": waiting, **results,
        "ruling_lag_is_lower_bound": (not lag_known) and waiting != 0,
    }
    front_std("advisor.job_age_min", "顾问批处理本轮已运行", 20, 60, False, "分钟",
              "批处理任务从启动到现在多久。过去的批次 3–15 分钟内出结果或失败；一小时还没动静 = 卡住，等超时或人工处理。",
              "lib.sh advisor_batch_job_json 的 started_at")
    front_std("advisor.failures_today", "顾问批处理今日失败次数", 2, 6, False, "次",
              "今日（会话日）批处理拍里 outcome 为失败类（job-failed / 超时 / 隔离 / provider 不可用等）的次数。偶发 1–2 次是网络，成批 = 顾问通道坏了。",
              "日志 advisor-batch-*.result.json")
    front_std("advisor.ruling_lag_hours", "距上次顾问裁决（有积压时）", 6, 24, False, "小时",
              "上一次批处理真正落下裁决（applied_count > 0）到现在多久；没有待裁决的票时不判。日志里一次裁决都没有时，按日志起点算下限。积压在等而它一直变大 = 顾问环节没产出。",
              "日志 advisor-batch-*.result.json 的 applied_count")
    front_values["advisor.job_age_min"] = job_age_min if job else 0
    front_values["advisor.failures_today"] = results["failures_today"]
    front_values["advisor.ruling_lag_hours"] = lag
    return panel

def front_advisor_loop_panel(now):
    """autopilot 评审循环里的顾问（第 2 次打回后问顾问）：裁决进 units 的 .cto_rulings，事件记在 history。"""
    counts, last = {"advisor-ruling": 0, "advisor-unavailable": 0}, {"advisor-ruling": None, "advisor-unavailable": None}
    for u in units:
        for h in u.get("history") or []:
            kind = h.get("stage") or h.get("ev")
            if kind not in counts:
                continue
            when = epoch_of(h.get("at", ""))
            if when and session_date_of(h.get("at")) == today_text:
                counts[kind] += 1
            if when and (last[kind] is None or when > last[kind]):
                last[kind] = when
    asked = counts["advisor-ruling"] + counts["advisor-unavailable"]
    pct = round(100 * counts["advisor-unavailable"] / asked) if asked else None
    front_std("advisor_loop.fail_pct_today", "评审循环顾问：今日没拿到裁决的比例", 10, 50, False, "%",
              "与体检指标 loop.advisor_fail_pct 同一条线，只算今日。高 = 顾问 provider 不可用，返工照常继续但没有顾问意见。",
              "units.json 历史：advisor-unavailable ÷（advisor-ruling + advisor-unavailable）")
    front_values["advisor_loop.fail_pct_today"] = pct
    iso = lambda e: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e)) if e else None
    return {"rulings_today": counts["advisor-ruling"], "unavailable_today": counts["advisor-unavailable"],
            "last_ruling_at": iso(last["advisor-ruling"]), "last_unavailable_at": iso(last["advisor-unavailable"]),
            "asking_now": sum(1 for u in units if u.get("advisor_pid") is not None and alive(u.get("advisor_pid")))}

def front_triage_panel(now, backlog):
    """triage 的记录在流水线效率账 metrics/efficiency-YYYY-MM.jsonl：run-triage*.sh 每分诊完一张票写一条 stage-exited needs-triage。"""
    months = {datetime.fromtimestamp(t, ZoneInfo("UTC")).strftime("%Y-%m") for t in (now, now - 86400 * 2)}
    done, entered, last = set(), {}, None
    for month in sorted(months):
        path = os.path.join(AGENT_HOME, "metrics", f"efficiency-{month}.jsonl")
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as stream:
                stream.seek(max(0, size - 6_000_000))
                lines = stream.read().decode(errors="ignore").splitlines()[1 if size > 6_000_000 else 0:]
        except OSError:
            continue
        for line in lines:
            if '"run-triage' not in line:
                continue
            try: ev = json.loads(line)
            except ValueError: continue
            if not str(ev.get("writer", "")).startswith("run-triage"):
                continue
            when = epoch_of(ev.get("ts", ""))
            if not when:
                continue
            if ev.get("event_type") == "stage-exited" and ev.get("stage") == "needs-triage":
                last = max(last or 0, when)
                if session_date_of(ev.get("ts")) == today_text:
                    done.add(ev.get("issue"))
            elif ev.get("event_type") == "stage-entered" and session_date_of(ev.get("ts")) == today_text:
                entered[ev.get("stage")] = entered.get(ev.get("stage"), 0) + 1
    batches = sorted(glob.glob(os.path.join(AGENT_HOME, "logs", "triage-triage-batch-*.log")))
    batch_stamp = re.search(r"-(\d{8}T\d{6}Z)-", os.path.basename(batches[-1])) if batches else None
    batch_at = (datetime.strptime(batch_stamp.group(1), "%Y%m%dT%H%M%SZ").strftime("%Y-%m-%dT%H:%M:%SZ")) if batch_stamp else None
    running = front_unit_active("zf-triage-batch.service")
    idle_min = None if last is None else round((now - last) / 60)
    if backlog == 0:  # 没有积压就没有"该出活而没出活"，两条都不判
        front_na.update(("triage.last_done_age_min", "triage.done_today"))
    front_std("triage.last_done_age_min", "距上次分诊完成一张票（有积压时）", 30, 120, False, "分钟",
              "triage 每 5 分钟一拍；待分诊有积压时，上一张票分诊完成到现在超过 2 小时 = triage 没在出活。没有积压时不判。",
              "流水线效率账 efficiency-*.jsonl：run-triage*.sh 的 stage-exited needs-triage")
    front_std("triage.done_today", "今日已分诊的票", 20, 5, True, "张",
              "今日（会话日）分诊完成的不同 issue 数。待分诊有积压时它应当接近每日来单量；没有积压时不判。",
              "流水线效率账 efficiency-*.jsonl")
    front_values["triage.last_done_age_min"] = idle_min
    front_values["triage.done_today"] = len(done)
    return {"done_today": len(done), "last_done_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(last)) if last else None,
            "last_batch_at": batch_at, "running": (bool(running) if running is not None else None),
            "routed_today": entered, "backlog": backlog}

def front_release_panel(now, awaiting):
    train = release_train_state
    alerts_path = f"{A}/alerts/release.md"
    held_lines = []
    try:
        with open(alerts_path, encoding="utf-8", errors="ignore") as stream:
            held_lines = [l for l in stream.read().splitlines()[-400:] if "RELEASE-HELD" in l]
    except OSError:
        pass
    last_line = held_lines[-1] if held_lines else ""
    cand = re.search(r"candidate=([0-9a-f]+)", last_line)
    held_epochs = [epoch_of(l.lstrip("[")) for l in held_lines if cand and f"candidate={cand.group(1)} " in l]
    held_epochs = [e for e in held_epochs if e]
    held_images = []
    if "supervised release needed:" in last_line:
        for part in last_line.split("supervised release needed:", 1)[1].split(";"):
            image, _, why = part.strip().partition("\t")
            if image:
                held_images.append({"image": image, "reason": why.strip()})
    holding = train.get("status") == "held"
    hold_hours = front_hours_since(min(held_epochs), now) if (holding and held_epochs) else (0 if not holding else None)
    deployed_sha = deployed_through[1]
    main_sha = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=10).stdout.strip()
    deployed_epoch, main_epoch = (sha_epoch(deployed_sha) if deployed_sha else None), sha_epoch(main_sha)
    lag = round(max(0, main_epoch - deployed_epoch) / 3600, 1) if deployed_epoch and main_epoch else None
    behind = None
    if deployed_sha and main_sha:
        out = subprocess.run(["git", "-C", ROOT, "rev-list", "--count", f"{deployed_sha}..{main_sha}"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        behind = int(out) if out.isdigit() else None
    front_std("release.hold_hours", "发布列车被挡住了多久", 2, 8, False, "小时",
              "列车状态为 held（待主管发布：新 migration / fleet 滚动）时，同一候选被挡的时长；没被挡记 0。自动发布已授权，挡住超过 8 小时就是流程缺口。",
              "release-train.json 的 status + alerts/release.md 的 RELEASE-HELD")
    front_std("release.main_ahead_hours", "生产落后 main 的小时数", 6, 24, False, "小时",
              "生产最新已部署提交与 main 头提交的时间差。发布列车每 15 分钟一拍，落后超过 24 小时 = 发布环节卡住。",
              "production Deployment / 容器 compose 目录里的提交 × git 提交时间")
    front_values["release.hold_hours"] = hold_hours
    front_values["release.main_ahead_hours"] = lag
    return {"train_status": train.get("status"), "candidate": train.get("candidate"), "held": holding,
            "held_since": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(min(held_epochs))) if held_epochs else None,
            "last_held_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(max(held_epochs))) if held_epochs else None,
            "held_images": held_images, "last_held_line": last_line[:600],
            "prod_sha": (deployed_sha or "")[:12] or None, "main_sha": main_sha[:12] or None,
            "main_ahead_commits": behind, "awaiting_release": awaiting}

release_train_state = read_json(f"{A}/release-train.json") or {}
front = {"errors": {}}
front_now = front_started = time.time()
try:
    front["stages"], front["github"] = front_stage_rows(front_now)
except Exception as ex:
    front["stages"], front["github"] = [], None
    front["errors"]["stages"] = front_error(ex)
def front_count(label):
    return next((s["count"] for s in front["stages"] if s["label"] == label), None)
for section, build in (
    ("advisor", lambda: front_advisor_panel(front_now, front_count("needs-advisor"))),
    ("advisor_loop", lambda: front_advisor_loop_panel(front_now)),
    ("triage", lambda: front_triage_panel(front_now, front_count("needs-triage"))),
    ("release", lambda: front_release_panel(front_now, front_count("awaiting-release"))),
):
    try:
        front[section] = build()
    except Exception as ex:
        front[section] = None
        front["errors"][section] = front_error(ex)
front["standards"] = front_standards
front["values"] = front_values
front["status"] = {k: ("N/A" if k in front_na else front_judge(front_values.get(k), sd)) for k, sd in front_standards.items()}
front["elapsed_s"] = round(time.time() - front_started, 2)

data = {
    "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "repo": os.environ.get("ZF_REPO", ""),
    "units": units, "workers": wl, "release": release, "cost": cost_data, "cost_ledger": cost_ledger,
    "traffic": traffic, "front": front,
    "release_train": (json.load(open(f"{A}/release-train.json")) if os.path.exists(f"{A}/release-train.json") else {}),
    "config": {
        "models": cfg["models"], "max_workers": cfg["max_workers"],
        "daily_token_budget": cfg["daily_token_budget"],
        "pricing": pricing, "pricing_note": cfg.get("pricing_note", ""),
        "focus_mode": cfg.get("focus_mode", "all"),
        "auto_merge": cfg.get("auto_merge"), "tick_seconds": cfg.get("tick_seconds"),
        "waste": cfg.get("waste", {}),
    },
    "totals": {
        "issues_open": len(issues_open), "needs_triage": needs_triage,
        "prs_open": len(prs_open), "merged_today": merged_today,
        "worktrees": tmp_wts, "branches": branches,
        "suites": suites, "ci": ci,
        "infra_latest": (infra_runs[0] if infra_runs else {}),
        "deployed_through": {"sha": (deployed_through[1] or "")[:12], "date": deployed_through[0]},
        "main_head": subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"],
                      capture_output=True, text=True, timeout=10).stdout.strip(),
    },
    "funnel": funnel,
    "efficiency": {
        "review_first_pass": first_pass, "review_sent_back": rc,
        "delivered_reports": sum(1 for w in wl if w["output"]),
        "wasted_workers": sum(1 for w in wl if not w["alive"] and not w.get("harvested") and not w["output"]),
        "total_tokens": sum(w["tokens"] for w in wl),
        "eff_units": eff_units,
    },
    "summary": {
        "live_workers": sum(1 for w in wl if w["alive"]), "max_workers": cfg["max_workers"],
        "total_tokens": sum(w["tokens"] for w in wl),
        "ready_to_merge": funnel.get("ready-to-merge", 0), "merged": merged_count,
        "real_daily_tokens": real_daily_tokens,
        "billable_daily_tokens": cost_data["today"]["billable"],
        "real_daily_cost": cost_data["today"]["dollars"],
        "sessions_today": cost_data["today"]["sessions"],
        "tokens_per_merged": real_daily_tokens / merged_count if merged_count else 0,
        "dollars_per_merged": cost_data["today"]["dollars"] / len(merged_today) if merged_today else 0,
        "focus_mode": cfg.get("focus_mode", "all"),
        "alert_count": len(alerts),
    },
    "alerts_tail": alerts[-8:],
    "ci_live": ci_live,
    "knobs": knobs,
    # One source of standards: node_health.py writes the scorecard, meanings and work-order bounds each tick.
    "standards": {**(read_json(f"{A}/node-health.json") or {}), "paused": current_pause()},
}
# Write then rename: the page re-reads this file every 30 s, and an in-place write let it catch a half-written file.
with open(dashboard_output + ".tmp", "w") as out:
    out.write("window.DASH=" + json.dumps(data, ensure_ascii=False) + ";")
os.replace(dashboard_output + ".tmp", dashboard_output)
