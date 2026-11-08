#!/usr/bin/env bash
# The new-issue walk does not repeat the handoff block for an issue that already has a unit and that the existing-only walk took through it this tick.
# Pass 1 (existing_only) queues its wait marks and writes them once. Both costs must not grow with the number of existing units.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/intake-handoff-skip"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
mkdir -p "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR/alerts" "$fixture/bin"
cp "$script_dir/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
fail() { echo "intake-handoff-skip.test.sh: $*" >&2; exit 1; }

gh_log="$fixture/gh.log"
cat > "$fixture/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
[[ "$1 $2" == "pr view" ]] && printf '{"number":%s,"headRefName":"agent/issue-x","title":"t","body":"","state":"MERGED","labels":[]}\n' "$3"
exit 0
GH
chmod +x "$fixture/bin/gh"
export GH_LOG="$gh_log" TICK_INTAKE_GH_INVOKE="$fixture/bin/gh"

MAX=500
CFG='{"issue_intake":{"enabled":true,"max_upstream":900,"max_ready":30,"ready_buffer":500}}'
footprint_waiters_revalidate() { :; }
live_workers() { echo 0; }
hotfix_issue_numbers() { :; }
tick_prs_prime() { :; }
tick_prs() { echo '[]'; }
intake_footprint_snapshot() { echo '[]'; }
scheduler_footprint() { echo '[]'; }
active_footprint_conflict() { :; }
predecessor_candidates() { :; }
issue_unit_task() { echo '{"task":"fixture","body_blocked_by":[],"labels":[]}'; }
row() { printf '%s\tpr\tfixture\t[]\t%s\n' "$1" "$(printf '{"number":%s,"state":"OPEN","subIssuesSummary":{"total":0},"labels":[{"name":"ready-for-agent"}]}' "$1" | base64 -w0)"; }
intake_candidates() { local i; for ((i = 1; i <= N + M; i++)); do row "$i"; done; }

eval "$(declare -f units_update | sed '1s/units_update/real_units_update/')"
writes="$fixture/writes"
units_update() { printf x >> "$writes"; real_units_update "$@"; }
count_writes() { [[ -s "$writes" ]] && wc -c < "$writes" || echo 0; }

# N existing units whose handoff episode is consumed and whose PR is merged (not in the open census); M new issues with a handoff and no unit.
setup() { # N M
  N=$1 M=$2
  jq -n --argjson N "$N" '{units: [range(1; $N + 1) | {id: "issue-\(.)", issue: ., branch: "agent/issue-\(.)", stage: "implement-pending", pr: (1000 + .), hold_handoff_episode: "e\(.)"}]}' > "$UNITS"
  rm -rf "$AGENT_HOME/state"; mkdir -p "$AGENT_HOME/state"
  local i; for ((i = 1; i <= N + M; i++)); do
    printf '{"state":"ready-for-agent","scheduler_handoff":{"episode":"e%s","open_pr":%s}}\n' "$i" "$((1000 + i))" > "$AGENT_HOME/state/$i.json"
  done
  rm -f "$UNITS.view" "$writes"; : > "$gh_log"; : > "$LOG"
}
pr_views() { awk -v lo="$1" -v hi="$2" '$1 == "pr" && $2 == "view" && $3 >= lo && $3 <= hi { n++ } END { print n + 0 }' "$gh_log"; } # PR reads in [lo, hi]

measure() { # N M: prints "p1_writes p1_views p2_writes p2_views_of_existing_units"
  setup "$1" "$2"
  register_new_issues 1 || true
  local p1w p1v p2w p2v
  p1w=$(count_writes); p1v=$(pr_views 1001 $((1000 + N + M)))
  : > "$gh_log"; rm -f "$writes"
  register_new_issues 0 || true
  p2w=$(count_writes); p2v=$(pr_views 1001 $((1000 + N)))
  echo "$p1w $p1v $p2w $p2v"
}
read -r a_p1w a_p1v a_p2w a_p2v <<<"$(measure 6 2)"
read -r b_p1w b_p1v b_p2w b_p2v <<<"$(measure 30 2)"

(( a_p1w == b_p1w && a_p1w <= 2 )) || fail "pass 1 ledger writes grow with the units: $a_p1w for 6, $b_p1w for 30"
(( a_p1v == 8 && b_p1v == 32 )) || fail "pass 1 should read each handoff row's PR once: $a_p1v for 6+2 rows, $b_p1v for 30+2"
(( a_p2w == b_p2w )) || fail "pass 2 ledger writes grow with the existing units: $a_p2w for 6, $b_p2w for 30"
# the new issues read their own PRs in pass 2; no existing unit's PR is read again
(( a_p2v == 0 && b_p2v == 0 )) || fail "pass 2 repeated the handoff reads of existing units: $a_p2v, $b_p2v"

# Same result as the full block: from the state pass 1 leaves, pass 2 with and without the skip writes the same ledger and counts the same skips.
setup 12 2
register_new_issues 1 || true
cp "$UNITS" "$fixture/after-pass1.json"
saved_census="$HANDOFF_PR_CENSUS" saved_prs="${HANDOFF_WAIT_PRS:-}" saved_branches="${HANDOFF_WAIT_BRANCHES:-}" saved_partial="${HANDOFF_CENSUS_PARTIAL:-}"
: > "$LOG"; register_new_issues 0 || true
skip_line="$(grep 'intake skip counts' "$LOG" | tail -1 | sed -E 's/^\[[^]]*\] //')"
jq -S . "$UNITS" > "$fixture/skip.json"
cp "$fixture/after-pass1.json" "$UNITS"; rm -f "$UNITS.view"
HANDOFF_PR_CENSUS="$saved_census" HANDOFF_WAIT_PRS="$saved_prs" HANDOFF_WAIT_BRANCHES="$saved_branches" HANDOFF_CENSUS_PARTIAL="$saved_partial"
INTAKE_EXISTING_WALKED=()
: > "$LOG"; register_new_issues 0 || true
full_line="$(grep 'intake skip counts' "$LOG" | tail -1 | sed -E 's/^\[[^]]*\] //')"
jq -S . "$UNITS" > "$fixture/full.json"
# the units the new-issue walk adds carry run-time stamps: compare only the existing units
for f in skip full; do jq -S '.units |= map(select(.issue <= 12))' "$fixture/$f.json" > "$fixture/$f.existing.json"; done
cmp -s "$fixture/skip.existing.json" "$fixture/full.existing.json" || { diff "$fixture/skip.existing.json" "$fixture/full.existing.json" | head >&2; fail "the skip changed the ledger of the existing units"; }
[[ "$skip_line" == "$full_line" ]] || fail "skip counts differ: '$skip_line' vs '$full_line'"
echo 'intake-handoff-skip.test.sh: pass'
