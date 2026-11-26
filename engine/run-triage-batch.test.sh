#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BATCH_SRC="$SCRIPT_DIR/run-triage-batch.sh"
# shellcheck source=./lib.d/triage-solo.sh
source "$SCRIPT_DIR/lib.d/triage-solo.sh"
TEST_ROOT="$(mktemp -d)"
ZF_CONFIG_ROOT="$TEST_ROOT/repo/.zenoforge"
mkdir -p "$ZF_CONFIG_ROOT/prompts"
cp "$SCRIPT_DIR/prompts/triage.md" "$ZF_CONFIG_ROOT/prompts/triage.md"
printf '\nCONFIG_TRIAGE_BATCH_PROMPT_OVERRIDE\n' >> "$ZF_CONFIG_ROOT/prompts/triage.md"
cp "$SCRIPT_DIR/prompts/triage.schema.json" "$ZF_CONFIG_ROOT/prompts/triage.schema.json"
cp "$SCRIPT_DIR/prompts/agent-settings.json" "$ZF_CONFIG_ROOT/prompts/agent-settings.json"
export ZF_CONFIG_ROOT; unset MAC_AUTOPILOT_RUNTIME_DIR
export AGENT_HOME="$TEST_ROOT/agent"
export ZF_REPO_DIR="$TEST_ROOT/repo"
export REPO="test/repo"
export ZF_REPO="$REPO"
mkdir -p "$HOME/wt" "$AGENT_HOME/state" "$AGENT_HOME/night"
jq -n '{founder_login:"maintainer"}' > "$AGENT_HOME/recipients.json"
for n in 910301 910302 910303 910401 910504 910505 910506 910507 910508 910509 910703 910901 910903 910904 \
  911001 911002 911003 911004 911005 911101 911102 911103 911104 911111 911112 911113 911114 911121 911122 \
  911131 911132 911133 911141 911501 911502 911503 911511 911512 911531 \
  911551 911552 911553 911561 911562 911563 911571 911572 911573; do
  if [ -e "$HOME/wt/triage-$n" ]; then
    echo "run-triage-batch.test: refusing to overwrite existing worktree $HOME/wt/triage-$n" >&2
    exit 2
  fi
done

FAILED=0
cleanup() {
  if [ -e "$ZF_REPO_DIR/.git" ]; then
    while IFS= read -r worktree; do
      case "$worktree" in
        "$HOME/wt/triage-batch-run-"*|"$HOME/wt/triage-911"*|"$HOME/wt/triage-910301"|"$HOME/wt/triage-910302"|"$HOME/wt/triage-910303"|"$HOME/wt/triage-910401"|"$HOME/wt/triage-910504"|"$HOME/wt/triage-910505"|"$HOME/wt/triage-910506"|"$HOME/wt/triage-910507"|"$HOME/wt/triage-910508"|"$HOME/wt/triage-910509"|"$HOME/wt/triage-910703"|"$HOME/wt/triage-910901"|"$HOME/wt/triage-910903"|"$HOME/wt/triage-910904")
          git -C "$ZF_REPO_DIR" worktree remove --force "$worktree" >/dev/null 2>&1 || true
          ;;
      esac
    done < <(git -C "$ZF_REPO_DIR" worktree list --porcelain | sed -n 's/^worktree //p')
  fi
  rm -rf -- "$TEST_ROOT"
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
    echo "not ok - $desc (unexpectedly found [$needle])"
    FAILED=1
  fi
}

# A tiny local origin lets the wrapper exercise its normal worktree lifecycle
# without touching another checkout or GitHub.
FIXTURE_ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$ZF_REPO_DIR"
git init -q --bare "$FIXTURE_ORIGIN"
git --git-dir="$FIXTURE_ORIGIN" symbolic-ref HEAD refs/heads/main
git -C "$ZF_REPO_DIR" init -q -b main
git -C "$ZF_REPO_DIR" config user.email test@example.com
git -C "$ZF_REPO_DIR" config user.name Test
printf 'seed\n' > "$ZF_REPO_DIR/seed.txt"
git -C "$ZF_REPO_DIR" add seed.txt
git -C "$ZF_REPO_DIR" commit -q -m seed
git -C "$ZF_REPO_DIR" remote add origin "$FIXTURE_ORIGIN"
git -C "$ZF_REPO_DIR" push -q -u origin main
mkdir -p "$ZF_REPO_DIR/.gitnexus" "$ZF_REPO_DIR/engine/state"
jq -n --arg sha "$(git -C "$ZF_REPO_DIR" rev-parse HEAD)" '{lastCommit:$sha}' > "$ZF_REPO_DIR/.gitnexus/meta.json"
cp "$SCRIPT_DIR/state/rulings.json" "$ZF_REPO_DIR/engine/state/rulings.json"
mkdir -p "$ZF_REPO_DIR/.agents/skills/triage" && : > "$ZF_REPO_DIR/.agents/skills/triage/SKILL.md" # untracked: in $REPO_DIR, not in the origin/main worktree the agent runs in
# Stage-routing fixture; roadmap admission is covered by roadmap-order.test.sh.
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export FAKE_GH_LOG="$TEST_ROOT/gh.log"
export FAKE_CODEX_OUTPUT="$TEST_ROOT/codex-output.ndjson"
export FAKE_CODEX_ARGS="$TEST_ROOT/codex-args.log"
export FAKE_PROMPT_CAPTURE="$TEST_ROOT/codex-prompt.txt"
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
case "$1 ${2:-}" in
  "issue view")
    n="$3"
    if [ -n "${FAKE_ISSUE_JSON_FILE:-}" ] && [ "$n" = "${FAKE_ISSUE_JSON_NUMBER:-}" ]; then
      cat "$FAKE_ISSUE_JSON_FILE"
      exit 0
    fi
    labels='[{"name":"needs-triage"},{"name":"enhancement"}]'
    if [ "${FAKE_ISSUE_READY_FOR_AGENT:-}" = "$n" ]; then
      labels='[{"name":"ready-for-agent"},{"name":"enhancement"}]'
    fi
    state=OPEN
    view_count_file="${FAKE_GH_LOG}.views.$n"
    view_count="$(cat "$view_count_file" 2>/dev/null || echo 0)"
    view_count=$((view_count + 1))
    printf '%s\n' "$view_count" > "$view_count_file"
    fail_from="$(cat "${FAKE_GH_LOG}.view-fail-from.$n" 2>/dev/null || echo 0)"
    case "$fail_from" in ''|*[!0-9]*) fail_from=0 ;; esac
    if [ "$fail_from" -gt 0 ] && [ "$view_count" -ge "$fail_from" ]; then
      echo "run-triage-batch.test: fake gh issue view #$n fails (view $view_count >= $fail_from)" >&2
      exit 1
    fi
    if [ -f "${FAKE_GH_LOG}.view-error.$n" ]; then
      cat "${FAKE_GH_LOG}.view-error.$n" >&2
      exit 1
    fi
    # Queue row 919 fixture: hold one issue's apply-time reread (view >= 2)
    # while the gate file exists; the marker tells the test the batch is
    # inside that view, mid-apply. The cap keeps a lost test from hanging.
    if [ "$view_count" -ge 2 ] && [ "${FAKE_GH_VIEW_HANG_ISSUE:-}" = "$n" ] \
      && [ -n "${FAKE_GH_VIEW_HANG_MARKER:-}" ] && [ -e "${FAKE_GH_VIEW_HANG_GATE:-}" ]; then
      printf 'view hang\n' > "$FAKE_GH_VIEW_HANG_MARKER"
      hang_waits=0
      while [ -e "$FAKE_GH_VIEW_HANG_GATE" ] && [ "$hang_waits" -lt 600 ]; do
        sleep 0.1
        hang_waits=$((hang_waits + 1))
      done
    fi
    if [ "${FAKE_ON_HOLD_ISSUE:-}" = "$n" ]; then
      labels='[{"name":"needs-triage"},{"name":"enhancement"},{"name":"on-hold"}]'
    fi
    if [ "${FAKE_STALE_BATCH_ISSUE:-}" = "$n" ] && [ "$view_count" -gt 1 ]; then
      state=CLOSED
      labels='[{"name":"priority:top"},{"name":"released"}]'
    fi
    if [ -e "${FAKE_GH_LOG}.founder-test.$n" ]; then
      labels="$(jq -c '. + [{name:"founder-test"}]' <<< "$labels")"
    fi
    updated_at="${FAKE_ISSUE_UPDATED_AT:-2026-01-01T00:00:00Z}"
    if [ "$view_count" -gt 1 ] && [ -n "${FAKE_ISSUE_UPDATED_AT_AFTER_FIRST_VIEW:-}" ]; then
      updated_at="$FAKE_ISSUE_UPDATED_AT_AFTER_FIRST_VIEW"
    fi
    jq -n --argjson n "$n" --arg state "$state" --arg updated_at "$updated_at" --arg author "${FAKE_AUTHOR:-testuser}" --argjson labels "$labels" '{number:$n,title:"batch fixture",body:"fixture body",author:{login:$author},comments:[],createdAt:"2026-01-01T00:00:00Z",updatedAt:$updated_at,state:$state,labels:$labels}'
    ;;
  "issue list")
    if [[ " $* " == *" --label needs-triage "* ]]; then
      queue_count_file="${FAKE_GH_LOG}.triage-list-count"
      queue_count="$(cat "$queue_count_file" 2>/dev/null || echo 0)"
      queue_count=$((queue_count + 1))
      printf '%s\n' "$queue_count" > "$queue_count_file"
      queue_file="${FAKE_TRIAGE_QUEUE_BEFORE_FILE:-}"
      if [ "$queue_count" -gt 1 ]; then
        queue_file="${FAKE_TRIAGE_QUEUE_AFTER_FILE:-$queue_file}"
      fi
      if [ -n "$queue_file" ] && [ -f "$queue_file" ]; then
        cat "$queue_file"
      else
        echo '[]'
      fi
    elif [[ " $* " == *" --label on-hold "* && -n "${FAKE_ON_HOLD_ISSUE:-}" ]]; then
      printf '%s\n' "$FAKE_ON_HOLD_ISSUE"
    else
      echo '[]'
    fi
    ;;
  "label list")
    # --json name (intake-priority) gets a JSON array as gh prints it; -q '.[].name' gets plain names.
    if [[ " $* " == *" -q "* ]]; then printf '%s\n' needs-triage needs-info ready-for-agent ready-for-human needs-owner duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded bug enhancement founder-test
    else printf '%s\n' needs-triage needs-info ready-for-agent ready-for-human needs-owner duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded bug enhancement founder-test | jq -Rsc 'split("\n") | map(select(length > 0) | {name: .})'; fi
    ;;
  "variable get") echo 3 ;;
  "pr list") echo '[]' ;;
  "api "*)
    # The shared admission guard requires a verified native-child read.
    if [[ "${2:-}" == repos/test/repo/issues/*/sub_issues?per_page=100 ]]; then echo '[]'
    # Row 920: intake-priority's label writes (row 920 tests) land in the log like issue edit.
    elif [[ "${2:-}" == "-X" ]]; then printf '%s\n' "$*" >> "$FAKE_GH_LOG"
    else exit 1; fi ;;
  "issue edit")
    printf '%s\n' "$*" >> "$FAKE_GH_LOG"
    if [[ " $* " == *" --add-label founder-test "* ]]; then : > "${FAKE_GH_LOG}.founder-test.$3"; fi
    ;;
  "issue comment"|"issue close"|"label create") printf '%s\n' "$*" >> "$FAKE_GH_LOG" ;;
  *) : ;;
esac
exit 0
EOF
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" list-units "* ]]; then
  exit 0
fi
exit 1
EOF
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_CODEX_ARGS"
out=""
worktree=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-last-message) out="$2"; shift 2 ;;
    --cd) worktree="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > "$FAKE_PROMPT_CAPTURE"
cp "$FAKE_CODEX_OUTPUT" "$out"
if [ -n "${FAKE_CODEX_TRANSCRIPT:-}" ]; then printf '%s\n' "$FAKE_CODEX_TRANSCRIPT" >&2; fi
if [ "${FAKE_CODEX_DIRTY_WORKTREE:-0}" = 1 ]; then
  printf 'preserve me\n' > "$worktree/triage-batch-dirty.txt"
fi
printf 'tokens used\n12,345\n' >&2
exit "${FAKE_CODEX_STATUS:-0}"
EOF
cat > "$FAKE_BIN/gitnexus" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = analyze ]; then
  echo 'fixture blocks real GitNexus analyze' >&2
  exit 1
fi
echo up-to-date
EOF
chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/systemctl" "$FAKE_BIN/codex" "$FAKE_BIN/gitnexus"
export PATH="$FAKE_BIN:$PATH"
export ZF_GCLOUD_BIN=/nonexistent/gcloud
export AGENT_TRIAGE_CAP=3

valid_result() {
  jq -nc '{category:"enhancement",state:"ready-for-agent",risk_class:"P1",level:"L1",entry_surface:"Web /chat/",acceptor:"maintainer",advisor_reason:"none",brief_md:"Summary: fixture.",notes_md:"No questions.",expected_packages:["packages/react-example"],expected_paths:[],related:[],suspected_shared_cause:null,estimated_changed_lines:0}'
}
VALID="$(valid_result)"
INVALID="$(jq -c 'del(.notes_md)' <<< "$VALID")"
MALFORMED_EXTERNAL="$(jq -c '. + {external_deliverable:{required:"true",location:"example-infra manual workflow file",reason:"malformed flag"}}' <<< "$VALID")"
{
  jq -nc --argjson issue 910301 --argjson result "$VALID" '{issue:$issue,result:$result}'
  jq -nc --argjson issue 910302 --argjson result "$INVALID" '{issue:$issue,result:$result}'
  jq -nc --argjson issue 910303 --argjson result "$MALFORMED_EXTERNAL" '{issue:$issue,result:$result}'
  jq -nc --argjson issue 910304 --argjson result "$VALID" '{issue:$issue,result:$result}'
} > "$FAKE_CODEX_OUTPUT"

FAKE_TRIAGE_QUEUE_BEFORE_FILE="$TEST_ROOT/triage-before.json"
FAKE_TRIAGE_QUEUE_AFTER_FILE="$TEST_ROOT/triage-after.json"
export FAKE_TRIAGE_QUEUE_BEFORE_FILE FAKE_TRIAGE_QUEUE_AFTER_FILE
jq -n '[{number:910301,labels:[{name:"needs-triage"}]},{number:910302,labels:[{name:"needs-triage"}]},{number:910303,labels:[{name:"needs-triage"}]},
  {number:910304,labels:[{name:"needs-triage"}]},{number:910305,labels:[{name:"needs-triage"},{name:"on-hold"}]},
  {number:910306,labels:[{name:"needs-triage"},{name:"pipeline-system"}]},{number:910307,labels:[{name:"needs-triage"}]}]' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
jq -n '[{number:910302,labels:[{name:"needs-triage"}]},{number:910304,labels:[{name:"needs-triage"}]},
  {number:910305,labels:[{name:"needs-triage"},{name:"on-hold"}]},{number:910306,labels:[{name:"needs-triage"},{name:"pipeline-system"}]},
  {number:910307,labels:[{name:"needs-triage"}]}]' > "$FAKE_TRIAGE_QUEUE_AFTER_FILE"
jq -n --argjson retry "$(( $(date +%s) + 600 ))" '{triage_retry_after_epoch:$retry}' > "$AGENT_HOME/state/910307.json"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
ZF_TRIAGE_TICK_ID=triage-batch-owner-multi-ticket-9103
ZF_TRIAGE_BATCH_ID=owner-multi-ticket-9103
jq -n '{issues:[910399]}' > "$AGENT_HOME/triage-batch-active-owner-unrelated.json"
export ZF_TRIAGE_TICK_ID ZF_TRIAGE_BATCH_ID

set +e
RUN_OUTPUT="$(bash "$BATCH_SRC" --scheduled 910301 910302 910303 910304 2>&1)"
RUN_STATUS=$?
set -e

assert_eq "one bad record does not fail the batch" 0 "$RUN_STATUS"
assert_contains "batch cap defers extra issue" "$RUN_OUTPUT" 'cap=3 deferred 1 issue(s)'
assert_contains "valid records apply through single triage path" "$(cat "$FAKE_GH_LOG")" 'issue edit 910301'
assert_contains "later valid record applies after bad record" "$(cat "$FAKE_GH_LOG")" 'issue edit 910303'
assert_eq "batch result missing external field defaults to implement" ready-for-agent \
  "$(jq -r '.state' "$AGENT_HOME/state/910301.json")"
assert_not_contains "batch result missing external field avoids supervisor hold" \
  "$(jq -r '.state' "$AGENT_HOME/state/910301.json")" 'on-hold'
assert_eq "malformed batch external field defaults to implement" ready-for-agent \
  "$(jq -r '.state' "$AGENT_HOME/state/910303.json")"
assert_not_contains "malformed batch external field avoids supervisor hold" \
  "$(jq -r '.state' "$AGENT_HOME/state/910303.json")" 'on-hold'
BAD_ISSUE_EDIT="$(sed -n '/^issue edit 910302 /p' "$FAKE_GH_LOG")"
assert_not_contains "bad issue does not receive ready-for-agent verdict" "$BAD_ISSUE_EDIT" '--add-label ready-for-agent'
assert_not_contains "cap leftover is not applied" "$(cat "$FAKE_GH_LOG")" 'issue edit 910304'
assert_eq "invalid member waits for a scoped retry" true "$(jq -e --argjson now "$(date +%s)" '.model_failure_backoff.until_epoch > $now' "$AGENT_HOME/state/910302.json" >/dev/null && echo true || echo false)"
assert_eq "scoped retry names the batch result failure" run-triage-batch:triage-result "$(jq -r '.model_failure_backoff.caller' "$AGENT_HOME/state/910302.json")"
assert_eq "invalid member is marked for retry alone" true "$(jq -r '.triage_batch_retry_alone' "$AGENT_HOME/state/910302.json")"
assert_eq "invalid member does not escalate before its solo retry" null "$(jq -r '.model_policy.failure.transition // null' "$AGENT_HOME/state/910302.json")"
assert_not_contains "invalid member does not enter advisor queue" "$BAD_ISSUE_EDIT" '--add-label needs-advisor'
assert_eq "valid member receives no failure backoff" false "$(jq 'has("model_failure_backoff")' "$AGENT_HOME/state/910301.json")"
assert_eq "valid result clears retry-alone marker" false "$(jq -r '.triage_batch_retry_alone // false' "$AGENT_HOME/state/910301.json")"
assert_eq "leftover stays untouched" false "$(test -f "$AGENT_HOME/state/910304.json" && echo true || echo false)"
assert_eq "only one Codex invocation ran" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_contains "Codex uses policy work role and effort" "$(cat "$FAKE_CODEX_ARGS")" \
  "-m $MODEL_POLICY_TEST_WORK_MODEL -c model_reasoning_effort=$MODEL_POLICY_TEST_WORK_EFFORT"
assert_contains "Codex forwards policy work service tier" "$(cat "$FAKE_CODEX_ARGS")" \
  "service_tier=\"$MODEL_POLICY_TEST_WORK_TIER\""
assert_contains "one prompt includes every admitted issue" "$(cat "$FAKE_PROMPT_CAPTURE")" '## Issue #910303'
assert_contains "batch triage prompt uses the target config override" "$(cat "$FAKE_PROMPT_CAPTURE")" 'CONFIG_TRIAGE_BATCH_PROMPT_OVERRIDE'
assert_not_contains "skill path is decided from the agent worktree, not the repo checkout" "$(cat "$FAKE_PROMPT_CAPTURE")" 'triage=.agents/skills/triage/SKILL.md'
assert_contains "skills note is in the prompt" "$(cat "$FAKE_PROMPT_CAPTURE")" 'Matt skill files for this run'
assert_not_contains "deferred issue is absent from prompt" "$(cat "$FAKE_PROMPT_CAPTURE")" '## Issue #910304'
assert_eq "batch spend row records tokens used" 12345 "$(awk -F '\t' '$2 == "triage" {print $6}' "$AGENT_HOME"/spend/*.log)"
MULTI_BATCH_LOG="$(cat "$AGENT_HOME/logs/triage-triage-batch-owner-multi-ticket-9103.log")"
assert_contains "batch log stores its tick ID" "$MULTI_BATCH_LOG" 'tick_id=triage-batch-owner-multi-ticket-9103'
assert_contains "batch log stores issue sample size" "$MULTI_BATCH_LOG" 'issue_sample_size=3'
assert_contains "batch log stores total Codex tokens" "$MULTI_BATCH_LOG" 'tokens_used=12345'
assert_contains "batch log stores average tokens per issue" "$MULTI_BATCH_LOG" 'average_tokens_per_issue=4115.00'
assert_contains "batch log stores selectable count before apply" "$MULTI_BATCH_LOG" 'needs_triage_selectable_before=4'
assert_contains "batch log stores selectable count after apply" "$MULTI_BATCH_LOG" 'needs_triage_selectable_after=1'
assert_contains "batch log stores selectable count delta" "$MULTI_BATCH_LOG" 'needs_triage_selectable_delta=-3'
assert_eq "batch cleanup removes only its own active marker" false \
  "$(test -e "$AGENT_HOME/triage-batch-active-owner-multi-ticket-9103.json" && echo true || echo false)"
assert_eq "batch cleanup preserves another active marker" true \
  "$(test -e "$AGENT_HOME/triage-batch-active-owner-unrelated.json" && echo true || echo false)"
assert_eq "successful batch leaves no worktree behind" 0 "$(find "$HOME/wt" -maxdepth 1 -type d -name 'triage-batch-run-*' | wc -l | tr -d ' ')"

# One issue per call provides directly comparable single-ticket token baseline.
: > "$FAKE_CODEX_ARGS"
cp "$SCRIPT_DIR/mac-autopilot/triage-fixture.json" "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
cp "$SCRIPT_DIR/mac-autopilot/triage-fixture.json" "$FAKE_TRIAGE_QUEUE_AFTER_FILE"
fixture_until=$(( $(date +%s) + 3600 ))
export MAC_AUTOPILOT_RUNTIME_DIR="$TEST_ROOT/triage-runtime"
mkdir -p "$MAC_AUTOPILOT_RUNTIME_DIR"
jq -n --argjson until "$fixture_until" '{model_failure_backoff:{until_epoch:$until}}' > "$AGENT_HOME/state/1004.json"
jq -n --argjson until "$fixture_until" '{triage_retry_after_epoch:$until}' > "$AGENT_HOME/state/1005.json"
jq -n '{units:[{id:"issue-805",issue:805,stage:"implement-pending"}]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
jq -nc --argjson issue 910310 --argjson result "$VALID" '{issue:$issue,result:$result}' > "$FAKE_CODEX_OUTPUT"
ZF_TRIAGE_TICK_ID=triage-batch-owner-single-ticket-910310 ZF_TRIAGE_BATCH_ID=owner-single-ticket-910310 \
  bash "$BATCH_SRC" --scheduled 910310 >/dev/null 2>&1
SINGLE_BATCH_LOG="$(cat "$AGENT_HOME/logs/triage-triage-batch-owner-single-ticket-910310.log")"
assert_contains "single-ticket baseline log has sample size one" "$SINGLE_BATCH_LOG" 'issue_sample_size=1'
assert_contains "single-ticket baseline records its token count" "$SINGLE_BATCH_LOG" 'tokens_used=12345'
assert_contains "single-ticket baseline average equals call total" "$SINGLE_BATCH_LOG" 'average_tokens_per_issue=12345.00'
assert_contains "batch log counts the shared triage fixture before apply" "$SINGLE_BATCH_LOG" 'needs_triage_selectable_before=2'
assert_contains "batch log counts the shared triage fixture after apply" "$SINGLE_BATCH_LOG" 'needs_triage_selectable_after=2'
assert_eq "parallel batch IDs keep separate metrics logs" 2 \
  "$(find "$AGENT_HOME/logs" -maxdepth 1 -name 'triage-triage-batch-owner-*.log' | wc -l | tr -d ' ')"
unset ZF_TRIAGE_TICK_ID ZF_TRIAGE_BATCH_ID MAC_AUTOPILOT_RUNTIME_DIR

# Oversize issue text is cut in the prompt with a pointer to the full thread;
# a short issue in the same batch passes through unchanged.
pad() { yes "$1" | tr -d '\n' | head -c "$2"; }
jq -n --arg body "$(pad b 20000)" \
  --arg c1 "OLD_CMT_MARK $(pad 1 9000)" --arg c2 "MID_CMT_MARK $(pad 2 9000)" --arg c3 "NEW_CMT_MARK $(pad 3 9000)" \
  '{number:910311,title:"bounded fixture",body:$body,author:{login:"testuser"},comments:[{body:$c1},{body:$c2},{body:$c3}],createdAt:"2026-01-01T00:00:00Z",updatedAt:"2026-01-01T00:00:00Z",state:"OPEN",labels:[{name:"needs-triage"}]}' \
  > "$TEST_ROOT/long-issue.json"
jq -nc --argjson result "$VALID" '{issue:910311,result:$result},{issue:910312,result:$result}' > "$FAKE_CODEX_OUTPUT"
FAKE_ISSUE_JSON_FILE="$TEST_ROOT/long-issue.json" FAKE_ISSUE_JSON_NUMBER=910311 \
  ZF_TRIAGE_TICK_ID=bounded-prompt bash "$BATCH_SRC" --scheduled 910311 910312 >/dev/null 2>&1 || true
BOUNDED_PROMPT="$(cat "$FAKE_PROMPT_CAPTURE")"
assert_contains "long issue body is cut to the prompt budget" "$BOUNDED_PROMPT" 'body cut to 8192 chars'
assert_contains "long issue keeps only comments that fit the budget" "$BOUNDED_PROMPT" 'comments kept 1 of 3'
assert_contains "long issue keeps the newest comment" "$BOUNDED_PROMPT" 'NEW_CMT_MARK'
assert_not_contains "long issue drops the middle comment" "$BOUNDED_PROMPT" 'MID_CMT_MARK'
assert_not_contains "long issue drops the oldest comment" "$BOUNDED_PROMPT" 'OLD_CMT_MARK'
assert_contains "long issue points at the full thread" "$BOUNDED_PROMPT" 'full thread: gh issue view 910311 --comments'
assert_contains "short issue passes through verbatim" "$BOUNDED_PROMPT" '"body": "fixture body"'
assert_not_contains "short issue gets no pointer" "$BOUNDED_PROMPT" 'gh issue view 910312'

# A completed batch verdict belongs to the state and labels in its original
# snapshot. Closure after assembly must discard the old result before writes.
: > "$FAKE_GH_LOG"
jq -nc --argjson issue 910801 --argjson result "$VALID" '{issue:$issue,result:$result}' > "$FAKE_CODEX_OUTPUT"
STALE_OUTPUT="$(FAKE_STALE_BATCH_ISSUE=910801 bash "$BATCH_SRC" --scheduled 910801 2>&1)"
STALE_GH_LOG="$(cat "$FAKE_GH_LOG")"
assert_contains "closed issue invalidates its batch verdict" "$STALE_OUTPUT" 'issue is closed'
assert_not_contains "closed issue receives no triage label write" "$STALE_GH_LOG" 'issue edit 910801'
assert_not_contains "closed issue receives no triage comment" "$STALE_GH_LOG" 'issue comment 910801'
assert_eq "apply path rereads issue after batch snapshot" 3 "$(cat "${FAKE_GH_LOG}.views.910801")"
assert_eq "stale batch verdict does not persist classification" false "$(jq 'has("risk_class")' "$AGENT_HOME/state/910801.json")"

# A ticket can become held or receive a retry deadline after the scheduler's
# snapshot. The batch wrapper must re-check both before adding it to the prompt.
: > "$FAKE_CODEX_ARGS"
: > "$FAKE_GH_LOG"
jq -n --argjson retry "$(( $(date +%s) + 600 ))" '{triage_retry_after_epoch:$retry}' \
  > "$AGENT_HOME/state/910502.json"
jq -n --argjson until "$(( $(date +%s) + 600 ))" '{model_failure_backoff:{until_epoch:$until}}' \
  > "$AGENT_HOME/state/910503.json"
set +e
GUARD_OUTPUT="$(FAKE_ON_HOLD_ISSUE=910501 bash "$BATCH_SRC" --scheduled 910501 910502 910503 2>&1)"
GUARD_STATUS=$?
set -e
assert_eq "ineligible batch snapshot exits cleanly" 0 "$GUARD_STATUS"
assert_contains "batch rechecks on-hold status" "$GUARD_OUTPUT" '#910501 is no longer selectable'
assert_contains "batch rechecks freshness retry deadline" "$GUARD_OUTPUT" '#910502 is no longer selectable'
assert_contains "batch rechecks model failure backoff" "$GUARD_OUTPUT" '#910503 is no longer selectable'
assert_not_contains "eligibility guard has no test syntax error" "$GUARD_OUTPUT" "missing"
assert_eq "ineligible tickets never reach Codex" 0 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "ineligible tickets receive no label mutation" 0 "$(wc -l < "$FAKE_GH_LOG" | tr -d ' ')"

# A known L2 ticket with unchanged GitHub updatedAt and still-unconfirmed
# freshness only advances its local retry; changed input or a fresh index
# restores normal batching.
TEST_UPDATED_AT="2026-09-26T11:21:51Z"
: > "$FAKE_GH_LOG"
: > "$FAKE_CODEX_ARGS"
printf '%s\n' '{"lastCommit":"stale"}' > "$ZF_REPO_DIR/.gitnexus/meta.json"
jq -n --arg updated_at "$TEST_UPDATED_AT" \
  '{triage_retry_after_epoch:1,triage_freshness_deferred_issue_updated_at:$updated_at}' \
  > "$AGENT_HOME/state/910504.json"
jq -nc --argjson issue 910504 --argjson result "$VALID" '{issue:$issue,result:$result}' \
  > "$FAKE_CODEX_OUTPUT"
RUN_OUTPUT="$(FAKE_ISSUE_UPDATED_AT="$TEST_UPDATED_AT" bash "$BATCH_SRC" --scheduled 910504 2>&1)"
assert_contains "unchanged issue remains freshness-deferred without model retry" "$RUN_OUTPUT" 'all candidates still require the same unconfirmed L2 freshness'
assert_eq "unchanged issue freshness retry deadline advances" true \
  "$(jq -e --argjson now "$(date +%s)" '.triage_retry_after_epoch > $now' "$AGENT_HOME/state/910504.json" >/dev/null && echo true || echo false)"
assert_eq "unchanged issue does not invoke Codex again" 0 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "deferred issue receives no GitHub mutation" 0 "$(wc -l < "$FAKE_GH_LOG" | tr -d ' ')"
assert_eq "legacy freshness deferral initializes bounded start time" true \
  "$(jq -e '.triage_freshness_deferred_since_epoch > 0' "$AGENT_HOME/state/910504.json" >/dev/null && echo true || echo false)"

# Queue row 897 (2026-11-21): the batch reads the index and leaves refreshing
# to the per-tick refresh unit. gitnexus_refresh_index_once opens
# $AGENT_HOME/gitnexus-analyze.lock on every call, fresh index or not, so the
# lock staying absent is the proof that the batch never called it.
: > "$FAKE_CODEX_ARGS"
rm -f "$AGENT_HOME/gitnexus-analyze.lock"
jq -n --arg sha "$(git -C "$ZF_REPO_DIR" rev-parse origin/main)" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{lastCommit:$sha,indexedAt:$at}' > "$ZF_REPO_DIR/.gitnexus/meta.json"
jq -nc --argjson issue 910510 --argjson result "$VALID" '{issue:$issue,result:$result}' \
  > "$FAKE_CODEX_OUTPUT"
FRESH_NO_REFRESH_OUTPUT="$(bash "$BATCH_SRC" --scheduled 910510 2>&1)"
assert_eq "fresh index reaches the model call" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_not_contains "fresh index run never reports unconfirmed freshness" "$FRESH_NO_REFRESH_OUTPUT" \
  'freshness not confirmed'
assert_eq "fresh index opens no GitNexus refresh lock" false \
  "$(test -e "$AGENT_HOME/gitnexus-analyze.lock" && echo true || echo false)"
assert_contains "prompt states what the freshness check verified" "$(cat "$FAKE_PROMPT_CAPTURE")" \
  'at most 60 minutes old and at most 20 commits behind origin/main'
assert_not_contains "prompt no longer claims a batch inline refresh" "$(cat "$FAKE_PROMPT_CAPTURE")" \
  'refreshed once for the batch'

# A stale index keeps the not-confirmed branch exactly as before, and also
# never calls the refresh helper itself.
: > "$FAKE_CODEX_ARGS"
rm -f "$AGENT_HOME/gitnexus-analyze.lock"
printf '%s\n' '{"lastCommit":"stale"}' > "$ZF_REPO_DIR/.gitnexus/meta.json"
jq -n --arg updated_at "$TEST_UPDATED_AT" \
  '{triage_retry_after_epoch:1,triage_freshness_deferred_issue_updated_at:$updated_at}' \
  > "$AGENT_HOME/state/910511.json"
STALE_NO_REFRESH_OUTPUT="$(FAKE_ISSUE_UPDATED_AT="$TEST_UPDATED_AT" bash "$BATCH_SRC" --scheduled 910511 2>&1)"
assert_contains "stale index still takes the not-confirmed branch" "$STALE_NO_REFRESH_OUTPUT" \
  'all candidates still require the same unconfirmed L2 freshness'
assert_eq "stale index defers the issue without a model call" 0 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "stale index opens no GitNexus refresh lock either" false \
  "$(test -e "$AGENT_HOME/gitnexus-analyze.lock" && echo true || echo false)"
assert_eq "stale index still advances the freshness retry deadline" true \
  "$(jq -e --argjson now "$(date +%s)" '.triage_retry_after_epoch > $now' "$AGENT_HOME/state/910511.json" >/dev/null && echo true || echo false)"

# Three failed analyze runs clear the dead wait. Batch re-admits the unchanged
# issue, while the per-issue apply path keeps its L2 gate closed and records why.
: > "$FAKE_CODEX_ARGS"
: > "$FAKE_GH_LOG"
printf 'run\tfailed-1\t1\tsha\t10000000\t10000000\t124\t0\nrun\tfailed-2\t2\tsha\t10000000\t10000000\t124\t0\nrun\tfailed-3\t3\tsha\t10000000\t10000000\t124\t0\n' \
  > "$AGENT_HOME/night/gitnexus-analyze-memory.tsv"
printf '%s\n' "$(date +%s)" > "$AGENT_HOME/gitnexus-analyze-last-start"
jq -n --arg updated_at "$TEST_UPDATED_AT" \
  '{triage_retry_after_epoch:1,triage_freshness_deferred_issue_updated_at:$updated_at}' \
  > "$AGENT_HOME/state/910504.json"
jq -nc '{category:"enhancement",state:"ready-for-agent",risk_class:"P1",level:"L2",entry_surface:"Web /chat/",acceptor:"maintainer",advisor_reason:"none",brief_md:"Summary: freshness failure fixture.",notes_md:"No questions.",expected_packages:["packages/react-example"],expected_paths:[],related:[],suspected_shared_cause:null,estimated_changed_lines:0}' \
  | jq -c --argjson issue 910504 '{issue:$issue,result:.}' > "$FAKE_CODEX_OUTPUT"
RUN_OUTPUT="$(FAKE_ISSUE_UPDATED_AT="$TEST_UPDATED_AT" bash "$BATCH_SRC" --scheduled 910504 2>&1)"
assert_not_contains "failed analyze streak bypasses batch freshness wait" "$RUN_OUTPUT" 'all candidates still require the same unconfirmed L2 freshness'
assert_contains "batch reports why it skipped the unchanged-issue deferral" "$RUN_OUTPUT" 'last 3 GitNexus analyze runs failed'
assert_eq "failed analyze streak re-admits issue to Codex" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "unconfirmed L2 keeps the model's state under the default" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/910504.json")"
assert_eq "failed streak does not schedule a future freshness retry" true \
  "$(jq -r --argjson now "$(date +%s)" '(.triage_retry_after_epoch // 0) <= $now' "$AGENT_HOME/state/910504.json")"
assert_contains "batch decision comment explains the skipped deferral" "$(cat "$FAKE_GH_LOG")" 'last 3 GitNexus analyze runs failed'
assert_contains "batch decision comment records the unconfirmed impact" "$(cat "$FAKE_GH_LOG")" 'L2 impact freshness was not confirmed'

: > "$FAKE_CODEX_ARGS"
jq -n --arg updated_at "$TEST_UPDATED_AT" \
  '{triage_retry_after_epoch:1,triage_freshness_deferred_issue_updated_at:$updated_at}' \
  > "$AGENT_HOME/state/910505.json"
jq -nc --argjson issue 910505 --argjson result "$VALID" '{issue:$issue,result:$result}' \
  > "$FAKE_CODEX_OUTPUT"
RUN_OUTPUT="$(FAKE_ISSUE_UPDATED_AT=2026-09-27T00:00:00Z bash "$BATCH_SRC" --scheduled 910505 2>&1)"
assert_eq "changed issue version returns to Codex" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"

: > "$FAKE_CODEX_ARGS"
jq -n --arg updated_at "$TEST_UPDATED_AT" \
  '{triage_retry_after_epoch:1,triage_freshness_deferred_issue_updated_at:$updated_at}' \
  > "$AGENT_HOME/state/910507.json"
jq -nc '{category:"enhancement",state:"ready-for-human",risk_class:"P1",level:"L2",entry_surface:"Web /chat/",acceptor:"maintainer",advisor_reason:"none",brief_md:"Summary: freshness fixture.",notes_md:"No questions.",expected_packages:["packages/react-example"],expected_paths:[],related:[],suspected_shared_cause:null,estimated_changed_lines:0}' \
  | jq -c --argjson issue 910507 '{issue:$issue,result:.}' > "$FAKE_CODEX_OUTPUT"
RUN_OUTPUT="$(FAKE_ISSUE_UPDATED_AT="$TEST_UPDATED_AT" FAKE_ISSUE_UPDATED_AT_AFTER_FIRST_VIEW=2026-09-27T00:00:00Z bash "$BATCH_SRC" --scheduled 910507 2>&1)"
assert_eq "live issue update after batch snapshot prevents retry suppression" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "freshness result records the version used for its verdict" "$TEST_UPDATED_AT" \
  "$(jq -r '.triage_freshness_deferred_issue_updated_at' "$AGENT_HOME/state/910507.json")"

: > "$FAKE_CODEX_ARGS"
printf '%s\n' "{\"lastCommit\":\"$(git -C "$ZF_REPO_DIR" rev-parse HEAD)\"}" \
  > "$ZF_REPO_DIR/.gitnexus/meta.json"
jq -n --arg updated_at "$TEST_UPDATED_AT" \
  '{triage_retry_after_epoch:1,triage_freshness_deferred_issue_updated_at:$updated_at}' \
  > "$AGENT_HOME/state/910506.json"
jq -nc --argjson issue 910506 --argjson result "$VALID" '{issue:$issue,result:$result}' \
  > "$FAKE_CODEX_OUTPUT"
RUN_OUTPUT="$(FAKE_ISSUE_UPDATED_AT="$TEST_UPDATED_AT" bash "$BATCH_SRC" --scheduled 910506 2>&1)"
assert_eq "fresh index returns unchanged issue to Codex" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"

# Once an unchanged issue has waited two hours, stale freshness no longer
# suppresses triage. The 2026-11-06 default keeps the model's state with the
# impact marked unconfirmed; only an advisor-only reason routes to the advisor.
: > "$FAKE_GH_LOG"
: > "$FAKE_CODEX_ARGS"
printf '%s\n' '{"lastCommit":"stale"}' > "$ZF_REPO_DIR/.gitnexus/meta.json"
jq -n --arg updated_at "$TEST_UPDATED_AT" --argjson since "$(( $(date +%s) - 7201 ))" \
  '{triage_retry_after_epoch:1,triage_freshness_deferred_issue_updated_at:$updated_at,triage_freshness_deferred_since_epoch:$since}' \
  > "$AGENT_HOME/state/910508.json"
jq -nc '{category:"enhancement",state:"ready-for-agent",risk_class:"P1",level:"L2",entry_surface:"Web /chat/",acceptor:"maintainer",advisor_reason:"none",brief_md:"Summary: stale L2 fixture.",notes_md:"No questions.",expected_packages:["packages/react-example"],expected_paths:[],related:[],suspected_shared_cause:null,estimated_changed_lines:0}' \
  | jq -c --argjson issue 910508 '{issue:$issue,result:.}' > "$FAKE_CODEX_OUTPUT"
RUN_OUTPUT="$(FAKE_ISSUE_UPDATED_AT="$TEST_UPDATED_AT" bash "$BATCH_SRC" --scheduled 910508 2>&1)"
assert_not_contains "expired freshness deferral does not skip stale L2 triage" "$RUN_OUTPUT" 'all candidates still require the same unconfirmed L2 freshness'
assert_eq "expired freshness deferral invokes Codex once" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "stale L2 result keeps the model's state under the default" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/910508.json")"
assert_contains "stale L2 result enters the implement queue" "$(cat "$FAKE_GH_LOG")" '--add-label ready-for-agent'
assert_not_contains "stale L2 result is not routed to the advisor by default" "$(cat "$FAKE_GH_LOG")" '--add-label needs-advisor'
assert_contains "stale L2 comment records the unconfirmed impact" "$(cat "$FAKE_GH_LOG")" 'L2 impact freshness was not confirmed'

# Maintainer-filed issues bypass an already-set freshness deadline, keep the
# default routing with the unconfirmed-impact note, and receive their durable
# priority label during triage intake.
: > "$FAKE_CODEX_ARGS"
: > "$FAKE_GH_LOG"
printf '%s\n' '{"lastCommit":"stale"}' > "$ZF_REPO_DIR/.gitnexus/meta.json"
jq -n --arg updated_at "$TEST_UPDATED_AT" --argjson retry "$(( $(date +%s) + 600 ))" --argjson since "$(date +%s)" \
  '{triage_retry_after_epoch:$retry,triage_freshness_deferred_issue_updated_at:$updated_at,triage_freshness_deferred_since_epoch:$since}' \
  > "$AGENT_HOME/state/910509.json"
jq -nc '{category:"enhancement",state:"ready-for-agent",risk_class:"P1",level:"L2",entry_surface:"Web /chat/",acceptor:"maintainer",advisor_reason:"none",brief_md:"Summary: maintainer test.",notes_md:"Index freshness unconfirmed.",expected_packages:["packages/react-example"],expected_paths:[],related:[],suspected_shared_cause:null,estimated_changed_lines:0}' \
  | jq -c --argjson issue 910509 '{issue:$issue,result:.}' > "$FAKE_CODEX_OUTPUT"
RUN_OUTPUT="$(FAKE_AUTHOR=maintainer FAKE_ISSUE_UPDATED_AT="$TEST_UPDATED_AT" bash "$BATCH_SRC" --scheduled 910509 2>&1)"
assert_eq "founder-test freshness deadline does not suppress triage" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_contains "founder-filed issue gets founder-test label at intake" "$(cat "$FAKE_GH_LOG")" 'issue edit 910509 --repo test/repo --add-label founder-test'
assert_eq "founder-test stale L2 keeps the model's state under the default" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/910509.json")"
assert_contains "founder-test stale L2 enters the implement queue" "$(cat "$FAKE_GH_LOG")" '--add-label ready-for-agent'
assert_not_contains "founder-test stale L2 is not routed to the advisor by default" "$(cat "$FAKE_GH_LOG")" '--add-label needs-advisor'

# A missing line follows same isolated retry path; cap remains independent.
: > "$FAKE_CODEX_ARGS"
jq -nc --argjson issue 910401 --argjson result "$VALID" '{issue:$issue,result:$result}' > "$FAKE_CODEX_OUTPUT"
set +e
MISSING_OUTPUT="$(AGENT_TRIAGE_CAP=2 bash "$BATCH_SRC" --scheduled 910401 910402 910403 2>&1)"
MISSING_STATUS=$?
set -e
assert_eq "missing result does not fail its batch" 0 "$MISSING_STATUS"
assert_contains "missing result is isolated for scoped retry" "$MISSING_OUTPUT" 'failed_or_missing=1'
assert_eq "missing member waits for a scoped retry" true "$(jq -e --argjson now "$(date +%s)" '.model_failure_backoff.until_epoch > $now' "$AGENT_HOME/state/910402.json" >/dev/null && echo true || echo false)"
assert_eq "missing member is marked for retry alone" true "$(jq -r '.triage_batch_retry_alone' "$AGENT_HOME/state/910402.json")"
MISSING_ISSUE_EDIT="$(sed -n '/^issue edit 910402 /p' "$FAKE_GH_LOG")"
assert_not_contains "missing issue stays out of advisor until its solo retry" "$MISSING_ISSUE_EDIT" '--add-label needs-advisor'
assert_not_contains "second cap leftover stays unapplied" "$(cat "$FAKE_GH_LOG")" 'issue edit 910403'

# Queue row 897: a solo retry run -- its one included issue entered flagged --
# takes the flag off once its model call returned, whatever the exit status.
# Only a zero exit with an invalid or missing record counts as a solo result
# failure, and the second one concludes the issue instead of requeueing it.
: > "$FAKE_CODEX_ARGS"
printf '%s\n' "{\"lastCommit\":\"$(git -C "$ZF_REPO_DIR" rev-parse HEAD)\"}" \
  > "$ZF_REPO_DIR/.gitnexus/meta.json"
jq -n '[910901] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
echo '[]' > "$FAKE_TRIAGE_QUEUE_AFTER_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
jq -n '{triage_batch_retry_alone:true}' > "$AGENT_HOME/state/910901.json"
jq -nc --argjson issue 910901 --argjson result "$INVALID" '{issue:$issue,result:$result}' > "$FAKE_CODEX_OUTPUT"
set +e
SOLO_INVALID_OUTPUT="$(ZF_TRIAGE_TICK_ID=solo-invalid-910901 bash "$BATCH_SRC" --scheduled 910901 2>&1)"
SOLO_INVALID_STATUS=$?
set -e
assert_eq "solo retry run with an invalid record exits cleanly" 0 "$SOLO_INVALID_STATUS"
assert_contains "solo run reports its invalid record" "$SOLO_INVALID_OUTPUT" 'failed_or_missing=1'
assert_eq "solo invalid record removes the retry-alone flag" false "$(jq -r '.triage_batch_retry_alone // false' "$AGENT_HOME/state/910901.json")"
assert_eq "solo invalid record counts its first solo result failure" 1 "$(jq -r '.triage_solo_result_failures // 0' "$AGENT_HOME/state/910901.json")"

jq -n '{triage_batch_retry_alone:true,triage_solo_result_failures:1}' > "$AGENT_HOME/state/910903.json"
: > "$FAKE_CODEX_OUTPUT"
set +e
SOLO_NONZERO_OUTPUT="$(FAKE_CODEX_STATUS=1 ZF_TRIAGE_TICK_ID=solo-nonzero-910903 bash "$BATCH_SRC" --scheduled 910903 2>&1)"
SOLO_NONZERO_STATUS=$?
set -e
assert_eq "solo retry run with a non-zero model exit exits cleanly" 0 "$SOLO_NONZERO_STATUS"
assert_eq "non-zero model exit still removes the retry-alone flag" false "$(jq -r '.triage_batch_retry_alone // false' "$AGENT_HOME/state/910903.json")"
assert_eq "non-zero model exit leaves the solo failure counter unchanged" 1 "$(jq -r '.triage_solo_result_failures // 0' "$AGENT_HOME/state/910903.json")"

jq -n '{triage_batch_retry_alone:true,triage_solo_result_failures:1}' > "$AGENT_HOME/state/910904.json"
jq -nc --argjson issue 910904 --argjson result "$VALID" '{issue:$issue,result:$result}' > "$FAKE_CODEX_OUTPUT"
set +e
SOLO_VALID_OUTPUT="$(ZF_TRIAGE_TICK_ID=solo-valid-910904 bash "$BATCH_SRC" --scheduled 910904 2>&1)"
SOLO_VALID_STATUS=$?
set -e
assert_eq "solo retry run with a valid record exits cleanly" 0 "$SOLO_VALID_STATUS"
assert_eq "solo valid record applies its verdict" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/910904.json")"
assert_eq "solo valid record leaves no retry-alone flag" false "$(jq -r '.triage_batch_retry_alone // false' "$AGENT_HOME/state/910904.json")"
assert_eq "solo valid record clears the solo failure counter" 0 "$(jq -r '.triage_solo_result_failures // 0' "$AGENT_HOME/state/910904.json")"

# The second solo result failure goes through the terminal path, not back to
# a queue: conclude_run is stubbed so the call itself is the assertion. The
# helper is sourced from its module, never extracted by text range
# (source-extract ratchet). Round 2 also sends one supervisor notice beside
# the conclusion; a failing notice must not undo or fail it.
SOLO_CONCLUDE_LOG="$TEST_ROOT/solo-conclude.log"
SOLO_NOTICE_LOG="$TEST_ROOT/solo-notice.log"
SOLO_FAIL_STATE="$TEST_ROOT/solo-fail-state.json"
jq -n '{triage_solo_result_failures:1}' > "$SOLO_FAIL_STATE"
(
  conclude_run() { printf 'conclude_run %s %s %s\n' "$1" "$2" "$3" >> "$SOLO_CONCLUDE_LOG"; }
  quarantine_supervisor_notice() { printf 'notice %s %s %s\n' "$1" "$2" "$3" >> "$SOLO_NOTICE_LOG"; }
  state_read() { cat "$SOLO_FAIL_STATE"; }
  state_merge() { local merged; merged="$(jq "$2" "$SOLO_FAIL_STATE")" && printf '%s\n' "$merged" > "$SOLO_FAIL_STATE"; }
  INCLUDED_IDS=(910902)
  declare -A SOLO_RETRY_AT_START=([910902]=1)
  STATUS=0
  triage_solo_count_result_failure 910902 "invalid triage.schema.json record (Codex exit 0)"
)
assert_contains "second solo result failure calls conclude_run" "$(cat "$SOLO_CONCLUDE_LOG")" \
  'conclude_run 910902 not-completed two solo triage result failures'
assert_contains "second solo result failure sends one supervisor notice" "$(cat "$SOLO_NOTICE_LOG")" \
  'notice triage solo-concluded issue=#910902'
assert_contains "the notice names the last failure reason" "$(cat "$SOLO_NOTICE_LOG")" \
  'reason=invalid triage.schema.json record (Codex exit 0)'
assert_eq "second solo failure leaves no retry-alone flag" false "$(jq -r '.triage_batch_retry_alone // false' "$SOLO_FAIL_STATE")"
assert_eq "second solo failure records the solo result failure cap" 2 "$(jq -r '.triage_solo_result_failures // 0' "$SOLO_FAIL_STATE")"

jq -n '{triage_solo_result_failures:1}' > "$SOLO_FAIL_STATE"
: > "$SOLO_CONCLUDE_LOG"
(
  conclude_run() { printf 'conclude_run %s %s %s\n' "$1" "$2" "$3" >> "$SOLO_CONCLUDE_LOG"; }
  quarantine_supervisor_notice() { echo "notice delivery failed" >&2; return 1; }
  state_read() { cat "$SOLO_FAIL_STATE"; }
  state_merge() { local merged; merged="$(jq "$2" "$SOLO_FAIL_STATE")" && printf '%s\n' "$merged" > "$SOLO_FAIL_STATE"; }
  INCLUDED_IDS=(910905)
  declare -A SOLO_RETRY_AT_START=([910905]=1)
  STATUS=0
  triage_solo_count_result_failure 910905 "invalid triage.schema.json record (Codex exit 0)"
)
assert_contains "a failing notice still concludes the issue" "$(cat "$SOLO_CONCLUDE_LOG")" \
  'conclude_run 910905 not-completed two solo triage result failures'
assert_eq "a failing notice does not fail the conclusion" 2 "$(jq -r '.triage_solo_result_failures // 0' "$SOLO_FAIL_STATE")"

# Queue row 897, round 2: a valid result whose apply failed is kept with the
# issue snapshot it was made from (one pair per issue under $AGENT_HOME); a
# later run applies an unchanged issue's pair without a model call, and drops
# the pair when the issue changed or the pair is older than 24 hours.
jq -n '[911001, 911002, 911003, 911004, 911005] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
echo '[]' > "$FAKE_TRIAGE_QUEUE_AFTER_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
jq -nc --argjson issue 911001 --argjson result "$VALID" '{issue:$issue,result:$result}' > "$FAKE_CODEX_OUTPUT"
printf '2\n' > "${FAKE_GH_LOG}.view-fail-from.911001"
set +e
KEPT_FAIL_OUTPUT="$(ZF_TRIAGE_TICK_ID=kept-fail-911001 bash "$BATCH_SRC" --scheduled 911001 2>&1)"
KEPT_FAIL_STATUS=$?
set -e
assert_eq "apply failure does not fail the batch" 0 "$KEPT_FAIL_STATUS"
assert_contains "apply failure is reported" "$KEPT_FAIL_OUTPUT" 'Apply failed'
assert_eq "apply failure keeps one result file" 1 "$(find "$AGENT_HOME/triage-kept" -name '911001-*.result.json' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "apply failure keeps the snapshot beside it" 1 "$(find "$AGENT_HOME/triage-kept" -name '911001-*.snapshot.json' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "kept pair name carries the issue number and a UTC stamp" 1 \
  "$(ls "$AGENT_HOME/triage-kept" 2>/dev/null | grep -cE '^911001-[0-9]{8}T[0-9]{6}Z[.]result[.]json$')"
assert_eq "apply failure sets no retry-alone flag" false "$(jq -r '.triage_batch_retry_alone // false' "$AGENT_HOME/state/911001.json")"
assert_eq "apply failure adds no solo result counter" 0 "$(jq -r '.triage_solo_result_failures // 0' "$AGENT_HOME/state/911001.json")"

rm -f "${FAKE_GH_LOG}.view-fail-from.911001"
: > "$FAKE_CODEX_ARGS"
KEPT_APPLY_OUTPUT="$(ZF_TRIAGE_TICK_ID=kept-apply-911001 bash "$BATCH_SRC" --scheduled 911001 2>&1)"
assert_contains "unchanged issue applies its kept result" "$KEPT_APPLY_OUTPUT" 'applied its kept result without a model call'
assert_contains "run with only kept results ends without a model call" "$KEPT_APPLY_OUTPUT" 'no model call'
assert_eq "kept-result apply makes no model call" 0 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "kept result applies the verdict" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/911001.json")"
assert_eq "successful kept apply deletes the pair" 0 "$(find "$AGENT_HOME/triage-kept" -name '911001-*' 2>/dev/null | wc -l | tr -d ' ')"

jq -nc --argjson issue 911002 --argjson result "$VALID" '{issue:$issue,result:$result}' > "$FAKE_CODEX_OUTPUT"
printf '2\n' > "${FAKE_GH_LOG}.view-fail-from.911002"
ZF_TRIAGE_TICK_ID=kept-fail-911002 bash "$BATCH_SRC" --scheduled 911002 >/dev/null 2>&1
assert_eq "changed-issue case first keeps its pair" 1 "$(find "$AGENT_HOME/triage-kept" -name '911002-*.result.json' | wc -l | tr -d ' ')"
rm -f "${FAKE_GH_LOG}.view-fail-from.911002"
jq -n '{number:911002,title:"batch fixture",body:"fixture body",author:{login:"testuser"},comments:[],createdAt:"2026-01-01T00:00:00Z",updatedAt:"2026-01-02T00:00:00Z",state:"OPEN",labels:[{name:"needs-triage"},{name:"priority:high"}]}' \
  > "$TEST_ROOT/changed-issue.json"
: > "$FAKE_CODEX_ARGS"
KEPT_CHANGED_OUTPUT="$(FAKE_ISSUE_JSON_FILE="$TEST_ROOT/changed-issue.json" FAKE_ISSUE_JSON_NUMBER=911002 \
  ZF_TRIAGE_TICK_ID=kept-changed-911002 bash "$BATCH_SRC" --scheduled 911002 2>&1)"
assert_contains "changed issue discards the kept pair" "$KEPT_CHANGED_OUTPUT" 'no longer matches the issue'
assert_eq "changed issue deletes the pair" 0 "$(find "$AGENT_HOME/triage-kept" -name '911002-*' | wc -l | tr -d ' ')"
assert_eq "changed issue is triaged by the model" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"

jq -nc --argjson issue 911003 --argjson result "$VALID" '{issue:$issue,result:$result}' > "$FAKE_CODEX_OUTPUT"
printf '2\n' > "${FAKE_GH_LOG}.view-fail-from.911003"
ZF_TRIAGE_TICK_ID=kept-fail-911003 bash "$BATCH_SRC" --scheduled 911003 >/dev/null 2>&1
touch -d '25 hours ago' "$AGENT_HOME/triage-kept"/911003-*.result.json "$AGENT_HOME/triage-kept"/911003-*.snapshot.json
rm -f "${FAKE_GH_LOG}.view-fail-from.911003"
: > "$FAKE_CODEX_ARGS"
KEPT_EXPIRED_OUTPUT="$(ZF_TRIAGE_TICK_ID=kept-expired-911003 bash "$BATCH_SRC" --scheduled 911003 2>&1)"
assert_contains "expired pair is discarded" "$KEPT_EXPIRED_OUTPUT" 'older than 24 hours'
assert_eq "expired pair is deleted" 0 "$(find "$AGENT_HOME/triage-kept" -name '911003-*' | wc -l | tr -d ' ')"
assert_eq "expired pair sends the issue back to the model" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"

jq -nc --argjson result "$VALID" '{issue:911004,result:$result},{issue:911005,result:$result}' > "$FAKE_CODEX_OUTPUT"
printf '2\n' > "${FAKE_GH_LOG}.view-fail-from.911004"
ZF_TRIAGE_TICK_ID=kept-fail-911004 bash "$BATCH_SRC" --scheduled 911004 911005 >/dev/null 2>&1
assert_eq "only the failing issue keeps a pair" 1 "$(find "$AGENT_HOME/triage-kept" -name '911004-*.result.json' | wc -l | tr -d ' ')"
assert_eq "the other issue applied normally" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/911005.json")"
rm -f "${FAKE_GH_LOG}.view-fail-from.911004"
jq -nc --argjson issue 911005 --argjson result "$VALID" '{issue:$issue,result:$result}' > "$FAKE_CODEX_OUTPUT"
: > "$FAKE_CODEX_ARGS"
KEPT_MIXED_OUTPUT="$(ZF_TRIAGE_TICK_ID=kept-mixed bash "$BATCH_SRC" --scheduled 911004 911005 2>&1)"
assert_contains "mixed batch applies the kept pair" "$KEPT_MIXED_OUTPUT" '#911004 applied its kept result without a model call'
assert_contains "the model batch holds only the other issue" "$(cat "$FAKE_PROMPT_CAPTURE")" '## Issue #911005'
assert_not_contains "kept-pair issue leaves the model batch" "$(cat "$FAKE_PROMPT_CAPTURE")" '## Issue #911004'
assert_eq "mixed batch still calls the model once" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "kept pair is consumed" 0 "$(find "$AGENT_HOME/triage-kept" -name '911004-*' | wc -l | tr -d ' ')"

# Queue row 919: a valid result is kept the moment it passes the schema
# check, before the first apply starts, and is deleted only after its own
# issue applies. The fake gh holds the first issue's apply-time reread on a
# gate file; the batch runs in its own session, so one TERM to the process
# group ends the wrapper, its apply and the fake gh together, the way the
# unit timeout's TERM reached the whole unit on 2026-11-21 17:42Z.
HANG_MARKER="$TEST_ROOT/view-hang.marker"
HANG_GATE="$TEST_ROOT/view-hang.gate"
jq -n '[911501, 911502, 911503] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
echo '[]' > "$FAKE_TRIAGE_QUEUE_AFTER_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
jq -nc --argjson result "$VALID" '{issue:911501,result:$result},{issue:911502,result:$result},{issue:911503,result:$result}' > "$FAKE_CODEX_OUTPUT"
rm -f "$HANG_MARKER"
: > "$HANG_GATE"
set +e
FAKE_GH_VIEW_HANG_ISSUE=911501 FAKE_GH_VIEW_HANG_MARKER="$HANG_MARKER" FAKE_GH_VIEW_HANG_GATE="$HANG_GATE" \
  setsid bash "$BATCH_SRC" --scheduled 911501 911502 911503 >"$TEST_ROOT/killed-run.out" 2>&1 &
KILLED_PID=$!
hang_waits=0
while [ ! -s "$HANG_MARKER" ] && [ "$hang_waits" -lt 600 ]; do
  sleep 0.1
  hang_waits=$((hang_waits + 1))
done
kill -TERM -- "-$KILLED_PID"
wait "$KILLED_PID"
KILLED_STATUS=$?
set -e
hang_waits=0
while kill -0 -- "-$KILLED_PID" 2>/dev/null && [ "$hang_waits" -lt 100 ]; do
  sleep 0.1
  hang_waits=$((hang_waits + 1))
done
assert_eq "a killed batch leaves no process behind" false \
  "$(kill -0 -- "-$KILLED_PID" 2>/dev/null && echo true || echo false)"
for n in 911501 911502 911503; do
  assert_eq "killed batch kept #$n's valid result before its apply finished" 1 \
    "$(find "$AGENT_HOME/triage-kept" -name "$n-*.result.json" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "killed batch kept #$n's snapshot beside the result" 1 \
    "$(find "$AGENT_HOME/triage-kept" -name "$n-*.snapshot.json" 2>/dev/null | wc -l | tr -d ' ')"
done
rm -f "$HANG_GATE"
: > "$FAKE_CODEX_ARGS"
set +e
KEPT_RESUME_OUTPUT="$(ZF_TRIAGE_TICK_ID=kept-resume-9115 bash "$BATCH_SRC" --scheduled 911501 911502 911503 2>&1)"
KEPT_RESUME_STATUS=$?
set -e
assert_eq "resumed run exits cleanly" 0 "$KEPT_RESUME_STATUS"
assert_contains "resumed run names how many issues it served from kept pairs" "$KEPT_RESUME_OUTPUT" \
  '3 issue(s) served from kept pairs left by an earlier run that did not finish'
assert_contains "resumed run applies every kept pair without a model call" "$KEPT_RESUME_OUTPUT" 'no model call'
assert_eq "resumed run never invokes the model" 0 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "resumed run consumes every kept pair" 0 \
  "$(find "$AGENT_HOME/triage-kept" \( -name '911501-*' -o -name '911502-*' -o -name '911503-*' \) 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "resumed run applies the interrupted issue's verdict" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/911501.json")"
assert_eq "resumed run applies an unreached issue's verdict" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/911502.json")"

# Before the first apply finishes, every valid result of the batch is
# already on disk; a run whose applies all succeed leaves no pair behind.
jq -n '[911511, 911512] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
jq -nc --argjson result "$VALID" '{issue:911511,result:$result},{issue:911512,result:$result}' > "$FAKE_CODEX_OUTPUT"
rm -f "$HANG_MARKER"
: > "$HANG_GATE"
set +e
FAKE_GH_VIEW_HANG_ISSUE=911511 FAKE_GH_VIEW_HANG_MARKER="$HANG_MARKER" FAKE_GH_VIEW_HANG_GATE="$HANG_GATE" \
  setsid bash "$BATCH_SRC" --scheduled 911511 911512 >"$TEST_ROOT/held-run.out" 2>&1 &
HELD_PID=$!
hang_waits=0
while [ ! -s "$HANG_MARKER" ] && [ "$hang_waits" -lt 600 ]; do
  sleep 0.1
  hang_waits=$((hang_waits + 1))
done
set -e
assert_eq "every valid result is kept before the first apply finishes" 2 \
  "$(find "$AGENT_HOME/triage-kept" \( -name '911511-*.result.json' -o -name '911512-*.result.json' \) 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "both snapshots sit beside the kept results" 2 \
  "$(find "$AGENT_HOME/triage-kept" \( -name '911511-*.snapshot.json' -o -name '911512-*.snapshot.json' \) 2>/dev/null | wc -l | tr -d ' ')"
rm -f "$HANG_GATE"
set +e
wait "$HELD_PID"
HELD_STATUS=$?
set -e
assert_eq "held batch finishes cleanly once the gate opens" 0 "$HELD_STATUS"
assert_contains "held batch applied both records" "$(cat "$TEST_ROOT/held-run.out")" 'applied 2 valid result(s)'
assert_eq "a run where every apply succeeds leaves no pair" 0 \
  "$(find "$AGENT_HOME/triage-kept" \( -name '911511-*' -o -name '911512-*' \) 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "held batch applied the hung issue's verdict" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/911511.json")"
assert_eq "held batch applied the queued issue's verdict" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/911512.json")"

# An invalid record never becomes a kept pair; it still goes to triage-invalid.
jq -n '[911531] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
jq -nc --argjson issue 911531 --argjson invalid "$INVALID" '{issue:$issue,result:$invalid}' > "$FAKE_CODEX_OUTPUT"
ZF_TRIAGE_TICK_ID=kept-invalid-911531 bash "$BATCH_SRC" --scheduled 911531 >/dev/null 2>&1
assert_eq "invalid record is kept for diagnosis, not as a pair" 1 \
  "$(find "$AGENT_HOME/triage-invalid" -name '911531-*.json' | wc -l | tr -d ' ')"
assert_eq "invalid record leaves no kept pair" 0 \
  "$(find "$AGENT_HOME/triage-kept" -name '911531-*' 2>/dev/null | wc -l | tr -d ' ')"

# Queue row 920: the batch's first credits-exhausted TypeSafe answer writes one
# stop file in the batch's scratch dir (ZF_INTAKE_JUDGE_STOP_FILE); the batch's
# remaining issues skip the judge call, log one fixed line each, and still get
# their fallback result through the haiku path. A request-failed answer never
# sets the file, and a valid record whose apply fails lands in the new
# apply_failed count beside applied_count and failed_record_count.
export FAKE_CLAUDE_JUDGE_LOG="$TEST_ROOT/intake-claude.log"
export FAKE_TS_JUDGE_LOG="$TEST_ROOT/intake-judge.log"
cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'called\n' >> "$FAKE_CLAUDE_JUDGE_LOG"
jq -cn --arg result '{"priority":"low","route":null}' '{type:"result",is_error:false,result:$result}'
EOF
cat > "$FAKE_BIN/ts-judge-stub.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$1" >> "$FAKE_TS_JUDGE_LOG"
if [ "$1" = intake-priority ]; then
  jq -cn --arg reason "${FAKE_TS_JUDGE_REASON:-credits-exhausted}" '{status:"fallback",question_set:"intake-priority",reason:$reason,candidate:null,confidence:null,decision:null,adopted:false}'
else
  printf '%s\n' '{"status":"answered","adopted":false,"decision":"ready-for-agent"}'
fi
EOF
chmod +x "$FAKE_BIN/claude" "$FAKE_BIN/ts-judge-stub.sh"
jq -n '{roots:[{number:900,title:"Roadmap",state:"open",labels:["roadmap"],children:[{number:901,title:"Theme",state:"open",labels:["roadmap-theme"],children:[{number:902,title:"Release epic",state:"open",labels:["roadmap-epic"],children:[]}]}]}]}' > "$TEST_ROOT/intake-roadmap.json"
run_intake_batch() { # <reason> <tick-id> <issues...>: one batch run with the TypeSafe stubs in its environment
  FAKE_TS_JUDGE_REASON="$1" TYPESAFE_API_KEY=fixture-only \
    ZF_TS_JUDGE_SCRIPT="$FAKE_BIN/ts-judge-stub.sh" ZF_ROADMAP_TREE_CACHE_FILE="$TEST_ROOT/intake-roadmap.json" \
    ZF_TRIAGE_TICK_ID="$2" bash "$BATCH_SRC" --scheduled "${@:3}" 2>&1
}

: > "$FAKE_CLAUDE_JUDGE_LOG"; : > "$FAKE_TS_JUDGE_LOG"; : > "$FAKE_GH_LOG"
jq -n '[911551, 911552, 911553] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
printf '%s\n' "{\"lastCommit\":\"$(git -C "$ZF_REPO_DIR" rev-parse HEAD)\"}" > "$ZF_REPO_DIR/.gitnexus/meta.json"
jq -nc --argjson result "$VALID" '{issue:911551,result:$result},{issue:911552,result:$result},{issue:911553,result:$result}' > "$FAKE_CODEX_OUTPUT"
set +e
JUDGE_STOP_OUTPUT="$(run_intake_batch credits-exhausted judge-stop-9115 911551 911552 911553)"
JUDGE_STOP_STATUS=$?
set -e
assert_eq "credits-exhausted batch exits cleanly" 0 "$JUDGE_STOP_STATUS"
assert_eq "the first credits-exhausted answer is the batch's only intake judge call" 1 \
  "$(grep -Fc 'intake-priority' "$FAKE_TS_JUDGE_LOG" || true)"
assert_eq "the batch's other two issues log the fixed skip line" 2 \
  "$(grep -Fc 'intake-priority: judge skipped (credits-exhausted earlier in this batch)' <<< "$JUDGE_STOP_OUTPUT" || true)"
assert_eq "the stop file leaves the triage-size judge alone" 3 \
  "$(grep -Fc 'triage-size' "$FAKE_TS_JUDGE_LOG" || true)"
assert_eq "every issue still reaches the haiku fallback" 3 "$(wc -l < "$FAKE_CLAUDE_JUDGE_LOG" | tr -d ' ')"
# Fixture issues carry the enhancement label, so the fruit-feature overlay (intake-priority-policy.jq) sets normal over the haiku low.
assert_eq "every issue writes its fallback priority label" 3 "$(grep -Fc 'labels[]=priority:normal' "$FAKE_GH_LOG" || true)"
assert_eq "every issue is marked as a judge fallback" 3 "$(grep -Fc 'labels[]=judge:fallback' "$FAKE_GH_LOG" || true)"
assert_contains "credits-exhausted batch still applies every verdict" "$JUDGE_STOP_OUTPUT" \
  'applied 3 valid result(s); apply_failed=0; failed_or_missing=0'

: > "$FAKE_TS_JUDGE_LOG"; : > "$FAKE_CLAUDE_JUDGE_LOG"
jq -n '[911561, 911562, 911563] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
jq -nc --argjson result "$VALID" '{issue:911561,result:$result},{issue:911562,result:$result},{issue:911563,result:$result}' > "$FAKE_CODEX_OUTPUT"
set +e
JUDGE_RETRY_OUTPUT="$(run_intake_batch request-failed judge-retry-9115 911561 911562 911563)"
JUDGE_RETRY_STATUS=$?
set -e
assert_eq "request-failed batch exits cleanly" 0 "$JUDGE_RETRY_STATUS"
assert_eq "request-failed keeps the judge called for every issue" 3 \
  "$(grep -Fc 'intake-priority' "$FAKE_TS_JUDGE_LOG" || true)"
assert_eq "request-failed never logs the skip line" 0 \
  "$(grep -Fc 'intake-priority: judge skipped' <<< "$JUDGE_RETRY_OUTPUT" || true)"
assert_eq "request-failed batch still labels every issue through haiku" 3 "$(wc -l < "$FAKE_CLAUDE_JUDGE_LOG" | tr -d ' ')"
rm -f "$FAKE_BIN/claude"

# A valid record whose write-back fails is a count of its own: the summary line
# and the metrics log carry apply_failed, and applied + apply_failed +
# failed_or_missing covers every included issue of the batch.
jq -n '[911571, 911572, 911573] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
jq -nc --argjson result "$VALID" '{issue:911571,result:$result},{issue:911572,result:$result},{issue:911573,result:$result}' > "$FAKE_CODEX_OUTPUT"
printf '2\n' > "${FAKE_GH_LOG}.view-fail-from.911572"
set +e
APPLY_FAIL_OUTPUT="$(ZF_TRIAGE_TICK_ID=apply-fail-9115 bash "$BATCH_SRC" --scheduled 911571 911572 911573 2>&1)"
APPLY_FAIL_STATUS=$?
set -e
rm -f "${FAKE_GH_LOG}.view-fail-from.911572"
assert_eq "one failed apply does not fail the batch" 0 "$APPLY_FAIL_STATUS"
assert_contains "one failed apply keeps its valid result for the next run" "$APPLY_FAIL_OUTPUT" 'Apply failed'
assert_contains "summary line carries the new apply_failed count" "$APPLY_FAIL_OUTPUT" \
  'applied 2 valid result(s); apply_failed=1; failed_or_missing=0; tokens=12345'
APPLY_FAIL_LOG="$(cat "$AGENT_HOME/logs/triage-apply-fail-9115.log")"
assert_contains "batch log keeps applied_count" "$APPLY_FAIL_LOG" 'applied_count=2'
assert_contains "batch log gains apply_failed_count beside it" "$APPLY_FAIL_LOG" 'apply_failed_count=1'
assert_contains "batch log keeps failed_record_count" "$APPLY_FAIL_LOG" 'failed_record_count=0'
assert_eq "the three counts cover every included issue" 3 \
  "$(( $(sed -n 's/^applied_count=//p' <<< "$APPLY_FAIL_LOG") + $(sed -n 's/^apply_failed_count=//p' <<< "$APPLY_FAIL_LOG") + $(sed -n 's/^failed_record_count=//p' <<< "$APPLY_FAIL_LOG") ))"

# Queue row 897, round 2: when the model call exited 0 and more than half of
# a multi-issue batch has no valid result, the failure follows the batch, not
# each issue: scoped backoff only, no solo retry flags.
: > "$FAKE_GH_LOG"
jq -n '[911101, 911102, 911103, 911104] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
jq -nc --argjson result "$VALID" --argjson invalid "$INVALID" \
  '{issue:911101,result:$result},{issue:911102,result:$invalid},{issue:911103,result:$invalid},{issue:911104,result:$invalid}' > "$FAKE_CODEX_OUTPUT"
set +e
BATCH_LEVEL_OUTPUT="$(AGENT_TRIAGE_CAP=4 ZF_TRIAGE_TICK_ID=batch-level-9111 bash "$BATCH_SRC" --scheduled 911101 911102 911103 911104 2>&1)"
BATCH_LEVEL_STATUS=$?
set -e
assert_eq "mostly-failed batch exits cleanly" 0 "$BATCH_LEVEL_STATUS"
assert_contains "mostly-failed batch logs the batch-level line with both numbers" "$BATCH_LEVEL_OUTPUT" \
  'batch-level failure: 3 of 4 included issues have no valid result'
for n in 911102 911103 911104; do
  assert_eq "batch-level failure flags #$n for no solo retry" false "$(jq -r '.triage_batch_retry_alone // false' "$AGENT_HOME/state/$n.json")"
  assert_eq "batch-level failure still backs off #$n" true "$(jq -e --argjson now "$(date +%s)" '.model_failure_backoff.until_epoch > $now' "$AGENT_HOME/state/$n.json" >/dev/null && echo true || echo false)"
  assert_eq "batch-level backoff names the batch result caller" run-triage-batch:triage-result "$(jq -r '.model_failure_backoff.caller' "$AGENT_HOME/state/$n.json")"
done
assert_eq "the one valid result still applies" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/911101.json")"

jq -n '[911111, 911112, 911113, 911114] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
jq -nc --argjson result "$VALID" --argjson invalid "$INVALID" \
  '{issue:911111,result:$result},{issue:911112,result:$invalid},{issue:911113,result:$result},{issue:911114,result:$result}' > "$FAKE_CODEX_OUTPUT"
ZF_TRIAGE_TICK_ID=batch-onebad-9111 AGENT_TRIAGE_CAP=4 bash "$BATCH_SRC" --scheduled 911111 911112 911113 911114 >/dev/null 2>&1
assert_eq "one invalid of four still gets the solo flag" true "$(jq -r '.triage_batch_retry_alone // false' "$AGENT_HOME/state/911112.json")"

jq -n '[911121, 911122] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
jq -nc --argjson result "$VALID" --argjson invalid "$INVALID" \
  '{issue:911121,result:$result},{issue:911122,result:$invalid}' > "$FAKE_CODEX_OUTPUT"
ZF_TRIAGE_TICK_ID=batch-half-9111 bash "$BATCH_SRC" --scheduled 911121 911122 >/dev/null 2>&1
assert_eq "half failed is not more than half: the solo flag stays" true "$(jq -r '.triage_batch_retry_alone // false' "$AGENT_HOME/state/911122.json")"

# Queue row 897, round 2: a schema failure names the first failing path and
# why, and the invalid record is kept under $AGENT_HOME/triage-invalid
# instead of deleted. All three records fail, so this is also a batch-level
# failure: nobody is flagged for a solo run.
: > "$FAKE_GH_LOG"
jq -n '[911131, 911132, 911133] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
ENUM_OUT="$(jq -c '.entry_surface = "Carrier Pigeon"' <<< "$VALID")"
jq -nc --argjson enum "$ENUM_OUT" --argjson missing "$INVALID" --argjson extra "$(jq -c '. + {foo: 1}' <<< "$VALID")" \
  '{issue:911131,result:$enum},{issue:911132,result:$missing},{issue:911133,result:$extra}' > "$FAKE_CODEX_OUTPUT"
set +e
NAMING_OUTPUT="$(ZF_TRIAGE_TICK_ID=naming-91113 bash "$BATCH_SRC" --scheduled 911131 911132 911133 2>&1)"
NAMING_STATUS=$?
set -e
assert_eq "schema-failed batch exits cleanly" 0 "$NAMING_STATUS"
assert_contains "enum failure names the field path" "$NAMING_OUTPUT" 'record failed triage.schema.json: entry_surface: value not in enum'
assert_contains "missing field names the path" "$NAMING_OUTPUT" 'record failed triage.schema.json: notes_md: missing'
assert_contains "extra property names the path" "$NAMING_OUTPUT" 'record failed triage.schema.json: foo: property not allowed'
assert_not_contains "invalid records are not applied" "$(cat "$FAKE_GH_LOG")" 'issue edit 911131'
for n in 911131 911132 911133; do
  assert_eq "invalid record #$n is kept for diagnosis" 1 "$(find "$AGENT_HOME/triage-invalid" -name "$n-*.json" | wc -l | tr -d ' ')"
done
assert_contains "kept invalid record holds the offending record" "$(cat "$AGENT_HOME/triage-invalid"/911131-*.json)" 'Carrier Pigeon'

rm -rf "$AGENT_HOME/triage-invalid"
mkdir -p "$AGENT_HOME/triage-invalid"
retention_base="$(( $(date +%s) - 3600 ))"
for i in $(seq 1 50); do
  : > "$AGENT_HOME/triage-invalid/9100$i-legacy.json"
  touch -d "@$((retention_base - i))" "$AGENT_HOME/triage-invalid/9100$i-legacy.json"
done
jq -nc --argjson invalid "$INVALID" '{issue:911141,result:$invalid}' > "$FAKE_CODEX_OUTPUT"
jq -n '[911141] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
ZF_TRIAGE_TICK_ID=retention-911141 bash "$BATCH_SRC" --scheduled 911141 >/dev/null 2>&1
assert_eq "invalid-record retention keeps only the newest 50" 50 "$(find "$AGENT_HOME/triage-invalid" -type f | wc -l | tr -d ' ')"
assert_eq "the oldest kept record is dropped" 0 "$(find "$AGENT_HOME/triage-invalid" -name '910050-legacy.json' | wc -l | tr -d ' ')"
assert_eq "the newest record is kept" 1 "$(find "$AGENT_HOME/triage-invalid" -name '911141-*.json' | wc -l | tr -d ' ')"

# A batch process timeout is transient for every admitted issue: preserve the
# model-policy rung and refund the attempt charged when recording the result.
: > "$FAKE_CODEX_ARGS"
: > "$FAKE_CODEX_OUTPUT"
set +e
TIMEOUT_OUTPUT="$(FAKE_CODEX_STATUS=124 bash "$BATCH_SRC" --scheduled 910601 2>&1)"
TIMEOUT_STATUS=$?
set -e
assert_eq "timed-out batch exits cleanly for later retry" 0 "$TIMEOUT_STATUS"
assert_eq "timed-out batch refunds the failure bookkeeping attempt" 0 "$(jq -r '.attempts // 0' "$AGENT_HOME/state/910601.json")"
assert_eq "timed-out batch keeps transient retry note" 124 "$(jq -r '.model_policy.retry_note.status // 0' "$AGENT_HOME/state/910601.json")"
assert_eq "timed-out batch does not advance policy" null "$(jq -r '.model_policy.failure.transition // null' "$AGENT_HOME/state/910601.json")"

# A provider-capacity line in Codex's transcript is an environment outage,
# not a failed triage attempt. Keep the same model rung and identity.
: > "$FAKE_CODEX_ARGS"
: > "$FAKE_CODEX_OUTPUT"
jq -n '{attempts:2,model_policy:{unit:"triage",step:"work_retry"}}' \
  > "$AGENT_HOME/state/910604.json"
CAPACITY_TRANSCRIPT='Selected model is at capacity'
set +e
CAPACITY_BATCH_OUTPUT="$(FAKE_CODEX_STATUS=1 FAKE_CODEX_TRANSCRIPT="$CAPACITY_TRANSCRIPT" \
  bash "$BATCH_SRC" --scheduled 910604 2>&1)"
CAPACITY_BATCH_STATUS=$?
set -e
assert_eq "capacity batch exits cleanly for same-identity retry" 0 "$CAPACITY_BATCH_STATUS"
assert_contains "fake Codex nonzero result reaches batch failure handler" \
  "$CAPACITY_BATCH_OUTPUT" 'Codex returned exit 1'
CAPACITY_STATE="$(cat "$AGENT_HOME/state/910604.json")"
assert_eq "capacity batch refunds dispatch attempt" 2 "$(jq -r '.attempts' <<< "$CAPACITY_STATE")"
assert_eq "capacity batch keeps policy rung" work_retry "$(jq -r '.model_policy.step' <<< "$CAPACITY_STATE")"
assert_eq "capacity batch records refunded retry" true "$(jq -r '.model_policy.retry_note.attempt_refunded' <<< "$CAPACITY_STATE")"
assert_eq "capacity batch keeps Codex identity" "$MODEL_POLICY_TEST_WORK_IDENTITY" \
  "$(jq -r '.model_failure_backoff.model' <<< "$CAPACITY_STATE")"
assert_eq "capacity batch records retryable provider backoff" true \
  "$(jq -e --argjson now "$(date +%s)" \
    '.model_failure_backoff.provider == "codex" and .model_failure_backoff.until_epoch > $now' \
    >/dev/null <<< "$CAPACITY_STATE" && echo true || echo false)"
assert_eq "capacity batch does not enter failure ladder" null \
  "$(jq -r '.model_policy.failure.transition // null' <<< "$CAPACITY_STATE")"
CAPACITY_MODEL="${MODEL_POLICY_TEST_WORK_IDENTITY#codex:}"
CAPACITY_MODEL="${CAPACITY_MODEL%%:*}"
rm -f "$AGENT_HOME/codex-exhausted-until.model-$CAPACITY_MODEL.capacity"

# Codex writes provider diagnostics to transcript, while the final-output
# file is empty. A real invalid identity must stay on its rung without retry.
: > "$FAKE_CODEX_ARGS"
: > "$FAKE_CODEX_OUTPUT"
CONFIG_TRANSCRIPT="ERROR: unexpected status 404 Not Found: model ($MODEL_POLICY_TEST_WORK_MODEL) may not exist or you may not have access"
MIXED_TIMEOUT_OUTPUT="$(FAKE_CODEX_STATUS=124 FAKE_CODEX_TRANSCRIPT="$CONFIG_TRANSCRIPT" bash "$BATCH_SRC" --scheduled 910603 2>&1)"
assert_eq "timeout outranks earlier 404 transcript" 124 "$(jq -r '.model_policy.retry_note.status // 0' "$AGENT_HOME/state/910603.json")"
assert_eq "timeout with 404 text refunds attempt" 0 "$(jq -r '.attempts // 0' "$AGENT_HOME/state/910603.json")"
assert_eq "timeout with 404 text leaves config open" false "$(test -e "$AGENT_HOME/model-config-work.json" && echo true || echo false)"
CONFIG_BATCH_OUTPUT="$(FAKE_CODEX_STATUS=1 FAKE_CODEX_TRANSCRIPT="$CONFIG_TRANSCRIPT" bash "$BATCH_SRC" --scheduled 910602 2>&1)"
assert_eq "configuration transcript keeps work rung" null "$(jq -r '.model_policy.failure.transition // null' "$AGENT_HOME/state/910602.json")"
assert_eq "configuration transcript refunds failed attempt" 0 "$(jq -r '.attempts // 0' "$AGENT_HOME/state/910602.json")"
assert_eq "configuration transcript records one env fault" 1 "$(wc -l < "$AGENT_HOME/env-faults/env:model-config:work:$MODEL_POLICY_TEST_WORK_IDENTITY.log")"
assert_eq "configuration transcript leaves PAUSE absent" false "$(test -e "$AGENT_HOME/PAUSE" && echo true || echo false)"
: > "$FAKE_CODEX_ARGS"
CONFIG_REPEAT_OUTPUT="$(FAKE_CODEX_STATUS=1 FAKE_CODEX_TRANSCRIPT="$CONFIG_TRANSCRIPT" bash "$BATCH_SRC" --scheduled 910602 2>&1)"
assert_eq "identical batch configuration does not invoke Codex again" 0 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "identical batch configuration alerts once" 1 "$(grep -c "env:model-config:work:$MODEL_POLICY_TEST_WORK_IDENTITY" "$AGENT_HOME/supervisor-inbox")"
rm -f "$AGENT_HOME/model-config-work.json"

# A failed safety proof must keep worktree data intact instead of force-removing it.
: > "$FAKE_CODEX_ARGS"
jq -nc --argjson issue 910701 --argjson result "$VALID" '{issue:$issue,result:$result}' > "$FAKE_CODEX_OUTPUT"
DIRTY_BATCH_OUTPUT="$(FAKE_CODEX_DIRTY_WORKTREE=1 bash "$BATCH_SRC" --scheduled 910701 2>&1)"
DIRTY_BATCH_WT="$(find "$HOME/wt" -maxdepth 1 -type d -name 'triage-batch-run-*' -print -quit)"
assert_contains "dirty batch worktree is retained by shared finalizer" "$DIRTY_BATCH_OUTPUT" 'uncommitted or untracked files remain'
assert_eq "dirty batch worktree remains registered on disk" true "$(test -d "$DIRTY_BATCH_WT" && echo true || echo false)"
assert_eq "dirty batch output survives unit cleanup" preserve-me "$(tr -d '\n' < "$DIRTY_BATCH_WT/triage-batch-dirty.txt" | sed 's/ /-/g')"

# Issue 2025: a partial advisor apply left a ready-for-agent ticket with
# step=advisor and a stored guarded ruling. Triage resumes as measurement.
: > "$FAKE_CODEX_ARGS"
: > "$FAKE_GH_LOG"
jq -n '{
  state:"ready-for-agent",
  risk_class:"P1",
  level:"L2",
  advisor_admission_measure_only:true,
  pending_advisor_verdict:{result:{verdict:"guarded"}},
  model_policy:{unit:"triage",step:"advisor",resume_stage:"triage"}
}' > "$AGENT_HOME/state/910702.json"
jq -nc --argjson issue 910702 --argjson result "$VALID" \
  '{issue:$issue,result:$result}' > "$FAKE_CODEX_OUTPUT"
PARTIAL_BATCH_OUTPUT="$(FAKE_ISSUE_READY_FOR_AGENT=910702 bash "$BATCH_SRC" --scheduled 910702 2>&1)"
assert_eq "2025 partial apply clears stale advisor step after measurement" false \
  "$(jq '.model_policy.step == "advisor"' "$AGENT_HOME/state/910702.json")"
assert_eq "2025 partial apply sends ticket to triage model" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_contains "2025 partial apply tells model to measure only" "$(cat "$FAKE_PROMPT_CAPTURE")" "advisor already admitted this episode"
assert_not_contains "2025 partial apply never re-routes to advisor" "$(cat "$FAKE_GH_LOG")" "--add-label needs-advisor"
assert_eq "2025 successful measurement consumes admission marker" false \
  "$(jq 'has("advisor_admission_measure_only")' "$AGENT_HOME/state/910702.json")"
unset FAKE_ISSUE_READY_FOR_AGENT

# Issue #1145 (2026-11-06): a ticket whose advisor convergence pass is still
# pending (advisor_convergence_pass=true, attempts unchanged since the pass
# was granted) while its triage ladder reads step=advisor used to be routed
# through the policy-step branch on EVERY tick: route_to_advisor() keeps the
# implement route without touching labels, state or the step, and the batch
# logged one policy_step routed line each time -- most of 154 lines over
# three days for that one ticket, none of them an actual route. One ticket is
# routed once per episode: the first keep advances the ladder off the advisor
# rung (the ruling already granted the implement pass) and logs outcome=kept,
# and the next tick no longer routes the same episode.
: > "$FAKE_CODEX_ARGS"
: > "$FAKE_GH_LOG"
export MAC_AUTOPILOT_RUNTIME_DIR="$TEST_ROOT/autopi-loop"
mkdir -p "$MAC_AUTOPILOT_RUNTIME_DIR"
echo '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' "{\"lastCommit\":\"$(git -C "$ZF_REPO_DIR" rev-parse HEAD)\"}" \
  > "$ZF_REPO_DIR/.gitnexus/meta.json"
jq -n '{
  state:"ready-for-agent",
  attempts:2,
  advisor_convergence_pass:true,
  advisor_convergence_pass_attempt:2,
  model_policy:{unit:"triage",step:"advisor"}
}' > "$AGENT_HOME/state/910802.json"
jq -nc --argjson issue 910802 --argjson result "$VALID" \
  '{issue:$issue,result:$result}' > "$FAKE_CODEX_OUTPUT"
LOOP_OUTPUT_1="$(FAKE_ISSUE_READY_FOR_AGENT=910802 bash "$BATCH_SRC" --scheduled 910802 2>&1)"
assert_contains "convergence keep reports the kept implement route" "$LOOP_OUTPUT_1" \
  'repeated advisor ruling still awaits its one implement pass'
assert_eq "first tick logs exactly one policy_step line" 1 \
  "$(grep -c 'advisor-route issue=#910802 reason=policy_step' "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log")"
assert_eq "policy_step line says kept, not routed" kept \
  "$(grep 'advisor-route issue=#910802 reason=policy_step' "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log" | tail -1 | sed -n 's/.*outcome=\([a-z-]*\).*/\1/p')"
assert_eq "first tick advances the ladder off the advisor rung" false \
  "$(jq '.model_policy.step == "advisor"' "$AGENT_HOME/state/910802.json")"
assert_not_contains "the kept route never writes the needs-advisor label" "$(cat "$FAKE_GH_LOG")" '--add-label needs-advisor'
LOOP_OUTPUT_2="$(FAKE_ISSUE_READY_FOR_AGENT=910802 bash "$BATCH_SRC" --scheduled 910802 2>&1)"
assert_eq "second tick does not route the same episode again" 1 \
  "$(grep -c 'advisor-route issue=#910802 reason=policy_step' "$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log")"
assert_eq "second tick proceeds to the triage measurement" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
unset MAC_AUTOPILOT_RUNTIME_DIR FAKE_ISSUE_READY_FOR_AGENT

# Budget refusal leaves batch queued and never starts Codex.
: > "$FAKE_CODEX_ARGS"
set +e
BUDGET_BATCH_OUTPUT="$(CODEX_DAILY_TOKEN_BUDGET=100 CODEX_PRODUCTION_TOKEN_RESERVE=10 \
  CODEX_BUDGET_RESERVATION_TOKENS=100 CODEX_PRODUCTION_RESERVATION_TOKENS=10 \
  CODEX_HAND_DISPATCH_RESERVATION_TOKENS=90 bash "$BATCH_SRC" --scheduled 910703 2>&1)"
BUDGET_BATCH_STATUS=$?
set -e
assert_eq "budget-refused batch exits cleanly" 0 "$BUDGET_BATCH_STATUS"
assert_contains "budget-refused batch reports deferral" "$BUDGET_BATCH_OUTPUT" 'Codex budget/provider hold'
assert_eq "budget-refused batch never invokes Codex" 0 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "budget-refused batch does not spend issue attempt" 0 \
  "$(jq -r '.attempts // 0' "$AGENT_HOME/state/910703.json")"

# Stage prompt templates each carry a recorded byte budget (rounded up to 1 KB).
# A template over its budget fails; shrink it before raising the number here.
PROMPT_BUDGETS="$SCRIPT_DIR/prompts/byte-budgets.tsv"
for template in "$SCRIPT_DIR"/prompts/*.md; do
  name="$(basename "$template")"
  budget="$(awk -F '\t' -v n="$name" '$1 == n {print $2}' "$PROMPT_BUDGETS")"
  bytes="$(wc -c < "$template" | tr -d ' ')"
  assert_eq "prompt template $name has a recorded budget" true \
    "$([ -n "$budget" ] && echo true || echo false)"
  assert_eq "prompt template $name is within its byte budget" true \
    "$([ -n "$budget" ] && [ "$bytes" -le "$budget" ] && echo true || echo false)"
done

# Issue read through gh_issue_view_or_wait. The 404 case runs first: the 403 case starts
# gh()'s shared graphql hold, which refuses every later issue read in this AGENT_HOME.
fault_rows() { awk -F '\t' -v n="$1" '$3 == n && $4 == "env:gh-api"' "$AGENT_HOME"/env-faults/*.log 2>/dev/null; }
: > "$FAKE_CODEX_OUTPUT"
: > "$FAKE_CODEX_ARGS"
jq -n '[911583] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
echo '[]' > "$FAKE_TRIAGE_QUEUE_AFTER_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
printf 'HTTP 404: Not Found\n' > "${FAKE_GH_LOG}.view-error.911583"
set +e
NOT_FOUND_OUTPUT="$(ZF_TRIAGE_TICK_ID=not-found-911583 bash "$BATCH_SRC" --scheduled 911583 2>&1)"
NOT_FOUND_STATUS=$?
set -e
assert_eq "404 read failure does not fail the batch" 0 "$NOT_FOUND_STATUS"
assert_eq "404 read failure records one env:gh-api fault" 1 "$(fault_rows 911583 | wc -l | tr -d ' ')"
assert_contains "404 env fault carries gh's detail line" "$(fault_rows 911583)" 'HTTP 404: Not Found'
assert_contains "404 read failure keeps the snapshot-failed line" "$NOT_FOUND_OUTPUT" 'run-triage-batch: #911583 issue snapshot failed; other issues continue'

# Secondary rate limit on the read: held by the shared back-off, no fault, batch goes on.
: > "$FAKE_CODEX_OUTPUT"
: > "$FAKE_CODEX_ARGS"
jq -n '[911581, 911582] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
printf 'HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again.\n' > "${FAKE_GH_LOG}.view-error.911581"
set +e
HELD_OUTPUT="$(ZF_TRIAGE_TICK_ID=held-911581 bash "$BATCH_SRC" --scheduled 911581 911582 2>&1)"
HELD_STATUS=$?
set -e
assert_eq "held read does not fail the batch" 0 "$HELD_STATUS"
assert_contains "held read is left queued with its own line" "$HELD_OUTPUT" 'run-triage-batch: #911581 issue read held by GitHub back-off; left queued'
assert_eq "held read records no env:gh-api fault" 0 "$(fault_rows 911581 | wc -l | tr -d ' ')"
assert_contains "batch loop reaches the next issue after a held read" "$HELD_OUTPUT" 'run-triage-batch: #911582 issue read held by GitHub back-off; left queued'

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "ALL PASS"
