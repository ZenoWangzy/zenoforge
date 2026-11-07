#!/usr/bin/env bash
# Sourced by land-direct-main.sh and land-direct-main-bootstrap.sh; each defines land_git_rebase and agent_home first.
# zf-ab 裁决（10-29）：footprint 互斥对 shared-append 注册表文件放行并行，文本冲突在落地
# rebase 处解决。这里把改动范围带 shared-append 文件的落地 rebase 记进共享日志
# （node_health 的 ci.shared_append_rebase_conflict_pct 读它）；遥测失败不阻断落地。
land_shared_append_range_files() { # base -> 落地范围与 shared-append 名单的交集（JSON 数组；无需记录时输出空）
  local base="$1" range template
  git merge-base --is-ancestor "$base" HEAD 2>/dev/null && return 0 # up-to-date 的 rebase 不重放提交
  range="$(git diff --name-only --no-renames "$base...HEAD" 2>/dev/null)" || return 0
  [[ -n "$range" ]] || return 0
  template="$(zf_config_file mac-autopilot/config.template.json)" || template="$land_script_dir/mac-autopilot/config.template.json"
  printf '%s' "$range" | jq -Rsc --slurpfile cfg "$template" '
    (($cfg[0].footprint_mutex.shared_append // []) | map(select(type == "string"))) as $sa
    | split("\n") | [.[] | select(length > 0) | select(. as $x | any($sa[]; . == $x))]' 2>/dev/null || return 0
}
land_record_shared_append_rebase() { # base shared_files_json conflict_bool conflict_files_json
  local when row
  when="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 0
  row="$(jq -cn --arg when "$when" --arg repo "${ZF_REPO:-example-maintainer/example-repo}" \
      --arg actor "${ZF_AGENT_NAME:-direct-main}" --arg base "$1" \
      --argjson files "$2" --argjson conflict "$3" --argjson cfiles "$4" '
    {schema: "zf-shared-append-rebase/v1", when: $when, repo: $repo, actor: $actor, base: $base,
     shared_files: $files, conflict: $conflict, conflict_files: $cfiles}')" || return 0
  mkdir -p -- "$agent_home/logs" 2>/dev/null || return 0
  printf '%s\n' "$row" >> "$agent_home/logs/shared-append-rebases.jsonl" 2>/dev/null || return 0
}
land_rebase_record_shared_append() { # base；rebase 本体失败照旧向上返回，rebase 停在冲突态时可见未合并路径
  local base="$1" files cfiles='[]'
  files="$(land_shared_append_range_files "$base")"
  if land_git_rebase "$base"; then
    [[ -n "$files" && "$files" != '[]' ]] \
      && land_record_shared_append_rebase "$base" "$files" false "$cfiles"
    return 0
  fi
  if [[ -n "$files" && "$files" != '[]' ]]; then
    cfiles="$(git diff --name-only --diff-filter=U 2>/dev/null | jq -Rsc --argjson files "$files" \
      'split("\n") | [.[] | select(length > 0) | select(. as $x | ($files | index($x)) != null)]' 2>/dev/null || true)"
    land_record_shared_append_rebase "$base" "$files" true "${cfiles:-[]}"
  fi
  return 1
}
