#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/test-scheduler-gates-fixture.sh"
fail() { echo "implement-no-push-recovery.test.sh: $*" >&2; exit 1; }
units() { printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
stage_of() { jq -r --arg id "$1" --arg st "$2" '[.units[] | select(.id==$id) | .history[]? | select(.stage==$st)] | length' "$UNITS"; }
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
M1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
M2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
M3=cccccccccccccccccccccccccccccccccccccccc
source "$script_dir/test-scheduler-gates-gh-fixture.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
ensure_clone() { printf '%s' "$WT_ROOT/wt-$1"; }
checkout_pr_head() { :; }

# 远端没有 agent/issue-* 分支时，harvest_pr_implement 先诊断 worktree 再决定路由（#5180/#5071/#5246）：
# 1) 已提交未推送 → 引擎代推 topic 分支并照常开 PR（推不动才带 push 错误转 supervisor）；
# 2) 空交付（无提交、树干净）→ 独立的 implement-no-changes 类，两次才转 supervisor，消息带原因；
# 3) 只有未提交改动 → 维持原 implement-no-push 重试/升级，升级消息补充原因。
np="$fixture/no-push-recovery"; rm -rf "$np"; mkdir -p "$np"
np_origin() { command git -C "$np/origin.git" "$@"; }
np_wt() { command git -C "$WT_ROOT/wt-$1" "${@:2}"; }
command git init -q --bare -b main "$np/origin.git"
command git init -q -b main "$np/src"
printf 'base\n' > "$np/src/f"; command git -C "$np/src" add -A; command git -C "$np/src" commit -qm base
command git -C "$np/src" remote add origin "$np/origin.git"; command git -C "$np/src" push -q origin main
WT_ROOT_SAVED="$WT_ROOT"; WT_ROOT="$np/wt-root"; mkdir -p "$WT_ROOT"
np_gh_saved="$(declare -f gh)"; : > "$fixture/np-create.log"
gh() { case "$1 $2" in "pr list") echo "" ;; "pr create") printf 'create\n' >> "$fixture/np-create.log"; echo "https://github.com/example-maintainer/example-repo/pull/4200" ;; *) eval "${np_gh_saved/gh ()/gh_s ()}"; gh_s "$@" ;; esac; }

# 1) worker 已提交但没推（#5180/#5071：产品侧 preflight 拒绝 --publish-topic，worker 遵守策略未推）。
command git clone -q "$np/origin.git" "$WT_ROOT/wt-issue-901"
np_wt issue-901 checkout -q -b agent/issue-901
printf 'fix\n' > "$WT_ROOT/wt-issue-901/f"; np_wt issue-901 add -A; np_wt issue-901 commit -qm impl
np_local_head="$(np_wt issue-901 rev-parse HEAD)"
units '{"units":[{"id":"issue-901","issue":901,"title":"stuck fix","branch":"agent/issue-901","lane":"pr","stage":"implement","history":[]}]}'
printf 'fix delivered\n' > "$sup/impl-901.md"
harvest_pr_implement issue-901 "$sup/impl-901.md" || :
[[ "$(np_origin rev-parse -q --verify refs/heads/agent/issue-901)" == "$np_local_head" ]] \
  || fail 'engine did not publish the worker committed branch (origin lacks agent/issue-901)'
[[ "$(field issue-901 .stage)" == review-pending && "$(field issue-901 .pr)" == 4200 ]] \
  || fail "committed-but-unpushed work was not recovered into review ($(field issue-901 .stage) pr=$(field issue-901 .pr))"
[[ "$(stage_of issue-901 implement-push-recovered)" == 1 && "$(field issue-901 '.history[] | select(.stage=="implement-push-recovered") | .result')" == *"engine pushed worker commit $np_local_head"* ]] \
  || fail 'recovery is not recorded with its cause in history'

# 2) 空交付（#5246：改动落在别的 checkout/远端，指定 worktree 既无提交也无未提交改动）。
command git clone -q "$np/origin.git" "$WT_ROOT/wt-issue-902"
np_wt issue-902 checkout -q -b agent/issue-902
units '{"units":[{"id":"issue-902","issue":902,"title":"empty run","branch":"agent/issue-902","lane":"pr","stage":"implement","history":[]}]}'
printf 'report only\n' > "$sup/impl-902.md"
harvest_pr_implement issue-902 "$sup/impl-902.md" || :
[[ "$(stage_of issue-902 implement-no-changes)" == 1 && "$(field issue-902 .stage)" == implement-pending ]] \
  || fail "empty delivery was not classed as its own no-changes retry ($(field issue-902 .stage))"
[[ "$(stage_of issue-902 implement-no-push)" == 0 && "$(field issue-902 .task)" == *'既没有本地提交也没有未提交改动'* ]] \
  || fail 'no-changes retry hint does not name the empty-worktree cause'
harvest_pr_implement issue-902 "$sup/impl-902.md" || :
[[ "$(field issue-902 .stage)" == supervisor-review && "$(field issue-902 .note)" == *'delivered no changes in the assigned worktree twice'* && "$(field issue-902 .note)" == *'clean tree'* ]] \
  || fail "second empty delivery did not escalate with the no-changes cause ($(field issue-902 .note))"

# 3) 引擎代推失败（pre-receive 拒绝）：升级消息带上提交与 push 错误，不盲跑第二轮 implement。
command git init -q --bare -b main "$np/origin-denied.git"
command git clone -q "$np/origin.git" "$np/seed2"
command git -C "$np/seed2" remote set-url origin "$np/origin-denied.git"
command git -C "$np/seed2" push -q origin main
mkdir -p "$np/origin-denied.git/hooks"
printf '#!/usr/bin/env bash\necho "hook: denied for test" >&2\nexit 1\n' > "$np/origin-denied.git/hooks/pre-receive"
chmod +x "$np/origin-denied.git/hooks/pre-receive"
command git clone -q "$np/origin-denied.git" "$WT_ROOT/wt-issue-903"
np_wt issue-903 checkout -q -b agent/issue-903
printf 'fix\n' > "$WT_ROOT/wt-issue-903/f"; np_wt issue-903 add -A; np_wt issue-903 commit -qm impl
np_denied_head="$(np_wt issue-903 rev-parse HEAD)"
units '{"units":[{"id":"issue-903","issue":903,"title":"denied push","branch":"agent/issue-903","lane":"pr","stage":"implement","history":[]}]}'
printf 'fix delivered\n' > "$sup/impl-903.md"
harvest_pr_implement issue-903 "$sup/impl-903.md" || :
[[ "$(field issue-903 .stage)" == supervisor-review && "$(field issue-903 .note)" == *"committed $np_denied_head on agent/issue-903 but publishing it failed"* && "$(field issue-903 .note)" == *'denied'* ]] \
  || fail "failed engine publish did not escalate with the commit and push error ($(field issue-903 .note))"
[[ "$(stage_of issue-903 implement-push-recovered)" == 0 ]] || fail 'a rejected publish was still recorded as recovered'

# 4) 只有未提交改动、没有本地提交：维持 implement-no-push 重试；第二次升级时消息补充原因。
command git clone -q "$np/origin.git" "$WT_ROOT/wt-issue-904"
np_wt issue-904 checkout -q -b agent/issue-904
printf 'dirty\n' > "$WT_ROOT/wt-issue-904/f"
units '{"units":[{"id":"issue-904","issue":904,"title":"dirty run","branch":"agent/issue-904","lane":"pr","stage":"implement","history":[{"stage":"implement-no-push","result":"impl-issue-904-1.md","at":"2026-11-02T00:00:00Z"}]}]}'
printf 'fix delivered\n' > "$sup/impl-904.md"
harvest_pr_implement issue-904 "$sup/impl-904.md" || :
[[ "$(field issue-904 .stage)" == supervisor-review && "$(field issue-904 .note)" == *'pushed no branch agent/issue-904 twice'* && "$(field issue-904 .note)" == *'uncommitted edits'* ]] \
  || fail "dirty-tree escalation does not carry the worktree cause ($(field issue-904 .note))"
[[ -z "$(np_origin rev-parse -q --verify refs/heads/agent/issue-904 2>/dev/null)" ]] \
  || fail 'uncommitted edits must not be pushed or published'

# 5) The counter never resets, so after one ruling every empty delivery escalated again (9 lines over 2 units in 24 h):
# the repeat takes the recut route once; a unit that already had a recut still goes to the supervisor.
routed="$fixture/np-routed"; : > "$routed"
scheduler_route_to_recut() { printf '%s ' "$1" >> "$routed"; }
esc='{"stage":"supervisor-escalated","result":"implement delivered no changes in the assigned worktree twice: x","at":"2026-11-02T00:00:00Z"}'
nc='{"stage":"implement-no-changes","result":"impl-1.md","at":"2026-11-02T00:00:00Z"}'
for n in 905 906; do
  command git clone -q "$np/origin.git" "$WT_ROOT/wt-issue-$n"
  np_wt issue-$n checkout -q -b agent/issue-$n
done
units '{"units":[{"id":"issue-905","issue":905,"title":"repeat","branch":"agent/issue-905","lane":"pr","stage":"implement","history":['"$nc,$esc"']},
 {"id":"issue-906","issue":906,"title":"recut already","branch":"agent/issue-906","lane":"pr","stage":"implement","history":['"$nc,$esc"',{"stage":"supervisor-budget-recut","result":"x","at":"2026-11-03T00:00:00Z"}]}]}'
printf 'report only\n' > "$sup/impl-905.md"
harvest_pr_implement issue-905 "$sup/impl-905.md" || :
[[ "$(field issue-905 .stage)" == closed && "$(stage_of issue-905 supervisor-budget-recut)" == 1 && "$(cat "$routed")" == '905 ' ]] \
  || fail "a repeat empty delivery was not sent to recut once ($(field issue-905 .stage))"
harvest_pr_implement issue-906 "$sup/impl-905.md" || :
[[ "$(field issue-906 .stage)" == supervisor-review && "$(cat "$routed")" == '905 ' ]] \
  || fail "a unit that already had a recut must go to the supervisor ($(field issue-906 .stage))"

eval "$np_gh_saved"; WT_ROOT="$WT_ROOT_SAVED"
echo 'implement-no-push-recovery.test.sh: PASS'
