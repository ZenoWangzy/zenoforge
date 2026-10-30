#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/night/outcomes-audit.sh"

REPO=test/repo
roadmap_ensure_issue_parent() { :; }
ensure_state_labels() { :; }
ISSUE_LABEL_SNAPSHOT_STATE[on-hold]=complete
ISSUE_LABEL_SNAPSHOT_IDS[on-hold]=""
GH_WRITES="$AGENT_HOME/gh-writes"
guarded_write() { printf '%s\n' "$*" >> "$GH_WRITES"; }

state_merge 5301 '{"state":"ready-for-agent"}'
issue_reconcile_closed_state 5301 '{"number":5301,"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-10-12T12:00:00Z","labels":[{"name":"ready-for-agent"}]}'
[[ "$(state_read 5301 | jq -r .state)" == concluded ]]
grep -Fq -- 'issue edit 5301' "$GH_WRITES"
grep -Fq -- '--remove-label ready-for-agent' "$GH_WRITES"
grep -Fq -- '--add-label concluded' "$GH_WRITES"
echo 'ok - completed close reconciles state and labels through issue_transition'

state_merge 5302 '{"state":"tracker"}'
state_merge 5303 '{"state":"needs-advisor"}'
closed_rows='[
  {"number":5302,"stateReason":"NOT_PLANNED","closedAt":"2026-10-12T12:00:00Z","labels":[{"name":"pipeline-system"}]},
  {"number":5303,"stateReason":"NOT_PLANNED","closedAt":"2026-10-12T12:00:00Z","labels":[{"name":"duplicate"}]}
]'
outcomes_reconcile_closed_states "$AGENT_HOME" "$closed_rows"
[[ "$(state_read 5302 | jq -r .state)" == wontfix ]]
[[ "$(state_read 5303 | jq -r .state)" == duplicate ]]
grep -Fq -- '--add-label wontfix' "$GH_WRITES"
grep -Fq -- '--add-label duplicate' "$GH_WRITES"
echo 'ok - not-planned and duplicate closes reconcile through shared close path'

state_merge 5306 '{"state":"ready-for-agent","released":true}'
issue_reconcile_closed_state 5306 '{"number":5306,"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-10-12T12:00:00Z","labels":[{"name":"ready-for-agent"}]}'
[[ "$(state_read 5306 | jq -r .state)" == concluded ]]
grep -Fq -- '--add-label released' "$GH_WRITES"
echo 'ok - released close keeps concluded and released stage labels'

state_merge 5307 '{"state":"on-hold","hold":{"kind":"supervisor-inbox","reason":"protected owner decision"}}'
cp "$(state_file 5307)" "$AGENT_HOME/before-observation.json"
cp "$GH_WRITES" "$AGENT_HOME/before-observation-writes"
observed="$(outcomes_reconcile_closed_states "$AGENT_HOME" \
  '[{"number":5307,"stateReason":"COMPLETED","closedAt":"2026-10-12T12:00:00Z","labels":[]}]' observe)"
cmp "$(state_file 5307)" "$AGENT_HOME/before-observation.json" || { echo 'not ok - observation changed lifecycle or protected hold' >&2; exit 1; }
cmp "$GH_WRITES" "$AGENT_HOME/before-observation-writes" || { echo 'not ok - observation wrote GitHub labels' >&2; exit 1; }
[[ "$observed" == 'pending=1 issues=#5307 held=1' ]]
echo 'ok - observational closed evidence retains protected hold/state and reports pending reconciliation without GH writes'

state_merge 5308 '{"state":"concluded","hold":{"kind":"supervisor-inbox","reason":"still protected"}}'
observed="$(outcomes_reconcile_closed_states "$AGENT_HOME" \
  '[{"number":5308,"stateReason":"COMPLETED","closedAt":"2026-10-12T12:00:00Z","labels":[]}]' observe)"
[[ "$observed" == 'pending=1 issues=#5308 held=1' ]]
[[ "$(state_read 5308 | jq -r '.hold.reason')" == 'still protected' ]]
printf '{"state":null}\n' > "$STATE_DIR/5309.json"
if outcomes_reconcile_closed_states "$AGENT_HOME" \
  '[{"number":5309,"stateReason":"COMPLETED","closedAt":"2026-10-12T12:00:00Z","labels":[]}]' observe; then
  echo 'not ok - invalid local lifecycle metadata was treated as observed clean' >&2; exit 1
fi
echo 'ok - observation exposes terminal/hold contradiction and refuses unreadable lifecycle metadata'

state_merge 5305 '{"state":"ready-for-agent"}'
OUTCOMES_RECONCILE_DRY_RUN=1 outcomes_reconcile_closed_states "$AGENT_HOME" \
  '[{"number":5305,"stateReason":"COMPLETED","closedAt":"2026-10-12T12:00:00Z","labels":[{"name":"ready-for-agent"}]}]'
[[ "$(state_read 5305 | jq -r .state)" == ready-for-agent ]]
if grep -Fq 'issue edit 5305' "$GH_WRITES"; then
  echo 'unexpected match' >&2
  exit 1
fi
echo 'ok - closed-state reconciliation honors dry-run'

state_merge 5304 '{"state":"ready-for-agent"}'
if issue_transition 5304 awaiting-release merged-pr '.run.outcome = "merged"'; then
  echo 'not ok - awaiting-release accepted without merged PR identity' >&2
  exit 1
fi
[[ "$(state_read 5304 | jq -r .state)" == ready-for-agent ]]
if grep -Fq 'issue edit 5304' "$GH_WRITES"; then
  echo 'unexpected match' >&2
  exit 1
fi
echo 'ok - shared state writer rejects awaiting-release without PR identity'
