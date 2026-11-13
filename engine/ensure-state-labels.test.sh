#!/usr/bin/env bash
# ensure_state_labels creates only the state labels the label list says are missing,
# and creates nothing when the list read itself failed (#1038: a failed list made
# triage, the issue loop and the scheduler create all 16 labels blind, 16 failed
# GraphQL calls each time, while GitHub's API was already rate-limited).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

REPO=example/repo
CREATES="$AGENT_HOME/label-creates"
LIST_FAIL=0
LIST_OUT=""
guarded_write() { printf '%s\n' "$4" >> "$CREATES"; }
gh() {
  [[ "$1 $2" == 'label list' ]] || { echo "unexpected gh call: $*" >&2; return 1; }
  (( LIST_FAIL == 0 )) || return 1
  printf '%s' "$LIST_OUT"
}
fail() { printf 'ensure-state-labels.test.sh: %s\n' "$*" >&2; exit 1; }

: > "$CREATES"; LIST_FAIL=1
ensure_state_labels || fail 'a failed list made ensure_state_labels return non-zero'
[[ ! -s "$CREATES" ]] || fail "a failed list still created labels: $(tr '\n' ' ' < "$CREATES")"

: > "$CREATES"; LIST_FAIL=0
LIST_OUT="$(printf '%s\n' "${ALL_STATE_LABELS[@]}" | grep -vxE 'needs-recut|concluded')"
ensure_state_labels
[[ "$(sort "$CREATES" | tr '\n' ' ')" == 'concluded needs-recut ' ]] || fail "expected only the two missing labels, got: $(tr '\n' ' ' < "$CREATES")"

: > "$CREATES"; LIST_OUT="$(printf '%s\n' "${ALL_STATE_LABELS[@]}")"
ensure_state_labels
[[ ! -s "$CREATES" ]] || fail 'a complete list still created labels'
ensure_state_labels tracker
[[ "$(cat "$CREATES")" == tracker ]] || fail "tracker mode should create only tracker, got: $(tr '\n' ' ' < "$CREATES")"
printf 'ensure-state-labels.test.sh: ok\n'
