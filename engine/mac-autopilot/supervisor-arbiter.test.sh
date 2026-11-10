#!/usr/bin/env bash
# #4369 supervisor 裁决回归：supervisor-review 的派发/回收/六动作落地、两轮上限、第 3 次升级转 parked。
# 断言对外的动作（worker 派发、状态迁移、gh 评论/标签/关 PR、决策记录），不测 prompt 文案本身。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/sup-arbiter"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo" "$fixture/bin" "$fixture/worker-scratch/luna"
# Stage-transition fixtures are already roadmap leaves; this suite covers arbitration effects.
export ZF_ROADMAP_TREE_CACHE_FILE="$fixture/roadmap-tree.json"
jq -cn '{roots:[611,615,618,622,623,683,684,686,687,688,689,690,699] | map({number:.,title:("fixture issue " + tostring),state:"open",labels:[],children:[]})}' \
  > "$ZF_ROADMAP_TREE_CACHE_FILE"
jq '.auto_merge = false | .advisor = false | .precheck = false | .supervisor_arbiter.enabled = true | .supervisor_arbiter.cap_triage = false' "$script_dir/config.template.json" > "$sup/autopi/config.json"
echo '{"units":[]}' > "$sup/autopi/units.json"
echo '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi" WORKER_SCRATCH_ROOT="$fixture/worker-scratch"
export CODEX_HOME="$fixture/codex-home"
mkdir -p "$CODEX_HOME"
cat > "$CODEX_HOME/config.toml" <<'TOML'
[profiles.terra]
model = "gpt-6.1-terra"
TOML
export ZF_CONFIG_ROOT="$fixture/repo/.zenoforge"
mkdir -p "$ZF_CONFIG_ROOT/prompts"
cp "$script_dir/../prompts/supervisor-arbiter.md" "$ZF_CONFIG_ROOT/prompts/supervisor-arbiter.md"
printf '\nCONFIG_SUPERVISOR_PROMPT_OVERRIDE\n' >> "$ZF_CONFIG_ROOT/prompts/supervisor-arbiter.md"
cp "$script_dir/../prompts/review-contract.md" "$ZF_CONFIG_ROOT/prompts/review-contract.md"
export CODEX_SESSIONS_DIR="$fixture/sessions"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
[[ "$SUPERVISOR_ARBITER_UNIT_CAP" == 4 ]] || { echo 'supervisor-arbiter.test.sh: config must default supervisor_arbiter.unit_cap to 4' >&2; exit 1; }
decision_eval_stages() { printf '\n'; }
[[ "$(review_contract_rule)" == *"$ZF_CONFIG_ROOT/prompts/review-contract.md"* ]] \
  || { echo 'supervisor-arbiter.test.sh: review contract must use target config override' >&2; exit 1; }

fail() { echo "supervisor-arbiter.test.sh: $*" >&2; exit 1; }
declare -F supervisor_arbiter_owner_ruling_pending >/dev/null \
  || fail 'units.sh must load the no-human-wait helpers'
units() { printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
grep -Fq 'reconcile_size_recuts() {' "$script_dir/scheduler.d/size-recuts.sh" || fail 'size-recuts must own size-recut reconciliation'

GH_CALLS="$fixture/gh.calls"; : > "$GH_CALLS"
gh() {
  printf 'gh %s\n' "$*" >> "$GH_CALLS"
  case "$1 $2" in
    'issue view')
      if [[ "$*" == *'issue view 615'* && "$*" == *'--json number,title,body,state,labels'* ]]; then
        printf '%s\n' '{"number":615,"title":"fixture issue 615","body":"","state":"OPEN","labels":[{"name":"needs-advisor"},{"name":"on-hold"}]}'
        return 0
      fi
      if [[ "$*" == *'--json title,body,subIssuesSummary'* ]]; then
        if [[ "$*" == *'issue view 698'* ]]; then
          printf '%s\n' '{"title":"fixture parent","body":"- [ ] #797","subIssuesSummary":{"total":0}}'
        else
          printf '%s\n' '{"title":"fixture issue","body":"","subIssuesSummary":{"total":0}}'
        fi
        return 0
      fi
      if [[ "$*" == *'--json state --jq .state'* ]]; then echo OPEN; return 0; fi
      if [[ "$*" == *'--json number,title,body,state,labels'* ]]; then
        printf '%s\n' '{"number":611,"title":"fixture issue 611","body":"","state":"OPEN","labels":[{"name":"needs-advisor"}]}'
      elif [[ "$*" == *'--json labels -q .labels[].name'* ]]; then
        if [[ "$*" == *'issue view 615'* ]]; then printf '%s\n' needs-advisor on-hold; else printf '%s\n' needs-advisor; fi
      else
        echo "supervisor-arbiter.test.sh: unexpected gh call: $*" >&2
        return 97
      fi
      return 0
      ;;
    'issue comment') return 0 ;;
    'issue edit') return 0 ;;
    'label list') printf '%s\n' needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded on-hold ;;
    'label create') return 0 ;;
    'pr comment') return 0 ;;
    'pr close') return 0 ;;
    'pr view') case "$*" in *headRefName*) echo fix/token-fixture ;; esac; return 0 ;;
    *) echo "supervisor-arbiter.test.sh: unexpected gh call: $*" >&2; return 97 ;;
  esac
}
export -f gh 2>/dev/null || true

# codex 桩：记录调用，把预设裁决报告写到 --output-last-message。
ARBITRATION_REPLY="$fixture/arbitration-reply.md" CODEX_CALLS="$fixture/codex.calls"
codex_fake() {
  printf 'codex %s\n' "$*" >> "$CODEX_CALLS"
  local out="" prev=""
  local a
  for a in "$@"; do [[ "$prev" == --output-last-message ]] && out="$a"; prev="$a"; done
  [[ -n "$out" && -f "$ARBITRATION_REPLY" ]] || return 0
  cat "$ARBITRATION_REPLY" > "$out"
}
export ARBITRATION_REPLY CODEX_CALLS
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
jq -e --arg unit pr-601 'any(.workers[]; .unit == $unit and .type == "supervise" and (.model == "profile:terra"))' "$WORKERS" >/dev/null || fail "without a cache the arbiter must record the configured terra profile"
[[ "$(field pr-601 .stage)" == supervisor-review ]] || fail "dispatch must leave the unit in supervisor-review while arbitrating"
[[ "$(field pr-601 '.history[-1].stage')" == supervisor-arbiter ]] || fail "dispatch must consume one arbitration budget slot in history"
q_file="$(ls -t "$sup"/supervise-pr-601-*.q.md | head -1)"
grep -q 'six actions' "$q_file" || fail "arbitration prompt must carry the six-action prompt"
grep -q 'CONFIG_SUPERVISOR_PROMPT_OVERRIDE' "$q_file" || fail "arbitration prompt must use target config override"
frozen="$(sed -n '/^```json$/,/^```$/p' "$q_file" | sed '1d;$d' | grep -v '^#')"
[[ "$(jq -r '.unitId' <<<"$frozen")" == pr-601 ]] || fail "arbitration prompt must embed the unit id in the frozen record"
jq -e '.escalationReason.reason == "review report has no single VERDICT line" and (.unitHistory | length == 2) and .reviewFindings.available == true and (.ciEvidence | type == "array")' <<<"$frozen" >/dev/null \
  || fail "arbitration prompt must embed the frozen record (escalation/history/findings/ci)"
# 在途上限：pr-601 在裁，上限 2 时只再派一个，且不给在裁单元重复派。
printf '%s\n' "$(jq -cn '{units:[{id:"pr-601",stage:"supervisor-review",history:[{stage:"supervisor-arbiter",result:"x",at:"2026-10-27T00:00:00Z"}]},
  {id:"pr-602",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"x",at:"2026-10-27T00:00:00Z"}]},
  {id:"pr-603",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"y",at:"2026-10-27T00:00:00Z"}]}]}')" > "$UNITS"
before="$(jq '[.workers[] | select(.type=="supervise")] | length' "$WORKERS")"
saved_max="$SUPERVISOR_ARBITER_MAX"; SUPERVISOR_ARBITER_MAX=2; printf 'gpt-6.1-terra\t%s\n' "$(( $(date +%s) + 86400 ))" > "$WORKER_SCRATCH_ROOT/luna/model-not-found.cache"
dispatch_supervisor_arbiters
for _ in {1..50}; do grep -Fq ' -m gpt-6-luna -c model_reasoning_effort=max ' "$fixture/codex.calls" 2>/dev/null && break; sleep 0.02; done; [[ "$(jq '[.workers[] | select(.type=="supervise")] | length' "$WORKERS")" == "$((before + 1))" ]] && grep -Fq ' -m gpt-6-luna -c model_reasoning_effort=max ' "$fixture/codex.calls" || fail "cached terra must dispatch the arbiter on luna max (calls=$(cat "$fixture/codex.calls" 2>/dev/null || true))"
grep -Fq 'model-not-found cache swap arbiter profile=terra from=gpt-6.1-terra to=gpt-6-luna effort=max' "$LOG" || fail 'cached terra arbiter swap must be recorded'
jq -e '[.workers[] | select(.type=="supervise" and .unit=="pr-601")] | length == 1' "$WORKERS" >/dev/null || fail "a unit already under arbitration must not get a second worker"
jq -e 'any(.workers[]; .type=="supervise" and .unit=="pr-602")' "$WORKERS" >/dev/null || fail "the next unit in order must be dispatched"
before="$(jq '[.workers[] | select(.type=="supervise")] | length' "$WORKERS")"
dispatch_supervisor_arbiters
[[ "$(jq '[.workers[] | select(.type=="supervise")] | length' "$WORKERS")" == "$before" ]] || fail "no arbitration may dispatch at the in-flight cap"
SUPERVISOR_ARBITER_MAX="$saved_max"; rm -f "$WORKER_SCRATCH_ROOT/luna/model-not-found.cache"

# An under-cap RECUT refusal resumes existing work once; a legacy refusal does too, and a moved head can return to cap triage.
WT_ROOT="$fixture/clones"; mkdir -p "$WT_ROOT/wt-pr-650"
git -C "$WT_ROOT/wt-pr-650" init -q
git -C "$WT_ROOT/wt-pr-650" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
refused_sha="$(git -C "$WT_ROOT/wt-pr-650" rev-parse HEAD)"
printf '%s\n' "$(jq -cn '{units:[{id:"pr-650",issue:650,pr:650,stage:"parked",history:[{stage:"supervisor-cap-triage-park",result:"x",at:"2026-10-27T00:00:00Z"}]}]}')" > "$UNITS"
echo '{"workers":[]}' > "$WORKERS"; : > "$GH_CALLS"
supervisor_budget_recut pr-650 "cap triage: too large" null "cap triage could not complete the recut route" "recut" supervisor-cap-triage-park supervisor-cap-triage-recut true
[[ "$(field pr-650 .stage)" == repair-pending && "$(field pr-650 .parked_reason)" == null \
  && "$(field pr-650 .recut_refused_head)" == "$refused_sha" && "$(field pr-650 .recut_refused_verdict)" == RECUT ]] \
  || fail "a refused RECUT must resume the existing PR work and record its head and verdict"
[[ "$(field pr-650 .repair_hint)" == *'commit and push'* ]] || fail "a refused RECUT must tell the worker to publish its existing work"
! grep -Fq 'pr close' "$GH_CALLS" || fail "a refused RECUT must not close the PR"
saved_cap_triage="$SUPERVISOR_CAP_TRIAGE"; SUPERVISOR_CAP_TRIAGE=true
dispatch_supervisor_arbiters
[[ "$(jq '.workers | length' "$WORKERS")" == 0 && "$(field pr-650 .stage)" == repair-pending ]] || fail "resume must dispatch the existing work before another RECUT attempt"
printf '%s\n' "$(jq -cn --arg h "$refused_sha" '{units:[{id:"pr-650",issue:650,pr:650,branch:"agent/issue-650",stage:"parked",parked_reason:"recut-refused-unpushed",recut_refused_head:$h,recut_refused_verdict:"RECUT",history:[{stage:"supervisor-recut-refused",result:"legacy park"}]}]}')" > "$UNITS"
dispatch_supervisor_arbiters
[[ "$(field pr-650 .stage)" == repair-pending && "$(jq '.workers | length' "$WORKERS")" == 0 ]] || fail "a legacy refused-RECUT park must resume its existing work once"
git -C "$WT_ROOT/wt-pr-650" -c user.name=t -c user.email=t@t commit -q --allow-empty -m second
printf '%s\n' "$(jq -cn --arg h "$refused_sha" '{units:[{id:"pr-650",issue:650,pr:650,branch:"agent/issue-650",stage:"parked",parked_reason:"recut-refused-unpushed",recut_refused_head:$h,recut_refused_verdict:"RECUT",recut_refused_resume_head:$h,history:[{stage:"supervisor-recut-refused",result:"legacy park"}]}]}')" > "$UNITS"
ZF_ENGINE_DIR="$script_dir/.." dispatch_supervisor_arbiters
[[ "$(jq '[.workers[] | select(.unit=="pr-650")] | length' "$WORKERS")" == 1 ]] || fail "a moved head must reach cap triage again"
SUPERVISOR_CAP_TRIAGE="$saved_cap_triage"
# Daily ceiling: any verdict, one alert. The day stall is gone: the ceiling now ends the
# unit's arbitration through the scheduler's own default decision in the same tick.
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$(jq -cn --arg at "$now_iso" '{units:[{id:"pr-651",stage:"supervisor-review",history:[{stage:"supervisor-arbiter",result:"x",at:$at}]},
  {id:"pr-652",stage:"supervisor-review",history:[{stage:"supervisor-arbiter",result:"x",at:"2026-10-27T00:00:00Z"}]}]}')" > "$UNITS"
echo '{"workers":[]}' > "$WORKERS"
saved_daily="$SUPERVISOR_ARBITER_DAILY_MAX"; SUPERVISOR_ARBITER_DAILY_MAX=1
dispatch_supervisor_arbiters
SUPERVISOR_ARBITER_DAILY_MAX="$saved_daily"
! jq -e 'any(.workers[]; .unit=="pr-651")' "$WORKERS" >/dev/null || fail "a unit at the daily ceiling must not dispatch"
[[ "$(field pr-651 .arbiter_daily_max_alerted)" == "${STAMP%%T*}" ]] || fail "the ceiling must be recorded once"
jq -e --arg id pr-651 'any(.units[] | select(.id==$id) | .history[]; .stage == "supervisor-cap-default")' "$UNITS" >/dev/null \
  || fail "the daily ceiling must apply the default decision instead of stalling a day: $(jq -c '.units[0]' "$UNITS")"
[[ "$(field pr-651 .stage)" != supervisor-review ]] || fail "the daily ceiling must take the unit out of supervisor-review"
! grep -q 'arbiter-daily-max unit=pr-651' "$AGENT_HOME/supervisor-inbox" 2>/dev/null \
  || fail "the daily ceiling default must not create a founder handoff"
jq -e 'any(.workers[]; .unit=="pr-652")' "$WORKERS" >/dev/null || fail "old dispatches must not count against the ceiling"
echo '{"units":[]}' > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"

# A run that left the unit here holds it until head, state or ruling moves.
jq -cn '{units:[{id:"pr-661",stage:"supervisor-review",reviewed_pr_head:"aaa",history:[]},{id:"pr-662",stage:"supervisor-review",reviewed_pr_head:"bbb",history:[]},{id:"pr-663",stage:"supervisor-review",reviewed_pr_head:"ccc",cto_rulings:["new"],history:[]},
  {id:"pr-664",stage:"supervisor-review",reviewed_pr_head:"ddd",history:[{stage:"supervisor-arbiter",result:"dispatched to profile terra"}]}]}' > "$UNITS"
set_unit pr-661 ".arbiter_left_mark=$(js "$(supervisor_arbiter_mark "$(jq -c '.units[0]' "$UNITS")")")"
set_unit pr-662 '.arbiter_left_mark="aaa||0"'
set_unit pr-663 '.arbiter_left_mark="ccc||0"'
set_unit pr-664 ".arbiter_left_mark=$(js "$(supervisor_arbiter_mark "$(jq -c '.units[3]' "$UNITS")")")"
echo '{"workers":[]}' > "$WORKERS"
dispatch_supervisor_arbiters
! jq -e 'any(.workers[]; .unit=="pr-661")' "$WORKERS" >/dev/null || fail "an unchanged unit must not dispatch again"
jq -e 'any(.workers[]; .unit=="pr-662")' "$WORKERS" >/dev/null || fail "a new head must reopen arbitration"
jq -e 'any(.workers[]; .unit=="pr-663")' "$WORKERS" >/dev/null || fail "a new ruling must reopen arbitration"
jq -e 'any(.workers[]; .unit=="pr-664")' "$WORKERS" >/dev/null || fail "a dispatch without a decision must reopen arbitration"
jq -e '.units[]|select(.id=="pr-664")|has("arbiter_left_mark")|not' "$UNITS" >/dev/null || fail "a stale dispatch-only hold mark must be cleared"
grep -Fq 'arbiter-no-change unit=pr-661' "$AGENT_HOME/supervisor-inbox" || fail "a held unit must reach the supervisor"
echo '{"units":[]}' > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"

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
mkdir -p "$AGENT_HOME/state"
jq -n '{state:"needs-advisor",recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/611.json"
export OPEN_ISSUE_BLOCKER_GRAPH_JSON='[]'
harvest_with_reply pr-611 'ACTION: requeue
REASON: 评审报告缺结论行，可重跑
EVIDENCE: supervisor-escalated no VERDICT
REJECTED: close（产出仍需要）；approve（无已评审 head）
GUIDANCE: 先 git merge origin/main 再按类别修复'
[[ "$(field pr-611 .stage)" == repair-pending ]] || fail "requeue must return the unit to repair-pending"
[[ "$(field pr-611 .repair_hint)" == *'git merge origin/main'* ]] || fail "requeue guidance must reach the repair worker hint"
grep -Fq 'gh issue edit 611 ' "$GH_CALLS" \
  && grep -Fq -- '--remove-label needs-advisor' "$GH_CALLS" \
  && grep -Fq -- '--add-label ready-for-agent' "$GH_CALLS" \
  || fail "requeue must clear the stale needs-advisor label and return the issue to ready-for-agent"
jq -e --arg id pr-611 'any(.units[] | select(.id==$id) | .history[]; .stage == "supervisor-requeue" and (.decision.decision == "Supervisor arbitration: requeue") and (.decision.rejected | length == 1) and (.decision.evidence | test("supervise-pr-611")))' "$UNITS" >/dev/null \
  || fail "requeue must record decision/reason/evidence/rejected in the unit"

# Stop-loss adds an on-hold overlay and can leave the previous needs-advisor
# label underneath it. A supervisor requeue must clear both through the shared
# hold-requeue transition before returning the unit to its pending work stage.
units "$(jq -cn '{units:[{id:"pr-615",issue:615,pr:615,lane:"pr",branch:"agent/issue-615",stage:"supervisor-review",
  history:[{stage:"review-request-changes",result:"F1",at:"2026-10-27T00:00:00Z"},{stage:"supervisor-escalated",result:"stop-loss",at:"2026-10-27T00:01:00Z"}]}]}')"
jq -n '{state:"on-hold",hold:{kind:"stop-loss",holder:"scheduler-stop-loss"},recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/615.json"
harvest_with_reply pr-615 'ACTION: requeue
REASON: stop-loss hold reviewed, resume the approved repair
EVIDENCE: supervisor-escalated stop-loss
REJECTED: park（仍有可重试的修复）
GUIDANCE: 恢复修复并提交'
[[ "$(field pr-615 .stage)" == repair-pending ]] || fail "stop-loss requeue must return the unit to repair-pending"
jq -e '.state == "ready-for-agent" and .hold == null' "$AGENT_HOME/state/615.json" >/dev/null \
  || fail "stop-loss requeue must release the stop-loss hold and reset the issue stage"
grep -Fq 'gh issue edit 615 ' "$GH_CALLS" \
  && grep -Fq -- '--remove-label needs-advisor' "$GH_CALLS" \
  && grep -Fq -- '--remove-label on-hold' "$GH_CALLS" \
  && grep -Fq -- '--add-label ready-for-agent' "$GH_CALLS" \
  || fail "stop-loss requeue must clear stale needs-advisor/on-hold labels and add ready-for-agent"

units "$(jq -cn '{units:[{id:"pr-612",pr:612,lane:"pr",branch:"agent/issue-612",stage:"supervisor-review",blocked_on:700,reviewed_sha:"aaaa",reviewed_pr_head:"aaaa",
  history:[{stage:"review-block",result:"BLOCKED-ON #700",at:"2026-10-27T00:00:00Z"},{stage:"supervisor-review",result:"blocked-external without a predecessor",at:"2026-10-27T00:01:00Z"}]}]}')"
harvest_with_reply pr-612 'ACTION: reroute
REASON: BLOCK 在可修的点上
REJECTED: park
GUIDANCE: 按 F1 修复后重推'
[[ "$(field pr-612 .stage)" == review-pending ]] || fail "reroute after an INPUT_INCOMPLETE review must land in review-pending, never a repair, got $(field pr-612 .stage)"
[[ "$(field pr-612 .blocked_on)" == null ]] || fail "reroute must clear blocked_on"
[[ "$(field pr-612 .reviewed_sha)" == null ]] || fail "reroute must clear the reviewed pair for a fresh review"

# INPUT_INCOMPLETE judged no code: a requeue or a cap return goes back to a review, not to a commit repair.
units "$(jq -cn --argjson sha "$SHA1" '{units:[{id:"pr-616",pr:616,lane:"pr",branch:"agent/issue-616",stage:"supervisor-review",reviewed_sha:$sha,reviewed_pr_head:$sha,
  history:[{stage:"review-block",result:$sha,at:"2026-10-27T00:00:00Z"},{stage:"supervisor-escalated",result:"x",at:"2026-10-27T00:01:00Z"}]}]}')"
harvest_with_reply pr-616 'ACTION: requeue
REASON: 评审未能给出结论
REJECTED: park
GUIDANCE: 再评审一次'
[[ "$(field pr-616 .stage)" == review-pending && "$(field pr-616 .reviewed_sha)" == null ]] || fail "requeue after review-block must land in a fresh review, got $(field pr-616 .stage)"
blocked_unit="$(jq -cn --argjson sha "$SHA1" '{id:"pr-617",pr:617,stage:"blocked-external",history:[{stage:"review-block",result:$sha}]}')"
[[ "$(supervisor_return_stage "$blocked_unit")" == review-pending ]] || fail "cap return after review-block must be review-pending"
[[ "$(supervisor_return_stage "$(jq -c '.history=[{stage:"review-request-changes"}]' <<<"$blocked_unit")")" == repair-pending ]] || fail "cap return after a real NOT_READY stays repair-pending"

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
jq -e '.units[]|select(.id=="pr-616")|has("arbiter_left_mark")|not' "$UNITS" >/dev/null || fail "a decision that moved the unit must not hold it"

# A tracker flag on a ticket that still has an open task-list child refuses the requeue, so the unit parks with that refusal recorded.
units "$(jq -cn '{units:[{id:"pr-698",issue:698,pr:698,lane:"pr",branch:"agent/issue-698",stage:"supervisor-review",history:[{stage:"review-request-changes",result:"F1",at:"2026-10-27T00:00:00Z"},{stage:"supervisor-escalated",result:"stop-loss",at:"2026-10-27T00:01:00Z"}]}]}')"
jq -n '{state:"on-hold",tracker_parent:true,hold:{kind:"stop-loss",holder:"scheduler-stop-loss"},recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/698.json"
parent_reason="$(scheduler_issue_intake_parent_reason 698 '{"title":"fixture parent","body":"- [ ] #797","subIssuesSummary":{"total":0}}')" \
  || fail "the #698 fixture must be refused because open task-list child #797 is still open"
[[ "$parent_reason" == 'task list references open child #797' ]] \
  || fail "the #698 fixture must identify open task-list child #797 as the refusal reason, got: $parent_reason"
harvest_with_reply pr-698 'ACTION: requeue
REASON: stop-loss hold reviewed, resume the approved repair
EVIDENCE: supervisor-escalated stop-loss
REJECTED: park（仍有可重试的修复）
GUIDANCE: 恢复修复并提交' || :  # the scheduler runs without errexit
[[ "$(field pr-698 .stage)" == parked ]] || fail "a refused requeue must park the unit"
[[ "$parent_reason" == 'task list references open child #797' \
   && "$(field pr-698 .note)" == *'issue_transition: refused tracker parent #698'* ]] \
  || fail "the durable park must preserve the refusal caused by open task-list child #797"
jq -e '.tracker_parent == true and .state == "on-hold"' "$AGENT_HOME/state/698.json" >/dev/null || fail "a real parent must keep its flag"

# The #4879 and #5329 shape: on-hold, flag set, no child of any kind. The requeue clears the flag and goes through.
units "$(jq -cn '{units:[{id:"pr-699",issue:699,pr:699,lane:"pr",branch:"agent/issue-699",stage:"supervisor-review",history:[{stage:"review-request-changes",result:"F1",at:"2026-10-27T00:00:00Z"},{stage:"supervisor-escalated",result:"stop-loss",at:"2026-10-27T00:00:00Z"}]}]}')"
jq -n '{state:"on-hold",tracker_parent:true,hold:{kind:"stop-loss",holder:"scheduler-stop-loss"},recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/699.json"
harvest_with_reply pr-699 'ACTION: requeue
REASON: stop-loss hold reviewed, resume the approved repair
EVIDENCE: supervisor-escalated stop-loss
REJECTED: park（仍有可重试的修复）
GUIDANCE: 恢复修复并提交' || :
[[ "$(field pr-699 .stage)" != supervisor-review ]] || fail "a stale flag must not refuse the requeue"
jq -e '.state == "ready-for-agent" and (has("tracker_parent") | not) and .hold == null' "$AGENT_HOME/state/699.json" >/dev/null \
  || fail "the requeue must clear the stale flag: $(cat "$AGENT_HOME/state/699.json")"

units "$(jq -cn '{units:[{id:"pr-617",issue:617,pr:617,lane:"pr",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"superseded",at:"2026-10-27T00:00:00Z"}]}]}')"
harvest_with_reply pr-617 'no action line'
jq -e '.units[]|select(.id=="pr-617")|has("arbiter_left_mark")|not' "$UNITS" >/dev/null || fail "a run with no answer decided nothing and must not hold the next one"
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
printf '%s\n' '{"error":{"code":"model_not_found"}}' > "$sup/supervise-pr-620.worker.log"; harvest_supervisor_arbiter "$(jq -cn '{pid:99999999,unit:"pr-620",type:"supervise",log:"supervise-pr-620.worker.log",report:"supervise-pr-620-missing.md",started:"2026-10-27T00:00:00Z",model:"profile:terra"}')"
[[ "$(field pr-620 '.history[-1].stage')" == supervisor-arbiter-no-output ]] && grep -Eq '^gpt-6\.1-terra[[:space:]]+[0-9]+$' "$WORKER_SCRATCH_ROOT/luna/model-not-found.cache" || fail "a report-less terra arbiter must record its model-not-found cache entry"

# 历史里先有非评审记录再有评审记录（真实单元的形状）：requeue 回 repair，不因 jq 优先级报错落 parked。
units "$(jq -cn '{units:[{id:"pr-620",pr:620,lane:"pr",branch:"fix/x",stage:"supervisor-review",history:[{stage:"self-check-red",result:"x",at:"2026-10-27T00:00:00Z"},{stage:"review-request-changes",result:"y",at:"2026-10-27T00:01:00Z"},{stage:"supervisor-escalated",result:"blocked-external without a predecessor",at:"2026-10-27T00:02:00Z"}]}]}')"
harvest_with_reply pr-620 'ACTION: requeue
REASON: 无前置可等
GUIDANCE: git merge origin/main 后重新评审'
[[ "$(field pr-620 .stage)" == repair-pending ]] || fail "requeue of a reviewed PR unit must return to repair-pending, got $(field pr-620 .stage)"

# 没有可放回工作环节的 requeue：不猜，持久关闭（不再停车等人）。
units "$(jq -cn '{units:[{id:"misc-621",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"delivered with no transition",at:"2026-10-27T00:00:00Z"}]}]}')"
harvest_with_reply misc-621 'ACTION: requeue
REASON: 交付结果需要人定的后续
GUIDANCE: 重新评估交付'
[[ "$(field misc-621 .stage)" == closed ]] || fail "requeue without a work stage must close durably instead of guessing"

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

# A founder question that names a fact ends cap triage even when old history still shows a budget park; sweeping it again re-asks forever.
budget_park='{"stage":"supervisor-budget-park","result":"arbitration budget exhausted for x"}'
supervisor_cap_parked_unit "{\"stage\":\"parked\",\"history\":[$budget_park]}" || fail "a legacy budget park must stay swept"
supervisor_cap_parked_unit '{"stage":"parked","parked_reason":"repair-breaker","history":[{"stage":"repair-breaker","result":"same head"}]}' \
  || fail "a repair-breaker park must reach automatic arbitration"
if supervisor_cap_parked_unit "{\"stage\":\"parked\",\"parked_reason\":\"supervisor-cap-founder\",\"supervisor_cap_question\":\"这批单据要对接哪个外部系统？\",\"history\":[$budget_park]}"; then
  fail "a founder park with a real question must not be swept back into cap triage"
fi
# A generic founder park is an engine fault: it gets one sweep, and only one.
generic='工作单元 issue-1 多次升级到工厂 supervisor 后仍无法自动裁决（最近原因：stop-loss）'
supervisor_cap_parked_unit "$(jq -cn --arg q "$generic" '{stage:"parked",parked_reason:"supervisor-cap-founder",supervisor_cap_question:$q}')" \
  || fail "a generic founder park must get its one sweep"
if supervisor_cap_parked_unit "$(jq -cn --arg q "$generic" '{stage:"parked",parked_reason:"supervisor-cap-founder",supervisor_cap_question:$q,supervisor_cap_retry:"spent"}')"; then
  fail "a generic founder park must be swept once only"
fi
if supervisor_cap_parked_unit "{\"stage\":\"parked\",\"parked_reason\":\"supervisor-cap-exhausted\",\"history\":[$budget_park]}"; then
  fail "a terminal park must not be swept by its history"
fi

# The parser rejects text that names no owner fact, so the report re-asks instead of reaching the founder.
report="$fixture/founder-report.md"
founder_report() { printf 'REASON: r\nEVIDENCE: e\nQUESTION: %s\nVERDICT: FOUNDER\n' "$1" > "$report"; }
for generic in 'could not decide automatically' 'The unit could not decide automatically?' "$(printf '工作单元多次升级后仍无法自动裁决？')" 'no question mark here'; do
  founder_report "$generic"
  if supervisor_cap_verdict_of "$report" >/dev/null; then fail "generic founder question passed: $generic"; fi
done
for owner_question in '这批单据要对接哪个外部系统？' '多次升级时用哪个企业账号？'; do
  founder_report "$owner_question"
  [[ "$(supervisor_cap_verdict_of "$report")" == FOUNDER ]] || fail "a question naming an owner fact must pass: $owner_question"
done

# A unit on its one retry has capped again: even a valid FOUNDER verdict ends in the terminal park.
units "$(jq -cn '{units:[{id:"pr-694",lane:"pr",stage:"supervisor-review",supervisor_cap_retry:"pending",history:[]}]}')"
founder_report '这批单据要对接哪个外部系统？'
supervisor_apply_cap_verdict pr-694 "$report" FOUNDER
jq -e '.units[0] | .parked_reason=="supervisor-cap-exhausted" and (.unpark_condition | length > 0)' "$UNITS" >/dev/null \
  || fail "a retry must never reach the founder: $(jq -c '.units[0]' "$UNITS")"
grep -q 'cap-exhausted unit=pr-694' "$AGENT_HOME/supervisor-inbox" || fail "a terminal park must send head one line"
if grep -q 'cap-triage-founder unit=pr-694' "$AGENT_HOME/supervisor-inbox"; then fail "a retry reached the founder inbox"; fi

# The one sweep of a generic founder park goes back through cap triage with its retry pending.
units "$(jq -cn --arg q "$generic" '{units:[{id:"pr-695",lane:"pr",stage:"parked",parked_reason:"supervisor-cap-founder",supervisor_cap_question:$q,supervisor_cap_return_stage:"repair-pending",history:[]}]}')"
SUPERVISOR_ARBITER=true SUPERVISOR_CAP_TRIAGE=true SUPERVISOR_ARBITER_MAX=99 ZF_ENGINE_DIR="$script_dir/.." dispatch_supervisor_arbiters
jq -e '.units[0] | .stage=="supervisor-review" and .supervisor_cap_retry=="pending" and (has("parked_reason") | not)' "$UNITS" >/dev/null \
  || fail "a generic founder park must sweep once with its retry pending: $(jq -c '.units[0]' "$UNITS")"

# Two invalid answers are a terminal park too, with its unpark condition.
units "$(jq -cn '{units:[{id:"pr-692",lane:"pr",stage:"supervisor-review",supervisor_cap_reask:1,supervisor_cap_invalid_answers:["x"],history:[]}]}')"
printf 'no verdict\n' > "$report"
supervisor_cap_triage_reask_or_park pr-692 "$report"
jq -e '.units[0] | .parked_reason=="supervisor-cap-exhausted" and (.unpark_condition | length > 0)' "$UNITS" >/dev/null \
  || fail "two invalid answers must end with an unpark condition: $(jq -c '.units[0]' "$UNITS")"

# An alert that failed once goes out on a later pass; a delivered one does not repeat.
units "$(jq -cn '{units:[{id:"pr-691",lane:"pr",stage:"parked",parked_reason:"supervisor-cap-exhausted",reviewed_pr_head:"aaa",note:"n",cap_exhausted_mark:"aaa||0",history:[]}]}')"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 dispatch_supervisor_arbiters
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 dispatch_supervisor_arbiters
[[ "$(grep -c 'cap-exhausted unit=pr-691' "$AGENT_HOME/supervisor-inbox")" == 1 ]] || fail "a held terminal park must alert exactly once"

# ---- No answer: backoff, then a terminal park that an answering provider lifts ----
no_answer() { # unit: one dead worker that left no report
  harvest_supervisor_arbiter "$(jq -cn --arg unit "$1" '{pid:99999998,unit:$unit,type:"supervise",log:"none.log",report:("none-" + $unit + ".md"),started:"2026-10-27T00:00:00Z",model:"profile:terra"}')"
}
review_unit() { jq -cn --arg id "$1" '{id:$id,lane:"pr",stage:"supervisor-review",supervisor_cap_return_stage:"repair-pending",history:[]}'; }
units "$(jq -cn --argjson a "$(review_unit pr-681)" --argjson b "$(review_unit pr-682)" '{units:[$a,$b]}')"
rm -f "$sup/arbiter-last-answer" "$sup/arbiter-last-probe"
no_answer pr-681
wait_s="$(( $(field pr-681 .arbiter_retry_after) - $(date +%s) ))"
(( wait_s > 3500 && wait_s <= 3600 )) || fail "the first no-answer must wait 1h, got ${wait_s}s"
no_answer pr-681
wait_s="$(( $(field pr-681 .arbiter_retry_after) - $(date +%s) ))"
(( wait_s > 7100 && wait_s <= 7200 )) || fail "the second no-answer must wait 2h, got ${wait_s}s"
before="$(jq '[.workers[] | select(.type=="supervise")] | length' "$WORKERS")"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 ZF_ENGINE_DIR="$script_dir/.." dispatch_supervisor_arbiters
[[ "$(jq '[.workers[] | select(.unit=="pr-681" and .harvested!=true)] | length' "$WORKERS")" == 0 ]] || fail "a unit in backoff must not dispatch"
jq '.workers[].harvested = true' "$WORKERS" > "$fixture/workers.tmp" && mv "$fixture/workers.tmp" "$WORKERS"  # pr-682 was free to run
no_answer pr-681; no_answer pr-681
no_answer pr-682; no_answer pr-682; no_answer pr-682; no_answer pr-682
for unit in pr-681 pr-682; do
  jq -e --arg id "$unit" '.units[] | select(.id==$id) | .parked_reason=="supervisor-cap-exhausted" and .cap_exhausted_by=="no-answer" and (.unpark_condition | length > 0)' "$UNITS" >/dev/null \
    || fail "four no-answers with no other answer must wait for the provider: $unit"
done
[[ "$(grep -c '^.*arbiter-no-answer: runs stopped answering' "$AGENT_HOME/supervisor-inbox")" == 1 ]] || fail "an outage of many units must give one alert"
if grep -q 'cap-exhausted unit=pr-68[12]' "$AGENT_HOME/supervisor-inbox"; then fail "an outage must not alert per unit"; fi

no_answer_dispatch() {
  SUPERVISOR_ARBITER=true SUPERVISOR_CAP_TRIAGE="${1:-true}" SUPERVISOR_ARBITER_MAX=99 ZF_ENGINE_DIR="$script_dir/.." dispatch_supervisor_arbiters
  jq '.workers[].harvested = true' "$WORKERS" > "$fixture/workers.tmp" && mv "$fixture/workers.tmp" "$WORKERS"
}
waiting() { jq '[.units[] | select(.cap_exhausted_by=="no-answer")] | length' "$UNITS"; }
no_answer_dispatch
[[ "$(waiting)" == 2 ]] || fail "no answer yet and no probe due: the units must wait"

# With cap triage off nothing can run, so the probe is not spent.
jq '(.units[].cap_exhausted_at) |= (. - 21700)' "$UNITS" > "$fixture/units.tmp" && mv "$fixture/units.tmp" "$UNITS"
no_answer_dispatch false
[[ "$(waiting)" == 2 && ! -e "$sup/arbiter-last-probe" ]] || fail "cap triage off must not spend the probe"

# Six hours on, one unit probes; the other stays parked.
no_answer_dispatch
[[ "$(waiting)" == 1 ]] || fail "one interval gives one probe, got $(waiting) waiting"
jq -e '[.units[] | select(.cap_exhausted_by==null)][0].arbiter_no_answer == 3' "$UNITS" >/dev/null || fail "a probe with no answer must park again at once"

# A run that answers anywhere lifts the rest, even in the same second as the park.
jq --argjson t "$(supervisor_file_epoch "$sup/arbiter-last-probe")" '(.units[] | select(.cap_exhausted_by=="no-answer") | .cap_exhausted_at) = $t' "$UNITS" > "$fixture/units.tmp" && mv "$fixture/units.tmp" "$UNITS"
touch -r "$sup/arbiter-last-probe" "$sup/arbiter-last-answer"
no_answer_dispatch
[[ "$(waiting)" == 0 ]] || fail "an answer must unpark every waiting unit"

# Others answered during the streak: the fault is this unit's, and it does not wait for a provider.
units "$(jq -cn --argjson a "$(review_unit pr-683)" '{units:[$a]}')"
no_answer pr-683; no_answer pr-683; no_answer pr-683
touch -d '+1 hour' "$sup/arbiter-last-answer"
no_answer pr-683
[[ "$(field pr-683 .parked_reason)" == supervisor-cap-exhausted && "$(field pr-683 .cap_exhausted_by)" != no-answer ]] \
  || fail "a unit others answered around takes the ordinary terminal park: $(jq -c '.units[0]' "$UNITS")"
grep -q 'cap-exhausted unit=pr-683' "$AGENT_HOME/supervisor-inbox" || fail "a unit fault must alert for that unit"

# A decision ends the streak.
units "$(jq -cn --argjson a "$(review_unit pr-684)" '{units:[$a]}')"
no_answer pr-684
harvest_with_reply pr-684 'ACTION: park
REASON: 策略性搁置
REJECTED: close'
jq -e '.units[0] | (has("arbiter_no_answer") or has("arbiter_retry_after")) | not' "$UNITS" >/dev/null || fail "a decision must clear the streak"

# A cap RULE refills the stop-loss budget once and releases the stop-loss hold: 2295 was sent straight back by a wall counted from before its ruling.
old_write='{stage:"write-start",at:"2026-10-01T00:00:00Z",work_type:"repair"},{stage:"write-end",at:"2026-10-01T05:00:00Z"}'
budget_of() { TICKET_WALL_BUDGET_SECONDS=14400 NOW_EPOCH="$(date +%s)" TICKET_ROUND_BUDGET=3 ticket_budget_reason "$(jq -c --arg id "$1" '.units[] | select(.id==$id)' "$UNITS")"; }
stop_loss_hold() { jq -n '{state:"on-hold",hold:{kind:"stop-loss",holder:"scheduler-stop-loss"},recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/$1.json"; }
refills() { field "$1" '[.history[] | select(.stage=="supervisor-cap-budget-refill")] | length'; }
units "$(jq -cn "{units:[{id:\"pr-690\",issue:690,pr:690,lane:\"pr\",branch:\"agent/issue-690\",stage:\"supervisor-review\",supervisor_cap_return_stage:\"repair-pending\",history:[$old_write]}]}")"
stop_loss_hold 690
[[ -n "$(budget_of pr-690)" ]] || fail "the fixture must trip the wall"
printf 'REASON: r\nEVIDENCE: e\nVERDICT: RULE\n' > "$report"
supervisor_apply_cap_verdict pr-690 "$report" RULE
[[ "$(field pr-690 .stage)" == repair-pending && -z "$(budget_of pr-690)" && "$(refills pr-690)" == 1 ]] || fail "the first cap RULE must return the unit with a refilled budget: $(jq -c '.units[0]' "$UNITS")"
jq -e '.state == "ready-for-agent" and .hold == null' "$AGENT_HOME/state/690.json" >/dev/null || fail "RULE must release the stop-loss hold: $(cat "$AGENT_HOME/state/690.json")"
# A later cap RULE, retry or not, gets no second refill: RULE, fail, RULE cannot outrun the budget.
set_unit pr-690 ".history += [$old_write] | .stage=\"supervisor-review\" | .supervisor_cap_retry=\"pending\""
stop_loss_hold 690
supervisor_apply_cap_verdict pr-690 "$report" RULE
[[ "$(refills pr-690)" == 1 && -n "$(budget_of pr-690)" ]] || fail "a second cap RULE must not refill the budget: $(budget_of pr-690)"
# A RULE that never ran a round did not spend the retry, once: 2295's shape, retry spent, stopped in the tick of its RULE.
unrun_unit() { units "$(jq -cn --arg id "$1" --argjson n "$2" "{units:[{id:\$id,issue:\$n,pr:\$n,lane:\"pr\",branch:\"agent/issue-\(\$n)\",stage:\"supervisor-review\",supervisor_cap_return_stage:\"repair-pending\",supervisor_cap_retry:\"spent\",history:[$old_write,{stage:\"supervisor-cap-rule\"},{stage:\"supervisor-cap-rule\"},{stage:\"supervisor-arbiter-round\"},{stage:\"supervisor-escalated\",result:\"stop-loss: wall 1688min of 240min\"}]}]}")"; stop_loss_hold "$2"; }
unrun_unit pr-689 689
supervisor_apply_cap_verdict pr-689 "$report" RULE
[[ "$(field pr-689 .stage)" == repair-pending && "$(refills pr-689)" == 1 && -z "$(budget_of pr-689)" ]] || fail "a RULE stopped before its round must get its refill: $(jq -c '.units[0]' "$UNITS")"
set_unit pr-689 '.stage="supervisor-review"'
supervisor_apply_cap_verdict pr-689 "$report" RULE
[[ "$(field pr-689 .parked_reason)" == supervisor-cap-exhausted ]] || fail "the refill is one per unit: a later RULE with its retry spent must park: $(jq -c '.units[0]' "$UNITS")"
# A RULE that returned to review did run, whatever the rows after it: 5464 went supervisor-escalated then review-approve, 4330 was requeued.
for rows in '[{"stage":"supervisor-arbiter-round"}]' '[{"stage":"supervisor-escalated","result":"stop-loss: wall"},{"stage":"review-approve"}]' '[{"stage":"supervisor-escalated","result":"stop-loss: wall"},{"stage":"supervisor-requeue"}]' '[{"stage":"supervisor-escalated","result":"missing report"}]'; do
  supervisor_cap_rule_unrun "$(jq -cn --argjson rows "$rows" '{history:([{stage:"supervisor-cap-rule"}] + $rows)}')" && fail "this RULE ran: $rows"
done
unrun_unit pr-684 684
set_unit pr-684 '.history += [{stage:"rereview-pending"}]'
supervisor_apply_cap_verdict pr-684 "$report" RULE
[[ "$(field pr-684 .parked_reason)" == supervisor-cap-exhausted && "$(refills pr-684)" == 0 ]] || fail "a RULE that returned to rereview used its retry: $(jq -c '.units[0]' "$UNITS")"
# Another holder's hold stays, and the unit stays at supervisor-review.
unrun_unit pr-683 683
jq -n '{state:"on-hold",hold:{kind:"manual",holder:"head-hold"},recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/683.json"
printf 'REASON: r\nEVIDENCE: e\nVERDICT: RULE\n' > "$report"
supervisor_apply_cap_verdict pr-683 "$report" RULE
[[ "$(field pr-683 .stage)" == supervisor-review ]] || fail "a RULE must not send work past another holder's hold"
jq -e '.hold.holder == "head-hold"' "$AGENT_HOME/state/683.json" >/dev/null || fail "another holder's hold must stay"
# A held RULE is a recorded decision so the dispatch-only mark guard keeps it from spending another arbiter run.
units "$(jq -cn '{units:[{id:"pr-682",issue:683,pr:682,lane:"pr",branch:"agent/issue-682",stage:"supervisor-review",supervisor_cap_return_stage:"repair-pending",history:[{stage:"supervisor-arbiter",result:"dispatched to profile terra"}]}]}')"
printf '%s\n' '{"state":"on-hold","hold":{"kind":"manual","holder":"head-hold"}}' > "$AGENT_HOME/state/683.json"
printf 'REASON: r\nEVIDENCE: e\nVERDICT: RULE\n' > "$sup/supervise-pr-682-held-rule.md"
harvest_supervisor_arbiter "$(jq -cn '{pid:99999997,unit:"pr-682",type:"supervise",log:"none.log",report:"supervise-pr-682-held-rule.md",started:"2026-10-27T00:00:00Z",cap_triage:true}')"
[[ "$(field pr-682 .stage)" == supervisor-review ]] || fail "a held RULE must leave the unit in supervisor-review"
[[ "$(field pr-682 '.history[-1].stage')" == supervisor-cap-rule-held ]] || fail "a held RULE must write the decision history entry"
held_mark="$(field pr-682 .arbiter_left_mark)"
[[ -n "$held_mark" ]] || fail "a held RULE must record its left mark"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 dispatch_supervisor_arbiters
! jq -e 'any(.workers[]; .type=="supervise" and .unit=="pr-682")' "$WORKERS" >/dev/null || fail "a held RULE must not dispatch again while its mark is unchanged"
[[ "$(field pr-682 .arbiter_left_mark)" == "$held_mark" ]] || fail "a held RULE must retain its mark"
# Only a RULE releases the hold.
unrun_unit pr-688 688
founder_report "Please decide this?"
supervisor_apply_cap_verdict pr-688 "$report" FOUNDER
jq -e '.state == "on-hold"' "$AGENT_HOME/state/688.json" >/dev/null || fail "FOUNDER must leave the stop-loss hold"
printf 'REASON: r\nEVIDENCE: e\nVERDICT: CLOSE\n' > "$report"
unrun_unit pr-687 687
supervisor_apply_cap_verdict pr-687 "$report" CLOSE
jq -e '.state == "on-hold"' "$AGENT_HOME/state/687.json" >/dev/null || fail "CLOSE must leave the stop-loss hold"
printf 'REASON: r\nEVIDENCE: e\nVERDICT: RULE\n' > "$report"
# A failed release leaves the unit where it is.
unrun_unit pr-686 686
(REPO=""; ZF_REPO=""; if supervisor_apply_cap_verdict pr-686 "$report" RULE; then fail "a failed release must report failure"; fi)
[[ "$(field pr-686 .stage)" == supervisor-review && "$(refills pr-686)" == 0 ]] || fail "a hold that was not released must not apply the RULE"

# A terminal park unparks only when its mark changes.
units "$(jq -cn '{units:[{id:"pr-696",lane:"pr",stage:"parked",parked_reason:"supervisor-cap-exhausted",reviewed_pr_head:"aaa",supervisor_cap_retry:"spent",unpark_condition:"x",cap_exhausted_mark:"aaa||0",history:[]}]}')"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 dispatch_supervisor_arbiters
[[ "$(field pr-696 .parked_reason)" == supervisor-cap-exhausted ]] || fail "an unchanged terminal park must stay parked"
# An issue whose state cannot be read keeps the unit parked, though the mark reads as changed.
units "$(jq -cn '{units:[{id:"pr-693",issue:693,lane:"pr",stage:"parked",parked_reason:"supervisor-cap-exhausted",reviewed_pr_head:"aaa",supervisor_cap_retry:"spent",cap_exhausted_mark:"aaa|on-hold|0",history:[]}]}')"
(scheduler_issue_state() { return 1; }; SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 dispatch_supervisor_arbiters)
[[ "$(field pr-693 .parked_reason)" == supervisor-cap-exhausted ]] || fail "an unreadable issue state must not unpark"
units "$(jq -cn '{units:[{id:"pr-696",lane:"pr",stage:"parked",parked_reason:"supervisor-cap-exhausted",reviewed_pr_head:"bbb",supervisor_cap_retry:"spent",unpark_condition:"x",cap_exhausted_mark:"aaa||0",history:[]}]}')"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_CAP_TRIAGE=false dispatch_supervisor_arbiters
jq -e '.units[0] | .parked_reason=="supervisor-arbitration-cap" and (has("supervisor_cap_retry") | not) and (has("unpark_condition") | not)' "$UNITS" >/dev/null \
  || fail "a changed head must unpark a terminal park and reset its retry: $(jq -c '.units[0]' "$UNITS")"

# Route first: a refused recut route must leave the PR open, or the slice is left with no owner.
route_calls="$fixture/route-calls"; : > "$route_calls"
scheduler_route_to_recut() { printf 'route ' >> "$route_calls"; [[ "$ROUTE_RC" == 0 ]] || { echo 'refused tracker parent' >&2; return 1; }; }
tick_prs_changed() { :; }
tick_pr_state() { printf 'OPEN\n'; }
gh() { [[ "$1 $2" != 'pr close' ]] || printf 'close ' >> "$route_calls"; return 0; }
rm -rf "$WT_ROOT/wt-pr-651"
printf '%s\n' "$(jq -cn '{units:[{id:"pr-651",issue:651,pr:651,stage:"supervisor-review",history:[]}]}')" > "$UNITS"
ROUTE_RC=1 supervisor_budget_recut pr-651 "too large" null "cap triage could not complete the recut route" "recut" supervisor-cap-triage-park supervisor-cap-triage-recut true
[[ "$(cat "$route_calls")" == 'route ' && "$(field pr-651 .stage)" == parked ]] || fail "a refused route must park and keep the PR: calls=$(cat "$route_calls") stage=$(field pr-651 .stage)"
[[ "$(field pr-651 .note)$(jq -c '.units[0].history' "$UNITS")" == *'recut route failed'* ]] || fail 'the park must name the refused route'
: > "$route_calls"
printf '%s\n' "$(jq -cn '{units:[{id:"pr-651",issue:651,pr:651,stage:"supervisor-review",history:[]}]}')" > "$UNITS"
ROUTE_RC=0 supervisor_budget_recut pr-651 "too large" null "cap triage could not complete the recut route" "recut" supervisor-cap-triage-park supervisor-cap-triage-recut true
[[ "$(cat "$route_calls")" == 'route close ' && "$(field pr-651 .stage)" == closed ]] || fail "the PR closes only after the route: calls=$(cat "$route_calls") stage=$(field pr-651 .stage)"

# A failed close keeps the route on record, and the retry on that unit skips the refused route and closes.
: > "$route_calls"
gh() { [[ "$1 $2" != 'pr close' ]] || { printf 'close ' >> "$route_calls"; [[ "${CLOSE_RC:-0}" == 0 ]]; return; }; return 0; }
printf '%s\n' "$(jq -cn '{units:[{id:"pr-651",issue:651,pr:651,stage:"supervisor-review",history:[]}]}')" > "$UNITS"
ROUTE_RC=0 CLOSE_RC=1 supervisor_budget_recut pr-651 "too large" null "cap triage could not complete the recut route" "recut" supervisor-cap-triage-park supervisor-cap-triage-recut true
[[ "$(field pr-651 .recut_routed)" == true && "$(field pr-651 .stage)" == parked ]] || fail "a failed close must keep the route on record: $(jq -c '.units[0]' "$UNITS")"
: > "$route_calls"
ROUTE_RC=1 supervisor_budget_recut pr-651 "too large" null "cap triage could not complete the recut route" "recut" supervisor-cap-triage-park supervisor-cap-triage-recut true
[[ "$(cat "$route_calls")" == 'close ' && "$(field pr-651 .stage)" == closed ]] || fail "the retry must skip the route and close: calls=$(cat "$route_calls") stage=$(field pr-651 .stage)"

# ---- 终身仲裁上限（supervisor_arbiter.unit_cap，默认 4）：触顶不派模型，调度器当拍自己给默认决定 ----
# 上限按整份历史数 supervisor-arbiter 事件（忽略 supervisor-arbiter-round 轮标记），先于两轮预算与
# 每日天花板；已给过默认决定（历史有 supervisor-cap-default）的单元不再来第二次。
arb_hist() { # n → n 条 supervisor-arbiter 事件并穿插轮标记，终身计数不能看轮数
  jq -cn --argjson n "$1" '[range($n) as $i
    | {stage:"supervisor-arbiter",result:"dispatched",at:"2026-10-26T00:00:00Z"},
      {stage:"supervisor-arbiter-round",result:("round " + ($i|tostring)),at:"2026-10-26T00:01:00Z"}]'
}
route2="$fixture/route-calls-2"; : > "$route2"
scheduler_route_to_recut() { printf 'route ' >> "$route2"; [[ "${ROUTE_RC:-0}" == 0 ]] || { echo 'refused tracker parent' >&2; return 1; }; }
tick_prs_changed() { :; }
tick_pr_state() { printf 'OPEN\n'; }
close_calls="$fixture/close-calls"; : > "$close_calls"
gh() {
  case "$1 $2" in
    'issue close') printf 'issue-close: %s\n' "$*" >> "$close_calls"; return 0 ;;
    'pr close') printf 'pr-close: %s\n' "$*" >> "$close_calls"; [[ "${RECUT_CLOSE_RC:-0}" == 0 ]] && return 0; return 1 ;;
    'issue comment') printf 'issue-comment: %s\n' "$*" >> "$close_calls"; return 0 ;;
    'pr comment') return 0 ;;
  esac
  return 0
}
default_unit() { # id issue extra-fields-json extra-history-json → 一个 supervisor-review 单元，带 N 条仲裁历史
  printf '%s\n' "$(jq -cn --arg id "$1" --argjson issue "$2" --argjson extra "$3" --argjson past "$4" \
    --argjson arbs "$(arb_hist "${5:-4}")" \
    '{units:[({id:$id,issue:$issue,pr:$issue,lane:"pr",stage:"supervisor-review"} + $extra)
      | .history = ($arbs + $past + [{stage:"supervisor-escalated",result:"stop-loss: wall 300min of 240min after 3 rounds",at:"2026-10-27T00:00:00Z"}])]}' )" > "$UNITS"
  echo '{"workers":[]}' > "$WORKERS"
}
drop_unit_pr() { jq '(.units[0] |= del(.pr))' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"; }
cap_default_stage() { jq -r --arg id "$1" '.units[] | select(.id==$id) | .stage' "$UNITS"; }
cap_default_history() { jq -r --arg id "$1" --arg stage "$2" '[.units[] | select(.id==$id) | .history[] | select(.stage==$stage)] | length' "$UNITS"; }

# 上限以下（1 条）照旧派模型：上限是边界，不是新刹车。
default_unit pr-634 634 '{}' '[]' 1
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
jq -e 'any(.workers[]; .type=="supervise" and .unit=="pr-634")' "$WORKERS" >/dev/null \
  || fail "a unit under the lifetime cap must still dispatch: $(jq -c '.units' "$UNITS")"

# 分支 a：issue 已结论/进发布，或工作已在别处合入 → 按既有 obsolete 词汇关单元，不动 issue 和 PR。
default_unit pr-630 630 '{}' '[]' 4
jq -n '{state:"concluded",run:{outcome:"merged"}}' > "$AGENT_HOME/state/630.json"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
! jq -e 'any(.workers[]; .unit=="pr-630")' "$WORKERS" >/dev/null || fail "a unit at the lifetime cap must cost no model run"
[[ "$(cap_default_stage pr-630)" == closed ]] || fail "branch a must close the unit: $(jq -c '.units[0]' "$UNITS")"
[[ "$(cap_default_history pr-630 obsolete)" == 1 && "$(cap_default_history pr-630 supervisor-cap-default)" == 1 ]] \
  || fail "branch a must record obsolete + supervisor-cap-default: $(jq -c '.units[0].history[-2:]' "$UNITS")"
[[ "$(field pr-630 '.history[-1].result')" == branch=obsolete:* ]] || fail "the default-decision entry must name its branch"
! grep -q 'issue-close' "$close_calls" || fail "branch a must not touch an already-concluded issue"

# 分支 a 也包括 GitHub issue 已关闭；不能把它重新送进 recut。
default_unit pr-636 636 '{}' '[]' 4
jq -n '{state:"closed"}' > "$AGENT_HOME/state/636.json"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cap_default_history pr-636 supervisor-cap-default)" == 1 ]] || fail "a closed issue must take the obsolete default branch"
[[ "$(field pr-636 '.history[-1].result')" == branch=obsolete:* ]] || fail "a closed issue must be recorded as obsolete"

# 分支 b（从未走过 recut，单元没有 PR）：走既有 supervisor_budget_recut 一次，路由后单元关闭。
default_unit pr-631 631 '{}' '[]' 4
drop_unit_pr
jq -n '{state:"ready-for-agent",recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/631.json"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cat "$route2")" == 'route ' ]] || fail "branch b must take the existing recut route once: calls=$(cat "$route2")"
[[ "$(cap_default_stage pr-631)" == closed ]] || fail "a routed recut closes the unit: $(jq -c '.units[0]' "$UNITS")"
[[ "$(cap_default_history pr-631 supervisor-cap-triage-recut)" == 1 && "$(field pr-631 '.history[-1].result')" == branch=recut:* ]] \
  || fail "branch b must record the recut route and the default decision: $(jq -c '.units[0].history[-2:]' "$UNITS")"

# 分支 b（最近一次有效终局裁决是 RECUT）：即使更早走过一次预算 recut，仍按 RECUT 再走一次。
default_unit pr-632 632 '{"supervisor_cap_verdict":"RECUT"}' '[{"stage":"supervisor-budget-recut","result":"r","at":"2026-10-25T00:00:00Z"}]' 4
drop_unit_pr
jq -n '{state:"ready-for-agent",recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/632.json"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cat "$route2")" == 'route route ' ]] || fail "a RECUT verdict must take the recut route: calls=$(cat "$route2")"

# 单元有 PR：默认决定绝不关 PR，也不把 issue 送走，只停车。
default_unit pr-640 640 '{}' '[]' 4
jq -n '{state:"ready-for-agent",attempts:0,recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/640.json"
: > "$close_calls"; : > "$route2"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cap_default_stage pr-640)" == parked && "$(field pr-640 '.history[-1].result')" == branch=park:* ]] \
  || fail "a capped unit with a PR must park: $(jq -c '.units[0]' "$UNITS")"
[[ ! -s "$close_calls" && ! -s "$route2" ]] || fail "a capped unit with a PR must touch neither PR nor issue: $(cat "$close_calls" "$route2")"

# 分支 c：已 recut 过、最后的裁决不是 RECUT → 只停车记录，issue 和 PR 都不动。
default_unit pr-633 633 '{"supervisor_cap_verdict":"RULE"}' '[{"stage":"supervisor-cap-triage-recut","result":"r","at":"2026-10-26T01:00:00Z"}]' 4
jq -n '{state:"ready-for-agent",attempts:0,recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/633.json"
: > "$close_calls"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cap_default_stage pr-633)" == parked && "$(field pr-633 '.history[-1].result')" == branch=park:* ]] \
  || fail "branch c must park the unit: $(jq -c '.units[0]' "$UNITS")"
[[ "$(jq -r '.run.outcome // empty' "$AGENT_HOME/state/633.json")" == '' ]] || fail "branch c must not conclude the issue: $(cat "$AGENT_HOME/state/633.json")"
[[ ! -s "$close_calls" && ! -s "$route2" ]] || fail "branch c must touch neither PR nor issue: $(cat "$close_calls" "$route2")"
! grep -q 'cap-triage-founder unit=pr-63' "$AGENT_HOME/supervisor-inbox" || fail "the default decision must never reach the founder"

# 一次性：已有 supervisor-cap-default 的触顶单元不再重复给默认决定，也不派模型。
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cap_default_history pr-633 supervisor-cap-default)" == 1 ]] || fail "the default decision must run once per unit"
! jq -e 'any(.workers[]; .unit=="pr-633")' "$WORKERS" >/dev/null || fail "a handled capped unit must never dispatch again"

# Row 150 (issue-4879): after its default, a capped unit that re-enters supervisor-review closes with a durable hold.
cap_hold_stub="$fixture/cap-hold-stub"; cap_hold_calls="$fixture/cap-hold-calls"; mkdir -p "$cap_hold_stub"; : > "$cap_hold_calls"
printf '#!/usr/bin/env bash\nprintf "hold %%s\\n" "$*" >> %q\n' "$cap_hold_calls" > "$cap_hold_stub/hold.sh"
jq '(.units[0] |= (.stage = "supervisor-review" | .history += [{stage:"supervisor-escalated",result:"ci cancelled again",at:"2026-10-27T05:00:00Z"}]))' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
ZF_ENGINE_DIR="$cap_hold_stub" SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cap_default_stage pr-633)" == closed && "$(cap_default_history pr-633 supervisor-cap-default)" == 1 \
  && "$(cap_default_history pr-633 supervisor-close)" == 1 ]] \
  || fail "a capped unit back at supervisor-review after its default must close durably: $(jq -c '.units[0]' "$UNITS")"
grep -q '^hold --hold 633 ' "$cap_hold_calls" || fail "a repeated cap must hold issue 633: $(cat "$cap_hold_calls")"
! jq -e 'any(.workers[]; .unit=="pr-633")' "$WORKERS" >/dev/null || fail "the re-entry default must cost no model run"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cap_default_history pr-633 supervisor-cap-default)" == 1 ]] || fail "the repeated cap must not add a second default decision"

# A held issue gets no default and no model run; the default applies on the first tick after the hold ends.
default_unit pr-642 642 '{}' '[]' 4
jq -n '{state:"on-hold",hold:{kind:"stop-loss",expires_at:"2099-01-01T00:00:00Z"}}' > "$AGENT_HOME/state/642.json"
: > "$close_calls"; : > "$route2"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cap_default_stage pr-642)" == supervisor-review && "$(cap_default_history pr-642 supervisor-cap-default)" == 0 ]] \
  || fail "a held unit must get no default decision: $(jq -c '.units[0]' "$UNITS")"
! jq -e 'any(.workers[]; .unit=="pr-642")' "$WORKERS" >/dev/null || fail "a held capped unit must cost no model run"
[[ ! -s "$close_calls" && ! -s "$route2" ]] || fail "a held unit must touch neither PR nor issue: $(cat "$close_calls" "$route2")"
jq -n '{state:"ready-for-agent",recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/642.json"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cap_default_history pr-642 supervisor-cap-default)" == 1 ]] || fail "the default must apply once the hold ends: $(jq -c '.units[0]' "$UNITS")"

# An unreadable issue state may hide a hold, so nothing is decided that tick.
default_unit pr-643 643 '{}' '[]' 4
saved_issue_state="$(declare -f scheduler_issue_state)"
scheduler_issue_state() { return 1; }
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
eval "$saved_issue_state"
[[ "$(cap_default_stage pr-643)" == supervisor-review && "$(cap_default_history pr-643 supervisor-cap-default)" == 0 ]] \
  || fail "an unreadable state must decide nothing: $(jq -c '.units[0]' "$UNITS")"

# A refused recut route parks the unit in the same tick, with no founder handoff.
default_unit pr-638 638 '{}' '[]' 4
drop_unit_pr
jq -n '{state:"ready-for-agent",attempts:0,recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/638.json"
: > "$close_calls"; : > "$route2"
ROUTE_RC=1 SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
unset ROUTE_RC
[[ "$(cat "$route2")" == 'route ' ]] || fail "a failed cap recut must be attempted once: calls=$(cat "$route2")"
[[ "$(cap_default_stage pr-638)" == parked && "$(field pr-638 '.history[-1].result')" == branch=park:* ]] \
  || fail "a refused cap recut must park: $(jq -c '.units[0]' "$UNITS")"
[[ ! -s "$close_calls" ]] || fail "a refused cap recut must not close anything: $(cat "$close_calls")"
! grep -q 'cap-triage-founder unit=pr-638\|recut-refused unit=pr-638' "$AGENT_HOME/supervisor-inbox" \
  || fail "a cap default recut refusal must not create a founder handoff"

# Unpushed work also blocks recut; cap default records the refusal without an inbox handoff.
default_unit pr-639 639 '{}' '[]' 4
drop_unit_pr
jq -n '{state:"ready-for-agent",attempts:0,recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/639.json"
rm -rf "$WT_ROOT/wt-pr-639"; mkdir -p "$WT_ROOT/wt-pr-639"
git -C "$WT_ROOT/wt-pr-639" init -q
git -C "$WT_ROOT/wt-pr-639" -c user.name=t -c user.email=t@t commit -q --allow-empty -m fixture
: > "$close_calls"; : > "$route2"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cat "$route2")" == '' ]] || fail "unpushed work must not reach the recut route"
[[ "$(cap_default_stage pr-639)" == parked && "$(field pr-639 '.history[-1].result')" == branch=park:* ]] \
  || fail "unpushed cap recut must park: $(jq -c '.units[0]' "$UNITS")"
! grep -q 'recut-refused unit=pr-639' "$AGENT_HOME/supervisor-inbox" || fail "unpushed cap default must not create a founder handoff"

# An issue-level recut refusal survives a new unit and makes the cap default park without routing recut again.
default_unit pr-644 644 '{}' '[]' 4
drop_unit_pr
refused_at="$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg refused_at "$refused_at" '{state:"ready-for-agent",guarded:true,recut_refused_at:$refused_at}' > "$AGENT_HOME/state/644.json"
: > "$route2"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ ! -s "$route2" && "$(cap_default_stage pr-644)" == parked && "$(field pr-644 '.history[-1].result')" == branch=park:* ]] \
  || fail "a recent issue-level recut refusal must park a fresh capped unit without routing recut"

# Legacy issue units recover their ticket number, so a hold on the issue still protects them.
[[ "$(supervisor_cap_default_issue '{"id":"issue-641"}')" == 641 ]] || fail "the canonical issue unit id must recover its issue number"
[[ "$(supervisor_cap_default_issue '{"id":"pr-1641","branch":"agent/issue-641-fix"}')" == 641 ]] \
  || fail "an issue branch with a suffix must recover its issue number"
default_unit pr-1641 641 '{}' '[]' 4
jq '(.units[0] |= (del(.issue, .pr) | .branch="agent/issue-641-fix"))' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
jq -n '{state:"on-hold",hold:{kind:"stop-loss"}}' > "$AGENT_HOME/state/641.json"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cap_default_history pr-1641 supervisor-cap-default)" == 0 ]] || fail "a hold found through the branch must also stop the default"

# A full in-flight cap must not postpone default decisions for already-capped units.
default_unit pr-637 637 '{}' '[]' 4
jq -n '{state:"ready-for-agent",recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/637.json"
echo '{"workers":[{"unit":"other","type":"supervise","harvested":false}]}' > "$WORKERS"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=1 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cap_default_history pr-637 supervisor-cap-default)" == 1 ]] \
  || fail "a capped unit must take its default decision even when another arbiter fills the worker cap"
# Repeat guard: the same normalised escalation reason with no progress since the previous arbiter run takes the spent-budget route
# in the same tick, with no model run and no supervisor-cap-default event, and that route's own event carries the counted prefix.
repeat_unit() { # id issue extra-fields-json progress-stage-between(optional) second-reason → supervisor-review unit on its second identical escalation
  printf '%s\n' "$(jq -cn --arg id "$1" --argjson issue "$2" --argjson extra "$3" --arg between "${4:-}" --arg second "${5:-implement delivered no changes in the assigned worktree twice: agent/issue-9002 (report impl-9002-20261107T080000Z.md)}" \
    '{units:[({id:$id,issue:$issue,lane:"pr",stage:"supervisor-review"} + $extra)
      | .history = ([{stage:"supervisor-escalated",result:"implement delivered no changes in the assigned worktree twice: agent/issue-9001 (report impl-9001-20261106T080000Z.md)",at:"2026-11-07T01:00:00Z"},
                     {stage:"supervisor-arbiter",result:"dispatched",at:"2026-11-07T01:05:00Z"},
                     {stage:"supervisor-requeue",result:"retry",at:"2026-11-07T01:10:00Z"}]
          + (if $between == "" then [] else [{stage:$between,result:"",at:"2026-11-07T01:20:00Z"}] end)
          + [{stage:"supervisor-escalated",result:$second,at:"2026-11-07T02:00:00Z"}])]}')" > "$UNITS"
  echo '{"workers":[]}' > "$WORKERS"
}
repeat_dispatch() { SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters; }
repeat_hist() { jq -r --arg stage "$1" '[.units[0].history[] | select(.stage==$stage)] | length' "$UNITS"; }
jq -n '{state:"ready-for-agent",recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/9002.json"
: > "$close_calls"; : > "$route2"
repeat_unit pr-9002 9002 '{"pr":9002}'
supervisor_repeat_arbitration "$(jq -c '.units[0]' "$UNITS")" || fail "same reason, digits and SHAs apart, no progress: must be a repeat"
repeat_dispatch
! jq -e 'any(.workers[]; .unit=="pr-9002")' "$WORKERS" >/dev/null || fail "a repeat must cost no model run"
[[ "$(repeat_hist supervisor-arbiter)" == 1 && "$(repeat_hist supervisor-cap-default)" == 0 ]] || fail "a repeat adds no arbiter or cap-default event: $(jq -c '.units[0].history' "$UNITS")"
[[ "$(field pr-9002 .stage)" == parked && "$(cat "$route2")" == '' && "$(field pr-9002 '.history[-1].stage')" == supervisor-cap-triage-park && "$(field pr-9002 '.history[-1].result')" == 'supervisor repeat guard: '* ]] \
  || fail "a repeat on a unit with a PR must park through the cap route and name itself: $(jq -c '.units[0].history[-1]' "$UNITS")"
# No PR and never recut: the same route cap default takes, one recut.
repeat_unit pr-9003 9003 '{}'; drop_unit_pr
jq -n '{state:"ready-for-agent",recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/9003.json"
: > "$route2"; repeat_dispatch
[[ "$(cat "$route2")" == 'route ' && "$(field pr-9003 .stage)" == closed && "$(field pr-9003 '.history[-1].stage')" == supervisor-cap-triage-recut && "$(field pr-9003 '.history[-1].result')" == 'supervisor repeat guard: '* ]] \
  || fail "a repeat on a unit with no PR must take the recut route once: $(jq -c '.units[0]' "$UNITS")"
# Progress between the two runs, a different reason, or no earlier run: dispatch as before.
for progress in repair-delivered review-approve merged pr-opened; do
  repeat_unit pr-9004 9004 '{}' "$progress"
  ! supervisor_repeat_arbitration "$(jq -c '.units[0]' "$UNITS")" || fail "$progress between the runs is progress, not a repeat"
done
repeat_unit pr-9004 9004 '{}' '' 'size admission: 912 changed lines write-start (diff) exceed the 800-line limit'
! supervisor_repeat_arbitration "$(jq -c '.units[0]' "$UNITS")" || fail "a different reason is not a repeat"
jq -n '{state:"ready-for-agent",recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/9004.json"
repeat_dispatch
jq -e 'any(.workers[]; .unit=="pr-9004")' "$WORKERS" >/dev/null || fail "a first-time reason must still dispatch: $(jq -c '.units[0]' "$UNITS")"
jq -cn '{units:[{id:"pr-9005",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"x 1",at:"2026-11-07T01:00:00Z"}]}]}' > "$UNITS"
! supervisor_repeat_arbitration "$(jq -c '.units[0]' "$UNITS")" || fail "no earlier arbiter run is not a repeat"
jq -cn '{units:[{id:"pr-9005",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:"x 1",at:"2026-11-07T01:00:00Z"},{stage:"supervisor-arbiter",at:"2026-11-07T01:05:00Z"}]}]}' > "$UNITS"
! supervisor_repeat_arbitration "$(jq -c '.units[0]' "$UNITS")" || fail "a run already made for this escalation is not a repeat"

# Size recut without a person. (1) A held recut lifts on its own once the hold is gone, whatever state the issue came back in;
# a live hold keeps it parked. (2) An on-hold issue counts as routed (the recut waits behind the hold) instead of going to the
# supervisor. (3) A head sent to recut before routes again, unless that recut was refused.
issue_states="$fixture/issue-states"; mkdir -p "$issue_states"
scheduler_issue_state() { cat "$issue_states/$1.json"; }

# A requeue that observes a tracker parent closes by the shared recut path;
# ready-for-agent is already the desired state; only an explicit transition refusal parks.
saved_requeue_transition="$(declare -f scheduler_issue_transition)"
saved_requeue_repo="${REPO:-}"
REPO=ZenoWangzy/zenoforge
REQUEUE_TRANSITIONS="$fixture/requeue-transitions"; : > "$REQUEUE_TRANSITIONS"
scheduler_issue_transition() {
  printf '%s:%s\n' "$1" "$2" >> "$REQUEUE_TRANSITIONS"
  if [[ "$1" == 9407 ]]; then return 0; fi
  [[ "$1" != 9403 ]] || printf 'issue_transition: refused #9403 needs-advisor -> active state ready-for-agent (reason=supervisor-requeue)\n' >&2
  return 1
}
requeue_test_unit() {
  units "$(jq -cn --arg id "$1" --argjson issue "$2" --argjson pr "$3" --argjson followup "${4:-null}" '{units:[{id:$id,issue:$issue,pr:$pr,split_followup:$followup,lane:"pr",branch:("agent/"+$id),stage:"supervisor-review",history:[{stage:"review-request-changes",result:"F1",at:"2026-11-08T00:00:00Z"},{stage:"supervisor-escalated",result:"test requeue",at:"2026-11-08T00:01:00Z"}]}]}')"
}
requeue_decision="$(decision_entry 'Supervisor arbitration: requeue' 'resume work' 'synthetic requeue failure case' '[]' supervisor)"

printf '%s\n' '{"state":"tracker","recut_children":[9404]}' > "$issue_states/9401.json"
requeue_test_unit arbiter-tracker 9401 99401
supervisor_requeue_unit arbiter-tracker requeue "resume the child work" "$requeue_decision" || :
[[ "$(field arbiter-tracker .stage)" == closed ]] || fail "a tracker requeue must close the parent unit"
jq -e '.units[] | select(.id=="arbiter-tracker") | .history[-1].stage=="size-recut-completed" and (has("size_recut_pending")|not)' "$UNITS" >/dev/null \
  || fail "a tracker requeue must use the existing recut completion path"
grep -Fq 'supervisor arbitration unit=arbiter-tracker: issue #9401 became a tracker; closed the recut unit and left open PR #99401 for head to decide' "$LOG" \
  || fail "a tracker requeue must name its open PR for head"
[[ ! -s "$REQUEUE_TRANSITIONS" ]] || fail "a tracker requeue must not attempt an active-state transition"

# A tracked size-admission continuation keeps the first-slice PR in its normal
# requeue stage instead of closing it with the tracker parent.
followup_json="$(jq -cn --arg body '由 #9404 按尺寸准入拆分出的续作票：第一个可独立交付切片在 PR #99404 送评审。' '{number:9405,title:"continuation",body:$body,state:"OPEN",labels:[]}')"
followup_encoded="$(printf '%s' "$followup_json" | base64 | tr -d '\n')"
followup_rows="$(printf '9405\tpr\tcontinuation\t[]\t%s' "$followup_encoded")"
jq -cn --arg rows "$followup_rows" '{schema:4,created_at:(now|floor),rows:$rows}' > "$A/intake-candidates.json"
gh_calls_before="$(wc -l < "$GH_CALLS")"
printf '%s\n' '{"state":"tracker","recut_children":[9406]}' > "$issue_states/9404.json"
requeue_test_unit arbiter-cited 9404 99404 9405
supervisor_requeue_unit arbiter-cited requeue "resume the first slice" "$requeue_decision" || :
[[ "$(field arbiter-cited .stage)" == repair-pending ]] || fail "a cited first-slice PR must continue through the normal requeue target"
jq -e '.units[] | select(.id=="arbiter-cited") | .pr==99404 and .split_followup==9405 and .history[-1].stage=="supervisor-requeue"' "$UNITS" >/dev/null \
  || fail "a cited first-slice PR must stay attached to its requeued unit"
grep -Fq 'supervisor arbitration unit=arbiter-cited: issue #9404 became a tracker; continuation issue #9405 cites open PR #99404, carrying it to repair-pending' "$LOG" \
  || fail "a cited first-slice PR must log why it is being carried forward"
[[ "$(wc -l < "$GH_CALLS")" == "$gh_calls_before" ]] || fail "a fresh continuation cache must avoid an extra GitHub read"

printf '%s\n' '{"state":"ready-for-agent"}' > "$issue_states/9402.json"
requeue_test_unit arbiter-ready 9402 99402
supervisor_requeue_unit arbiter-ready requeue "resume the repair" "$requeue_decision" || :
[[ "$(field arbiter-ready .stage)" == repair-pending ]] || fail "an already-ready issue must complete the unit requeue"
[[ "$(field arbiter-ready '.history[-1].stage')" == supervisor-requeue ]] || fail "an already-ready issue must record the requeue verdict"
[[ ! -s "$REQUEUE_TRANSITIONS" ]] || fail "an already-ready issue must not retry a same-state transition"

printf '%s\n' '{"state":"needs-advisor"}' > "$issue_states/9403.json"
requeue_test_unit arbiter-failure 9403 99403
supervisor_requeue_unit arbiter-failure requeue "resume the repair" "$requeue_decision" || :
[[ "$(field arbiter-failure .stage)" == parked ]] || fail "a failed requeue transition must durably park the unit"
jq -e '.units[] | select(.id=="arbiter-failure") | .parked_reason=="supervisor-budget" and (.note|contains("issue #9403 could not be requeued to ready-for-agent")) and .history[-1].stage=="supervisor-requeue-failed"' "$UNITS" >/dev/null \
  || fail "the durable park must retain the transition failure as its reason"
jq -e '.units[] | select(.id=="arbiter-failure") | .note|contains("issue_transition: refused #9403")' "$UNITS" >/dev/null \
  || fail "the durable park must preserve the transition refusal"
grep -Fq '9403:ready-for-agent' "$REQUEUE_TRANSITIONS" || fail "the other-state case must exercise a failed transition"

printf '%s\n' '{"attempts":0}' > "$issue_states/9407.json"
requeue_test_unit arbiter-untracked 9407 99407
supervisor_requeue_unit arbiter-untracked requeue "resume the repair" "$requeue_decision" || :
[[ "$(field arbiter-untracked .stage)" == repair-pending ]] || fail "a missing issue state must continue the requeue"
grep -Fq '9407:ready-for-agent' "$REQUEUE_TRANSITIONS" || fail "a missing issue state must transition to ready-for-agent"

printf '%s\n' '{"state":""}' > "$issue_states/9408.json"
requeue_test_unit arbiter-empty-state 9408 99408
supervisor_requeue_unit arbiter-empty-state requeue "resume the repair" "$requeue_decision" || :
[[ "$(field arbiter-empty-state .stage)" == supervisor-review ]] || fail "an empty issue state must retry requeue"
! grep -Fq '9408:ready-for-agent' "$REQUEUE_TRANSITIONS" || fail "an empty issue state must not attempt the issue transition"

# A GitHub read failure is retryable: it leaves the arbitration unit in review.
printf '%s\n' '{"state":"needs-advisor"}' > "$issue_states/9406.json"
saved_requeue_gh="$(declare -f gh)"
gh() { printf 'gh %s\n' "$*" >> "$GH_CALLS"; return 1; }
requeue_test_unit arbiter-read-failed 9406 99406
harvest_with_reply arbiter-read-failed 'ACTION: requeue
REASON: resume reviewed work
EVIDENCE: synthetic transient GitHub read failure
REJECTED: park
GUIDANCE: retry the requeue' || :
eval "$saved_requeue_gh"
[[ "$(field arbiter-read-failed .stage)" == supervisor-review ]] \
  || fail "a failed gh issue view must leave the unit at supervisor-review for retry"
jq -e '.units[] | select(.id=="arbiter-read-failed") | has("arbiter_left_mark") | not' "$UNITS" >/dev/null \
  || fail "a failed gh issue view must not hold the next tick"
jq -e '.units[] | select(.id=="arbiter-read-failed") | all(.history[]; .stage != "supervisor-requeue-failed")' "$UNITS" >/dev/null \
  || fail "a failed gh issue view must not record a durable requeue-failure park"
grep -Fq 'gh issue view 9406 --repo ZenoWangzy/zenoforge --json number,title,body,state,labels' "$GH_CALLS" \
  || fail "the retry case must exercise gh issue view rc 1"
! grep -Fq '9406:ready-for-agent' "$REQUEUE_TRANSITIONS" \
  || fail "a failed gh issue view must not attempt the issue transition"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 dispatch_supervisor_arbiters
jq -e 'any(.workers[]; .type=="supervise" and .unit=="arbiter-read-failed")' "$WORKERS" >/dev/null \
  || fail "tick two must dispatch the unit again after its transient requeue failure"

# A non-stop-loss hold is a deterministic refusal and must park for the regular dead-park recovery route.
printf '%s\n' '{"state":"on-hold","hold":{"kind":"manual","holder":"head"}}' > "$issue_states/9407.json"
requeue_test_unit arbiter-nonstoploss 9407 99407
harvest_with_reply arbiter-nonstoploss 'ACTION: requeue
REASON: resume reviewed work
EVIDENCE: manual on-hold state
REJECTED: park
GUIDANCE: resume after the hold' || :
[[ "$(field arbiter-nonstoploss .stage)" == parked ]] \
  || fail "a non-stop-loss hold must durably park the requeue"
jq -e '.units[] | select(.id=="arbiter-nonstoploss") | .parked_reason=="supervisor-budget" and (.note|contains("issue #9407 has a non-stop-loss hold")) and .history[-1].stage=="supervisor-requeue-failed"' "$UNITS" >/dev/null \
  || fail "the non-stop-loss hold park must retain its reason"

# A deterministic requeue-failure park is eligible for the existing daily dead-park recut.
saved_dead_park_tick_prs="$(declare -f tick_prs)"
saved_dead_park_budget_recut="$(declare -f supervisor_budget_recut)"
DEAD_RECUT_CALLS="$fixture/dead-recut-calls"; : > "$DEAD_RECUT_CALLS"
tick_prs() { printf '%s\n' '[]'; }
supervisor_budget_recut() { printf '%s\t%s\n' "$1" "$2" >> "$DEAD_RECUT_CALLS"; }
units "$(jq -cn '{units:[{id:"arbiter-failed-park",issue:9403,pr:99403,lane:"pr",branch:"agent/arbiter-failed-park",stage:"parked",parked_reason:"supervisor-budget",note:"supervisor requeue failed",history:[{stage:"supervisor-requeue-failed",result:"issue #9403 could not be requeued to ready-for-agent: issue_transition: refused #9403 needs-advisor",at:"2026-11-08T00:00:00Z"}]}]}')"
dead_park_exit
[[ "$(cat "$DEAD_RECUT_CALLS")" == $'arbiter-failed-park\tdead park exit (budget-park)' ]] \
  || fail "a supervisor-requeue-failed park must use the existing dead-park recut route"
[[ "$(field arbiter-failed-park '.history[-1].stage')" == dead-park-exit ]] \
  || fail "the daily recovery attempt must be recorded in unit history"
eval "$saved_dead_park_tick_prs"
eval "$saved_dead_park_budget_recut"

eval "$saved_requeue_transition"
REPO="$saved_requeue_repo"

printf '%s\n' '{"state":"on-hold","hold":{"kind":"stop-loss"}}' > "$issue_states/701.json"
printf '%s\n' '{"state":"needs-recut","hold":null}' > "$issue_states/702.json"
printf '%s\n' '{"state":"needs-triage","hold":null}' > "$issue_states/703.json"
units "$(jq -cn '{units:[701,702,703] | map({id:("issue-"+tostring),issue:.,stage:"parked",size_recut_pending:true,note:("issue #"+tostring+" recut is on hold"),parked_reason:"on-hold",unpark_condition:"the on-hold label lifts",history:[]})}')"
reconcile_size_recuts
[[ "$(field issue-701 .stage)" == parked ]] || fail "a live hold must keep the size recut parked"
for u in issue-702 issue-703; do
  jq -e --arg id "$u" '.units[] | select(.id == $id) | .stage == "blocked-external" and .note == null and .size_recut_pending == true and (has("parked_reason") | not) and ([.history[].stage] | index("size-recut-unheld") != null)' "$UNITS" >/dev/null \
    || fail "$u: a lifted hold did not release the size recut: $(jq -c --arg id "$u" '.units[] | select(.id == $id)' "$UNITS")"
done

# A supervisor-review unit whose issue became a tracker closes (the arbiter cannot requeue a tracker, and its no-change hold
# would repeat that failure forever). Only that branch applies there: a ready issue leaves the unit with the arbiter.
printf '%s\n' '{"state":"tracker"}' > "$issue_states/704.json"
printf '%s\n' '{"state":"ready-for-agent"}' > "$issue_states/705.json"
units "$(jq -cn '{units:[704,705] | map({id:("issue-"+tostring),issue:.,stage:"supervisor-review",size_recut_pending:true,history:[]})}')"
reconcile_size_recuts
[[ "$(field issue-704 .stage)" == closed && "$(field issue-704 .size_recut_pending)" == null ]] \
  || fail "a tracker issue must close its supervisor-review size recut: $(jq -c '.units' "$UNITS")"
[[ "$(field issue-705 .stage)" == supervisor-review && "$(field issue-705 .size_recut_pending)" == true ]] \
  || fail "a supervisor-review unit with a ready issue must stay with the arbiter: $(jq -c '.units' "$UNITS")"

printf '%s\n' '{"state":"on-hold","hold":{"kind":"stop-loss"},"size_admission":{"lines":802,"limit":800}}' > "$fixture/recut-agent-state.json"
cat > "$fixture/recut-agent-lib.sh" <<LIB
route_to_recut() { return 0; }
state_read() { cat "$fixture/recut-agent-state.json"; }
LIB
( SCHEDULER_AGENT_LIB="$fixture/recut-agent-lib.sh"; scheduler_size_recut 705 802 800 issue-705 agent/issue-705 "$(printf 'a%.0s' {1..40})" ) \
  || fail "an on-hold issue with the recorded size evidence must count as routed"
printf '%s\n' '{"state":"ready-for-agent"}' > "$fixture/recut-agent-state.json"
( SCHEDULER_AGENT_LIB="$fixture/recut-agent-lib.sh"; ! scheduler_size_recut 705 802 800 issue-705 agent/issue-705 "$(printf 'a%.0s' {1..40})" ) \
  || fail "an issue the route left elsewhere must not count as routed"

head_a="$(printf 'a%.0s' {1..40})"
printf '%s\n' '{"state":"ready-for-agent"}' > "$issue_states/706.json"
printf '%s\n' '{"state":"ready-for-agent","recut_refused_at":"now"}' > "$issue_states/707.json"
for n in 706 707; do
  units "$(jq -cn --argjson n "$n" --arg head "$head_a" '{units:[{id:("issue-"+($n|tostring)),issue:$n,stage:"implement",history:[{stage:"size-recut",result:("head="+$head)}]}]}')"
  : > "$fixture/recut-calls"
  ( scheduler_size_recut() { echo routed >> "$fixture/recut-calls"; }; to_supervisor() { echo supervisor >> "$fixture/recut-calls"; }
    size_admission_reject "issue-$n" 802 agent/x "admission" "$head_a" "" 802 admission 800 ) || true
  [[ "$n" == 706 && "$(cat "$fixture/recut-calls")" == routed || "$n" == 707 && "$(cat "$fixture/recut-calls")" == supervisor ]] \
    || fail "issue $n: wrong size-admission route: $(cat "$fixture/recut-calls")"
done

# Starvation: more candidates than slots. A unit that was arbitrated comes back as a fresh escalation (requeue, repair delivers,
# review blocks again), so in units.json order the front units were re-picked every tick and the rest never ran
# (issue-5389 waited 14.5 h on 2026-11-08 with 55 of 55 picks ahead of it). Oldest-waiting first: every candidate runs within
# ceil(candidates / slots) ticks. The array is oldest-last, so array order and age order disagree.
n_cand=7 slots=2
: > "$fixture/starve-picks"
jq -cn --argjson n "$n_cand" '{units:[range($n; 0; -1) as $i | {id:("pr-91\($i)"),issue:(9100+$i),pr:(9100+$i),lane:"pr",stage:"supervisor-review",history:[{stage:"supervisor-escalated",result:("blocked by reason " + ("x" * $i)),at:("2026-11-08T01:0\($i):00Z")}]}]}' > "$UNITS"
echo '{"workers":[]}' > "$WORKERS"
for i in $(seq 1 "$n_cand"); do jq -n '{state:"ready-for-agent",recut_children:[],recut_comment_scanned:true}' > "$AGENT_HOME/state/910$i.json"; done
for tick in $(seq 1 "$(( (n_cand + slots - 1) / slots ))"); do
  SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX="$slots" SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
  picked="$(jq -r '[.workers[] | select(.type=="supervise") | .unit] | join(" ")' "$WORKERS")"
  [[ -n "$picked" ]] || fail "starvation tick $tick dispatched nothing: $(jq -c '[.units[] | {id,stage}]' "$UNITS")"
  [[ "$tick" != 1 || "$picked" == "pr-911 pr-912" ]] || fail "first tick must take the two oldest escalations, got: $picked"
  printf '%s\n' $picked >> "$fixture/starve-picks"
  # The worker ends; each picked unit re-escalates later than every unit still waiting.
  for id in $picked; do
    jq --arg id "$id" --arg at "$(printf '2026-11-08T%02d:00:00Z' "$((10 + tick))")" \
      '.units |= map(if .id == $id then .history += [{stage:"repair-delivered",at:$at},{stage:"supervisor-escalated",result:("blocked again at " + $at + " after a repair"),at:$at}] else . end)' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
  done
  echo '{"workers":[]}' > "$WORKERS"
done
for i in $(seq 1 "$n_cand"); do
  grep -qx "pr-91$i" "$fixture/starve-picks" || fail "pr-91$i starved: not picked in $(( (n_cand + slots - 1) / slots )) ticks, picks: $(tr '\n' ' ' < "$fixture/starve-picks")"
done

# Two candidates equally old: the one holding more waiting dependents goes first, whatever the array order.
jq -cn '{units:[range(1;4) as $i | {id:("pr-92\($i)"),issue:(9200+$i),pr:(9200+$i),lane:"pr",stage:(if $i == 2 then "parked" else "supervisor-review" end),parked_reason:"supervisor-cap-founder",held_dependents:([1,3,2][$i-1]),history:[{stage:"supervisor-escalated",result:"x",at:"2026-11-08T01:00:00Z"}]}]}' > "$UNITS"
[[ "$(supervisor_arbiter_candidates | jq -r .id | tr '\n' ' ')" == "pr-922 pr-923 pr-921 " ]] || fail "equal-age candidates must go by held dependents, higher first: $(supervisor_arbiter_candidates | jq -r .id | tr '\n' ' ')"

# ---- 决策类 park（"a supervisor decision"，非 cap park）：repair-breaker 与无 PR 的 stop-loss 进仲裁 ----
# A repair-breaker whose no-push rounds died in the backend is requeued by the existing path, with no model run.
units "$(jq -cn --arg sha "$SHA1" '{units:[{id:"pr-7101",lane:"pr",pr:7101,branch:"agent/issue-7101",stage:"parked",parked_reason:"repair-breaker",unpark_condition:"a supervisor decision",
  reviewed_sha:$sha,reviewed_pr_head:$sha,note:"breaker",history:[{stage:"review-request-changes",result:"F1",at:"2026-11-09T08:00:00Z"},
  {stage:"repair-no-push",result:("head "+$sha+" unchanged after repair"),backend_failure:"worker: both backends failed: luna: fatal stderr pattern: authentication or quota error",at:"2026-11-09T08:10:00Z"},
  {stage:"repair-no-push",result:("head "+$sha+" unchanged after repair"),backend_failure:"worker: both backends failed: luna: fatal stderr pattern: authentication or quota error",at:"2026-11-09T08:20:00Z"},
  {stage:"repair-breaker",result:("head "+$sha+": 2 consecutive repair runs ended on it without a push"),at:"2026-11-09T08:20:00Z"}]}]}')"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 dispatch_supervisor_arbiters
jq -e 'any(.workers[]; .type=="supervise" and .unit=="pr-7101") | not' "$WORKERS" >/dev/null || fail "a backend-failed repair-breaker must not get a model run: $(jq -c '.workers' "$WORKERS")"
[[ "$(field pr-7101 '[.history[].stage] | contains(["supervisor-requeue"])')" == true ]] || fail "a backend-failed repair-breaker must be requeued: $(jq -c '.units[0].history[-3:]' "$UNITS")"
[[ "$(field pr-7101 .parked_reason)" == null && "$(field pr-7101 .stage)" != parked ]] || fail "the requeued unit must leave the park: $(jq -c '.units[0] | {stage,parked_reason}' "$UNITS")"

# A repair-breaker without a backend failure takes the normal verdict: selected, dispatched to a supervise worker, back at supervisor-review.
units "$(jq -cn --arg sha "$SHA2" '{units:[{id:"pr-7102",lane:"pr",pr:7102,branch:"agent/issue-7102",stage:"parked",parked_reason:"repair-breaker",unpark_condition:"a supervisor decision",
  reviewed_sha:$sha,reviewed_pr_head:$sha,note:"breaker",history:[{stage:"review-request-changes",result:"F1",at:"2026-11-09T08:00:00Z"},
  {stage:"repair-no-push",result:("head "+$sha+" unchanged after repair"),at:"2026-11-09T08:10:00Z"},
  {stage:"repair-no-push",result:("head "+$sha+" unchanged after repair"),at:"2026-11-09T08:20:00Z"},
  {stage:"repair-breaker",result:("head "+$sha+": 2 consecutive repair runs ended on it without a push"),at:"2026-11-09T08:20:00Z"}]}]}')"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 dispatch_supervisor_arbiters
jq -e 'any(.workers[]; .type=="supervise" and .unit=="pr-7102")' "$WORKERS" >/dev/null || fail "a repair-breaker without a backend failure must get the normal arbitration: $(jq -c '.workers' "$WORKERS")"
[[ "$(field pr-7102 .stage)" == supervisor-review && "$(field pr-7102 .parked_reason)" == null ]] || fail "the arbitrated repair-breaker must be at supervisor-review: $(jq -c '.units[0] | {stage,parked_reason}' "$UNITS")"

# A stop-loss same failure with no PR waits for a supervisor decision: it is selected and arbitrated.
units "$(jq -cn '{units:[{id:"issue-7103",lane:"pr",branch:"agent/issue-7103",stage:"parked",parked_reason:"stop-loss same failure: ci-tests",unpark_condition:"a supervisor decision",
  note:"stop-loss",history:[{stage:"stop-loss",result:"ci-tests failed twice",at:"2026-11-09T08:00:00Z"}]}]}')"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 dispatch_supervisor_arbiters
jq -e 'any(.workers[]; .type=="supervise" and .unit=="issue-7103")' "$WORKERS" >/dev/null || fail "a stop-loss same-failure park with no PR must get the normal arbitration: $(jq -c '.workers' "$WORKERS")"

# The harvest records a backend failure on the no-push row only when the round's log shows the worker's own failure line.
units "$(jq -cn '{units:[{id:"pr-7104",lane:"pr",pr:7104,stage:"repair-pending",history:[]}]}')"
bf_log="$fixture/repair-backend-fail.log"; ok_log="$fixture/repair-prose.log"
printf 'worker: both backends failed: luna: fatal stderr pattern: authentication or quota error\n' > "$bf_log"
printf 'the docs say the authentication flow needs a quota check\n' > "$ok_log"
rr="$(printf '{"history":[]}' | jq -c "$(repair_run_filter pr-7104 unchanged "$SHA1" 5 "$bf_log" /dev/null)")"
jq -e '.history[-1] | .stage == "repair-no-push" and (.backend_failure | contains("both backends failed"))' <<<"$rr" >/dev/null || fail "a no-push round with a worker failure line must record backend_failure: $rr"
rr="$(printf '{"history":[]}' | jq -c "$(repair_run_filter pr-7104 unchanged "$SHA1" 5 "$ok_log" /dev/null)")"
jq -e '.history[-1] | has("backend_failure") | not' <<<"$rr" >/dev/null || fail "prose about auth or quota is not a backend failure: $rr"

jq -cn '{units:[{id:"issue-4865",issue:4865,stage:"parked",parked_reason:"repair-breaker",note:"same head after repeated no-push repair",history:[{stage:"repair-breaker",result:"same head"}]}]}' > "$UNITS"
[[ "$(supervisor_arbiter_candidates | jq -r .id)" == issue-4865 ]] \
  || fail "a repair-breaker park must enter the automatic arbiter queue: $(supervisor_arbiter_candidates | jq -r .id)"
# ---- 行 172b：仲裁裁决的停车没有无限期的人工等待（每条路径一行可 grep 的日志，单元与原因都在行内）----
hold_stub="$fixture/hold-stub"; hold_calls="$fixture/hold-calls"; mkdir -p "$hold_stub"; : > "$hold_calls"
printf '#!/usr/bin/env bash\nprintf "hold %%s\\n" "$*" >> %q\n' "$hold_calls" > "$hold_stub/hold.sh"
export ZF_ENGINE_DIR="$hold_stub"
ci_runs_at() { jq -cn --arg at "$1" --arg sha "$2" '{workflow_runs:[{status:"completed",conclusion:"success",created_at:$at,id:9,run_attempt:1,head_sha:$sha,event:"push"}]}'; }
# The real main-CI verdict reads one Actions list through gh api: answer that read from CI_RUNS, everything else from the earlier gh double.
eval "$(declare -f gh | sed '1s/^gh ()/gh_prev ()/')"
gh() { if [[ "$1" == api ]]; then printf '%s\n' "$CI_RUNS"; return 0; fi; gh_prev "$@"; }
main_gh() { gh "$@"; }
export REPO=ZenoWangzy/zenoforge
hist_park_at() { jq -cn --arg at "$1" '[{stage:"supervisor-park",result:"approve refused",at:$at}]'; }

# park-label-sweep may label a legacy cap park supervisor-park without a supervisor-park history row.
units "$(jq -cn '{units:[{id:"legacy-cap-park",issue:769,stage:"parked",parked_reason:"supervisor-park",unpark_condition:"a supervisor decision",history:[{stage:"supervisor-budget-park",result:"third entry into supervisor-review; arbitration cap is 2 (#4369)",at:"2026-10-27T00:02:00Z"}]}]}')"
supervisor_parked_unpark_sweeps
legacy_cap_unit="$(jq -c '.units[0]' "$UNITS")"
[[ "$(jq -r '.stage' <<<"$legacy_cap_unit")" == parked ]] \
  || fail "a migrated legacy cap park without supervisor-park history must stay parked: $legacy_cap_unit"
supervisor_cap_parked_unit "$legacy_cap_unit" \
  || fail "a migrated legacy cap park must remain eligible for final cap triage: $legacy_cap_unit"

# main-red-guard：只有park之后出现的绿色 main run 才放行；park之前的绿色不算。
units "$(jq -cn --argjson h "$(hist_park_at 2026-11-09T02:00:00Z)" '{units:[{id:"pr-901",pr:901,stage:"parked",parked_reason:"main-red-guard",unpark_condition:"main of this repo is green again",history:$h}]}')"
CI_RUNS="$(ci_runs_at 2026-11-09T01:00:00Z 1111111111111111111111111111111111111111)"
supervisor_parked_unpark_sweeps
[[ "$(field pr-901 .stage)" == parked ]] || fail "a green run older than the park must not release it: $(jq -c '.units[0]' "$UNITS")"
CI_RUNS="$(ci_runs_at 2026-11-09T03:00:00Z 3333333333333333333333333333333333333333)"
supervisor_parked_unpark_sweeps
[[ "$(field pr-901 .stage)" == supervisor-review && "$(field pr-901 .parked_reason)" == null ]] \
  || fail "green main after the park must release it to review: $(jq -c '.units[0]' "$UNITS")"
grep -q 'supervisor park unit=pr-901 reason=main-red-guard released: main green at 333333333' "$LOG" || fail "the release must log its unit and reason"

# requeue-target-missing：没有工作环节可放回，单元以持久 hold 关闭（issue 上 hold.sh --hold），不是评论式停车。
: > "$hold_calls"
units "$(jq -cn '{units:[{id:"issue-6401",issue:6401,stage:"supervisor-review",history:[]}]}')"
supervisor_requeue_unit issue-6401 requeue "guidance" '{"decision":"x"}'
[[ "$(field issue-6401 .stage)" == closed && "$(field issue-6401 .parked_reason)" == null ]] \
  || fail "a missing requeue target must close, not park: $(jq -c '.units[0]' "$UNITS")"
grep -q '^hold --hold 6401 ' "$hold_calls" || fail "the close must hold its issue through hold.sh: $(cat "$hold_calls")"
grep -q 'supervisor close unit=issue-6401 reason=requeue-target-missing: closed with a durable hold' "$LOG" || fail "the close must log its unit and reason"

# supervisor-park：第一次停车等 main 或 PR head 变化（或 24 h）；变化后只重仲裁一次；重复的同类裁决直接关闭并 hold。
: > "$hold_calls"
units "$(jq -cn '{units:[{id:"issue-6402",issue:6402,stage:"supervisor-review",history:[]}]}')"
MAIN_HEAD=1111111111111111111111111111111111111111 supervisor_park_verdict issue-6402 "stuck on review" '{"decision":"x"}'
[[ "$(field issue-6402 .stage)" == parked && "$(field issue-6402 .parked_reason)" == supervisor-park && "$(field issue-6402 .unpark_condition)" == "a state change or 24 h" ]] \
  || fail "the first park must wait for a state change or 24 h: $(jq -c '.units[0]' "$UNITS")"
supervisor_parked_unpark_sweeps
[[ "$(field issue-6402 .stage)" == parked ]] || fail "no state change: the park must keep waiting"
MAIN_HEAD=2222222222222222222222222222222222222222 supervisor_parked_unpark_sweeps
[[ "$(field issue-6402 .stage)" == supervisor-review ]] || fail "a main move must re-arbitrate the park once: $(jq -c '.units[0]' "$UNITS")"
supervisor_park_verdict issue-6402 "stuck on review" '{"decision":"x"}'
[[ "$(field issue-6402 .stage)" == closed ]] || fail "a repeated park must close, never park again: $(jq -c '.units[0]' "$UNITS")"
grep -q '^hold --hold 6402 ' "$hold_calls" || fail "the repeat close must hold issue 6402"

# 上限：只打一次日志（owner=head），且之后不再派模型。
: > "$LOG"
default_unit pr-660 660 '{}' '[]' 4
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(grep -c 'arbiter cap reached unit=pr-660 runs=4 owner=head' "$LOG")" == 1 ]] \
  || fail "the cap must log once per unit: $(grep 'arbiter cap' "$LOG")"

# 上限之内的 head 裁决：一条 supervisor-requeue 裁决（带 owner 评论 id）恰好再给一次仲裁；消耗后再次触顶。
default_unit pr-661 661 '{}' '[{"stage":"supervisor-requeue","result":"supervisor ruling 6736537359: one luna repair round","at":"2026-10-27T01:00:00Z"}]' 4
echo '{"workers":[]}' > "$WORKERS"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
jq -e 'any(.workers[]; .type=="supervise" and .unit=="pr-661")' "$WORKERS" >/dev/null \
  || fail "an owner ruling must buy one arbiter run past the cap: $(jq -c '.units[0].history[-3:]' "$UNITS")"
echo '{"workers":[]}' > "$WORKERS"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
! jq -e 'any(.workers[]; .unit=="pr-661")' "$WORKERS" >/dev/null || fail "one ruling is exactly one run"

# 普通 requeue（没有评论 id）不给额外仲裁。
default_unit pr-665 665 '{}' '[{"stage":"supervisor-requeue","result":"plain requeue without an owner comment","at":"2026-10-27T01:00:00Z"}]' 4
echo '{"workers":[]}' > "$WORKERS"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
! jq -e 'any(.workers[]; .unit=="pr-665")' "$WORKERS" >/dev/null || fail "a plain requeue must grant no run past the cap"

# 6 小时之内没有裁决：不派、不动；超过 6 小时：走一次既有 recut/park 路线。
units "$(jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{units:[{id:"pr-662",issue:662,pr:662,lane:"pr",stage:"supervisor-review",history:[range(4) | {stage:"supervisor-arbiter",result:"dispatched",at:$at}]}]}')"
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cap_default_history pr-662 supervisor-cap-default)" == 0 && "$(cap_default_stage pr-662)" == supervisor-review ]] \
  || fail "inside the six-hour wait the cap must neither default nor move the unit: $(jq -c '.units[0]' "$UNITS")"

# 第二次触顶（已有一次默认决定）：持久关闭，issue 上 hold。
: > "$hold_calls"
default_unit pr-663 663 '{}' '[{"stage":"supervisor-cap-default","result":"branch=park: arbitration cap (4 lifetime dispatches) reached; recut already tried","at":"2026-10-26T00:02:00Z"}]' 4
drop_unit_pr
SUPERVISOR_ARBITER=true SUPERVISOR_ARBITER_MAX=99 SUPERVISOR_ARBITER_UNIT_CAP=4 dispatch_supervisor_arbiters
[[ "$(cap_default_stage pr-663)" == closed ]] || fail "a second cap must close durably: $(jq -c '.units[0]' "$UNITS")"
grep -q '^hold --hold 663 ' "$hold_calls" || fail "the second cap must hold issue 663: $(cat "$hold_calls")"

# ---- 行 172b 第二轮：cap 关闭时挂着的 PR 一并关闭（有 hold 链接），session-owned 与被 open issue 引用的 PR 不关 ----
pr_calls="$fixture/pr-close-calls"; : > "$pr_calls"; PR_STATE="OPEN factory"; CITED_ISSUES=""
eval "$(declare -f gh | sed '1s/^gh ()/gh_before_pr ()/')"
gh() {
  case "$1 $2" in
    'pr view') printf '%s\n' "$PR_STATE"; return 0 ;;
    'issue list') printf '%s\n' "$CITED_ISSUES"; return 0 ;;
    'pr close') printf 'pr-close %s\n' "$*" >> "$pr_calls"; return 0 ;;
  esac
  gh_before_pr "$@"
}
units "$(jq -cn '{units:[{id:"issue-6801",issue:6801,pr:6811,stage:"closed",history:[]}]}')"
: > "$hold_calls"; : > "$pr_calls"
supervisor_cap_close_pr issue-6801 arbitration-cap-again "cap again, no ruling"
grep -q 'pr close 6811 ' "$pr_calls" || fail "an unlabeled open PR must close with the cap close: $(cat "$pr_calls")"
grep -q 'issue #6801 is on hold (hold.sh, holder scheduler-stop-loss): cap again, no ruling' "$pr_calls" || fail "the PR close must link the hold: $(cat "$pr_calls")"
grep -q 'supervisor close unit=issue-6801 reason=arbitration-cap-again: PR #6811 closed, hold on issue #6801' "$LOG" || fail "the PR close must log its unit, reason and hold issue"

PR_STATE="OPEN session-owned,factory"; : > "$pr_calls"
supervisor_cap_close_pr issue-6801 arbitration-cap-again "cap again, no ruling"
[[ ! -s "$pr_calls" ]] || fail "a session-owned PR must stay open: $(cat "$pr_calls")"

PR_STATE="OPEN factory"; CITED_ISSUES="6900"; : > "$pr_calls"
supervisor_cap_close_pr issue-6801 arbitration-cap-again "cap again, no ruling"
[[ ! -s "$pr_calls" ]] || fail "a PR cited by an open issue (first slice) must stay open: $(cat "$pr_calls")"
grep -q 'first slice cited by open issue #6900' "$LOG" || fail "the first-slice keep must log one line"

# ---- 行 172c：cap-exhausted 停放也有机械出口：owner 裁决 +1；6 h 无裁决 recut 一次；再次触顶 durable close ----
cx_hist() { # exhausted-at [extra-json] → arbiter history (4 runs, old) + the cap-exhausted park row + extra rows
  jq -cn --arg at "$1" --argjson extra "${2:-[]}" \
    '[range(4) | {stage:"supervisor-arbiter",result:"dispatched",at:"2026-10-26T00:00:00Z"}]
     + [{stage:"supervisor-cap-exhausted",result:"capped again after its one retry",at:$at}] + $extra'
}
cx_unit() { # id issue hist-json → a parked cap-exhausted unit
  jq -cn --arg id "$1" --argjson issue "$2" --argjson h "$3" \
    '{units:[{id:$id,issue:$issue,stage:"parked",parked_reason:"supervisor-cap-exhausted",unpark_condition:"a new issue state or supervisor ruling",history:$h}]}'
}
cx_stage() { jq -r --arg id "$1" '.units[] | select(.id==$id) | .stage' "$UNITS"; }
cx_reason() { jq -r --arg id "$1" '.units[] | select(.id==$id) | .parked_reason' "$UNITS"; }

# The issue-state reader is not what these cases test: it reads ready-for-agent for every issue here.
scheduler_issue_state() { printf '{"state":"ready-for-agent"}\n'; }
# owner ruling after the park: +1 release, the unit re-enters the arbitration-cap park (the one run is then dispatched by the existing path)
units "$(cx_unit issue-671 671 "$(cx_hist 2026-10-27T01:00:00Z '[{"stage":"supervisor-requeue","result":"supervisor ruling 6737000001: one more run","at":"2026-10-27T02:00:00Z"}]')")"
supervisor_cap_exhausted_sweep
[[ "$(cx_reason issue-671)" == supervisor-arbitration-cap ]] || fail "an owner ruling after the cap-exhausted park must release it: $(jq -c '.units[0]' "$UNITS")"
grep -q 'supervisor cap-exhausted unit=issue-671 reason=supervisor-cap-exhausted: released by a head ruling' "$LOG" || fail "the ruling release must log its unit and reason"

# no ruling, six hours: recut default once (the existing recut route; the unit closes on the route)
echo '{"state":"ready-for-agent","recut_children":[],"recut_comment_scanned":true}' > "$AGENT_HOME/state/672.json"
: > "$route2"; units "$(cx_unit issue-672 672 "$(cx_hist 2026-10-26T00:00:00Z)")"
supervisor_cap_exhausted_sweep
[[ "$(cat "$route2")" == 'route ' && "$(cx_stage issue-672)" == closed ]] \
  || fail "six hours without a ruling must take the recut route once: calls=$(cat "$route2") $(jq -c '.units[0]' "$UNITS")"
grep -q 'supervisor cap-exhausted unit=issue-672 reason=supervisor-cap-exhausted: six hours without a ruling, recut default once' "$LOG" || fail "the recut exit must log its unit and reason"

# no ruling, six hours, the cap came back after its recut default: durable close with the issue hold
echo '{"state":"ready-for-agent","recut_children":[],"recut_comment_scanned":true}' > "$AGENT_HOME/state/673.json"
: > "$hold_calls"
units "$(cx_unit issue-673 673 "$(cx_hist 2026-10-26T00:00:00Z '[{"stage":"supervisor-cap-default","result":"branch=recut: arbitration cap (4 lifetime dispatches) reached; recut the unit once","at":"2026-10-26T00:01:00Z"}]')")"
supervisor_cap_exhausted_sweep
[[ "$(cx_stage issue-673)" == closed ]] || fail "a second cap with no ruling must close durably: $(jq -c '.units[0]' "$UNITS")"
grep -q '^hold --hold 673 ' "$hold_calls" || fail "the second-cap close must hold issue 673: $(cat "$hold_calls")"

# inside the six-hour wait (no ruling): nothing moves, nothing is held
: > "$hold_calls"; : > "$route2"
units "$(cx_unit issue-674 674 "$(cx_hist "$(date -u +%Y-%m-%dT%H:%M:%SZ)")")"
supervisor_cap_exhausted_sweep
[[ "$(cx_stage issue-674)" == parked && "$(cx_reason issue-674)" == supervisor-cap-exhausted && ! -s "$hold_calls" && ! -s "$route2" ]] \
  || fail "inside the six-hour wait the cap-exhausted park must stay put: $(jq -c '.units[0]' "$UNITS")"

echo 'supervisor-arbiter.test.sh: all assertions passed'
