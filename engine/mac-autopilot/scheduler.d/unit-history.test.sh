#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/core.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_equal() {
  local label="$1" expected="$2" actual="$3"
  [[ "$actual" == "$expected" ]] || {
    printf 'not ok - %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  }
}

eval_history_jq() {
  local unit="$1" expression="$2"
  jqf -c "${UNIT_HISTORY_JQ} ${expression}" <<<"$unit"
}

[[ -n "${UNIT_HISTORY_JQ:-}" ]] || fail 'UNIT_HISTORY_JQ is not defined'

missing_history='{"id":"missing-history"}'
empty_history='{"history":[]}'
events='{"history":[{"stage":"A","result":"first","at":"2026-01-01T00:00:00Z"},{"stage":"B","result":"second","at":"2026-01-02T00:00:00Z"},{"stage":"A","result":"third","at":"2026-01-03T00:00:00Z"}]}'
event_a='{"stage":"A","result":"third","at":"2026-01-03T00:00:00Z"}'
event_b='{"stage":"B","result":"second","at":"2026-01-02T00:00:00Z"}'
event_last='{"stage":"A","result":"third","at":"2026-01-03T00:00:00Z"}'

for unit in "$missing_history" "$empty_history"; do
  assert_equal 'last event on empty history' null "$(eval_history_jq "$unit" 'last_event')"
  assert_equal 'last event of selected type on empty history' null "$(eval_history_jq "$unit" 'last_event_of(["B"])')"
  assert_equal 'last event except selected type on empty history' null "$(eval_history_jq "$unit" 'last_event_except(["A"])')"
done

assert_equal 'last event' "$event_last" "$(eval_history_jq "$events" 'last_event')"
assert_equal 'last event of B' "$event_b" "$(eval_history_jq "$events" 'last_event_of(["B"])')"
assert_equal 'last event except A' "$event_b" "$(eval_history_jq "$events" 'last_event_except(["A"])')"
assert_equal 'no matching event type' null "$(eval_history_jq "$events" 'last_event_of(["C"])')"

assert_equal 'unit_last_event without types' "$event_last" "$(unit_last_event "$events")"
assert_equal 'unit_last_event for B' "$event_b" "$(unit_last_event "$events" B)"
assert_equal 'unit_last_event for A' "$event_a" "$(unit_last_event "$events" A)"
assert_equal 'unit_last_event on missing history' null "$(unit_last_event "$missing_history")"
assert_equal 'unit_last_event on empty history' null "$(unit_last_event "$empty_history")"

echo 'ok - unit history helpers select the expected events'
