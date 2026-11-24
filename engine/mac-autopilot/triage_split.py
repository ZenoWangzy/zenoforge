"""待分诊共享筛选：dispatcher、batch log 与 dashboard 共用排除规则。"""
import fcntl, json, os, sys, time
from config_paths import zf_config_file

ROADMAP_LABELS = ("roadmap", "roadmap-theme", "roadmap-epic")
EXCLUSION_NAMES = {
    "roadmap": "路线图排序", "system": "系统通道", "session_owned": "会话持有",
    "on_hold": "暂停中", "model_backoff": "模型退避", "retry_deferred": "等待刷新",
    "scheduler_inflight": "调度器处理中",
}
TOOLTIPS = {
    "roadmap": "带 roadmap / roadmap-theme / roadmap-epic 标签：路线图排序开启时，这类票按路线图的顺序安排，不走 triage 逐张分诊，所以不计入待分诊。",
    "system": "带系统通道标签（nonproduct-lane-routing 裁决里的标签，如 pipeline-system）：归系统通道处理（流水线运维票），不走产品 triage，所以不计入待分诊。",
    "session_owned": "带 session-owned 标签：由现有会话持有，不由 dispatcher 派发，不计入待分诊。",
    "on_hold": "带 on-hold 标签：暂停 triage 派发，不计入待分诊。",
    "model_backoff": "issue 状态中的模型退避仍未到期，不计入待分诊。",
    "retry_deferred": "issue 状态中的 triage 刷新重试时间仍未到期，不计入待分诊。",
    "scheduler_inflight": "units.json 中存在非终态的 issue 单元，或 issue 正在 triage 批处理中，不计入待分诊。",
}
EXCLUSION_ORDER = ("session_owned", "system", "roadmap", "on_hold", "model_backoff", "retry_deferred", "scheduler_inflight")
TRIAGE_PAGE_QUERY = ('query($owner:String!,$name:String!,$after:String!){repository(owner:$owner,name:$name){'
                     'issues(states:OPEN,labels:["needs-triage"],first:100,after:$after,'
                     'orderBy:{field:UPDATED_AT,direction:ASC}){totalCount nodes{number title createdAt updatedAt '
                     'labels(first:100){nodes{name}}} pageInfo{endCursor hasNextPage}}}}')


def graphql_stage_fields(stages):
    fields = []
    for i, row in enumerate(stages):
        label = row[0]
        page_size = 100 if label == "needs-triage" else 10
        page_info = " pageInfo{endCursor hasNextPage}" if label == "needs-triage" else ""
        fields.append(f'a{i}:issues(states:OPEN,labels:["{label}"],first:{page_size},'
                      'orderBy:{field:UPDATED_AT,direction:ASC})'
                      '{totalCount nodes{number title createdAt updatedAt labels(first:100){nodes{name}}}'
                      + page_info + '}')
    return " ".join(fields)


def complete_needs_triage_pages(block, owner, name, run):
    nodes, total = list(block.get("nodes") or []), block.get("totalCount")
    page = block.get("pageInfo") or {}
    while page.get("hasNextPage") is True:
        cursor = page.get("endCursor")
        if not isinstance(cursor, str) or not cursor:
            raise RuntimeError("待分诊分页缺少下一页游标")
        args = ["gh", "api", "graphql", "-F", f"owner={owner}", "-F", f"name={name}", "-F", f"after={cursor}", "-f", "query=" + TRIAGE_PAGE_QUERY]
        payload = json.loads(run(args, 30))
        repo = ((payload or {}).get("data") or {}).get("repository") if isinstance(payload, dict) else None
        following = repo.get("issues") if isinstance(repo, dict) else None
        if not isinstance(following, dict) or following.get("totalCount") != total:
            raise RuntimeError("待分诊分页计数变化或 GitHub 返回无数据")
        nodes.extend(following.get("nodes") or [])
        page = following.get("pageInfo") or {}
    if total != len(nodes):
        raise RuntimeError(f"待分诊 {total} 张，分页读取到 {len(nodes)} 张")
    block["nodes"] = nodes
    return block


def system_lane_labels():
    # 同 pipeline_system_issue_labels_json：读不到或为空就报错，不当成"没有系统通道票"
    path = zf_config_file("state/rulings.json")
    if not path:
        raise RuntimeError("没有 state/rulings.json，无法读系统通道标签")
    rulings = json.load(open(path)).get("rulings") or []
    labels = {l for r in rulings if r.get("id") == "nonproduct-lane-routing"
              for l in ((r.get("membership") or {}).get("labels") or [])}
    if not labels or not all(isinstance(l, str) and l for l in labels):
        raise RuntimeError("nonproduct-lane-routing 裁决没有系统通道标签")
    return labels


def roadmap_order_on():
    override = os.environ.get("ZF_PIPELINE_ROADMAP_SWITCH")
    if override:
        return override == "true"
    policy = os.environ.get("MODEL_POLICY_FILE") or os.path.join(
        os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME") or os.path.expanduser("~/.zenoforge"), "model-policy.json")
    try:
        return json.load(open(policy)).get("switches", {}).get("roadmap-order") is True
    except (OSError, ValueError, AttributeError):
        return False


def _labels(issue):
    raw = issue.get("labels") or []
    if isinstance(raw, dict):
        raw = raw.get("nodes") or []
    return {row.get("name") for row in raw if isinstance(row, dict) and isinstance(row.get("name"), str)}


def _json_file(path, description):
    try:
        with open(path, encoding="utf-8") as stream:
            return json.load(stream)
    except (OSError, ValueError, UnicodeDecodeError) as error:
        raise RuntimeError(f"{description} unavailable: {path}") from error


def _runtime_dir():
    configured = os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR")
    if configured:
        return configured
    repo = os.environ.get("REPO_DIR") or os.environ.get("ZF_REPO_DIR")
    if not repo:
        here = os.path.dirname(os.path.realpath(__file__))
        marker = "/.scratch-supervisor/autopi"
        repo = here.split(marker, 1)[0] if marker in here else os.path.dirname(os.path.dirname(here))
    return os.path.join(repo, ".scratch-supervisor", "autopi")


def _scheduler_inflight_ids():
    runtime = _runtime_dir()
    if not runtime or not os.path.isdir(runtime):
        return set()
    units_path = os.path.join(runtime, "units.json")
    doc = _json_file(units_path, "scheduler unit ledger")
    if not isinstance(doc, dict) or not isinstance(doc.get("units"), list):
        raise RuntimeError("scheduler unit ledger malformed")
    terminal = {"merged", "landed", "closed", "done", "wontfix", "duplicate"}
    return {
        row.get("issue") for row in doc["units"]
        if isinstance(row, dict) and type(row.get("issue")) is int
        and not (isinstance(row.get("stage"), str) and row["stage"] in terminal)
    }


def _active_batch_ids():
    home = os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME") or os.path.expanduser("~/.zenoforge")
    lock_path, marker = os.path.join(home, "triage-batch.lock"), os.path.join(home, "triage-batch-active.json")
    if not os.path.isfile(lock_path) or not os.path.isfile(marker):
        return set()
    try:
        with open(lock_path, "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                doc = _json_file(marker, "triage batch marker")
                if not isinstance(doc, dict) or not isinstance(doc.get("issues"), list):
                    raise RuntimeError("triage batch marker malformed")
                return {issue for issue in doc["issues"] if type(issue) is int}
            finally:
                try:
                    fcntl.flock(lock, fcntl.LOCK_UN)
                except OSError:
                    pass
    except OSError as error:
        raise RuntimeError("triage batch lock unavailable") from error
    return set()


def _state(issue_number):
    home = os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME") or os.path.expanduser("~/.zenoforge")
    path = os.path.join(home, "state", f"{issue_number}.json")
    try:
        return _json_file(path, "issue state") if os.path.isfile(path) else {}
    except RuntimeError:
        return {}


def _epoch(value):
    if isinstance(value, int):
        return value
    return int(value) if isinstance(value, str) and value.isdecimal() else 0


def exclusion_reason(issue, now=None, lane_labels=None, roadmap_on=None, inflight=None, batch_active=None):
    number = issue.get("number")
    labels = _labels(issue)
    state = _state(number) if isinstance(number, int) else {}
    now = int(time.time()) if now is None else int(now)
    lane_labels = system_lane_labels() if lane_labels is None else lane_labels
    roadmap_on = roadmap_order_on() if roadmap_on is None else roadmap_on
    inflight = _scheduler_inflight_ids() if inflight is None else inflight
    batch_active = _active_batch_ids() if batch_active is None else batch_active
    if "session-owned" in labels:
        return "session_owned"
    if labels & lane_labels:
        return "system"
    if roadmap_on and labels & set(ROADMAP_LABELS):
        return "roadmap"
    if "on-hold" in labels:
        return "on_hold"
    backoff_state = state.get("model_failure_backoff") if isinstance(state, dict) else None
    backoff = _epoch(backoff_state.get("until_epoch")) if isinstance(backoff_state, dict) else 0
    if backoff > now:
        return "model_backoff"
    retry_after = _epoch(state.get("triage_retry_after_epoch")) if isinstance(state, dict) else 0
    if "founder-test" not in labels and retry_after > now:
        return "retry_deferred"
    if number in inflight or number in batch_active:
        return "scheduler_inflight"
    return None


def filter_issues(issues, now=None):
    if not isinstance(issues, list):
        raise RuntimeError("triage candidate snapshot malformed")
    lane_labels, roadmap_on = system_lane_labels(), roadmap_order_on()
    inflight, batch_active = _scheduler_inflight_ids(), _active_batch_ids()
    eligible, excluded = [], {key: 0 for key in EXCLUSION_ORDER}
    for issue in issues:
        reason = exclusion_reason(issue, now, lane_labels, roadmap_on, inflight, batch_active)
        if reason:
            excluded[reason] += 1
        else:
            eligible.append(issue)
    return eligible, excluded


def cache_has_filter(cached):
    required = set(EXCLUSION_ORDER)
    return any(isinstance(stage, dict) and stage.get("label") == "needs-triage"
               and isinstance(stage.get("excluded"), list)
               and required.issubset({row.get("key") for row in stage["excluded"] if isinstance(row, dict)})
               for stage in cached.get("stages") or [])


def count_source(label):
    return ("GitHub GraphQL needs-triage snapshot + triage_split.filter_issues: labels, AGENT_HOME issue state, units.json, and active triage batch markers; exclusions count first match"
            if label == "needs-triage" else "GitHub GraphQL: open issues per label")


def idle_source(label):
    return ("oldest updatedAt after the shared triage filter"
            if label == "needs-triage" else "GitHub GraphQL: oldest updatedAt per label")


def _row(label, count, nodes):
    node = (nodes or [None])[0] or {}
    return {"label": label, "count": count,
            "oldest": {"number": node.get("number"), "created_at": node.get("createdAt"), "updated_at": node.get("updatedAt")} if node else None,
            "items": [{"number": n.get("number"), "title": (n.get("title") or "")[:60], "updated_at": n.get("updatedAt")} for n in (nodes or [])[:10]]}


def stage(label, block):
    """一个前段阶段的 GraphQL 结果 → 阶段行。nodes 按 updatedAt 升序；needs-triage 读全部开放票再切分。"""
    nodes = block.get("nodes") or []
    if label != "needs-triage":
        return _row(label, block.get("totalCount"), nodes)
    total = block.get("totalCount")
    if total is None or total > len(nodes):
        raise RuntimeError(f"待分诊 {total} 张，超过一次读取的 {len(nodes)} 张，无法逐张判定排除")
    eligible, excluded = filter_issues(nodes)
    row = _row(label, len(eligible), eligible)
    row["excluded"] = [{"key": k, "name": EXCLUSION_NAMES[k], "count": excluded[k], "tooltip": TOOLTIPS[k]} for k in EXCLUSION_ORDER]
    return row


if __name__ == "__main__":
    if sys.argv[1:] != ["filter"]:
        sys.exit(64)
    try:
        eligible, excluded = filter_issues(json.load(sys.stdin))
    except (json.JSONDecodeError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    json.dump({"eligible": eligible, "excluded": excluded}, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
