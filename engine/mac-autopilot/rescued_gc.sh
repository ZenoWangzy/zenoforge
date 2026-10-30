#!/usr/bin/env bash
# rescued/* 分支的生命周期收尾（2026-10-22 维护者裁决：归档后按规则自动清理）。
# run-implement.sh 在 worker 失败时把未提交改动推到 rescued/issue-N-<时间>，下一次实现会取回；此前从无清理，攒到 479 个。
# 规则：issue 已关闭 → 删；名字里没有 issue 号且最后提交超过 RESCUED_MAX_AGE_DAYS（默认 14）天 → 删；其余保留。
# 删除前先把提交以 refs/zf-rescue/archived/<名> 推到 GitHub（git fetch origin refs/zf-rescue/archived/<名> 即可取回），存档成功才删，每删一条在 <log> 记一行。
# 用法：rescued_gc.sh <repo> <log>；GitHub 查询失败就整轮跳过，绝不在不知道 issue 状态时删。
set -euo pipefail
repo="${1:?repo}" log="${2:?log file}"
max_age_days="${RESCUED_MAX_AGE_DAYS:-14}"
now="${NOW_EPOCH:-$(date +%s)}"
stamp="$(date -u -d "@$now" +%Y%m%dT%H%M%SZ)"

git -C "$repo" fetch -q --prune origin '+refs/heads/rescued/*:refs/remotes/origin/rescued/*' 2>/dev/null || exit 0
declare -A sha_of=() age_ok=() issue_of=()
while read -r ref when sha; do
  b="${ref#origin/}"
  sha_of["$b"]="$sha"
  (( now - when > max_age_days * 86400 )) && age_ok["$b"]=1
  [[ "$b" =~ issue-([0-9]+) ]] && issue_of["$b"]="${BASH_REMATCH[1]}"
done < <(git -C "$repo" for-each-ref --format='%(refname:short) %(committerdate:unix) %(objectname)' refs/remotes/origin/rescued/)
(( ${#sha_of[@]} )) || exit 0

# issue 状态：GraphQL 每批 100 个别名；任何一批失败就整轮放弃。
declare -A closed=()
mapfile -t nums < <(printf '%s\n' "${issue_of[@]}" | sort -un)
owner_repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || exit 0
for ((i = 0; i < ${#nums[@]}; i += 100)); do
  q="query { repository(owner: \"${owner_repo%/*}\", name: \"${owner_repo#*/}\") {"
  for n in "${nums[@]:i:100}"; do q+=" i$n: issueOrPullRequest(number: $n) { ... on Issue { state } ... on PullRequest { state } }"; done
  q+=" } }"
  out="$(gh api graphql -f query="$q" --jq '.data.repository | to_entries[] | select(.value.state == "CLOSED" or .value.state == "MERGED") | .key' 2>/dev/null)" || exit 0
  while read -r k; do [[ -n "$k" ]] && closed["${k#i}"]=1; done <<<"$out"
done

victims=() reasons=()
for b in "${!sha_of[@]}"; do
  n="${issue_of[$b]:-}"
  if [[ -n "$n" && -n "${closed[$n]:-}" ]]; then victims+=("$b"); reasons+=("closed-issue-$n")
  elif [[ -z "$n" && -n "${age_ok[$b]:-}" ]]; then victims+=("$b"); reasons+=("no-issue-older-${max_age_days}d")
  fi
done
(( ${#victims[@]} )) || exit 0

deleted=0 failed=0
for ((i = 0; i < ${#victims[@]}; i += 50)); do
  batch=("${victims[@]:i:50}")
  specs=(); for b in "${batch[@]}"; do specs+=("${sha_of[$b]}:refs/zf-rescue/archived/${b#rescued/}"); done
  # 先把提交以非分支 ref 存档到 GitHub；存档推送失败则这批一条不删。
  if ! git -C "$repo" push -q origin "${specs[@]}" 2>/dev/null; then failed=1; continue; fi
  git -C "$repo" push -q origin --delete "${batch[@]}" 2>/dev/null || continue
  for ((j = 0; j < ${#batch[@]}; j++)); do
    printf '%s deleted %s %s reason=%s archive=refs/zf-rescue/archived/%s\n' "$stamp" "${batch[j]}" "${sha_of[${batch[j]}]}" "${reasons[i + j]}" "${batch[j]#rescued/}" >> "$log"
    deleted=$((deleted + 1))
  done
done
echo "rescued_gc: deleted $deleted of ${#sha_of[@]} rescued branches (archived under refs/zf-rescue/archived/)"
(( failed == 0 )) || { echo "rescued_gc: archive push failed for at least one batch; that batch was not deleted" >&2; exit 1; }
