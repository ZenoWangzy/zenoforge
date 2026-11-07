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
        (if $f.spend.day == null or $f.spend.day.money_usd == 0 then null
         else "- 按美元计价的调用：过去一天 \(money($f.spend.day.money_usd))" + inl("money") + "；与令牌分开记账，没有相加。" end)])
    + section("各环节效率"; $f.compare.station_lines // [])
    + section("变化原因"; $f.compare.causes // [])
    | join("\n")
  ' <<< "$1"
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
