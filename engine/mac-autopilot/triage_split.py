"""待分诊口径：triage 批处理选不到的票（路线图排序 / 系统通道）不计入待分诊，单列两个数字。
排除规则与选择器同源：系统通道标签读 nonproduct-lane-routing 裁决（engine/lib.d/pipeline-system.sh），
路线图标签是 engine/roadmap.sh:315 的常量，路线图排序开关先读 ZF_PIPELINE_ROADMAP_SWITCH，再按 engine/roadmap.sh:83 读 model-policy。"""
import json, os
from config_paths import zf_config_file

ROADMAP_LABELS = ("roadmap", "roadmap-theme", "roadmap-epic")
NAMES = {"roadmap": "路线图排序", "system": "系统通道"}
TOOLTIPS = {
    "roadmap": "带 roadmap / roadmap-theme / roadmap-epic 标签：路线图排序开启时，这类票按路线图的顺序安排，不走 triage 逐张分诊，所以不计入待分诊。",
    "system": "带系统通道标签（nonproduct-lane-routing 裁决里的标签，如 pipeline-system）：归系统通道处理（流水线运维票），不走产品 triage，所以不计入待分诊。",
}
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
        os.environ.get("AGENT_HOME") or os.path.expanduser("~/.zenoforge"), "model-policy.json")
    try:
        return json.load(open(policy)).get("switches", {}).get("roadmap-order") is True
    except (OSError, ValueError, AttributeError):
        return False


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
    system, roadmap_on = system_lane_labels(), roadmap_order_on()
    eligible, excluded = [], {"roadmap": 0, "system": 0}
    for n in nodes:
        names = {l.get("name") for l in ((n.get("labels") or {}).get("nodes") or [])}
        if names & system:
            excluded["system"] += 1
        elif roadmap_on and names & set(ROADMAP_LABELS):
            excluded["roadmap"] += 1
        else:
            eligible.append(n)
    row = _row(label, len(eligible), eligible)
    row["excluded"] = [{"key": k, "name": NAMES[k], "count": excluded[k], "tooltip": TOOLTIPS[k]} for k in ("roadmap", "system")]
    return row
