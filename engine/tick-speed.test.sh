#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/test-env.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/open-pr-snapshot.test.py"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/night/hand-agent-watchdog.sh"
NIGHT="$AGENT_HOME/night"; mkdir -p "$NIGHT" "$STATE_DIR"
# 30 unrelated live owners must cost zero PID probes for a candidate.
for ((i=1;i<=30;i++)); do
  printf '%s\towner-%s\tm\te\tw\tb\tr\tl\t1\tt\twork\t123\t%s\tn\n' "$i" "$i" "$i"
done > "$NIGHT/agents.txt"
hand_agent_pid_live() { printf . >> "$AGENT_HOME/pid-calls"; return 0; }
if hand_agent_issue_is_live_owned 999; then
  echo 'unexpected predicate result' >&2
  exit 1
fi
[ ! -s "$AGENT_HOME/pid-calls" ] || { echo 'FAIL ownership probes every unrelated PID per candidate'; exit 1; }
hand_agent_issue_is_live_owned 30
[ "$(cat "$AGENT_HOME/pid-calls")" = . ]
echo 'ok - ownership probes only matching owners, retains PID/start verification'
# Already labeled and cached negative issues cause O(1) external commands.
printf '{"founder_login":"maintainer"}\n' > "$AGENT_HOME/recipients.json"
for ((i=1;i<=100;i++)); do printf '{"founder_test_checked":true}' > "$STATE_DIR/$i.json"; done
issues="$(jq -cn '[range(1;201) | {number:.,title:"feature",body:"",author:{login:"maintainer"},labels:(if .>100 then [{name:"founder-test"}] else [] end)}]')"
jq() { printf . >> "$AGENT_HOME/jq-calls"; command jq "$@"; }
gh() { echo 'FAIL unexpected point read' >&2; return 2; }
result="$(label_maintainer_test_candidates "$issues")"
[ "$result" = "$issues" ]
[ "$(wc -c < "$AGENT_HOME/jq-calls")" -le 5 ] || { echo 'FAIL maintainer prefilter shells out per issue'; exit 1; }
echo 'ok - maintainer prefilter command count stays constant for 200 issues'
printf '{"risk_class":"P0","level":"L0"}' > "$STATE_DIR/1.json"
printf '{bad-json' > "$STATE_DIR/2.json"
printf '{}' > "$STATE_DIR/3.json"
before_calls="$(wc -c < "$AGENT_HOME/jq-calls")"
[ "$(triage_unmeasured_issue_ids '1 2 3 999')" = $'3\n999' ]
[ "$(wc -c < "$AGENT_HOME/jq-calls")" = "$before_calls" ]
echo 'ok - measurement prefilter batches state reads; measured/malformed/missing gates remain distinct'
printf '{}' > "$STATE_DIR/2.json"

# The real slice loop must move on after an actual timed-out child, with its
# decision lock held. No systemd/GitHub mutation is used in this replay.
source "$SCRIPT_DIR/issue-pipeline-slices.sh"
cat > "$AGENT_HOME/scheduler" <<'CHILD'
#!/usr/bin/env bash
flock -n 9 || exit 9
printf '%s\n' "$2" >> "$AGENT_HOME/stages"
if [ "$2" = fastlane ]; then
  mkfifo "$AGENT_HOME/overrun-fifo"
  read -r _ < "$AGENT_HOME/overrun-fifo"
fi
CHILD
gh() { printf 'release\n'; }
check_gmail_credential() { :; }
roadmap_switch_value() { printf 'true\n'; }
roadmap_fetch_for_admission() {
  printf . >> "$AGENT_HOME/roadmap-reads"
  printf '{"roots":[]}\n' > "$1"
  ROADMAP_TREE_STALE=1 ROADMAP_SNAPSHOT_AGE_SECONDS=50
}
manual_pause_is_valid() { return 1; }
timeout() {
  shift 2
  if [ "${@: -1}" = fastlane ]; then command timeout --kill-after=0.1s 2s "$@";
  else command timeout 5s "$@"; fi
}
LOCK_FILE="$AGENT_HOME/slice.lock"
run_pipeline_slices "$AGENT_HOME/scheduler" 2> "$AGENT_HOME/slice-log"
stages="$(cat "$AGENT_HOME/stages")"
[ "${stages#fastlane$'\n'}" = $'triage\nadvisor\nrecut\nmaintenance' ] || {
  printf '%s\n' "$stages"; cat "$AGENT_HOME/slice-log"; exit 1;
}
[ "$(cat "$AGENT_HOME/roadmap-reads")" = . ]
[ "$ZF_PIPELINE_ROADMAP_STALE/$ZF_PIPELINE_ROADMAP_AGE" = 1/50 ]
grep -q 'stage=fastlane.*status=124' "$AGENT_HOME/slice-log"
if grep -q 'FAIL' "$AGENT_HOME/slice-log"; then
  echo 'unexpected match' >&2
  exit 1
fi
echo 'ok - real stage overrun still gives triage, advisor, recut and maintenance a slice (implement and release belong to the autopilot)'


eval "$(sed -n '/^fastlane_scan_order() {/,/^}/p; /^fastlane_snapshot_candidates() {/,/^}/p; /^fastlane_read_path_contexts() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
held="$(command jq -cn '[range(1;201) | {number:.,labels:[{name:"on-hold"}],subIssuesSummary:{total:0},blockedBy:{nodes:[]}}]')"
gh() { echo 'FAIL held fastlane point read' >&2; exit 1; }
PIPELINE_SYSTEM_LABELS_JSON='["pipeline-system"]'
[ -z "$(fastlane_read_path_contexts "$held")" ]
ROADMAP_ORDER_ENABLED=false
printf 'STATUS: DONE\n' > "$NIGHT/hand-1.report"
[ "$(fastlane_snapshot_candidates "$held" | command jq 'length')" = 1 ]
echo 'ok - held fastlane cohort makes zero point reads; completed reports remain consumable'

gh() { printf '{"number":999,"state":"OPEN","labels":[],"body":"","comments":[{"body":"engine/lib.sh"}]}\n'; }
route_nonproduct_path_issue_rows() { printf '%s\n' "$1" >> "$AGENT_HOME/contexts-routed"; }
fastlane_read_path_contexts '[{"number":999,"labels":[]}]'
command jq -e '.[0].comments[0].body == "engine/lib.sh"' "$AGENT_HOME/contexts-routed" >/dev/null
echo 'ok - rich comments reach routing immediately after the leaf read'
