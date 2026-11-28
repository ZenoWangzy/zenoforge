#!/usr/bin/env bash
# 复发守卫（2026-11-04 vecta main 384831fce1 红一下午无人发现）：merge_gate.main_workflow 配置了替代门禁
# 工作流（产品仓库删掉 pipeline-suites.yml 后配它必需的 "CI"）时——门禁随配置激活（不因 pipeline-suites.yml
# 缺席退役），run 只查配置的工作流；红 main 给一条点名 SHA + 失败 job 的 GATE 告警并走既有 main-red 路径
# （首红重跑一次排 infra、重跑后仍红开 fix-forward 直落单元、回退后不代派 pipeline-suites.yml）；
# 绿 main 不产生任何红告警/单元；缺 run 走既有 missing 处理（GATE unknown、流水线 PR 挂起）。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/test-scheduler-gates-fixture.sh"
fail() { echo "scheduler-gates-main-workflow.test.sh: $*" >&2; exit 1; }
units() { reset_gate_fixture_reads; printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
H1=1111111111111111111111111111111111111111
M2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
source "$script_dir/test-scheduler-gates-gh-fixture.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
alive() { [[ " ${ALIVE_PIDS:-} " == *" $1 "* ]]; }
ensure_clone() { printf '%s' "$fixture/wt-$1"; }
checkout_pr_head() { :; }
MAIN_HEAD="$M2"
git() {
  if [[ " $* " == *" ls-remote "* ]]; then printf '%s\trefs/heads/main\n' "$MAIN_HEAD"
  elif [[ "${1:-}" == -C && "${3:-}" == fetch && ( "${!#}" == refs/pull/*/head || "${!#}" == +refs/pull/*/head:refs/autopi/merge-candidates/* ) ]]; then return 0
  elif [[ "${1:-}" == -C && "${3:-}" == rev-parse && ( "${5:-}" == FETCH_HEAD* || "${5:-}" == refs/autopi/merge-candidates/* ) ]]; then echo "$GH_HEAD"
  else command git "$@"; fi
}
mkdir -p "$ROOT/engine"
printf '#!/usr/bin/env bash\nprintf "rule-lane: decision=pass actor=%%s touched=0\\n" "${ZF_AGENT_NAME:-unit}"\n' > "$ROOT/engine/rule-lane.sh"
GH_HEAD="$H1"; GH_MERGE_SHA="$M2"
: > "$A/alerts/gate.md"
gate_alerts_since() { tail -n +"$(( ${1:-0} + 1 ))" "$A/alerts/gate.md" 2>/dev/null; }
pipeline_unit() { # id pr → 一个已批准的流水线 PR（必需检查行叫 Pipeline suites）
  jq -cn --arg id "$1" --argjson pr "$2" --arg sha "$H1" \
    '{units:[{id:$id,pr:$pr,stage:"ready-to-merge",lane:"pr",approved_sha:$sha,history:[]}]}'
}

# 目标仓库：没有 pipeline-suites.yml（#4860 已删），main 门禁配到它必需的 CI 工作流。
wf_repo="$fixture/wf-main-gate-repo"; rm -rf "$wf_repo"
command git init -q -b main "$wf_repo"
command git -C "$wf_repo" config user.email t@example.invalid; command git -C "$wf_repo" config user.name t
mkdir -p "$wf_repo/engine"
cp -- "$ROOT/engine/rule-lane.sh" "$wf_repo/engine/rule-lane.sh"
echo base > "$wf_repo/base.txt"
command git -C "$wf_repo" add -A; command git -C "$wf_repo" commit -qm 'green base'
green_sha="$(command git -C "$wf_repo" rev-parse HEAD)"
echo red > "$wf_repo/red.txt"
command git -C "$wf_repo" add -A; command git -C "$wf_repo" commit -qm 'red head'
red_sha="$(command git -C "$wf_repo" rev-parse HEAD)"
command git -C "$wf_repo" update-ref refs/remotes/origin/main "$red_sha"
wf_root_saved="$ROOT"; ROOT="$wf_repo"
CFG="$(jq '.merge_gate.main_workflow="CI"' <<<"$CFG")"

# gh 只答配置的工作流：CI 的 main run 来自夹具；Pipeline suites 的查询/派发一次都不该有。
wf_gh_saved="$(declare -f gh)"
SUITES_RUN_QUERIES=0; SUITES_DISPATCHES=0; GH_CI_RUNS='[]'; GH_CHECK_RUNS='{"check_runs":[]}'
gh() {
  if [[ "$1 $2" == "run list" && "$*" == *"--workflow CI"* ]]; then printf '%s\n' "$GH_CI_RUNS"; return 0; fi
  if [[ "$1 $2" == "run list" && "$*" == *"--workflow Pipeline suites"* ]]; then
    SUITES_RUN_QUERIES=$((SUITES_RUN_QUERIES + 1)); printf '[]\n'; return 0
  fi
  if [[ "$1 $2" == "workflow run" && "$*" == *pipeline-suites.yml* ]]; then
    SUITES_DISPATCHES=$((SUITES_DISPATCHES + 1)); return 0
  fi
  if [[ "$1" == api ]]; then
    # GH_CHECK_RUNS 只答 main 两个 run head 的读取（main-red 分类）；PR 自己 head 的 check-runs
    # 走下面包着的共享夹具（无表模式由 GH_CHECKS 转成 REST 行），否则 PR 会读到 main 的红行
    case "$2" in repos/*/*/commits/"$red_sha"/check-runs*|repos/*/*/commits/"$green_sha"/check-runs*) printf '%s\n' "$GH_CHECK_RUNS"; return 0 ;; esac
  fi
  eval "${wf_gh_saved/gh ()/gh_wf ()}"; gh_wf "$@"
}
GH_CHECKS='[{"name":"Pipeline suites","bucket":"pass"}]'
red_runs() { # attempt → main HEAD 上一次完成的 CI 失败 run + 此前的绿 run
  jq -cn --argjson attempt "$1" --arg red "$red_sha" --arg green "$green_sha" \
    '[
      {headSha:$green,status:"completed",conclusion:"success",createdAt:"2026-11-04T14:00:00Z",databaseId:700,attempt:1},
      {headSha:$red,status:"completed",conclusion:"failure",createdAt:"2026-11-04T15:25:23Z",databaseId:701,attempt:$attempt}
    ]'
}
# TS2769 是代码失败（不是 infra）；没有 FAILED suite= 行，landed-red 快速路径不该开单元
GH_LOG='src/entity-link-writer.ts:126:34 - error TS2769: No overload matches this call.'
GH_CHECK_RUNS='{"check_runs":[{"name":"Postsubmit validate","conclusion":"failure"},{"name":"Migration SQL Gate","conclusion":"success"}]}'
rerun_count() { printf '%s\n' "${#GH_RERUNS[@]}"; }

# ---------- 红 main（首见）：一条点名 SHA + 失败 job 的 GATE 告警；重跑预约记录配置的工作流 ----------
rm -f "$A/gate-net-rerun.json"
GH_CI_RUNS="$(red_runs 1)"
mark="$(wc -l < "$A/alerts/gate.md")"; reruns_before="$(rerun_count)"
units "$(pipeline_unit pr-91 91)"
GH_MERGES=(); run_merge_lane || :
red_alerts="$(gate_alerts_since "$mark")"
[[ "$(grep -c 'GATE class=code' <<<"$red_alerts")" -eq 1 ]] || fail "red main on the configured workflow did not write exactly one GATE alert: $(grep 'GATE ' <<<"$red_alerts" || true)"
grep -q "GATE class=code main=$red_sha.*failing checks: Postsubmit validate" <<<"$red_alerts" \
  || fail "the red alert does not name the SHA and the failing job: $(grep 'GATE class=code' <<<"$red_alerts")"
[[ "$(jq -r --arg k "$red_sha" '.[$k].workflow // empty' "$A/gate-net-rerun.json")" == CI ]] \
  || fail "retry reservation recorded the wrong workflow: $(cat "$A/gate-net-rerun.json")"
[[ "$(rerun_count)" -gt "$reruns_before" ]] || fail 'red main did not request the one rerun that rules out infra'
[[ ${#GH_MERGES[@]} -eq 0 ]] || fail "pipeline PR merged on a red main ($(field pr-91 .stage))"
if jq -e --arg red "$red_sha" 'any(.units[]; .main_red == true and .ci_sha == $red)' "$UNITS" >/dev/null; then
  fail 'a main-red unit opened before the rerun verdict came back'
fi

# ---------- 重跑后仍红（attempt 2）：开 fix-forward 直落单元（既有 main-red 路径） ----------
GH_CI_RUNS="$(red_runs 2)"
MAIN_SUITES_RUNS_LOADED=false; MAIN_SUITES_RUNS=""
mark="$(wc -l < "$A/alerts/gate.md")"
units "$(pipeline_unit pr-91 91)"
GH_MERGES=(); run_merge_lane || :
red_id="main-red-${red_sha:0:9}"
[[ "$(field "$red_id" .stage)" == implement-pending ]] || fail "a still-red rerun did not open the fix-forward main-red unit ($(field "$red_id" .stage))"
[[ "$(field "$red_id" .lane)" == direct-main ]] || fail "the main-red unit is not a direct-main unit"
[[ "$(field "$red_id" .title)" == "fix red main CI at ${red_sha:0:9}" ]] || fail "the main-red unit title does not name the configured workflow ($(field "$red_id" .title))"
grep -q "MAIN-RED unit=$red_id main=$red_sha run=701" <<<"$(gate_alerts_since "$mark")" \
  || fail 'the main-red unit opening was not alerted'
[[ "$(gate_alerts_since "$mark" | grep -c 'GATE class=')" -eq 1 ]] \
  || fail "the red state change wrote more than one GATE alert: $(gate_alerts_since "$mark" | grep 'GATE ')"
[[ ${#GH_MERGES[@]} -eq 0 ]] || fail 'pipeline PR merged while main is still red after the rerun'

# ---------- 同样的红再跑一拍：告警不重复（gate_note 去重）、单元不重复（车道幂等）；ledger 原样保留 ----------
mark="$(wc -l < "$A/alerts/gate.md")"
GH_MERGES=(); run_merge_lane || :
[[ -z "$(gate_alerts_since "$mark")" ]] || fail "an unchanged red state re-alerted: $(gate_alerts_since "$mark")"
[[ "$(jq -r '[.units[] | select(.main_red == true)] | length' "$UNITS")" -eq 1 ]] \
  || fail 'an unchanged red state opened a second main-red unit'

# ---------- 绿 main：什么都不产生（无红告警、无单元、无重跑），流水线 PR 照合 ----------
GH_CI_RUNS="$(jq -cn --arg sha "$red_sha" '[{headSha:$sha,status:"completed",conclusion:"success",createdAt:"2026-11-04T16:00:00Z",databaseId:710,attempt:1}]')"
MAIN_SUITES_RUNS_LOADED=false; MAIN_SUITES_RUNS=""
rm -f "$A/gate-net-rerun.json"
mark="$(wc -l < "$A/alerts/gate.md")"; reruns_before="$(rerun_count)"
units "$(pipeline_unit pr-92 92)"
GH_MERGES=(); run_merge_lane || :
[[ "${GH_MERGES[0]:-}" == *"pr merge 92"* ]] || fail "green main on the configured workflow held a pipeline PR ($(field pr-92 .stage))"
green_alerts="$(gate_alerts_since "$mark")"
! grep -qE 'class=|merge lane held|MAIN-RED|LANDED-RED|REVERTED' <<<"$green_alerts" \
  || fail "green main produced red-path alerts: $green_alerts"
if jq -e 'any(.units[]; .main_red == true)' "$UNITS" >/dev/null; then fail 'green main opened a main-red unit'; fi
[[ "$(rerun_count)" -eq "$reruns_before" ]] || fail 'green main requested a rerun'

# ---------- 缺 run：既有 missing 处理（GATE unknown、流水线 PR 挂起），不是退役放行，也不是红单元 ----------
GH_CI_RUNS='[]'
MAIN_SUITES_RUNS_LOADED=false; MAIN_SUITES_RUNS=""
mark="$(wc -l < "$A/alerts/gate.md")"; reruns_before="$(rerun_count)"
units "$(pipeline_unit pr-93 93)"
GH_MERGES=(); run_merge_lane || :
missing_alerts="$(gate_alerts_since "$mark")"
grep -q "GATE class=unknown main=$red_sha run=unknown; CI missing/no-verdict on $red_sha" <<<"$missing_alerts" \
  || fail "a missing run on the configured workflow did not get the existing missing handling: $(grep 'GATE ' <<<"$missing_alerts" || true)"
grep -q 'merge lane held' <<<"$missing_alerts" || fail 'missing run did not hold pipeline PRs'
! grep -q 'retired' <<<"$missing_alerts" || fail 'a configured gate got retired just because pipeline-suites.yml is absent'
[[ ${#GH_MERGES[@]} -eq 0 ]] || fail 'pipeline PR merged with no gate run at all'
if jq -e 'any(.units[]; .main_red == true)' "$UNITS" >/dev/null; then fail 'a missing run opened a main-red unit'; fi
[[ "$(rerun_count)" -eq "$reruns_before" ]] || fail 'a missing run requested a rerun'

# ---------- 配置的工作流自始至终取代 Pipeline suites：零查询、零派发 ----------
[[ "$SUITES_RUN_QUERIES" -eq 0 ]] || fail "the gate still queried Pipeline suites runs ($SUITES_RUN_QUERIES times)"
[[ "$SUITES_DISPATCHES" -eq 0 ]] || fail "the gate dispatched pipeline-suites.yml ($SUITES_DISPATCHES times)"

# ---------- 红 main 的回退落地后：替代门禁工作流不代派 pipeline-suites.yml，只留一条操作者可见的说明 ----------
mr_dir_saved="$MAIN_RED_DIR"; MAIN_RED_DIR="$fixture/mr-wf-dir"; rm -rf "$MAIN_RED_DIR"; mkdir -p "$MAIN_RED_DIR"
revert_squash_merge() { return 0; }
printf 'culprit=%s suite=engine/x.test.sh first-red-run=701 green=%s\n' "$M2" "$green_sha" > "$MAIN_RED_DIR/$red_sha.report"
: > "$MAIN_RED_DIR/$red_sha.started"
: > "$LOG"
eval "$main_red_real"
MAIN_RED_REVERTED=0; main_red_attribution "$red_sha" 701 2 || :
[[ -e "$MAIN_RED_DIR/$red_sha.reverted" && "$MAIN_RED_REVERTED" == 1 ]] || fail 'the revert did not complete for a configured-workflow gate'
[[ "$SUITES_DISPATCHES" -eq 0 ]] || fail 'a configured-workflow repo still dispatched Pipeline suites after a revert'
grep -q 'CI run on the revert push verifies it; no pipeline-suites dispatch' "$LOG" \
  || fail "the revert verification path was not explained to the operator: $(tail -5 "$LOG")"
grep -q "MAIN-RED-REVERTED main=$red_sha" "$A/alerts/gate.md" || fail 'the revert alert is missing'
main_red_attribution() { MAIN_RED_REVERTED=0; MAIN_RED_PENDING=0; }
unset -f revert_squash_merge
MAIN_RED_DIR="$mr_dir_saved"

ROOT="$wf_root_saved"
echo 'scheduler-gates-main-workflow.test.sh: PASS'
