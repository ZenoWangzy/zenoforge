#!/usr/bin/env bash
# M3 传感器/执行器分离（#4499，spec #4495）：规则文件清单（engine/state/rule-files.json）
# 内的文件是 pipeline 的控制信号。unit 的 diff 碰到清单内文件，落地被拒；supervisor
# （ZF_AGENT_NAME=supervisor）走规则通道：改动提交必须带 Rule-Replay: <报告路径> trailer。
# 无 baseline 报告要求 falseStops 为 0；有 baseline 时要求 newFalseStops 为 0。
# 每次调用都输出一条 rule-lane 判定行（M5 生产事件：落地日志里核对这条线）。
set -euo pipefail

(( $# == 2 )) || { echo "rule-lane: usage: rule-lane.sh <base-sha> <head-sha>" >&2; exit 2; }
base="$1"
head="$2"

manifest_path="${ZF_PACK_REL:-engine}/state/rule-files.json"
rule_fix_hint='规则改动由 supervisor 落地：direct-main 规则通道，或 supervisor 合入的 PR 带 Rule-Replay 回放报告；unit PR 即使带回放报告也会拒绝。健康告警请修行为，并挂到根因票下。'

# 清单优先取被落地 head 的树；head 删除清单时退回 base，使删除本身仍算触碰清单内路径。
manifest_ref="$head"
git cat-file -e "$head:$manifest_path" 2>/dev/null || manifest_ref="$base"

declare -A rule_set=()
if git cat-file -e "$manifest_ref:$manifest_path" 2>/dev/null; then
  manifest_list="$(git show "$manifest_ref:$manifest_path" | jq -er '
    if .schema == "zf-rule-files/v1" and (.files | type == "object")
    then .files | keys[] | strings
    else error("manifest must be zf-rule-files/v1 with a files object") end')" || {
    echo "rule-lane: rule manifest $manifest_path at $manifest_ref is invalid" >&2
    exit 2
  }
  while IFS= read -r rule_file; do
    [[ -n "$rule_file" ]] && rule_set["$rule_file"]=1
  done <<< "$manifest_list"
fi

mapfile -t changed < <(git diff --name-only --no-renames "$base...$head")
touched=()
for path in "${changed[@]}"; do
  [[ -n "${rule_set[$path]:-}" ]] && touched+=("$path")
done

actor=unit
[[ "${ZF_AGENT_NAME:-}" == supervisor ]] && actor=supervisor

if (( ${#touched[@]} == 0 )); then
  printf 'rule-lane: decision=pass actor=%s touched=0\n' "$actor" >&2
  exit 0
fi

if [[ "$actor" == unit ]]; then
  printf 'rule-lane: decision=unit-reject refused=rule-files actor=%s touched=%s files=%s\n' \
    "${ZF_AGENT_NAME:-unknown}" "${#touched[@]}" "${touched[*]}" >&2
  printf 'rule-lane: %s\n' "$rule_fix_hint" >&2
  exit 1
fi

# 规则通道：每个碰到清单内文件的提交都要引用回测报告，且报告在误杀为 0 时才放行。
reports_validated=0
baseline_reports=0
candidate_false_stops=0
new_false_stops=0
for commit in $(git rev-list --reverse "$base..$head"); do
  commit_touched=0
  while IFS= read -r path; do
    [[ -n "${rule_set[$path]:-}" ]] || continue
    commit_touched=1
    break
  done < <(git diff-tree --no-commit-id --name-only -r "$commit")
  (( commit_touched )) || continue

  trailer_paths="$(git show -s --format='%(trailers:key=Rule-Replay,valueonly)' "$commit")"
  if [[ -z "$trailer_paths" ]]; then
    printf 'rule-lane: decision=rule-reject refused=rule-lane commit=%s reason=missing-trailer touched=%s\n' \
      "${commit:0:12}" "${touched[*]}" >&2
    printf 'rule-lane: 规则通道提交需要 Rule-Replay: <docs/agents/rule-replays/ 报告路径> trailer。%s\n' "$rule_fix_hint" >&2
    exit 1
  fi
  while IFS= read -r report_path; do
    [[ -n "$report_path" ]] || continue
    if ! report_json="$(git show "$commit:$report_path" 2>/dev/null)"; then
      printf 'rule-lane: decision=rule-reject refused=rule-lane commit=%s reason=report-missing path=%s\n' \
        "${commit:0:12}" "$report_path" >&2
      printf 'rule-lane: 回测报告必须随规则改动提交进仓库。%s\n' "$rule_fix_hint" >&2
      exit 1
    fi
    if ! jq -e '.schema == "zf-control-rule-replay/v1" and (.falseStops | type == "array")' \
        <<< "$report_json" >/dev/null 2>&1; then
      printf 'rule-lane: decision=rule-reject refused=rule-lane commit=%s reason=invalid-report path=%s\n' \
        "${commit:0:12}" "$report_path" >&2
      printf 'rule-lane: 回测报告格式无效，不能落地。%s\n' "$rule_fix_hint" >&2
      exit 1
    fi
    false_stops="$(jq -r '.falseStops | length' <<< "$report_json")"
    candidate_false_stops=$((candidate_false_stops + false_stops))
    if jq -e 'has("baseline")' <<< "$report_json" >/dev/null; then
      if ! jq -e '(.baseline | type == "object") and (.changedDecisions | type == "array") and (.newFalseStops | type == "array")' \
          <<< "$report_json" >/dev/null 2>&1; then
        printf 'rule-lane: decision=rule-reject refused=rule-lane commit=%s reason=invalid-baseline-report path=%s\n' \
          "${commit:0:12}" "$report_path" >&2
        printf 'rule-lane: baseline 回测报告缺少比较结果，不能落地。%s\n' "$rule_fix_hint" >&2
        exit 1
      fi
      new_stops="$(jq -r '.newFalseStops | length' <<< "$report_json")"
      if (( new_stops > 0 )); then
        printf 'rule-lane: decision=rule-reject refused=rule-lane commit=%s reason=new-false-stops count=%s path=%s\n' \
          "${commit:0:12}" "$new_stops" "$report_path" >&2
        printf 'rule-lane: baseline 对比发现新增历史误杀，不能落地。%s\n' "$rule_fix_hint" >&2
        exit 1
      fi
      baseline_reports=$((baseline_reports + 1))
      new_false_stops=$((new_false_stops + new_stops))
    elif (( false_stops > 0 )); then
      printf 'rule-lane: decision=rule-reject refused=rule-lane commit=%s reason=false-stops count=%s path=%s\n' \
        "${commit:0:12}" "$false_stops" "$report_path" >&2
      printf 'rule-lane: 回测误杀不为 0，不能落地。%s\n' "$rule_fix_hint" >&2
      exit 1
    fi
    reports_validated=$((reports_validated + 1))
  done <<< "$trailer_paths"
done

if (( baseline_reports > 0 )); then
  printf 'rule-lane: decision=rule-lane actor=supervisor touched=%s reports=%s false-stops=%s new-false-stops=%s\n' \
    "${#touched[@]}" "$reports_validated" "$candidate_false_stops" "$new_false_stops" >&2
else
  printf 'rule-lane: decision=rule-lane actor=supervisor touched=%s reports=%s false-stops=0\n' \
    "${#touched[@]}" "$reports_validated" >&2
fi
exit 0
