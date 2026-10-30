#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BATCH_SRC="$SCRIPT_DIR/run-triage-batch.sh"
TEST_ROOT="$(mktemp -d)"
export AGENT_HOME="$TEST_ROOT/agent"
export ZF_REPO_DIR="$TEST_ROOT/repo"
export REPO="test/repo"
export ZF_REPO="$REPO"
mkdir -p "$HOME/wt" "$AGENT_HOME/state" "$AGENT_HOME/night"
jq -n '{founder_login:"maintainer"}' > "$AGENT_HOME/recipients.json"
for n in 910301 910302 910303 910401 910504 910505 910506 910507 910508 910509 910703; do
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
        "$HOME/wt/triage-batch-run-"*|"$HOME/wt/triage-910301"|"$HOME/wt/triage-910302"|"$HOME/wt/triage-910303"|"$HOME/wt/triage-910401"|"$HOME/wt/triage-910504"|"$HOME/wt/triage-910505"|"$HOME/wt/triage-910506"|"$HOME/wt/triage-910507"|"$HOME/wt/triage-910508"|"$HOME/wt/triage-910509"|"$HOME/wt/triage-910703")
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
    labels='[{"name":"needs-triage"},{"name":"enhancement"}]'
    if [ "${FAKE_ISSUE_READY_FOR_AGENT:-}" = "$n" ]; then
      labels='[{"name":"ready-for-agent"},{"name":"enhancement"}]'
    fi
    state=OPEN
    view_count_file="${FAKE_GH_LOG}.views.$n"
    view_count="$(cat "$view_count_file" 2>/dev/null || echo 0)"
    view_count=$((view_count + 1))
    printf '%s\n' "$view_count" > "$view_count_file"
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
    printf '%s\n' needs-triage needs-info ready-for-agent ready-for-human needs-owner duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded bug enhancement founder-test
    ;;
  "variable get") echo 3 ;;
  "pr list") echo '[]' ;;
  "api "*)
    # The shared admission guard requires a verified native-child read.
    if [[ "${2:-}" == repos/test/repo/issues/*/sub_issues?per_page=100 ]]; then echo '[]'; else exit 1; fi
    ;;
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
  jq -nc '{category:"enhancement",state:"ready-for-agent",risk_class:"P1",level:"L1",entry_surface:"Web /chat/",acceptor:"maintainer",brief_md:"Summary: fixture.",notes_md:"No questions.",expected_packages:["packages/react-example"],expected_paths:[],estimated_changed_lines:0}'
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
jq -n '[
  {number:910301,labels:[{name:"needs-triage"}]},
  {number:910302,labels:[{name:"needs-triage"}]},
  {number:910303,labels:[{name:"needs-triage"}]},
  {number:910304,labels:[{name:"needs-triage"}]},
  {number:910305,labels:[{name:"needs-triage"},{name:"on-hold"}]},
  {number:910306,labels:[{name:"needs-triage"},{name:"pipeline-system"}]},
  {number:910307,labels:[{name:"needs-triage"}]}
]' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
jq -n '[
  {number:910302,labels:[{name:"needs-triage"}]},
  {number:910304,labels:[{name:"needs-triage"}]},
  {number:910305,labels:[{name:"needs-triage"},{name:"on-hold"}]},
  {number:910306,labels:[{name:"needs-triage"},{name:"pipeline-system"}]},
  {number:910307,labels:[{name:"needs-triage"}]}
]' > "$FAKE_TRIAGE_QUEUE_AFTER_FILE"
jq -n --argjson retry "$(( $(date +%s) + 600 ))" '{triage_retry_after_epoch:$retry}' > "$AGENT_HOME/state/910307.json"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
ZF_TRIAGE_TICK_ID=multi-ticket-9103
export ZF_TRIAGE_TICK_ID

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
assert_not_contains "skill path is decided from the agent worktree, not the repo checkout" "$(cat "$FAKE_PROMPT_CAPTURE")" 'triage=.agents/skills/triage/SKILL.md'
assert_contains "skills note is in the prompt" "$(cat "$FAKE_PROMPT_CAPTURE")" 'Matt skill files for this run'
assert_not_contains "deferred issue is absent from prompt" "$(cat "$FAKE_PROMPT_CAPTURE")" '## Issue #910304'
assert_eq "batch spend row records tokens used" 12345 "$(awk -F '\t' '$2 == "triage" {print $6}' "$AGENT_HOME"/spend/*.log)"
MULTI_BATCH_LOG="$(cat "$AGENT_HOME/logs/triage-multi-ticket-9103.log")"
assert_contains "batch log stores its tick ID" "$MULTI_BATCH_LOG" 'tick_id=multi-ticket-9103'
assert_contains "batch log stores issue sample size" "$MULTI_BATCH_LOG" 'issue_sample_size=3'
assert_contains "batch log stores total Codex tokens" "$MULTI_BATCH_LOG" 'tokens_used=12345'
assert_contains "batch log stores average tokens per issue" "$MULTI_BATCH_LOG" 'average_tokens_per_issue=4115.00'
assert_contains "batch log stores selectable count before apply" "$MULTI_BATCH_LOG" 'needs_triage_selectable_before=4'
assert_contains "batch log stores selectable count after apply" "$MULTI_BATCH_LOG" 'needs_triage_selectable_after=1'
assert_contains "batch log stores selectable count delta" "$MULTI_BATCH_LOG" 'needs_triage_selectable_delta=-3'
assert_eq "successful batch leaves no worktree behind" 0 "$(find "$HOME/wt" -maxdepth 1 -type d -name 'triage-batch-run-*' | wc -l | tr -d ' ')"

# One issue per call provides directly comparable single-ticket token baseline.
: > "$FAKE_CODEX_ARGS"
jq -n '[910310] | map({number:.,labels:[{name:"needs-triage"}]})' > "$FAKE_TRIAGE_QUEUE_BEFORE_FILE"
echo '[]' > "$FAKE_TRIAGE_QUEUE_AFTER_FILE"
printf '0\n' > "$FAKE_GH_LOG.triage-list-count"
jq -nc --argjson issue 910310 --argjson result "$VALID" '{issue:$issue,result:$result}' > "$FAKE_CODEX_OUTPUT"
ZF_TRIAGE_TICK_ID=single-ticket-910310 bash "$BATCH_SRC" --scheduled 910310 >/dev/null 2>&1
SINGLE_BATCH_LOG="$(cat "$AGENT_HOME/logs/triage-single-ticket-910310.log")"
assert_contains "single-ticket baseline log has sample size one" "$SINGLE_BATCH_LOG" 'issue_sample_size=1'
assert_contains "single-ticket baseline records its token count" "$SINGLE_BATCH_LOG" 'tokens_used=12345'
assert_contains "single-ticket baseline average equals call total" "$SINGLE_BATCH_LOG" 'average_tokens_per_issue=12345.00'
unset ZF_TRIAGE_TICK_ID

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
jq -nc '{category:"enhancement",state:"ready-for-agent",risk_class:"P1",level:"L2",entry_surface:"Web /chat/",acceptor:"maintainer",brief_md:"Summary: freshness failure fixture.",notes_md:"No questions.",expected_packages:["packages/react-example"],expected_paths:[],estimated_changed_lines:0}' \
  | jq -c --argjson issue 910504 '{issue:$issue,result:.}' > "$FAKE_CODEX_OUTPUT"
RUN_OUTPUT="$(FAKE_ISSUE_UPDATED_AT="$TEST_UPDATED_AT" bash "$BATCH_SRC" --scheduled 910504 2>&1)"
assert_not_contains "failed analyze streak bypasses batch freshness wait" "$RUN_OUTPUT" 'all candidates still require the same unconfirmed L2 freshness'
assert_contains "batch reports why it skipped the unchanged-issue deferral" "$RUN_OUTPUT" 'last 3 GitNexus analyze runs failed'
assert_eq "failed analyze streak re-admits issue to Codex" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "batch result keeps the unconfirmed L2 gate closed" needs-advisor "$(jq -r '.state' "$AGENT_HOME/state/910504.json")"
assert_eq "failed streak does not schedule a future freshness retry" true \
  "$(jq -r --argjson now "$(date +%s)" '(.triage_retry_after_epoch // 0) <= $now' "$AGENT_HOME/state/910504.json")"
assert_contains "batch decision comment explains the skipped deferral" "$(cat "$FAKE_GH_LOG")" 'last 3 GitNexus analyze runs failed'

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
jq -nc '{category:"enhancement",state:"ready-for-human",risk_class:"P1",level:"L2",entry_surface:"Web /chat/",acceptor:"maintainer",brief_md:"Summary: freshness fixture.",notes_md:"No questions.",expected_packages:["packages/react-example"],expected_paths:[],estimated_changed_lines:0}' \
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
# suppresses triage. The L2 gate still routes it to the advisor, never to the
# ready-for-agent queue.
: > "$FAKE_GH_LOG"
: > "$FAKE_CODEX_ARGS"
printf '%s\n' '{"lastCommit":"stale"}' > "$ZF_REPO_DIR/.gitnexus/meta.json"
jq -n --arg updated_at "$TEST_UPDATED_AT" --argjson since "$(( $(date +%s) - 7201 ))" \
  '{triage_retry_after_epoch:1,triage_freshness_deferred_issue_updated_at:$updated_at,triage_freshness_deferred_since_epoch:$since}' \
  > "$AGENT_HOME/state/910508.json"
jq -nc '{category:"enhancement",state:"ready-for-agent",risk_class:"P1",level:"L2",entry_surface:"Web /chat/",acceptor:"maintainer",brief_md:"Summary: stale L2 fixture.",notes_md:"No questions.",expected_packages:["packages/react-example"],expected_paths:[],estimated_changed_lines:0}' \
  | jq -c --argjson issue 910508 '{issue:$issue,result:.}' > "$FAKE_CODEX_OUTPUT"
RUN_OUTPUT="$(FAKE_ISSUE_UPDATED_AT="$TEST_UPDATED_AT" bash "$BATCH_SRC" --scheduled 910508 2>&1)"
assert_not_contains "expired freshness deferral does not skip stale L2 triage" "$RUN_OUTPUT" 'all candidates still require the same unconfirmed L2 freshness'
assert_eq "expired freshness deferral invokes Codex once" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "stale L2 result is fail-closed to advisor" needs-advisor "$(jq -r '.state' "$AGENT_HOME/state/910508.json")"
assert_contains "stale L2 result enters advisor queue" "$(cat "$FAKE_GH_LOG")" '--add-label needs-advisor'
assert_not_contains "stale L2 result never enters implement queue" "$(cat "$FAKE_GH_LOG")" '--add-label ready-for-agent'

# Maintainer-filed issues bypass an already-set freshness deadline, keep L2
# fail-closed, and receive their durable priority label during triage intake.
: > "$FAKE_CODEX_ARGS"
: > "$FAKE_GH_LOG"
printf '%s\n' '{"lastCommit":"stale"}' > "$ZF_REPO_DIR/.gitnexus/meta.json"
jq -n --arg updated_at "$TEST_UPDATED_AT" --argjson retry "$(( $(date +%s) + 600 ))" --argjson since "$(date +%s)" \
  '{triage_retry_after_epoch:$retry,triage_freshness_deferred_issue_updated_at:$updated_at,triage_freshness_deferred_since_epoch:$since}' \
  > "$AGENT_HOME/state/910509.json"
jq -nc '{category:"enhancement",state:"ready-for-agent",risk_class:"P1",level:"L2",entry_surface:"Web /chat/",acceptor:"maintainer",brief_md:"Summary: maintainer test.",notes_md:"Index freshness unconfirmed.",expected_packages:["packages/react-example"],expected_paths:[],estimated_changed_lines:0}' \
  | jq -c --argjson issue 910509 '{issue:$issue,result:.}' > "$FAKE_CODEX_OUTPUT"
RUN_OUTPUT="$(FAKE_AUTHOR=maintainer FAKE_ISSUE_UPDATED_AT="$TEST_UPDATED_AT" bash "$BATCH_SRC" --scheduled 910509 2>&1)"
assert_eq "founder-test freshness deadline does not suppress triage" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_contains "founder-filed issue gets founder-test label at intake" "$(cat "$FAKE_GH_LOG")" 'issue edit 910509 --repo test/repo --add-label founder-test'
assert_eq "founder-test stale L2 is fail-closed to advisor" needs-advisor "$(jq -r '.state' "$AGENT_HOME/state/910509.json")"
assert_contains "founder-test stale L2 enters advisor queue" "$(cat "$FAKE_GH_LOG")" '--add-label needs-advisor'
assert_not_contains "founder-test stale L2 never enters implement queue" "$(cat "$FAKE_GH_LOG")" '--add-label ready-for-agent'

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

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "ALL PASS"
