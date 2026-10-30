#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
NIGHT="$tmp/night"
mkdir -p "$NIGHT"
source "$REPO_DIR/engine/night/hand-agent-watchdog.sh"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" != "$actual" ]; then
    printf 'not ok - %s\nexpected: <%s>\nactual:   <%s>\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  printf 'ok - %s\n' "$label"
}

EMPTY_EPOCH_NOW="$(date +%s)"
EMPTY_EPOCH_TZ_MIN=$(( (1440 - (EMPTY_EPOCH_NOW / 60) % 1440 + 1) % 1440 ))
export TZ="PIN-$((EMPTY_EPOCH_TZ_MIN / 60)):$((EMPTY_EPOCH_TZ_MIN % 60))"
empty_write_event="$tmp/empty-write-event.jsonl"
jq -cn '{type:"response_item",payload:{type:"custom_tool_call_output",output:[{text:"To https://example.invalid/repo -> abc"}]},timestamp:""}' \
  > "$empty_write_event"
assert_eq 1 "$(hand_agent_codex_session_write_epoch "$empty_write_event" >/dev/null 2>&1 && echo 0 || echo 1)" \
  'empty commit timestamp takes parser fallback'

issues="$(hand_agent_issue_ids hand-1820 '1820 1815')"
assert_eq '1820 1815' "$issues" 'explicit issue list merges with hand-N name and deduplicates'
brief="$tmp/named-agent.md"
printf 'Owned issues: 3240 3242 3243\n\nFix all three tickets.\n' > "$brief"
assert_eq '3240 3242 3243' "$(hand_agent_issue_ids_from_brief hand-hold-state-1011 "$brief")" \
  'named multi-issue hand reads its owned issue list from the brief'
assert_eq '3240 3244 3242 3243' "$(hand_agent_issue_ids_from_brief hand-hold-state-1011 "$brief" '3240 3244')" \
  'explicit queue ownership unions with brief header and deduplicates'
nodes="$(hand_agent_node_names hand-owner 'pipeline-ci outcomes-pipeline-closure')"
assert_eq 'pipeline-ci outcomes-pipeline-closure' "$nodes" \
  'explicit owned nodes validate and deduplicate'
if hand_agent_issue_ids hand-1820 '1815 invalid' >/dev/null 2>&1; then
  echo 'not ok - invalid owned issue number refused' >&2
  exit 1
fi
echo 'ok - invalid owned issue number refused'
if hand_agent_node_names hand-owner 'pipeline-ci bad/node' >/dev/null 2>&1; then
  echo 'not ok - invalid owned node refused' >&2
  exit 1
fi
echo 'ok - invalid owned node refused'

stats="$(hand_agent_proc_stats "$$")"
read -r _cpu start_ticks _state <<< "$stats"
printf '%s\thand-1820\t%s\t%s\tworktree\tbrief\treport\tlog\t0\t1\twork\t%s\t1820 1815\tpipeline-ci outcomes-pipeline-closure\n' "$$" "$MODEL_POLICY_TEST_WORK_MODEL" "$MODEL_POLICY_TEST_WORK_EFFORT" "$start_ticks" > "$NIGHT/agents.txt"
if ! hand_agent_pid_live "$$" "$start_ticks"; then
  echo 'not ok - recorded PID and start identity accepted as live' >&2
  exit 1
fi
echo 'ok - recorded PID and start identity accepted as live'
assert_eq 1 "$(hand_agent_pid_live "$$" "$((start_ticks + 1))" && echo 0 || echo 1)" \
  'mismatched start identity refused'
assert_eq 0 "$(hand_agent_issue_is_live_owned 1820 && echo 0 || echo 1)" \
  'live hand agent owns first recorded issue'
assert_eq 0 "$(hand_agent_issue_is_live_owned 1815 && echo 0 || echo 1)" \
  'live hand agent owns second recorded issue'
assert_eq 1 "$(hand_agent_issue_is_live_owned 1918 && echo 0 || echo 1)" \
  'unlisted issue remains unowned'
assert_eq 0 "$(hand_agent_node_is_live_owned pipeline-ci && echo 0 || echo 1)" \
  'live hand agent owns first recorded node'
assert_eq 0 "$(hand_agent_node_is_live_owned outcomes-pipeline-closure && echo 0 || echo 1)" \
  'live hand agent owns second recorded node'
assert_eq 1 "$(hand_agent_node_is_live_owned outcomes && echo 0 || echo 1)" \
  'unlisted node remains unowned'
printf '%s\thand-1820\t%s\t%s\tworktree\tbrief\treport\tlog\t0\t1\twork\t%s\t1820 1815\n' \
  "$$" "$MODEL_POLICY_TEST_WORK_MODEL" "$MODEL_POLICY_TEST_WORK_EFFORT" "$((start_ticks + 1))" > "$NIGHT/agents.txt"
assert_eq 1 "$(hand_agent_issue_is_live_owned 1820 && echo 0 || echo 1)" \
  'reused PID with mismatched start identity does not own issue'

sleep 30 &
child_pid=$!
child_stats="$(hand_agent_proc_stats "$child_pid")"
read -r _child_cpu child_start_ticks _child_state <<< "$child_stats"
printf '%s\thand-1815\t%s\t%s\tworktree\tbrief\treport\tlog\t0\t1\twork\t%s\t1815\n' \
  "$child_pid" "$MODEL_POLICY_TEST_WORK_MODEL" "$MODEL_POLICY_TEST_WORK_EFFORT" "$child_start_ticks" > "$NIGHT/agents.txt"
assert_eq 0 "$(hand_agent_issue_is_live_owned 1815 && echo 0 || echo 1)" \
  'live hand agent owns its issue before exit'
kill "$child_pid"
wait "$child_pid" 2>/dev/null || true
assert_eq 1 "$(hand_agent_issue_is_live_owned 1815 && echo 0 || echo 1)" \
  'exited hand agent releases its issue immediately'

AGENT_HOME="$tmp/agent"
DRY_RUN=0
source "$REPO_DIR/engine/lib.sh"
STATE_DIR="$tmp/state"
mkdir -p "$STATE_DIR"
state_merge 1820 '.attempts = 3 | .state = "ready-for-agent"'
record_implement_tick_decision 1820 test skipped hand-owned 'live hand agent owns issue' hand-agent
record_advisor_tick_decision 1820 test skipped hand-owned 'live hand agent owns issue' hand-agent
record_triage_tick_decision 1820 test skipped hand-owned 'live hand agent owns issue' hand-agent
assert_eq '3 ready-for-agent true true true' \
  "$(jq -r '[.attempts,.state,(.implement_tick_decision.gate == "hand-owned"),(.advisor_tick_decision.gate == "hand-owned"),(.triage_tick_decision.gate == "hand-owned")]|map(tostring)|join(" ")' "$STATE_DIR/1820.json")" \
  'all three stage decisions persist without changing attempts or state'

PIPELINE="$REPO_DIR/engine/issue-pipeline.sh"
for gate in \
  'hand_agent_issue_is_live_owned "$next_triage"' \
  'hand_agent_issue_is_live_owned "$next_measure"' \
  'hand_agent_issue_is_live_owned "$advisor_id"' \
  'hand_agent_issue_is_live_owned "$next_poll"' \
  'hand_agent_issue_is_live_owned "$next_orphan"' \
  'hand_agent_issue_is_live_owned "$n"' \
  'record_hand_owned_decision triage "$next_triage"' \
  'record_hand_owned_decision advisor "$advisor_id"'; do
  grep -Fq "$gate" "$PIPELINE" || { echo "not ok - selector gate missing: $gate" >&2; exit 1; }
done
echo 'ok - triage and advisor selectors retain hand-owned gates'
