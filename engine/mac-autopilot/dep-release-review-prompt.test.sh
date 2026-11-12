#!/usr/bin/env bash
# A unit the scheduler releases because its blocker's PR merged (issue still OPEN until release) must tell its reviewer so:
# the review prompt gets "#N delivered: PR #M merged at <sha>" and the order to accept merged-on-main; a unit never released gets no such line.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
fail() { printf 'dep-release-review-prompt.test.sh: %s\n' "$*" >&2; exit 1; }

fixture="$test_env_root/dep-release-review-prompt"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"; LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"; A="$MAC_AUTOPILOT_RUNTIME_DIR"
STAMP=2026-11-08T10:47:12Z; NOW_EPOCH=1794221232
cancel_unit_runs() { :; }
tick_prs() { printf '[]'; }
gh() { return 1; }

sha=0123456789abcdef0123456789abcdef01234567
jq -cn --arg sha "$sha" '{units: [
  {id:"issue-100",issue:100,stage:"merged",pr:55,merge_sha:$sha,task:"t",branch:"agent/issue-100",history:[]},
  {id:"issue-1",issue:1,stage:"blocked-external",blocked_on:100,body_blocked_by:[100],pr:70,task:"t",branch:"agent/issue-1",history:[]},
  {id:"issue-103",issue:103,stage:"implement-pending",task:"t",branch:"agent/issue-103",history:[]},
  {id:"issue-4",issue:4,stage:"blocked-external",blocked_on:103,body_blocked_by:[103],pr:71,task:"t",branch:"agent/issue-4",history:[]}]}' > "$UNITS"
printf '{"workers":[]}\n' > "$A/workers.json"
DEP_DELIVERED_CACHE=(); DEP_PARKED_CACHE=()
release_dependency_blocks || :

unit_of() { jq -c --arg id "$1" '.units[] | select(.id == $id)' "$UNITS"; }
[[ "$(unit_of issue-1 | jq -r .stage)" == review-pending ]] || fail 'the delivered waiter must be released to review'
line="$(supervisor_rule "$(unit_of issue-1)")"
[[ "$line" == *"#100 delivered: PR #55 merged at ${sha:0:12}"* ]] || fail "review prompt lacks the delivered line with PR and sha: $line"
[[ "$line" == *INPUT_INCOMPLETE* && "$line" == *Refs* && "$line" == *OPEN* ]] || fail "review prompt must forbid INPUT_INCOMPLETE and accept merged-on-main with the issue OPEN: $line"
[[ -z "$(supervisor_rule "$(unit_of issue-4)")" ]] || fail 'a unit never released must get no release line'

# a supervisor reroute that drops the blocker carries the ruling text
line="$(supervisor_rule '{"released_deps":[{"issue":7,"kind":"ruling","reason":"#7 ruled resolved by supervisor (obsolete, scope moved to #9)"}]}')"
[[ "$line" == *"#7 ruled resolved by supervisor (obsolete, scope moved to #9)"* && "$line" != *Refs* ]] || fail "ruling line wrong: $line"
echo ok
