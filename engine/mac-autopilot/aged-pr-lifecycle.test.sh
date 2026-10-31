#!/usr/bin/env bash
# 旧 PR 生命周期三分类（#4360）：三类 fixture PR 各自得到正确动作；新 ticket 带原 PR 链接与意图摘要。
# 真 git fixture（patch-id/删除/冲突/干净合并都要真实对象），gh 打桩记录对外动作。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/aged-pr"; sup="$fixture/supervisor"
origin="$fixture/origin.git"; root="$fixture/repo"
mkdir -p "$sup/autopi/alerts" "$fixture/db"
cp "$script_dir/config.template.json" "$sup/autopi/config.json"
cat > "$sup/autopi/units.json" <<'JSON'
{"units":[
  {"id":"pr-103","stage":"review-pending","pr":103,"branch":"agent/issue-903"},
  {"id":"pr-199","stage":"review-pending","pr":199,"branch":"fix/legacy"},
  {"id":"pr-107","stage":"ready-to-merge","pr":107,"branch":"agent/issue-903","history":[{"stage":"rereview","at":"NOW_ISO"}]}
]}
JSON
sed -i "s/NOW_ISO/$(date -u +%FT%TZ)/" "$sup/autopi/units.json"
printf '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$root" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup"
export CODEX_SESSIONS_DIR="$fixture/sessions" AUTOPI_TEST_LIBRARY_ONLY=true
export REQUIRED_PR_CHECKS_FILE="$test_env_root/required-pr-checks.json"
printf '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"

# ---- 真 git fixture：origin 裸库 + 工作克隆，分支按场景铺 ----------------------------------
git() { command git -c user.name=t -c user.email=t@example.invalid "$@"; }
git init -q --bare -b main "$origin"
git clone -q "$origin" "$root"
cd "$root"
git commit -q --allow-empty -m base
echo base-a > a; echo base-b > b; printf 'l1\nl2\n' > c
git add .; git commit -qm "base files"
# 已过时（删除）：902 改 b，main 删 b
git checkout -q -b agent/issue-902; echo changed-b > b; git commit -qam "edit b"
git checkout -q main; git rm -q b; git commit -qm "drop b"
# 仍需要（冲突）：906 改 c 第一行，main 把同一行改成别的——冲突只说明 main 动了，不说明意图过时
git checkout -q -b agent/issue-906; printf 'theirs\nl2\n' > c; git commit -qam "edit c ours"
git checkout -q main; printf 'rewritten\nl2\n' > c; git commit -qam "edit c theirs"
# 仍需要（issue 在）：903 加新文件，干净合并
git checkout -q -b agent/issue-903; echo new-file > d; git add d; git commit -qm "add d"
git checkout -q main
# 已在 main（patch-id）：901 改 a，main cherry-pick 同一补丁（先垫一个无关提交，避免 parent 相同产生同 SHA）
git checkout -q -b agent/issue-901; echo landed-a > a; git commit -qam "edit a"
git checkout -q main; git commit -q --allow-empty -m unrelated; git cherry-pick agent/issue-901
# 仍需要（无 issue，hand 分支，靠落后数触发）：main 再进 301 个提交
git checkout -q -b hand/1234; echo hand-file > e; git add e; git commit -qm "add e"
git checkout -q main
for i in $(seq 301); do git commit -q --allow-empty -m "advance $i"; done
git push -q origin main agent/issue-901 agent/issue-902 agent/issue-903 agent/issue-906 hand/1234
git fetch -q origin
head_901="$(git rev-parse agent/issue-901)"; head_902="$(git rev-parse agent/issue-902)"
head_903="$(git rev-parse agent/issue-903)"; head_906="$(git rev-parse agent/issue-906)"
head_1234="$(git rev-parse hand/1234)"
cd - >/dev/null

# ---- gh 打桩：fixture 库 + 动作日志 ----------------------------------------------------------------------------
DB="$fixture/db"; ACTIONS="$DB/actions.log"; NEXT="$DB/next-issue"
iso_days_ago() { date -u -d "@$(( $(date -u +%s) - $1 * 86400 ))" +%Y-%m-%dT%H:%M:%SZ; }
mk_pr() { # number branch head days-ago base title body
  jq -cn --argjson n "$1" --arg b "$2" --arg h "$3" --arg c "$(iso_days_ago "$4")" \
    --arg base "${5:-main}" --arg t "$6" --arg body "$7" \
    '{number:$n,headRefName:$b,headRefOid:$h,createdAt:$c,baseRefName:$base,state:"OPEN",title:$t,body:$body}'
}
mk_issue() { jq -cn --argjson n "$1" --arg s "$2" --arg t "$3" --arg b "$4" '{number:$n,state:$s,title:$t,body:$b}'; }
cat > "$DB/prs.json" <<JSON
[$(mk_pr 105 agent/issue-905 "$head_901" 9 main "fix(#905): stale" "pr body 105"),
$(mk_pr 199 fix/legacy "$head_901" 9 main "human branch" ""),
$(mk_pr 198 agent/issue-907 "$head_901" 9 develop "stack pilot" ""),
$(mk_pr 101 agent/issue-901 "$head_901" 8 main "fix(#901): landed" ""),
$(mk_pr 102 agent/issue-902 "$head_902" 8 main "fix(#902): target deleted" ""),
$(mk_pr 106 agent/issue-906 "$head_906" 8 main "fix(#906): conflict" ""),
$(mk_pr 103 agent/issue-903 "$head_903" 8 main "fix(#903): still needed" ""),
$(mk_pr 104 hand/1234 "$head_1234" 1 main "hand lane change" "hand pr body 104"),
$(mk_pr 107 agent/issue-903 "$head_903" 9 main "fix(#903): approved, in the merge lane" "")]
JSON
cat > "$DB/issues.json" <<JSON
[$(mk_issue 901 OPEN "让 a 更好" "issue 901 body"),
$(mk_issue 902 OPEN "改 b" "issue 902 body"),
$(mk_issue 906 OPEN "改 c" "issue 906 body"),
$(mk_issue 903 OPEN "让导入每行有交代" "导入的每一行都要有下落，失败要说明原因。"),
$(mk_issue 905 CLOSED "已完成的票" "done")]
JSON
echo 9000 > "$NEXT"; : > "$ACTIONS"

source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
A="$MAC_AUTOPILOT_RUNTIME_DIR"
# The stub must load after the scheduler: core.sh's own gh() wrapper (call counting
# around `command gh`) would otherwise shadow it and every census would hit real gh.
gh() {
  local n c num t b
  case "$1 $2" in
    'pr list')
      jq -c 'map(select(.state == "OPEN"))' "$DB/prs.json" ;;
    'pr close')
      n="$3"; c=""
      [[ "$4" == --comment ]] && c="$5"
      printf 'pr-close\t%s\t%s\n' "$n" "${c//$'\n'/ }" >> "$ACTIONS"
      jq --argjson n "$n" 'map(if .number == $n then .state = "CLOSED" else . end)' "$DB/prs.json" > "$DB/prs.json.tmp"
      mv "$DB/prs.json.tmp" "$DB/prs.json" ;;
    'pr view')
      jq -c --argjson n "$3" 'map(select(.number == $n)) | first | {title, body}' "$DB/prs.json" ;;
    'issue view')
      jq -c --argjson n "$3" 'map(select(.number == $n)) | first' "$DB/issues.json" ;;
    'issue create')
      num="$(( $(cat "$NEXT") + 1 ))"; echo "$num" > "$NEXT"
      t=""; b=""
      [[ "$3" == --title ]] && t="$4"; [[ "$5" == --body ]] && b="$6"
      printf 'issue-create\t%s\t%s\t%s\n' "$num" "$t" "${b//$'\n'/ }" >> "$ACTIONS"
      printf 'https://github.com/example-maintainer/example-repo/issues/%s\n' "$num" ;;
    'issue close')
      n="$3"; c=""
      [[ "$4" == --comment ]] && c="$5"
      printf 'issue-close\t%s\t%s\n' "$n" "${c//$'\n'/ }" >> "$ACTIONS"
      jq --argjson n "$n" 'map(if .number == $n then .state = "CLOSED" else . end)' "$DB/issues.json" > "$DB/issues.json.tmp"
      mv "$DB/issues.json.tmp" "$DB/issues.json" ;;
    *)
      printf 'unexpected-gh\t%s\n' "$*" >> "$ACTIONS"; return 1 ;;
  esac
}

fail() { echo "aged-pr-lifecycle.test.sh: $*" >&2; exit 1; }
actions_of() { grep -F "$(printf '%s\t' "$1")" "$ACTIONS" || true; }

# 首轮：AGED_PR_MAX=1 → 只处理最老的超龄 PR（105），其余顺延。
AGED_PR_MAX=1 aged_pr_lifecycle
[[ "$(actions_of pr-close | wc -l)" == 1 ]] || fail "cap=1 should close exactly one PR, got: $(actions_of pr-close | wc -l)"
actions_of pr-close | grep -q $'^pr-close\t105\t' || fail "cap=1 should pick the oldest qualifying PR (105)"
grep -q '原 ticket #905 已关闭' <(actions_of pr-close) || fail "closed-issue PR should cite the closed ticket"
[[ "$(grep -c . "$A/aged-prs.count")" == 1 ]]
grep -q 'classified=1 deferred=5' "$A/aged-prs.count" || fail "cap accounting: $(cat "$A/aged-prs.count")"

# 间隔门：epoch 未过期时不再产生任何动作。
before="$(wc -l < "$ACTIONS")"
aged_pr_lifecycle
[[ "$(wc -l < "$ACTIONS")" == "$before" ]] || fail "interval gate admitted a second run in the same epoch"

# 次轮：放满额度，清空其余积压。
rm -f "$A/aged-pr-check.epoch"
AGED_PR_MAX=10 aged_pr_lifecycle
grep -q 'classified=5 deferred=0' "$A/aged-prs.count" || fail "second run accounting: $(cat "$A/aged-prs.count")"

# 三类各自得到正确的动作
grep -q $'^pr-close\t101\t.*分类：已在 main' "$ACTIONS" || fail "PR 101 (patch-id landed) not closed as 已在 main"
grep -q 'patch-id 全部与 main 等价' <(actions_of pr-close) || fail "PR 101 reason should cite patch-id equivalence"
grep -q $'^pr-close\t102\t.*分类：已过时' "$ACTIONS" || fail "PR 102 (target deleted) not closed as 已过时"
grep -q '已全部删除' <(actions_of pr-close) || fail "PR 102 reason should cite deleted files"
grep -q $'^pr-close\t106\t.*分类：仍需要' "$ACTIONS" || fail "PR 106 (conflict with rewritten main) not closed as 仍需要"
grep -q $'^pr-close\t106\t.*重开为 #9001' "$ACTIONS" || fail "PR 106 close should point at its reopened ticket"
grep -q $'^pr-close\t103\t.*分类：仍需要' "$ACTIONS" || fail "PR 103 (still needed) not closed as 仍需要"
grep -q $'^pr-close\t104\t.*分类：仍需要' "$ACTIONS" || fail "PR 104 (hand lane, behind>300) not closed as 仍需要"

# 人手分支与非 main base 的 PR 不动
! grep -q $'^pr-close\t199\t' <(actions_of pr-close) || fail "human-branch PR 199 must stay untouched"
! grep -q $'^pr-close\t198\t' <(actions_of pr-close) || fail "non-main-base PR 198 must stay untouched"
! grep -q $'^pr-close\t107\t' <(actions_of pr-close) || fail "PR 107 held by a recently active ledger unit must stay untouched"

# 新 ticket 带上原 PR 链接和原意图摘要
create_106="$(grep -F $'issue-create\t9001\t' "$ACTIONS")"
[[ "$create_106" == *"重做（旧 PR #106）：改 c"* ]] || fail "conflict PR's new ticket title should carry the original intent: $create_106"
[[ "$create_106" == *"#106"* && "$create_106" == *"agent/issue-906"* ]] || fail "conflict PR's new ticket body should link the original PR"
[[ "$create_106" == *"issue 906 body"* ]] || fail "conflict PR's new ticket body should carry the intent summary"
grep -q $'^issue-close\t906\t.*#9001' "$ACTIONS" || fail "open original ticket 906 should be superseded by the new ticket"
create_103="$(grep -F $'issue-create\t9002\t' "$ACTIONS")"
[[ "$create_103" == *"重做（旧 PR #103）：让导入每行有交代"* ]] || fail "new ticket title should carry the original intent: $create_103"
[[ "$create_103" == *"#103"* && "$create_103" == *"agent/issue-903"* ]] || fail "new ticket body should link the original PR"
[[ "$create_103" == *"#903"* ]] || fail "new ticket body should link the original ticket"
[[ "$create_103" == *"导入的每一行都要有下落"* ]] || fail "new ticket body should carry the intent summary"
grep -q $'^issue-close\t903\t.*#9002' "$ACTIONS" || fail "open original ticket 903 should be superseded by the new ticket"
create_104="$(grep -F $'issue-create\t9003\t' "$ACTIONS")"
[[ "$create_104" == *"#104"* && "$create_104" == *"hand/1234"* ]] || fail "no-issue new ticket should link the original PR"
[[ "$create_104" == *"hand pr body 104"* ]] || fail "no-issue new ticket should carry the PR body as intent summary"

# 仍需要路径必须先开新票再关旧 PR（创建失败时旧 PR 留着，下一轮重试）
grep -n $'issue-create\t9001\t' "$ACTIONS" | cut -d: -f1 | head -1 > "$fixture/create_line"
grep -n $'^pr-close\t106\t' "$ACTIONS" | cut -d: -f1 | head -1 > "$fixture/close_line"
(( $(cat "$fixture/create_line") < $(cat "$fixture/close_line") )) || fail "conflict PR's new ticket must be created before PR 106 closes"
grep -n $'issue-create\t9002\t' "$ACTIONS" | cut -d: -f1 | head -1 > "$fixture/create_line"
grep -n $'^pr-close\t103\t' "$ACTIONS" | cut -d: -f1 | head -1 > "$fixture/close_line"
(( $(cat "$fixture/create_line") < $(cat "$fixture/close_line") )) || fail "new ticket must be created before the old PR closes"

# 台账单元随 PR 关闭
jq -e '.units[] | select(.id == "pr-103") | .stage == "closed" and ((.history // []) | any(.stage == "aged-triage"))' \
  "$UNITS" >/dev/null || fail "ledger unit pr-103 should close with aged-triage history"
jq -e '.units[] | select(.id == "pr-199") | .stage == "review-pending"' "$UNITS" >/dev/null || fail "untouched PR's unit must stay as-is"

# 未预期到的 gh 调用不该出现
! grep -q 'unexpected-gh' "$ACTIONS" || fail "unexpected gh calls: $(grep unexpected-gh "$ACTIONS")"

echo "aged-pr-lifecycle.test.sh: all assertions passed"
