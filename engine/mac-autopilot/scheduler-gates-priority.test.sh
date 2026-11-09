#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/test-scheduler-gates-fixture.sh"
fail() { echo "scheduler-gates.test.sh: $*" >&2; exit 1; }
units() { printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
M1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
M2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
M3=cccccccccccccccccccccccccccccccccccccccc
source "$script_dir/test-scheduler-gates-gh-fixture.sh"
CFG_SAVED="$CFG"
# ---------- 热修优先（统一准入，#4625 起挡板退役）：热修分支的 run 不被任何准入取消；census 不可用时不做取消决定 ----------
ph="$fixture/prio-root"; mkdir -p "$ph/engine/night"
printf '#!/usr/bin/env bash\necho "$2" >> "%s/cancelled"\necho "${ZF_CANCEL_REASON-unset}" >> "%s/reasons"\n' "$ph" "$ph" > "$ph/engine/night/main-ci-recovery.sh"
run_json() { printf '{"databaseId":%s,"status":"%s","event":"pull_request","headBranch":"%s","headSha":"%s","workflowName":"%s"}' "$@"; }
gh_prio_saved="$(declare -f gh)"
# 关联 issue 分类为 hotfix 的 review PR 不能被 draft defer 取消。
rm -f "$ph/cancelled"
units "{\"units\":[{\"id\":\"linked-hotfix\",\"pr\":30,\"stage\":\"review-pending\",\"branch\":\"agent/issue-30\",\"history\":[]}]}"
GH_PR_TABLE="$fixture/defer-linked-hotfix-prs.json"; printf '[{"number":30,"headRefName":"agent/issue-30","headRefOid":"%s","isDraft":false,"labels":[],"statusCheckRollup":[]} ]\n' "$H2" > "$GH_PR_TABLE"
TICK_PRS=""; TICK_UNFINISHED="[$(run_json 76 queued agent/issue-30 "$H2" CI)]"
hotfix_issues_saved="$TICK_HOTFIX_ISSUES"; hotfix_issues_loaded_saved="$TICK_HOTFIX_ISSUES_LOADED"
TICK_HOTFIX_ISSUES='[30]'; TICK_HOTFIX_ISSUES_LOADED=true
( ROOT="$ph"; ci_defer_classified_test ) || fail 'draft defer errored on a linked hotfix PR'
[[ ! -s "$ph/cancelled" && "$(field linked-hotfix '.ci_deferred_sha // "none"')" == none ]] \
  || fail "draft defer cancelled or marked a linked hotfix run ($(cat "$ph/cancelled" 2>/dev/null))"
TICK_HOTFIX_ISSUES="$hotfix_issues_saved"; TICK_HOTFIX_ISSUES_LOADED="$hotfix_issues_loaded_saved"
unset GH_PR_TABLE; GH_RUNS='[]'; TICK_UNFINISHED=""
# 读不到 PR census 时 controller 不做取消决定，避免漏识别热修后把它送进 defer。
rm -f "$ph/cancelled"
units "{\"units\":[{\"id\":\"pr-21\",\"pr\":21,\"stage\":\"review-pending\",\"branch\":\"plain\",\"history\":[]},{\"id\":\"pr-20\",\"pr\":20,\"stage\":\"review-pending\",\"hotpatch\":true,\"branch\":\"hp\",\"history\":[]}]}"
GH_RUNS="[$(run_json 70 queued hp "$H2" CI),$(run_json 71 queued plain "$H1" CI)]"
gh_census_saved="$(declare -f gh)"
gh() { if [[ "$1 $2" == "pr list" ]]; then return 1; else eval "${gh_census_saved/gh ()/gh_f ()}"; gh_f "$@"; fi; }
( ROOT="$ph"; TICK_PRS=""; ci_admission ) || fail 'ci_admission errored with an unavailable PR census'
[[ ! -s "$ph/cancelled" ]] || fail "controller cancelled runs without hotfix classification ($(tr '\n' ' ' < "$ph/cancelled"))"
eval "$gh_census_saved"; GH_RUNS='[]'
# ---------- 统一优先级与 FIFO：main-red > opt > normal；同级按 ready_since ----------
rank_prs="$fixture/ci-admission-ranked-prs.json"; GH_PR_TABLE="$rank_prs"; echo '[]' > "$GH_PR_TABLE"; : > "$GH_PR_CALLS"
gh_pr_open 61 "$H1" true MERGEABLE agent/issue-61
gh_pr_open 62 "$H1" true MERGEABLE agent/issue-62
gh_pr_open 63 "$H1" true MERGEABLE agent/issue-63
gh_pr_open 64 "$H1" true MERGEABLE agent/issue-64
jq -c 'map(.labels = [{name: "agent/ci-gated"}])' "$GH_PR_TABLE" > "$GH_PR_TABLE.tmp" && mv "$GH_PR_TABLE.tmp" "$GH_PR_TABLE"
gh_rank_saved="$(declare -f gh)"
gh() { case "$1 $2" in
  "api -i")
    local rest=() skip_next=0 arg body
    for arg in "$@"; do
      (( skip_next )) && { skip_next=0; continue; }
      case "$arg" in
        -i) ;;
        -H) skip_next=1 ;;
        *) rest+=("$arg") ;;
      esac
    done
    body="$(gh "${rest[@]}")" || return $?
    printf 'HTTP/2.0 200 OK\nEtag: "stub"\n\n%s\n' "$body"
    return 0 ;;
  "pr list") cat "$GH_PR_TABLE" ;;
  "pr ready") if [[ "${4:-}" == "--undo" ]]; then gh_pr_ready "$3" --undo; else gh_pr_ready "$3"; fi ;;
  "api repos/{owner}/{repo}/commits/"*"/status"*) echo 0 ;;
  "api repos/{owner}/{repo}/statuses/"*) echo "$*" >> "$GH_PR_CALLS" ;;
  "run list"*) echo '[]' ;;
  "api --paginate")
    case "$3" in
      # 一个在线 PR runner → 一个空槽；名额来自 runner 而不是配置（60ba960cf）
      "repos/{owner}/{repo}/actions/runners?per_page=100") echo 1 ;;
    esac ;;
  "api "*)
    if [[ "$*" == *'actions/runners?per_page=100'* ]]; then
      local runners_jq="" runners_prev="" arg
      for arg in "$@"; do [[ "$runners_prev" == --jq ]] && runners_jq="$arg"; runners_prev="$arg"; done
      jq -r "${runners_jq:-.runners[].id}" <<<"$GH_RUNNERS"
    else
      echo '[]'
    fi ;;
  *) echo "unexpected gh in admission fixture: $*" >&2; return 97 ;;
esac; }
pr_behind_rank_saved="$(declare -f pr_behind_main)"
pr_behind_main() { return 1; } # 排序用例不覆盖 update-branch / mergeability
CFG="$(jq '.precheck=false' <<<"$CFG_SAVED")"
units "$(jq -cn --arg h "$H1" '{units:[
  {id:"main-red",pr:61,branch:"agent/issue-61",stage:"ready-to-merge",main_red:true,approved_sha:$h,ready_since:30,product_paths:true,history:[]},
  {id:"opt-early",pr:62,branch:"agent/issue-62",stage:"ready-to-merge",ci_priority:true,approved_sha:$h,ready_since:10,product_paths:true,history:[]},
  {id:"opt-late",pr:63,branch:"agent/issue-63",stage:"ready-to-merge",ci_priority:true,approved_sha:$h,ready_since:20,product_paths:true,history:[]},
  {id:"normal",pr:64,branch:"agent/issue-64",stage:"ready-to-merge",approved_sha:$h,ready_since:1,product_paths:true,history:[]}
]}')"
( ROOT="$ph"; TICK_PRS=""; TICK_UNFINISHED='[]'; ci_wip_gate_test )
[[ "$(gh_pr_is_draft 61):$(gh_pr_is_draft 62):$(gh_pr_is_draft 63):$(gh_pr_is_draft 64)" == "false:true:true:true" ]] \
  || fail "main-red did not win the full slot over opt and normal ($(gh_pr_is_draft 61):$(gh_pr_is_draft 62):$(gh_pr_is_draft 63):$(gh_pr_is_draft 64))"
jq -c 'map(.isDraft = true)' "$GH_PR_TABLE" > "$GH_PR_TABLE.tmp" && mv "$GH_PR_TABLE.tmp" "$GH_PR_TABLE"
units "$(jq -cn --arg h "$H1" '{units:[
  {id:"opt-early",pr:62,branch:"agent/issue-62",stage:"ready-to-merge",ci_priority:true,approved_sha:$h,ready_since:10,product_paths:true,history:[]},
  {id:"opt-late",pr:63,branch:"agent/issue-63",stage:"ready-to-merge",ci_priority:true,approved_sha:$h,ready_since:20,product_paths:true,history:[]},
  {id:"normal",pr:64,branch:"agent/issue-64",stage:"ready-to-merge",approved_sha:$h,ready_since:1,product_paths:true,history:[]}
]}')"
( ROOT="$ph"; TICK_PRS=""; TICK_UNFINISHED='[]'; ci_wip_gate_test )
[[ "$(gh_pr_is_draft 62):$(gh_pr_is_draft 63):$(gh_pr_is_draft 64)" == "false:true:true" ]] \
  || fail "opt did not outrank normal or preserve same-level ready order ($(gh_pr_is_draft 62):$(gh_pr_is_draft 63):$(gh_pr_is_draft 64))"
# 关联 issue 分类为 hotfix 的门控 PR 不占产品 WIP 名额，满额时仍立即 ready；它进入 review 后也不能被 demote 取消。
GH_PR_TABLE="$fixture/ci-admission-hotfix-gated.json"; echo '[]' > "$GH_PR_TABLE"; : > "$GH_PR_CALLS"
pr_behind_hotfix_saved="$(declare -f pr_behind_main)"
pr_behind_main() { return 1; } # Hotfix slot admission does not exercise main-branch synchronization.
gh_pr_open 65 "$H1" true MERGEABLE agent/issue-65
gh_pr_open 66 "$H1" true MERGEABLE agent/issue-66
CFG_RANK_SAVED="$CFG"
jq -c '.hotfix_lane={branch_prefixes:["hotfix/","agent/issue-hf-"],label:"hotfix"}' <<<"$CFG" > "$fixture/ci-admission-config.json"
CFG="$(cat "$fixture/ci-admission-config.json")"
jq -c 'map(.labels = [{name: "agent/ci-gated"}]) + [{number:67,headRefOid:"'"$H1"'",isDraft:true,mergeable:"MERGEABLE",headRefName:"hotfix/urgent",labels:[{name:"agent/ci-gated"}],statusCheckRollup:[]}]' "$GH_PR_TABLE" > "$GH_PR_TABLE.tmp" && mv "$GH_PR_TABLE.tmp" "$GH_PR_TABLE"
hotfix_issues_saved="$TICK_HOTFIX_ISSUES"; hotfix_issues_loaded_saved="$TICK_HOTFIX_ISSUES_LOADED"
TICK_HOTFIX_ISSUES='[65]'; TICK_HOTFIX_ISSUES_LOADED=true
units "$(jq -cn --arg h "$H1" '{units:[
  {id:"hotfix",pr:65,branch:"agent/issue-65",stage:"ready-to-merge",approved_sha:$h,ready_since:20,product_paths:true,history:[]},
  {id:"normal",pr:66,branch:"agent/issue-66",stage:"ready-to-merge",approved_sha:$h,ready_since:1,product_paths:true,history:[]},
  {id:"prefixed-hotfix",pr:67,branch:"hotfix/urgent",stage:"ready-to-merge",approved_sha:$h,ready_since:2,product_paths:true,history:[]}
]}')"
( ROOT="$ph"; TICK_PRS=""; TICK_UNFINISHED='[]'; ci_admission_test )
[[ "$(gh_pr_is_draft 65):$(gh_pr_is_draft 66):$(gh_pr_is_draft 67)" == "false:false:false" ]] \
  || fail "linked or configured-prefix hotfix did not start outside the full normal WIP slot ($(gh_pr_is_draft 65):$(gh_pr_is_draft 66):$(gh_pr_is_draft 67))"
[[ "$(grep '^pr ready ' "$GH_PR_CALLS" | tr '\n' ' ')" == "pr ready 65 pr ready 67 pr ready 66 " ]] \
  || fail "full-slot admission readied normal CI before hotfix CI ($(grep '^pr ready ' "$GH_PR_CALLS" | tr '\n' ' '))"
units "$(jq -cn --arg h "$H1" '{units:[
  {id:"hotfix",pr:65,branch:"agent/issue-65",stage:"review-pending",history:[]},
  {id:"normal",pr:66,branch:"agent/issue-66",stage:"ready-to-merge",approved_sha:$h,ci_ready_sha:$h,ci_ready_at:"2026-10-30T00:00:00Z",ready_since:1,product_paths:true,history:[]},
  {id:"prefixed-hotfix",pr:67,branch:"hotfix/urgent",stage:"review-pending",history:[]}
]}')"
: > "$GH_PR_CALLS"
( ROOT="$ph"; TICK_PRS=""; TICK_UNFINISHED='[]'; ci_admission_test )
[[ "$(gh_pr_is_draft 65):$(gh_pr_is_draft 67)" == "false:false" ]] \
  && ! grep -Eq 'pr ready (65|67) --undo' "$GH_PR_CALLS" \
  || fail "linked or configured-prefix hotfix was demoted and its CI cancelled ($(cat "$GH_PR_CALLS" 2>/dev/null | tr '\n' '|'))"
eval "$pr_behind_hotfix_saved"
CFG="$CFG_RANK_SAVED"
TICK_HOTFIX_ISSUES="$hotfix_issues_saved"; TICK_HOTFIX_ISSUES_LOADED="$hotfix_issues_loaded_saved"
eval "$pr_behind_rank_saved"
unset GH_PR_TABLE
TICK_PRS=""; TICK_UNFINISHED=""
eval "$gh_prio_saved"; GH_RUNS='[]'; GH_RERUNS=()

rm -f "$LUNA_SLOTS"/wait-*
touch "$LOG" "$A/alerts/waste.md" "$LUNA_SLOTS/wait-opt-$$"
units "$(jq -cn --argjson since "$(( $(date +%s) - 1201 ))" '{units:[{id:"review",stage:"review-pending"},{id:"normal-a",stage:"implement"},{id:"normal-b",stage:"implement"},{id:"starved",stage:"implement",priority_hold:{since_epoch:$since,alerted:false}}]}')"
priority_failures=()
if room_for review review "$(jq -c '.units[] | select(.id=="review")' "$UNITS")"; then :; else priority_failures+=(review); fi
touch -d "@$(($(date +%s) - 1300))" "$LUNA_SLOTS/wait-opt-$$"
TICK_PRIORITY_HOLD_EXPIRED=()
for id in normal-a normal-b; do
  unit="$(jq -c --arg id "$id" '.units[] | select(.id==$id)' "$UNITS")"
  if room_for "$id" implement "$unit" true false; then :; else priority_failures+=(stale); fi
done
[[ "$(grep -c 'priority hold expired for wait-opt-.* after .*s; normal dispatch resumes' "$LOG")" == 1 ]] || priority_failures+=(expiry-log)
touch -d "@$(($(date +%s) - 60))" "$LUNA_SLOTS/wait-opt-$$"
unit="$(jq -c '.units[] | select(.id=="normal-a")' "$UNITS")"
if room_for normal-a implement "$unit" true false; then priority_failures+=(fresh); fi
if room_for starved implement "" true false; then priority_failures+=(starve-admitted); fi
if room_for starved implement "" true false; then priority_failures+=(starve-admitted); fi
[[ "$(grep -c 'PRIORITY-HOLD-STARVE unit=starved waiter=wait-opt-' "$LOG")" == 1 ]] || priority_failures+=(starve-log)
[[ "$(grep -c 'PRIORITY-HOLD-STARVE unit=starved waiter=wait-opt-' "$A/alerts/waste.md")" == 1 ]] || priority_failures+=(starve-alert)
(( ${#priority_failures[@]} == 0 )) || fail "dispatch priority regressions: ${priority_failures[*]}"

echo 'scheduler-gates-priority.test.sh: PASS'
