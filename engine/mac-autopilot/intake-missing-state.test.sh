#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

fixture="$test_env_root/intake-missing-state"
AGENT_HOME="$fixture/agent-home"
A="$fixture/autopi"
LOG="$A/scheduler.log"
UNITS="$A/units.json"
WORKERS="$A/workers.json"
STAMP=2026-11-02T00:00:00Z
NOW_EPOCH=1793577600
MAX=1
CFG='{"issue_intake":{"enabled":true,"max_upstream":8,"max_ready":30,"ready_buffer":0,"labels":[],"product_labels":["ready-for-agent"]}}'
HANDOFF_PR_CENSUS='[]'
HANDOFF_CENSUS_PARTIAL=0
mkdir -p "$AGENT_HOME/state" "$A/alerts"
: > "$LOG"
printf '%s\n' '{"units":[{"id":"issue-2826","issue":2826,"branch":"agent/issue-2826","stage":"blocked-external","pr":null}]}' > "$UNITS"

source "$script_dir/scheduler.d/core.sh"
source "$script_dir/scheduler.d/units.sh"
source "$script_dir/scheduler.d/intake-steps.sh"
source "$script_dir/scheduler.d/intake.sh"
UNITS_ARCHIVE="$A/units-archive.json"

hotfix_lane_label() { printf 'hotfix-lane\n'; }
hotfix_issue_numbers() { return 0; }
live_workers() { printf '0\n'; }
tick_prs_prime() { :; }
tick_prs() { printf '[]\n'; }
intake_footprint_snapshot() { printf '[]\n'; }
candidate_json="$(jq -cn '{number:2826,title:"fixture",body:"",state:"OPEN",labels:[{name:"ready-for-agent"}]}')"
candidate64="$(printf '%s' "$candidate_json" | base64 | tr -d '\n')"
intake_candidates() { printf '2826\tpr\tfixture\t[]\t%s\n' "$candidate64"; }

state_file="$AGENT_HOME/state/2826.json"
[[ ! -e "$state_file" ]] || { echo 'not ok - fixture state file must be missing' >&2; exit 1; }
register_new_issues || { echo 'not ok - intake failed for a candidate without optional state' >&2; exit 1; }
if grep -Fq 'jqf error' "$LOG"; then
  cat "$LOG" >&2
  echo 'not ok - missing optional issue state was logged as a jqf error' >&2
  exit 1
fi
[[ ! -e "$state_file" ]] || { echo 'not ok - optional read created issue state' >&2; exit 1; }

printf '%s\n' '{invalid' > "$state_file"
if register_new_issues; then
  echo 'not ok - intake accepted malformed existing issue state' >&2
  exit 1
fi
grep -Fq 'jqf error' "$LOG" && grep -Fq 'in register_new_issues' "$LOG" \
  || { echo 'not ok - malformed optional state lost jqf diagnostics' >&2; exit 1; }

echo 'ok - missing issue state means no handoff; malformed existing state still logs'
