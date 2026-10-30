#!/usr/bin/env bash
# Regression tests for detect-label-churn.sh. Plain bash assertions, no
# framework -- matches run-advisor.test.sh's style: a fake `gh` shadowing
# the real binary on PATH, driven by env vars per scenario, and
# AGENT_DRY_RUN=1 so guarded_write's own dry-run branch (never a real `gh
# issue comment`) is what proves whether the script decided to flag an
# issue -- no gh write log needed for that half.
#
# This pins the INVARIANT (#1180's actual failure mode: an issue's watched
# pair of labels flips past a threshold within a window with nobody told),
# not the symptom (the exact sequence #1180 produced, or the exact label
# pair watched at the time -- #1180 itself was ready-for-agent/
# ready-for-human; WATCHED_B moved to needs-advisor on 2026-09-15 when the
# ladder redesign abolished ready-for-human as a destination, see
# detect-label-churn.sh's own WATCHED_B comment for the #1204/#1206 incident
# that caught the drift) -- see this file's scenarios below, each
# independent of any particular timeline shape.
#
# 2026-09-16: this file's own detect_one() is now a thin wrapper around
# loop_break_check() (lib.sh), the shared mechanism route_to_advisor() and
# admit_guarded() also call in-line -- so these scenarios now exercise
# loop_break_check() through detect-label-churn.sh's entry point rather than
# logic local to this file. The marker/message text changed
# (zenoforge-agent-churn-alert -> zf-loop-escalation) but the invariant these
# scenarios pin did not. Scenario 1 also asserts no maintainer email goes out
# any more for this class (removed in favor of loop_break_check()'s own
# issue-comment escalation plus a passive count folded into the daily
# digest, send_heartbeat()) -- see detect-label-churn.sh's own header for
# why no out-of-band channel is kept.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR_SRC="$SCRIPT_DIR/detect-label-churn.sh"

FAILED=0
TMP_DIRS=()
cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected [$expected], got [$actual])"
    FAILED=1
  fi
}

# --- fake gh, shadowing the real binary on PATH -----------------------------
# `issue list --label X` -> FAKE_ISSUES_A/FAKE_ISSUES_B (space-separated
# issue numbers). `api .../issues/N/timeline` -> FAKE_TIMELINE_<N> (one
# fake event line per selected label as if gh's --jq filter ran, formatted
# `created_at<TAB>label`. `api .../issues/N/comments` -> FAKE_COMMENTS_<N> (comment
# bodies, one per line -- the script only greps these for the marker).
FAKE_BIN="$(mktemp -d)"
TMP_DIRS+=("$FAKE_BIN")
REAL_GIT="$(command -v git)"
export REAL_GIT
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  label=""
  for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = "--label" ]; then j=$((i + 1)); label="${!j}"; fi
  done
  case "$label" in
    ready-for-agent) echo "${FAKE_ISSUES_A:-}" ;;
    needs-advisor) echo "${FAKE_ISSUES_B:-}" ;;
  esac
  exit 0
fi
if [ "$1" = "api" ]; then
  path="$2"
  n="$(echo "$path" | grep -oE '/issues/[0-9]+/' | grep -oE '[0-9]+')"
  if [[ "$path" == */sub_issues\?* ]]; then
    echo '[]'
    exit 0
  fi
  if [[ "$path" == *timeline && " $* " == *'"on-hold"'* ]]; then
    var="FAKE_HOLD_LIFT_$n"
    reopen="FAKE_REOPEN_$n"
    { printf '%s\n' "${!var:-}"; [[ " $* " == *'"concluded"'* ]] && printf '%s\n' "${!reopen:-}"; } | grep . || true
    exit 0
  fi
  if [[ "$path" == *timeline ]]; then
    var="FAKE_TIMELINE_$n"
    since=""
    for ((i = 1; i <= $#; i++)); do
      if [ "${!i}" = --jq ]; then
        j=$((i + 1))
        since="$(sed -nE 's/.*select\(\.created_at >= "([^"]+)".*/\1/p' <<< "${!j}")"
        break
      fi
    done
    if [ -n "$since" ]; then
      awk -F '\t' -v since="$since" '$1 >= since' <<< "${!var:-}"
    else
      printf '%s\n' "${!var:-}"
    fi
    exit 0
  fi
  if [[ "$path" == *comments ]]; then
    var="FAKE_COMMENTS_$n"
    printf '%s\n' "${!var:-}"
    exit 0
  fi
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  if [[ " $* " == *" --json state,comments "* ]]; then
    echo '{"state":"OPEN","labels":[{"name":"on-hold"}],"comments":[]}'
    exit 0
  fi
  if [[ " $* " == *" --json comments "* ]]; then
    echo '{"comments":[]}'
    exit 0
  fi
  case "${3:-}" in
    103) echo '{"state":"OPEN","labels":[{"name":"needs-advisor"}]}' ;;
    *) echo '{"state":"OPEN","labels":[{"name":"ready-for-agent"}]}' ;;
  esac
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  echo '[]'
  exit 0
fi
if [ "$1" = "issue" ] && { [ "$2" = "edit" ] || [ "$2" = "comment" ] || [ "$2" = "close" ]; }; then
  if [ -n "${FAKE_GH_WRITE_LOG:-}" ]; then
    printf 'gh' >> "$FAKE_GH_WRITE_LOG"
    printf ' %q' "$@" >> "$FAKE_GH_WRITE_LOG"
    printf '\n' >> "$FAKE_GH_WRITE_LOG"
  for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = --body-file ]; then
      body_index=$((i + 1))
      printf 'body-file contents:\n' >> "$FAKE_GH_WRITE_LOG"
      cat -- "${!body_index}" >> "$FAKE_GH_WRITE_LOG" || exit 1
      printf '\n' >> "$FAKE_GH_WRITE_LOG"
      break
    fi
  done
  fi
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/gh"
cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    fetch) exit 0 ;;
    ls-remote) exit 0 ;;
  esac
done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$FAKE_BIN/git"
mkdir -p "$FAKE_BIN/repo"
"$REAL_GIT" -C "$FAKE_BIN/repo" init -q -b main
"$REAL_GIT" -C "$FAKE_BIN/repo" config user.name Fixture
"$REAL_GIT" -C "$FAKE_BIN/repo" config user.email fixture@example.invalid
printf 'fixture\n' > "$FAKE_BIN/repo/fixture.txt"
"$REAL_GIT" -C "$FAKE_BIN/repo" add fixture.txt
"$REAL_GIT" -C "$FAKE_BIN/repo" commit -q -m fixture
"$REAL_GIT" -C "$FAKE_BIN/repo" update-ref refs/remotes/origin/main HEAD
export PATH="$FAKE_BIN:$PATH"
export REPO="test/repo"
export ZF_REPO_DIR="$FAKE_BIN/repo"
export AGENT_DRY_RUN=1
export FAKE_GH_WRITE_LOG="$FAKE_BIN/writes.log"
: > "$FAKE_GH_WRITE_LOG"
export ZF_AGENT_RECIPIENTS_FILE="/nonexistent/recipients.json"

run_once() {
  local agent_home
  agent_home="$(mktemp -d)"
  TMP_DIRS+=("$agent_home")
  LAST_AGENT_HOME="$agent_home"
  export AGENT_HOME="$agent_home"
  export ZF_WORKTREE_ROOT="$agent_home/wt"
  # Churn detection has no roadmap tree; roadmap admission has its own suite.
  jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$agent_home/model-policy.json"
  if [ -n "${FAKE_WRITER_RECEIPTS:-}" ]; then
    mkdir -p "$agent_home/state"
    printf '%s\n' "$FAKE_WRITER_RECEIPTS" > "$agent_home/state/ticket-transitions.jsonl"
  fi
  set +e
  RUN_OUTPUT="$(bash "$DETECTOR_SRC" 2>&1)"
  RUN_STATUS=$?
  set -e
}

# ago <minutes> -> a real ISO8601 UTC timestamp that many minutes in the
# past. Real timestamps, not placeholder strings: the script's own recency
# filter (added after a live run flagged ~24 settled issues alongside the
# one actually still looping -- see detect-label-churn.sh's RECENCY_MINUTES
# comment) does a lexicographic string comparison against these, so a
# fixture has to look like the real thing to exercise it at all.
ago() { date -u -d "-$1 minutes" +%Y-%m-%dT%H:%M:%SZ; }
alternating_timeline() {
  local label_a="$1" label_b="$2" label="$1" timestamp
  shift 2
  for timestamp in "$@"; do
    printf '%s\t%s\n' "$timestamp" "$label"
    if [[ "$label" == "$label_a" ]]; then label="$label_b"; else label="$label_a"; fi
  done
}

# --- scenario 1: two full ready/advisor round trips still freeze -----------
export FAKE_ISSUES_A="101"
export FAKE_ISSUES_B=""
export FAKE_TIMELINE_101="$(alternating_timeline ready-for-agent needs-advisor "$(ago 50)" "$(ago 40)" "$(ago 30)" "$(ago 20)" "$(ago 5)")"
export FAKE_COMMENTS_101=""
run_once
assert_contains "over-threshold, recent, never-alerted issue gets flagged" \
  "$RUN_OUTPUT" "#101 crossed"
assert_eq "dry-run churn detection performs no GitHub writes" '' "$(cat "$FAKE_GH_WRITE_LOG")"
assert_contains "flagging posts the loop-escalation marker (dry-run gh issue comment)" \
  "$RUN_OUTPUT" "zf-loop-escalation"
assert_not_contains "no maintainer email goes out for a churning ticket any more" \
  "$RUN_OUTPUT" "[dry-run] send_email"
unset FAKE_TIMELINE_101 FAKE_COMMENTS_101

# --- scenario 2: churn under threshold -> not flagged -----------------------
export FAKE_ISSUES_A="102"
export FAKE_ISSUES_B=""
export FAKE_TIMELINE_102="$(alternating_timeline ready-for-agent needs-advisor "$(ago 10)" "$(ago 5)")"
export FAKE_COMMENTS_102=""
run_once
assert_not_contains "under-threshold issue is not flagged" \
  "$RUN_OUTPUT" "#102 crossed"
unset FAKE_TIMELINE_102 FAKE_COMMENTS_102

# --- scenario 3: exact #3685 timeline is one advisor round trip, no hold ---
# 02:12 ready (triage), 02:41 ready re-added after an unlabeled event,
# 04:25 needs-advisor, 04:55 ready (advisor answer).
export FAKE_ISSUES_A="3685"
export FAKE_ISSUES_B=""
export FAKE_TIMELINE_3685="$(printf '%s\t%s\n' "$(ago 50)" ready-for-agent "$(ago 45)" ready-for-agent "$(ago 20)" needs-advisor "$(ago 5)" ready-for-agent)"
export FAKE_COMMENTS_3685=""
run_once
assert_not_contains "#3685's duplicate ready label and one advisor round trip do not freeze" \
  "$RUN_OUTPUT" "on-hold"
unset FAKE_TIMELINE_3685 FAKE_COMMENTS_3685

# --- scenario 4: legacy alert cannot leave a live loop unfrozen -------------
export FAKE_ISSUES_A=""
export FAKE_ISSUES_B="103"
export FAKE_TIMELINE_103="$(alternating_timeline ready-for-agent needs-advisor "$(ago 60)" "$(ago 50)" "$(ago 40)" "$(ago 30)" "$(ago 20)")"
export FAKE_COMMENTS_103="some earlier bot comment
<!-- zf-loop-escalation -->
already flagged this once"
run_once
assert_contains "legacy alert still freezes an actively churning issue" \
  "$RUN_OUTPUT" "--add-label on-hold"
assert_contains "legacy alert gets an episode-specific freeze comment" \
  "$RUN_OUTPUT" "zf-loop-episode="
unset FAKE_TIMELINE_103 FAKE_COMMENTS_103

# --- scenario 5: churn past threshold, but the burst has SETTLED -> no flag
# The exact failure mode a live run against the real repo produced the same
# night this was built: a batch of recut children each flipped several
# times during one hour of active development, then sat untouched for
# hours. Count alone cannot tell that apart from #1180, which kept flipping
# for three more hours after its own burst -- this is the case the recency
# filter exists for.
export FAKE_ISSUES_A="104"
export FAKE_ISSUES_B=""
export FAKE_TIMELINE_104="$(alternating_timeline ready-for-agent needs-advisor "$(ago 300)" "$(ago 290)" "$(ago 280)" "$(ago 270)" "$(ago 260)")"
export FAKE_COMMENTS_104=""
run_once
assert_not_contains "over-threshold but settled (all flips outside the recency window) is not flagged" \
  "$RUN_OUTPUT" "#104 crossed"
unset FAKE_TIMELINE_104 FAKE_COMMENTS_104

# --- scenario 6: escalation freezes issue and records one inbox line -------
export AGENT_DRY_RUN=0
export FAKE_GH_WRITE_LOG="$FAKE_BIN/writes.log"
: > "$FAKE_GH_WRITE_LOG"
export FAKE_ISSUES_A="105"
export FAKE_ISSUES_B=""
export FAKE_TIMELINE_105="$(alternating_timeline ready-for-agent needs-advisor "$(ago 50)" "$(ago 40)" "$(ago 30)" "$(ago 20)" "$(ago 5)")"
export FAKE_COMMENTS_105=""
writer_receipt() {
  jq -cn --arg ts "$1" --arg from "$2" --arg to "$3" --arg writer "$4" \
    '{ts:$ts,issue:105,from_stage:$from,to_stage:$to,writer:$writer,kind:"flip",progress:false}'
}
export FAKE_WRITER_RECEIPTS="$(writer_receipt "$(ago 50)" ready-for-agent needs-advisor run-implement.sh)
$(writer_receipt "$(ago 40)" needs-advisor ready-for-agent run-advisor.sh)
$(writer_receipt "$(ago 30)" ready-for-agent needs-advisor run-implement.sh)
$(writer_receipt "$(ago 20)" needs-advisor ready-for-agent run-advisor.sh)
$(writer_receipt "$(ago 5)" ready-for-agent needs-advisor run-implement.sh)"
run_once
assert_contains "churn escalation removes both flipping labels and adds on-hold" \
  "$(cat "$FAKE_GH_WRITE_LOG")" "--remove-label ready-for-agent"
assert_contains "churn escalation removes needs-advisor" \
  "$(cat "$FAKE_GH_WRITE_LOG")" "--remove-label needs-advisor"
assert_contains "churn escalation freezes issue in on-hold" \
  "$(cat "$FAKE_GH_WRITE_LOG")" "--add-label on-hold"
assert_contains "churn escalation posts issue comment" \
  "$(cat "$FAKE_GH_WRITE_LOG")" "gh issue comment 105"
assert_contains "churn issue comment names writers from observed transition receipts" \
  "$(cat "$FAKE_GH_WRITE_LOG")" 'writers=run-advisor.sh,run-implement.sh'
assert_eq "churn escalation writes one supervisor line per episode" '1' \
  "$(grep -cF 'label-churn issue=#105' "$LAST_AGENT_HOME/supervisor-inbox" 2>/dev/null || true)"
assert_contains "supervisor line names writers from observed transition receipts" \
  "$(cat "$LAST_AGENT_HOME/supervisor-inbox")" 'writers=run-advisor.sh,run-implement.sh'
assert_eq "active churn returns to the scheduler" ready-for-agent \
  "$(jq -r '.state' "$LAST_AGENT_HOME/state/105.json")"
assert_eq "active churn records one scheduler handoff comment" '1' \
  "$(grep -F -c 'zf-scheduler-handoff issue=105' "$FAKE_GH_WRITE_LOG" || true)"
WRITE_COUNT_BEFORE="$(wc -l < "$FAKE_GH_WRITE_LOG" | tr -d '[:space:]')"
AGENT_HOME="$LAST_AGENT_HOME" bash "$DETECTOR_SRC" >/dev/null 2>&1
assert_eq "same churn episode does not repeat writes" "$WRITE_COUNT_BEFORE" \
  "$(wc -l < "$FAKE_GH_WRITE_LOG" | tr -d '[:space:]')"
assert_eq "same churn episode keeps one supervisor line" '1' \
  "$(grep -cF 'label-churn issue=#105' "$LAST_AGENT_HOME/supervisor-inbox" 2>/dev/null || true)"

# --- scenario 7: overlapping inline/timer checks share one episode lock ----
LAST_AGENT_HOME="$(mktemp -d)"
TMP_DIRS+=("$LAST_AGENT_HOME")
export AGENT_HOME="$LAST_AGENT_HOME"
export ZF_WORKTREE_ROOT="$AGENT_HOME/wt"
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"
: > "$FAKE_GH_WRITE_LOG"
export FAKE_ISSUES_A="106"
export FAKE_ISSUES_B=""
export FAKE_TIMELINE_106="$(alternating_timeline ready-for-agent needs-advisor "$(ago 50)" "$(ago 40)" "$(ago 30)" "$(ago 20)" "$(ago 5)")"
export FAKE_COMMENTS_106=""
bash "$DETECTOR_SRC" >/dev/null 2>&1 &
CHURN_PID_A=$!
bash "$DETECTOR_SRC" >/dev/null 2>&1 &
CHURN_PID_B=$!
wait "$CHURN_PID_A" || FAILED=1
wait "$CHURN_PID_B" || FAILED=1
assert_eq "overlapping churn checks post one episode comment" '1' \
  "$(grep -cF 'zf-loop-episode=' "$FAKE_GH_WRITE_LOG" || true)"
assert_eq "overlapping churn checks apply one on-hold edit" '1' \
  "$(grep -F -c -- '--add-label on-hold' "$FAKE_GH_WRITE_LOG" || true)"
assert_eq "overlapping churn checks write one supervisor line" '1' \
  "$(grep -cF 'label-churn issue=#106' "$LAST_AGENT_HOME/supervisor-inbox" 2>/dev/null || true)"

# --- scenario 8: a supervisor lifted on-hold after the loop was fixed -------
# Issue 1943 was re-frozen 27 minutes after the lift because the 6h window
# still held the transitions from before it; only transitions after the lift
# belong to a new episode.
export FAKE_ISSUES_A="107"
export FAKE_ISSUES_B=""
export FAKE_TIMELINE_107="$(alternating_timeline ready-for-agent needs-advisor "$(ago 50)" "$(ago 40)" "$(ago 30)" "$(ago 20)" "$(ago 5)")"
export FAKE_HOLD_LIFT_107="$(ago 10)"
export FAKE_COMMENTS_107=""
run_once
assert_not_contains "transitions before an on-hold lift do not re-freeze the ticket" \
  "$RUN_OUTPUT" "#107 crossed"
export FAKE_HOLD_LIFT_107="$(ago 55)"
run_once
assert_contains "a loop that resumes after the lift is still frozen" \
  "$RUN_OUTPUT" "#107 crossed"
unset FAKE_TIMELINE_107 FAKE_HOLD_LIFT_107 FAKE_COMMENTS_107

# --- scenario 9: a concluded ticket was reopened ----------------------------
# Issue 3050 was frozen after one ready -> advisor -> ready round trip because
# the window still held the ready-for-agent label from its previous lifecycle.
export FAKE_ISSUES_A="108"
export FAKE_ISSUES_B=""
export FAKE_TIMELINE_108="$(alternating_timeline ready-for-agent needs-advisor "$(ago 70)" "$(ago 60)" "$(ago 50)" "$(ago 45)" "$(ago 30)" "$(ago 20)" "$(ago 5)")"
export FAKE_REOPEN_108="$(ago 40)"
export FAKE_COMMENTS_108=""
run_once
assert_not_contains "transitions before a reopen do not freeze the new lifecycle" \
  "$RUN_OUTPUT" "#108 crossed"
unset FAKE_TIMELINE_108 FAKE_REOPEN_108 FAKE_COMMENTS_108

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
