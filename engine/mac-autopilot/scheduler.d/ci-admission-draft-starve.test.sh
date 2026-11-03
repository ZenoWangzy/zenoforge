#!/usr/bin/env bash
# 2026-11-03 incident: four ready-to-merge hotpatch units (PR#4921/#4938/#4940/#4942 shaped) sat on
# draft PRs with no agent/ci-gated label while 5 PR runners idled. gated_ready returned silently for
# branches outside the gated-label census, and the hotpatch exclusion in the WIP loop meant no other
# path could ever ready them. This suite replays that population end to end through ci_admission.
#
# --plant-old mode (arg 1 = --plant-old) restores the original gated_ready verbatim and expects the
# replay to leave the drafts un-readied (exit 1 with evidence): the planted copy of the real past
# bad code. Without the argument the fixed code must ready every draft in the same pass (exit 0).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"

fixture="$test_env_root/ci-admission-draft-starve"
supervisor="$fixture/supervisor"
mkdir -p "$supervisor/autopi/alerts" "$fixture/repo"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$supervisor" \
  MAC_AUTOPILOT_RUNTIME_DIR="$supervisor/autopi" REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
jq '.precheck = false | .hotfix_lane = {"label":"hotfix","branch_prefixes":[]}' \
  "$engine_dir/mac-autopilot/config.template.json" > "$supervisor/autopi/config.json"
echo '{"units":[]}' > "$supervisor/autopi/units.json"
echo '{"workers":[]}' > "$supervisor/autopi/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

head1="$(printf '%040x' 4921)"; head2="$(printf '%040x' 4938)"
head3="$(printf '%040x' 4940)"; head4="$(printf '%040x' 4942)"

# The live census shape: four open draft PRs on hotfix/* branches with NO labels (so gated_load
# indexes none of them) and a labeled agent PR that is already ready (census is non-empty, loaded).
starve_census() {
  command jq -cn --arg h1 "$head1" --arg h2 "$head2" --arg h3 "$head3" --arg h4 "$head4" '[
    {number:4921, headRefName:"hotfix/ontology-inventory-perf", headRefOid:$h1, isDraft:true,  labels:[], body:"", baseRefName:"main"},
    {number:4938, headRefName:"hotfix/diag-approve-failed-item", headRefOid:$h2, isDraft:true, labels:[], body:"", baseRefName:"main"},
    {number:4940, headRefName:"hotfix/f6-live-fallback",         headRefOid:$h3, isDraft:true, labels:[], body:"", baseRefName:"main"},
    {number:4942, headRefName:"hotfix/act1-rowbind",             headRefOid:$h4, isDraft:true, labels:[], body:"", baseRefName:"main"}
  ]'
}

starve_fixture() { # name -> $td: live units.json shape + census + shared stubs
  td="$test_env_root/$1"; mkdir -p "$td/alerts"
  A="$td"; LOG="$td/scheduler.log"; : > "$LOG"
  UNITS="$td/units.json"; WORKERS="$td/workers.json"
  STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; SCHED_LOCK_HELD=true
  TICK_PRS="$(starve_census)"; TICK_PR_CHECK_CENSUS=''
  TICK_HOTFIX_ISSUES_LOADED=true; TICK_HOTFIX_ISSUES='[]'
  GATED_OF=(); GATED_SLOT=(); READIED_PRS=()
  SLOT_SYNC_CARRIED_HEAD=""; SLOT_SYNC_SPENT=0
  ready_calls=0
  command jq -cn --arg h1 "$head1" --arg h2 "$head2" --arg h3 "$head3" --arg h4 "$head4" '{units:[
    {id:"pr-4921", pr:4921, branch:"hotfix/ontology-inventory-perf", lane:"pr", stage:"ready-to-merge",
     approved_sha:$h1, hotpatch:true, critical:true, product_paths:true, ready_since:1, history:[]},
    {id:"pr-4938", pr:4938, branch:"hotfix/diag-approve-failed-item", lane:"pr", stage:"ready-to-merge",
     approved_sha:$h2, hotpatch:true, critical:true, product_paths:true, ready_since:2, history:[]},
    {id:"pr-4940", pr:4940, branch:"hotfix/f6-live-fallback", lane:"pr", stage:"ready-to-merge",
     approved_sha:$h3, hotpatch:true, critical:true, product_paths:true, ready_since:3, history:[]},
    {id:"pr-4942", pr:4942, branch:"hotfix/act1-rowbind", lane:"pr", stage:"ready-to-merge",
     approved_sha:$h4, hotpatch:true, critical:true, product_paths:true, ready_since:4, history:[]} ]}' > "$UNITS"
  echo '{"workers":[]}' > "$WORKERS"
  ci_pr_free_slots() { printf '5\n'; }
  unfinished_runs() { printf '[]'; }
  ci_jobs_prefetch() { :; }
  approved_status_on() { return 0; }
  gated_status() { :; }
  pr_view() { return 1; }
  gh() {
    case "$*" in
      'pr ready 4921'|'pr ready 4938'|'pr ready 4940'|'pr ready 4942')
        ready_calls=$((ready_calls + 1)); return 0 ;;
      *) echo "ci-admission-draft-starve.test.sh: unexpected gh call: $*" >&2; return 97 ;;
    esac
  }
}

# Exit 0 iff no ready-to-merge unit with an approved head still points at a census draft:
# the invariant whose violation starved the four units for hours.
starve_invariant_ok() {
  jqf -e --argjson prs "$TICK_PRS" '[.units[]
    | select(.stage == "ready-to-merge" and (.pr // null) != null and (.approved_sha // "") != "")
    | . as $u | ($prs[] | select(.number == $u.pr) | select(.isDraft == true))] | length == 0' "$UNITS" >/dev/null
}

if [[ "${1:-}" == "--plant-old" ]]; then
  # Verbatim pre-fix gated_ready (origin/main engine/mac-autopilot/scheduler.d/ci-status.sh): the
  # planted copy of the real past bad code. Unlabeled drafts return silently at the GATED_OF check.
  gated_ready() { # id branch approved_head：批准的 head 占到名额（或属于豁免类）才 ready；head 对不上不翻，已 ready 的退回 draft
    local pr draft ghead ready_sha ready_at
    read -r pr draft ghead <<<"${GATED_OF[$2]:-}"
    [[ -n "$pr" ]] || return 0
    GATED_SLOT["$2"]=1
    if [[ "$draft" == false ]] && jqf -e --arg branch "$2" 'index($branch) != null' <<<"${CI_HOTFIX_BRANCHES:-[]}" >/dev/null 2>&1; then
      return 0
    fi
    if [[ "$ghead" != "$3" ]]; then
      [[ "$draft" == false ]] && gated_demote_pr "$pr" "$2" "ci deferred; approval no longer on the live head" \
        && say "gated unit=$1 PR#$pr demoted: approved ${3:0:9} is not the live head ${ghead:0:9}"
      return 0
    fi
    if [[ "$draft" == false ]]; then
      ready_sha="$(unit_field "$1" '.ci_ready_sha // empty')"
      ready_at="$(unit_field "$1" '.ci_ready_at // empty')"
      [[ "$ready_sha" == "$3" && -n "$ready_at" ]] && return 0
      gated_demote_pr "$pr" "$2" "ci deferred; refreshing ready-event evidence" || return 0
      draft=true
    fi
    approved_status_on "$3" || gated_status "$3" success agent/ci-approved "approved by the reviewer" || return 0
    ready_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gh pr ready "$pr" >/dev/null 2>&1 || { tick_prs_changed; return 0; }
    tick_prs_set_draft "$pr" false
    GATED_OF["$2"]="$pr false $ghead"
    READIED_PRS["$pr"]=1
    [[ "$(unit_field "$1" '.ci_wip_wait // empty')" == "$3" ]] && gated_status "$3" success agent/ci-waiting "CI slot granted"
    set_unit "$1" "$(hist ci-ready "PR#$pr readied on ${3:0:9}") | .ci_ready_sha=$(js "$3") | .ci_ready_at=$(js "$ready_at") | del(.ci_wip_wait) | del(.ci_cancel_reruns)"
    say "gated unit=$1 PR#$pr readied on ${3:0:9}"
  }
  starve_fixture plant-old
  ci_admission
  if starve_invariant_ok || (( ready_calls > 0 )); then
    echo 'ci-admission-draft-starve.test.sh: planted pre-fix gated_ready unexpectedly readied the unlabeled drafts' >&2
    exit 1
  fi
  echo "ci-admission-draft-starve.test.sh: PLANTED-OLD left $(( $(command jq '.units | length' "$UNITS") )) ready-to-merge drafts un-readied with 5 free slots; guard must fail" >&2
  command jq -e 'all(.units[]; has("ci_slot_wait_since"))' "$UNITS" >/dev/null \
    || { echo 'ci-admission-draft-starve.test.sh: planted run did not start the starvation clock (ci_slot_wait_since)' >&2; exit 1; }
  command jq -e 'all(.units[]; .ci_slot_wait_ticks == 1)' "$UNITS" >/dev/null \
    || { echo 'ci-admission-draft-starve.test.sh: planted run did not count the first free-slot tick' >&2; exit 1; }
  exit 1 # the planted bad code fails the replay by construction
fi

# --- case 1: the incident replay, fixed code. One admission pass, 5 free slots, no queued runs. ---
starve_fixture incident-replay
ci_admission
[[ "$ready_calls" == 4 ]] || { echo "ci-admission-draft-starve.test.sh: expected 4 ready flips, got $ready_calls" >&2; exit 1; }
starve_invariant_ok || { echo 'ci-admission-draft-starve.test.sh: a ready-to-merge draft survived the admission pass' >&2; exit 1; }
command jq -e --arg h1 "$head1" --arg h4 "$head4" '
  ([.units[] | select(.id == "pr-4921")][0].ci_ready_sha == $h1)
  and ([.units[] | select(.id == "pr-4942")][0].ci_ready_sha == $h4)
  and (all(.units[]; .ci_wip_wait == null))
  and (all(.units[]; .ci_slot_wait_since == null))
  and (all(.units[]; .ci_slot_wait_ticks == null))
  and (all(.units[]; .ci_slot_starve_alerted == null))
  and all(.units[]; any(.history[]?; .stage == "ci-ready"))' "$UNITS" >/dev/null \
  || { echo 'ci-admission-draft-starve.test.sh: ledger evidence after the ready flips is wrong' >&2; exit 1; }
grep -Fq 'PR#4921 readied on' "$LOG" || { echo 'ci-admission-draft-starve.test.sh: no readied log line for PR#4921' >&2; exit 1; }
grep -Fq 'ci slot starvation' "$LOG" && { echo 'ci-admission-draft-starve.test.sh: starvation alert fired for units readied this pass' >&2; exit 1; }

# --- case 2: the recurrence guard. A draft still unready after two free-slot ticks alerts once. ---
starve_fixture starve-watch
CI_SLOT_STARVE_SLOW_TICKS=2
ci_slot_starve_watch
command jq -e '([.units[] | select(.id == "pr-4921")][0].ci_slot_wait_ticks == 1)' "$UNITS" >/dev/null \
  || { echo 'ci-admission-draft-starve.test.sh: first free-slot tick was not counted' >&2; exit 1; }
grep -Fq 'CI-SLOT-STARVE' "$A/alerts/slo.md" 2>/dev/null && { echo 'ci-admission-draft-starve.test.sh: starvation alert fired before two slow ticks' >&2; exit 1; }
ci_slot_starve_watch
grep -Fq 'ci slot starvation unit=pr-4921 PR#4921: still draft with 5 free slot(s) after 2 slow tick(s)' "$LOG" \
  || { echo 'ci-admission-draft-starve.test.sh: starvation watch did not log the wait' >&2; exit 1; }
grep -Fq 'CI-SLOT-STARVE unit=pr-4921 PR#4921 free_slots=5' "$A/alerts/slo.md" \
  || { echo 'ci-admission-draft-starve.test.sh: starvation watch did not write the slo.md alert' >&2; exit 1; }
command jq -e '([.units[] | select(.id == "pr-4921")][0].ci_slot_starve_alerted == true)' "$UNITS" >/dev/null \
  || { echo 'ci-admission-draft-starve.test.sh: starvation alert flag not recorded' >&2; exit 1; }
ci_slot_starve_watch
[[ "$(grep -c 'CI-SLOT-STARVE unit=pr-4921' "$A/alerts/slo.md")" == 1 ]] \
  || { echo 'ci-admission-draft-starve.test.sh: starvation alert duplicated for one episode' >&2; exit 1; }
starve_fixture starve-full-queue # 0 free slots is normal queueing: clock and alert both stay off
ci_pr_free_slots() { printf '0\n'; }
ci_slot_starve_watch
grep -Fq 'CI-SLOT-STARVE' "$A/alerts/slo.md" 2>/dev/null && { echo 'ci-admission-draft-starve.test.sh: alerted with zero free slots' >&2; exit 1; }

# --- case 3: wip_assignment bound. Behind-main slot syncs are capped per pass; the rest defer. ---
starve_fixture sync-budget
s1="$(printf '%040x' 2101)"; s2="$(printf '%040x' 2102)"; s3="$(printf '%040x' 2103)"
command jq -cn --arg s1 "$s1" --arg s2 "$s2" --arg s3 "$s3" '{units:[
    {id:"sync-1", pr:2101, branch:"fix/sync-1", lane:"pr", stage:"ready-to-merge", approved_sha:$s1,
     product_paths:true, ready_since:1, ci_wip_wait:$s1, history:[]},
    {id:"sync-2", pr:2102, branch:"fix/sync-2", lane:"pr", stage:"ready-to-merge", approved_sha:$s2,
     product_paths:true, ready_since:2, ci_wip_wait:$s2, history:[]},
    {id:"sync-3", pr:2103, branch:"fix/sync-3", lane:"pr", stage:"ready-to-merge", approved_sha:$s3,
     product_paths:true, ready_since:3, ci_wip_wait:$s3, history:[]} ]}' > "$UNITS"
update_calls=0
pr_behind_main() { return 0; }
tick_pr_mergeable() { echo MERGEABLE; }
ci_update_branch() { update_calls=$((update_calls + 1)); return 0; }
ci_assign_wip
[[ "$update_calls" == 2 ]] || { echo "ci-admission-draft-starve.test.sh: slot_sync cap did not bound update-branch chains (calls=$update_calls)" >&2; exit 1; }
command jq -e '([.units[] | select(.id == "sync-3")][0].slot_sync_sha == null)' "$UNITS" >/dev/null \
  || { echo 'ci-admission-draft-starve.test.sh: third behind-main unit synced past the per-pass budget' >&2; exit 1; }

# --- case 4: path classification is one bounded GraphQL batch; missing partial data stays unknown. ---
starve_fixture product-path-budget
command jq -cn '{units:[
  {id:"path-1",pr:3001,stage:"ready-to-merge"},
  {id:"path-2",pr:3002,stage:"ready-to-merge"},
  {id:"path-3",pr:3003,stage:"ready-to-merge"},
  {id:"path-4",pr:3004,stage:"ready-to-merge"}]}' > "$UNITS"
GH_PARALLEL=2 PRODUCT_PATHS_PER_TICK=3 CI_PRODUCT_PATH_LOOKUP_TIMEOUT_SECONDS=7
GH_REPO=fixture-org/fixture-repo
export GH_REPO
QUERY_LOG="$A/query-timeouts"; : > "$QUERY_LOG"
gh() {
  [[ "$1" == api && "$2" == graphql ]] || return 97
  printf '%s\t%s\n' "$2" "${AUTOPI_GH_TIMEOUT_SECONDS:-unset}" >> "$QUERY_LOG"
  cat <<'JSON'
{"data":{"repository":{"pr_3001":{"files":{"nodes":[{"path":"src/app.ts"}]}},"pr_3002":null,"pr_3003":{"files":{"nodes":[{"path":"src/other.ts"}]}}}}}
JSON
}
mark_product_paths
[[ "$(wc -l < "$QUERY_LOG")" == 1 ]] || { echo 'ci-admission-draft-starve.test.sh: path classification was not one GraphQL batch' >&2; exit 1; }
awk -F '\t' 'NF != 2 || $2 != 7 { exit 1 }' "$QUERY_LOG" \
  || { echo 'ci-admission-draft-starve.test.sh: GraphQL product-path timeout was not applied' >&2; exit 1; }
command jq -e '
  ([.units[] | select(.pr == 3001)][0].product_paths == true)
  and ([.units[] | select(.pr == 3002)][0].product_paths == null)
  and ([.units[] | select(.pr == 3003)][0].product_paths == true)
  and ([.units[] | select(.pr == 3004)][0].product_paths == null)' "$UNITS" >/dev/null \
  || { echo 'ci-admission-draft-starve.test.sh: missing GraphQL path data was incorrectly classified' >&2; exit 1; }

echo 'ci-admission-draft-starve.test.sh: pass (one-pass draft admission, 3-tick starvation alert, slot_sync and path lookup bounds verified)'
