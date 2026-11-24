#!/usr/bin/env bash

# Subject, body rendering and the send-boundary contract for the owner report.

maintainer_health_mail_subject() { # <facts>
  local facts="$1" decisions day headline
  decisions="$(jq -r '.decisions.total // "null"' <<< "$facts")"
  day="$(jq -r '.report_day' <<< "$facts")"
  headline="$(jq -r '[(if .output.finished.day != null then "做完 \(.output.finished.day) 个" else empty end),
      (if .output.shipped.day != null then "正式上线 \(.output.shipped.day) 个" else empty end)]
    | if length == 0 then "产出记录读取失败" else join("、") end' <<< "$facts")"
  if [[ "$decisions" =~ ^[1-9][0-9]*$ ]]; then printf '工厂日报 %s：%s，有 %s 件事等你\n' "$day" "$headline" "$decisions"; else printf '工厂日报 %s：%s\n' "$day" "$headline"; fi
}

# maintainer_health_mail_build_body <facts>
# The short owner report: one conclusion, then decisions, output, change, quality,
# resources, stations and causes, in plain Chinese. Each figure shows each comparison once,
# from the compare facts (yesterday and the same weekday last week). A figure the engine cannot read
# is dropped, never shown as a placeholder; a section left empty is dropped.
maintainer_health_mail_build_body() {
  jq -r '
    # "（比昨天多 2 个，比上周同日少 1 个）" from the compare facts, or nothing when no base was readable.
    . as $f | def inl($k): (($f.compare.inline // {})[$k]) as $c | if $c == null or $c == "" then "" else "（" + $c + "）" end;
    # "过去一天 N 个（比昨天…）；近 7 天 X 个（上一个 7 天 Y 个）", dropping what is null.
    def pair($a; $b; $cmp; $unit): if $a == null then null else "\($a) \($unit)" + (if $b == null then "" else "（\($cmp) \($b) \($unit)）" end) end;
    def periods($p; $unit; $k): if $p == null then "" else
      [(if $p.day == null then empty else "过去一天 \($p.day) \($unit)" + inl($k) end),
       (pair($p.week; $p.prev_week; "上一个 7 天"; $unit) | if . == null then empty else "近 7 天 " + . end)] | join("；") end;
    def wan($n): if $n >= 10000 then "\((($n / 1000 | round) / 10)) 万" else "\($n)" end;
    def money($v): if $v == null then null else "\($v) 美元" end;
    def section($name; $lines): ($lines | map(select(. != null and . != ""))) as $kept | if ($kept | length) == 0 then [] else [$name] + $kept end;
    . as $f
    | ($f.output) as $o
    | (if $f.last_deploy_at == null then ""
       else (($f.window.end - $f.last_deploy_at) / 86400 | floor) as $days
         | if $days >= 1 then "距上次上线 \($days) 天。" else "距上次上线不到 1 天。" end end) as $since_deploy
    | ([ (periods($o.finished; "个"; "finished") | if . == "" then null else "- 做完（已合入主线）：" + . + "。" end),
         (periods($o.shipped; "个"; "shipped") | if . == "" then null else "- 正式上线：" + . + "。" + $since_deploy end) ]
       | map(select(. != null))) as $output_lines
    | [ "一句话结论：\($f.conclusion.reason)。" ]
    + [ "需要你决定" ]
    + (if $f.decisions.total == null then ["- 决定记录读取失败，本期无法列出。"]
       elif $f.decisions.total == 0 then ["- 没有"]
       else
        (($f.decisions.items // []) as $items
          | ($f.decisions.incomplete // 0) as $incomplete
          | ($items[0:3]) as $shown
          | if $incomplete > 0 then
              if ($shown | length) > 0 then
                ["- \($shown[0].question)——\($shown[0].recommendation)（另有 \($incomplete) 件记录缺少问题或建议）"]
                + ($shown[1:] | map("- \(.question)——\(.recommendation)"))
              else ["- 有 \($incomplete) 件事项缺少问题或建议，暂无法给出建议。"] end
            else $shown | map("- \(.question)——\(.recommendation)") end)
       end)
    + [ "产出" ] + (if ($output_lines | length) == 0 then ["- 需求进度记录读取失败，产出无法统计。"] else $output_lines end)
    + section("变化"; (if $o == null or $o.stock.now == null then [] else
        ["- 做完等上线的需求（未关闭）：现在 \($o.stock.now) 个" + inl("stock") + "。"] end) + [$f.compare.note // null])
    + section("质量"; [
        (if $f.quality.incidents_period == null then null
         else "- 线上告警：过去一天 \($f.quality.incidents_period) 次" + inl("incidents") + (if $f.quality.alert_classes == null then "" else "，共 \($f.quality.alert_classes) 类" end) + "。" end),
        (if $f.quality.rollbacks == null then null else "- 撤回上线：过去一天 \($f.quality.rollbacks) 次" + inl("rollbacks") + "。" end)])
    + section("资源"; [
        (if $f.spend.day == null then null
         else "- 令牌用量：过去一天 \(wan($f.spend.day.tokens))" + inl("tokens") + "。" end),
        (if $f.spend.day == null or $f.spend.day.money_usd == null or $f.spend.day.money_usd == 0 then null
         else "- 按美元计价的调用：过去一天 \(money($f.spend.day.money_usd))" + inl("money") + "；与令牌分开记账，没有相加。" end)])
    + section("各环节效率"; $f.compare.station_lines // [])
    + section("变化原因"; $f.compare.causes // [])
    | join("\n")
  ' <<< "$1"
}

maintainer_health_mail_build_html() {
  local decision_flags_file="" owners_file="${ZF_ANOMALY_OWNERS_FILE:-$HOME/.zenoforge/state/work/anomaly-owners.json}" agent_home="${3:-${AGENT_HOME:-}}"
  [[ -z "$agent_home" ]] || decision_flags_file="$agent_home/checkout/.scratch-supervisor/decision-log-flags.jsonl"
  { printf '%s\n' "$1"; printf '%s' "$2"; } | ZF_DECISION_LOG_FLAGS_FILE="$decision_flags_file" ZF_ANOMALY_OWNERS_FILE="$owners_file" python3 -c '
import datetime, html, json, math, os, sys
raw = sys.stdin.read()
facts_text, body = raw.split("\n", 1)
facts = json.loads(facts_text)
decision_flags=[]
flags_file=os.environ.get("ZF_DECISION_LOG_FLAGS_FILE")
if flags_file:
    try:
        with open(flags_file, encoding="utf-8") as source:
            for line in source:
                try:
                    flag=json.loads(line)
                    if isinstance(flag,dict) and isinstance(flag.get("entry"),str) and isinstance(flag.get("reason"),str): decision_flags.append(flag)
                except json.JSONDecodeError: pass
    except FileNotFoundError: pass
owners={}
owners_file=os.environ.get("ZF_ANOMALY_OWNERS_FILE")
if owners_file:
    try:
        with open(owners_file, encoding="utf-8") as source:
            loaded=json.load(source)
            owners=loaded if isinstance(loaded,dict) else {}
    except (OSError, json.JSONDecodeError): pass
charts = (facts.get("compare") or {}).get("charts") or {}
images = []
parts = ["<!doctype html><html><body style=\"font-family:Arial,sans-serif;color:#18212f;line-height:1.5\">",
         "<h1>工厂日报</h1>"]
esc = lambda value: html.escape(str(value), quote=True)
number = lambda value: str(int(value)) if float(value).is_integer() else f"{value:.1f}"
money = lambda value: f"{value:.2f}"
def table(headers, rows, bar_column=None):
    out=["<table style=\"border-collapse:collapse;width:100%;margin:10px 0\"><thead><tr>"]
    out += ["<th"+(" width=\"240\" style=\"width:240px;" if index==bar_column else " style=\"")+"text-align:left;border-bottom:1px solid #cbd5e1;padding:6px\">"+esc(h)+"</th>" for index,h in enumerate(headers)]
    out.append("</tr></thead><tbody>")
    for row in rows:
        cells=[]
        for index,cell in enumerate(row):
            width=" width=\"240\" style=\"width:240px;" if index==bar_column else " style=\""
            cells.append("<td"+width+"border-bottom:1px solid #e2e8f0;padding:6px\">"+str(cell)+"</td>")
        out.append("<tr>"+"".join(cells)+"</tr>")
    return "".join(out+["</tbody></table>"])
blue, orange, red = "#3064b4", "#e19123", "#cd4141"
valid_number = lambda value: isinstance(value,(int,float)) and not isinstance(value,bool) and math.isfinite(value)
show = lambda value: esc(number(value)) if valid_number(value) else ""
def bar(value, maximum, color):
    share = max(0,min(1,value/maximum)) if maximum > 0 else 0
    return "<div style=\"width:100%;height:12px;background:#e2e8f0\"><div style=\"height:12px;width:"+str(round(share*100,1))+"%;background:"+color+"\"></div></div>"
def chart_table(rows):
    return table(["项目","对比条","数值"],rows,1)
def standard_share(value, healthy, higher):
    return value/healthy if higher else (1 if value <= 0 else healthy/value)
def status_color(status):
    return red if status == "UNHEALTHY" else orange if status == "WARN" else blue
verdict=(facts.get("conclusion") or {}).get("reason")
if isinstance(verdict,str) and verdict.strip(): parts.append("<p style=\"font-size:18px;font-weight:bold\">一句话结论："+esc(verdict)+"。</p>")
parts.append("<h2>异常情况</h2>")
anomalies=[]
for r in charts.get("anomalies",[]):
    if isinstance(r,dict) and valid_number(r.get("value")) and valid_number(r.get("standard")):
        owner_key=r.get("owner_key")
        owner_row=owners.get(owner_key) if isinstance(owner_key,str) else None
        registered=isinstance(owner_key,str) and owner_key in owners
        unit=r.get("unit", "")
        anomalies.append([esc(r.get("label","")),esc(number(r["value"])+" "+unit),esc(number(r["standard"])+" "+unit),
                         esc((owner_row.get("owner") or "") if registered and isinstance(owner_row,dict) else "" if registered else "未登记"),
                         esc((owner_row.get("cause") or "") if registered and isinstance(owner_row,dict) else "" if registered else "原因未查明")])
parts.append(table(["项目","现值","标准","负责人","原因"],anomalies))
stations=[r for r in charts.get("station_standards",[]) if isinstance(r,dict) and isinstance(r.get("name"),str)
          and valid_number(r.get("value")) and valid_number(r.get("healthy")) and r["healthy"] > 0]
if stations:
    parts.append("<h2>各环节对比</h2><p>图例：达到健康线或更好为蓝色，偏离健康线为橙色，未达标为红色。</p>")
    rows=[]
    for r in stations:
        share=standard_share(r["value"],r["healthy"],r.get("higher",True))
        rows.append([esc(r["name"]),bar(share,1,status_color(r.get("status"))),
                     esc(number(r["value"])+" "+r.get("unit","")+"（标准 "+number(r["healthy"])+"）")])
    parts.append(chart_table(rows))
    parts.append(table(["环节","现值","标准"],[[esc(r["name"]),esc(number(r["value"])+" "+r.get("unit","")),esc(number(r["healthy"])+" "+r.get("unit",""))] for r in stations]))
daily=charts.get("period_comparison") or {}
periods={p.get("key"):p.get("label") for p in daily.get("periods",[]) if isinstance(p,dict) and isinstance(p.get("key"),str) and isinstance(p.get("label"),str)}
daily_rows=[]
for metric in daily.get("metrics",[]):
    if not isinstance(metric,dict) or not isinstance(metric.get("label"),str): continue
    points=[p for p in metric.get("points",[]) if isinstance(p,dict) and valid_number(p.get("value"))]
    maximum=max([p["value"] for p in points]+[0])
    for point in points:
        period=point.get("period")
        label=periods.get(period,period or "")
        daily_rows.append([esc(metric["label"]+"（"+str(label)+"）"),bar(point["value"],maximum,blue if period=="today" else orange),show(point["value"])])
if daily_rows:
    parts.append("<h2>每日对比</h2><p>图例：今天为蓝色，昨天和上周同日为橙色。</p>")
    parts.append(chart_table(daily_rows))
    parts.append(table(["项目"]+[periods.get(k,k) for k in ("today","yesterday","last_week")],
      [[esc(r["label"])]+[show(next((p["value"] for p in r["points"] if p.get("period")==k and valid_number(p.get("value"))),None)) for k in ("today","yesterday","last_week")] for r in daily.get("metrics",[]) if isinstance(r,dict) and isinstance(r.get("label"),str)]))
trend_rows=[]
for station in charts.get("station_series",[]):
    if not isinstance(station,dict) or not isinstance(station.get("name"),str) or not valid_number(station.get("healthy")) or station["healthy"] <= 0: continue
    points=[p for p in station.get("points",[]) if isinstance(p,dict) and valid_number(p.get("value")) and isinstance(p.get("day"),str)]
    for point in points:
        try: day=datetime.date.fromisoformat(point["day"]).strftime("%m月%d日")
        except ValueError: continue
        share=standard_share(point["value"],station["healthy"],station.get("higher",True))
        color=status_color(station.get("status")) if point is points[-1] else blue if share >= 1 else orange
        trend_rows.append([esc(station["name"]+"（"+day+"）"),bar(share,1,color),esc(number(point["value"])+" "+station.get("unit","")+"（标准 "+number(station["healthy"])+"）")])
if trend_rows:
    parts.append("<h2>近七天趋势</h2><p>图例：达到健康线或更好为蓝色，偏离健康线为橙色，当天未达标为红色。</p>")
    parts.append(chart_table(trend_rows))
models=[r for r in charts.get("model_spend",[]) if isinstance(r,dict) and isinstance(r.get("model"),str)
        and any(valid_number(r.get(k)) for k in ("tokens","money_usd"))]
model_rows=[]
for measure, label, color, formatter in (("tokens","令牌",blue,lambda value:number(value)),("money_usd","调用金额（美元）",orange,lambda value:money(value)+" 美元")):
    values=[r[measure] for r in models if valid_number(r.get(measure))]
    maximum=max(values+[0])
    for r in models:
        if valid_number(r.get(measure)):
            model_rows.append([esc("模型 "+r["model"]+"（"+label+"）"),bar(r[measure],maximum,color),esc(formatter(r[measure]))])
if model_rows:
    parts.append("<h2>模型用量</h2><p>图例：蓝色为令牌用量，橙色为已记录的调用金额。</p>")
    parts.append(chart_table(model_rows))
    parts.append(table(["模型","令牌","调用金额（美元）"],[[esc(r["model"]),esc(number(r["tokens"])) if valid_number(r.get("tokens")) else "",esc(money(r["money_usd"])) if valid_number(r.get("money_usd")) else ""] for r in models]))
parts.append("<h2>文字版</h2><pre style=\"white-space:pre-wrap;font-family:inherit\">"+esc(body)+"</pre>")
attachments=[]
if decision_flags:
    decision_text="\n\n".join("第"+str(index+1)+"条\n记录："+item["entry"]+"\n原因："+item["reason"] for index,item in enumerate(decision_flags))
    attachments.append({"filename":"decision-log-review.txt","content":decision_text})
parts.append("<h2>决策日志复核（"+str(len(decision_flags))+" 条）</h2>")
parts.append("<ol>"+"".join("<li><strong>记录：</strong>"+esc(item["entry"])+" <strong>原因：</strong>"+esc(item["reason"])+"</li>" for item in decision_flags[:10])+"</ol>" if decision_flags else "<p>没有需关注的条目。</p>")
if len(decision_flags)>10: parts.append("<p>仅显示前10条，完整列表见文本附件。</p>")
parts.append("</body></html>")
print(json.dumps({"html":"".join(parts),"images":images,"attachments":attachments},ensure_ascii=False,separators=(",",":")))
'
}


# The owner-report contract: the fixed sections in order (需要你决定 and 产出 always, right after the one-line
# conclusion and in that order; the rest when they have content), plain Chinese
# only (no Latin letters at all), no tracker or commit ids, no unreadable
# epoch-derived dates, at most three decision lines. 2026-11-07: 需要你决定 moved to the top, 各环节效率 and 变化原因
# were added, and the line limit is 32 (the longest body the renderer can build: conclusion 1, decisions 4, output 3,
# change 3, quality 3, resources 3, stations 10, causes 5). "isolate-lines" drops
# single offending lines while keeping the rest of the report sendable.
maintainer_health_mail_output_contract() {
  local body="$1" now="$2"
  printf '%s' "$body" | python3 -c '
import json
import re
import sys

text = sys.stdin.read()
SECTIONS = ["需要你决定", "产出", "变化", "质量", "资源", "各环节效率", "变化原因"]
REQUIRED = ("产出", "需要你决定")
MAX_LINES = 32

def validate(text):
    errors = set()
    lines = text.splitlines()
    if not text.strip():
        errors.add("empty-body")
        return errors
    if len(lines) > MAX_LINES:
        errors.add("one-screen")
    if not re.match(r"^一句话结论：.+。", lines[0] if lines else ""):
        errors.add("conclusion")
    position = 0
    for section in SECTIONS:
        if section not in lines:
            if section in REQUIRED:
                errors.add("missing-section")
            continue
        index = lines.index(section)
        if index <= position:
            errors.add("section-order")
        position = index
    # Every section must carry at least one line of content.
    boundaries = [lines.index(section) for section in SECTIONS if section in lines]
    for index in boundaries:
        if index + 1 >= len(lines) or lines[index + 1] in SECTIONS or not lines[index + 1].strip():
            errors.add("empty-section")
    if "需要你决定" in lines:
        start = lines.index("需要你决定") + 1
        stop = next((i for i in range(start, len(lines)) if lines[i] in SECTIONS), len(lines))
        items = [line for line in lines[start:stop] if line.startswith("- ")]
        if len(items) > 3:
            errors.add("decision-limit")
        if not items:
            errors.add("empty-section")
        if any(line not in ("- 没有", "- 决定记录读取失败，本期无法列出。")
               and not re.match(r"^- .+[？?]——建议：.+。?$", line)
               and not re.match(r"^- 有 [0-9]+ 件事项缺少问题或建议，暂无法给出建议。$", line)
               for line in items):
            errors.add("decision-line")
    if re.search(r"[A-Za-z]", text):
        errors.add("ascii-text")
    if "1970" in text or "时间待核实" in text or "日期待核实" in text \
            or re.search(r"(?<![0-9])1月1日", text):
        errors.add("epoch-date")
    if re.search(r"#[0-9]+", text):
        errors.add("issue-id")
    if re.search(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", text):
        errors.add("iso-date")
    return errors

try:
    now = int(sys.argv[1])
except (IndexError, ValueError):
    now = 0
mode = sys.argv[2] if len(sys.argv) > 2 else "validate"
if now < 946684800:
    print("epoch-date")
    raise SystemExit(1)

if mode == "isolate-lines":
    kept, rejected = [], []
    for line in text.splitlines():
        errors = validate(line) - {"missing-section", "section-order", "empty-section", "conclusion", "decision-limit", "empty-body"}
        if errors:
            rejected.append({"key": "output-line:" + line, "reason": ",".join(sorted(errors))})
        else:
            kept.append(line)
    print(json.dumps({"body": "\n".join(kept), "rejected": rejected}, ensure_ascii=False))
else:
    errors = validate(text)
    if errors:
        print(",".join(sorted(errors)))
        raise SystemExit(1)
' "$now" "${3:-validate}"
}

maintainer_health_mail_subject_rejection_reason() {
  local subject="$1"
  grep -Eq '^工厂日报 [0-9]{2}-[0-9]{2}：.+(，有 [0-9]+ 件事等你)?$' <<< "$subject" || printf 'health-subject\n'
}

maintainer_health_mail_notify_rejection_reason() {
  local body="$1" now="$2" errors
  if errors="$(maintainer_health_mail_output_contract "$body" "$now")"; then
    return 0
  fi
  case ",$errors," in
    *,decision-limit,*) printf 'health-decision-limit\n' ;;
    *,decision-line,*) printf 'health-decision-line\n' ;;
    *,ascii-text,*|*,epoch-date,*|*,issue-id,*|*,iso-date,*) printf 'body-internal\n' ;;
    *) printf 'health-sections\n' ;;
  esac
}
