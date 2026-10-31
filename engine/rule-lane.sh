#!/usr/bin/env bash
# M3 传感器/执行器分离（#4499，spec #4495）：规则文件清单（engine/state/rule-files.json）
# 内的文件是 pipeline 的控制信号。unit 的 diff 碰到清单内文件，落地被拒；supervisor
# （ZF_AGENT_NAME=supervisor）走规则通道：按 2026-10-31 裁决，对触碰文件做语法检查。
# 每次调用都输出一条 rule-lane 判定行（M5 生产事件：落地日志里核对这条线）。
set -euo pipefail

(( $# == 2 )) || { echo "rule-lane: usage: rule-lane.sh <base-sha> <head-sha>" >&2; exit 2; }
base="$1"
head="$2"

manifest_path="${ZF_PACK_REL:-engine}/state/rule-files.json"
rule_fix_hint='规则改动由 supervisor 落地并通过语法检查；unit PR 即使带回放报告也会拒绝。健康告警请修行为，并挂到根因票下。'

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

for path in "${touched[@]}"; do
  # 删除路径在 head 没有内容可检查。
  git cat-file -e "$head:$path" 2>/dev/null || continue
  syntax_status=0
  case "$path" in
    *.json)
      if ! git show "$head:$path" | jq empty >/dev/null 2>&1; then syntax_status=1; fi
      ;;
    *.sh|*.py|*.mjs|*.js)
      if ! syntax_dir="$(mktemp -d)"; then
        syntax_status=1
      else
        syntax_file="$syntax_dir/rule.${path##*.}"
        if ! git show "$head:$path" > "$syntax_file"; then
          syntax_status=1
        else
          case "$path" in
            *.sh) bash -n "$syntax_file" || syntax_status=1 ;;
            *.py) python3 -m py_compile "$syntax_file" || syntax_status=1 ;;
            *.mjs|*.js) node --check "$syntax_file" || syntax_status=1 ;;
          esac
        fi
        rm -rf -- "$syntax_dir"
      fi
      ;;
  esac
  if (( syntax_status != 0 )); then
    printf 'rule-lane: decision=rule-reject refused=syntax path=%s\n' "$path" >&2
    exit 1
  fi
done

printf 'rule-lane: decision=rule-lane actor=supervisor touched=%s check=syntax\n' "${#touched[@]}" >&2
exit 0
