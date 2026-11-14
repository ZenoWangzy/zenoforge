#!/usr/bin/env bash
# Regression tests for the two distinct recut terminal markers. A completed
# split retires the parent from the active needs-recut queue but retains its
# child list as the umbrella record; a refused recut may start another round,
# so route_to_recut clears only its refusal marker.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILED=0
TMP_DIRS=()
cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected [$expected], got [$actual])"
    FAILED=1
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected to find [$needle])"
    FAILED=1
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected NOT to find [$needle])"
    FAILED=1
  fi
}

TEST_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"
TMP_DIRS+=("$TEST_HOME" "$FAKE_BIN")
mkdir -p "$TEST_HOME/state"
# Stage-routing fixture; roadmap admission is covered by roadmap-order.test.sh.
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$TEST_HOME/model-policy.json"
GH_LOG="$TEST_HOME/gh.log"
: > "$GH_LOG"

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$FAKE_GH_LOG"
if [ "${1:-} ${2:-}" = "issue view" ]; then
  printf '%s\n' '{"labels":[],"comments":[]}'
fi
if [ "${1:-}" = api ]; then
  printf '{"number":%s,"state":"open","pull_request":null,"labels":[]}\n' "${2##*/}"
fi
EOF
chmod +x "$FAKE_BIN/gh"

run_lib() {
  local command="$1"
  shift
  set +e
  RUN_OUTPUT="$(PATH="$FAKE_BIN:$PATH" AGENT_HOME="$TEST_HOME" ZF_REPO="test/repo" FAKE_GH_LOG="$GH_LOG" "$@" bash -c "source \"\$0/lib.sh\"; $command" "$SCRIPT_DIR" 2>&1)"
  RUN_STATUS=$?
  set -e
}

# The recut wrapper's terminal write must delegate to the shared transition,
# rather than writing the permanent marker on its own and forgetting the
# matching active-label retirement.
RUN_RECUT_COMPLETION="$(sed -n '/^CHILD_NUMBERS_JSON=/,/^\[ -z/p' "$SCRIPT_DIR/run-recut.sh")"
assert_contains "run-recut delegates its completed-parent transition to the shared writer" \
  "$RUN_RECUT_COMPLETION" 'complete_recut_parent "$N" "$CHILD_NUMBERS_JSON"'
assert_not_contains "run-recut no longer writes recut_children without retiring its queue label" \
  "$RUN_RECUT_COMPLETION" 'state_merge "$N"'

# A successfully cut parent is now an umbrella only, not active recut work.
printf '{"attempts":0}' > "$TEST_HOME/state/7001.json"
run_lib 'complete_recut_parent 7001 "[701,702]"' env
STATE_7001="$(cat "$TEST_HOME/state/7001.json")"
GH_AFTER_7001="$(cat "$GH_LOG")"
assert_eq "completed recut parent exits successfully" "0" "$RUN_STATUS"
assert_eq "completed recut parent records its children" "true" \
  "$(echo "$STATE_7001" | jq 'has("recut_children")')"
assert_contains "completed recut parent retains both child numbers" \
  "$STATE_7001" '701'
assert_contains "completed recut parent retires needs-recut through the shared writer" \
  "$GH_AFTER_7001" "gh issue edit 7001 --repo test/repo"
assert_contains "completed recut parent removes needs-recut" \
  "$GH_AFTER_7001" "--remove-label needs-recut"

# recut_children is permanent: an attempted new recut route must fail before
# adding its active label, rather than deleting the child record and risking a
# second set of children.
printf '{"attempts":0,"recut_children":[703]}' > "$TEST_HOME/state/7002.json"
: > "$GH_LOG"
run_lib 'route_to_recut 7002' env
STATE_7002="$(cat "$TEST_HOME/state/7002.json")"
GH_AFTER_7002="$(cat "$GH_LOG")"
assert_eq "child-completed parent rejects a new recut route" "1" "$RUN_STATUS"
assert_eq "child-completed parent keeps its permanent child marker" "true" \
  "$(echo "$STATE_7002" | jq 'has("recut_children")')"
assert_not_contains "child-completed parent receives no needs-recut label write" \
  "$GH_AFTER_7002" "gh issue edit 7002"

# A refusal marker is different: it belongs to an earlier episode and is
# cleared as the new needs-recut route is applied.
printf '{"attempts":0,"recut_refused_at":"2026-01-01T00:00:00Z"}' > "$TEST_HOME/state/7003.json"
: > "$GH_LOG"
run_lib 'route_to_recut 7003' env
STATE_7003="$(cat "$TEST_HOME/state/7003.json")"
GH_AFTER_7003="$(cat "$GH_LOG")"
assert_eq "refused parent can enter a new recut route" "0" "$RUN_STATUS"
assert_eq "new recut route clears the earlier refusal marker" "false" \
  "$(echo "$STATE_7003" | jq 'has("recut_refused_at")')"
assert_contains "new recut route applies needs-recut" \
  "$GH_AFTER_7003" "gh issue edit 7003 --repo test/repo"
assert_contains "new recut route adds needs-recut" \
  "$GH_AFTER_7003" "--add-label needs-recut"

# Measured size evidence is committed with the same label transition; the
# existing second argument remains an issue snapshot, not size evidence.
printf '{"state":"ready-for-agent"}' > "$TEST_HOME/state/7005.json"
: > "$GH_LOG"
run_lib "route_to_recut 7005 '' '{\"kind\":\"size-admission\",\"lines\":801,\"limit\":800}'" env
assert_eq "measured size route succeeds" "0" "$RUN_STATUS"
assert_eq "size evidence and recut state are persisted together" "true" \
  "$(jq '.state == "needs-recut" and .size_admission.lines == 801 and .size_admission.limit == 800' "$TEST_HOME/state/7005.json")"
assert_contains "size route changes the issue label" "$(cat "$GH_LOG")" "--add-label needs-recut"
printf '{"state":"ready-for-agent"}' > "$TEST_HOME/state/7006.json"
run_lib "route_to_recut 7006 '{\"number\":7006,\"labels\":[]}'" env
assert_eq "issue snapshot does not become size evidence" "false" "$(jq 'has("size_admission")' "$TEST_HOME/state/7006.json")"
printf '%s\n' '{"state":"needs-advisor","model_policy":{"failure":{"unit":"recut"}},"size_admission":{"kind":"size-admission","lines":801,"limit":800}}' > "$TEST_HOME/state/7007.json"
run_lib 'route_to_recut 7007' env
assert_eq "advisor retry preserves the failed recut size evidence" "801" "$(jq '.size_admission.lines' "$TEST_HOME/state/7007.json")"
printf '%s\n' '{"state":"ready-for-agent","size_admission":{"lines":801}}' > "$TEST_HOME/state/7008.json"
run_lib 'route_to_recut 7008' env
assert_eq "unrelated later recut clears stale size evidence" "false" "$(jq 'has("size_admission")' "$TEST_HOME/state/7008.json")"

# AGENT_DRY_RUN remains authoritative for both the local marker write and
# the external label removal.
printf '{"attempts":0}' > "$TEST_HOME/state/7004.json"
BEFORE_7004="$(cat "$TEST_HOME/state/7004.json")"
: > "$GH_LOG"
run_lib 'complete_recut_parent 7004 "[704]"' env AGENT_DRY_RUN=1
AFTER_7004="$(cat "$TEST_HOME/state/7004.json")"
GH_AFTER_7004="$(cat "$GH_LOG")"
assert_eq "dry-run completed parent exits successfully" "0" "$RUN_STATUS"
assert_contains "dry-run prints the planned state write" "$RUN_OUTPUT" "[dry-run] state_merge 7004"
assert_contains "dry-run prints the planned label edit" "$RUN_OUTPUT" "[dry-run] gh issue edit 7004 --repo test/repo"
assert_contains "dry-run prints the planned label removal" "$RUN_OUTPUT" "--remove-label needs-recut"
assert_eq "dry-run does not change the parent state" "$BEFORE_7004" "$AFTER_7004"
assert_eq "dry-run does not execute gh" "" "$GH_AFTER_7004"

# Recut loop: the third recut route for one issue is held for a size ruling, whichever unit asks for it.
# State already holds two recut rounds (7010), so this route would be the third: it holds, keeps its size numbers and stops.
printf '%s\n' '{"attempts":0,"state":"ready-for-agent","recut_rounds":2}' > "$TEST_HOME/state/7010.json"
: > "$GH_LOG"
run_lib "route_to_recut 7010 '' '{\"kind\":\"size-admission\",\"lines\":650,\"limit\":640}'" env
STATE_7010="$(cat "$TEST_HOME/state/7010.json")"
assert_eq "third recut route is held, not routed" "0" "$RUN_STATUS"
assert_eq "recut loop hold has kind recut-loop" "recut-loop" "$(echo "$STATE_7010" | jq -r '.hold.kind // empty')"
assert_eq "recut loop hold resumes at ready-for-agent, not needs-recut" "ready-for-agent" "$(echo "$STATE_7010" | jq -r '.hold.stage_before // empty')"
assert_eq "recut loop hold keeps the round counter at two" "2" "$(echo "$STATE_7010" | jq -r '.recut_rounds')"
assert_eq "recut loop hold keeps the size numbers for reconcile" "650" "$(echo "$STATE_7010" | jq -r '.size_admission.lines')"
assert_contains "recut loop hold does not apply needs-recut" "$(cat "$GH_LOG")" "--add-label on-hold"
assert_not_contains "recut loop hold adds no needs-recut label" "$(cat "$GH_LOG")" "--add-label needs-recut"
assert_contains "recut loop stop logs the issue, rounds, estimate and limit" "$RUN_OUTPUT" \
  "recut loop stop issue=#7010 rounds=3 estimate=650 limit=640"

# One earlier round still routes, and the route counts it.
printf '%s\n' '{"attempts":0,"state":"ready-for-agent","recut_rounds":1}' > "$TEST_HOME/state/7011.json"
: > "$GH_LOG"
run_lib 'route_to_recut 7011' env
assert_eq "second recut route still goes to recut" "0" "$RUN_STATUS"
assert_eq "second recut route applies needs-recut" "true" "$(jq '.state == "needs-recut"' "$TEST_HOME/state/7011.json")"
assert_eq "second recut route counts its round" "2" "$(jq -r '.recut_rounds' "$TEST_HOME/state/7011.json")"

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS"
