#!/usr/bin/env bash
# Regression test for sweep-parked-backlog.sh: the criterion split (state
# file + attempts>=1 climbs; no file or attempts=0 stays; on-hold is never
# touched regardless) and that it never depends on conclude_run (concluded
# has never fired in production as of this writing -- see the script's own
# header comment). Plain bash assertions, no framework -- matches this
# repo's other engine/*.test.sh style: fake gh on PATH, run the real
# script as a subprocess under AGENT_DRY_RUN=1 so the assertions read the
# guarded_write dry-run print lines rather than needing every gh call
# faked for real writes.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP_SRC="$SCRIPT_DIR/sweep-parked-backlog.sh"

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

# --- fake gh: issue list (including the bulk on-hold snapshot), issue view
# fallback, label list (pre-seeded so ensure_state_labels() has nothing to
# create), everything else logged. --------------------------------------
FAKE_BIN="$(mktemp -d)"
TMP_DIRS+=("$FAKE_BIN")
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
sub="$1 ${2:-}"
q_expr=""
label=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  if [ "${args[$i]}" = "-q" ]; then
    q_expr="${args[$((i + 1))]:-}"
  fi
  if [ "${args[$i]}" = "--label" ]; then
    label="${args[$((i + 1))]:-}"
  fi
  i=$((i + 1))
done
case "$sub" in
  "issue list")
    if [ "$label" = "on-hold" ]; then
      echo "${FAKE_ISSUE_LABELS_JSON:-{}}" | jq -r 'to_entries[] | select(any(.value[]; . == "on-hold")) | .key'
    else
      echo "${FAKE_ISSUE_LIST_JSON:-[]}" | jq -r "${q_expr:-.}"
    fi
    ;;
  "issue view")
    n="${args[2]:-}"
    state=OPEN
    if [ "${FAKE_CLOSED_ROUTE_ISSUE:-}" = "$n" ]; then state=CLOSED; fi
    echo "${FAKE_ISSUE_LABELS_JSON:-{}}" | jq -r --arg n "$n" --arg state "$state" '{state:$state,labels: ((.[$n] // []) | map({name: .}))}' | jq -r "${q_expr:-.}" ;;
  "label list")
    echo '[{"name":"needs-triage"},{"name":"needs-info"},{"name":"ready-for-agent"},{"name":"ready-for-human"},{"name":"needs-owner"},{"name":"duplicate"},{"name":"finish-first"},{"name":"wontfix"},{"name":"needs-advisor"},{"name":"needs-recut"},{"name":"concluded"}]' ;;
  "api "*)
    # loop_break_check() (lib.sh, called by route_to_advisor()) reads
    # repos/.../issues/N/timeline and .../comments -- a READ, not a
    # mutation (same convention as gh issue view above: never through
    # guarded_write, so it runs even under AGENT_DRY_RUN=1). No events
    # fixture is seeded here (no ticket in this test is actually churning),
    # so returning empty makes loop_break_check() a no-op without touching
    # the mutation-only catch-all log below.
    : ;;
  *)
    echo "gh $*" >> "${FAKE_GH_LOG:-/dev/null}" ;;
esac
exit 0
EOF
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"

AGENT_HOME="$(mktemp -d)"
TMP_DIRS+=("$AGENT_HOME")
mkdir -p "$AGENT_HOME/state"
# Stage-routing fixture; roadmap admission is covered by roadmap-order.test.sh.
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"

# #101: dispatched twice, in flight -- must climb.
echo '{"attempts":2}' > "$AGENT_HOME/state/101.json"
# #102: no state file at all -- never entered, must stay.
# (deliberately nothing written for #102)
# #103: state file exists but attempts:0 -- never dispatched, must stay.
echo '{"attempts":0}' > "$AGENT_HOME/state/103.json"
# #104: dispatched once, but on-hold -- must stay regardless of attempts.
echo '{"attempts":1}' > "$AGENT_HOME/state/104.json"

FAKE_GH_LOG="$AGENT_HOME/gh.log"
: > "$FAKE_GH_LOG"

export AGENT_HOME ZF_REPO="test/repo" AGENT_DRY_RUN=1 \
  FAKE_ISSUE_LIST_JSON='[{"number":101},{"number":102},{"number":103},{"number":104}]' \
  FAKE_ISSUE_LABELS_JSON='{"104":["on-hold"]}' \
  FAKE_GH_LOG PATH

RUN_OUTPUT="$(bash "$SWEEP_SRC" 2>&1)"
RUN_STATUS=$?

assert_eq "sweep exits 0" "0" "$RUN_STATUS"

ADVISOR_WRITE="$(grep -F 'gh issue edit 101 ' <<< "$RUN_OUTPUT" || true)"
assert_contains "#101 (attempts=2, in flight) routes to needs-advisor" \
  "$ADVISOR_WRITE" "--remove-label ready-for-human"
assert_contains "#101 route adds needs-advisor" \
  "$ADVISOR_WRITE" "--add-label needs-advisor"
assert_contains "...the comment explains why (references the ladder ruling)" \
  "$RUN_OUTPUT" "进了 pipeline 就要走到结果"

assert_not_contains "#102 (no state file) is never relabeled" \
  "$RUN_OUTPUT" "gh issue edit 102"
assert_contains "...and is logged as never having entered the pipeline" \
  "$RUN_OUTPUT" "sweep: #102 -- no state file"

assert_not_contains "#103 (attempts=0) is never relabeled" \
  "$RUN_OUTPUT" "gh issue edit 103"
assert_contains "...and is logged as never dispatched" \
  "$RUN_OUTPUT" "sweep: #103 -- state file exists but attempts=0"

assert_not_contains "#104 (on-hold, even though attempts=1) is never relabeled" \
  "$RUN_OUTPUT" "gh issue edit 104"
assert_contains "...and is logged as on-hold" \
  "$RUN_OUTPUT" "sweep: #104 -- on-hold"

assert_contains "final summary line reports all four counts" \
  "$RUN_OUTPUT" "routed=1, left(on-hold)=1, left(no state file)=1, left(attempts=0)=1"

assert_eq "under AGENT_DRY_RUN=1, no gh mutation of any kind actually ran (fake gh's catch-all log stays empty -- guarded_write only ever prints)" \
  "" "$(cat "$FAKE_GH_LOG")"

assert_eq "never calls conclude_run (as opposed to mentioning it in a comment) -- concluded has never fired in production, this sweep must not depend on it" \
  "0" "$(grep -cE 'conclude_run "' "$SWEEP_SRC" || true)"

# Search can select an issue that closed after the list snapshot. Shared route
# guard must prevent both relabel and its caller's follow-up comment.
: > "$FAKE_GH_LOG"
CLOSED_ROUTE_OUTPUT="$(FAKE_CLOSED_ROUTE_ISSUE=101 AGENT_DRY_RUN=0 bash "$SWEEP_SRC" 2>&1)"
assert_contains "parked sweep logs closed issue skip" "$CLOSED_ROUTE_OUTPUT" "issue is closed"
assert_not_contains "parked sweep does not relabel closed issue" "$(cat "$FAKE_GH_LOG")" "issue edit 101"
assert_not_contains "parked sweep does not comment on stale route" "$(cat "$FAKE_GH_LOG")" "issue comment 101"
assert_contains "parked sweep leaves closed issue out of routed count" "$CLOSED_ROUTE_OUTPUT" "routed=0"

if [ "$FAILED" -eq 1 ]; then
  echo "FAILED"
  echo "--- run output ---"
  echo "$RUN_OUTPUT"
  exit 1
fi
echo "ALL PASS"
