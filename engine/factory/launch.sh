#!/usr/bin/env bash
# Start one factory worker: locked worktree from origin/main, brief = issue pointer + factory rules + shared worker rules.
set -uo pipefail
unset GH_TOKEN
S=${HOME:-/tmp}/.zenoforge/scratch; C=$HOME/.zenoforge/checkout; WT=$HOME/.zenoforge/checkout-wt
key=$1 issue=$2 note=${3:-}; W=$WT/$key; B=$S/factory/$key.brief.md
# 10-29: three workers ran on an empty note (a bad path cat'ed to nothing) and burned gate slots
[[ -z $note || -f $note && -s $note ]] || { echo "FAILED $key: note $note is missing or empty" >&2; exit 1; }
[[ $issue != 0 || -n $note ]] || { echo "FAILED $key: issue 0 needs a note with the task" >&2; exit 1; }
git -C "$C" fetch -q origin main || exit 1
# scheduler intake skips opt-lane issues, so the pipeline never dispatches the same ticket twice
[[ $issue =~ ^[1-9][0-9]*$ ]] && gh issue edit "$issue" --add-label opt-lane >/dev/null 2>&1
[[ -d $W ]] || git -C "$C" worktree add -q --lock -b "factory/$key" "$W" origin/main || exit 1
{ if [[ $issue == 0 ]]; then printf '# 你的任务：按下面“本票的补充说明”执行（没有对应的 GitHub issue，issue 号 0 表示无票，不要去查 issue）\n\nworktree：%s\n\n' "$W"
  else printf '# 你的任务：实现 GitHub issue #%s（%s）\n\n先读 issue 正文，再按下面的规则执行。worktree：%s\n\n' "$issue" "${ZF_REPO:-}" "$W"; fi
  cat "$S/factory/common.md"; [[ -n $note ]] && { printf "\n## 本票的补充说明（CTO 审核）\n"; cat "$note"; }; printf '\n## Shared brief rules\n'; cat "$S/luna/briefs/_rules.md"
  # maintainer 10-29: notes/issues kept asking for tests and overrode common.md; this line comes last so it wins
  printf '\n## 最终规则（优先于上文任何测试要求）\n非产品代码：落地前不写测试也不跑测试，改完立即 land-direct-main 落地，落地即生效。验收项里的测试要求一律视为不适用。land-direct-main 自带的 preflight 照常运行，不算你在跑测试，不要因此停下来问。\n'; } > "$B"
# 10-30 head: opt workers bypassed the luna CPU cap (CPUQuota=infinity); cap every opt worker at start (hotfix weight is 1000)
systemd-run --user --unit "$key" --collect -p CPUQuota="${LUNA_CPU_QUOTA:-200%}" -p CPUWeight=100 -E PATH -E https_proxy -E HTTPS_PROXY -E http_proxy -E HTTP_PROXY \
  -E no_proxy -E NO_PROXY -E ALL_PROXY -E NODE_USE_ENV_PROXY -E LUNA_PRIORITY=opt -E LUNA_AGE_ADMIT_SECONDS -p WorkingDirectory="$W" \
  "$S/bin/worker" "$key" "$W" "$B" >/dev/null 2>&1 && echo "started $key #$issue" || echo "FAILED $key"
