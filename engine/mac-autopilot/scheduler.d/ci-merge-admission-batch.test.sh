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
    'api --allow-escape-sequences')
      [[ "${3:-}" == 'repos/{owner}/{repo}/actions/jobs/123/logs' ]] || return 98
      cat "$GH_JOB_LOG"
      ;;
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

run_ci_facts_case() {
  local output facts i
  GH_JOB_LOG="$fixture/no-marker-job.log"
  : > "$GH_JOB_LOG"
  for ((i = 1; i <= 13; i++)); do
    printf '2026-11-11T20:13:58.0919699Z 291 : ┆ [5m29s] |  FAIL  tests/a.test.ts > suite > test-%02d\n' "$i" >> "$GH_JOB_LOG"
  done
  output="$(ci_test_red_checks '[{"bucket":"fail","name":"Touched packages PR gate","link":"https://example.invalid/job/123"}]')"
  [[ "$(head -n 1 <<<"$output")" == 'Touched packages PR gate' ]] || fail "raw Dagger test failures were not recognized ($(head -n 1 <<<"$output"))"
  facts="$(tail -n +2 <<<"$output")"
  jq -e '(.suites | length) == 1
    and .suites[0].file == "tests/a.test.ts"
    and (.suites[0].tests | length) == 12
    and .suites[0].tests[0].name == "suite > test-01"
    and .suites[0].tests[11].name == "suite > test-12"' <<<"$facts" >/dev/null \
    || fail "raw Dagger test facts did not include the stripped file/test paths with a 12-test cap ($facts)"

  GH_JOB_LOG="$fixture/marker-job.log"
  cat > "$GH_JOB_LOG" <<'LOG'
2026-11-11T20:13:58.0919699Z 291 : ┆ [5m29s] |  FAIL  tests/fallback.test.ts > suite > ignored fallback
ZENOFORGE-FAIL-FACTS {"suites":[{"file":"tests/marked.test.ts","tests":[{"name":"marked test"}]}]}
LOG
  output="$(ci_test_red_checks '[{"bucket":"fail","name":"Fruit industry pack PR gate","link":"https://example.invalid/job/123"}]')"
  facts="$(tail -n +2 <<<"$output")"
  [[ "$facts" == '{"suites":[{"file":"tests/marked.test.ts","tests":[{"name":"marked test"}]}]}' ]] \
    || fail "existing ZENOFORGE-FAIL-FACTS marker did not retain precedence ($facts)"
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
  ci-facts)
    run_ci_facts_case
    echo 'ci-merge-admission-batch.test.sh ci-facts: pass (Dagger raw failures become bounded facts; explicit marker remains authoritative)'
    ;;
  all)
    run_ci_batch_case
    run_ci_zero_slot_case
    run_merge_empty_case
    run_ci_facts_case
    echo 'ci-merge-admission-batch.test.sh: pass (30 PRs use one census; zero-slot admission makes no per-PR reads; empty merge lane makes no GitHub calls; Dagger failures produce bounded facts)'
    ;;
  *) fail "unknown test mode: $1" ;;
esac
