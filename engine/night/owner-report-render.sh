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

# maintainer_health_mail_build_html <facts> <plain-body> -> {html,images}
# PNGs are written with Python's standard library so mail needs no host image package.
maintainer_health_mail_build_html() {
  { printf '%s\n' "$1"; printf '%s' "$2"; } | python3 -c '
import base64, datetime, html, json, math, struct, sys, zlib
raw = sys.stdin.read()
facts_text, body = raw.split("\n", 1)
facts = json.loads(facts_text)
charts = (facts.get("compare") or {}).get("charts") or {}
images = []
parts = ["<!doctype html><html><body style=\"font-family:Arial,sans-serif;color:#18212f;line-height:1.5\">",
         "<h1>工厂日报</h1>"]
esc = lambda value: html.escape(str(value), quote=True)
number = lambda value: str(int(value)) if float(value).is_integer() else f"{value:.1f}"
money = lambda value: f"{value:.2f}"
show = lambda value: esc(number(value)) if isinstance(value,(int,float)) and math.isfinite(value) else ""
colors = {"blue": (48, 100, 180), "green": (48, 145, 105), "orange": (225, 145, 35),
          "red": (205, 65, 65), "gray": (220, 226, 235), "ink": (75, 88, 105), "white": (255, 255, 255)}
font = {"0":("111","101","101","101","111"),"1":("010","110","010","010","111"),
        "2":("111","001","111","100","111"),"3":("110","001","011","001","110"),
        "4":("101","101","111","001","001"),"5":("111","100","111","001","111"),
        "6":("111","100","111","101","111"),"7":("111","001","010","010","010"),
        "8":("111","101","111","101","111"),"9":("111","101","111","001","111"),
        ".":("000","000","000","000","010"),"-":("000","000","111","000","000"),
        "%":("101","001","010","100","101")}
def canvas(height): return bytearray(bytes(colors["white"]) * (720 * height)), height
def pixel(c, h, x, y, color):
    if 0 <= x < 720 and 0 <= y < h: c[(y * 720 + x) * 3:(y * 720 + x) * 3 + 3] = bytes(color)
def line(c, h, x0, y0, x1, y1, color, dashed=False):
    dx, sx = abs(x1-x0), 1 if x0 < x1 else -1
    dy, sy = -abs(y1-y0), 1 if y0 < y1 else -1
    err, step = dx + dy, 0
    while True:
        if not dashed or step % 8 < 4: pixel(c, h, x0, y0, color)
        if x0 == x1 and y0 == y1: break
        twice = 2 * err
        if twice >= dy: err += dy; x0 += sx
        if twice <= dx: err += dx; y0 += sy
        step += 1
def rect(c, h, x, y, width, height, color):
    for yy in range(max(0,y), min(h,y+height)):
        for xx in range(max(0,x), min(720,x+width)): pixel(c,h,xx,yy,color)
def text(c, h, x, y, value, color=colors["ink"]):
    for char in str(value):
        glyph = font.get(char)
        if glyph:
            for yy, row in enumerate(glyph):
                for xx, bit in enumerate(row):
                    if bit == "1": pixel(c,h,x+xx,y+yy,color)
        x += 5
def png(c, h):
    def chunk(kind, data): return struct.pack(">I",len(data)) + kind + data + struct.pack(">I",zlib.crc32(kind+data)&0xffffffff)
    stride = 720 * 3
    scan = b"".join(b"\0" + c[y*stride:(y+1)*stride] for y in range(h))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR",struct.pack(">IIBBBBB",720,h,8,2,0,0,0)) + chunk(b"IDAT",zlib.compress(scan,6)) + chunk(b"IEND",b"")
def attach(cid, data, alt, caption):
    images.append({"cid":cid,"filename":cid+".png","data":base64.b64encode(data).decode("ascii")})
    parts.append("<figure style=\"margin:20px 0\"><figcaption><b>"+esc(caption)+"</b></figcaption><img style=\"max-width:100%;height:auto\" src=\"cid:"+cid+"\" alt=\""+esc(alt)+"\"></figure>")
def valid_rows(rows, fields):
    return [row for row in rows if isinstance(row,dict) and all(isinstance(row.get(k),(int,float)) and math.isfinite(row[k]) for k in fields)]
def station_png(rows):
    rows = [r for r in valid_rows(rows,["value","healthy"]) if r["healthy"] > 0]
    if not rows: return None
    h, x0, plot = 42 + 34*len(rows), 95, 550
    c, h = canvas(h); scale = max(150, math.ceil(max(abs(r["value"]/r["healthy"]*100) for r in rows)/50)*50)
    for tick in range(0,scale+1,50):
        x=x0+round(plot*tick/scale); line(c,h,x,22,x,h-12,colors["gray"]); text(c,h,x-7,8,str(tick)+"%")
    line(c,h,x0+round(plot*100/scale),18,x0+round(plot*100/scale),h-10,colors["red"],True)
    for i,r in enumerate(rows):
        y=31+i*34; ratio=r["value"]/r["healthy"]*100
        width=round(plot*min(scale,abs(ratio))/scale)
        text(c,h,42,y+3,str(i+1)); rect(c,h,x0,y,width,15,colors["red"] if r.get("status")=="UNHEALTHY" else colors["orange"] if r.get("status")=="WARN" else colors["blue"])
        text(c,h,min(650,x0+width+5),y+4,str(round(ratio))+"%")
    return png(c,h), rows
def period_png(data):
    periods={p["key"]:p["label"] for p in data.get("periods",[]) if isinstance(p,dict) and "key" in p and "label" in p}
    rows=[r for r in data.get("metrics",[]) if isinstance(r,dict) and len([p for p in r.get("points",[]) if isinstance(p,dict) and isinstance(p.get("value"),(int,float))])>=2]
    if not rows: return None
    h,x0,plot=42+48*len(rows),120,515; c,h=canvas(h)
    palette={"today":colors["blue"],"yesterday":colors["green"],"last_week":colors["orange"]}
    for i,r in enumerate(rows):
        points=[p for p in r["points"] if isinstance(p,dict) and isinstance(p.get("value"),(int,float)) and math.isfinite(p["value"])]
        if len(points)<2: continue
        maxv=max(abs(p["value"]) for p in points) or 1; y0=24+i*48
        text(c,h,30,y0+8,str(i+1))
        for j,p in enumerate(points):
            y=y0+j*11; width=round(plot*abs(p["value"])/maxv)
            rect(c,h,x0,y,width,7,palette.get(p["period"],colors["blue"]))
            text(c,h,min(642,x0+width+5),y,str(round(p["value"]*10)/10))
    return png(c,h), rows, periods
def station_trend_png(rows, end):
    rows=[r for r in rows if isinstance(r,dict) and isinstance(r.get("healthy"),(int,float)) and r["healthy"]>0
          and len([p for p in r.get("points",[]) if isinstance(p,dict) and isinstance(p.get("value"),(int,float))])>=2]
    if not rows: return None
    h,x0,plot=44+38*len(rows),90,560; c,h=canvas(h)
    current=datetime.datetime.fromtimestamp(end,datetime.timezone(datetime.timedelta(hours=8))).date() if isinstance(end,(int,float)) else None
    scale=max(200,math.ceil(max(abs(p["value"]/r["healthy"]*100) for r in rows for p in r["points"] if isinstance(p,dict) and isinstance(p.get("value"),(int,float)))/50)*50)
    for i,r in enumerate(rows):
        y0=24+i*38; baseline=y0+28-round(100/scale*25); line(c,h,x0,baseline,x0+plot,baseline,colors["red"],True)
        points=[]
        for n,p in enumerate(r["points"]):
            if not isinstance(p.get("value"),(int,float)): continue
            try: xday=(datetime.date.fromisoformat(p["day"])-current).days+6
            except (ValueError,TypeError): xday=n
            if 0<=xday<=6: points.append((x0+round(plot*xday/6),y0+28-round(min(scale,abs(p["value"]/r["healthy"]*100))/scale*25)))
        for a,b in zip(points,points[1:]): line(c,h,*a,*b,colors["blue"])
        for x,y in points: rect(c,h,x-2,y-2,5,5,colors["blue"])
        text(c,h,35,y0+8,str(i+1))
    for i in range(7): text(c,h,x0+round(plot*i/6)-3,h-12,str(i+1))
    return png(c,h), rows
def model_png(rows):
    rows=[r for r in rows if isinstance(r,dict) and isinstance(r.get("model"),str)
          and any(isinstance(r.get(k),(int,float)) and math.isfinite(r[k]) for k in ("tokens","money_usd"))]
    if not rows or not any((r.get("tokens") if isinstance(r.get("tokens"),(int,float)) else 0)>0 or (r.get("money_usd") if isinstance(r.get("money_usd"),(int,float)) else 0)>0 for r in rows): return None
    h,x0,plot=42+42*len(rows),115,520; c,h=canvas(h)
    maxt=max([r.get("tokens",0) or 0 for r in rows]+[1])
    maxu=max([r["money_usd"] for r in rows if isinstance(r.get("money_usd"),(int,float)) and math.isfinite(r["money_usd"])]+[1])
    for i,r in enumerate(rows):
        y=23+i*42; tokens=r.get("tokens") if isinstance(r.get("tokens"),(int,float)) else 0
        rect(c,h,x0,y,round(plot*tokens/maxt),10,colors["blue"]); text(c,h,min(645,x0+round(plot*tokens/maxt)+5),y+2,str(round(tokens)))
        money=r.get("money_usd")
        if isinstance(money,(int,float)) and math.isfinite(money):
            rect(c,h,x0,y+14,round(plot*money/maxu),10,colors["orange"]); text(c,h,min(645,x0+round(plot*money/maxu)+5),y+16,str(round(money*100)/100))
        text(c,h,35,y+6,str(i+1))
    return png(c,h), rows
def table(headers, rows):
    out=["<table style=\"border-collapse:collapse;width:100%;margin:10px 0\"><thead><tr>"]
    out += ["<th style=\"text-align:left;border-bottom:1px solid #cbd5e1;padding:6px\">"+esc(h)+"</th>" for h in headers]
    out.append("</tr></thead><tbody>")
    for row in rows:
        out.append("<tr>"+"".join("<td style=\"border-bottom:1px solid #e2e8f0;padding:6px\">"+str(cell)+"</td>" for cell in row)+"</tr>")
    return "".join(out+["</tbody></table>"])
verdict=(facts.get("conclusion") or {}).get("reason")
if isinstance(verdict,str) and verdict.strip(): parts.append("<p style=\"font-size:18px;font-weight:bold\">一句话结论："+esc(verdict)+"。</p>")
parts.append("<h2>异常情况</h2>")
anomalies=[]
for r in charts.get("anomalies",[]):
    if isinstance(r,dict) and isinstance(r.get("value"),(int,float)) and isinstance(r.get("standard"),(int,float)):
        unit=esc(r.get("unit", "")); anomalies.append([esc(r.get("label","")),esc(number(r["value"])+" "+unit),esc(number(r["standard"])+" "+unit),esc(r.get("owner") or "未登记"),esc(r.get("cause") or "原因未查明")])
parts.append(table(["项目","现值","标准","负责人","原因"],anomalies))
station=station_png(charts.get("station_standards",[]))
if station:
    data,rows=station; attach("owner-station-standard",data,"各环节当前数值与标准线对比","环节流转和等待（标准线为100%）")
    parts.append("<p>图例：红色虚线为标准；蓝色达标，橙色偏离标准，红色未达标。</p>")
    parts.append(table(["环节","现值","标准"],[[esc(r["name"]),esc(number(r["value"])+" "+r["unit"]),esc(number(r["healthy"])+" "+r["unit"])] for r in rows]))
daily=period_png(charts.get("period_comparison") or {})
if daily:
    data,rows,periods=daily; attach("owner-daily-comparison",data,"合入、做完和正式上线的日期对比","今天、昨天和上周同日")
    parts.append("<p>图例：蓝色为今天，绿色为昨天，橙色为上周同日。</p>")
    parts.append(table(["项目"]+[periods.get(k,k) for k in ("today","yesterday","last_week")],
      [[esc(r["label"])]+[show(next((p["value"] for p in r["points"] if p["period"]==k),None)) for k in ("today","yesterday","last_week")] for r in rows]))
trend=station_trend_png(charts.get("station_series",[]),(facts.get("window") or {}).get("end"))
if trend:
    data,rows=trend; attach("owner-station-trend",data,"最近七天各环节相对标准的变化","近七天环节趋势（标准线为100%）")
    parts.append("<p>图例：蓝线为每日实际值，红色虚线为标准。</p>")
    parts.append("<p>序号对应环节：</p>"+"；".join(str(i+1)+"："+esc(r["name"]) for i,r in enumerate(rows)))
models=model_png(charts.get("model_spend",[]))
if models:
    data,rows=models; attach("owner-model-spend",data,"各模型的令牌用量和可读取的调用金额","按模型查看令牌和调用金额")
    parts.append("<p>图例：蓝色为令牌用量，橙色为已记录的调用金额（美元）。</p>")
    parts.append(table(["模型","令牌","调用金额（美元）"],[[esc(r["model"]),esc(number(r["tokens"])) if isinstance(r.get("tokens"),(int,float)) else "",esc(money(r["money_usd"])) if isinstance(r.get("money_usd"),(int,float)) else ""] for r in rows]))
parts.append("<h2>文字版</h2><pre style=\"white-space:pre-wrap;font-family:inherit\">"+esc(body)+"</pre></body></html>")
print(json.dumps({"html":"".join(parts),"images":images},ensure_ascii=False,separators=(",",":")))
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
