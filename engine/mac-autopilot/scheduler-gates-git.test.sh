#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/test-scheduler-gates-fixture.sh"
fail() { echo "scheduler-gates.test.sh: $*" >&2; exit 1; }
units() { reset_gate_fixture_reads; printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
M1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
M2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
M3=cccccccccccccccccccccccccccccccccccccccc
source "$script_dir/test-scheduler-gates-gh-fixture.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
alive() { [[ " ${ALIVE_PIDS:-} " == *" $1 "* ]]; }
ensure_clone() { printf '%s' "$WT_ROOT/wt-$1"; }
checkout_pr_head() { :; }
# 尺寸准入（10-22 R2）：>800 改动行（锁文件/快照不计）的实现不开评审，连同数字转 supervisor 重切；
# 正好 800 或超出的行数都在锁文件里 → 照常开 PR（docs-only/generated-only 不因此阻断）。
sa="$fixture/size-admission"; mkdir -p "$sa"
command git init -q --bare -b main "$sa/origin.git"
command git init -q -b main "$sa/src"
sa_git() { command git -C "$sa/src" "$@"; }
sa_git config user.email t@example.invalid; sa_git config user.name t
echo base > "$sa/src/base.txt"; sa_git add -A; sa_git commit -qm base
sa_git remote add origin "$sa/origin.git"; sa_git push -q origin main
WT_ROOT_SAVED="$WT_ROOT"; WT_ROOT="$sa/wt-root"; mkdir -p "$WT_ROOT"
command git clone -q "$sa/origin.git" "$WT_ROOT/wt-issue-901"
sa_impl() { # code-lines lockfile-lines → 在 agent/issue-901 上重做一次实现并 force push
  sa_git checkout -q -B agent/issue-901 origin/main
  mkdir -p "$sa/src/packages/x"; seq 1 "$1" > "$sa/src/packages/x/large.ts"
  (( $2 > 0 )) && seq 1 "$2" >> "$sa/src/pnpm-lock.yaml"
  sa_git add -A; sa_git commit -qm impl; sa_git push -q -f origin agent/issue-901
}
size_gh_saved="$(declare -f gh)"; : > "$fixture/size-create.log"
gh() { case "$1 $2" in "pr list") echo "" ;; "pr create") printf 'create\n' >> "$fixture/size-create.log"; echo "https://github.com/example-maintainer/example-repo/pull/4100" ;; *) eval "${size_gh_saved/gh ()/gh_s ()}"; gh_s "$@" ;; esac; }
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","lane":"pr","stage":"implement","history":[]}]}'
printf 'fix delivered\n' > "$sup/impl-901.md"
sa_impl 801 0
harvest_pr_implement issue-901 "$sup/impl-901.md" || :
[[ "$(field issue-901 .stage)" == supervisor-review ]] || fail "801-line implementation was not routed to the supervisor re-scope ($(field issue-901 .stage))"
[[ "$(field issue-901 '.history[-1].stage')" == supervisor-escalated && "$(field issue-901 .note)" == *"801 changed lines"* && "$(field issue-901 .note)" == *"800"* ]] \
  || fail "size escalation lacks the numbers ($(field issue-901 .note))"
[[ "$(field issue-901 '.history[-1].decision.decision')" == 'Request recut or split before review' \
  && "$(field issue-901 '.history[-1].decision.evidence')" == '801 changed lines on agent/issue-901 exceed 800-line limit' \
  && "$(field issue-901 '.history[-1].decision.rejected[0]')" == 'Open PR for review without recutting' ]] || fail 'size admission did not record why the implementation must be recut'
[[ ! -s "$fixture/size-create.log" ]] || fail 'over-limit implementation still opened a PR for review'
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","lane":"pr","stage":"implement","history":[]}]}'
sa_impl 700 5000
harvest_pr_implement issue-901 "$sup/impl-901.md" || :
[[ "$(field issue-901 .stage)" == review-pending && "$(field issue-901 .pr)" == 4100 ]] || fail "lockfile lines were not excluded from the size count ($(field issue-901 .stage))"
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","lane":"pr","stage":"implement","history":[]}]}'
sa_git checkout -q -B agent/issue-901 origin/main
mkdir -p "$sa/src/packages/x/generated"
seq 1 801 > "$sa/src/packages/x/generated/api.ts"
sa_git add -A; sa_git commit -qm generated; sa_git push -q -f origin agent/issue-901
harvest_pr_implement issue-901 "$sup/impl-901.md" || :
[[ "$(field issue-901 .stage)" == review-pending ]] || fail "generated-only implementation was blocked by the size admission ($(field issue-901 .stage))"
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","lane":"pr","stage":"implement","history":[]}]}'
sa_git checkout -q -B agent/issue-901 origin/main
mkdir -p "$sa/src/docs"
seq 1 801 > "$sa/src/docs/guide.md"
sa_git add -A; sa_git commit -qm docs; sa_git push -q -f origin agent/issue-901
harvest_pr_implement issue-901 "$sup/impl-901.md" || :
[[ "$(field issue-901 .stage)" == review-pending ]] || fail "docs-only implementation was blocked by the size admission ($(field issue-901 .stage))"
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","lane":"pr","stage":"implement","history":[]}]}'
sa_git checkout -q -B agent/issue-901 origin/main
mkdir -p "$sa/src/.agents/skills/example"
seq 1 801 > "$sa/src/.agents/skills/example/SKILL.md"
sa_git add -A; sa_git commit -qm nested-docs; sa_git push -q -f origin agent/issue-901
harvest_pr_implement issue-901 "$sup/impl-901.md" || :
[[ "$(field issue-901 .stage)" == review-pending ]] || fail "nested Markdown-only implementation was blocked by the size admission ($(field issue-901 .stage))"
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","lane":"pr","stage":"implement","history":[]}]}'
sa_impl 800 0
harvest_pr_implement issue-901 "$sup/impl-901.md" || :
[[ "$(field issue-901 .stage)" == review-pending ]] || fail "exactly 800 changed lines must still open for review ($(field issue-901 .stage))"
[[ "$(wc -l < "$fixture/size-create.log")" == 5 ]] || fail "expected exactly five PRs opened across the admitted cases ($(cat "$fixture/size-create.log"))"
# #4482：尺寸准入在 repair 交付的新 head 上复查——开门时合规的 PR 会被修复轮养过线
#（如 #4396 从 611 变到 1090 准入行）；超线不开下一轮复检，转 supervisor 拆分。
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","pr":4100,"lane":"pr","stage":"repair","reviewed_sha":"'"$H1"'","history":[{"stage":"review-request-changes","at":"2026-10-19T10:00:00Z"}]}]}'
sa_impl 900 0
printf 'repaired\n' > "$sup/repair-901.md"
jq -n --arg dir "$WT_ROOT/wt-issue-901" '{workers:[{pid:4390,unit:"issue-901",type:"repair",log:"x.log",report:"repair-901.md",workdir:$dir}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field issue-901 '.history[-2].stage')" == repair-delivered ]] || fail "oversized repair was not delivered before the recheck ($(field issue-901 '.history[-2].stage'))"
[[ "$(field issue-901 .stage)" == supervisor-review ]] || fail "oversized repair head was not routed to the supervisor re-scope ($(field issue-901 .stage))"
[[ "$(field issue-901 '.history[-1].stage')" == supervisor-escalated && "$(field issue-901 .note)" == *"900 changed lines on agent/issue-901 after repair"* ]] \
  || fail "repair size escalation lacks the numbers ($(field issue-901 .note))"
[[ "$(field issue-901 '.history[-1].decision.decision')" == 'Request recut or split before review' ]] || fail 'repair size escalation did not record the recut decision'
units '{"units":[{"id":"issue-901","issue":901,"title":"big fix","branch":"agent/issue-901","pr":4100,"lane":"pr","stage":"repair","reviewed_sha":"'"$H1"'","history":[{"stage":"review-request-changes","at":"2026-10-19T10:00:00Z"}]}]}'
sa_impl 700 0
jq -n --arg dir "$WT_ROOT/wt-issue-901" '{workers:[{pid:4391,unit:"issue-901",type:"repair",log:"x.log",report:"repair-901.md",workdir:$dir}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field issue-901 .stage)" == rereview-pending ]] || fail "in-limit repair head was blocked by the size recheck ($(field issue-901 .stage))"
eval "$size_gh_saved"; WT_ROOT="$WT_ROOT_SAVED"


# revert_squash_merge is the single revert primitive (main-red recovery calls it): history-marker idempotency,
# conflict refusal and commit-not-on-main refusal, against a real bare origin.
(
  rv="$fixture/revert-prim"; rm -rf "$rv"; mkdir -p "$rv"
  command git init -q --bare -b main "$rv/origin.git"
  command git clone -q "$rv/origin.git" "$rv/seed" 2>/dev/null
  seed_git() { command git -C "$rv/seed" -c user.email=t@example.invalid -c user.name=t "$@"; }
  seed_git checkout -q -b main; echo one > "$rv/seed/f"; seed_git add f; seed_git commit -q -m base
  echo two > "$rv/seed/f"; seed_git commit -q -am 'squash change'; rv_bad="$(seed_git rev-parse HEAD)"
  seed_git push -q origin main
  seed_git checkout -q -b side "$rv_bad~1"; echo side > "$rv/seed/g"; seed_git add g; seed_git commit -q -m side; rv_off="$(seed_git rev-parse HEAD)"
  seed_git push -q origin side
  command git clone -q "$rv/origin.git" "$rv/root" 2>/dev/null
  ROOT="$rv/root"; WT_ROOT="$rv/wt"; LOG="$rv/say.log"; : > "$LOG"
  revert_squash_merge 1 "$rv_off" && fail 'a commit that is not on origin/main was reverted'
  grep -q 'refused: commit not on origin/main' "$LOG" || fail 'off-main revert refusal was not recorded'
  revert_squash_merge 1 "$rv_bad" || fail 'a clean squash commit was not reverted'
  [[ "$(command git -C "$rv/origin.git" log main -1 --format=%B | grep -c "This reverts commit $rv_bad")" == 1 ]] || fail 'revert did not land on origin/main with its history marker'
  head_after="$(command git -C "$rv/origin.git" rev-parse main)"
  revert_squash_merge 1 "$rv_bad" || fail 'a repeated revert was not treated as done'
  [[ "$(command git -C "$rv/origin.git" rev-parse main)" == "$head_after" ]] && grep -q 'already present' "$LOG" || fail 'a repeated revert pushed a second commit'
  # conflict: a later commit rewrites the same line, so the plain revert of the earlier change cannot apply
  seed_git checkout -q main; seed_git pull -q origin main 2>/dev/null; echo A > "$rv/seed/f"; seed_git commit -q -am 'change A'; rv_conf="$(seed_git rev-parse HEAD)"
  echo B > "$rv/seed/f"; seed_git commit -q -am 'change B'; seed_git push -q origin main
  conf_head="$(command git -C "$rv/origin.git" rev-parse main)"
  revert_squash_merge 2 "$rv_conf" && fail 'a conflicting revert reported success'
  grep -q 'merge revert conflict PR#2' "$LOG" && [[ "$(command git -C "$rv/origin.git" rev-parse main)" == "$conf_head" ]] || fail 'a conflicting revert was not refused cleanly'
)
echo 'scheduler-gates-git.test.sh: PASS'
