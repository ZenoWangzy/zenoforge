#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
test_root="$ZF_AGENT_TEST_ROOT"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
source "$SCRIPT_DIR/lib.sh"
trap 'rm -rf -- "$test_root"' EXIT
candidate_file="$test_root/main-red-candidates.json"
printf '[]\n' > "$candidate_file"

gh() {
  if [[ "$1 $2" == 'issue list' ]]; then cat -- "$candidate_file"; else return 1; fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  [[ "$expected" == "$actual" ]] || { echo "not ok - $name: expected [$expected], got [$actual]" >&2; exit 1; }
  echo "ok - $name"
}

fresh_quarantine() {
  AGENT_HOME="$(mktemp -d "$test_root/quarantine.XXXXXX")"
  STATE_DIR="$AGENT_HOME/state"
  QUARANTINE_DIR="$AGENT_HOME/quarantine"
  ENV_FAULT_DIR="$AGENT_HOME/env-faults"
  mkdir -p -- "$QUARANTINE_DIR" "$ENV_FAULT_DIR"
}

fresh_quarantine
main_ci_red_scope_extend 990201 '["packages/shared/tests/red.test.ts"]' \
  '["red-signature"]' '["packages/trigger"]' '' 'test main-ci-red scope'
stage_dispatch_allowed implement '[]' 1800000100 '["packages/other"]' ''
assert_eq 'unrelated package runs' 0 "$?"
if stage_dispatch_allowed implement '[]' 1800000100 '["packages/shared"]' ''; then
  echo 'not ok - overlapping package is blocked' >&2
  exit 1
fi
echo 'ok - overlapping package blocked'

main_ci_red_scope_extend 990202 '[]' '["unknown-signature"]' \
  '["packages/trigger"]' '' 'unparseable main log'
if stage_dispatch_allowed implement '[]' 1800000101 '["packages/other"]' ''; then
  echo 'not ok - unknown scope blocks all' >&2
  exit 1
fi
echo 'ok - unknown scope blocks all'

fresh_quarantine
main_ci_red_scope_extend 990203 '["scripts/failed.test.mjs"]' \
  '["red-signature"]' '["scripts/failed.test.mjs"]' 902 'test epic scope'
if main_ci_red_candidate_allowed '["packages/other"]' 902; then
  echo 'not ok - same roadmap epic blocked' >&2
  exit 1
fi
echo 'ok - same roadmap epic blocked'
main_ci_red_candidate_allowed '["packages/other"]' 903
echo 'ok - different roadmap epic runs'
for issue in 990211 990212 990213 990214 990215; do
  main_ci_red_record_dispatch "$issue" '["packages/other"]' 903
done
main_ci_red_record_same_signature_failure 990211 red-signature
assert_eq 'five dispatches recorded' 5 "$(jq -r '.scoped_dispatches | length' "$(quarantine_file implement)")"
assert_eq 'one same-signature failure triggers full block' true "$(jq -r '.full_block' "$(quarantine_file implement)")"
assert_eq 'replay ledger records same-signature full-block transition' 1 \
  "$(jq -r -s '[.[] | select(.event == "fallback")] | length' "$(main_ci_red_episode_file)")"

# Existing main-red records predate scope metadata. Upgrade from their exact
# run and ledger row before admitting any ticket; lookup failures stay blocked.
fresh_quarantine
legacy_detail='main ci.yml push run 990298 shares failing test with PR #990299: node red-signature'
quarantine_open implement env:main-ci-red "$legacy_detail" 1
legacy_quarantine="$(quarantine_file implement)"
jq 'del(.scope_known,.full_block,.blocked_paths,.failed_test_ids,.main_run_ids,.blocked_epics)' \
  "$legacy_quarantine" > "$legacy_quarantine.tmp" && mv "$legacy_quarantine.tmp" "$legacy_quarantine"
printf '1791735816\timplement\t990299\tenv:main-ci-red\t%s\n' "$legacy_detail" \
  > "$ENV_FAULT_DIR/$(env_fault_key env:main-ci-red).log"
export ZF_ROADMAP_TREE_CACHE_FILE="$test_root/roadmap.json"
cat > "$ZF_ROADMAP_TREE_CACHE_FILE" <<'JSON'
{"roots":[{"number":1,"title":"theme","state":"open","labels":["roadmap-theme"],"children":[{"number":2,"title":"group","state":"open","labels":[],"children":[{"number":902,"title":"epic","state":"open","labels":["roadmap-epic"],"children":[{"number":990299,"title":"trigger","state":"open","labels":[]}]}]}]}]}
JSON
gh() {
  if [[ "$1 $2" == 'run view' ]]; then
    printf '%s\n' $'FAIL packages/trigger/tests/red.test.mjs > red-signature\nnot ok 1 - red-signature'
  elif [[ "$1 $2" == 'issue view' ]]; then
    printf '%s\n' '{"body":"","labels":[{"name":"pkg:trigger"}]}'
  else
    return 1
  fi
}
main_ci_red_candidate_allowed '["packages/other"]' 903
assert_eq 'legacy quarantine upgrades from failed run' true \
  "$(jq -r '.scope_known' "$legacy_quarantine")"
assert_eq 'legacy quarantine recovers trigger epic' '["902"]' \
  "$(jq -c '.blocked_epics' "$legacy_quarantine")"
if main_ci_red_candidate_allowed '["packages/other"]' 902; then
  echo 'not ok - hydrated trigger epic is blocked' >&2
  exit 1
fi
echo 'ok - hydrated trigger epic blocked'

scope_paths="$(ci_failed_test_scope_from_log $'job\tstep\t FAIL /src/scripts/deploy-regression-contract.test.mjs > ratchet\nnot ok 1 - wall-clock contract\n  location: /src/scripts/deploy-regression-contract.test.mjs:111:1\n')"
assert_eq 'failed suite maps to workflow source paths' \
  '[".github/workflows/agent-workflow-contract.yml",".github/workflows/ci.yml",".github/workflows/migration-sql-gate.yml",".github/workflows/pipeline-suites.yml","engine/mac-autopilot/required-pr-checks.json","package.json","pnpm-lock.yaml","pnpm-workspace.yaml","scripts/check-regression-contract-teeth.mjs","scripts/deploy-regression-contract.test.mjs"]' \
  "$scope_paths"
assert_eq 'package test failure quarantines full package' \
  '["packages/example","packages/example/tests/red.test.mjs"]' \
  "$(ci_failed_test_scope_from_log $'FAIL packages/example/tests/red.test.mjs > red-signature\n')"
assert_eq 'unmapped non-package failure is unknown' '[]' \
  "$(ci_failed_test_scope_from_log $'FAIL scripts/unmapped.test.mjs > unknown-signature\n')"
surface="$(issue_change_surface_json \
  '{"expected_paths":[],"expected_packages":[]}' \
  $'## Key files and symbols\n- `packages/example/src/receipt.ts`\n' \
  '[{"name":"pkg:another"}]')"
assert_eq 'issue key files and package labels expand candidate surface' \
  '["packages/another","packages/example/src/receipt.ts"]' "$surface"

roadmap_tree='{"roots":[{"number":1,"title":"theme","state":"open","labels":["roadmap-theme"],"children":[{"number":11,"title":"group","state":"open","labels":[],"children":[{"number":902,"title":"epic","state":"open","labels":["roadmap-epic"],"children":[{"number":990205,"title":"candidate","state":"open","labels":[]}]}]}]}]}'
roadmap_flat="$(roadmap_flatten "$roadmap_tree")"
ROADMAP_ISSUE_EPICS_JSON="$(jq -c '
  . as $nodes
  | [$nodes[] as $issue | select($issue.depth == 3) | $nodes[]
     | select(.number == $issue.parent and .depth == 2 and (.labels | index("roadmap-epic") != null))
     | {key:($issue.number | tostring),value:(.number | tostring)}] | from_entries
' <<< "$roadmap_flat")"
assert_eq 'roadmap leaf maps to parent epic' '{"990205":"902"}' "$ROADMAP_ISSUE_EPICS_JSON"

# A complete open/lift episode preserves candidate scope and replays without
# estimating actual saved ticket-hours.
fresh_quarantine
mkdir -p "$STATE_DIR"
ZF_ROADMAP_TREE_CACHE_FILE="$test_root/replay-roadmap.json"
export ZF_ROADMAP_TREE_CACHE_FILE
cat > "$ZF_ROADMAP_TREE_CACHE_FILE" <<'JSON'
{"roots":[{"number":1,"title":"theme","state":"open","labels":["roadmap-theme"],"children":[{"number":11,"title":"group","state":"open","labels":[],"children":[{"number":902,"title":"red epic","state":"open","labels":["roadmap-epic"],"children":[{"number":991302,"title":"overlap","state":"open","labels":[]}]},{"number":903,"title":"other epic","state":"open","labels":["roadmap-epic"],"children":[{"number":991301,"title":"disjoint","state":"open","labels":[]},{"number":991303,"title":"unknown","state":"open","labels":[]}]}]}]}]}
JSON
jq -n '{expected_paths:["packages/other/src/file.ts"],expected_packages:["packages/other"]}' > "$STATE_DIR/991301.json"
jq -n '{expected_paths:["packages/red/src/file.ts"],expected_packages:["packages/red"]}' > "$STATE_DIR/991302.json"
jq -n '{}' > "$STATE_DIR/991303.json"
cat > "$candidate_file" <<'JSON'
[{"number":991301,"body":"","labels":[{"name":"pkg:other"}]},{"number":991302,"body":"","labels":[{"name":"package:red"}]},{"number":991303,"body":"","labels":[]}]
JSON
gh() {
  if [[ "$1 $2" == 'issue list' ]]; then cat -- "$candidate_file"; else return 1; fi
}
main_ci_red_scope_extend 990299 '["packages/red/tests/red.test.ts"]' \
  '["red-signature"]' '["packages/red"]' 902 'test episode snapshot'
quarantine_lift implement 'newest main push succeeded' "$(date +%s)"
episode_file="$(main_ci_red_episode_file)"
assert_eq 'one episode open and one linked lift are retained' \
  'open,lift' "$(jq -r -s 'map(.event) | join(",")' "$episode_file")"
assert_eq 'open and lift share same episode id' true \
  "$(jq -r -s '.[0].episode_id == .[1].episode_id' "$episode_file")"
assert_eq 'episode snapshot retains failed run and signature' \
  '990299|red-signature' \
  "$(jq -r -s '.[0] | [(.failed_run_ids | map(tostring) | join(",")),(.failed_signatures | join(","))] | join("|")' "$episode_file")"
assert_eq 'candidate expected scope and package labels are snapshotted' \
  '["packages/other/src/file.ts"]|["packages/other"]|["pkg:other"]' \
  "$(jq -r -s '.[0].candidate_snapshot.candidates[] | select(.issue_id == 991301) | [(.expected_paths|tojson),(.expected_packages|tojson),(.package_labels|tojson)] | join("|")' "$episode_file")"
assert_eq 'candidate roadmap epic is snapshotted' 903 \
  "$(jq -r -s '.[0].candidate_snapshot.candidates[] | select(.issue_id == 991301) | .roadmap_epic' "$episode_file")"
replay="$(AGENT_HOME="$AGENT_HOME" node "$SCRIPT_DIR/main-ci-red-replay.mjs")"
assert_eq 'replay classifies disjoint, overlapping and unknown candidates' \
  '1|1|1' "$(jq -r '[.allowed,.blocked,.unknown] | join("|")' <<< "$replay")"
assert_eq 'replay never claims actual saved ticket-hours' UNKNOWN \
  "$(jq -r '.actual_saved_ticket_hours' <<< "$replay")"
assert_eq 'replay emits candidate exposure durations' true \
  "$(jq -r '.candidate_exposure_seconds | type == "object" and (.allowed | type == "number") and (.unknown | type == "number")' <<< "$replay")"

# An open event without retained lift time stays UNKNOWN after the active file is gone.
fresh_quarantine
mkdir -p "$QUARANTINE_DIR"
missing_lift_at="$(date +%s)"
jq -cn --argjson opened_at "$((missing_lift_at - 60))" '{event:"open",episode_id:"missing-lift",opened_at:$opened_at,scope_known:true,full_block:true,blocked_paths:[],blocked_epics:[],failed_run_ids:[999998],failed_signatures:["red-signature"],candidate_snapshot:{status:"complete",candidates:[{issue_id:991304,surface:["packages/other"],scope_known:true}]}}' \
  > "$QUARANTINE_DIR/main-ci-red-episodes.jsonl"
missing_lift_replay="$(AGENT_HOME="$AGENT_HOME" node "$SCRIPT_DIR/main-ci-red-replay.mjs")"
assert_eq 'missing historical lift timestamp remains UNKNOWN' UNKNOWN \
  "$(jq -r '.lifted_at' <<< "$missing_lift_replay")"
assert_eq 'missing historical exposure duration remains UNKNOWN' UNKNOWN \
  "$(jq -r '.candidate_exposure_seconds' <<< "$missing_lift_replay")"

# Fault rows without an episode snapshot retain UNKNOWN history in replay.
fresh_quarantine
legacy_fault_at="$(date +%s)"
mkdir -p "$ENV_FAULT_DIR"
printf '%s\timplement\t990298\tenv:main-ci-red\tmain ci.yml push run 999999 failed\n' "$legacy_fault_at" \
  > "$ENV_FAULT_DIR/$(env_fault_key env:main-ci-red).log"
legacy_replay="$(AGENT_HOME="$AGENT_HOME" node "$SCRIPT_DIR/main-ci-red-replay.mjs")"
assert_eq 'legacy fault without retained episode reports UNKNOWN' \
  'UNKNOWN|UNKNOWN|UNKNOWN' \
  "$(jq -r '[.opened_at,.lifted_at,.candidate_exposure_seconds] | join("|")' <<< "$legacy_replay")"
