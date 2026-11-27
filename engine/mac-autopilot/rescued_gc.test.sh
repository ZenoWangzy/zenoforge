#!/usr/bin/env bash
# rescued_gc.sh: archives each stale head under a unique ref, reads it back, then deletes it; a collision or a rejected archive push cannot fail the batch and a failed batch raises an alert.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
systemd_dir="$script_dir/../systemd"
fail() { echo "rescued_gc.test.sh: $*" >&2; exit 1; }
f="$test_env_root/rescued"; mkdir -p "$f/bin"
bot=7+bot@users.noreply.github.com
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=$bot GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=$bot
git init -q --bare "$f/origin.git"
git clone -q "$f/origin.git" "$f/repo" 2>/dev/null
old=1700000000 now=1800000000
mk() {
  git -C "$f/repo" checkout -q --orphan "$1"
  echo "$1" > "$f/repo/f"; git -C "$f/repo" add f
  GIT_COMMITTER_DATE="@$2" GIT_AUTHOR_DATE="@$2" GIT_AUTHOR_EMAIL="${3:-$bot}" GIT_COMMITTER_EMAIL="${3:-$bot}" git -C "$f/repo" commit -q -m "$1"
  git -C "$f/repo" push -q origin "$1"
}
sha() { git -C "$f/repo" rev-parse "refs/heads/$1"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
mk main $old
for b in rescued/issue-10-x rescued/issue-20-y rescued/advisor-old rescued/tree rescued/reject-me backup/pre-cleanup-1 salvage/s1 train/t1 backup/open-pr feat/merged feat/fresh-closed feat/moved feat/no-pr; do mk "$b" $old; done
mk rescued/advisor-new $((now - 3600))
mk backup/foreign $old other@example.invalid
jq -n --arg merged "$(sha feat/merged)" --arg fresh "$(sha feat/fresh-closed)" --arg open "$(sha backup/open-pr)" --arg old "$(iso $old)" --arg recent "$(iso $((now - 86400)))" '[
  {headRefName:"feat/merged",headRefOid:$merged,baseRefName:"main",state:"MERGED",closedAt:$old,isCrossRepository:false},
  {headRefName:"feat/fresh-closed",headRefOid:$fresh,baseRefName:"main",state:"CLOSED",closedAt:$recent,isCrossRepository:false},
  {headRefName:"feat/moved",headRefOid:"0000000000000000000000000000000000000000",baseRefName:"main",state:"CLOSED",closedAt:$old,isCrossRepository:false},
  {headRefName:"backup/open-pr",headRefOid:$open,baseRefName:"main",state:"OPEN",closedAt:null,isCrossRepository:false}]' > "$f/prs.json"
cat > "$f/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "${GH_FAIL:-0}" == 1 ]] && exit 1
case "$1 $2" in
  "repo view") printf 'owner/repo\tmain\n' ;;
  "api user") echo '7 bot' ;;
  "api graphql") echo i10 ;;
  "pr list") cat "$PRS_JSON" ;;
esac
EOF
chmod +x "$f/bin/gh"
heads() { git -C "$f/origin.git" for-each-ref --format='%(refname:short)' refs/heads/ | sort | tr '\n' ' '; }
want() { printf '%s\n' "$@" | sort | tr '\n' ' '; }
run_gc() { PATH="$f/bin:$PATH" PRS_JSON="$f/prs.json" NOW_EPOCH=$now bash "$script_dir/rescued_gc.sh" "$f/repo" "$f/gc.log" 2>&1; }
all_heads="$(heads)"
alerts="$f/alerts/branch-gc.md"

rc=0; GH_FAIL=1 run_gc >/dev/null || rc=$?
[[ $rc == 1 ]] || fail "GitHub lookup failure must exit 1, got $rc"
[[ "$(heads)" == "$all_heads" ]] || fail "deleted without GitHub state: $(heads)"
grep -q 'BRANCH-GC-FAILED' "$alerts" || fail 'GitHub lookup failure raised no alert'
: > "$alerts"

git -C "$f/repo" push -q origin "$(sha main)":refs/vecta-rescue/archived/tree
tree_ref="refs/vecta-rescue/archived/rescued/tree-$(sha rescued/tree | cut -c1-12)"
cleanup_ref="refs/vecta-rescue/archived/backup/pre-cleanup-1-$(sha backup/pre-cleanup-1 | cut -c1-12)"
git -C "$f/repo" push -q origin "$(sha main)":"$cleanup_ref"
printf '#!/bin/sh\ncase "$1" in refs/vecta-rescue/*reject-me*) echo declined >&2; exit 1;; esac\n' > "$f/origin.git/hooks/update"
chmod +x "$f/origin.git/hooks/update"
tips="$(sha rescued/tree) $(sha backup/pre-cleanup-1)"

rc=0; out="$(run_gc)" || rc=$?
[[ $rc == 1 ]] || fail "rejected archive push must exit 1, got $rc: $out"
survivors=(main rescued/advisor-new rescued/issue-20-y rescued/reject-me backup/foreign backup/open-pr feat/fresh-closed feat/moved feat/no-pr)
[[ "$(heads)" == "$(want "${survivors[@]}")" ]] || fail "wrong survivors after rejected archive: $(heads)"
[[ "$out" == *'deleted 7 of 8'* ]] || fail "summary wrong: $out"
grep -q 'BRANCH-GC-FAILED.*rescued/reject-me' "$alerts" || fail 'rejected archive push raised no alert naming the branch'
[[ "$(git -C "$f/origin.git" rev-parse "$tree_ref")" == "$(echo $tips | cut -d' ' -f1)" ]] || fail 'collision: unique archive ref does not hold the branch tip'
[[ "$(git -C "$f/origin.git" rev-parse "$cleanup_ref")" == "$(echo $tips | cut -d' ' -f2)" ]] || fail 'stale unique archive ref was not forced to the branch tip'
[[ "$(git -C "$f/origin.git" rev-parse refs/vecta-rescue/archived/tree)" == "$(sha main)" ]] || fail 'older archive ref was touched'
grep -q "deleted rescued/issue-10-x .* reason=closed-issue-10" "$f/gc.log" || fail 'closed-issue deletion not logged'
grep -q "deleted rescued/advisor-old .* reason=rescued-older-14d" "$f/gc.log" || fail 'aged rescued deletion not logged'
grep -q "deleted feat/merged .* reason=pr-closed-older-7d" "$f/gc.log" || fail 'closed PR head deletion not logged'
grep -q "deleted rescued/tree .* archive=$tree_ref" "$f/gc.log" || fail 'archive ref not logged'
for b in backup/pre-cleanup-1 salvage/s1 train/t1; do grep -q "deleted $b " "$f/gc.log" || fail "$b not collected"; done

rm "$f/origin.git/hooks/update"
alert_lines="$(wc -l < "$alerts")"
out="$(run_gc)" || fail "clean rerun failed: $out"
[[ "$(heads)" == "$(want main rescued/advisor-new rescued/issue-20-y backup/foreign backup/open-pr feat/fresh-closed feat/moved feat/no-pr)" ]] || fail "rerun survivors wrong: $(heads)"
[[ "$(wc -l < "$alerts")" == "$alert_lines" ]] || fail 'clean rerun raised an alert'
git -C "$f/origin.git" rev-parse -q --verify "refs/vecta-rescue/archived/rescued/reject-me-$(sha rescued/reject-me | cut -c1-12)" >/dev/null || fail 'rerun did not archive the previously rejected branch'

timer="$systemd_dir/zenoforge-branch-gc.timer"
service="$systemd_dir/zenoforge-branch-gc.service"
grep -Eq '^OnCalendar=' "$timer" || fail 'branch collector has no timer schedule'
grep -Eq '^ExecStart=.*mac-autopilot/rescued_gc\.sh' "$service" || fail 'branch collector service does not run rescued_gc.sh'
grep -Fxq 'zenoforge-branch-gc.timer - timer-alerted-zenoforge-branch-gc.timer' "$systemd_dir/pipeline-timers.list" || fail 'branch collector timer is not tracked by run-tick'
! grep -q 'rescued_gc' "$script_dir/scheduler.d/cleanup.sh" || fail 'scheduler cleanup still runs the branch collector'
echo 'rescued_gc.test.sh: PASS'
