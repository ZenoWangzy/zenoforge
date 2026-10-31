#!/usr/bin/env bash
# Regression tests for run-recut.sh's entry and refusal routing: its
# precondition checks `needs-recut`, ordinary refusals climb to guarded
# `ready-for-agent`, and guarded repeat refusals return to the scheduler.
# Successful child creation retires the parent through
# complete_recut_parent(); its focused state/label contract lives in
# recut-parent-state.test.sh.
#
# Plain bash assertions, no framework -- same fake-gh/fake-codex/real-git
# pattern as run-advisor.test.sh and run-release.test.sh. This does not
# re-test recut's own model-output verification machinery (file/symbol
# fabrication checks, topo order, child cap) -- those are lib.sh's
# recut_slice_verified()/recut_topo_order()/recut_child_count_ok(), already
# covered by lib.test.sh. This covers entry and refusal routing.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECUT_SRC="$SCRIPT_DIR/run-recut.sh"
N=90043
ZF_CONFIG_ROOT="$test_env_root/recut-target/.zenoforge"
mkdir -p "$ZF_CONFIG_ROOT/prompts"
cp "$SCRIPT_DIR/prompts/recut.md" "$ZF_CONFIG_ROOT/prompts/recut.md"
printf '\nCONFIG_RECUT_PROMPT_OVERRIDE\n' >> "$ZF_CONFIG_ROOT/prompts/recut.md"
cp "$SCRIPT_DIR/prompts/recut.schema.json" "$ZF_CONFIG_ROOT/prompts/recut.schema.json"
cp "$SCRIPT_DIR/prompts/agent-settings.json" "$ZF_CONFIG_ROOT/prompts/agent-settings.json"
export ZF_CONFIG_ROOT

FAILED=0
TMP_DIRS=()
HAND_TEST_WORKTREES=()
HAND_TEST_OWNER_PIDS=()
HAND_TEST_PR_JSON='[]'
HAND_TEST_PR_HEAD=''
HAND_TEST_ENQUEUE_EXIT=0
HAND_TEST_OWNER_MODE=''
HAND_TEST_TITLE='recut test issue'
HAND_TEST_BODY=''
cleanup() {
  local d
  local wt
  local owner_pid
  for owner_pid in "${HAND_TEST_OWNER_PIDS[@]}"; do
    kill "$owner_pid" 2>/dev/null || true
    wait "$owner_pid" 2>/dev/null || true
  done
  for wt in "${HAND_TEST_WORKTREES[@]:-}"; do
    [ -n "$wt" ] || continue
    if [ -n "${FIXTURE_REPO:-}" ]; then
      git -C "$FIXTURE_REPO" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf -- "$wt"
    else
      rm -rf -- "$wt"
    fi
  done
  if [ -n "${FIXTURE_REPO:-}" ]; then git -C "$FIXTURE_REPO" worktree prune >/dev/null 2>&1 || :; fi
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$HOME/wt/recut-$N"
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

# --- fake gh/codex, shadowing the real binaries on PATH --------------------
FAKE_BIN="$(mktemp -d)"
TMP_DIRS+=("$FAKE_BIN")

# Fake gh: issue view's labels come from $FAKE_ISSUE_LABELS (space-separated,
# set per test case) so has_label()/is_on_hold() (lib.sh, both go through
# `gh issue view --json labels -q '.labels[].name'`) see exactly what each
# case needs -- real gh applies -q itself, so this fake has to too, not just
# echo the raw object the way run-advisor.test.sh's fake gh can get away
# with (run-advisor.sh never calls has_label/is_on_hold itself).
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = api ]; then
  if [[ "${2:-}" == */timeline ]]; then
    query=""
    previous=""
    for arg in "$@"; do
      [ "$previous" = "--jq" ] && query="$arg"
      previous="$arg"
    done
    if [[ "$query" == *'event=="unlabeled"'* ]]; then
      [ -z "${FAKE_ISSUE_HOLD_LIFT:-}" ] || printf '%s\n' "$FAKE_ISSUE_HOLD_LIFT"
    else
      jq -r "${query:-.[].created_at}" <<< "${FAKE_ISSUE_TIMELINE_JSON:-[]}"
    fi
  else
    echo '[]'
  fi
  exit 0
fi
sub="$1 ${2:-}"
case "$sub" in
  "issue list")
    label=""
    previous=""
    for arg in "$@"; do
      [ "$previous" = "--label" ] && label="$arg" && break
      previous="$arg"
    done
    case " ${FAKE_ISSUE_LABELS:-} " in
      *" $label "*) echo "${FAKE_ISSUE_NUMBER:-90043}" ;;
    esac
    ;;
  "issue view")
    labels_json="[]"
    for l in ${FAKE_ISSUE_LABELS:-}; do
      labels_json="$(echo "$labels_json" | jq -c --arg l "$l" '. + [{name: $l}]')"
    done
    state_request=""
    query=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "-q" ] && query="$a"
      [ "$prev" = "--json" ] && state_request="$a"
      prev="$a"
    done
    if [[ "$state_request" == *title* || "$state_request" == "state,labels" ]]; then
      state_view_file="${FAKE_GH_LOG}.state-views"
      state_view_count="$(cat "$state_view_file" 2>/dev/null || echo 0)"
      state_view_count=$((state_view_count + 1))
      printf '%s\n' "$state_view_count" > "$state_view_file"
    fi
    state=OPEN
    if [ "${FAKE_RECUIT_STALE_AFTER_SNAPSHOT:-0}" = "1" ] \
      && [ "${state_view_count:-0}" -gt 1 ]; then
      state=CLOSED
      labels_json='[{"name":"priority:top"},{"name":"released"}]'
    fi
    obj="$(jq -n --arg state "$state" --argjson labels "$labels_json" \
      --arg title "${FAKE_ISSUE_TITLE:-recut test issue}" --arg body "${FAKE_ISSUE_BODY:-}" \
      '{number: 1, title: $title, body: $body, author: {login: "testuser"}, comments: [], createdAt: "2026-01-01T00:00:00Z", state: $state, labels: $labels}')"
    if [ -n "$query" ]; then
      echo "$obj" | jq -r "$query"
    else
      echo "$obj"
    fi
    ;;
  "pr list")
    head=""
    previous=""
    for arg in "$@"; do
      [ "$previous" = "--head" ] && head="$arg"
      previous="$arg"
    done
    if [ "$head" = "${FAKE_HAND_PR_HEAD:-}" ]; then
      printf '%s\n' "${FAKE_HAND_PR_JSON:-[]}"
    else
      echo '[]'
    fi
    ;;
  "issue edit"|"issue comment"|"issue create")
    echo "gh $*" >> "$FAKE_GH_LOG"
    previous=""
    for arg in "$@"; do
      if [ "$previous" = "--body-file" ]; then
        cat "$arg" >> "$FAKE_GH_LOG"
        printf '\n' >> "$FAKE_GH_LOG"
        break
      fi
      previous="$arg"
    done
    ;;
  "pr checks") printf '%s\n' '[{"name":"fixture","bucket":"fail"}]'; exit 1 ;;
  *) : ;;
esac
exit 0
EOF

# Fake Codex: a domain_verified=false refusal every time -- these tests
# cover the label change, not the model's own cut-vs-refuse judgement.
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_RECUIT_ARGS_FILE"
out="" previous=""
schema=""
for arg in "$@"; do
  [ "$previous" = "--output-last-message" ] && out="$arg"
  [ "$previous" = "--output-schema" ] && schema="$arg"
  previous="$arg"
done
cat > "${FAKE_RECUIT_INPUT:-/dev/null}"
if [ -n "$schema" ] && [ -n "${FAKE_RECUIT_SCHEMA_FILE:-}" ]; then
  cp "$schema" "$FAKE_RECUIT_SCHEMA_FILE"
fi
if [ -n "${FAKE_RECUIT_REASON_FILE:-}" ]; then
  jq -cn --rawfile reason "$FAKE_RECUIT_REASON_FILE" \
    --arg production_access "${FAKE_RECUIT_PRODUCTION_ACCESS:-__omit__}" \
    '{domain_verified:false,refuse_reason:$reason,children:[]} + (if $production_access == "true" then {needs_production_access:true} elif $production_access == "false" then {needs_production_access:false} else {} end)' > "$out"
else
  jq -cn --arg production_access "${FAKE_RECUIT_PRODUCTION_ACCESS:-__omit__}" \
    '{domain_verified:false,refuse_reason:"没有找到对应的真实实现，无法据此拆票。",children:[]} + (if $production_access == "true" then {needs_production_access:true} elif $production_access == "false" then {needs_production_access:false} else {} end)' > "$out"
fi
printf '%s\n' 'tokens used' '1' >&2
EOF
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
# Worktree finalizer needs a readable, empty owner inventory.
case " $* " in *' list-units '*) exit 0 ;; esac
exit 1
EOF

chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/codex" "$FAKE_BIN/systemctl"
export PATH="$FAKE_BIN:$PATH"
export REPO="test/repo"

# --- one shared git fixture: a bare origin + a clone with one commit -------
FIXTURE_ORIGIN="$(mktemp -d)"
FIXTURE_REPO="$(mktemp -d)"
TMP_DIRS+=("$FIXTURE_ORIGIN" "$FIXTURE_REPO")
git init -q --bare "$FIXTURE_ORIGIN"
git -C "$FIXTURE_ORIGIN" symbolic-ref HEAD refs/heads/main
git -C "$FIXTURE_REPO" init -q -b main
git -C "$FIXTURE_REPO" config user.email test@example.com
git -C "$FIXTURE_REPO" config user.name "Test"
mkdir -p "$FIXTURE_REPO/engine"
cp "$SCRIPT_DIR/model-policy.default.json" "$FIXTURE_REPO/engine/model-policy.default.json"
echo seed > "$FIXTURE_REPO/seed.txt"
git -C "$FIXTURE_REPO" add -A
git -C "$FIXTURE_REPO" commit -q -m seed
git -C "$FIXTURE_REPO" remote add origin "$FIXTURE_ORIGIN"
git -C "$FIXTURE_REPO" push -q -u origin main

push_ref_at_date() {
  local ref="$1" date="$2" base tree commit
  base="$(git -C "$FIXTURE_REPO" rev-parse origin/main)"
  tree="$(git -C "$FIXTURE_REPO" rev-parse "$base^{tree}")"
  commit="$(GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
    git -C "$FIXTURE_REPO" commit-tree "$tree" -p "$base" -m "fixture $ref")"
  git -C "$FIXTURE_REPO" push -q origin "$commit:refs/heads/$ref"
}

# run_once <labels> [prior_state_json] -- seeds AGENT_HOME/state, runs
# run-recut.sh live (not --dry-run).
run_once() {
  local labels="$1" prior_state agent_home stale_after_snapshot="${3:-0}" fake_reason_file="${5:-}"
  local hand_issue="${7:-$N}" hand_root="${ZF_WORKTREE_ROOT:-$HOME/wt}" hand_wt stat_line rest owner_pid owner_ticks
  owner_pid="$$"
  IFS= read -r stat_line < "/proc/$owner_pid/stat"
  rest="${stat_line##*) }"
  owner_ticks="$(awk '{print $20}' <<< "$rest")"
  hand_wt="$hand_root/hand-$hand_issue"
  if [ $# -ge 2 ]; then prior_state="$2"; else prior_state='{"attempts":0}'; fi
  agent_home="$(mktemp -d)"
  TMP_DIRS+=("$agent_home")
  mkdir -p "$agent_home/state"
  echo "$prior_state" > "$agent_home/state/$hand_issue.json"
  if [ "${4:-0}" = 1 ]; then
    jq ".roles.advisor.disabled = false" "$SCRIPT_DIR/model-policy.default.json" > "$agent_home/model-policy.json"
    jq -n --argjson config "$(jq -c '.roles.work' "$agent_home/model-policy.json")" \
      --arg identity "$MODEL_POLICY_TEST_WORK_IDENTITY" \
      '{role:"work",identity:$identity,config:$config}' > "$agent_home/model-config-work.json"
  fi
  ROADMAP_TEST_ISSUE="$hand_issue" ROADMAP_TEST_TITLE="$HAND_TEST_TITLE" \
    python3 - "$agent_home/roadmap-tree.json" <<'PY'
import json, os, sys
n = int(os.environ['ROADMAP_TEST_ISSUE'])
title = os.environ['ROADMAP_TEST_TITLE']
tree = {"roots": [{"number": 900001, "title": "roadmap", "state": "open", "labels": ["roadmap"], "children": [
    {"number": 900002, "title": "theme", "state": "open", "labels": ["roadmap-theme"], "children": [
        {"number": 900003, "title": "epic", "state": "open", "labels": ["roadmap-epic"], "children": [
            {"number": n, "title": title, "state": "open", "labels": ["needs-recut"], "children": []}
        ]}
    ]}
]}]}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(tree, f)
PY

  export AGENT_HOME="$agent_home"
  export ZF_REPO_DIR="$FIXTURE_REPO"
  export FAKE_ISSUE_LABELS="$labels"
  export FAKE_ISSUE_NUMBER="$hand_issue"
  export FAKE_ISSUE_TITLE="$HAND_TEST_TITLE"
  export FAKE_ISSUE_BODY="$HAND_TEST_BODY"
  export FAKE_HAND_PR_JSON="$HAND_TEST_PR_JSON"
  export FAKE_HAND_PR_HEAD="$HAND_TEST_PR_HEAD"
  export FAKE_HAND_ENQUEUE_EXIT="$HAND_TEST_ENQUEUE_EXIT"
  export FAKE_RECUIT_STALE_AFTER_SNAPSHOT="$stale_after_snapshot"
  export FAKE_RECUIT_REASON_FILE="$fake_reason_file"
  export ZF_ROADMAP_TREE_CACHE_FILE="${agent_home}/roadmap-tree.json"
  export FAKE_RECUIT_PRODUCTION_ACCESS="${6:-__omit__}"
  export FAKE_GH_LOG="$agent_home/gh.log"
  export FAKE_RECUIT_SCHEMA_FILE="$agent_home/recut-schema.json"
  export FAKE_RECUIT_ARGS_FILE="$agent_home/recut-args.txt"
  export FAKE_RECUIT_INPUT="$agent_home/recut-input.txt"
  export FAKE_HAND_ENQUEUE_LOG="$agent_home/hand-enqueue.log"
  mkdir -p "$agent_home/night" "$hand_root"
  if [[ "$HAND_TEST_OWNER_MODE" == running || "$HAND_TEST_OWNER_MODE" == worktree ]]; then
    # Both roster and worktree ownership require a live Codex argv match.
    mkfifo "$agent_home/owner-ready" "$agent_home/owner-control"
    cat > "$agent_home/codex" <<'OWNER'
#!/usr/bin/env bash
printf 'ready\n' > "${0%/*}/owner-ready"
exec 3<> "${0%/*}/owner-control"
read -r _ <&3
OWNER
    bash "$agent_home/codex" exec --json --cd "$hand_wt" &
    owner_pid=$!
    HAND_TEST_OWNER_PIDS+=("$owner_pid")
    read -r _ < "$agent_home/owner-ready"
    IFS= read -r stat_line < "/proc/$owner_pid/stat"
    rest="${stat_line##*) }"
    owner_ticks="$(awk '{print $20}' <<< "$rest")"
  fi
  case "$HAND_TEST_OWNER_MODE" in
    queue)
      mkdir -p "$agent_home/night"
      printf 'hand-%s\t%s\tbrief\tnote\n' "$hand_issue" "$hand_wt" > "$agent_home/night/supervisor-dispatch-queue.tsv"
      ;;
    running)
      mkdir -p "$agent_home/night"
      printf '%s\thand-%s\tmodel\teffort\t%s\tbrief\treport\tlog\t0\t1\twork\t%s\t%s\n' \
        "$owner_pid" "$hand_issue" "$hand_wt" "$owner_ticks" "$hand_issue" > "$agent_home/night/agents.txt"
      ;;
    worktree)
      git -C "$FIXTURE_REPO" worktree add -q --detach "$hand_wt" origin/main
      git -C "$FIXTURE_REPO" worktree lock --reason \
        "hand-agent:owner_pid=$owner_pid owner_start_ticks=$owner_ticks unit=zf-hand-fixture.service" "$hand_wt"
      ;;
  esac
  : > "$FAKE_GH_LOG"
  : > "${FAKE_GH_LOG}.state-views"
  : > "$FAKE_HAND_ENQUEUE_LOG"

  # Start from the persisted failure state an advisor receives, then apply
  # its recut decision through the same transition used by both advisor paths.
  if [ "${8:-}" = advisor-recut ]; then
    bash -c 'source "$1/lib.sh"; route_to_recut "$2"' _ "$SCRIPT_DIR" "$hand_issue"
  fi
  set +e
  RUN_OUTPUT="$(bash "$RECUT_SRC" "$hand_issue" 2>&1)"
  RUN_STATUS=$?
  set -e
  if [ "$RUN_STATUS" -ne 0 ] && jq -e '.guarded == true' <<< "$prior_state" >/dev/null 2>&1; then
    printf 'debug - run-recut issue=%s failed: %s\n' "$hand_issue" "$RUN_OUTPUT"
  fi
  GH_LOG_CONTENT="$(cat "$FAKE_GH_LOG" 2>/dev/null || true)"
  STATE_CONTENT="$(cat "$agent_home/state/$hand_issue.json" 2>/dev/null || true)"
  INBOX_CONTENT="$(cat "$agent_home/supervisor-inbox" 2>/dev/null || true)"
  SCHEMA_CONTENT="$(cat "$FAKE_RECUIT_SCHEMA_FILE" 2>/dev/null || true)"
  RECUIT_INPUT_CONTENT="$(cat "$FAKE_RECUIT_INPUT" 2>/dev/null || true)"
  RECUIT_ARGS_CONTENT="$(cat "$FAKE_RECUIT_ARGS_FILE" 2>/dev/null || true)"
  SPEND_CONTENT="$(cat "$agent_home"/spend/*.log 2>/dev/null || true)"
  HAND_ENQUEUE_CONTENT="$(cat "$FAKE_HAND_ENQUEUE_LOG" 2>/dev/null || true)"
  local brief_path
  brief_path="$(awk -F '\t' 'NR == 1 {print $3}' "$FAKE_HAND_ENQUEUE_LOG" 2>/dev/null || true)"
  HAND_BRIEF_CONTENT="$(cat "$brief_path" 2>/dev/null || true)"
  if [ -e "$hand_wt" ] || [ -L "$hand_wt" ]; then HAND_TEST_WORKTREES+=("$hand_wt"); fi
}

# --- precondition: not labeled needs-recut -> refuses, no worktree/claude --
run_once "needs-recut" '{"attempts":0}' 0 1
assert_eq "configured model fault keeps recut queued" 0 "$RUN_STATUS"
assert_contains "configured model fault names blocked identity" "$RUN_OUTPUT" 'model configuration fault remains'
assert_eq "configured model fault makes no recut model call" "" "$SPEND_CONTENT"

run_once "ready-for-human"
assert_eq "not labeled needs-recut: exits 1" "1" "$RUN_STATUS"
assert_contains "...names needs-recut, not ready-for-human, as the required label" \
  "$RUN_OUTPUT" "not labeled needs-recut"
assert_eq "...no gh mutation" "" "$GH_LOG_CONTENT"

# --- precondition: labeled the OLD entry label alone is no longer enough ---
run_once "ready-for-human bug"
assert_eq "labeled ready-for-human but not needs-recut: exits 1" "1" "$RUN_STATUS"

# --- idempotency: already has a recorded verdict -> skip, no mutation ------
run_once "needs-recut" '{"attempts":0,"recut_refused_at":"2026-01-01T00:00:00Z"}'
assert_eq "already-refused parent: exits 0 (skip, not re-run)" "0" "$RUN_STATUS"
assert_eq "...no gh mutation" "" "$GH_LOG_CONTENT"

# --- a refusal or a recorded verdict completes the recut unit (issue 2040) --
ACTIVE_RECUT='"model_policy":{"unit":"recut","step":"work","active":{"unit":"recut","step":"work","dispatched_at":"2026-10-03T15:28:52Z"}}'
run_once "needs-recut" "{\"attempts\":0,\"recut_refused_at\":\"2026-01-01T00:00:00Z\",$ACTIVE_RECUT}"
assert_eq "recorded verdict: exits 0" "0" "$RUN_STATUS"
assert_eq "...clears the recut active marker" "false" "$(echo "$STATE_CONTENT" | jq '.model_policy | has("active")')"
run_once "needs-recut" "{\"attempts\":0,\"risk_class\":\"P1\",\"level\":\"L2\",$ACTIVE_RECUT}"
assert_eq "dispatchable classification refusal: exits 0" "0" "$RUN_STATUS"
assert_eq "...clears the recut active marker" "false" "$(echo "$STATE_CONTENT" | jq '.model_policy | has("active")')"
run_once "needs-recut" '{"attempts":0,"risk_class":"P1","level":"L2","size_admission":{"kind":"size-admission","lines":801,"limit":800,"branch":"agent/issue-90043","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
assert_eq "measured oversized P1/L2 enters recut: exits 0" "0" "$RUN_STATUS"
assert_contains "...actually runs recut despite its risk classification" "$SPEND_CONTENT" $'\trecut\t'
assert_contains "...recut sees measured changed lines" "$(cat "$FAKE_RECUIT_INPUT")" '"lines":801'
assert_contains "...recut sees the source branch and exact head" "$(cat "$FAKE_RECUIT_INPUT")" '"branch":"agent/issue-90043","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
run_once "needs-recut" '{"state":"needs-advisor","risk_class":"P1","level":"L2","model_policy":{"failure":{"unit":"recut"}},"size_admission":{"kind":"size-admission","lines":801,"limit":800,"branch":"agent/issue-90043","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' 0 0 '' __omit__ "$N" advisor-recut
assert_eq "advisor recut retry exits 0" "0" "$RUN_STATUS"
assert_contains "...retry still runs the recut on its measured evidence" "$SPEND_CONTENT" $'\trecut\t'
assert_contains "...retry passes the measured evidence to recut" "$(cat "$FAKE_RECUIT_INPUT")" '"lines":801'
run_once "needs-recut" '{"attempts":0,"risk_class":"P1","level":"L2","size_admission":{"kind":"size-admission","lines":800,"limit":800,"branch":"agent/issue-90043","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
assert_eq "exactly-at-limit P1/L2 keeps ordinary classification" "" "$SPEND_CONTENT"

# --- labeled needs-recut, categorically oversized, model refuses: climbs ---
# --- to the guarded rung (2026-09-15 ladder) -- a ticket that cannot be ---
# --- split is exactly the case for policy-resolved implementation/review. --
run_once "needs-recut" '{"attempts":0,"risk_class":"P2","level":"L4","brief_md":"旧简报：维持 ready-for-human。"}'
assert_eq "needs-recut, model refuses: exits 0" "0" "$RUN_STATUS"
assert_contains "...records the recut model call" "$SPEND_CONTENT" $'\trecut\t'
assert_eq "recut spend row records tokens used" 1 "$(awk -F '\t' '$2 == "recut" {print $6}' <<< "$SPEND_CONTENT")"
assert_contains "schema string sent to model includes production access flag" \
  "$SCHEMA_CONTENT" '"needs_production_access"'
assert_contains "recut schema uses the target config override" "$RECUIT_ARGS_CONTENT" "$ZF_CONFIG_ROOT/prompts/recut.schema.json"
assert_contains "recut prompt uses the target config override" "$RECUIT_INPUT_CONTENT" 'CONFIG_RECUT_PROMPT_OVERRIDE'
assert_contains "schema describes work outside repository checkout" \
  "$SCHEMA_CONTENT" "outside this repository checkout"
assert_contains "...removes needs-recut" "$GH_LOG_CONTENT" "--remove-label needs-recut"
assert_contains "...admits at the guarded rung (ready-for-agent)" \
  "$GH_LOG_CONTENT" "--add-label ready-for-agent"
assert_not_contains "...never ready-for-human -- a refusal is not a stop" \
  "$GH_LOG_CONTENT" "--add-label ready-for-human"
assert_contains "...posts the refusal reason inside the guarded comment" "$GH_LOG_CONTENT" "没有找到对应的真实实现"
assert_contains "...and says it is guarded" "$GH_LOG_CONTENT" "加强看护"
assert_eq "...records recut_refused_at" "true" "$(echo "$STATE_CONTENT" | jq 'has("recut_refused_at")')"
assert_contains "...persists recut refusal reason for blocker recovery" \
  "$(echo "$STATE_CONTENT" | jq -r '.recut_refused_reason')" "没有找到对应的真实实现"
assert_eq "...state carries guarded: true" "true" "$(echo "$STATE_CONTENT" | jq -r '.guarded')"
assert_eq "...state moves to ready-for-agent" "ready-for-agent" "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_eq "...the stored classification is kept" "P2" "$(echo "$STATE_CONTENT" | jq -r '.risk_class')"
if [[ "$(echo "$STATE_CONTENT" | jq -r '.brief_md')" == *"加强看护"*"维持 ready-for-human"* ]]; then
  echo "ok - ...the guarded banner precedes the stale brief conclusion"
else
  echo "not ok - ...the guarded banner precedes the stale brief conclusion"
  FAILED=1
fi

# --- a guarded repeat carries the refusal into the scheduler handoff ---
run_once "needs-recut" '{"attempts":0,"risk_class":"P2","level":"L4","guarded":true}'
assert_eq "guarded repeat refusal exits successfully" "0" "$RUN_STATUS"
assert_contains "guarded repeat refusal returns to implement" \
  "$GH_LOG_CONTENT" "--add-label ready-for-agent"
assert_contains "guarded repeat refusal holds the issue" "$GH_LOG_CONTENT" "--add-label on-hold"
assert_eq "guarded repeat clears the temporary hold after handoff" "ready-for-agent" \
  "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_eq "guarded repeat releases hold ownership" "null" "$(echo "$STATE_CONTENT" | jq -r '.hold')"
assert_contains "guarded repeat handoff preserves the refusal" "$GH_LOG_CONTENT" '没有找到对应的真实实现'

# --- a production-access refusal is held for the supervisor, not implement ---
# The hot-fix mechanism closed on 2026-10-04: no hotfix label, and the supervisor inbox is told.
run_once "needs-recut" '{"attempts":0,"risk_class":"P2","level":"L4"}' "0" "0" "" "true"
assert_eq "production-access refusal exits successfully" "0" "$RUN_STATUS"
assert_not_contains "production-access refusal adds no hotfix label" "$GH_LOG_CONTENT" "--add-label hotfix"
assert_contains "production-access refusal wakes the supervisor" "$INBOX_CONTENT" "production-access issue=#"
assert_eq "production-access refusal is held for the supervisor" "supervisor" \
  "$(echo "$STATE_CONTENT" | jq -r '.hold.holder')"
assert_contains "production-access refusal holds issue" "$GH_LOG_CONTENT" "--add-label on-hold"
assert_contains "production-access hold removes needs-recut stage" \
  "$GH_LOG_CONTENT" "--remove-label needs-recut"
assert_not_contains "production-access refusal does not queue implement" \
  "$GH_LOG_CONTENT" "--add-label ready-for-agent"
assert_eq "production-access refusal flag is durable" "true" \
  "$(echo "$STATE_CONTENT" | jq -r '.recut_needs_production_access')"
assert_eq "production-access refusal hold kind is production-access" "production-access" \
  "$(echo "$STATE_CONTENT" | jq -r '.hold.kind')"
assert_eq "production-access refusal state is on-hold" "on-hold" \
  "$(echo "$STATE_CONTENT" | jq -r '.state')"

# The older output shape (no flag) remains a normal guarded refusal.
run_once "needs-recut" '{"attempts":0,"risk_class":"P2","level":"L4"}'
assert_eq "refusal without production flag exits successfully" "0" "$RUN_STATUS"
assert_contains "refusal without production flag still queues implement" \
  "$GH_LOG_CONTENT" "--add-label ready-for-agent"
assert_eq "refusal without production flag stores false" "false" \
  "$(echo "$STATE_CONTENT" | jq -r '.recut_needs_production_access')"

# A refusal reason can exceed Linux MAX_ARG_STRLEN. Persist it through jq's
# --rawfile path and keep the guarded GitHub comment on --body-file too.
LONG_REASON_FILE="$(mktemp)"
TMP_DIRS+=("$LONG_REASON_FILE")
printf '没有找到对应的真实实现：' > "$LONG_REASON_FILE"
head -c 140000 /dev/zero | tr '\000' x >> "$LONG_REASON_FILE"
LONG_REASON_BYTES="$(wc -c < "$LONG_REASON_FILE" | tr -d ' ')"
run_once "needs-recut" '{"attempts":0}' "0" "0" "$LONG_REASON_FILE"
assert_eq "refusal reason beyond MAX_ARG_STRLEN persists" \
  "$((LONG_REASON_BYTES + 1))" "$(jq -r '.recut_refused_reason' <<< "$STATE_CONTENT" | wc -c | tr -d ' ')"
assert_contains "long refusal comment uses a body file" "$GH_LOG_CONTENT" "没有找到对应的真实实现"

# --- an untriaged parent (no classification at all) refused: guarded, ------
# --- classification left unset so the scheduler measures it first --------
run_once "needs-recut" '{"attempts":0}'
assert_eq "untriaged parent refused: exits 0" "0" "$RUN_STATUS"
assert_contains "...still admits guarded" "$GH_LOG_CONTENT" "--add-label ready-for-agent"
assert_eq "...leaves risk_class unset (unmeasured, to be measured under the label)" \
  "false" "$(echo "$STATE_CONTENT" | jq 'has("risk_class")')"
assert_eq "...guarded: true survives for that later dispatch" "true" "$(echo "$STATE_CONTENT" | jq -r '.guarded')"

# A refusal is also a verdict. If parent closes after the recut snapshot,
# discard refusal side effects and preserve supervisor's released label.
run_once "needs-recut" '{"attempts":0}' 1
assert_eq "closed parent discards recut refusal: exits 0" "0" "$RUN_STATUS"
assert_contains "closed parent refusal logs why it was skipped" "$RUN_OUTPUT" "issue is closed"
assert_not_contains "closed parent receives no recut label write" "$GH_LOG_CONTENT" "issue edit"
assert_not_contains "closed parent receives no recut comment or child" "$GH_LOG_CONTENT" "issue comment"
assert_not_contains "closed parent creates no child issue" "$GH_LOG_CONTENT" "issue create"
assert_eq "closed parent stores no recut refusal" "false" "$(echo "$STATE_CONTENT" | jq 'has("recut_refused_at")')"

# A guarded repeat returns to the scheduler with prior work referenced.
PR_ISSUE=90044
push_ref_at_date "agent/issue-$PR_ISSUE" "2026-10-03T00:00:00Z"
HAND_TEST_PR_HEAD="agent/issue-$PR_ISSUE"
HAND_TEST_PR_JSON="$(jq -cn --arg branch "$HAND_TEST_PR_HEAD" \
  '[{number:944,title:"Existing PR",url:"https://example.invalid/pull/944",headRefName:$branch}]')"
HAND_TEST_TITLE="candidate image fix"
HAND_TEST_BODY="Build Dockerfile candidate image and verify it on cihost."
run_once "needs-recut" '{"attempts":0,"risk_class":"P1","level":"L2","guarded":true}' "0" "0" "" "__omit__" "$PR_ISSUE"
assert_eq "guarded repeat with PR exits successfully" "0" "$RUN_STATUS"
assert_eq "guarded repeat becomes ready" ready-for-agent "$(jq -r '.state' <<< "$STATE_CONTENT")"
assert_contains "handoff retains existing PR URL" "$GH_LOG_CONTENT" 'https://example.invalid/pull/944'
assert_contains "handoff retains refusal reason" "$GH_LOG_CONTENT" 'Latest recut finding'
assert_eq "guarded repeat does not enqueue a hand" "" "$HAND_ENQUEUE_CONTENT"

STALE_ISSUE=90071
push_ref_at_date "agent/issue-$STALE_ISSUE" "2026-10-03T00:00:00Z"
git -C "$FIXTURE_REPO" branch "hand-$STALE_ISSUE" origin/main
STALE_BRANCH_TIP="$(git -C "$FIXTURE_REPO" rev-parse "hand-$STALE_ISSUE")"
HAND_TEST_PR_HEAD="agent/issue-$STALE_ISSUE"
HAND_TEST_PR_JSON="$(jq -cn --arg branch "$HAND_TEST_PR_HEAD" '[{number:946,url:"https://example.invalid/pull/946",headRefName:$branch}]')"
run_once "needs-recut" '{"attempts":0,"risk_class":"P1","level":"L2","guarded":true}' "0" "0" "" "__omit__" "$STALE_ISSUE"
assert_eq "stale branch does not prevent scheduler handoff" "0" "$RUN_STATUS"
assert_eq "old hand branch remains untouched" "$STALE_BRANCH_TIP" "$(git -C "$FIXTURE_REPO" rev-parse "hand-$STALE_ISSUE")"

RESCUE_ISSUE=90045
push_ref_at_date "rescued/agent-issue-$RESCUE_ISSUE-old" "2026-10-01T00:00:00Z"
push_ref_at_date "rescued/agent-issue-$RESCUE_ISSUE-new" "2026-10-02T00:00:00Z"
HAND_TEST_PR_HEAD=''; HAND_TEST_PR_JSON='[]'
run_once "needs-recut" '{"attempts":0,"risk_class":"P2","level":"L4","guarded":true}' "0" "0" "" "__omit__" "$RESCUE_ISSUE"
assert_eq "guarded repeat with rescued work exits successfully" "0" "$RUN_STATUS"
assert_contains "handoff keeps newest rescued ref" "$GH_LOG_CONTENT" "origin/rescued/agent-issue-$RESCUE_ISSUE-new"
assert_contains "handoff keeps older rescued ref" "$GH_LOG_CONTENT" "origin/rescued/agent-issue-$RESCUE_ISSUE-old"
assert_eq "scheduler starts from newest rescued ref" "rescued/agent-issue-$RESCUE_ISSUE-new" "$(jq -r '.scheduler_handoff.start_ref' <<< "$STATE_CONTENT")"
assert_eq "scheduler pins rescued commit" "$(git -C "$FIXTURE_REPO" rev-parse "origin/rescued/agent-issue-$RESCUE_ISSUE-new")" "$(jq -r '.scheduler_handoff.start_sha' <<< "$STATE_CONTENT")"

NO_BRANCH_ISSUE=90046
run_once "needs-recut" '{"attempts":0,"risk_class":"P2","level":"L4","guarded":true}' "0" "0" "" "__omit__" "$NO_BRANCH_ISSUE"
assert_eq "no-branch guarded refusal returns to scheduler" "0" "$RUN_STATUS"
assert_eq "no-branch handoff uses the main checkout" null "$(jq -r '.scheduler_handoff.start_ref // null' <<< "$STATE_CONTENT")"
assert_eq "no-branch handoff retains its episode" true "$(jq -r '(.scheduler_handoff.episode // "" | length) > 0' <<< "$STATE_CONTENT")"

git -C "$FIXTURE_REPO" remote set-url origin "$FIXTURE_ORIGIN/missing-remote"
run_once "needs-recut" '{"attempts":0,"risk_class":"P2","level":"L4","guarded":true}' "0" "0" "" "__omit__" "90050"
git -C "$FIXTURE_REPO" remote set-url origin "$FIXTURE_ORIGIN"
assert_eq "failed rescue discovery is surfaced" "1" "$RUN_STATUS"
assert_eq "failed rescue discovery keeps the hold" on-hold "$(jq -r '.state' <<< "$STATE_CONTENT")"

for owner_case in queue running worktree; do
  case "$owner_case" in queue) owned_issue=90047 ;; running) owned_issue=90048 ;; worktree) owned_issue=90049 ;; esac
  HAND_TEST_OWNER_MODE="$owner_case"
  run_once "needs-recut" '{"attempts":0,"risk_class":"P2","level":"L4","guarded":true}' "0" "0" "" "__omit__" "$owned_issue"
  assert_eq "$owner_case never enqueues a retired hand" "" "$HAND_ENQUEUE_CONTENT"
  if [[ "$owner_case" == queue ]]; then
    assert_eq "retired queue row does not block scheduler" ready-for-agent "$(jq -r '.state' <<< "$STATE_CONTENT")"
  else
    assert_eq "$owner_case live owner keeps hold" on-hold "$(jq -r '.state' <<< "$STATE_CONTENT")"
  fi
done
HAND_TEST_OWNER_MODE=''

# The loop breaker still holds the issue, so repeated labels do not re-enter work.
make_loop_timeline() {
  local offset="$1"
  jq -nc \
    --arg t1 "$(date -u -d "$((50 - offset)) minutes ago" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg t2 "$(date -u -d "$((40 - offset)) minutes ago" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg t3 "$(date -u -d "$((30 - offset)) minutes ago" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg t4 "$(date -u -d "$((20 - offset)) minutes ago" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg t5 "$(date -u -d "$((10 - offset)) minutes ago" +%Y-%m-%dT%H:%M:%SZ)" \
    '[[$t1,"ready-for-agent"],[$t2,"needs-advisor"],[$t3,"ready-for-agent"],[$t4,"needs-advisor"],[$t5,"ready-for-agent"]] | map({event:"labeled",created_at:.[0],label:{name:.[1]}})'
}
LOOP_AGENT_HOME="$(mktemp -d)"; TMP_DIRS+=("$LOOP_AGENT_HOME")
mkdir -p "$LOOP_AGENT_HOME/state" "$LOOP_AGENT_HOME/night"
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$LOOP_AGENT_HOME/model-policy.json"
push_ref_at_date "agent/issue-90051" "2026-10-03T00:00:00Z"
export AGENT_HOME="$LOOP_AGENT_HOME" ZF_REPO_DIR="$FIXTURE_REPO" FAKE_ISSUE_NUMBER=90051
export FAKE_ISSUE_LABELS="ready-for-agent needs-advisor" FAKE_ISSUE_TIMELINE_JSON="$(make_loop_timeline 0)"
export FAKE_GH_LOG="$LOOP_AGENT_HOME/gh.log" FAKE_ISSUE_HOLD_LIFT=''
export FAKE_HAND_PR_HEAD='agent/issue-90051' FAKE_HAND_PR_JSON='[{"number":951,"url":"https://example.invalid/pull/951","headRefName":"agent/issue-90051"}]'
printf '%s\n' '{"attempts":0,"brief_md":"loop-root-cause-marker","last_failure_tail":"loop-review-marker","advisor_last_verdict":{"material":"loop-advisor-marker"}}' > "$AGENT_HOME/state/90051.json"
LOOP_RUN_STATUS=0
LOOP_RUN_OUTPUT="$(bash -c 'source "$1/lib.sh"; loop_break_check "$2" ready-for-agent needs-advisor' _ "$SCRIPT_DIR" 90051 2>&1)" || LOOP_RUN_STATUS=$?
assert_eq "loop escalation succeeds" 0 "$LOOP_RUN_STATUS"
assert_eq "first loop escalation resumes via scheduler" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/90051.json")"
assert_contains "loop escalation notifies supervisor" "$(cat "$AGENT_HOME/supervisor-inbox")" 'label-churn issue=#90051'
assert_contains "loop handoff retains current review" "$(cat "$AGENT_HOME/gh.log")" 'loop-review-marker'
assert_contains "loop handoff retains advisor finding" "$(cat "$AGENT_HOME/gh.log")" 'loop-advisor-marker'
assert_contains "loop handoff retains existing PR" "$(cat "$AGENT_HOME/gh.log")" 'https://example.invalid/pull/951'
export FAKE_ISSUE_TIMELINE_JSON="$(make_loop_timeline 10)"
LOOP_RUN_STATUS=0
LOOP_RUN_OUTPUT="$(bash -c 'source "$1/lib.sh"; loop_break_check "$2" ready-for-agent needs-advisor' _ "$SCRIPT_DIR" 90051 2>&1)" || LOOP_RUN_STATUS=$?
assert_eq "repeat loop escalation succeeds" 0 "$LOOP_RUN_STATUS"
assert_eq "repeat loop stays on hold within 24 hours" on-hold "$(jq -r '.state' "$AGENT_HOME/state/90051.json")"
assert_eq "loop escalation creates no retired hand queue" false "$([ -s "$AGENT_HOME/night/supervisor-dispatch-queue.tsv" ] && echo true || echo false)"

# Budget refusal leaves issue eligible and never launches Codex.
budget_issue=90044
CODEX_DAILY_TOKEN_BUDGET=100 CODEX_PRODUCTION_TOKEN_RESERVE=10 \
CODEX_BUDGET_RESERVATION_TOKENS=100 CODEX_PRODUCTION_RESERVATION_TOKENS=10 \
CODEX_HAND_DISPATCH_RESERVATION_TOKENS=90 run_once "needs-recut" '{"attempts":0}' 0 0 "" "" "$budget_issue"
assert_eq "budget-refused recut exits cleanly" 0 "$RUN_STATUS"
assert_contains "budget-refused recut reports deferral" "$RUN_OUTPUT" 'Codex budget/provider hold'
assert_eq "budget-refused recut records no model spend" "" "$SPEND_CONTENT"
assert_eq "budget-refused recut does not bump issue attempts" 0 "$(jq -r '.attempts' <<< "$STATE_CONTENT")"

if [ "$FAILED" -eq 1 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS"
