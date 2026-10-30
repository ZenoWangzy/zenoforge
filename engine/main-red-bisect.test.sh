#!/usr/bin/env bash
# Main-red validation bisect lifecycle (#4356, #4477), driven through the tick's
# post-dispatch maintenance entry point against a real git fixture (bare
# origin + clone) and fake gh behind engine/gh-shim. Asserts actions:
# the same-SHA rerun, the source-workflow midpoint probe on a train ref,
# both bisect bounds, the revert PR, reopened ticket and ledger requeue,
# merges held through the revert's red Postsubmit, and the flaky path.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

test_root="${test_env_root:?}"
trap 'rm -rf -- "$test_root"' EXIT

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="test/repo"
export REPO
DRY_RUN=0
AGENT_DRY_RUN=0
export DRY_RUN AGENT_DRY_RUN

FAILED=0
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok - %s\n' "$desc"
  else
    printf 'not ok - %s (expected to find [%s])\n' "$desc" "$needle" >&2
    FAILED=1
  fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok - %s\n' "$desc"
  else
    printf 'not ok - %s (expected NOT to find [%s])\n' "$desc" "$needle" >&2
    FAILED=1
  fi
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok - %s\n' "$desc"
  else
    printf 'not ok - %s (expected [%s], got [%s])\n' "$desc" "$expected" "$actual" >&2
    FAILED=1
  fi
}

# --- git fixture: green G, one clean commit, a culprit, then the red tip.
# The first midpoint is red; the next midpoint is green, exercising both
# bounds before the culprit is selected.
origin="$test_root/origin.git"
repo="$test_root/repo"
git init -q -b main --bare "$origin"
git init -q -b main "$repo"
git -C "$repo" remote add origin "$origin"
git -C "$repo" config user.name 'Fixture'
git -C "$repo" config user.email fixture@example.test
COMMIT_COUNT=0
commit() {
  local msg="$1"
  COMMIT_COUNT=$((COMMIT_COUNT + 1))
  printf '%s\n' "$msg" > "$repo/fixture-$COMMIT_COUNT.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$msg"
}
commit "base"
GREEN_SHA="$(git -C "$repo" rev-parse HEAD)"
commit "chore: clean one"
GREEN_MID_SHA="$(git -C "$repo" rev-parse HEAD)"
commit "fix(#4102): culprit"
CULPRIT_SHA="$(git -C "$repo" rev-parse HEAD)"
commit "chore: red tip"
RED_SHA="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" push -q origin main
export ZF_REPO_DIR="$repo" ZF_REPO="$REPO"

# --- fake gh behind the real gh-shim guard chain
FAKE_BIN="$test_root/fake-bin"
mkdir -p "$FAKE_BIN" "$test_root/gh-state"
export FAKE_GH_STATE="$test_root/gh-state"
export PATH="$SCRIPT_DIR/gh-shim:$FAKE_BIN:$PATH"
export ZF_GH_REAL_CLI="$FAKE_BIN/gh"
cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
state="${FAKE_GH_STATE:?}"
printf '%s\n' "$*" >> "$state/calls.log"
api_path=""
if [ "${1:-}" = api ]; then
  for arg in "$@"; do case "$arg" in repos/*) api_path="$arg"; break ;; esac; done
fi
if [ "${1:-}" = api ]; then
  case "$api_path" in
    repos/*/actions/workflows/ci.yml/runs?*) cat "$state/completed-runs.json" ;;
    repos/*/actions/workflows/pipeline-suites.yml/runs?*) cat "$state/pipeline-suites-runs.json" ;;
    repos/*/actions/runs?head_sha=*)
      sha="${api_path#*head_sha=}"; sha="${sha%%&*}"
      jq -cn --argjson runs "$(cat "$state/per-sha-runs.json")" --arg sha "$sha" \
        '{workflow_runs: ($runs[$sha] // [])}'
      ;;
    *) printf '{}\n' ;;
  esac
  exit 0
fi
case "${1:-} ${2:-}" in
  "run rerun") printf 'rerun %s\n' "$3" >> "$state/actions.log"; exit 0 ;;
  "workflow run")
    if [ "${FAKE_FAIL_WORKFLOW_DISPATCH:-0}" = 1 ]; then exit 1; fi
    printf 'dispatch %s %s %s\n' "$3" "$7" "${9#source_sha=}" >> "$state/actions.log"
    exit 0 ;;
  "pr create")
    count=0
    [ ! -r "$state/pr-create-count" ] || count="$(cat "$state/pr-create-count")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$state/pr-create-count"
    if [ "$count" -eq 1 ] && [ "${FAKE_FAIL_FIRST_PR_CREATE:-0}" = 1 ]; then exit 1; fi
    printf 'https://github.com/test/repo/pull/6001\n'
    exit 0 ;;
  "pr view")
    case "$*" in
      *"--json state -q .state"*)
        case "$3" in
          6001) printf '%s\n' "${FAKE_REVERT_PR_STATE:-OPEN}" ;;
          *) printf 'OPEN\n' ;;
        esac
        exit 0 ;;
    esac
    ;;
  "issue view") printf '%s\n' "${FAKE_ISSUE_STATE:-CLOSED}"; exit 0 ;;
  "issue reopen") printf 'reopen %s\n' "$3" >> "$state/actions.log"; exit 0 ;;
  "issue edit") printf 'edit %s %s\n' "$3" "$*" >> "$state/actions.log"; exit 0 ;;
  "issue comment")
    issue_number="$3"
    body_file=""
    while (($#)); do
      if [ "$1" = --body-file ]; then body_file="$2"; break; fi
      shift
    done
    printf 'issue comment %s\n' "$issue_number" >> "$state/actions.log"
    [ -n "$body_file" ] && cat "$body_file" >> "$state/actions.log"
    exit 0 ;;
  "pr list") exit 0 ;;
esac
exit 0
GH
chmod +x "$FAKE_BIN/gh"
: > "$FAKE_GH_STATE/actions.log"
printf '{}' > "$FAKE_GH_STATE/per-sha-runs.json"
printf '{"workflow_runs":[]}\n' > "$FAKE_GH_STATE/pipeline-suites-runs.json"

main_runs() { # <green-conclusion> <red-conclusion> -> completed-runs.json
  jq -cn --arg green "$GREEN_SHA" --arg red "$RED_SHA" \
    --arg gc "${1:-success}" --arg rc "${2:-failure}" \
    '{workflow_runs:[
      {id:400,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:$gc,created_at:"2026-10-27T09:00:00Z"},
      {id:501,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:$rc,created_at:"2026-10-27T10:00:00Z"}]}'
}
# Set the per-SHA run history for one SHA (write is tmp+mv so a caller can
# never redirect-read the same file into truncation).
probe_runs() { # <sha> <status> <conclusion> [workflow]
  local tmp workflow="${4:-ci.yml}"
  tmp="$(mktemp)"
  jq -cn --arg sha "$1" --arg status "$2" --arg conclusion "$3" --arg workflow "$workflow" \
    --argjson existing "$(cat "$FAKE_GH_STATE/per-sha-runs.json")" \
    '$existing * {($sha): [{id:601,head_sha:$sha,head_branch:"train/bisect-fixture",event:"workflow_dispatch",path:(".github/workflows/" + $workflow),status:$status,conclusion:(if $status == "completed" then $conclusion else null end),created_at:"2026-10-27T11:00:00Z"}]}' \
    > "$tmp" && mv -f -- "$tmp" "$FAKE_GH_STATE/per-sha-runs.json"
}

main_runs > "$FAKE_GH_STATE/completed-runs.json"

source "$SCRIPT_DIR/lib.sh"

# Run the tick-owned maintenance loop from its durable resume point. The
# other maintenance owners are quiet fixtures; main-red is the real sweep.
eval "$(sed -n '/^run_post_dispatch_maintenance() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
profile_mark() { :; }
checks_blocked_sweep() { :; }
hold_sweep() { :; }
supervisor_hold_sweep() { :; }
reconcile_maintainer_outcomes() { :; }
flush_maintainer_outcome_digest() { :; }
read_needs_info_email_replies() { :; }
sweep_reopened_issues() { :; }
sweep_blocking_issue_roots() { :; }
sweep_unlabeled_issues() { :; }
reconcile_needs_info_issues() { :; }
is_on_hold() { return 1; }
recut_parent_has_open_child() { return 3; }
roadmap_ensure_issue_parent() { :; }
IMPLEMENT_TICK_ID=main-red-fixture
TICK_UNIT_TIMEOUT_SECONDS=1200
MAINTENANCE_STEP_RESERVE_SECONDS=240
maintenance_tick() {
  mkdir -p "$AGENT_HOME/night"
  printf 'main-red-bisect\n' > "$AGENT_HOME/night/maintenance-resume"
  SECONDS=0
  run_post_dispatch_maintenance
}

# Outward-effect recorders replace the network/notify surfaces.
EVENTS="$test_root/events.log"
: > "$EVENTS"
supervisor_inbox_append() { printf 'event %s\n' "$*" >> "$EVENTS"; }
STATE_DIR="$AGENT_HOME/state"
mkdir -p "$STATE_DIR"

session_json() { jq -c . "$AGENT_HOME/main-red/$RED_SHA.json" 2>/dev/null || echo '{}'; }

# Tick 1: the red appears; the same-SHA rerun (flaky check) is requested.
maintenance_tick
assert_contains "tick 1 requests the one same-SHA rerun" "$(cat "$FAKE_GH_STATE/actions.log")" "rerun 501"
assert_eq "tick 1 opens a rerun-requested session" rerun-requested "$(session_json | jq -r .status)"

# Tick 2: the rerun finished red; the bisect window opens.
main_runs failure failure > "$FAKE_GH_STATE/completed-runs.json"
maintenance_tick
assert_eq "tick 2 moves to bisecting after the rerun stayed red" bisecting "$(session_json | jq -r .status)"

# Tick 3: the first midpoint is the culprit and has no verdict yet; the tick
# dispatches ci.yml Postsubmit on it via workflow_dispatch from a train ref.
maintenance_tick
ACTIONS="$(cat "$FAKE_GH_STATE/actions.log")"
assert_contains "tick 3 dispatches a midpoint Postsubmit probe" "$ACTIONS" \
  "dispatch ci.yml train/bisect-${RED_SHA:0:12} $CULPRIT_SHA"
assert_contains "the train ref for the probe was pushed" \
  "$(git -C "$origin" for-each-ref --format='%(refname:short)' refs/heads/)" "train/bisect-${RED_SHA:0:12}"
# While the culprit is unknown, merging is stopped: the gate is closed.
if main_merge_clear >/dev/null 2>&1; then GATE3=clear; else GATE3=held; fi
assert_eq "merging is stopped while the bisect has no culprit" held "$GATE3"

# An in-flight midpoint is held without a duplicate dispatch.
probe_runs "$CULPRIT_SHA" in_progress ""
maintenance_tick
assert_eq "pending midpoint keeps the same probe in flight" "$CULPRIT_SHA" "$(session_json | jq -r '.probe.sha')"
assert_eq "pending midpoint is not dispatched again" 1 "$(grep -c '^dispatch ' "$FAKE_GH_STATE/actions.log")"

# Tick 5: the red midpoint narrows the upper bound.
probe_runs "$CULPRIT_SHA" completed failure
maintenance_tick
# Tick 6 dispatches the clean midpoint; tick 7 observes its green verdict.
maintenance_tick
assert_contains "tick 6 dispatches the next midpoint" "$(cat "$FAKE_GH_STATE/actions.log")" \
  "dispatch ci.yml train/bisect-${RED_SHA:0:12} $GREEN_MID_SHA"
probe_runs "$GREEN_MID_SHA" completed success
maintenance_tick
maintenance_tick
assert_eq "tick 8 has selected the culprit" "$CULPRIT_SHA" "$(session_json | jq -r .culprit)"

# Tick 9's PR-create call fails after the branch push; tick 10 reuses that
# exact branch SHA, opens the PR, reopens the ticket and requeues its ledger.
jq -cn '{state:"awaiting-release",attempts:3,model_policy:{unit:"release",step:"production",history:[]}}' \
  > "$STATE_DIR/4102.json"
FAKE_FAIL_FIRST_PR_CREATE=1 maintenance_tick
BRANCH_SHA_AFTER_FAILED_CREATE="$(git --git-dir="$origin" rev-parse "refs/heads/agent/revert-main-4102-${CULPRIT_SHA:0:12}")"
assert_eq "failed PR creation leaves the original revert branch available" culprit-found "$(session_json | jq -r .status)"
maintenance_tick
BRANCH_SHA_AFTER_RETRY="$(git --git-dir="$origin" rev-parse "refs/heads/agent/revert-main-4102-${CULPRIT_SHA:0:12}")"
assert_eq "retry reuses the pushed revert SHA" "$BRANCH_SHA_AFTER_FAILED_CREATE" "$BRANCH_SHA_AFTER_RETRY"
assert_eq "tick 10 records an open revert PR" revert-open "$(session_json | jq -r .status)"
assert_contains "the revert branch was pushed" \
  "$(git -C "$origin" for-each-ref --format='%(refname:short)' refs/heads/)" \
  "agent/revert-main-4102-${CULPRIT_SHA:0:12}"
CALLS="$(cat "$FAKE_GH_STATE/actions.log")"
assert_contains "the culprit's ticket gets the bisect evidence" "$CALLS" "issue comment 4102"
assert_contains "the evidence names the culprit commit" "$CALLS" "$CULPRIT_SHA"
assert_contains "the evidence links the revert PR" "$CALLS" "#6001"
assert_contains "the closed ticket is reopened" "$CALLS" "reopen 4102"
assert_eq "the issue ledger returns to implementation" ready-for-agent "$(jq -r .state "$STATE_DIR/4102.json")"
assert_eq "the issue ledger resets the implement attempt budget" 0 "$(jq -r .attempts "$STATE_DIR/4102.json")"
# Naming a culprit does not open the ordinary merge gate; only the revert PR
# can pass until a later Postsubmit on the reverted main is green.
if main_merge_clear >/dev/null 2>&1; then GATE7=clear; else GATE7=held; fi
assert_eq "ordinary merges stay held while the revert PR is open" held "$GATE7"

# Tick 11: the revert PR merged, but the old red still holds ordinary merges.
FAKE_REVERT_PR_STATE=MERGED maintenance_tick
assert_eq "tick 10 records the merged revert" reverted "$(session_json | jq -r .status)"
if main_merge_clear >/dev/null 2>&1; then GATE8=clear; else GATE8=held; fi
assert_eq "ordinary merges stay held until the revert Postsubmit is green" held "$GATE8"
git -C "$repo" -c user.name='Fixture' -c user.email=fixture@example.test revert --no-edit "$CULPRIT_SHA" >/dev/null
REVERTED_MAIN_SHA="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" push -q origin main
jq -cn --arg green "$REVERTED_MAIN_SHA" --arg red "$RED_SHA" \
  '{workflow_runs:[
    {id:400,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-27T10:00:00Z"},
    {id:700,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-27T12:00:00Z"}]}' \
  > "$FAKE_GH_STATE/completed-runs.json"
maintenance_tick
if main_merge_clear >/dev/null 2>&1; then GATE_GREEN=clear; else GATE_GREEN=held; fi
assert_eq "later green Postsubmit releases ordinary merges" clear "$GATE_GREEN"
assert_not_contains "no supervisor event fired on the happy path" "$(cat "$EVENTS")" "event main-red-bisect"

# --- Flaky: the same SHA reruns green; no revert, no bisect.
FLAKY_RED="$test_root/flaky"
rm -rf "$AGENT_HOME/main-red"
: > "$FAKE_GH_STATE/actions.log"
: > "$FAKE_GH_STATE/calls.log"
commit "fix(#4104): fourth"
FLAKY_SHA="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" push -q origin main
FLAKY_SHA="$FLAKY_SHA" RED_SHA="$FLAKY_SHA" main_runs > "$FAKE_GH_STATE/completed-runs.json"
maintenance_tick
assert_contains "flaky tick 1 requests the same-SHA rerun" "$(cat "$FAKE_GH_STATE/actions.log")" "rerun 501"
FLAKY_SHA="$FLAKY_SHA" RED_SHA="$FLAKY_SHA" main_runs failure success > "$FAKE_GH_STATE/completed-runs.json"
probe_runs "$FLAKY_SHA" completed success
maintenance_tick
assert_eq "a red that reruns green is recorded flaky" flaky \
  "$(jq -r .status "$AGENT_HOME/main-red/$FLAKY_SHA.json")"
assert_not_contains "the flaky path never creates a revert PR" "$(cat "$FAKE_GH_STATE/calls.log")" "pr create"
assert_not_contains "the flaky path never dispatches a probe" "$(cat "$FAKE_GH_STATE/actions.log")" "dispatch"
assert_not_contains "the flaky path never comments on a ticket" "$(cat "$FAKE_GH_STATE/actions.log")" "issue comment"

# No successful baseline cannot anchor attribution. The tick emits one
# supervisor event and keeps the red gate closed; later ticks do not repeat it.
rm -rf "$AGENT_HOME/main-red"
: > "$FAKE_GH_STATE/actions.log"
commit "fix(#4105): no baseline"
NO_BASE_SHA="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" push -q origin main
jq -cn --arg red "$NO_BASE_SHA" \
  '{workflow_runs:[{id:501,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-28T10:00:00Z"}]}' \
  > "$FAKE_GH_STATE/completed-runs.json"
maintenance_tick
assert_contains "unanchored red requests the same-SHA rerun" "$(cat "$FAKE_GH_STATE/actions.log")" "rerun 501"
maintenance_tick
assert_contains "unanchored red emits one supervisor event" "$(cat "$EVENTS")" "reason=no-green-baseline"
if main_merge_clear >/dev/null 2>&1; then GATE_UNANCHORED=clear; else GATE_UNANCHORED=held; fi
assert_eq "unattributed red keeps ordinary merges held" held "$GATE_UNANCHORED"
maintenance_tick
assert_eq "unattributed red does not repeat its event" 1 "$(grep -c 'reason=no-green-baseline' "$EVENTS")"

# Failed workflow_dispatch probes are counted before the external call, then
# stop with one supervisor event instead of retrying forever.
rm -rf "$AGENT_HOME/main-red"
printf '{}' > "$FAKE_GH_STATE/per-sha-runs.json"
commit "chore: probe dispatch baseline"
commit "fix(#4106): probe dispatch culprit"
commit "chore: probe dispatch red tip"
DISPATCH_RED_SHA="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" push -q origin main
jq -cn --arg green "$GREEN_SHA" --arg red "$DISPATCH_RED_SHA" \
  '{workflow_runs:[
    {id:400,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-27T09:00:00Z"},
    {id:501,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-28T10:00:00Z"}]}' \
  > "$FAKE_GH_STATE/completed-runs.json"
FAKE_FAIL_WORKFLOW_DISPATCH=1 maintenance_tick
jq -cn --arg green "$GREEN_SHA" --arg red "$DISPATCH_RED_SHA" \
  '{workflow_runs:[
    {id:400,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-27T09:00:00Z"},
    {id:501,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-28T10:00:00Z"}]}' \
  > "$FAKE_GH_STATE/completed-runs.json"
FAKE_FAIL_WORKFLOW_DISPATCH=1 maintenance_tick
# Tick 3 attempts the first midpoint dispatch.
FAKE_FAIL_WORKFLOW_DISPATCH=1 maintenance_tick
DISPATCH_SESSION="$AGENT_HOME/main-red/$DISPATCH_RED_SHA.json"
assert_eq "failed midpoint dispatch is durably counted" 1 "$(jq -r '.probe.attempts' "$DISPATCH_SESSION")"
touch -d '20 minutes ago' "$DISPATCH_SESSION"
FAKE_FAIL_WORKFLOW_DISPATCH=1 maintenance_tick
assert_eq "second failed midpoint dispatch consumes the bounded retry" 2 "$(jq -r '.probe.attempts' "$DISPATCH_SESSION")"
touch -d '20 minutes ago' "$DISPATCH_SESSION"
FAKE_FAIL_WORKFLOW_DISPATCH=1 maintenance_tick
assert_eq "exhausted midpoint dispatch becomes unattributed" unattributed "$(jq -r .status "$DISPATCH_SESSION")"
assert_eq "exhausted dispatch emits one event" 1 "$(grep -c 'reason=probe-dispatch-exhausted' "$EVENTS")"
maintenance_tick
assert_eq "exhausted dispatch does not repeat its event" 1 "$(grep -c 'reason=probe-dispatch-exhausted' "$EVENTS")"
unset FAKE_FAIL_WORKFLOW_DISPATCH

# A bisected commit without a fix(#N) owner is held for a human and never
# creates a revert PR.
rm -rf "$AGENT_HOME/main-red"
: > "$FAKE_GH_STATE/calls.log"
UNOWNED_BASE="$(git -C "$repo" rev-parse HEAD)"
commit "feat: unowned main regression"
UNOWNED_SHA="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" push -q origin main
jq -cn --arg green "$UNOWNED_BASE" --arg red "$UNOWNED_SHA" \
  '{workflow_runs:[
    {id:600,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-28T11:00:00Z"},
    {id:601,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-28T12:00:00Z"}]}' \
  > "$FAKE_GH_STATE/completed-runs.json"
maintenance_tick
jq -cn --arg green "$UNOWNED_BASE" --arg red "$UNOWNED_SHA" \
  '{workflow_runs:[
    {id:600,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-28T11:00:00Z"},
    {id:601,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-28T12:00:00Z"}]}' \
  > "$FAKE_GH_STATE/completed-runs.json"
maintenance_tick
maintenance_tick
maintenance_tick
UNOWNED_SESSION="$AGENT_HOME/main-red/$UNOWNED_SHA.json"
assert_eq "ownerless culprit becomes unattributed" unattributed "$(jq -r .status "$UNOWNED_SESSION")"
assert_contains "ownerless culprit notifies the supervisor" "$(cat "$EVENTS")" "reason=no-owner-issue"
assert_not_contains "ownerless culprit never creates a revert PR" "$(cat "$FAKE_GH_STATE/calls.log")" "pr create"

# A Pipeline suites-only red is discovered even when Postsubmit has no run on
# that SHA. The same workflow owns its rerun and midpoint probe.
rm -rf "$AGENT_HOME/main-red"
: > "$FAKE_GH_STATE/actions.log"
: > "$FAKE_GH_STATE/calls.log"
: > "$EVENTS"
printf '{}' > "$FAKE_GH_STATE/per-sha-runs.json"
jq -cn --arg green "$GREEN_SHA" \
  '{workflow_runs:[{id:400,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-27T09:00:00Z"}]}' \
  > "$FAKE_GH_STATE/completed-runs.json"
jq -cn --arg green "$GREEN_SHA" --arg red "$RED_SHA" \
  '{workflow_runs:[
    {id:800,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-27T09:00:00Z"},
    {id:801,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-27T10:00:00Z"}]}' \
  > "$FAKE_GH_STATE/pipeline-suites-runs.json"
maintenance_tick
SUITE_SESSION="$AGENT_HOME/main-red/$RED_SHA.json"
assert_eq "a suites-only red opens the existing rerun session" rerun-requested "$(jq -r '.status' "$SUITE_SESSION")"
assert_eq "the session records Pipeline suites as its red source" pipeline-suites.yml "$(jq -r '.red_workflow' "$SUITE_SESSION")"
assert_contains "a suites-only red reruns its main run" "$(cat "$FAKE_GH_STATE/actions.log")" "rerun 801"

jq -cn --arg green "$GREEN_SHA" --arg red "$RED_SHA" \
  '{workflow_runs:[
    {id:800,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-27T09:00:00Z"},
    {id:801,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-27T10:00:00Z",run_attempt:2}]}' \
  > "$FAKE_GH_STATE/pipeline-suites-runs.json"
maintenance_tick
assert_eq "the same-SHA suites rerun failure advances to bisecting" bisecting "$(jq -r '.status' "$SUITE_SESSION")"
maintenance_tick
assert_contains "a suites-only red dispatches a Pipeline suites midpoint" \
  "$(cat "$FAKE_GH_STATE/actions.log")" "dispatch pipeline-suites.yml train/bisect-${RED_SHA:0:12}"

# A Pipeline suites same-SHA rerun that passes is recorded as flaky without
# falling back to the unrelated ci.yml verdict.
rm -rf "$AGENT_HOME/main-red"
: > "$FAKE_GH_STATE/actions.log"
printf '{}' > "$FAKE_GH_STATE/per-sha-runs.json"
jq -cn --arg green "$GREEN_SHA" --arg red "$RED_SHA" \
  '{workflow_runs:[
    {id:800,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-27T09:00:00Z"},
    {id:801,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-27T10:00:00Z"}]}' \
  > "$FAKE_GH_STATE/pipeline-suites-runs.json"
maintenance_tick
probe_runs "$RED_SHA" completed success pipeline-suites.yml
jq -cn --arg green "$GREEN_SHA" --arg red "$RED_SHA" \
  '{workflow_runs:[
    {id:800,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-27T09:00:00Z"},
    {id:801,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-27T10:00:00Z",run_attempt:2}]}' \
  > "$FAKE_GH_STATE/pipeline-suites-runs.json"
maintenance_tick
assert_eq "a suites red whose same-SHA rerun passes becomes flaky" flaky \
  "$(jq -r '.status' "$AGENT_HOME/main-red/$RED_SHA.json")"
assert_not_contains "the suites flaky path does not dispatch a midpoint" \
  "$(cat "$FAKE_GH_STATE/actions.log")" "dispatch"

# A newer green attempt in the same workflow supersedes its earlier red.
rm -rf "$AGENT_HOME/main-red"
: > "$FAKE_GH_STATE/actions.log"
jq -cn --arg green "$GREEN_SHA" \
  '{workflow_runs:[{id:400,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-27T09:00:00Z"}]}' \
  > "$FAKE_GH_STATE/completed-runs.json"
jq -cn --arg green "$GREEN_SHA" --arg red "$RED_SHA" \
  '{workflow_runs:[
    {id:800,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-27T09:00:00Z"},
    {id:801,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-27T10:00:00Z"},
    {id:802,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-27T11:00:00Z"}]}' \
  > "$FAKE_GH_STATE/pipeline-suites-runs.json"
maintenance_tick
assert_eq "a newer same-workflow green does not reopen an old red" absent \
  "$(if [ -e "$AGENT_HOME/main-red/$RED_SHA.json" ]; then echo present; else echo absent; fi)"
assert_not_contains "a superseded suite red does not request another rerun" \
  "$(cat "$FAKE_GH_STATE/actions.log")" "rerun"

# A valid PAUSE still discovers that red and queues one supervisor event, but
# neither the pause gate nor its delegated release exception advances recovery.
rm -rf "$AGENT_HOME/main-red"
: > "$FAKE_GH_STATE/actions.log"
: > "$EVENTS"
rm -f "$AGENT_HOME/supervisor-inbox" "$AGENT_HOME/supervisor-inbox.once"
jq -cn --arg green "$GREEN_SHA" --arg red "$RED_SHA" \
  '{workflow_runs:[
    {id:800,head_sha:$green,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-27T09:00:00Z"},
    {id:801,head_sha:$red,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-27T10:00:00Z"}]}' \
  > "$FAKE_GH_STATE/pipeline-suites-runs.json"
supervisor_inbox_append() {
  printf 'event %s\n' "$2" >> "$EVENTS"
  printf '%s\n' "$2" >> "$AGENT_HOME/supervisor-inbox"
}
PAUSE_GATE_BODY="$(sed -n '/^if \[ -e "\$PAUSE_FILE" \]; then$/,/^# Kill switch: gh variable AGENT_PIPELINE/p' \
  "$SCRIPT_DIR/issue-pipeline.sh" | sed '$d')"
PIPELINE_STAGE=implement ZF_RELEASE_TRAIN_DELEGATE=0
export PIPELINE_STAGE ZF_RELEASE_TRAIN_DELEGATE
jq -n --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{reason:"fixture pause",caller:"operator",issue:"none",provider:"none",model:"none",timestamp:$timestamp}' \
  > "$PAUSE_FILE"
pause_gate_tick() (
  PIPELINE_STAGE="${1:-implement}"
  ZF_RELEASE_TRAIN_DELEGATE="${2:-0}"
  eval "$PAUSE_GATE_BODY"
  printf 'continued\n'
)
PAUSE_TICK_RESULT="$(pause_gate_tick implement 0)"
assert_eq "the valid PAUSE gate exits after reporting the red" '' "$PAUSE_TICK_RESULT"
assert_contains "the paused suites red queues a supervisor inbox event" "$(cat "$EVENTS")" \
  "event main-red-bisect red=${RED_SHA:0:12} status=paused workflow=pipeline-suites.yml run=801"
assert_contains "the paused suites red is written to the supervisor inbox" \
  "$(cat "$AGENT_HOME/supervisor-inbox")" \
  "main-red-bisect red=${RED_SHA:0:12} status=paused workflow=pipeline-suites.yml run=801"
assert_eq "repeated valid PAUSE discovery is deduplicated" 1 \
  "$(grep -c 'status=paused workflow=pipeline-suites.yml' "$EVENTS")"
assert_eq "paused discovery does not open a bisect session" absent \
  "$(if [ -e "$AGENT_HOME/main-red/$RED_SHA.json" ]; then echo present; else echo absent; fi)"
PAUSE_TICK_RESULT="$(pause_gate_tick release 1)"
assert_eq "the delegated release slice may continue under PAUSE" continued "$PAUSE_TICK_RESULT"
PIPELINE_STAGE=release ZF_RELEASE_TRAIN_DELEGATE=1 maintenance_tick
assert_not_contains "PAUSE prevents the release exception from starting bisect actions" \
  "$(cat "$FAKE_GH_STATE/actions.log")" "rerun 801"
assert_eq "PAUSE keeps the bisect session unopened in maintenance" absent \
  "$(if [ -e "$AGENT_HOME/main-red/$RED_SHA.json" ]; then echo present; else echo absent; fi)"
rm -f "$PAUSE_FILE"

if [ "$FAILED" -eq 1 ]; then
  printf 'FAILED\n' >&2
  exit 1
fi
printf 'ALL PASS\n'
