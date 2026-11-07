#!/usr/bin/env bash

# Subject, body rendering and the send-boundary contract for the owner report.

maintainer_health_mail_subject() { # <facts>
  local facts="$1" released decisions day headline
  released="$(jq -r '.releases.period_count // "null"' <<< "$facts")"
  decisions="$(jq -r '.decisions.total // "null"' <<< "$facts")"
  day="$(jq -r '.report_day' <<< "$facts")"
  if [[ "$released" =~ ^[0-9]+$ ]]; then headline="正式发版 ${released} 次（热修未计入）"; else headline='正式发版次数待核实'; fi
  if [[ "$decisions" =~ ^[0-9]+$ ]]; then
    if (( decisions > 0 )); then printf '工厂日报 %s：%s，有 %s 件事等你\n' "$day" "$headline" "$decisions"; else printf '工厂日报 %s：%s\n' "$day" "$headline"; fi
  else
    printf '工厂日报 %s：%s，待决定事项未测量\n' "$day" "$headline"
  fi
}

# maintainer_health_mail_build_body <facts>
# The one-screen owner report: plain Chinese, no engineering vocabulary, a
# number only where the engine has a record, and an explicit 未测量 anywhere
# it does not.
maintainer_health_mail_build_body() {
  local facts="$1"
  local now start last_at days_since
  now="$(jq -r '.window.end' <<< "$facts")"
  start="$(jq -r '.window.start' <<< "$facts")"
  jq -r --argjson now "$now" '
    def count($n; $unit): if $n == null then "未测量" else ($n | tostring) + $unit end;
    def items($rows):
      ([$rows[:2][] | "- " + (if (.text | length) > 96 then .text[:95] + "…" else .text end)])
      + (if ($rows | length) > 2 then ["- 另有 \((($rows | length) - 2)) 个需求上线，邮件未逐项列出。"] else [] end);
    . as $f
    | ($f.releases.last_at // null) as $last_at
    | (if $last_at == null then null else (($f.window.end - $last_at) / 86400) end) as $days_since
    | [
        "一句话结论：\($f.conclusion.level)——\($f.conclusion.reason)。",
        "今天上线了什么"
      ]
    + (if ($f.releases.items | length) > 0 then items($f.releases.items)
       else ["- \($f.releases.zero_reason)"] end)
    + [ "进度",
        "- 新提出：过去一天 \(count($f.progress.created_period; " 个"))；累计 \(count($f.progress.created_total; " 个"))；目前在办共 \(count($f.progress.open_total; " 个"))。",
        "- 已做完等上线：过去一天 \(count($f.progress.awaiting_period; " 个"))；当前共 \(count($f.progress.awaiting_total; " 个"))。",
        "- 已上线：过去一天正式发版 \(count($f.progress.released_period; " 次"))（热修未计入）；有记录以来正式发版 \(count($f.progress.released_total; " 次"))，需求逐个数量未能核对。"
      ]
    + (if $days_since != null and $days_since > 1 then ["- 距离上一次正式发版已经 \($days_since | floor) 天（热修未计入）。"] else [] end)
    + [ "效率",
        "- 近 7 天平均每天正式发版 \(if $f.efficiency.per_day_week == null then "未测量" else ((($f.efficiency.per_day_week * 10 | round) / 10) | tostring) end) 次；上一个 7 天 \(if $f.efficiency.per_day_prev == null then "未测量" else ((($f.efficiency.per_day_prev * 10 | round) / 10) | tostring) end) 次（热修未计入）。",
        "- 需求从提出到上线：近 7 天中位 \(if $f.efficiency.lead_days_week != null then ((($f.efficiency.lead_days_week * 10 | round) / 10) | tostring) + " 天" elif $f.efficiency.lead_week_measured == true then "无样本" else "未测量" end)；上一个 7 天 \(if $f.efficiency.lead_days_prev != null then ((($f.efficiency.lead_days_prev * 10 | round) / 10) | tostring) + " 天" elif $f.efficiency.lead_prev_measured == true then "无样本" else "未测量" end)。",
        (if $f.efficiency.split == null or $f.efficiency.split.requirement_pct == null then "- 近 7 天工作时间：需求与工厂自身维护占比未测量。"
         else "- 近 7 天已分类工作时间：需求 \($f.efficiency.split.requirement_pct)%；工厂自身维护 \($f.efficiency.split.self_pct)%\(if $f.efficiency.split.unclassified_seconds > 0 then "；另有 \((($f.efficiency.split.unclassified_seconds / 3600 * 10 | round) / 10)) 小时未分类" else "" end)\(if $f.efficiency.split.partial then "；部分记录未能读取" else "" end)。" end)
      ]
    + [ "花费",
        "- 过去一天令牌用量 \(if $f.spend.tokens == null then "未测量" elif $f.spend.tokens_complete then "\($f.spend.tokens | tostring)" else "至少记录 \($f.spend.tokens | tostring)，另有部分未测量" end)；\(if $f.spend.per_requirement == null then "每个上线需求的令牌花费未测量" else "每个上线需求平均 \($f.spend.per_requirement | tostring) 令牌" end)。",
        (if $f.spend.money_complete and $f.spend.money_usd != null then "- 可计价金额：\($f.spend.money_usd) 美元。"
         elif $f.spend.money_usd != null then "- 至少记录到 \($f.spend.money_usd) 美元，其余金额未测量。"
         else "- 金额没有完整记录，无法算出总花费。" end)
      ]
    + [ "质量",
        "- 线上事故：过去一天 \(count($f.quality.incidents_period; " 起"))；目前仍在处理 \(count($f.quality.incidents_open; " 起"))。",
        "- 撤回上线：过去一天 \(count($f.quality.rollbacks; " 次"))。",
        "- 已上线需求后来再出问题并返修：过去一天 \(count($f.quality.post_land_fixes; " 起"))。"
      ]
    + [ "需要你决定" ]
    + (if $f.decisions.total == null then ["- 待决定事项未测量，无法列出问题和建议。"]
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
    | join("\n")
  ' <<< "$facts"
}


# The owner-report contract: the seven fixed sections in order, plain Chinese
# only (no Latin letters at all), no tracker or commit ids, no unreadable
# epoch-derived dates, at most three decision lines. "isolate-lines" drops
# single offending lines while keeping the rest of the report sendable.
maintainer_health_mail_output_contract() {
  local body="$1" now="$2"
  printf '%s' "$body" | python3 -c '
import json
import re
import sys

text = sys.stdin.read()
SECTIONS = ["今天上线了什么", "进度", "效率", "花费", "质量", "需要你决定"]

def validate(text):
    errors = set()
    lines = text.splitlines()
    if not text.strip():
        errors.add("empty-body")
        return errors
    if len(lines) > 25:
        errors.add("one-screen")
    if not re.match(r"^一句话结论：(正常|有风险|出事了)——.+。", lines[0] if lines else ""):
        errors.add("conclusion")
    position = 0
    for section in SECTIONS:
        if section not in lines:
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
        tail = lines[lines.index("需要你决定") + 1:]
        items = [line for line in tail if line.startswith("- ")]
        if len(items) > 3:
            errors.add("decision-limit")
        if not items:
            errors.add("empty-section")
        if any(line not in ("- 没有", "- 待决定事项未测量，无法列出问题和建议。")
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
  local subject="$1" body="$2"
  if ! grep -Eq '^工厂日报 [0-9]{2}-[0-9]{2}：.+(，(有 [0-9]+ 件事等你|待决定事项未测量))?$' <<< "$subject"; then
    printf 'health-subject\n'
    return 0
  fi
  if [[ "$subject" == *'待决定事项未测量' ]] && ! grep -Fq -- '待决定事项未测量' <<< "$body"; then
    printf 'health-subject\n'
  elif [[ "$subject" != *'待决定事项未测量' ]] && grep -Fq -- '待决定事项未测量' <<< "$body"; then
    printf 'health-subject\n'
  fi
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
