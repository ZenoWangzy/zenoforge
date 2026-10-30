#!/usr/bin/env bash
# 非产品快车道：把已批准（head 绑定）的 PR 压成一个 [skip ci] 提交，经 land-direct-main.sh 直落 main，
# 成功后关闭 PR。由 scheduler 作为 land worker 派发；结果写入报告文件（LANDED <sha> | FAILED <原因>）。
# 用法: land-pr.sh <clone-dir> <pr> <approved-sha> <title> <report-path> <reviewed-pr-head> [issue]
#   pr 为空 = 无 PR 的直落单元：reviewed-pr-head 是本地分支与 main 的分叉点，落地后不碰 PR。 <reviewed-pr-head>
set -uo pipefail
: "${ZF_AGENT_GIT_USER_NAME:=zenoforge-agent}" "${ZF_AGENT_GIT_USER_EMAIL:=zenoforge-agent@users.noreply.github.com}"
export ZF_AGENT_GIT_USER_NAME ZF_AGENT_GIT_USER_EMAIL
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$ZF_AGENT_GIT_USER_NAME}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$ZF_AGENT_GIT_USER_EMAIL}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$ZF_AGENT_GIT_USER_NAME}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$ZF_AGENT_GIT_USER_EMAIL}"
dir="$1" pr="$2" sha="$3" title="$4" report="$5" reviewed_pr_head="${6:-}" issue="${7:-}"
finish() { printf '%s\n' "$1" > "$report.partial" && mv -f "$report.partial" "$report"; exit 0; }

cd "$dir" || finish "FAILED clone $dir unavailable"
if [[ -n "$pr" ]]; then
  git fetch -q origin main || finish "FAILED fetch of main/PR head"
  git fetch -q origin "refs/pull/$pr/head" || finish "FAILED fetch of main/PR head"
  pr_head="$(git rev-parse FETCH_HEAD)"
else
  git fetch -q origin main || finish "FAILED fetch of main"
  pr_head="$reviewed_pr_head"
fi
[[ "$reviewed_pr_head" =~ ^[0-9a-f]{40}$ ]] || finish "FAILED missing reviewed PR head for approved $sha"
git cat-file -e "${sha}^{commit}" 2>/dev/null || finish "FAILED unknown approved SHA $sha"
# The approved candidate may be a local repair commit, but it must descend from the exact PR head observed during review.
git merge-base --is-ancestor "$reviewed_pr_head" "$sha" 2>/dev/null \
  || finish "FAILED approved $sha is not based on reviewed PR head $reviewed_pr_head"
[[ "$pr_head" == "$reviewed_pr_head" ]] \
  || finish "FAILED PR head moved since approval (reviewed $reviewed_pr_head current $pr_head)"
base="$(git merge-base origin/main "$sha")" || finish "FAILED cannot find main merge base for $sha"
mapfile -d '' -t changes < <(git -c core.quotePath=false diff --name-status -z --find-renames "$base" "$sha")
files=()
for ((i = 0; i < ${#changes[@]}; )); do
  status="${changes[i]}"
  ((i += 1))
  case "$status" in
    R*|C*)
      ((i + 1 < ${#changes[@]})) || finish "FAILED malformed rename diff for $sha"
      files+=("${changes[i]}" "${changes[i + 1]}")
      ((i += 2))
      ;;
    *)
      ((i < ${#changes[@]})) || finish "FAILED malformed name-status diff for $sha"
      files+=("${changes[i]}")
      ((i += 1))
      ;;
  esac
done
((${#files[@]})) || finish "FAILED PR has no changes against main"
paths_json="$(printf '%s\n' "${files[@]}" | jq -Rnc '[inputs]')"
[[ "$(node "${LAND_PR_POLICY:-scripts/branch-delivery-policy.mjs}" --classify-path-set - <<<"$paths_json")" == eligible ]] \
  || finish "FAILED not eligible for the direct-main lane (product paths)"

ref="${pr:-$issue}"
git checkout -q -B "land-pr-${pr:-local}" origin/main || finish "FAILED checkout of origin/main"
git merge -q --squash "$sha" >/dev/null 2>&1 || { git merge --abort 2>/dev/null; git reset -q --hard origin/main; finish "FAILED squash of $sha conflicts with main"; }
git -c user.name="${ZF_AGENT_GIT_USER_NAME:-zenoforge-agent}" -c user.email="${ZF_AGENT_GIT_USER_EMAIL:-zenoforge-agent@users.noreply.github.com}" \
  commit -q -m "[skip ci] ${title}${ref:+ (#${ref})}" \
  -m "Squash-landed from ${pr:+PR #${pr} }(approved head ${sha}) through the autopilot direct-main lane." \
  || finish "FAILED squash commit"

log="$report.land.log"
# 改了落地机制本身的 PR 可能把落地器卡死（#3985 自锁 75 分钟）；超时整组杀掉，不留任何东西等下一次落地。
land_timeout="${LAND_PR_TIMEOUT_SECONDS:-1500}"
ZF_LAND_GIT_TIMEOUT_SECONDS="${ZF_LAND_GIT_TIMEOUT_SECONDS:-900}" timeout -k 30 "$land_timeout" \
  bash "${LAND_PR_LANDER:-engine/land-direct-main.sh}" > "$log" 2>&1
case $? in
  0) ;;
  124|137) finish "FAILED land-direct-main timed out after ${land_timeout}s (wedged lander; killed)" ;;
  *) finish "FAILED land-direct-main: $(grep -E 'outcome=|refus|must|Error' "$log" | tail -1)" ;;
esac
landed="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$landed" origin/main 2>/dev/null || git fetch -q origin main
[[ -n "$pr" ]] || finish "LANDED $landed"
if ! git fetch -q origin "refs/pull/$pr/head"; then
  finish "FAILED POST-LAND PR HEAD-RECHECK $landed"
fi
current_pr_head="$(git rev-parse FETCH_HEAD)"
[[ "$current_pr_head" == "$reviewed_pr_head" ]] || finish "LANDED-HEAD-MOVED $landed $current_pr_head"

if ! gh pr close "$pr" --comment "Landed on main as ${landed} through the autopilot direct-main lane (non-product change; approved head ${sha} squash-landed with land-direct-main.sh preflight)." >>"$log" 2>&1; then
  finish "FAILED POST-LAND PR CLOSE $landed"
fi

# Narrow the remaining close race: if a commit arrived between the pre-close fetch and close,
# reopen the PR so that the new head can be reviewed instead of silently closing it.
if ! git fetch -q origin "refs/pull/$pr/head"; then
  gh pr reopen "$pr" >>"$log" 2>&1 || true
  finish "FAILED POST-LAND PR HEAD-RECHECK $landed"
fi
current_pr_head="$(git rev-parse FETCH_HEAD)"
if [[ "$current_pr_head" != "$reviewed_pr_head" ]]; then
  if gh pr reopen "$pr" >>"$log" 2>&1; then
    finish "LANDED-HEAD-MOVED $landed $current_pr_head"
  fi
  finish "FAILED POST-LAND PR REOPEN $landed"
fi
finish "LANDED $landed"
