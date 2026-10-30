#!/usr/bin/env bash
# Regression test for sweep-acceptor-backlog.sh: on-hold and already-closed
# issues are left untouched; a manifest entry with no real merged PR is
# refused rather than guessed closed (the #1221 lesson its own header
# names); a genuinely merged entry gets acceptor recorded, is commented and
# closed, and is stamped closed_by_pipeline so a later reopen is swept by
# sweep_reopened_issues() (lib.sh). Same style as sweep-parked-backlog.test.sh:
# fake gh on PATH, run the real script as a subprocess under
# AGENT_DRY_RUN=1, read guarded_write's dry-run print lines.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP_SRC="$SCRIPT_DIR/sweep-acceptor-backlog.sh"

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

# --- fake gh: issue view (--json state for the closed check), issue list
# (the batched on-hold label snapshot), pr list (the real merged-PR
# confirmation), label list (pre-seeded so ensure_state_labels() has
# nothing to create), everything else (comment/close) logged. ----------
FAKE_BIN="$(mktemp -d)"
TMP_DIRS+=("$FAKE_BIN")
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
sub="$1 ${2:-}"
args=("$@")
last="${args[-1]}"
case "$sub" in
  "issue view")
    n="${args[2]:-}"
    state="OPEN"
    [[ " ${FAKE_CLOSED_ISSUES:-} " == *" $n "* ]] && state="CLOSED"
    labels="$(echo "${FAKE_ISSUE_LABELS_JSON:-{}}" | jq -c --arg n "$n" '(.[$n] // []) | map({name: .})')"
    jq -n --arg s "$state" --argjson l "$labels" '{state: $s, labels: $l}' | jq -r "$last"
    ;;
  "issue list")
    label=""
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [ "${args[$i]}" = "--label" ]; then
        label="${args[$((i + 1))]:-}"
        break
      fi
    done
    [ -n "$label" ] || exit 0
    echo "${FAKE_ISSUE_LABELS_JSON:-{}}" \
      | jq -r --arg want_label "$label" 'to_entries[] | select(.value | index($want_label) != null) | .key'
    ;;
  "pr list")
    n=""
    for a in "${args[@]}"; do
      case "$a" in
        *head:agent/issue-*) n="${a#*head:agent/issue-}" ;;
      esac
    done
    if [[ " ${FAKE_MERGED_ISSUES:-} " == *" $n "* ]]; then
      echo "$((n + 1000))"
    fi
    ;;
  "label list")
    echo '[{"name":"needs-triage"},{"name":"needs-info"},{"name":"ready-for-agent"},{"name":"ready-for-human"},{"name":"needs-owner"},{"name":"duplicate"},{"name":"finish-first"},{"name":"wontfix"},{"name":"needs-advisor"},{"name":"needs-recut"},{"name":"concluded"}]' ;;
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

FAKE_GH_LOG="$AGENT_HOME/gh.log"
: > "$FAKE_GH_LOG"

# Real manifest entries: 1226/1227 -> none, 1235/1214/1180/1178/1175/1172/1179
# -> maintainer (see the script's own header for why). Exercise:
#   1227: genuinely merged -> must close.
#   1226: on-hold -> must stay untouched.
#   1235: already closed on GitHub -> idempotent no-op, not re-processed.
#   1214: NOT actually merged (no PR found) -> must NOT close, logged.
export AGENT_HOME ZF_REPO="test/repo" AGENT_DRY_RUN=1 \
  FAKE_ISSUE_LABELS_JSON='{"1226":["on-hold"]}' \
  FAKE_CLOSED_ISSUES=" 1235 " \
  FAKE_MERGED_ISSUES=" 1227 1235 1180 1178 1175 1172 1179 " \
  FAKE_GH_LOG PATH

RUN_OUTPUT="$(bash "$SWEEP_SRC" 2>&1)"
RUN_STATUS=$?

assert_eq "sweep exits 0" "0" "$RUN_STATUS"

assert_contains "#1227 (none, genuinely merged) gets closed" \
  "$RUN_OUTPUT" "gh issue close 1227 --repo test/repo"
assert_contains "...the comment names the real merged PR number" \
  "$RUN_OUTPUT" "#2227"
assert_contains "...acceptor is recorded in state" \
  "$RUN_OUTPUT" "acceptor"

assert_not_contains "#1226 (on-hold) is never touched" \
  "$RUN_OUTPUT" "issue close 1226"
assert_contains "...and is logged as on-hold" \
  "$RUN_OUTPUT" "sweep-acceptor-backlog: #1226 -- on-hold"

assert_not_contains "#1235 (already closed on GitHub) is not re-closed" \
  "$RUN_OUTPUT" "issue close 1235"
assert_contains "...and is logged as an idempotent no-op" \
  "$RUN_OUTPUT" "sweep-acceptor-backlog: #1235 -- already closed"

assert_not_contains "#1214 (manifest says maintainer, but no real merged PR found) is NOT closed" \
  "$RUN_OUTPUT" "issue close 1214"
assert_contains "...refuses to guess a merge that may not exist" \
  "$RUN_OUTPUT" "no merged agent/issue-1214 PR found; NOT closing"

assert_contains "final summary line reports all four counts" \
  "$RUN_OUTPUT" "closed=6 skipped(not merged)=1 skipped(already closed)=1 skipped(on-hold)=1"

assert_eq "under AGENT_DRY_RUN=1, no gh mutation of any kind actually ran (fake gh's catch-all log stays empty -- guarded_write only ever prints)" \
  "" "$(cat "$FAKE_GH_LOG")"

# Live-path fixture: a historical acceptor close must clear an advisor job
# marker before the close, not depend on the dry-run branch or a later sweep.
jq -n '{web_advisor_provider_job_id:"acceptor-job",web_advisor_provider_job_started_at:1,web_advisor_provider_job_episode_seq:2}' \
  > "$AGENT_HOME/state/1227.json"
: > "$FAKE_GH_LOG"
export AGENT_DRY_RUN=0
LIVE_OUTPUT="$(bash "$SWEEP_SRC" 2>&1)"
assert_contains "live acceptor close still runs" "$(cat "$FAKE_GH_LOG")" "gh issue close 1227 --repo test/repo"
assert_eq "live acceptor close clears web-advisor-provider job id" "null" \
  "$(jq -r '.web_advisor_provider_job_id // null' "$AGENT_HOME/state/1227.json")"

if [ "$FAILED" -eq 1 ]; then
  echo "FAILED"
  echo "--- run output ---"
  echo "$RUN_OUTPUT"
  exit 1
fi
echo "ALL PASS"
