#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/founder-health-mail.sh"
source "$SCRIPT_DIR/../lib.sh"

daily_perf_report_logged_send_count() {
  local notify_log="$1" day="$2" maintainer="$3"
  [ -r "$notify_log" ] || return 1
  awk -F '\t' -v day="$day" -v maintainer="$maintainer" '
    substr($1, 1, 10) == day {
      recipients = ""
      sent = 0
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^recipients=/) recipients = substr($i, 12)
        if ($i == "result=sent") sent = 1
      }
      if (sent && index("," recipients ",", "," maintainer ",") > 0) count++
    }
    END { print count + 0 }
  ' "$notify_log"
}

daily_perf_report_reconcile_mail() {
  local home="$1" day="$2" notify_log="$1/logs/notify.log" maintainer logged start end sent
  maintainer="$(_maintainer_email "$home/recipients.json")"
  if [ -z "$maintainer" ]; then
    AGENT_HOME="$home" supervisor_inbox_append mail-count-check-failed "日期=$day 无法读取维护者地址"
    return $?
  fi
  if ! logged="$(daily_perf_report_logged_send_count "$notify_log" "$day" "$maintainer")"; then
    AGENT_HOME="$home" supervisor_inbox_append mail-count-check-failed "日期=$day 无法读取发送记录"
    return $?
  fi
  start="$(date -u -d "$day 00:00:00" +%s)" || return 1
  end="$(date -u -d "$day +1 day 00:00:00" +%s)" || return 1
  if ! sent="$(gmail_sent_message_count "$maintainer" "$start" "$end")"; then
    AGENT_HOME="$home" supervisor_inbox_append mail-count-check-failed "日期=$day 无法读取邮件夹数量"
    return $?
  fi
  [[ "$sent" =~ ^[0-9]+$ ]] || {
    AGENT_HOME="$home" supervisor_inbox_append mail-count-check-failed "日期=$day 邮件夹数量无效"
    return $?
  }
  if [ "$sent" -ne "$logged" ]; then
    AGENT_HOME="$home" supervisor_inbox_append mail-mismatch "日期=$day Gmail=$sent notify=$logged"
  fi
}

daily_perf_report_window() {
  local agent_home="$1" repo_root="$2" day="$3" offset sample_day end_epoch measure
  for offset in 6 5 4 3 2 1 0; do
    sample_day="$(date -u -d "$day -$offset day" +%Y-%m-%d)" || return 1
    end_epoch="$(date -u -d "$sample_day 23:59:59" +%s)" || return 1
    measure="$(founder_health_mail_measure "$agent_home" "$sample_day" "$end_epoch" "$repo_root")" || return 1
    printf '%s\n' "$measure"
  done | jq -cs .
}

daily_perf_report_average() {
  jq -c '
    . as $days |
    def mean($values): if ($values|length) == 0 then null else (($values|add) / ($values|length) * 10 | round) / 10 end;
    {
      calls: mean([$days[].calls]),
      tokens: mean([$days[].tokens]),
      released_issues: mean([$days[].released_issues]),
      tokens_per_released_issue: mean([$days[].tokens_per_released_issue | select(type == "number")]),
      deploys: mean([$days[].deploys]),
      wakeups_day: mean([$days[].wakeups_day | select(type == "number")]),
      recurrences_day: mean([$days[] | select(.recurrence_tracking) | .recurrences_day]),
      wakes_by_kind: (reduce ($days[].wakes_by_kind | keys[]) as $kind ({};
        .[$kind] = mean([$days[] | .wakes_by_kind[$kind] // 0])))
    }
  '
}

daily_perf_report_rolling_baseline() {
  local agent_home="$1" day="$2"
  node "$SCRIPT_DIR/efficiency-regression.mjs" baseline \
    --home "$agent_home" --before "${day}T00:00:00Z"
}

daily_perf_report_top_issues() {
  local agent_home="$1" day="$2" start_epoch="$3" end_epoch="$4" spend_file="$agent_home/spend/$day.log"
  local issue tokens state_file outcome state
  [ -r "$spend_file" ] || return 0
  while IFS=$'\t' read -r issue tokens; do
    [[ "$issue" =~ ^[0-9]+$ && "$tokens" =~ ^[0-9]+$ ]] || continue
    (( tokens > 0 )) || continue
    state_file="$agent_home/state/$issue.json"
    outcome="进度待核实"
    if [ -r "$state_file" ]; then
      state="$(jq -r 'if .released == true then "已上线"
        elif .run.outcome == "merged" then "已合并，待上线"
        elif .run.outcome == "not-completed" then "暂未完成"
        else "" end' "$state_file" 2>/dev/null || true)"
      [ -z "$state" ] || outcome="$state"
      if [ "$outcome" = 进度待核实 ]; then
        outcome="$(jq -r '(.state // "") as $state | if $state == "queued" then "排队中"
          elif $state == "ready-for-agent" then "待处理"
          elif $state == "in-progress" then "处理中"
          elif $state == "awaiting-release" then "待上线"
          elif $state == "needs-info" then "待补充信息"
          elif $state == "needs-triage" then "待分诊"
          elif $state == "concluded" then "已完成"
          else "进度待核实" end' "$state_file" 2>/dev/null || printf '进度待核实')"
      fi
    fi
    printf '%s\t%s\t%s\n' "$issue" "$tokens" "$outcome"
  done < <(awk -F '\t' -v start="$start_epoch" -v end="$end_epoch" '
    $1 ~ /^[0-9]+$/ && $1 >= start && $1 <= end && $4 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+$/ { tokens[$4] += $6 }
    END { for (issue in tokens) printf "%s\t%.0f\n", issue, tokens[issue] }
  ' "$spend_file" | LC_ALL=C sort -t $'\t' -k2,2nr -k1,1n | head -5)
}

daily_perf_report_kind_label() {
  case "$1" in
    node-health|node-stuck-30min|node-escalation) printf '运行异常' ;;
    mail-mismatch|mail-count-mismatch|daily-mail-mismatch|mail-count-check-failed) printf '邮件数量核对' ;;
    timer-outage) printf '定时任务异常' ;;
    *) printf '其他介入' ;;
  esac
}

daily_perf_report_change() {
  local current="$1" previous="$2" unit="$3" delta
  if ! [[ "$current" =~ ^[0-9]+([.][0-9]+)?$ && "$previous" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '较昨日待统计'
  elif awk -v c="$current" -v p="$previous" 'BEGIN { exit !(c == p) }'; then
    printf '与昨日持平'
  elif awk -v c="$current" -v p="$previous" 'BEGIN { exit !(c > p) }'; then
    delta="$(jq -nr --argjson c "$current" --argjson p "$previous" '($c - $p) | if . == floor then tostring else tostring end')"
    printf '较昨日增加%s%s' "$delta" "$unit"
  else
    delta="$(jq -nr --argjson c "$current" --argjson p "$previous" '($p - $c) | if . == floor then tostring else tostring end')"
    printf '较昨日减少%s%s' "$delta" "$unit"
  fi
}

daily_perf_report_metric_line() {
  local label="$1" current="$2" previous="$3" average="$4" baseline="$5" unit="$6"
  local current_text change average_text baseline_text current_unit='' average_unit=''
  current_text="$current"
  [ "$current" = null ] && current_text=待统计 || current_unit="$unit"
  change="$(daily_perf_report_change "$current" "$previous" "$unit")"
  average_text="$average"
  [ "$average" = null ] && average_text=待统计 || average_unit="$unit"
  baseline_text=''
  [ "$baseline" = null ] || baseline_text="；滚动基准中位数${baseline}${unit}"
  printf '%s：%s%s；%s；近七日均值%s%s%s。\n' \
    "$label" "$current_text" "$current_unit" "$change" "$average_text" "$average_unit" "$baseline_text"
}

daily_perf_report_duration() {
  local seconds="$1"
  [ "$seconds" = null ] && { printf '待统计'; return 0; }
  jq -nr --argjson seconds "$seconds" '($seconds / 60 | round | tostring) + "分钟"'
}

daily_perf_report_conclusion() {
  jq -nr --argjson current "$1" --argjson previous "$2" '
    def abs: if . < 0 then -. else . end;
    def metric($key; $label_name; $unit; $higher_better):
      {key:$key,label:$label_name,unit:$unit,higher_better:$higher_better,
       current:($current[$key]), previous:($previous[$key])};
    [metric("calls";"模型调用";"次";false),
     metric("tokens";"模型令牌";"枚";false),
     metric("released_issues";"上线事项";"张";true),
     metric("tokens_per_released_issue";"每张交付票平均令牌";"枚";false),
     metric("deploys";"发布次数";"次";true),
     metric("wakeups_day";"人工介入";"次";false),
     metric("recurrences_day";"同类复发";"次";false)]
    | map(select(.current != null and .previous != null)) as $metrics
    | [$metrics[] | select(.current != .previous)] as $changed
    | [$changed[] | select((.higher_better and .current > .previous) or ((.higher_better|not) and .current < .previous))] as $better
    | [$changed[] | select((.higher_better and .current < .previous) or ((.higher_better|not) and .current > .previous))] as $worse
    | (if ($better|length) > ($worse|length) then "较昨日整体变好"
       elif ($worse|length) > 0 then "较昨日整体变差"
       else "较昨日整体持平" end) as $direction
    | (if ($better|length) > ($worse|length) then $better
       elif ($worse|length) > 0 then $worse
       else $changed end) as $drivers
    | if ($drivers|length) == 0 then
        "一句话结论：\($direction)，各项指标没有明显变化。"
      else
        ($drivers | map(. + {magnitude:(if .previous == 0 then 1 else (((.current - .previous)|abs) / (.previous|abs)) end)}) | max_by(.magnitude)) as $driver
        | (if $driver.current > $driver.previous then "增加" else "减少" end) as $change
        | (((($driver.current - $driver.previous)|abs) | if . == floor then tostring else tostring end) + $driver.unit) as $amount
        | "一句话结论：\($direction)；最大变化来自\($driver.label)\($change)\($amount)。"
      end
  '
}

daily_perf_report_verification_line() {
  local agent_home="$1" repo_root="$2" report planned available unavailable unmapped feature_count
  if ! report="$(node "$SCRIPT_DIR/../verification-map-audit.mjs" --root "$repo_root" --state-dir "$agent_home/state" 2>/dev/null)"; then
    printf '功能验证映射：待统计。\n'
    return 0
  fi
  planned="$(jq -r '.state_evidence.planned // 0' <<< "$report")"
  available="$(jq -r '.state_evidence.available // 0' <<< "$report")"
  unavailable="$(jq -r '.state_evidence.unavailable // 0' <<< "$report")"
  unmapped="$(jq -r '.state_evidence.with_unmapped_paths // 0' <<< "$report")"
  feature_count="$(jq -r '.feature_count // 0' <<< "$report")"
  if [ "$planned" -eq 0 ]; then
    printf '功能验证映射：地图覆盖%s个功能；尚无真实工单样本。\n' "$feature_count"
  else
    printf '功能验证映射：地图覆盖%s个功能；已有%s张票记录，%s张可用，%s张不可用，%s张存在未映射路径。\n' \
      "$feature_count" "$planned" "$available" "$unavailable" "$unmapped"
  fi
}

daily_perf_report_timing_section() {
  local agent_home="$1" day="$2" repo_root="$3" dry_run="${4:-0}" origin repo
  local -a args=(daily --home "$agent_home" --day "$day")
  if [ "$dry_run" = 1 ]; then
    args+=(--read-only)
  else
    repo="${REPO:-}"
    if [ -z "$repo" ]; then
      origin="$(git -C "$repo_root" config --get remote.origin.url)" || return 1
      case "$origin" in
        git@github.com:*) repo="${origin#git@github.com:}" ;;
        https://github.com/*) repo="${origin#https://github.com/}" ;;
        *) printf 'daily-perf-report: unsupported GitHub remote\n' >&2; return 1 ;;
      esac
      repo="${repo%.git}"
    fi
    args+=(--repo "$repo")
  fi
  node "$SCRIPT_DIR/efficiency-regression.mjs" "${args[@]}" | jq -r '.mail_summary'
}

daily_perf_report_build() {
  local agent_home="$1" repo_root="$2" day="$3" guard_audit="$4" dry_run="${5:-0}" start_epoch end_epoch now label releases efficiency timing anomalies reason work_data active queued work_reason pipeline_efficiency report contract_errors
  start_epoch="$(date -u -d "$day 00:00:00" +%s)" || return 1
  end_epoch="$(date -u -d "$day +1 day 00:00:00" +%s)" || return 1
  now="$(date +%s)" || return 1
  label="$(maintainer_local_time "$(date -u -d "$day 00:00:00" +%s)" '%-m月%-d日')" || return 1
  releases="$(founder_health_mail_release_lines "$agent_home" "$start_epoch" "$end_epoch")" || return 1
  work_data="$(founder_health_mail_work_counts "$agent_home" "$now")" || work_data='{"active":null,"queued":null}'
  active="$(jq -r '.active // "null"' <<< "$work_data")" || return 1
  queued="$(jq -r '.queued // "null"' <<< "$work_data")" || return 1
  efficiency="$(founder_health_mail_efficiency_block "$agent_home" daily "$day" "$now" "$work_data" 2>/dev/null || true)"
  timing="$(daily_perf_report_timing_section "$agent_home" "$day" "$repo_root" "$dry_run")" || return 1
  if [ -z "$efficiency" ]; then
    efficiency="$(founder_health_mail_render_efficiency '{"current":{"launched":null,"closed":null,"created":null,"backlog":null,"average_hours":null},"previous":{"launched":null,"closed":null,"created":null,"backlog":null,"average_hours":null},"week":{"launched":null,"closed":null,"created":null,"backlog":null,"average_hours":null},"work":{"active":null,"queued":null}}' daily)" || return 1
  fi
  anomalies="$(founder_health_mail_current_anomalies "$agent_home" "$now")" || return 1
  reason="$(founder_health_mail_no_launch_reason)"
  work_reason="$(founder_health_mail_no_work_reason "$active" "$queued")"
  pipeline_efficiency="$(founder_health_mail_pipeline_efficiency_block "$agent_home" daily "$day")" || return 1
  report="$( {
    printf '**今日汇总（%s）**\n\n**上线情况**\n' "$label"
    if [ -n "$releases" ]; then printf '%s' "$releases"
    else printf '%s没有上线：%s。\n' "$label" "$reason"; fi
    printf '\n%s\n\n%s\n\n%s\n' "$efficiency" "$pipeline_efficiency" "$timing"
    [ -z "$work_reason" ] || printf '\n%s\n' "$work_reason"
    printf '\n**异常**\n%s\n' "$anomalies"
  } )" || return 1
  if ! contract_errors="$(founder_health_mail_output_contract "$report" "$now")"; then
    contract_errors="${contract_errors:-validator-failed}"
    if [ "$dry_run" != 1 ]; then
      founder_health_mail_contract_inbox "$agent_home" "$contract_errors" || return 1
    fi
    printf 'daily-perf-report: output contract failed: %s\n' "$contract_errors" >&2
    return 1
  fi
  printf '%s\n' "$report"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$SCRIPT_DIR/../config.sh"
  repo_root="${ZF_REPO_DIR:-$(cd -- "$SCRIPT_DIR/../.." && pwd -P)}"
  dry_run=0
  if [ "${1:-}" = --dry-run ]; then dry_run=1; shift; fi
  [ "$#" -le 1 ] || { printf 'usage: %s [--dry-run] [YYYY-MM-DD]\n' "$0" >&2; exit 2; }
  report_day="${1:-$(date -u -d yesterday +%Y-%m-%d)}"
  [[ "$report_day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo 'daily-perf-report: invalid date' >&2; exit 2; }
  [ "$(date -u -d "$report_day" +%Y-%m-%d 2>/dev/null || true)" = "$report_day" ] || {
    echo 'daily-perf-report: invalid date' >&2
    exit 2
  }
  guard_audit_args=(--repo "$repo_root" --history-dir "$AGENT_HOME/night/logs")
  if [ "$dry_run" != 1 ]; then
    guard_audit_args+=(--output "$AGENT_HOME/night/incident-guard-audit-$report_day.json")
  fi
  guard_audit="$(node "$SCRIPT_DIR/incident-guard-audit.mjs" "${guard_audit_args[@]}")" || exit 1
  report="$(daily_perf_report_build "$AGENT_HOME" "$repo_root" "$report_day" "$guard_audit" "$dry_run")" || exit 1
  if [ "$dry_run" = 1 ]; then
    printf '%s\n' "$report"
    exit 0
  fi
  daily_perf_report_reconcile_mail "$AGENT_HOME" "$report_day" || {
    echo 'daily-perf-report: failed to record mail-count comparison' >&2
    exit 1
  }
  mkdir -p "$AGENT_HOME/logs"
  report_file="$AGENT_HOME/logs/daily-perf-$report_day.md"
  tmp="$(mktemp "${report_file}.XXXXXX")"
  printf '%s\n' "$report" > "$tmp"
  mv -f "$tmp" "$report_file"
  founder_health_mail_record_event "$AGENT_HOME/night/founder-health-mail.json" \
    "daily:$report_day" '今日汇总' "$report" "$(date +%s)" daily >/dev/null
fi
