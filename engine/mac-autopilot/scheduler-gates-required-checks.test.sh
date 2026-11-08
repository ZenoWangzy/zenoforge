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
MAIN_HEAD="$M1"
gate_eval_sha() { printf '%s' "$M1"; }
git() {
  if [[ " $* " == *" ls-remote "* ]]; then printf '%s\trefs/heads/main\n' "$MAIN_HEAD"
  elif [[ "${1:-}" == -C && "${3:-}" == fetch && ( "${!#}" == refs/pull/*/head || "${!#}" == +refs/pull/*/head:refs/autopi/merge-candidates/* ) ]]; then return 0
  elif [[ "${1:-}" == -C && "${3:-}" == rev-parse && ( "${5:-}" == FETCH_HEAD* || "${5:-}" == refs/autopi/merge-candidates/* ) ]]; then echo "$GH_HEAD"
  else command git "$@"; fi
}
mkdir -p "$ROOT/engine"
printf '#!/usr/bin/env bash\nprintf "rule-lane: decision=pass actor=unit touched=0\\n"\n' > "$ROOT/engine/rule-lane.sh"
GH_RUNS="[{\"headSha\":\"$M1\",\"conclusion\":\"success\",\"status\":\"completed\",\"createdAt\":\"2026-10-19T00:00:00Z\",\"databaseId\":7}]"
GH_MERGE_SHA="$M2"
# Required checks use the deployed shared definition; missing/skipping/neutral
# rows cannot merge and must not change stage, cancel, or rerun anything.
(
  # required_checks_without_pass uses gh_timeout, so pin the external CLI used
  # by this synthetic merge fixture instead of
  # inheriting the cihost runner's installed version.
  gh_cli_stub="$fixture/gh-cli"
  mkdir -p "$gh_cli_stub"
  cat > "$gh_cli_stub/gh" <<'SH'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf 'gh version %s (fixture)\n' "${FIXTURE_GH_VERSION:-2.50.0}"
  exit 0
fi
exit 98
SH
  chmod +x "$gh_cli_stub/gh"
  PATH="$gh_cli_stub:$PATH"
  export PATH
  REQUIRED_PR_CHECKS_FILE="$script_dir/required-pr-checks.json"
  passing_checks="$(jq -c '.required | map({name:.,bucket:"pass"})' "$REQUIRED_PR_CHECKS_FILE")"
  FIXTURE_GH_VERSION=2.49.0; export FIXTURE_GH_VERSION
  [[ "$(required_checks_without_pass "$passing_checks")" == 'gh 2.49.0 is older than required 2.50.0' ]] \
    || fail 'an older GitHub CLI version did not fail the required-check guard'
  FIXTURE_GH_VERSION=2.50.0
  for aggregate_bucket in missing skipping neutral; do
    GH_CHECKS="$(jq -c --arg bucket "$aggregate_bucket" '
      map(select(.name != "Required CI gates")) +
      (if $bucket == "missing" then [] else [{name:"Required CI gates",bucket:$bucket}] end)
    ' <<< "$passing_checks")"
    units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-required",pr:11,stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
    GH_MERGES=(); GH_RERUNS=(); : > "$LOG"
    cancel_branch_runs() { fail 'required-check block cancelled a run'; }
    run_merge_lane || :
    [[ ${#GH_MERGES[@]} == 0 && ${#GH_RERUNS[@]} == 0 && "$(field pr-required .stage)" == ready-to-merge ]] || fail "$aggregate_bucket aggregate did not leave the merge blocked without side effects"
    grep -Fq 'merge skipped PR#11 (required checks without a real pass: Required CI gates)' "$LOG" || fail "$aggregate_bucket aggregate lacks the required-check log"
  done
  # The aggregate is the single required source (#4484): heavy gates that legitimately did not
  # run (only skipping rows) no longer block the merge when the aggregate row is green.
  GH_CHECKS="$(jq -c '. + [{name:"Touched packages PR gate",bucket:"skipping"},{name:"Example pack PR gate",bucket:"skipping"}]' <<< "$passing_checks")"
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-required",pr:11,stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  GH_MERGES=(); run_merge_lane || :
  [[ "${GH_MERGES[0]:-}" == *"pr merge 11"* && "$(field pr-required .stage)" == merged ]] || fail 'skipping heavy rows blocked a green aggregate from merging'
  ready_at='2026-10-28T22:00:00Z'
  GH_CHECKS="$(jq -c --arg started_at '2026-10-28T21:59:59Z' '
    .required | map({name:.,bucket:"pass",started_at:$started_at})
  ' "$REQUIRED_PR_CHECKS_FILE")"
  units "$(jq -cn --arg sha "$H1" --arg ready "$ready_at" '{units:[{id:"pr-ready-event",pr:11,branch:"agent/issue-11",stage:"ready-to-merge",approved_sha:$sha,gated:true,ci_ready_sha:$sha,ci_ready_at:$ready,history:[]}]}')"
  GH_MERGES=(); : > "$LOG"
  run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 && "$(field pr-ready-event .stage)" == ready-to-merge ]] || fail 'checks from before ready_for_review satisfied the merge gate'
  grep -Fq 'merge skipped PR#11 (required checks without a real pass:' "$LOG" || fail 'stale checks lack the required-check block reason'
  GH_CHECKS="$(jq -c --arg started_at '2026-10-28T22:00:00.123456Z' '.required | map({name:.,bucket:"pass",started_at:$started_at})' "$REQUIRED_PR_CHECKS_FILE")"
  units "$(jq -cn --arg sha "$H1" --arg ready "$ready_at" '{units:[{id:"pr-ready-event",pr:11,branch:"agent/issue-11",stage:"ready-to-merge",approved_sha:$sha,gated:true,ci_ready_sha:$sha,ci_ready_at:$ready,history:[]}]}')"
  GH_MERGES=(); run_merge_lane || :
  [[ "${GH_MERGES[0]:-}" == *"pr merge 11"* && "$(field pr-ready-event .stage)" == merged ]] || fail 'checks started at ready_for_review did not satisfy the merge gate'
  # #4484：非 agent 分支的接管 PR 首拍先补 pipeline-ci 标签（labeled 事件开 CI）并记账时间下限，
  # 打标签前的聚合绿行不能直接拿来合入；第二个拍检查行早于下限仍不合，晚于下限才合。
  : > "$fixture/pr-edit.calls"
  unset GH_PR_TABLE
  GH_CHECKS="$passing_checks"
  GH_PR_EDIT_STATUS=1
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-adopt-failed",pr:11,branch:"fix/dispatch-unique-sku-unit",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  GH_MERGES=(); : > "$LOG"; run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 && "$(cat "$fixture/pr-edit.calls")" == 'pr edit 11 --add-label pipeline-ci' ]] \
    || fail 'a failed pipeline-ci label add did not hold the merge'
  [[ "$(field pr-adopt-failed .ci_adopt_head)" == null ]] || fail 'a failed label add was recorded as successful adoption'
  grep -Fq 'pipeline-ci label event setup failed; retried next pass' "$LOG" || fail 'a failed label event setup has no retry reason'
  unset GH_PR_EDIT_STATUS

  : > "$fixture/pr-edit.calls"
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-adopt",pr:11,branch:"fix/dispatch-unique-sku-unit",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  GH_MERGES=(); : > "$LOG"; run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 && "$(cat "$fixture/pr-edit.calls")" == 'pr edit 11 --add-label pipeline-ci' ]] \
    || fail 'a non-agent adopted PR was not labeled pipeline-ci instead of merging'
  [[ "$(field pr-adopt .ci_adopt_head)" == "$H1" && "$(field pr-adopt .ci_adopt_at)" != null ]] || fail 'adoption did not pin the head and its time floor'
  grep -Fq 'adopt PR#11: pipeline-ci label event started branch policy and heavy gates' "$LOG" || fail 'adoption lacks its log line'

  # An old/manual pipeline-ci label makes --add-label a no-op. Remove and add it back
  # so both pull_request and pull_request_target receive a new labeled event.
  cp "$fixture/pr-edit.calls" "$fixture/pr-edit.calls.before-existing-label"
  GH_PR_TABLE="$fixture/pr-adopt-existing-label.json"
  jq -cn --arg sha "$H1" '[{number:11,headRefOid:$sha,headRefName:"fix/dispatch-unique-sku-unit",isDraft:false,title:"adopted PR",labels:[{name:"pipeline-ci"}],statusCheckRollup:[]}]' > "$GH_PR_TABLE"
  : > "$fixture/pr-edit.calls"
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-adopt-existing-label",pr:11,branch:"fix/dispatch-unique-sku-unit",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  GH_MERGES=(); : > "$LOG"; run_merge_lane || :
  [[ "$(cat "$fixture/pr-edit.calls")" == $'pr edit 11 --remove-label pipeline-ci\npr edit 11 --add-label pipeline-ci' ]] \
    || fail 'a pre-existing adoption label did not produce a fresh labeled event'
  jq -e 'any(.[] | select(.number == 11) | .labels[]?; .name == "pipeline-ci")' "$GH_PR_TABLE" >/dev/null \
    || fail 'refreshing the adoption label did not leave it attached'
  [[ ${#GH_MERGES[@]} == 0 && "$(field pr-adopt-existing-label .ci_adopt_head)" == "$H1" \
      && "$(field pr-adopt-existing-label .ci_adopt_at)" != null ]] \
    || fail 'a pre-existing adoption label was recorded without holding for fresh checks'
  grep -Fq 'label event started branch policy and heavy gates' "$LOG" || fail 'pre-existing label refresh lacks its log line'
  unset GH_PR_TABLE
  mv "$fixture/pr-edit.calls.before-existing-label" "$fixture/pr-edit.calls"

  adopt_at='2026-10-29T10:00:00Z'
  GH_CHECKS="$(jq -c --arg started_at '2026-10-29T09:59:59Z' '.required | map({name:.,bucket:"pass",started_at:$started_at})' "$REQUIRED_PR_CHECKS_FILE")"
  units "$(jq -cn --arg sha "$H1" --arg at "$adopt_at" '{units:[{id:"pr-adopt",pr:11,branch:"fix/dispatch-unique-sku-unit",stage:"ready-to-merge",approved_sha:$sha,ci_adopt_head:$sha,ci_adopt_at:$at,history:[]}]}')"
  GH_MERGES=(); : > "$LOG"; run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 ]] || fail 'pre-adoption green rows satisfied the merge gate'
  grep -Fq 'merge skipped PR#11 (required checks without a real pass:' "$LOG" || fail 'pre-adoption rows lack the required-check block reason'
  [[ "$(wc -l < "$fixture/pr-edit.calls")" == 1 ]] || fail 'an already-adopted head was labeled again'
  GH_CHECKS="$(jq -c --arg started_at '2026-10-29T10:00:01Z' '.required | map({name:.,bucket:"pass",started_at:$started_at})' "$REQUIRED_PR_CHECKS_FILE")"
  GH_MERGE_SHA="$M2"
  run_merge_lane || :
  [[ "${GH_MERGES[0]:-}" == *"pr merge 11"* && "$(field pr-adopt .stage)" == merged ]] || fail 'post-adoption green rows did not merge'
  # A later synchronize event has already launched CI because the adoption label remains on
  # the PR. Advancing the ledger head must preserve the first label timestamp, not label again
  # or move the freshness floor past those synchronize checks.
  adopt_at="$(field pr-adopt .ci_adopt_at)"
  GH_HEAD="$H2"; GH_MERGE_SHA="$M3"
  units "$(jq -cn --arg old "$H1" --arg head "$H2" --arg at "$adopt_at" '{units:[{id:"pr-adopt-next-head",pr:11,branch:"fix/dispatch-unique-sku-unit",stage:"ready-to-merge",approved_sha:$head,ci_adopt_head:$old,ci_adopt_at:$at,history:[]}]}')"
  GH_MERGES=(); run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 && "$(field pr-adopt-next-head .ci_adopt_head)" == "$H2" ]] \
    || fail 'a new adopted head was not recorded before reading synchronize checks'
  [[ "$(field pr-adopt-next-head .ci_adopt_at)" == "$adopt_at" ]] \
    || fail 'a synchronize head reset the adoption freshness floor after CI had started'
  [[ "$(wc -l < "$fixture/pr-edit.calls")" == 1 ]] || fail 'a new head re-added the existing pipeline-ci label'
  run_merge_lane || :
  [[ "${GH_MERGES[0]:-}" == *"pr merge 11"* && "$(field pr-adopt-next-head .stage)" == merged ]] \
    || fail 'fresh synchronize checks on an already-adopted label did not merge'
  # #4484：分支自带的 workflow 先于聚合 job 的，永远没有聚合行：落后 main 且干净就服务端
  # update-branch 刷新分支 workflow（批准由 approval_carries 沿用），不再永久等待。
  UPDATE_BRANCH_CALLS="$fixture/update-branch.calls"; : > "$UPDATE_BRANCH_CALLS"
  ci_update_branch_saved="$(declare -f ci_update_branch)"; pr_behind_saved="$(declare -f pr_behind_main)"
  ci_update_branch() { printf '%s %s\n' "$1" "$2" >> "$UPDATE_BRANCH_CALLS"; return 0; }
  pr_behind_main() { return 0; }
  pr_view_saved="$(declare -f pr_view)"
  pr_view() { case "$2" in state) echo OPEN ;; headRefOid) echo "$GH_HEAD" ;; mergeable) echo "${GH_MERGEABLE_STATE:-MERGEABLE}" ;; mergeCommit) echo "$GH_MERGE_SHA" ;; *) echo "" ;; esac; }
  GH_HEAD="$H1"; GH_MERGEABLE_STATE=MERGEABLE
  GH_CHECKS='[{"name":"Enforce branch delivery policy","bucket":"pass"}]'
  GH_PR_TABLE="$fixture/pr-stale-wf.json"; echo '[]' > "$GH_PR_TABLE"
  stale_wf_checks="$(jq -cn '[{__typename:"CheckRun",name:"Enforce branch delivery policy",status:"COMPLETED",conclusion:"SUCCESS"}]')"
  gh_pr_open 11 "$H1" false MERGEABLE agent/issue-11 "$stale_wf_checks"
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-stale-wf",pr:11,branch:"agent/issue-11",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  GH_MERGES=(); : > "$LOG"; run_merge_lane || :
  [[ "$(cat "$UPDATE_BRANCH_CALLS")" == "11 $H1" && ${#GH_MERGES[@]} == 0 ]] || fail 'a missing aggregate row on a stale branch did not request update-branch'
  grep -Fq 'update-branch refreshes the branch workflows' "$LOG" || fail 'the workflow refresh lacks its log line'
  [[ "$(field pr-stale-wf .ci_sync_head)" == "$H1" ]] || fail 'the workflow refresh was not pinned to the head'
  # 同一 head 不重复请求；冲突照旧派修复合 main。
  : > "$UPDATE_BRANCH_CALLS"
  run_merge_lane || :
  [[ -s "$UPDATE_BRANCH_CALLS" ]] && fail 'update-branch was requested twice for the same head'
  GH_MERGEABLE_STATE=CONFLICTING
  jq -c 'map(.mergeable = "CONFLICTING")' "$GH_PR_TABLE" > "$GH_PR_TABLE.tmp" && mv "$GH_PR_TABLE.tmp" "$GH_PR_TABLE"
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-stale-wf2",pr:11,branch:"agent/issue-11",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  run_merge_lane || :
  [[ "$(field pr-stale-wf2 .stage)" == repair-pending ]] || fail 'a conflicting stale branch was not routed to repair'
  eval "$pr_view_saved"; eval "$ci_update_branch_saved"; eval "$pr_behind_saved"
  unset GH_MERGEABLE_STATE GH_PR_TABLE
  # 2026-11-08 PR#5707: a PR red on a check that is green on main has a base from before main's fix. One update-branch
  # per unit and failed-check set, then the normal path; "check failed" is never logged as "pending or unavailable".
  UPDATE_BRANCH_CALLS="$fixture/green-main-update.calls"; : > "$UPDATE_BRANCH_CALLS"
  ci_update_branch() { printf '%s %s\n' "$1" "$2" >> "$UPDATE_BRANCH_CALLS"; return 0; }
  pr_behind_main() { return 0; }
  pr_view() { case "$2" in state) echo OPEN ;; headRefOid) echo "$GH_HEAD" ;; mergeable) echo MERGEABLE ;; mergeCommit) echo "$GH_MERGE_SHA" ;; *) echo "" ;; esac; }
  gh_green_stub="$(declare -f gh)"
  gh() { if [[ "$1 $2" == "api repos/{owner}/{repo}/commits/$M1/check-runs?per_page=100" ]]; then echo "$MAIN_RUNS"; else eval "${gh_green_stub/gh ()/gh_g ()}"; gh_g "$@"; fi; }
  gate='Release suites PR gate (release-entry shard)'
  MAIN_RUNS="$(jq -cn --arg n "$gate" '{check_runs:[{name:$n,conclusion:"success"},{name:"other",conclusion:"failure"}]}')"
  GH_HEAD="$H1"; GH_MERGES=()
  GH_CHECKS="$(jq -cn --arg n "$gate" '[{name:$n,bucket:"fail"},{name:"contract",bucket:"pass"}]')"
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-green-main",pr:11,branch:"agent/issue-11",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  : > "$LOG"; run_merge_lane || :
  [[ "$(cat "$UPDATE_BRANCH_CALLS")" == "11 $H1" && ${#GH_MERGES[@]} == 0 && "$(field pr-green-main .stage)" == ready-to-merge \
      && "$(field pr-green-main '.history[-1].stage')" == ci-red-green-on-main-update ]] || fail 'a red check that is green on main did not get one update-branch'
  grep -Fq "check failed: $gate; green on main" "$LOG" || fail 'the stale-base update lacks the check failed log line'
  # Same failed checks on the updated head (new SHA, still behind a moving main): no second update-branch, the failure is named.
  : > "$UPDATE_BRANCH_CALLS"; GH_HEAD="$H2"
  GH_CHECKS="$(jq -cn --arg n "$gate" '[{name:$n,bucket:"fail"},{name:"Required CI gates",bucket:"pending"}]')"
  jq -c --arg sha "$H2" '.units[0].approved_sha=$sha' "$UNITS" > "$UNITS.tmp" && mv "$UNITS.tmp" "$UNITS"
  : > "$LOG"; run_merge_lane || :
  [[ ! -s "$UPDATE_BRANCH_CALLS" ]] || fail 'the updated head got a second update-branch for the same failed check'
  grep -Fq "merge skipped PR#11 (check failed: $gate; other checks still pending)" "$LOG" || fail 'a completed failure beside a pending check lacks the check failed label'
  ! grep -Fq 'pending or unavailable' "$LOG" || fail 'a completed failure was logged as pending or unavailable'
  # A check that is not green on main gets no hop; pending-only keeps the old label.
  MAIN_RUNS='{"check_runs":[]}'; CI_MAIN_GREEN_CHECKS_CACHE=()
  GH_HEAD="$H1"
  GH_CHECKS="$(jq -cn --arg n "$gate" '[{name:$n,bucket:"fail"},{name:"Required CI gates",bucket:"pending"}]')"
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-red-main-red",pr:11,branch:"agent/issue-11",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  run_merge_lane || :
  [[ ! -s "$UPDATE_BRANCH_CALLS" ]] || fail 'a check that is not green on main still triggered the update-branch hop'
  GH_CHECKS='[{"name":"Required CI gates","bucket":"pending"}]'
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-pending",pr:11,branch:"agent/issue-11",stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  : > "$LOG"; run_merge_lane || :
  grep -Fq 'merge skipped PR#11 (checks pending or unavailable)' "$LOG" || fail 'a pending check lost the pending or unavailable label'
  eval "$gh_green_stub"; eval "$pr_view_saved"; eval "$ci_update_branch_saved"; eval "$pr_behind_saved"
  GH_CHECKS="$passing_checks"
  REQUIRED_PR_CHECKS_FILE="$fixture/absent-required-pr-checks.json"
  units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-required",pr:11,stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"
  GH_MERGES=(); GH_RERUNS=(); : > "$LOG"
  run_merge_lane || :
  [[ ${#GH_MERGES[@]} == 0 && ${#GH_RERUNS[@]} == 0 && "$(field pr-required .stage)" == ready-to-merge ]] || fail 'unreadable required checks did not block without side effects'
  grep -Fq 'merge skipped PR#11 (required checks without a real pass: required-pr-checks.json unreadable)' "$LOG" || fail 'unreadable required checks lack the reason'
)

echo 'scheduler-gates-required-checks.test.sh: PASS'
