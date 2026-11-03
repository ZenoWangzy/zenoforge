#!/usr/bin/env bash
# 2026-11-03 labeled-draft starvation (PR#5284/#5283 shaped): full admission passes came ~22 min
# apart. At 14:39Z one failed open-PR census read paused the whole pass; at 15:01Z one failed
# runner census read skipped wip assignment. Both drafts carried the agent/ci-gated label while
# 7 PR runners idled and 0 runs queued, and no later pass ever flipped them. This suite pins the
# three guarantees that were missing: (1) a transient runner-census failure costs one retry, not
# the pass, and every admissible labeled draft is readied in that same pass, oldest first;
# (2) a failed PR census continues on the last good census while it is younger than
# CI_CENSUS_FALLBACK_MAX_AGE_SECONDS; (3) a fallback older than the bound pauses admission with
# exactly one log line.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"

fixture="$test_env_root/ci-admission-census-fallback"
supervisor="$fixture/supervisor"
mkdir -p "$supervisor/autopi/alerts" "$fixture/repo"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$supervisor/autopi" REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
jq '.precheck = false | .hotfix_lane = {"label":"hotfix","branch_prefixes":[]}' \
  "$engine_dir/mac-autopilot/config.template.json" > "$supervisor/autopi/config.json"
echo '{"units":[]}' > "$supervisor/autopi/units.json"
echo '{"workers":[]}' > "$supervisor/autopi/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

head_old="$(printf '%040x' 5283)"
head_new="$(printf '%040x' 5284)"

census_json() { # → two labeled agent/ci-gated drafts (the live 2026-11-03 census shape)
  command jq -cn --arg ho "$head_old" --arg hn "$head_new" '[
    {number:5283, headRefName:"agent/issue-4882", headRefOid:$ho, isDraft:true,
     labels:[{name:"agent/ci-gated"}], body:"", baseRefName:"main"},
    {number:5284, headRefName:"agent/issue-5087", headRefOid:$hn, isDraft:true,
     labels:[{name:"agent/ci-gated"}], body:"", baseRefName:"main"}
  ]'
}

census_fixture() { # name -> $td: two ready-to-merge draft units behind the gated label + shared stubs
  td="$test_env_root/$1"; mkdir -p "$td/alerts"
  A="$td"; LOG="$td/scheduler.log"; : > "$LOG"
  UNITS="$td/units.json"; WORKERS="$td/workers.json"
  STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; SCHED_LOCK_HELD=true
  TICK_PRS=''; TICK_PR_CHECK_CENSUS=''
  TICK_HOTFIX_ISSUES_LOADED=true; TICK_HOTFIX_ISSUES='[]'
  GATED_OF=(); GATED_SLOT=(); READIED_PRS=()
  SLOT_SYNC_CARRIED_HEAD=""; SLOT_SYNC_SPENT=0
  TICK_UNFINISHED_LOADED=true; TICK_UNFINISHED='[]'
  ready_log="$td/ready-calls"; : > "$ready_log"
  command jq -cn --arg ho "$head_old" --arg hn "$head_new" '{units:[
    {id:"issue-4882", pr:5283, branch:"agent/issue-4882", lane:"pr", stage:"ready-to-merge",
     approved_sha:$ho, product_paths:true, ready_since:1, history:[]},
    {id:"issue-5087", pr:5284, branch:"agent/issue-5087", lane:"pr", stage:"ready-to-merge",
     approved_sha:$hn, product_paths:true, ready_since:2, history:[]} ]}' > "$UNITS"
  echo '{"workers":[]}' > "$WORKERS"
  unfinished_runs() { printf '[]'; }
  ci_jobs_prefetch() { :; }
  approved_status_on() { return 0; }
  gated_status() { :; }
  pr_view() { return 1; }
  pr_behind_main() { return 1; } # heads are current: slot_sync hands the unit straight to its slot
  gh() {
    case "$*" in
      'pr ready 5283'|'pr ready 5284')
        printf '%s\n' "$*" >> "$ready_log"; return 0 ;;
      'pr list'*) return 1 ;; # census read fails; cases seed the cache or expect the pause
      *) echo "ci-admission-census-fallback.test.sh: unexpected gh call: $*" >&2; return 97 ;;
    esac
  }
  gh_api_cached() {
    [[ "${3:-}" == *actions/runners* ]] || return 1
    # 每次调用都在 $( ) 子 shell 里跑：用标记文件跨调用记住「第一次失败」
    if [[ -e "$td/runner-read-fail-once" ]]; then rm -f "$td/runner-read-fail-once"; return 1; fi
    printf 'false\nfalse\nfalse\nfalse\nfalse\nfalse\nfalse\ntrue\ntrue\ntrue\ntrue\ntrue' # 7 idle of 12
  }
}

# --- case 1: transient runner-census failure. One retry inside the pass, both labeled drafts
# readied in that same pass, oldest first; the slot count is cached for later fallbacks. ---
census_fixture runner-transient
TICK_PRS="$(census_json)"
: > "$td/runner-read-fail-once" # 瞬时失败：只在第一次 runner 读时
ci_admission
[[ "$(cat "$ready_log")" == $'pr ready 5283\npr ready 5284' ]] \
  || { echo "ci-admission-census-fallback.test.sh: expected both drafts readied oldest first, got: $(cat "$ready_log")" >&2; exit 1; }
command jq -e --arg ho "$head_old" --arg hn "$head_new" '
  ([.units[] | select(.id == "issue-4882")][0].ci_ready_sha == $ho)
  and ([.units[] | select(.id == "issue-5087")][0].ci_ready_sha == $hn)
  and (all(.units[]; .ci_wip_wait == null))' "$UNITS" >/dev/null \
  || { echo 'ci-admission-census-fallback.test.sh: ledger evidence after the ready flips is wrong' >&2; exit 1; }
grep -Fq 'PR runner capacity unavailable; admission skipped' "$LOG" && { echo 'ci-admission-census-fallback.test.sh: one runner-read failure skipped the whole pass' >&2; exit 1; }
command jq -e '.free_slots == 7' "$A/ci-runner-slots-cache.json" >/dev/null \
  || { echo 'ci-admission-census-fallback.test.sh: fresh runner slot count was not cached' >&2; exit 1; }

# --- case 2: census read fails twice. The last good census is fresh, so admission runs on it
# and both drafts are readied; the fallback is announced exactly once. ---
census_fixture census-fallback
: # runner 读稳定成功
command jq -cn --argjson now "$(date -u +%s)" --argjson prs "$(census_json)" '{cached_at:$now, prs:$prs}' \
  > "$A/open-pr-census-cache.json"
ci_admission
[[ "$(cat "$ready_log")" == $'pr ready 5283\npr ready 5284' ]] \
  || { echo "ci-admission-census-fallback.test.sh: cached census did not ready both drafts, got: $(cat "$ready_log")" >&2; exit 1; }
grep -Fq 'continuing on the cached census from' "$LOG" \
  || { echo 'ci-admission-census-fallback.test.sh: the census fallback use was not logged' >&2; exit 1; }
[[ "$(grep -Fc 'continuing on the cached census from' "$LOG")" == 1 ]] \
  || { echo 'ci-admission-census-fallback.test.sh: the census fallback was logged more than once' >&2; exit 1; }
grep -Fq 'ci admission paused' "$LOG" && { echo 'ci-admission-census-fallback.test.sh: admission paused although the cached census was fresh' >&2; exit 1; }

# --- case 3: census read fails twice and the last good census is older than the bound:
# admission pauses with exactly one log line that names the exceeded bound. ---
census_fixture census-stale
: # runner 读稳定成功
CI_CENSUS_FALLBACK_MAX_AGE_SECONDS=300
export CI_CENSUS_FALLBACK_MAX_AGE_SECONDS
command jq -cn --argjson now "$(( $(date -u +%s) - 900 ))" --argjson prs "$(census_json)" '{cached_at:$now, prs:$prs}' \
  > "$A/open-pr-census-cache.json"
ci_admission
[[ ! -s "$ready_log" ]] || { echo "ci-admission-census-fallback.test.sh: stale census still readied: $(cat "$ready_log")" >&2; exit 1; }
[[ "$(grep -Fc 'ci admission paused' "$LOG")" == 1 ]] \
  || { echo "ci-admission-census-fallback.test.sh: expected exactly one pause line, got $(grep -Fc 'ci admission paused' "$LOG")" >&2; exit 1; }
grep -Fq 'exceeds the 300s fallback bound' "$LOG" \
  || { echo 'ci-admission-census-fallback.test.sh: the pause line does not name the exceeded fallback bound' >&2; exit 1; }
grep -Fq 'continuing on the cached census from' "$LOG" && { echo 'ci-admission-census-fallback.test.sh: a stale census was still used' >&2; exit 1; }
command jq -e 'all(.units[]; .ci_ready_sha == null)' "$UNITS" >/dev/null \
  || { echo 'ci-admission-census-fallback.test.sh: paused pass still wrote ready evidence' >&2; exit 1; }

echo 'ci-admission-census-fallback.test.sh: pass (retry+fallback for both census reads, stale bound pauses once)'
