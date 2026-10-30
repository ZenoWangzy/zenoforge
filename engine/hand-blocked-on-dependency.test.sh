#!/usr/bin/env bash
# A hand agent tied to issue N (run-recut.sh's guarded flow queues them as
# hand-<N>) that ends `STATUS: BLOCKED-ON issue M` must leave a native
# dependency on N and a requeued ticket: worktree-lifecycle.sh watch runs at
# agent exit, before the roster row is dropped, and lib.sh's
# hand_report_blocked_on_dependency resolves the report header. This suite
# runs the real watch path against a fake gh, the same fixture shape
# worktree-lifecycle.test.sh uses.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LIFECYCLE="$SCRIPT_DIR/worktree-lifecycle.sh"
ROOT="$(mktemp -d)"
REPO_PATH="$ROOT/repo"
REMOTE="$ROOT/origin.git"
NIGHT="$ROOT/night"
BIN="$ROOT/bin"
AGENT_HOME_DIR="$ROOT/home/.zenoforge"
STATE_DIR="$AGENT_HOME_DIR/state"
cleanup() { rm -rf -- "$ROOT"; }
trap cleanup EXIT
mkdir -p "$NIGHT" "$BIN" "$STATE_DIR" "$AGENT_HOME_DIR/logs" "$ROOT/wt-root" "$ROOT/node-owners"
# Stage-routing fixture; roadmap admission is covered by roadmap-order.test.sh.
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME_DIR/model-policy.json"
git init -q --bare "$REMOTE"
git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
git init -q -b main "$REPO_PATH"
git -C "$REPO_PATH" config user.name fixture
git -C "$REPO_PATH" config user.email fixture@example.invalid
git -C "$REPO_PATH" commit --allow-empty -qm base
git -C "$REPO_PATH" remote add origin "$REMOTE"
git -C "$REPO_PATH" push -qu origin main
git -C "$REPO_PATH" fetch -q origin

GH_LOG="$ROOT/gh.log"
DEP_LOG="$ROOT/dependency-writes.log"
COMMENT_LOG="$ROOT/comments.log"
EDIT_LOG="$ROOT/edits.log"
INBOX="$AGENT_HOME_DIR/supervisor-inbox"
RESUME_LOG="$ROOT/resumes.log"

# Fake gh: answers exactly the calls hand_report_blocked_on_dependency and
# state_requeue make -- blocker view, native dependency endpoints, one
# comment, the requeue label edit, and label list -- recording each write.
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
set -u
printf 'gh %s\n' "\$*" >> "$GH_LOG"
case "\${1:-} \${2:-}" in
  "issue view")
    if [ "\${FAKE_BLOCKER_VIEW_FAIL:-0}" = "1" ]; then exit 1; fi
    state="\${FAKE_DEPENDENCY_STATE:-\${FAKE_BLOCKER_STATE:-OPEN}}"
    if [[ " \$* " == *" --jq .state "* ]]; then printf '%s\n' "\$state"
    else printf '{"state":"%s","stateReason":null,"closedAt":null}\n' "\$state"; fi
    exit 0 ;;
  "pr view")
    state="\${FAKE_PR_STATE:-OPEN}"
    if [[ " \$* " == *" --jq .state "* ]]; then printf '%s\n' "\$state"
    else printf '{"number":%s,"state":"%s","closingIssuesReferences":%s}\n' \
      "\${FAKE_PR_NUMBER:-9001999}" "\$state" "\${FAKE_PR_CLOSES_JSON:-[]}"; fi
    exit 0 ;;
  "issue comment")
    printf '%s\n' "\${3:-}" >> "$COMMENT_LOG"
    exit 0 ;;
  "issue edit")
    printf '%s\n' "\$*" >> "$EDIT_LOG"
    exit 0 ;;
  "label list")
    printf '%s\n' needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded
    exit 0 ;;
esac
if [ "\${1:-}" = api ]; then
  endpoint=""
  for arg in "\$@"; do
    case "\$arg" in repos/test/repo/issues/*) endpoint="\$arg" ;; esac
  done
  case "\$endpoint" in
    */dependencies/blocked_by)
      if [[ " \$* " == *" --method POST "* ]]; then
        for arg in "\$@"; do
          case "\$arg" in issue_id=*) printf '%s\n' "\${arg#issue_id=}" >> "$DEP_LOG" ;; esac
        done
        printf '{}\n'
      else
        printf '[]\n'
      fi ;;
    repos/test/repo/issues/[0-9]*)
      number="\${endpoint##*/}"
      [[ "\$number" =~ ^[0-9]+$ ]] || { printf '[]\n'; exit 0; }
      id=\$((82000000 + number))
      state="\${FAKE_DEPENDENCY_STATE:-OPEN}"
      if [ "\$number" = "\${FAKE_PR_NUMBER:-}" ]; then
        printf '{"id":%s,"number":%s,"state":"%s","pull_request":{}}\n' "\$id" "\$number" "\${FAKE_PR_STATE:-OPEN}"
      else
        printf '{"id":%s,"number":%s,"state":"%s"}\n' "\$id" "\$number" "\$state"
      fi ;;
    *)
      printf '[]\n' ;;
  esac
  exit 0
fi
exit 0
EOF
# No systemd user manager in the fixture: report zero active units, as
# worktree-lifecycle.test.sh does, so the real lifecycle can verify ownership.
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$BIN/ps" <<'EOF'
#!/usr/bin/env bash
exec /bin/ps "$@"
EOF
chmod +x "$BIN/gh" "$BIN/systemctl" "$BIN/ps"
export PATH="$BIN:$PATH"

mkdir -p "$REPO_PATH/engine/night"
cat > "$REPO_PATH/engine/issue-pipeline.sh" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == '--stage ready-refill' ]]
EOF
cat > "$REPO_PATH/engine/night/dispatch.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RESUME_LOG"
EOF
chmod +x "$REPO_PATH/engine/night/dispatch.sh"

run_lifecycle() {
  AGENT_HOME="$AGENT_HOME_DIR" \
  ZF_NIGHT_DIR="$NIGHT" \
  ZF_WORKTREE_ROOT="$ROOT/wt-root" \
  ZF_PRIMARY_REPO_DIR="$REPO_PATH" \
  ZF_ENGINE_DIR="$REPO_PATH/engine" \
  ZF_GH_REPO=test/repo \
  PATH="$BIN:$PATH" \
    bash "$LIFECYCLE" "$@"
}

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

HAND_WT="$ROOT/wt-hand-9001914"
HAND_REPORT="$NIGHT/hand-9001914-report.md"
HAND_RUN=0
HAND_PID=999999999
HAND_TICKS=0

# reset_fixture <state-json> -- fresh worktree, roster row, and report for
# hand-9001914 (issue 9001914), with the report written after the roster's
# started timestamp so resume decision sees a current report.
reset_fixture() {
  local state_json="$1" started_ns
  HAND_RUN=$((HAND_RUN + 1))
  HAND_PID=$((999999999 - HAND_RUN))
  HAND_TICKS="$HAND_RUN"
  git -C "$REPO_PATH" worktree remove --force "$HAND_WT" >/dev/null 2>&1 || true
  git -C "$REPO_PATH" branch -D hand-9001914 >/dev/null 2>&1 || true
  rm -f "$NIGHT/agents.txt" "$INBOX" "$AGENT_HOME_DIR/supervisor-inbox.once" \
    "$GH_LOG" "$DEP_LOG" "$COMMENT_LOG" "$EDIT_LOG" "$HAND_REPORT"
  rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
  # supervisor_inbox_append collapses a repeat by kind+targets+state in the
  # daily seen ledger; scenarios share an issue number, so start each with a
  # fresh alert ledger.
  rm -rf "$AGENT_HOME_DIR/logs"; mkdir -p "$AGENT_HOME_DIR/logs"
  printf '%s\n' "$state_json" > "$STATE_DIR/9001914.json"
  git -C "$REPO_PATH" worktree add -q "$HAND_WT" -b hand-9001914 main
  started_ns="$(date +%s%N)"
  sleep 0.01
  printf '%s\n' "$REPORT_BODY" > "$HAND_REPORT"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$HAND_PID" hand-9001914 gpt-6-luna max "$HAND_WT" "$ROOT/hand-brief.md" "$HAND_REPORT" "$ROOT/hand.log" \
    0 "$started_ns" work "$HAND_TICKS" 9001914 '' > "$NIGHT/agents.txt"
}

assert_no_supervisor_line() {
  [ ! -e "$INBOX" ] || [ ! -s "$INBOX" ] || fail "$1: unexpected supervisor inbox line: $(cat "$INBOX")"
}

ON_HOLD_STATE='{"attempts":1,"state":"on-hold","hold":{"kind":"guarded-recut-repeat","holder":"supervisor"},"guarded":true}'

# --- open blocker: one POST, one comment, requeue to ready-for-agent --------
REPORT_BODY='STATUS: BLOCKED-ON issue 9001131
canonical Run terminal-event source (issue 9001131) is not on origin/main yet
work stopped before any diff'
reset_fixture "$ON_HOLD_STATE"
  watch_output="$(FAKE_BLOCKER_STATE=OPEN run_lifecycle watch "$REPO_PATH" "$HAND_WT" "$HAND_PID" "$HAND_TICKS" 2>&1)"
[ -d "$HAND_WT" ] || fail "open blocker: watch removed BLOCKED-ON hand worktree: $watch_output"
[ "$(grep -c -- '--method POST repos/test/repo/issues/9001914/dependencies/blocked_by' "$GH_LOG")" -eq 1 ] \
  || fail "open blocker: expected exactly one dependency POST: $(cat "$GH_LOG")"
[ "$(wc -l < "$DEP_LOG")" -eq 1 ] || fail "open blocker: dependency write count: $(cat "$DEP_LOG" 2>/dev/null)"
grep -Fxq 91001131 "$DEP_LOG" || fail "open blocker: POST carried the blocker database id"
[ "$(wc -l < "$COMMENT_LOG")" -eq 1 ] || fail "open blocker: expected exactly one comment, got $(wc -l < "$COMMENT_LOG")"
grep -Fxq 9001914 "$COMMENT_LOG" || fail "open blocker: comment posted on the tied issue"
[ -s "$STATE_DIR/9001914.json" ] || fail "open blocker: state file missing"
jq -e '.state == "ready-for-agent" and .hold == null and .hand_blocked_on.blocker == 9001131' \
  "$STATE_DIR/9001914.json" >/dev/null || fail "open blocker: state not requeued: $(cat "$STATE_DIR/9001914.json"); watch=$watch_output; gh=$(cat "$GH_LOG")"
grep -q -- '--add-label ready-for-agent' "$EDIT_LOG" || fail "open blocker: requeue label edit missing"
assert_no_supervisor_line "open blocker"
echo 'ok - open blocker leaves native dependency, one comment, ready-for-agent requeue'

# --- closed blocker: no requeue, one supervisor inbox line ------------------
reset_fixture "$ON_HOLD_STATE"
  watch_output="$(FAKE_BLOCKER_STATE=CLOSED run_lifecycle watch "$REPO_PATH" "$HAND_WT" "$HAND_PID" "$HAND_TICKS" 2>&1)"
[ -d "$HAND_WT" ] || fail "closed blocker: watch removed BLOCKED-ON hand worktree: $watch_output"
[ ! -e "$DEP_LOG" ] || [ ! -s "$DEP_LOG" ] || fail "closed blocker: dependency was written: $(cat "$DEP_LOG")"
[ ! -e "$COMMENT_LOG" ] || [ ! -s "$COMMENT_LOG" ] || fail "closed blocker: comment was posted"
[ ! -e "$EDIT_LOG" ] || [ ! -s "$EDIT_LOG" ] || fail "closed blocker: issue was requeued: $(cat "$EDIT_LOG")"
jq -e '.state == "on-hold" and (.hand_blocked_on // null) == null' \
  "$STATE_DIR/9001914.json" >/dev/null || fail "closed blocker: issue state changed: $(cat "$STATE_DIR/9001914.json")"
[ -s "$INBOX" ] || fail "closed blocker: no supervisor inbox line"
[ "$(wc -l < "$INBOX")" -eq 1 ] || fail "closed blocker: expected one inbox line, got $(wc -l < "$INBOX")"
grep -q 9001131 "$INBOX" || fail "closed blocker: inbox line does not name the blocker: $(cat "$INBOX")"
echo 'ok - closed blocker stays on hold with one supervisor inbox line'

# --- unreadable blocker: same terminal rule ----------------------------------
reset_fixture "$ON_HOLD_STATE"
  watch_output="$(FAKE_BLOCKER_VIEW_FAIL=1 run_lifecycle watch "$REPO_PATH" "$HAND_WT" "$HAND_PID" "$HAND_TICKS" 2>&1)"
[ ! -e "$DEP_LOG" ] || [ ! -s "$DEP_LOG" ] || fail "unreadable blocker: dependency was written"
[ ! -e "$EDIT_LOG" ] || [ ! -s "$EDIT_LOG" ] || fail "unreadable blocker: issue was requeued"
jq -e '.state == "on-hold"' "$STATE_DIR/9001914.json" >/dev/null || fail "unreadable blocker: issue state changed"
[ "$(wc -l < "$INBOX")" -eq 1 ] || fail "unreadable blocker: expected one inbox line, got $(wc -l < "$INBOX" 2>/dev/null || echo 0)"
echo 'ok - unreadable blocker routes to supervisor without requeue'

# --- #<M> form is accepted ----------------------------------------------------
REPORT_BODY='STATUS: BLOCKED-ON #9001131
blocker via hash form'
reset_fixture "$ON_HOLD_STATE"
  watch_output="$(FAKE_BLOCKER_STATE=OPEN run_lifecycle watch "$REPO_PATH" "$HAND_WT" "$HAND_PID" "$HAND_TICKS" 2>&1)"
[ "$(grep -c -- '--method POST repos/test/repo/issues/9001914/dependencies/blocked_by' "$GH_LOG")" -eq 1 ] \
  || fail "hash form: expected exactly one dependency POST: $(cat "$GH_LOG")"
jq -e '.state == "ready-for-agent" and .hand_blocked_on.blocker == 9001131' \
  "$STATE_DIR/9001914.json" >/dev/null || fail "hash form: state not requeued"
echo 'ok - BLOCKED-ON #<M> form resolves the same dependency'

# --- already recorded for this blocker: no duplicate writes ------------------
reset_fixture '{"attempts":1,"state":"on-hold","hold":{"kind":"guarded-recut-repeat","holder":"supervisor"},"guarded":true,"hand_blocked_on":{"blocker":9001131,"agent":"hand-9001914","recorded_at":"2026-10-07T00:00:00Z"}}'
  watch_output="$(FAKE_BLOCKER_STATE=OPEN run_lifecycle watch "$REPO_PATH" "$HAND_WT" "$HAND_PID" "$HAND_TICKS" 2>&1)"
[ ! -s "$GH_LOG" ] || fail "already recorded: handler still called gh: $(cat "$GH_LOG")"
jq -e '.state == "on-hold"' "$STATE_DIR/9001914.json" >/dev/null || fail "already recorded: state changed"
[ ! -s "$INBOX" ] || fail "already recorded: unexpected inbox line"
echo 'ok - repeat exit for the same blocker writes nothing'

# FOLLOWUP cases exercise the same live watcher and scheduler resume path.
reset_followup() {
  REPORT_BODY="$1"
  reset_fixture "$ON_HOLD_STATE"
  rm -f "$NIGHT/blocked-hand-agents.json" "$NIGHT/worktree-cleanup-manifest.txt" "$RESUME_LOG" "$QUEUE_CALLS"
}

export AGENT_HOME="$AGENT_HOME_DIR" ZF_NIGHT_DIR="$NIGHT" ZF_GH_REPO=test/repo ZF_HAND_REPO_DIR="$REPO_PATH"
export ZF_REPO_DIR="$REPO_PATH" ZF_WORKTREE_ROOT="$ROOT/wt-root" RESUME_LOG
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/night/hand-agent-watchdog.sh"
source "$SCRIPT_DIR/night/hand-exit-handoff.sh"
source "$SCRIPT_DIR/supervisor-holds.sh"
eval "$(sed -n '/^ensure_issue_roadmap_parent_for_dispatch() {/,/^}/p; /^pipeline_system_hand_report_conclusion() {/,/^}/p; /^route_pipeline_fastlane_issue() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
AGENT_HOME="$AGENT_HOME_DIR"
ZF_NIGHT_DIR="$NIGHT"
NIGHT="$NIGHT"
H="$AGENT_HOME_DIR"
REPO=test/repo
REPO_DIR="$REPO_PATH"
WORKTREE_ROOT="$ROOT/wt-root"
LOG="$ROOT/night.log"
BLOCKED_HAND_AGENTS="$NIGHT/blocked-hand-agents.json"
say() { printf '%s\n' "$*" >> "$LOG"; }
hand_agent_issue_is_live_owned() { return 1; }
QUEUE_CALLS="$ROOT/queue-calls.log"
scheduler_requeue_issue() { printf '%s\n' "$*" >> "$QUEUE_CALLS"; }

# Issue blocker: native edge, blocked owner, and requeue. Fastlane sees
# owner=blocked, so no duplicate dispatch or owner-missing page.
reset_followup $'STATUS: FOLLOWUP(9001914, 9001131)\nWaiting for prerequisite issue.'
followup_output="$(FAKE_DEPENDENCY_STATE=OPEN run_lifecycle watch "$REPO_PATH" "$HAND_WT" "$HAND_PID" "$HAND_TICKS" 2>&1)" \
  || fail "FOLLOWUP issue: lifecycle failed: $followup_output"
[ "$(wc -l < "$DEP_LOG")" -eq 1 ] || fail "FOLLOWUP issue: expected one native edge: $(cat "$GH_LOG")"
grep -Fxq 91001131 "$DEP_LOG" || fail "FOLLOWUP issue: dependency edge missed blocker issue id"
jq -e '.[0].dependency == "followup issue:9001131" and .[0].owned_issues == "9001914"' \
  "$BLOCKED_HAND_AGENTS" >/dev/null || fail "FOLLOWUP issue: blocked owner dependency missing: $(cat "$BLOCKED_HAND_AGENTS")"
jq -e '.state == "ready-for-agent" and .hold == null' "$STATE_DIR/9001914.json" >/dev/null \
  || fail "FOLLOWUP issue: owner issue was not requeued"
[ -d "$HAND_WT" ] || fail "FOLLOWUP issue: blocked owner worktree was removed"
supervisor_hold_owner_state 9001914 || fail "FOLLOWUP issue: supervisor did not see owner state"
[ "$SUPERVISOR_HOLD_OWNER_STATE" = blocked ] || fail "FOLLOWUP issue: owner state was $SUPERVISOR_HOLD_OWNER_STATE"
: > "$QUEUE_CALLS"
fastlane_output="$(route_pipeline_fastlane_issue 9001914 '{"labels":[{"name":"pipeline-system"}]}' test 2>&1)" \
  || fail "FOLLOWUP issue: fastlane owner read failed: $fastlane_output"
[ ! -s "$QUEUE_CALLS" ] || fail "FOLLOWUP issue: fastlane dispatched issue with blocked owner"
! grep -q 'pipeline-system-fastlane-owner-missing' "$INBOX" 2>/dev/null \
  || fail "FOLLOWUP issue: blocked owner triggered owner-missing page"
echo 'ok - FOLLOWUP issue blocker records native edge and blocked owner without fastlane page'

# Own issue only: no foreign dependency, no requeue, no blocked owner.
reset_followup $'STATUS: FOLLOWUP(9001914)\nNo external blocker listed.'
followup_output="$(run_lifecycle watch "$REPO_PATH" "$HAND_WT" "$HAND_PID" "$HAND_TICKS" 2>&1)" \
  || fail "FOLLOWUP own-only: lifecycle failed: $followup_output"
[ ! -s "$DEP_LOG" ] || fail "FOLLOWUP own-only: wrote a dependency edge"
[ ! -s "$NIGHT/blocked-hand-agents.json" ] || fail "FOLLOWUP own-only: created a blocked owner"
[ ! -s "$EDIT_LOG" ] || fail "FOLLOWUP own-only: requeued issue without external blocker"
[ ! -e "$HAND_WT" ] || fail "FOLLOWUP own-only: retained ownerless worktree"
echo 'ok - FOLLOWUP own-only remains ownerless with no dependency'

# PR with closing issue maps its native dependency to that issue, never PR id.
reset_followup $'STATUS: FOLLOWUP(9001914, 9001999)\nWaiting for pull request.'
followup_output="$(FAKE_PR_NUMBER=9001999 FAKE_PR_CLOSES_JSON='[{"number":9001132}]' FAKE_DEPENDENCY_STATE=OPEN \
  run_lifecycle watch "$REPO_PATH" "$HAND_WT" "$HAND_PID" "$HAND_TICKS" 2>&1)" \
  || fail "FOLLOWUP PR: lifecycle failed: $followup_output"
grep -Fxq 91001132 "$DEP_LOG" || fail "FOLLOWUP PR: closing issue was not linked: $(cat "$DEP_LOG" 2>/dev/null)"
! grep -Fxq 91019999 "$DEP_LOG" || fail "FOLLOWUP PR: linked PR directly instead of closing issue"
jq -e '.[0].dependency == "followup issue:9001132"' "$BLOCKED_HAND_AGENTS" >/dev/null \
  || fail "FOLLOWUP PR: owner dependency does not name the closing issue"
echo 'ok - FOLLOWUP PR links its open closing issue'

# PR with no closing issue remains in owner record until PR closes.
reset_followup $'STATUS: FOLLOWUP(9001914, 9001998)\nWaiting for unlinked pull request.'
followup_output="$(FAKE_PR_NUMBER=9001998 FAKE_PR_CLOSES_JSON='[]' FAKE_PR_STATE=OPEN \
  run_lifecycle watch "$REPO_PATH" "$HAND_WT" "$HAND_PID" "$HAND_TICKS" 2>&1)" \
  || fail "FOLLOWUP unlinked PR: lifecycle failed: $followup_output"
[ ! -s "$DEP_LOG" ] || fail "FOLLOWUP unlinked PR: wrote issue dependency edge"
jq -e '.[0].dependency == "followup pr:9001998"' "$BLOCKED_HAND_AGENTS" >/dev/null \
  || fail "FOLLOWUP unlinked PR: PR dependency missing from owner record"
