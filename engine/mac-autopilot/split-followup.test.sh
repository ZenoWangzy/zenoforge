#!/usr/bin/env bash
# A split follow-up stays out of its parent's children, so the parent can reach awaiting-release.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/split-followup"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo/engine/prompts" "$fixture/bin"
export ZF_ROADMAP_TREE_CACHE_FILE="$fixture/roadmap-tree.json"
jq -cn '{roots:[]}' > "$ZF_ROADMAP_TREE_CACHE_FILE"
jq '.auto_merge = false | .advisor = false | .precheck = false | .supervisor_arbiter.enabled = true' "$script_dir/config.template.json" > "$sup/autopi/config.json"
echo '{"units":[]}' > "$sup/autopi/units.json"
echo '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export ZF_CONFIG_ROOT="$fixture/repo/.zenoforge"
mkdir -p "$ZF_CONFIG_ROOT/prompts"
cp "$script_dir/../prompts/supervisor-arbiter.md" "$ZF_CONFIG_ROOT/prompts/supervisor-arbiter.md"
cp "$script_dir/../prompts/review-contract.md" "$ZF_CONFIG_ROOT/prompts/review-contract.md"
cp "$script_dir/../prompts/supervisor-arbiter.md" "$fixture/repo/engine/prompts/supervisor-arbiter.md"
export CODEX_SESSIONS_DIR="$fixture/sessions"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { echo "split-followup.test.sh: $*" >&2; exit 1; }
printf '%s\n' '{"units":[{"id":"issue-40","issue":40,"title":"t","stage":"review","history":[]}]}' > "$UNITS"
printf 'slice report\n' > "$fixture/report"
created="$fixture/created"
gh() {
  case "$1 $2" in
    "api repos/{owner}/{repo}/issues/40/parent") printf '%s' "${PARENT_OF_40:-}"; [[ -n "${PARENT_OF_40:-}" ]] ;;
    "issue create") printf '%s\n' "$*" > "$created"; echo "https://github.com/o/r/issues/41" ;;
    *) return 1 ;;
  esac
}
PARENT_OF_40=7 split_followup_issue issue-40 40 50 'SPLIT: the rest' "$fixture/report"
grep -q -- '--parent 7' "$created" || fail "the follow-up must be the parent's sibling ($(cat "$created"))"
! grep -q -- '--parent 40' "$created" || fail "an open child would make the parent a container"
[[ "$(jqf -r '.units[0].split_followup' "$UNITS")" == 41 ]] || fail "the follow-up number was not recorded"
PARENT_OF_40= split_followup_issue issue-40 40 50 'SPLIT: the rest' "$fixture/report"
! grep -q -- '--parent' "$created" || fail "a top-level parent has no parent to share"
# A refused recut sent back to implement escalated again and again at the same scope; after one ruling the worker runs once on the SPLIT contract.
sa="$fixture/size-admit"; mkdir -p "$sa"; command git init -q -b main "$sa/wt"
command git -C "$sa/wt" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
sa_head="$(command git -C "$sa/wt" rev-parse HEAD)"
SIZE_ADMISSION_LINES=800; TICK_DISPATCH_LOCAL_REFILL=false
scheduler_issue_state() { echo '{"state":"ready-for-agent","recut_refused_at":"2026-11-06T00:00:00Z"}'; }
scheduler_size_recut() { fail 'a refused head must not be routed to recut again'; }
changed_lines_in_checkout() { echo "${SA_ACTUAL:-}"; }
to_supervisor() { set_unit "$1" "$(hist supervisor-escalated "$2") | .stage=\"supervisor-review\""; }
sa_unit='{"id":"issue-60","issue":60,"estimated_changed_lines":1000}'
sa_hist='{"stage":"size-recut","result":"issue #60: 1000 lines exceed 800; head='"$sa_head"'","at":"t1"},{"stage":"size-recut-resumed","result":"back","at":"t2"}'
printf '%s\n' '{"units":[{"id":"issue-60","issue":60,"estimated_changed_lines":1000,"stage":"implement-pending","history":['"$sa_hist"']}]}' > "$UNITS"
rc=0; size_admission_write_start issue-60 "$sa/wt" "$sa_unit" || rc=$?
[[ "$rc" == 1 && "$(jqf -r '.units[0].stage' "$UNITS")" == supervisor-review ]] || fail "first refusal must still reach the arbiter (rc=$rc)"
rc=0; size_admission_write_start issue-60 "$sa/wt" "$sa_unit" || rc=$?
[[ "$rc" == 0 && "$(jqf -r '[.units[0].history[] | select(.stage=="size-split-admitted")] | length' "$UNITS")" == 1 ]] \
  || fail "a repeat refusal after a ruling was not admitted once for a split delivery (rc=$rc)"
SA_ACTUAL=28; rc=0; size_admission_write_start issue-60 "$sa/wt" "$sa_unit" || rc=$?
[[ "$rc" == 0 ]] || fail "an admitted slice was judged on the stale whole-ticket estimate (rc=$rc)"
SA_ACTUAL=900; rc=0; size_admission_write_start issue-60 "$sa/wt" "$sa_unit" || rc=$?
[[ "$rc" == 1 && "$(jqf -r '[.units[0].history[] | select(.stage=="size-split-admitted")] | length' "$UNITS")" == 1 ]] \
  || fail "an oversized real diff must still be refused, and the admission is once only (rc=$rc)"
# A verified owner ruling after that admission opens one more SPLIT attempt; its result carries the comment URL.
set_unit issue-60 '.history += [{stage:"supervisor-requeue",result:"supervisor ruling https://github.com/o/r/issues/60#issuecomment-12345: schema first",at:"t3"}]'
SA_ACTUAL=28; rc=0; size_admission_write_start issue-60 "$sa/wt" "$sa_unit" || rc=$?
[[ "$rc" == 0 && "$(jqf -r '[.units[0].history[] | select(.stage=="size-split-admitted")] | length' "$UNITS")" == 2 ]] \
  || fail "a real ruling did not open a second admission for the same refused branch (rc=$rc)"
# Re-escalating without another ruling must not grant a third admission.
SA_ACTUAL=900; rc=0; size_admission_write_start issue-60 "$sa/wt" "$sa_unit" || rc=$?
[[ "$rc" == 1 && "$(jqf -r '[.units[0].history[] | select(.stage=="size-split-admitted")] | length' "$UNITS")" == 2 ]] \
  || fail "a second escalation without a ruling granted another admission (rc=$rc)"
rc=0; size_admission_write_start issue-60 "$sa/wt" "$sa_unit" || rc=$?
[[ "$rc" == 1 && "$(jqf -r '[.units[0].history[] | select(.stage=="size-split-admitted")] | length' "$UNITS")" == 2 ]] \
  || fail "a repeated escalation without a ruling granted another admission (rc=$rc)"
# Repair-pending (issue 5374 live shape): an 802-line repair head is refused, then admitted once on the same refused head, then refused again.
printf '%s\n' '{"units":[{"id":"issue-61","issue":61,"stage":"repair-pending","history":['"$sa_hist"']}]}' > "$UNITS"
rc=0; size_admission_reject issue-61 802 agent/issue-61 "repair-pending before dispatch" "$sa_head" "" 802 admission 800 || rc=$?
[[ "$rc" == 1 && "$(jqf -r '.units[0].stage' "$UNITS")" == supervisor-review ]] || fail "first repair refusal must reach the arbiter (rc=$rc)"
rc=0; size_admission_reject issue-61 802 agent/issue-61 "repair-pending before dispatch" "$sa_head" "" 802 admission 800 || rc=$?
[[ "$rc" == 0 && "$(jqf -r '[.units[0].history[] | select(.stage=="size-split-admitted")] | length' "$UNITS")" == 1 ]] \
  || fail "a repair refused on the same head was not admitted once (rc=$rc)"
rc=0; size_admission_reject issue-61 802 agent/issue-61 "repair-pending before dispatch" "$sa_head" "" 802 admission 800 || rc=$?
[[ "$rc" == 1 && "$(jqf -r '[.units[0].history[] | select(.stage=="size-split-admitted")] | length' "$UNITS")" == 1 ]] \
  || fail "a still-oversized repair after the one admission must be refused (rc=$rc)"
automatic_requeues=(
  'scheduler fresh-signal requeue: review-request-changes'
  'stop-loss same failure: unparked, repeated red; budget refilled'
  'recut refused at 2026-11-06T00:00:00Z; reopened with a refilled stop-loss budget'
  'guarded recut refused; resumed with a refilled budget (round trip 1 of 1)'
  'ticket budget is available again; the issue is ready-for-agent'
)
for automatic_result in "${automatic_requeues[@]}"; do
  set_unit issue-61 "$(hist supervisor-requeue "$automatic_result")"
  rc=0; size_admission_reject issue-61 802 agent/issue-61 "repair-pending before dispatch" "$sa_head" "" 802 admission 800 || rc=$?
  [[ "$rc" == 1 && "$(jqf -r '[.units[0].history[] | select(.stage=="size-split-admitted")] | length' "$UNITS")" == 1 ]] \
    || fail "automatic requeue reset the split admission: $automatic_result (rc=$rc)"
done
# Main moves the checkout head while a ticket waits (11-14: 6570 saw four heads at 1100 lines). A recut already sent at this
# estimate is not sent again on the new head, refused or completed; a new estimate still routes to recut.
command git -C "$sa/wt" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m moved
scheduler_size_recut() { fail 'a recut already sent at this estimate was routed to recut again on a moved head'; }
SA_ACTUAL=
for sized_state in '{"state":"ready-for-agent","recut_refused_at":"2026-11-06T00:00:00Z"}' '{"state":"ready-for-agent","recut_children":[71]}'; do
  scheduler_issue_state() { echo "$sized_state"; }
  printf '%s\n' '{"units":[{"id":"issue-62","issue":62,"estimated_changed_lines":1000,"stage":"implement-pending","history":['"$sa_hist"']}]}' > "$UNITS"
  rc=0; size_admission_write_start issue-62 "$sa/wt" '{"id":"issue-62","issue":62,"estimated_changed_lines":1000}' || rc=$?
  [[ "$rc" == 1 && "$(jqf -r '.units[0].stage' "$UNITS")" == supervisor-review ]] \
    || fail "a recut already sent at this estimate was not sent to the arbiter on a moved head (rc=$rc state=$sized_state)"
done
scheduler_size_recut() { return 0; }
printf '%s\n' '{"units":[{"id":"issue-62","issue":62,"estimated_changed_lines":1100,"stage":"implement-pending","history":['"$sa_hist"']}]}' > "$UNITS"
rc=0; size_admission_write_start issue-62 "$sa/wt" '{"id":"issue-62","issue":62,"estimated_changed_lines":1100}' || rc=$?
[[ "$rc" == 1 && "$(jqf -r '.units[0].stage' "$UNITS")" == blocked-external ]] \
  || fail "a new estimate after a refused recut was not routed to recut (rc=$rc)"
echo "split-followup.test.sh: all assertions passed"
