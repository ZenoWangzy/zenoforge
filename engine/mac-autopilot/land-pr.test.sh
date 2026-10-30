#!/usr/bin/env bash
# land-pr.sh：head 漂移/产品路径/落地成功/落地失败 四种结果都写成单行报告。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "land-pr.test.sh: $*" >&2; exit 1; }
f="$test_env_root/land"; mkdir -p "$f/bin"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
git init -q -b main "$f/src"
mkdir -p "$f/src/packages/example/src"
echo product > "$f/src/packages/example/src/a.ts"
git -C "$f/src" add .
git -C "$f/src" commit -q -m base
git -C "$f/src" checkout -q -b topic
mkdir -p "$f/src/engine"; echo change > "$f/src/engine/tool.sh"
git -C "$f/src" add . && git -C "$f/src" commit -q -m 'topic change'
pr_sha="$(git -C "$f/src" rev-parse HEAD)"
git -C "$f/src" checkout -q main
base_sha="$(git -C "$f/src" rev-parse HEAD)"
git clone -q --bare "$f/src" "$f/remote.git"
git -C "$f/remote.git" update-ref refs/pull/7/head "$pr_sha"
git clone -q "$f/remote.git" "$f/clone"

cat > "$f/policy.mjs" <<'JS'
import { readFileSync } from 'node:fs';
console.log(JSON.parse(process.argv[3] === '-' ? readFileSync(0, 'utf8') : process.argv[3]).every((p) => !p.startsWith('packages/')) ? 'eligible' : 'not-eligible');
JS
cat > "$f/lander.sh" <<'SH'
#!/usr/bin/env bash
echo started >> "$FAKE_LAND_CALLS"
[[ "${FAKE_LAND_FAIL:-0}" == 1 ]] && { echo 'land-direct-main: lock-released outcome=push-failed'; exit 1; }
[[ "${FAKE_LAND_HANG:-0}" == 1 ]] && read -r _ < "$FAKE_LAND_FIFO"  # 无写端：一直阻塞，模拟卡死的落地
git log -1 --format=%s > "$FAKE_LAND_SUBJECT"
if [[ -n "${FAKE_DRIFT_PR_HEAD:-}" ]]; then
  git --git-dir="$FAKE_REMOTE" update-ref refs/pull/7/head "$FAKE_DRIFT_PR_HEAD"
fi
SH
cat > "$f/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_GH_CALLS"
if [[ "$1 $2" == 'pr close' && "${FAKE_GH_CLOSE_FAIL:-0}" == 1 ]]; then exit 1; fi
if [[ "$1 $2" == 'pr close' && -n "${FAKE_DRIFT_ON_CLOSE:-}" ]]; then
  git --git-dir="$FAKE_REMOTE" update-ref refs/pull/7/head "$FAKE_DRIFT_ON_CLOSE"
fi
exit 0
SH
chmod +x "$f/lander.sh" "$f/bin/gh"
export LAND_PR_POLICY="$f/policy.mjs" LAND_PR_LANDER="$f/lander.sh" FAKE_LAND_SUBJECT="$f/subject"
export FAKE_REMOTE="$f/remote.git" FAKE_GH_CALLS="$f/gh.calls" FAKE_LAND_CALLS="$f/land.calls" PATH="$f/bin:$PATH"
: > "$f/land.calls"
run() { local approved="$1" reviewed="${2:-$1}"; bash "$script_dir/land-pr.sh" "$f/clone" 7 "$approved" 'tool tweak' "$f/report.md" "$reviewed"; head -1 "$f/report.md"; }

out="$(run 1111111111111111111111111111111111111111 "$pr_sha")"
[[ "$out" == "FAILED "* ]] || fail "unknown approved SHA not refused: $out"
before_lands="$(wc -l < "$f/land.calls")"
git --git-dir="$f/remote.git" update-ref refs/pull/7/head "$base_sha"
out="$(run "$pr_sha" "$pr_sha")"
[[ "$out" == "FAILED PR head moved since approval"* ]] || fail "PR rollback to an approved-SHA ancestor was accepted: $out"
[[ "$(wc -l < "$f/land.calls")" == "$before_lands" ]] || fail 'lander ran after the PR head rolled back before worker start'
git --git-dir="$f/remote.git" update-ref refs/pull/7/head "$pr_sha"
out="$(run "$pr_sha")"
[[ "$out" == "LANDED "* ]] || fail "eligible PR not landed: $out"
if git -C "$f/clone" show-ref --verify --quiet refs/remotes/origin/pr/7; then
  fail 'landing retained a PR remote-tracking ref'
fi
[[ "$(cat "$f/subject")" == '[skip ci] tool tweak (#7)' ]] || fail "squash subject wrong: $(cat "$f/subject")"
grep -Fq 'gh pr close 7' "$f/gh.calls" || fail 'PR not closed after landing'
[[ "$(git -C "$f/clone" diff --name-only origin/main HEAD)" == engine/tool.sh ]] || fail 'squash commit content wrong'
out="$(FAKE_LAND_FAIL=1 run "$pr_sha")"
[[ "$out" == "FAILED land-direct-main:"*"push-failed"* ]] || fail "lander failure not reported: $out"
mkfifo "$f/never.fifo"
out="$(FAKE_LAND_HANG=1 FAKE_LAND_FIFO="$f/never.fifo" LAND_PR_TIMEOUT_SECONDS=1 run "$pr_sha")"
[[ "$out" == "FAILED land-direct-main timed out"* ]] || fail "wedged lander not timed out: $out"
# A PR commit arriving while focused landing runs must leave the PR open for a fresh review.
git -C "$f/src" checkout -q -B drift-fixture "$pr_sha"
echo drift >> "$f/src/engine/tool.sh"
git -C "$f/src" commit -qam 'unapproved follow-up'
drift_sha="$(git -C "$f/src" rev-parse HEAD)"
git -C "$f/src" push -q "$f/remote.git" "$drift_sha:refs/heads/drift-fixture"
: > "$FAKE_GH_CALLS"
out="$(FAKE_DRIFT_PR_HEAD="$drift_sha" run "$pr_sha")"
[[ "$out" == "LANDED-HEAD-MOVED "* ]] || fail "head drift during landing not reported: $out"
! grep -Fq 'gh pr close 7' "$f/gh.calls" || fail 'PR was closed after an unapproved commit arrived during landing'
git --git-dir="$f/remote.git" update-ref refs/pull/7/head "$pr_sha"
# If a commit arrives in the narrow close race, the lander reopens the PR for review.
: > "$FAKE_GH_CALLS"
out="$(FAKE_DRIFT_ON_CLOSE="$drift_sha" run "$pr_sha")"
[[ "$out" == "LANDED-HEAD-MOVED "* ]] || fail "head drift during close not reported: $out"
grep -Fq 'gh pr reopen 7' "$f/gh.calls" || fail 'PR was not reopened after a close-race head update'
git --git-dir="$f/remote.git" update-ref refs/pull/7/head "$pr_sha"
# A failed close is a distinct post-land failure, not a successful terminal result.
out="$(FAKE_GH_CLOSE_FAIL=1 run "$pr_sha")"
[[ "$out" == "FAILED POST-LAND PR CLOSE "* ]] || fail "PR close failure not reported: $out"
# 本 clone 里基于 PR head 的本地修复提交（推不上 PR 分支）也能落地
git -C "$f/clone" fetch -q origin "refs/pull/7/head"
git -C "$f/clone" checkout -q -B topic "$pr_sha" && echo fix >> "$f/clone/engine/tool.sh"
git -C "$f/clone" commit -qam 'local repair'
local_sha="$(git -C "$f/clone" rev-parse HEAD)"
out="$(run "$local_sha" "$pr_sha")"
[[ "$out" == "LANDED "* ]] || fail "local repair commit not landed: $out"
# A rename from a product path to an allowed path still classifies both names.
git -C "$f/src" checkout -q -B rename-fixture "$pr_sha"
git -C "$f/src" mv packages/example/src/a.ts engine/renamed.ts
git -C "$f/src" commit -q -m 'rename product file out of product tree'
rename_sha="$(git -C "$f/src" rev-parse HEAD)"
git -C "$f/src" push -q "$f/remote.git" "$rename_sha:refs/heads/rename-fixture"
git --git-dir="$f/remote.git" update-ref refs/pull/7/head "$rename_sha"
out="$(run "$rename_sha")"
[[ "$out" == "FAILED not eligible"* ]] || fail "product-to-nonproduct rename bypassed lane policy: $out"
git --git-dir="$f/remote.git" update-ref refs/pull/7/head "$pr_sha"
# 无 PR 的直落单元：本地分支提交直接落地，主题引用 issue，不碰 PR
git -C "$f/clone" checkout -q -B agent/auto-issue-9 origin/main && mkdir -p "$f/clone/engine" && echo issue > "$f/clone/engine/issue.sh"
git -C "$f/clone" add -A && git -C "$f/clone" commit -qm 'issue fix'
issue_sha="$(git -C "$f/clone" rev-parse HEAD)"; issue_base="$(git -C "$f/clone" merge-base origin/main HEAD)"
: > "$FAKE_GH_CALLS"
bash "$script_dir/land-pr.sh" "$f/clone" '' "$issue_sha" 'issue tweak' "$f/report.md" "$issue_base" 9
[[ "$(head -1 "$f/report.md")" == "LANDED "* ]] || fail "PR-less unit not landed: $(cat "$f/report.md")"
[[ "$(cat "$f/subject")" == '[skip ci] issue tweak (#9)' ]] || fail "PR-less subject wrong: $(cat "$f/subject")"
[[ ! -s "$FAKE_GH_CALLS" ]] || fail "PR-less landing touched a PR: $(cat "$FAKE_GH_CALLS")"
printf 'console.log("not-eligible")\n' > "$f/policy.mjs"
[[ "$(run "$pr_sha")" == "FAILED not eligible"* ]] || fail 'product PR not refused'
echo 'land-pr.test.sh: PASS'
