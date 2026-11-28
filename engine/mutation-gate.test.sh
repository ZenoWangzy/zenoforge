#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ZF_COORD=on
source "$SCRIPT_DIR/lib.sh"

fail() { printf 'mutation-gate.test.sh: %s\n' "$*" >&2; exit 1; }
coord_remote_enabled() { [[ "${ZF_COORD:-off}" == on ]]; }
coord_assert_owned() {
  [[ "$#" == 1 && "$1" == "${ZF_COORD_SCOPE:-}" && "$1" == ticket:issue-* \
    && "${ZF_COORD_OWNER:-}" == fixture-owner ]]
}
ensure_state_labels() { :; }
is_on_hold() { return 1; }
roadmap_ensure_issue_parent() { return 0; }

blocked_write="$test_env_root/blocked-write"
if guarded_write touch "$blocked_write" 2>/dev/null; then
  fail 'unscoped write succeeded while coordination was on'
fi
[[ ! -e "$blocked_write" ]] || fail 'unscoped write reached its command'

ZF_COORD_SCOPE=ticket:issue-84001 ZF_COORD_OWNER=fixture-owner
allowed_write="$test_env_root/allowed-write"
guarded_write touch "$allowed_write" || fail 'owned write was refused'
[[ -e "$allowed_write" ]] || fail 'owned write did not reach its command'

ZF_COORD=off
unset ZF_COORD_SCOPE ZF_COORD_OWNER
off_write="$test_env_root/off-write"
guarded_write touch "$off_write" || fail 'coordination-off write changed behavior'
[[ -e "$off_write" ]] || fail 'coordination-off write did not reach its command'

ZF_COORD=on
DRY_RUN=0
mkdir -p -- "$STATE_DIR"
printf '%s\n' '{"state":"needs-triage","attempts":0}' > "$STATE_DIR/84002.json"
before="$(cat "$STATE_DIR/84002.json")"
if issue_transition 84002 needs-advisor mutation-gate-test . 1; then
  fail 'unscoped issue transition succeeded while coordination was on'
fi
[[ "$(cat "$STATE_DIR/84002.json")" == "$before" ]] \
  || fail 'unscoped issue transition changed local state'

printf '%s\n' '{"state":"needs-triage","attempts":0}' > "$STATE_DIR/84003.json"
ZF_COORD_SCOPE=ticket:issue-84003 ZF_COORD_OWNER=fixture-owner
issue_transition 84003 needs-advisor mutation-gate-test . 1 \
  || fail 'owned issue transition was refused'
[[ "$(jq -r '.state' "$STATE_DIR/84003.json")" == needs-advisor ]] \
  || fail 'owned issue transition did not change local state'

printf 'mutation-gate.test.sh: PASS\n'
