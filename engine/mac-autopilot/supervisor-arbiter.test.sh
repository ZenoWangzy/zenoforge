#!/usr/bin/env bash
# #4369 supervisor 裁决回归：supervisor-review 的派发/回收/六动作落地、两轮上限、第 3 次升级转 parked。
# 断言对外的动作（worker 派发、状态迁移、gh 评论/标签/关 PR、决策记录），不测 prompt 文案本身。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/sup-arbiter"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo" "$fixture/bin"
# Stage-transition fixtures are already roadmap leaves; this suite covers arbitration effects.
export ZF_ROADMAP_TREE_CACHE_FILE="$fixture/roadmap-tree.json"
jq -cn '{roots:[618,622,623] | map({number:.,title:("fixture issue " + tostring),state:"open",labels:[],children:[]})}' \
  > "$ZF_ROADMAP_TREE_CACHE_FILE"
jq '.auto_merge = false | .advisor = false | .precheck = false | .supervisor_arbiter.enabled = true' "$script_dir/config.template.json" > "$sup/autopi/config.json"
echo '{"units":[]}' > "$sup/autopi/units.json"
echo '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export CODEX_SESSIONS_DIR="$fixture/sessions"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
decision_eval_stages() { printf '\n'; }

fail() { echo "supervisor-arbiter.test.sh: $*" >&2; exit 1; }
units() { printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }

GH_CALLS="$fixture/gh.calls"; : > "$GH_CALLS"
gh() {
  printf 'gh %s\n' "$*" >> "$GH_CALLS"
  case "$1 $2" in
    'issue view')
      [[ "$*" == *'--json labels -q .labels[].name'* ]] || {
        echo "supervisor-arbiter.test.sh: unexpected gh call: $*" >&2
        return 97
      }
      return 0
      ;;
    'issue comment') return 0 ;;
    'issue edit') return 0 ;;
    'label list') printf '%s\n' needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded ;;
    'label create') return 0 ;;
    'pr comment') return 0 ;;
    'pr close') return 0 ;;
    'pr view') case "$*" in *headRefName*) echo fix/token-fixture ;; esac; return 0 ;;
    *) echo "supervisor-arbiter.test.sh: unexpected gh call: $*" >&2; return 97 ;;
  esac
}
export -f gh 2>/dev/null || true

# codex 桩：记录调用，把预设裁决报告写到 --output-last-message。
ARBITRATION_REPLY="$fixture/arbitration-reply.md"
codex_fake() {
  printf 'codex %s\n' "$*" >> "$fixture/codex.calls"
  local out="" prev=""
  local a
  for a in "$@"; do [[ "$prev" == --output-last-message ]] && out="$a"; prev="$a"; done
  [[ -n "$out" && -f "$ARBITRATION_REPLY" ]] || return 0
  cat "$ARBITRATION_REPLY" > "$out"
}
export ARBITRATION_REPLY
export -f codex_fake
printf '#!/usr/bin/env bash\ncodex_fake "$@"\n' > "$fixture/bin/codex"
chmod +x "$fixture/bin/codex"
export PATH="$fixture/bin:$PATH"

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
SHA3=3333333333333333333333333333333333333333
mkdir -p "$fixture/repo/engine/prompts"
cp "$script_dir/../prompts/supervisor-arbiter.md" "$fixture/repo/engine/prompts/supervisor-arbiter.md"

# ---- 派发：gate 开时第 1 次升级派一个 terra 裁决 worker，冻结记录进 prompt ----
units "$(jq -cn --argjson sha "$SHA1" '{units:[{id:"pr-601",issue:601,pr:601,lane:"pr",branch:"agent/issue-601",stage:"supervisor-review",
  note:"review report has no single VERDICT line",review_report:"review-601.md",reviewed_sha:$sha,reviewed_pr_head:$sha,
  history:[{stage:"review-request-changes",result:"F1",at:"2026-10-27T00:00:00Z"},{stage:"supervisor-escalated",result:"review report has no single VERDICT line",at:"2026-10-27T00:01:00Z"}]}]}')"
printf 'VERDICT: REQUEST-CHANGES\nF1 缺回归测试\n' > "$sup/review-601.md"
: > "$fixture/codex.calls"
dispatch_supervisor_arbiters
[[ "$(jq -r '[.workers[] | select(.type=="supervise")] | length' "$WORKERS")" == 1 ]] || fail "gate on: no supervise worker dispatched"
jq -e --arg unit pr-601 'any(.workers[]; .unit == $unit and .type == "supervise" and (.model == "profile:terra"))' "$WORKERS" >/dev/null || fail "supervise worker model must record the terra profile"
[[ "$(field pr-601 .stage)" == supervisor-review ]] || fail "dispatch must leave the unit in supervisor-review while arbitrating"
[[ "$(field pr-601 '.history[-1].stage')" == supervisor-arbiter ]] || fail "dispatch must consume one arbitration budget slot in history"
q_file="$(ls -t "$sup"/supervise-pr-601-*.q.md | head -1)"
grep -q 'six actions' "$q_file" || fail "arbitration prompt must carry the six-action prompt"
frozen="$(sed -n '/^```json$/,/^```$/p' "$q_file" | sed '1d;$d' | grep -v '^#')"
[[ "$(jq -r '.unitId' <<<"$frozen")" == pr-601 ]] || fail "arbitration prompt must embed the unit id in the frozen record"
jq -e '.escalationReason.reason == "review report has no single VERDICT line" and (.unitHistory | length == 2) and .reviewFindings.available == true and (.ciEvidence | type == "array")' <<<"$frozen" >/dev/null \
  || fail "arbitration prompt must embed the frozen record (escalation/history/findings/ci)"
# 在途上限：pr-601 在裁，上限 2 时只再派一个，且不给在裁单元重复派。
printf '%s\n' "$(jq -cn '{units:[{id:"pr-601",stage:"supervisor-review",history:[{stage:"supervisor-arbiter",result:"x",at:"2026-10-27T00:00:00Z"}]},
  {id:"pr-602",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"x",at:"2026-10-27T00:00:00Z"}]},
  {id:"pr-603",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"y",at:"2026-10-27T00:00:00Z"}]}]}')" > "$UNITS"
before="$(jq '[.workers[] | select(.type=="supervise")] | length' "$WORKERS")"
saved_max="$SUPERVISOR_ARBITER_MAX"; SUPERVISOR_ARBITER_MAX=2
dispatch_supervisor_arbiters
[[ "$(jq '[.workers[] | select(.type=="supervise")] | length' "$WORKERS")" == "$((before + 1))" ]] || fail "arbitration must fill up to the in-flight cap"
jq -e '[.workers[] | select(.type=="supervise" and .unit=="pr-601")] | length == 1' "$WORKERS" >/dev/null || fail "a unit already under arbitration must not get a second worker"
jq -e 'any(.workers[]; .type=="supervise" and .unit=="pr-602")' "$WORKERS" >/dev/null || fail "the next unit in order must be dispatched"
before="$(jq '[.workers[] | select(.type=="supervise")] | length' "$WORKERS")"
dispatch_supervisor_arbiters
[[ "$(jq '[.workers[] | select(.type=="supervise")] | length' "$WORKERS")" == "$before" ]] || fail "no arbitration may dispatch at the in-flight cap"
SUPERVISOR_ARBITER_MAX="$saved_max"

# ---- 回收：六个动作逐个断言对外效果 ----
harvest_with_reply() { # unit report-body → 用一个已死 worker 回收
  local unit="$1" reply="$2"
  local report="supervise-$unit-reply.md"
  printf '%s\n' "$reply" > "$sup/$report"
  harvest_supervisor_arbiter "$(jq -cn --arg unit "$unit" --arg report "$report" --arg log "supervise-$unit.worker.log" \
    '{pid:99999999,unit:$unit,type:"supervise",log:$log,report:$report,started:"2026-10-27T00:00:00Z",model:"profile:terra"}')"
}

units "$(jq -cn --argjson sha "$SHA1" '{units:[{id:"pr-611",issue:611,pr:611,lane:"pr",branch:"agent/issue-611",stage:"supervisor-review",
  history:[{stage:"review-request-changes",result:"F1",at:"2026-10-27T00:00:00Z"},{stage:"supervisor-escalated",result:"no VERDICT",at:"2026-10-27T00:01:00Z"}]}]}')"
harvest_with_reply pr-611 'ACTION: requeue
REASON: 评审报告缺结论行，可重跑
EVIDENCE: supervisor-escalated no VERDICT
REJECTED: close（产出仍需要）；approve（无已评审 head）
GUIDANCE: 先 git merge origin/main 再按类别修复'
[[ "$(field pr-611 .stage)" == repair-pending ]] || fail "requeue must return the unit to repair-pending"
[[ "$(field pr-611 .repair_hint)" == *'git merge origin/main'* ]] || fail "requeue guidance must reach the repair worker hint"
jq -e --arg id pr-611 'any(.units[] | select(.id==$id) | .history[]; .stage == "supervisor-requeue" and (.decision.decision == "Supervisor arbitration: requeue") and (.decision.rejected | length == 1) and (.decision.evidence | test("supervise-pr-611")))' "$UNITS" >/dev/null \
  || fail "requeue must record decision/reason/evidence/rejected in the unit"

units "$(jq -cn '{units:[{id:"pr-612",pr:612,lane:"pr",branch:"agent/issue-612",stage:"supervisor-review",blocked_on:700,reviewed_sha:"aaaa",reviewed_pr_head:"aaaa",
  history:[{stage:"review-block",result:"BLOCKED-ON #700",at:"2026-10-27T00:00:00Z"},{stage:"supervisor-review",result:"blocked-external without a predecessor",at:"2026-10-27T00:01:00Z"}]}]}')"
harvest_with_reply pr-612 'ACTION: reroute
REASON: BLOCK 在可修的点上
REJECTED: park
GUIDANCE: 按 F1 修复后重推'
[[ "$(field pr-612 .stage)" == repair-pending ]] || fail "reroute must land in repair-pending"
[[ "$(field pr-612 .blocked_on)" == null ]] || fail "reroute must clear blocked_on"
[[ "$(field pr-612 .reviewed_sha)" == null ]] || fail "reroute must clear the reviewed pair for a fresh review"

units "$(jq -cn --argjson sha "$SHA1" --argjson head "$SHA2" '{units:[{id:"pr-613",issue:613,pr:613,lane:"pr",branch:"agent/issue-613",stage:"supervisor-review",
  reviewed_sha:$sha,reviewed_pr_head:$head,approved_sha:null,
  history:[{stage:"review-approve",result:"ok",at:"2026-10-27T00:00:00Z"},{stage:"supervisor-review",result:"runner environment failure persists",at:"2026-10-27T00:01:00Z"}]}]}')"
harvest_with_reply pr-613 'ACTION: approve
REASON: 批准后 CI 基建反复失败，head 本身已评审通过
EVIDENCE: review-approve 后仅 ci 基建失败
REJECTED: requeue（无代码问题）'
[[ "$(field pr-613 .stage)" == ready-to-merge ]] || fail "approve must return the unit to the merge lane"
[[ "$(field pr-613 .approved_sha)" == "$SHA1" ]] || fail "approve must bind the reviewed head"

# 危险 approve 挡板：main_red 单元与批准后回滚过的单元不允许 approve（f11 基线实测 2 次危险 approve）。
units "$(jq -cn --argjson sha "$SHA1" '{units:[{id:"pr-614",pr:614,lane:"pr",stage:"supervisor-review",main_red:true,reviewed_sha:$sha,reviewed_pr_head:$sha,
  history:[{stage:"review-request-changes",result:"F1",at:"2026-10-27T00:00:00Z"},{stage:"supervisor-escalated",result:"x",at:"2026-10-27T00:02:00Z"}]}]}')"
harvest_with_reply pr-614 'ACTION: approve
REASON: head 没问题
REJECTED: park'
[[ "$(field pr-614 .stage)" == parked ]] || fail "unsafe approve on a main_red unit must be refused into parked, got $(field pr-614 .stage)"

units "$(jq -cn --argjson sha "$SHA1" '{units:[{id:"pr-615",pr:615,lane:"pr",stage:"supervisor-review",reviewed_sha:$sha,reviewed_pr_head:$sha,
  history:[{stage:"review-approve",result:"ok",at:"2026-10-27T00:00:00Z"},{stage:"merge-reverted",result:"post-merge red",at:"2026-10-27T00:01:00Z"},{stage:"supervisor-escalated",result:"re-deliver",at:"2026-10-27T00:02:00Z"}]}]}')"
harvest_with_reply pr-615 'ACTION: approve
REASON: head 没问题
REJECTED: park'
[[ "$(field pr-615 .stage)" == parked ]] || fail "unsafe approve after a post-approval revert must be refused into parked, got $(field pr-615 .stage)"

units "$(jq -cn '{units:[{id:"pr-616",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"non-product cannot push",at:"2026-10-27T00:00:00Z"}]}]}')"
harvest_with_reply pr-616 'ACTION: park
REASON: 策略性搁置，等产品决策
REJECTED: close'
[[ "$(field pr-616 .stage)" == parked ]] || fail "park must land in parked"

units "$(jq -cn '{units:[{id:"pr-617",issue:617,pr:617,lane:"pr",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"superseded",at:"2026-10-27T00:00:00Z"}]}]}')"
harvest_with_reply pr-617 'ACTION: close
REASON: 已被 #618 取代
REJECTED: park'
[[ "$(field pr-617 .stage)" == closed ]] || fail "close must land in closed"
grep -q '^gh pr close 617 ' "$GH_CALLS" || fail "close must close the unit PR"

units "$(jq -cn '{units:[{id:"issue-618",issue:618,stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"needs a maintainer business fact",at:"2026-10-27T00:00:00Z"}]}]}')"
harvest_with_reply issue-618 'ACTION: needs-info
REASON: 缺一个只有人知道的事实
REJECTED: requeue
QUESTION: EMPMRUEF3ZX 现在是生效还是已退役？'
[[ "$(field issue-618 .stage)" == needs-human ]] || fail "needs-info must land in needs-human"
grep -q '^gh issue comment 618 ' "$GH_CALLS" || fail "needs-info must comment on the issue"
grep -Eq '^gh issue edit 618 .*--add-label needs-info$' "$GH_CALLS" || {
  fail "needs-info must label the issue; calls for #618: $(grep ' 618 ' "$GH_CALLS" || true); scheduler log: $(tail -n 4 "$LOG" 2>/dev/null || true)"
}

# 无 PR 无 issue 的单元：问题发不出去，要留告警而不是静默。
units "$(jq -cn '{units:[{id:"main-red-abc123456",main_red:true,stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"x",at:"2026-10-27T00:00:00Z"}]}]}')"
harvest_with_reply main-red-abc123456 'ACTION: needs-info
REASON: 只能改 workflow
QUESTION: 允许改 workflow 吗？'
[[ "$(field main-red-abc123456 .stage)" == needs-human ]] || fail "needs-info without an issue must still leave supervisor-review"
grep -q 'NEEDS-INFO-UNDELIVERED unit=main-red-abc123456' "$sup/autopi/alerts/state.md" || fail "undeliverable needs-info must alert"

# 无法解析的输出与无报告：都记一次无效裁决（预算已消耗），单元留在 supervisor-review 等下一拍。
units "$(jq -cn '{units:[{id:"pr-619",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"x",at:"2026-10-27T00:00:00Z"}]}]}')"
harvest_with_reply pr-619 '我觉得应该再修一轮。'
[[ "$(field pr-619 .stage)" == supervisor-review && "$(field pr-619 '.history[-1].stage')" == supervisor-arbiter-invalid ]] \
  || fail "an unparseable reply must record supervisor-arbiter-invalid and keep the unit parked in supervisor-review"
units "$(jq -cn '{units:[{id:"pr-620",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"x",at:"2026-10-27T00:00:00Z"}]}]}')"
harvest_supervisor_arbiter "$(jq -cn '{pid:99999999,unit:"pr-620",type:"supervise",log:"supervise-pr-620.worker.log",report:"supervise-pr-620-missing.md",started:"2026-10-27T00:00:00Z"}')"
[[ "$(field pr-620 '.history[-1].stage')" == supervisor-arbiter-no-output ]] || fail "a report-less worker must record supervisor-arbiter-no-output"

# 历史里先有非评审记录再有评审记录（真实单元的形状）：requeue 回 repair，不因 jq 优先级报错落 parked。
units "$(jq -cn '{units:[{id:"pr-620",pr:620,lane:"pr",branch:"fix/x",stage:"supervisor-review",history:[{stage:"self-check-red",result:"x",at:"2026-10-27T00:00:00Z"},{stage:"review-block",result:"y",at:"2026-10-27T00:01:00Z"},{stage:"supervisor-escalated",result:"blocked-external without a predecessor",at:"2026-10-27T00:02:00Z"}]}]}')"
harvest_with_reply pr-620 'ACTION: requeue
REASON: 无前置可等
GUIDANCE: git merge origin/main 后重新评审'
[[ "$(field pr-620 .stage)" == repair-pending ]] || fail "requeue of a reviewed PR unit must return to repair-pending, got $(field pr-620 .stage)"

# 没有可放回工作环节的 requeue：不猜，落 parked。
units "$(jq -cn '{units:[{id:"misc-621",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"delivered with no transition",at:"2026-10-27T00:00:00Z"}]}]}')"
harvest_with_reply misc-621 'ACTION: requeue
REASON: 交付结果需要人定的后续
GUIDANCE: 重新评估交付'
[[ "$(field misc-621 .stage)" == parked ]] || fail "requeue without a work stage must park instead of guessing"

# ---- 两轮裁决上限与第 3 次升级 ----
units "$(jq -cn '{units:[{id:"pr-622",issue:622,stage:"supervisor-review",
  history:[{stage:"supervisor-escalated",result:"r1",at:"2026-10-26T00:00:00Z"},{stage:"supervisor-arbiter",result:"dispatched",at:"2026-10-26T00:01:00Z"},
           {stage:"supervisor-escalated",result:"r2",at:"2026-10-26T02:00:00Z"},{stage:"supervisor-arbiter",result:"dispatched",at:"2026-10-26T02:01:00Z"},
           {stage:"supervisor-escalated",result:"r3",at:"2026-10-26T04:00:00Z"}]}]}')"
: > "$GH_CALLS"
dispatch_supervisor_arbiters
[[ "$(field pr-622 .stage)" == parked ]] || fail "a twice-arbitrated unit must park on the next entry, got $(field pr-622 .stage)"
! grep -q 'gh issue comment 622 ' "$GH_CALLS" || fail "budget exhaustion must not ask the requester a process question"
[[ "$(jq '[.workers[] | select(.type=="supervise")] | length' "$WORKERS")" == 0 ]] || fail "budget exhaustion must not dispatch another arbitration"

# 人工交接不算升级：三次 "handed to ..." 仍派裁决，不转 needs-info。
units "$(jq -cn '{units:[{id:"pr-623",issue:623,stage:"supervisor-review",
  history:[{stage:"supervisor-escalated",result:"handed to zf-29 for founder-approved batch land",at:"2026-10-26T00:00:00Z"},
           {stage:"supervisor-review",result:"handed to zf-29 for founder-approved batch land",at:"2026-10-26T01:00:00Z"},
           {stage:"supervisor-escalated",result:"handed to zf-29 for founder-approved batch land",at:"2026-10-26T02:00:00Z"}]}]}')"
dispatch_supervisor_arbiters
[[ "$(field pr-623 .stage)" == supervisor-review ]] || fail "manual handoffs must not exhaust the escalation budget, got $(field pr-623 .stage)"
jq -e 'any(.workers[]; .type=="supervise" and .unit=="pr-623")' "$WORKERS" >/dev/null || fail "a unit with only manual handoffs must get an arbitration"

# 第 3 次升级在 to_supervisor 里直接 park，不再停在 supervisor-review，也不问人。
units "$(jq -cn '{units:[{id:"pr-623",issue:623,pr:623,lane:"pr",stage:"repair-pending",
  history:[{stage:"supervisor-escalated",result:"r1",at:"2026-10-26T00:00:00Z"},{stage:"supervisor-escalated",result:"r2",at:"2026-10-26T01:00:00Z"}]}]}')"
: > "$GH_CALLS"
to_supervisor pr-623 "loop-breaker: rounds after arbitration"
[[ "$(field pr-623 .stage)" == parked ]] || fail "the third escalation must park, got $(field pr-623 .stage)"
! grep -q 'gh issue comment 623 ' "$GH_CALLS" || fail "the third escalation must not post a process question"
jq -e --arg id pr-623 'any(.units[] | select(.id==$id) | .history[]; .stage == "supervisor-budget-park")' "$UNITS" >/dev/null || fail "budget park must be recorded in history"

# ---- 开关关着：不派裁决；单元保持 supervisor-review（机制落地、开关关着）----
jq '.supervisor_arbiter.enabled = false' "$sup/autopi/config.json" > "$fixture/config.tmp" && mv "$fixture/config.tmp" "$sup/autopi/config.json"
CFG="$(cat "$sup/autopi/config.json")"
SUPERVISOR_ARBITER="$(jqf -r 'if .supervisor_arbiter.enabled == true then "true" else "false" end' <<<"$CFG")"
units "$(jq -cn '{units:[{id:"pr-624",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"x",at:"2026-10-27T00:00:00Z"}]}]}')"
before="$(jq '[.workers[] | select(.type=="supervise")] | length' "$WORKERS")"
dispatch_supervisor_arbiters
[[ "$(field pr-624 .stage)" == supervisor-review ]] || fail "gate off must keep the current waiting behavior"
[[ "$(jq '[.workers[] | select(.type=="supervise")] | length' "$WORKERS")" == "$before" ]] || fail "gate off must not dispatch an arbitration worker"

echo 'supervisor-arbiter.test.sh: all assertions passed'
