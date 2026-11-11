#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"

fixture="$test_env_root/ci-merge-admission-batch"
supervisor="$fixture/supervisor"
mkdir -p "$supervisor/autopi/alerts" "$fixture/repo" "$fixture/empty-root"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$supervisor" \
  MAC_AUTOPILOT_RUNTIME_DIR="$supervisor/autopi" REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json" \
  GH_REPO="fixture-org/fixture-repo"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
jq '.precheck = false | .auto_merge = true | .batch_max = 1' \
  "$engine_dir/mac-autopilot/config.template.json" > "$supervisor/autopi/config.json"
echo '{"units":[]}' > "$supervisor/autopi/units.json"
echo '{"workers":[]}' > "$supervisor/autopi/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { printf 'ci-merge-admission-batch.test.sh: %s\n' "$*" >&2; exit 1; }
N=30
SLOTS=2
PRODUCT_PATHS_PER_TICK=30
export PRODUCT_PATHS_PER_TICK
GH_CALLS="$fixture/gh-calls"
CENSUS="$fixture/prs.json"
ROWS="$fixture/prs.tsv"
: > "$ROWS"
for ((i = 1; i <= N; i++)); do
  number=$((6000 + i))
  printf '%s\t%s\n' "$number" "$(printf '%040x' "$number")" >> "$ROWS"
done

make_census() {
  jq -Rn '[inputs | split("\t") | {number:(.[0]|tonumber), headRefName:("agent/issue-"+.[0]),
    headRefOid:.[1], baseRefName:"main", isDraft:false, title:"fixture", labels:[], body:"",
    mergeable:"MERGEABLE", statusCheckRollup:[],
    files:[{path:(if ((.[0]|tonumber) % 3 == 0) then "docs/fixture.md" else "src/fixture.ts" end)}]}]' < "$ROWS" > "$CENSUS"
}
make_units() {
  jq -Rn '{units:[inputs | split("\t") | {id:("unit-"+.[0]), pr:(.[0]|tonumber),
    branch:("agent/issue-"+.[0]), lane:"pr", stage:"ready-to-merge", approved_sha:.[1],
    ci_wip_wait:.[1], ready_since:(.[0]|tonumber), history:[]}]}' < "$ROWS" > "$UNITS"
}
make_census

gh() {
  printf '%s\n' "$*" >> "$GH_CALLS"
  case "${1:-} ${2:-}" in
    'pr list') cat "$CENSUS" ;;
    'pr view') printf 'src/fixture.ts\n' ;;
    'run list') printf '[]\n' ;;
    'api graphql') jq -c '{data:{repository:(map({key:("pr_"+(.number|tostring)),value:{files:{nodes:.files}}})|from_entries)}}' "$CENSUS" ;;
    *) return 97 ;;
  esac
}
ci_pr_free_slots() { printf '%s\n' "$SLOTS"; }
unfinished_runs() { printf '[]'; }
ci_jobs_prefetch() { :; }
pr_behind_main() { return 1; }
hotfix_issue_numbers() { TICK_HOTFIX_ISSUES='[]'; return 0; }

prepare_tick() {
  make_units
  : > "$GH_CALLS"
  TICK_PRS=''
  TICK_PR_CHECK_CENSUS=''
  TICK_PR_STATE=()
  TICK_UNFINISHED=''
  TICK_UNFINISHED_LOADED=false
  TICK_HOTFIX_ISSUES='[]'
  TICK_HOTFIX_ISSUES_LOADED=true
  GATED_OF=(); GATED_SLOT=(); READIED_PRS=()
  SCHED_LOCK_HELD=true
  STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  LOG="$fixture/scheduler.log"; : > "$LOG"
}
call_count() { awk -v a="$1" -v b="${2:-}" '$1 == a && (b == "" || $2 == b) { n++ } END { print n+0 }' "$GH_CALLS"; }
per_pr_read_count() {
  awk '($1 == "pr" && $2 == "view") || ($1 == "run" && $2 == "list" && $3 == "--commit") { n++ } END { print n+0 }' "$GH_CALLS"
}

run_ci_batch_case() {
  prepare_tick
  SLOTS=2
  ci_admission
  [[ "$(call_count pr list)" == 1 ]] || fail "30 PRs caused $(call_count pr list) open-PR list calls"
  [[ "$(call_count api graphql)" == 1 ]] || fail "30 PRs caused $(call_count api graphql) batched path queries"
  [[ "$(call_count pr view)" == 0 ]] || fail "product path classification made $(call_count pr view) per-PR reads"
  [[ "$(call_count run list)" == "$SLOTS" ]] || fail "expected $SLOTS bounded run-list reads, got $(call_count run list)"
  command jq -e 'all(.units[]; if (.pr % 3 == 0) then .product_paths == false else .product_paths == true end)' "$UNITS" >/dev/null \
    || fail 'batched PR file census changed product/non-product classification'
}

run_ci_zero_slot_case() {
  prepare_tick
  SLOTS=0
  ci_admission
  [[ "$(call_count pr list)" == 1 ]] || fail "zero-slot pass expected one census, got $(call_count pr list)"
  [[ "$(call_count api graphql)" == 1 ]] || fail "zero-slot pass expected one batched path query, got $(call_count api graphql)"
  [[ "$(per_pr_read_count)" == 0 ]] || fail "zero-slot pass made per-PR reads: $(cat "$GH_CALLS")"
}

run_merge_empty_case() {
  # With no merge-ready PRs, the lane should not refresh main, query the suites
  # run list, or prime the open-PR census. A blocked-PR retry remains separate.
  echo '{"units":[]}' > "$UNITS"
  ROOT="$fixture/empty-root"
  TICK_PRS=''; TICK_PR_CHECK_CENSUS=''; TICK_PR_STATE=()
  : > "$GH_CALLS"
  gate_eval_sha() { printf '%040x\n' 1; }
  run_merge_lane
  [[ ! -s "$GH_CALLS" ]] || fail "empty merge lane made GitHub calls: $(cat "$GH_CALLS")"
}

stuck_setup() {
  STUCK_PR=6001
  STUCK_HEAD="$(printf '%040x' "$STUCK_PR")"
  STUCK_BRANCH="agent/issue-$STUCK_PR"
  STUCK_NEW_HEAD="$(printf '%040x' 7001)"
  STUCK_TREE="$(printf '%040x' 7002)"
  STAMP=2026-11-11T22:00:00Z
  NOW_EPOCH="$(date -u -d "$STAMP" +%s)"
  CI_STUCK_UNQUEUED_SECONDS=1800
  ROOT="$fixture/repo"; MAIN_HEAD="$(printf '%040x' 7003)"
  CFG="$(jq -c . "$supervisor/autopi/config.json")"
  TICK_PR_STATE=(); TICK_PR_CHECK_CENSUS='{}'; TICK_PRS='[]'
  TICK_HOTFIX_ISSUES='[]'; TICK_HOTFIX_ISSUES_LOADED=true
  TICK_UNFINISHED_LOADED=true; TICK_UNFINISHED='[]'; TICK_UNFINISHED_ALL_OK=true
  CI_RUN_JOBS_CACHE=()
  SCHED_LOCK_HELD=true
  GH_CALLS="$fixture/stuck-gh-calls"; : > "$GH_CALLS"
  LOG="$fixture/stuck-scheduler.log"; : > "$LOG"
  command jq -cn --arg head "$STUCK_HEAD" --arg branch "$STUCK_BRANCH" \
    '{units:[{id:"unit-6001",pr:6001,branch:$branch,lane:"pr",stage:"ready-to-merge",approved_sha:$head,history:[]}]}' > "$UNITS"
  STUCK_READY="$(jq -cn --arg head "$STUCK_HEAD" --arg branch "$STUCK_BRANCH" \
    '{id:"unit-6001",pr:6001,branch:$branch,lane:"pr",stage:"ready-to-merge",approved_sha:$head,
      pr_open_head:$head,pr_open_draft:false,pr_open_mergeable:"MERGEABLE",pr_open_checks:[{name:"CI",bucket:"pending"}] }')"
  merge_candidates() { printf '%s\n' "$STUCK_READY"; }
  merge_gate_suites_active() { MERGE_GATE_SUITES_NOTE=""; return 1; }
  ci_classify_run() { :; }
  tick_prs_prime() { :; }
  merge_census_retry() { :; }
  tick_pr_mergeable() { printf 'MERGEABLE\n'; }
  unfinished_runs() { printf '%s' "$TICK_UNFINISHED"; }
  guarded_write() { "$@"; }
  git() {
    case " $* " in
      *" fetch -q origin main "*) return 0 ;;
      *" fetch -q --no-tags origin "*) return 0 ;;
      *" rev-parse -q --verify refs/remotes/origin/main "*) printf '%s\n' "$MAIN_HEAD" ;;
      *" rev-parse --verify refs/autopi/merge-candidates/"*) printf '%s\n' "$STUCK_HEAD" ;;
      *) command git "$@" ;;
    esac
  }
  gh() {
    printf '%s\n' "$*" >> "$GH_CALLS"
    case "$*" in
      *'--method GET repos/{owner}/{repo}/git/commits/'*) printf '%s\n' "$STUCK_TREE" ;;
      *'--method POST repos/{owner}/{repo}/git/commits'*) printf '%s\n' "$STUCK_NEW_HEAD" ;;
      *'--method PATCH repos/{owner}/{repo}/git/refs/heads/'*) printf '%s\n' "$STUCK_NEW_HEAD" ;;
      *) return 97 ;;
    esac
  }
}

stuck_runs() {
  local first_at="$1" second_at="${2:-$1}"
  TICK_UNFINISHED="$(jq -cn --arg head "$STUCK_HEAD" --arg branch "$STUCK_BRANCH" \
    --arg a "$first_at" --arg b "$second_at" \
    '[{databaseId:7301,event:"pull_request",headSha:$head,headBranch:$branch,status:"queued",createdAt:$a},
      {databaseId:7302,event:"pull_request",headSha:$head,headBranch:$branch,status:"queued",createdAt:$b}]')"
  CI_RUN_JOBS_CACHE[7301]='[]'; CI_RUN_JOBS_CACHE[7302]='[]'
}

stuck_target_run() {
  local completed_at="$1" target_at="$2"
  TICK_UNFINISHED="$(jq -cn --arg head "$STUCK_HEAD" --arg branch "$STUCK_BRANCH" \
    --arg completed_at "$completed_at" --arg target_at "$target_at" \
    '[{databaseId:7303,event:"pull_request",headSha:$head,headBranch:$branch,status:"completed",createdAt:$completed_at},
      {databaseId:7304,event:"pull_request_target",headSha:$head,headBranch:$branch,status:"queued",createdAt:$target_at}]')"
  CI_RUN_JOBS_CACHE=()
  CI_RUN_JOBS_CACHE[7304]='[]'
  unfinished_runs() { command jq -c '[.[] | select(.status != "completed")]' <<<"$TICK_UNFINISHED"; }
}

run_stuck_unqueued_case() {
  stuck_setup
  stuck_runs "$(date -u -d "$STAMP - 45 minutes" +%Y-%m-%dT%H:%M:%SZ)" \
    "$(date -u -d "$STAMP - 40 minutes" +%Y-%m-%dT%H:%M:%SZ)"
  run_merge_lane_pass
  [[ "$(call_count api --method)" == 3 ]] || fail "stale zero-job runs did not make the tree GET, commit POST and ref PATCH: $(cat "$GH_CALLS")"
  grep -Fq 'STUCK-UNQUEUED unit=unit-6001 PR#6001' "$LOG" || fail 'stale zero-job run was not logged with its unit and PR'
  grep -Fq "head=$STUCK_HEAD" "$LOG" && grep -Fq 'run_ids=7301,7302' "$LOG" \
    || fail 'STUCK-UNQUEUED did not name the head and all run ids'
  grep -Fq -- '--method POST repos/{owner}/{repo}/git/commits' "$GH_CALLS" \
    || fail 'retrigger did not create an empty commit through the git API'
  grep -Fq "tree=$STUCK_TREE" "$GH_CALLS" && grep -Fq "parents[]=$STUCK_HEAD" "$GH_CALLS" \
    || fail 'commit POST did not reuse the head tree and parent'
  grep -Fq -- "--method PATCH repos/{owner}/{repo}/git/refs/heads/$STUCK_BRANCH" "$GH_CALLS" \
    && grep -Fq 'force=false' "$GH_CALLS" || fail 'retrigger did not update the branch without force'
  command jq -e --arg head "$STUCK_HEAD" '.units[0].ci_unqueued_retrigger_head == $head
    and any(.units[0].history[]; .stage == "ci-stuck-unqueued")' "$UNITS" >/dev/null \
    || fail 'unit did not record the retriggered head and history'
  : > "$GH_CALLS"; : > "$LOG"
  run_merge_lane_pass
  [[ ! -s "$GH_CALLS" ]] || fail "same head retriggered twice: $(cat "$GH_CALLS")"

  stuck_setup
  stuck_target_run "$(date -u -d "$STAMP - 45 minutes" +%Y-%m-%dT%H:%M:%SZ)" \
    "$(date -u -d "$STAMP - 40 minutes" +%Y-%m-%dT%H:%M:%SZ)"
  run_merge_lane_pass
  grep -Fq 'STUCK-UNQUEUED unit=unit-6001 PR#6001' "$LOG" \
    || fail 'stale pull_request_target run was not retriggered after pull_request completed'
  grep -Fq "run_ids=7304" "$LOG" || fail 'completed pull_request run was included in the retrigger'
  [[ "$(awk '$1 == "api" && $2 == "--method" && $3 == "POST" && $4 == "repos/{owner}/{repo}/git/commits" { n++ } END { print n+0 }' "$GH_CALLS")" == 1 ]] \
    || fail "pull_request_target retrigger did not create exactly one empty commit: $(cat "$GH_CALLS")"
  [[ "$(awk -v endpoint="repos/{owner}/{repo}/git/refs/heads/$STUCK_BRANCH" \
    '$1 == "api" && $2 == "--method" && $3 == "PATCH" && $4 == endpoint && index($0, "force=false") > 0 { n++ } END { print n+0 }' "$GH_CALLS")" == 1 ]] \
    || fail "pull_request_target retrigger did not make exactly one force=false ref update: $(cat "$GH_CALLS")"

  stuck_setup
  stuck_runs "$(date -u -d "$STAMP - 10 minutes" +%Y-%m-%dT%H:%M:%SZ)"
  run_merge_lane_pass
  [[ ! -s "$GH_CALLS" ]] || fail "young queued runs were retriggered: $(cat "$GH_CALLS")"

  stuck_setup
  stuck_runs "$(date -u -d "$STAMP - 45 minutes" +%Y-%m-%dT%H:%M:%SZ)"
  CI_RUN_JOBS_CACHE[7302]='[{"status":"queued"}]'
  run_merge_lane_pass
  [[ ! -s "$GH_CALLS" ]] || fail "a queued run with jobs was retriggered: $(cat "$GH_CALLS")"

  stuck_setup
  STUCK_BRANCH=main
  STUCK_READY="$(jq -c --arg head "$STUCK_HEAD" '.branch="main" | .ci_adopt_head=$head' <<<"$STUCK_READY")"
  command jq --arg head "$STUCK_HEAD" '.units[0].branch="main" | .units[0].ci_adopt_head=$head' "$UNITS" > "$fixture/main-branch-units.json"
  mv "$fixture/main-branch-units.json" "$UNITS"
  stuck_runs "$(date -u -d "$STAMP - 45 minutes" +%Y-%m-%dT%H:%M:%SZ)"
  run_merge_lane_pass
  [[ ! -s "$GH_CALLS" ]] || fail "main branch was retriggered: $(cat "$GH_CALLS")"

  stuck_setup
  STUCK_READY="$(jq -c --arg old "$(printf '%040x' 6999)" '.ci_unqueued_retrigger_head=$old' <<<"$STUCK_READY")"
  command jq --arg old "$(printf '%040x' 6999)" '.units[0].ci_unqueued_retrigger_head=$old' "$UNITS" > "$fixture/old-head-units.json"
  mv "$fixture/old-head-units.json" "$UNITS"
  stuck_runs "$(date -u -d "$STAMP - 45 minutes" +%Y-%m-%dT%H:%M:%SZ)"
  cancel_unit_runs() { :; }
  run_merge_lane_pass
  [[ ! -s "$GH_CALLS" ]] || fail "second stuck head was retriggered instead of escalated: $(cat "$GH_CALLS")"
  command jq -e '.units[0].stage == "supervisor-review"
    and any(.units[0].history[]; .stage == "supervisor-escalated")' "$UNITS" >/dev/null \
    || fail 'second stuck head did not escalate to supervisor-review'
}

case "${1:-all}" in
  ci-batch)
    run_ci_batch_case
    echo 'ci-merge-admission-batch.test.sh ci-batch: pass (30 PRs use one PR census and one GraphQL path batch; slot run reads stay bounded)'
    ;;
  ci-zero-slots)
    run_ci_zero_slot_case
    echo 'ci-merge-admission-batch.test.sh ci-zero-slots: pass (zero free slots make no per-PR reads)'
    ;;
  merge-empty)
    run_merge_empty_case
    echo 'ci-merge-admission-batch.test.sh merge-empty: pass (no merge-ready PRs means no GitHub calls)'
    ;;
  stuck-unqueued)
    run_stuck_unqueued_case
    echo 'ci-merge-admission-batch.test.sh stuck-unqueued: pass (stale empty queued runs retrigger once per head; young/job-bearing runs wait; second stuck head escalates)'
    ;;
  all)
    run_ci_batch_case
    run_ci_zero_slot_case
    run_merge_empty_case
    run_stuck_unqueued_case
    echo 'ci-merge-admission-batch.test.sh: pass (30 PRs use one census; zero-slot admission makes no per-PR reads; empty merge lane makes no GitHub calls; stuck unqueued CI retriggers once per head)'
    ;;
  *) fail "unknown test mode: $1" ;;
esac
