#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export ZF_REPO=test/repo ZF_REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
export ZF_WORKTREE_ROOT="$test_env_root/worktrees"
source "$SCRIPT_DIR/lib.sh"
eval "$(sed -n '/^ensure_issue_roadmap_parent_for_dispatch() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
eval "$(sed -n '/^route_pipeline_fastlane_issue() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
trap 'rm -rf -- "$test_env_root"' EXIT
mkdir -p "$AGENT_HOME/night" "$AGENT_HOME/land-queue/requests" "$AGENT_HOME/state"
request="$AGENT_HOME/land-queue/requests/00000000000000000549.json"
jq -n '{ticket:"00000000000000000549",owner:"hand-3449",owned_issues:"3449 3413",state:"queued"}' > "$request"
cat > "$test_env_bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
chmod +x "$test_env_bin/gh"
hand_agent_worktree_pid() { return 1; }
hand_agent_issue_is_live_owned() { return 1; }
pipeline_system_hand_report_conclusion() { return 1; }
scheduler_requeue_issue() { echo dispatch >> "$AGENT_HOME/dispatch"; }
supervisor_inbox_append_once() { echo "$*" >> "$AGENT_HOME/supervisor-inbox"; }
hold_issue() { echo hold >> "$AGENT_HOME/holds"; }
assert_owner() {
  supervisor_hold_owner_state "$1"
  [[ "$SUPERVISOR_HOLD_OWNER_STATE" == "$2" ]] || {
    echo "FAIL issue=$1 expected=$2 actual=$SUPERVISOR_HOLD_OWNER_STATE" >&2; exit 1;
  }
}
for issue in 3449 3413; do
  assert_owner "$issue" queued
  [[ "$SUPERVISOR_HOLD_OWNER_DETAIL" == *land-queue*00000000000000000549* ]]
  route_pipeline_fastlane_issue "$issue" '{"labels":[]}' test
done
ensure_issue_roadmap_parent_for_dispatch() { return 0; }
stage_unit_active() { return 1; }
coord_issue_live_worker() { return 1; }
issue_body_mentions_product_scope() { return 1; }
label_writes="$AGENT_HOME/label-writes"
guarded_write() { printf '%s\n' "$*" >> "$label_writes"; }
triage_key=issue-910806
triage_owner=triage-owner-910806
triage_claim_status=0
coord_acquire "$triage_key" "$triage_owner" systemd-worker 910806 zf-triage-batch triage-batch || triage_claim_status=$?
[[ "$triage_claim_status" == 0 ]] || { echo "FAIL could not hold triage claim status=$triage_claim_status" >&2; exit 1; }
fastlane_status=0
route_pipeline_fastlane_issue 910806 \
  '{"number":910806,"title":"Path-only fixture","body":"Fix engine/lib.sh","comments":[],"labels":[],"state":"OPEN"}' \
  'held by triage' 2> "$AGENT_HOME/fastlane-held.log" || fastlane_status=$?
[[ "$fastlane_status" == 1 ]] || { echo "FAIL fastlane status=$fastlane_status with triage claim" >&2; exit 1; }
[[ ! -e "$label_writes" ]] || { echo 'FAIL fastlane changed labels on a triage-owned issue' >&2; exit 1; }
triage_owned_status=0
coord_assert_owned "$triage_key" "$triage_owner" >/dev/null || triage_owned_status=$?
[[ "$triage_owned_status" == 0 ]] || { echo "FAIL triage claim lost status=$triage_owned_status" >&2; exit 1; }
triage_release_status=0
coord_release "$triage_key" "$triage_owner" >/dev/null || triage_release_status=$?
[[ "$triage_release_status" == 0 ]] || { echo "FAIL could not release triage claim status=$triage_release_status" >&2; exit 1; }
echo 'ok - fastlane skips label write when triage owns the issue'
[[ ! -e "$AGENT_HOME/dispatch" && ! -e "$AGENT_HOME/supervisor-inbox" && ! -e "$AGENT_HOME/holds" ]]
assert_owner 344 none
assert_owner 341 none
for state in running direct-pending-push; do
  jq --arg state "$state" '.state=$state' "$request" > "$request.tmp"
  mv "$request.tmp" "$request"
  assert_owner 3413 running
done
for state in landed failed cancelled pr-opened; do
  jq --arg state "$state" '.state=$state' "$request" > "$request.tmp"
  mv "$request.tmp" "$request"
  assert_owner 3449 none
done
jq '.state="queued" | .ticket="invalid"' "$request" > "$request.tmp"
mv "$request.tmp" "$request"
assert_owner 3449 none
jq '.ticket="00000000000000000549"' "$request" > "$request.tmp"
mv "$request.tmp" "$request"
# Older requests can identify their issue through the canonical hand name.
jq '.state="queued" | del(.owned_issues)' "$request" > "$request.tmp"
mv "$request.tmp" "$request"
assert_owner 3449 queued
assert_owner 3413 none
jq '.owned_issues="3449 3413"' "$request" > "$request.tmp"
mv "$request.tmp" "$request"
for issue in 3449 3413; do
  jq -n '{state:"on-hold",hold:{holder:"supervisor",kind:"pipeline-system-fastlane",created_at:(now-3600|todate),expires_at:(now+3600|todate),stage_before:"ready-for-agent",release_condition:"landing complete",durable_record:true}}' > "$AGENT_HOME/state/$issue.json"
done
reader="$(declare -f supervisor_hold_landing_rows)"
eval "${reader/supervisor_hold_landing_rows/saved_landing_rows}"
supervisor_hold_landing_rows() { echo read >> "$AGENT_HOME/landing-reads"; saved_landing_rows; }
snapshot="$(supervisor_holds_snapshot $'3449\n3413' "$(date +%s)" '[]')"
[[ "$(wc -l < "$AGENT_HOME/landing-reads")" == 1 ]]
eval "$reader"
jq -e 'length == 2 and all(.[]; .owner == "queued")' <<< "$snapshot" >/dev/null
jq '.state="landed"' "$request" > "$request.tmp"
mv "$request.tmp" "$request"
# Snapshot ownership must not leak into a later direct owner check.
assert_owner 3449 none
printf '{broken json\n' > "$request"
status=0
supervisor_hold_owner_state 3449 2>/dev/null || status=$?
[[ "$status" == 2 && "$SUPERVISOR_HOLD_OWNER_STATE" == unknown ]]
echo 'ok - active landing owns fastlane and hold snapshot; terminal and corrupt requests cannot hide missing owners'
