#!/usr/bin/env bash
# 复发守卫（2026-11-04 产品仓库 PR #4860）：目标仓库没有 .github/workflows/pipeline-suites.yml 时，
# main-suites 门禁退役——一条清晰告警（不随 main 提交重复）、不再查询/派发 suites、流水线 PR 不再永久挂起；
# 还保留该工作流的仓库照旧门禁；merge_gate.pipeline_suites=off 显式退役。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/test-scheduler-gates-fixture.sh"
fail() { echo "scheduler-gates-suites-retired.test.sh: $*" >&2; exit 1; }
units() { reset_gate_fixture_reads; printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
H1=1111111111111111111111111111111111111111
M1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
M2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
M3=cccccccccccccccccccccccccccccccccccccccc
source "$script_dir/test-scheduler-gates-gh-fixture.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
alive() { [[ " ${ALIVE_PIDS:-} " == *" $1 "* ]]; }
ensure_clone() { printf '%s' "$fixture/wt-$1"; }
checkout_pr_head() { :; }
MAIN_HEAD="$M3"
gate_eval_sha() { printf '%s\n' "$M3"; }
git() {
  if [[ " $* " == *" ls-remote "* ]]; then printf '%s\trefs/heads/main\n' "$MAIN_HEAD"
  elif [[ "${1:-}" == -C && "${3:-}" == fetch && ( "${!#}" == refs/pull/*/head || "${!#}" == +refs/pull/*/head:refs/autopi/merge-candidates/* ) ]]; then return 0
  elif [[ "${1:-}" == -C && "${3:-}" == rev-parse && ( "${5:-}" == FETCH_HEAD* || "${5:-}" == refs/autopi/merge-candidates/* ) ]]; then echo "$GH_HEAD"
  else command git "$@"; fi
}
mkdir -p "$ROOT/engine"
printf '#!/usr/bin/env bash\nprintf "rule-lane: decision=pass actor=%%s touched=0\\n" "${ZF_AGENT_NAME:-unit}"\n' > "$ROOT/engine/rule-lane.sh"
GH_RUNS='[]'
GH_HEAD="$H1"; GH_MERGE_SHA="$M2"
: > "$A/alerts/gate.md"
gate_alerts_since() { tail -n +"$(( ${1:-0} + 1 ))" "$A/alerts/gate.md" 2>/dev/null; }
pipeline_unit() { # id pr → 一个已批准的流水线 PR（必需检查行就叫 Pipeline suites）
  jq -cn --arg id "$1" --argjson pr "$2" --arg sha "$H1" \
    '{units:[{id:$id,pr:$pr,stage:"ready-to-merge",lane:"pr",approved_sha:$sha,history:[]}]}'
}

# ---------- 仓库没有 pipeline-suites.yml：门禁退役，一条告警，不随 main 前进重复 ----------
retired_repo="$fixture/retired-suites-repo"; rm -rf "$retired_repo"
command git init -q -b main "$retired_repo"
command git -C "$retired_repo" config user.email t@example.invalid; command git -C "$retired_repo" config user.name t
mkdir -p "$retired_repo/engine"
cp -- "$ROOT/engine/rule-lane.sh" "$retired_repo/engine/rule-lane.sh"
echo base > "$retired_repo/base.txt"
command git -C "$retired_repo" add -A; command git -C "$retired_repo" commit -qm base
command git -C "$retired_repo" update-ref refs/remotes/origin/main "$(command git -C "$retired_repo" rev-parse HEAD)"
retired_root_saved="$ROOT"; ROOT="$retired_repo"
retired_gh_saved="$(declare -f gh)"
SUITES_RUN_QUERIES=0; SUITES_DISPATCHES=0
gh() { # 记录对 main Pipeline suites run 的查询与派发：退役后一次都不该有
  [[ "$1 $2" == "run list" && "$*" == *"--workflow Pipeline suites"* ]] && SUITES_RUN_QUERIES=$((SUITES_RUN_QUERIES + 1))
  [[ "$1 $2" == "workflow run" && "$*" == *pipeline-suites.yml* ]] && SUITES_DISPATCHES=$((SUITES_DISPATCHES + 1))
  eval "${retired_gh_saved/gh ()/gh_ret ()}"; gh_ret "$@"
}
GH_CHECKS='[{"name":"Pipeline suites","bucket":"pass"}]'
gate_mark="$(wc -l < "$A/alerts/gate.md")"
units "$(pipeline_unit pr-87 87)"
GH_MERGES=(); run_merge_lane || :
[[ "${GH_MERGES[0]:-}" == *"pr merge 87"* ]] || fail "pipeline PR stayed held after the gate workflow left the repo ($(field pr-87 .stage))"
[[ "$SUITES_RUN_QUERIES" -eq 0 ]] || fail "a retired gate still queried Pipeline suites runs ($SUITES_RUN_QUERIES times)"
retired_alerts="$(gate_alerts_since "$gate_mark")"
[[ "$(grep -c 'GATE pipeline-suites retired.*absent from origin/main' <<<"$retired_alerts")" -eq 1 ]] \
  || fail "gate retirement was not reported once: $(grep 'retired' <<<"$retired_alerts" || true)"
! grep -q 'merge lane held' <<<"$retired_alerts" || fail 'retired gate still wrote a merge lane hold'
# main 前进一个提交：告警不重复（修复前的文本含提交 SHA，每个 main 提交刷一条 GATE unknown）
echo next > "$retired_repo/next.txt"
command git -C "$retired_repo" add -A; command git -C "$retired_repo" commit -qm 'main advanced'
command git -C "$retired_repo" update-ref refs/remotes/origin/main "$(command git -C "$retired_repo" rev-parse HEAD)"
units "$(pipeline_unit pr-88 88)"
GH_MERGES=(); run_merge_lane || :
[[ "${GH_MERGES[0]:-}" == *"pr merge 88"* ]] || fail "pipeline PR stayed held on a retired gate after main advanced ($(field pr-88 .stage))"
[[ "$(gate_alerts_since "$gate_mark" | grep -c 'GATE ')" -eq 1 ]] \
  || fail "retired gate kept alerting on later ticks: $(gate_alerts_since "$gate_mark" | grep 'GATE ')"

# 退役仓库的 main-red 回退不再派发 pipeline-suites.yml（工作流已不存在，派发只会失败）
retired_sha="$(command git -C "$retired_repo" rev-parse HEAD)"
mr_dir_saved="$MAIN_RED_DIR"; MAIN_RED_DIR="$fixture/mr-retired-dir"; rm -rf "$MAIN_RED_DIR"; mkdir -p "$MAIN_RED_DIR"
revert_squash_merge() { return 0; }
printf 'culprit=%s suite=engine/x.test.sh first-red-run=9 green=%s\n' "$M2" "$M3" > "$MAIN_RED_DIR/$retired_sha.report"
: > "$MAIN_RED_DIR/$retired_sha.started"
: > "$LOG"
eval "$main_red_real"
MAIN_RED_REVERTED=0; main_red_attribution "$retired_sha" 9 1 || :
[[ -e "$MAIN_RED_DIR/$retired_sha.reverted" && "$MAIN_RED_REVERTED" == 1 ]] || fail 'the revert itself did not complete before the dispatch decision'
[[ "$SUITES_DISPATCHES" -eq 0 ]] || fail 'a retired repo still dispatched Pipeline suites after a revert'
grep -q 'Pipeline suites dispatch skipped (gate retired' "$LOG" || fail 'the skipped dispatch was not logged for the operator'
main_red_attribution() { MAIN_RED_REVERTED=0; MAIN_RED_PENDING=0; }
unset -f revert_squash_merge
MAIN_RED_DIR="$mr_dir_saved"
eval "$retired_gh_saved"

# ---------- 还保留 pipeline-suites.yml 的仓库照旧门禁：main 红仍拦流水线 PR ----------
kept_repo="$fixture/kept-suites-repo"; rm -rf "$kept_repo"
command git init -q -b main "$kept_repo"
command git -C "$kept_repo" config user.email t@example.invalid; command git -C "$kept_repo" config user.name t
mkdir -p "$kept_repo/.github/workflows" "$kept_repo/engine"
cp -- "$ROOT/engine/rule-lane.sh" "$kept_repo/engine/rule-lane.sh"
cat > "$kept_repo/.github/workflows/pipeline-suites.yml" <<'YAML'
on:
  pull_request:
    paths:
      - 'engine/**'
  workflow_dispatch:
YAML
echo base > "$kept_repo/base.txt"
command git -C "$kept_repo" add -A; command git -C "$kept_repo" commit -qm base
command git -C "$kept_repo" update-ref refs/remotes/origin/main "$(command git -C "$kept_repo" rev-parse HEAD)"
ROOT="$kept_repo"; rm -f "$A/gate-net-rerun.json"
suites_run_for() { [[ "$1" == "$M3" ]] && jq -cn --arg sha "$1" '{headSha:$sha,status:"completed",conclusion:"failure",databaseId:9,attempt:1}'; }
kept_mark="$(wc -l < "$A/alerts/gate.md")"
units "$(pipeline_unit pr-89 89)"
GH_MERGES=(); run_merge_lane || :
[[ ${#GH_MERGES[@]} -eq 0 && "$(field pr-89 .stage)" == ready-to-merge ]] || fail 'a repo that still has pipeline-suites.yml lost its main suites gate'
grep -q 'merge lane held' <<<"$(gate_alerts_since "$kept_mark")" || fail 'red main suites in a workflow-bearing repo did not write the hold note'

# ---------- merge_gate.pipeline_suites=off 显式退役：即使工作流还在、main 还是红，流水线 PR 也照合 ----------
kept_cfg_saved="$CFG"; CFG="$(jq '.merge_gate.pipeline_suites="off"' <<<"$CFG")"
kept_mark="$(wc -l < "$A/alerts/gate.md")"
units "$(pipeline_unit pr-90 90)"
GH_MERGES=(); run_merge_lane || :
[[ "${GH_MERGES[0]:-}" == *"pr merge 90"* ]] || fail "merge_gate.pipeline_suites=off did not retire the gate ($(field pr-90 .stage))"
[[ "$(grep -c 'GATE pipeline-suites retired by config' <<<"$(gate_alerts_since "$kept_mark")")" -eq 1 ]] || fail 'config retirement was not reported once'
CFG="$kept_cfg_saved"; ROOT="$retired_root_saved"
unset -f suites_run_for
echo 'scheduler-gates-suites-retired.test.sh: PASS'
