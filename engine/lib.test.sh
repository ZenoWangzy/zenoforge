#!/usr/bin/env bash
# Regression tests for lib.sh's bash functions that don't fit node --test
# (risk-class.mjs/changed-images.mjs cover the .mjs side). Plain bash
# assertions, no framework — matches this repo's ops-script test style.
#
# Output contract (#4480): a green run prints one summary line; a failing run
# prints every failing assertion ("not ok - <case>") before the FAILED tail.
# Targeted runs: `bash engine/lib.test.sh --quota-only` runs only the
# provider-quota case. Section stop switches are LIB_TEST_POST_LAND_ONLY,
# LIB_TEST_STALE_HOLD_REQUEUE_ONLY, LIB_TEST_HOLD_REQUEUE_ONLY,
# LIB_TEST_RELEASE_CLOSE_ONLY, LIB_TEST_OPS_TRANSITION_ONLY, and
# LIB_TEST_MODEL_POLICY_ONLY; each stops after its section, so preceding
# sections still run.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-lib-helpers.sh"

test_provider_quota_classification() {
  local refusal="ERROR: You’ve hit your usage limit. Try again at Oct 19th, 2099 1:13 AM." event
  assert_false "signal status never classifies even a real refusal" premium_call_is_quota_refused "$refusal" 143
  assert_false "successful exit never creates quota hold" premium_call_is_quota_refused "$refusal" 0
  assert_false "bare quota prose is not provider evidence" premium_call_is_quota_refused 'an overly broad quota regex' 1
  assert_false "bare rate limit prose is not provider evidence" premium_call_is_quota_refused 'rate limit exceeded, try again later' 1
  assert_false "bare HTTP status is not provider evidence" premium_call_is_quota_refused 'HTTP 429 Too Many Requests' 1
  assert_false "codex-error prose is not provider evidence" premium_call_is_quota_refused '2026-10-11T23:07:06Z codex-error fixing quota and rate limit' 1
  assert_true "actual Codex usage-limit line is provider evidence" premium_call_is_quota_refused "$refusal" 1
  assert_true "normalized HTTP 429 error remains supported" premium_call_is_quota_refused '{"api_error_status":429}' 1
  event="$(jq -cn --arg message "${refusal#ERROR: }" '{type:"turn.failed",error:{message:$message}}')"
  assert_true "CLI turn.failed event is provider evidence" premium_call_is_quota_refused "$event" 1
  event="$(jq -cn --arg message "${refusal#ERROR: }" '{type:"error",message:$message}')"
  assert_true "CLI error event is provider evidence" premium_call_is_quota_refused "$event" 1
  event="$(jq -cn --arg text "$refusal" '{type:"item.completed",item:{type:"agent_message",text:$text}}')"
  assert_false "agent JSON quoting refusal is not provider evidence" premium_call_is_quota_refused "$event" 1
  event="$(jq -cn --arg result "$refusal" '{is_error:true,result:$result}')"
  assert_true "run_codex_json failure envelope retains provider error" premium_call_is_quota_refused "$event" 1
  assert_false "504 containing quota prose is not quota" premium_call_is_quota_refused 'ERROR: unexpected status 504 Gateway Timeout: quota proxy unavailable' 1
  assert_false "websocket close containing quota prose is not quota" premium_call_is_quota_refused 'ERROR: websocket closed by server before response.completed: quota' 1
  assert_eq "uppercase CLI Try again parses exact reset" "$(agent_epoch 'Oct 19, 2099 1:13 AM')" "$(parse_quota_reset_epoch "$refusal")"
  assert_eq "same-day CLI reset time parses" "$(agent_epoch '1:13 AM')" "$(parse_quota_reset_epoch 'ERROR: You’ve hit your usage limit. Try again at 1:13 AM.')"
}
test_provider_quota_classification
if [[ "${1:-}" == --quota-only ]]; then lib_case_exit; fi

# lib.sh is sourced by callers whose SCRIPT_DIR is unset (merge-held.sh) or another
# directory (night/); 2026-10-08 a lib.sh helper died with "SCRIPT_DIR: unbound variable".
lib_reads_caller_script_dir() { grep -nE '\$\{?SCRIPT_DIR' "$SCRIPT_DIR/lib.sh" "$SCRIPT_DIR"/lib.d/*.sh | grep -vE '^[0-9]+:[[:space:]]*#'; }
assert_false "lib.sh never reads the caller's SCRIPT_DIR" lib_reads_caller_script_dir

test_direct_landing_product_and_revert() {
  local home repo queue issues sha output
  home="$(mktemp -d)"; repo="$home/repo"; queue="$home/land-queue"; issues="$home/issues"
  sha=0123456789abcdef0123456789abcdef01234567
  mkdir -p "$repo" "$queue/requests" "$issues" "$home/state"
  jq -n --arg sha "$sha" --arg ticket 00000000000000003203 '{ticket:$ticket,state:"landed",landed_sha:$sha,post_land_verdict:{outcome:"green"},owner:"hand-3203",owned_issues:""}' \
    > "$queue/requests/00000000000000003203.json"
  jq -n --arg sha "$sha" --arg ticket 00000000000000003204 '{ticket:$ticket,state:"landed",landed_sha:$sha,post_land_verdict:{outcome:"culprit-reverted"},owner:"hand-3204",owned_issues:""}' \
    > "$queue/requests/00000000000000003204.json"
  jq -n '{number:3203,state:"OPEN",labels:[{name:"needs-triage"}],title:"product fix",comments:[]}' > "$issues/3203.json"
  jq -n '{number:3204,state:"OPEN",labels:[{name:"pipeline-system"},{name:"on-hold"}],title:"reverted fix",comments:[]}' > "$issues/3204.json"
  printf '%s\n' '{"state":"on-hold","hold":{}}' > "$home/state/3204.json"
  if ! output="$(AGENT_HOME="$home" ZF_REPO_DIR="$repo" ZF_LAND_QUEUE_DIR="$queue" \
      ZF_REPO=test/repo QUEUE_CLOSE_ISSUES="$issues" QUEUE_CLOSE_WRITES="$home/writes" \
      QUEUE_CLOSE_TRANSITIONS="$home/transitions" QUEUE_CLOSE_REQUEUES="$home/requeues" \
      QUEUE_CLOSE_DISPATCHES="$home/dispatches" QUEUE_CLOSE_HOLDS="$home/holds" \
      bash -c '
        set -euo pipefail
        source "$1/lib.sh"
        gh() { [[ "${1:-}" == issue && "${2:-}" == view ]] && cat "$QUEUE_CLOSE_ISSUES/${3}.json"; }
        guarded_write() { printf "%s\n" "$*" >> "$QUEUE_CLOSE_WRITES"; }
        issue_transition() { printf "%s %s %s\n" "$1" "$2" "$3" >> "$QUEUE_CLOSE_TRANSITIONS"; }
        state_requeue() { printf "%s\n" "$*" >> "$QUEUE_CLOSE_REQUEUES"; }
        scheduler_requeue_issue() {
          printf "%s %s\n" "$1" "$2" >> "$QUEUE_CLOSE_DISPATCHES"
          state_requeue "$1" release-hold hold-requeue "$7"
          SCHEDULER_REQUEUE_RESULT=requeued
        }
        hold_issue() { printf "%s\n" "$*" >> "$QUEUE_CLOSE_HOLDS"; }
        pipeline_system_finish_direct_landing "$ZF_LAND_QUEUE_DIR/requests/00000000000000003203.json" green
        [[ ! -s "$QUEUE_CLOSE_WRITES" && ! -s "$QUEUE_CLOSE_TRANSITIONS" ]]
        pipeline_system_finish_direct_landing "$ZF_LAND_QUEUE_DIR/requests/00000000000000003204.json" culprit-reverted
        grep -Fq "3204 release-hold hold-requeue" "$QUEUE_CLOSE_REQUEUES"
        grep -Fq "3204 direct-main landing reverted by post-land verification" "$QUEUE_CLOSE_DISPATCHES"
        [[ ! -s "$QUEUE_CLOSE_HOLDS" ]]
      ' _ "$SCRIPT_DIR" 2>&1)"; then
    printf '%s\n' "$output" >&2
    echo 'not ok - product issue skip or culprit-reverted requeue failed' >&2
    FAILED=1
  else
    ok 'product owner issue stays open after landing'
    ok 'culprit-reverted product scope is requeued without a hand hold'
  fi
  rm -rf -- "$home"
}

if [[ "${LIB_TEST_POST_LAND_ONLY:-0}" == 1 ]]; then
  test_direct_landing_product_and_revert
  lib_case_exit
fi

test_stale_hold_requeue() {
  local home="$INBOX_HELPER_HOME/stale-hold-requeue" output
  mkdir -p "$home/state"
  jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$home/model-policy.json"
  output="$(AGENT_HOME="$home" DRY_RUN=0 AGENT_DRY_RUN=0 REPO=test/repo bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    ensure_state_labels() { :; }
    recut_parent_has_open_child() { return 1; }
    is_on_hold() { return 0; }
    guarded_write() { printf "%s\\n" "$*" >> "$AGENT_HOME/label-writes"; }
    printf "%s\\n" '\''{"state":"ready-for-agent","hold":null,"attempts":1}'\'' > "$STATE_DIR/740031.json"
    if state_requeue 740031; then echo ordinary-requeue-accepted; exit 1; fi
    test "$(jq -r .state "$STATE_DIR/740031.json")" = ready-for-agent
    echo ordinary-requeue-refused
    state_requeue 740031 release-hold
    jq -e '\''.state == "ready-for-agent" and .hold == null and .attempts == 0'\'' "$STATE_DIR/740031.json" >/dev/null
    grep -F -- '\''--remove-label on-hold'\'' "$AGENT_HOME/label-writes" >/dev/null
    echo explicit-hold-requeue-accepted

    printf "%s\\n" '\''{"attempts":1}'\'' > "$STATE_DIR/740032.json"
    state_requeue 740032 release-hold
    jq -e '\''.state == "ready-for-agent" and .hold == null and .attempts == 0'\'' "$STATE_DIR/740032.json" >/dev/null
    echo explicit-hold-requeue-accepts-untracked-state
  ' _ "$SCRIPT_DIR" 2>&1)" || {
    printf '%s\n' "$output" >&2
    FAILED=1
    return
  }
  assert_contains "ordinary requeue still respects on-hold" "$output" "ordinary-requeue-refused"
  assert_contains "explicit hold requeue clears stale label after local state advanced" \
    "$output" "explicit-hold-requeue-accepted"
  assert_contains "explicit hold requeue recovers missing local state" \
    "$output" "explicit-hold-requeue-accepts-untracked-state"
}

test_stale_hold_requeue

test_hold_requeue_child_status_consistency() {
  local home="$INBOX_HELPER_HOME/hold-requeue-child-status" output
  mkdir -p "$home/state"
  jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$home/model-policy.json"
  for issue in 740041 740042 740043; do
    child=$((issue + 100))
    printf '{"state":"on-hold","attempts":2,"recut_children":[%s],"hold":{"holder":"supervisor","release_condition":"child status confirmed","expires_at":"2026-10-07T19:36:50Z","stage_before":"ready-for-agent","kind":"manual"}}\n' "$child" \
      > "$home/state/$issue.json"
  done
  output="$(AGENT_HOME="$home" REPO=test/repo SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    set -euo pipefail
    source "$SCRIPT_DIR/lib.sh"
    ensure_state_labels() { :; }
    mkdir -p "$AGENT_HOME/child-reads" "$AGENT_HOME/fake-labels"
    printf "%s\\n" on-hold > "$AGENT_HOME/fake-labels/740041"
    printf "%s\\n" on-hold > "$AGENT_HOME/fake-labels/740042"
    # #1598 had an expired local hold while GitHub retained product-stage labels.
    printf "%s\\n" enhancement\|awaiting-release\|ready-for-human > "$AGENT_HOME/fake-labels/740043"
    gh() {
      if [[ "${1:-} ${2:-}" == "issue view" ]]; then
        local child="$3" reads=0
        [[ ! -f "$AGENT_HOME/child-reads/$child" ]] || reads="$(cat "$AGENT_HOME/child-reads/$child")"
        printf "%s\\n" "$((reads + 1))" > "$AGENT_HOME/child-reads/$child"
        case "$child:$reads" in 740141:0|740142:1) return 1 ;; esac
        echo CLOSED
        return 0
      fi
      if [[ "${1:-} ${2:-}" == "issue edit" ]]; then
        local issue="$3" label remove label_file="$AGENT_HOME/fake-labels/$3"
        local -a labels=() next=()
        shift 3
        IFS="|" read -r -a labels < "$label_file"
        while (($#)); do
          case "$1" in
            --remove-label)
              remove="$2"; next=()
              for label in "${labels[@]}"; do [[ "$label" == "$remove" ]] || next+=("$label"); done
              labels=("${next[@]}"); shift 2 ;;
            --add-label)
              label="$2"
              if [[ ! " ${labels[*]} " == *" $label "* ]]; then labels+=("$label"); fi
              shift 2 ;;
            *) shift ;;
          esac
        done
        (IFS="|"; printf "%s\\n" "${labels[*]}") > "$label_file"
        return 0
      fi
      return 1
    }

    if state_requeue 740041 release-hold; then echo unknown-first-read-accepted; exit 1; fi
    jq -e '\''.state == "on-hold" and .hold != null'\'' "$STATE_DIR/740041.json" >/dev/null
    [[ "$(cat "$AGENT_HOME/fake-labels/740041")" == on-hold ]]

    if state_requeue 740042 release-hold; then echo unknown-second-read-accepted; exit 1; fi
    jq -e '\''.state == "on-hold" and .hold != null'\'' "$STATE_DIR/740042.json" >/dev/null
    [[ "$(cat "$AGENT_HOME/fake-labels/740042")" == on-hold ]]

    state_requeue 740043 release-hold
    jq -e '\''.state == "ready-for-agent" and .hold == null'\'' "$STATE_DIR/740043.json" >/dev/null
    [[ "$(cat "$AGENT_HOME/fake-labels/740043")" == "enhancement|ready-for-agent" ]]
    echo hold-requeue-label-consistency-passed
  ' 2>&1)" || {
    printf '%s\n' "$output" >&2
    FAILED=1
    return
  }
  assert_contains "unknown child state leaves held state and GitHub label unchanged" \
    "$output" "cannot verify children for #740041"
  assert_contains "second unknown child read aborts the partial state transition" \
    "$output" "hold-requeue-label-consistency-passed"
  assert_contains "hold requeue clears stale GitHub stages and restores ready-for-agent" \
    "$output" "hold-requeue-label-consistency-passed"
}

test_hold_requeue_child_status_consistency
if [ "${LIB_TEST_STALE_HOLD_REQUEUE_ONLY:-0}" = 1 ] || [ "${LIB_TEST_HOLD_REQUEUE_ONLY:-0}" = 1 ]; then lib_case_exit; fi

# Release conclusions use the exact PR's actual merge time, not handoff time.
RELEASE_CLOSE_HOME="$INBOX_HELPER_HOME/release-close"
mkdir -p "$RELEASE_CLOSE_HOME/state"
RELEASE_CLOSE_OUT="$(AGENT_HOME="$RELEASE_CLOSE_HOME" DRY_RUN=0 AGENT_DRY_RUN=0 ZF_REPO=test/repo bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  ensure_state_labels() { :; }
  is_on_hold() { return 1; }
  guarded_write() { :; }
  gh() {
    [[ "$1" == api && "$2" == repos/test/repo/pulls/795 ]] || return 1
    printf "%s\n" '\''{"number":795,"merged":true,"base":{"ref":"main"},"merge_commit_sha":"0123456789abcdef0123456789abcdef01234567","merged_at":"2026-10-07T10:00:00Z"}'\''
  }
  seed='\''{"state":"awaiting-release","deploy_state":"deployed","requeued_at":"2026-10-07T09:00:00Z","run":{"outcome":"merged","merged_at":"2026-10-07T11:00:00Z","evidence":{"pr_number":795}}}'\''
  for started in null '\''"2026-10-07T08:00:00Z"'\''; do
    jq --argjson started "$started" '\''.run.implement_started_at = $started'\'' <<< "$seed" > "$STATE_DIR/740050.json"
    merged_pr_for_issue 740050 >/dev/null
    if issue_transition 740050 concluded conclude:deployed; then echo merged-after-requeue=accepted; else echo merged-after-requeue=refused; fi
  done
  jq '\''.run.implement_started_at = "2026-10-07T08:00:00Z" | .run.evidence.merged_pr = {number:795,merged_at:"2026-10-07T08:59:59Z",merge_sha:"old-sha"}'\'' <<< "$seed" > "$STATE_DIR/740050.json"
  if issue_transition 740050 concluded conclude:deployed; then echo old-merge=accepted; else echo old-merge=refused; fi
  state_merge 740050 '\''.run.evidence.merged_pr.merged_at = "2026-10-07T10:00:00Z" | .run.evidence.merged_pr.number = 796'\''
  if issue_transition 740050 concluded conclude:deployed; then echo other-pr=accepted; else echo other-pr=refused; fi
  state_merge 740050 '\''.run.evidence.merged_pr.number = 795'\''
  if issue_transition 740050 concluded conclude:failed; then echo failed-run=accepted; else echo failed-run=refused; fi
  sha=0123456789abcdef0123456789abcdef01234567
  next_sha=1123456789abcdef0123456789abcdef01234567
  state_merge 740050 '\''.release_close_refusals = {"0123456789abcdef0123456789abcdef01234567":"close-contract-failed"}'\''
  if release_close_refusal_seen 740050 "$sha"; then echo legacy-contract=skipped; else echo legacy-contract=retried; fi
  release_close_refusal_record 740050 "$sha" close-contract-failed
  if release_close_refusal_seen 740050 "$next_sha"; then echo new-sha=skipped; else echo new-sha=retried; fi
  state_merge 740050 '\''.requeued_at = "2026-10-08T09:00:00Z"'\''
  if release_close_refusal_seen 740050 "$sha"; then echo new-requeue=skipped; else echo new-requeue=retried; fi
  release_close_refusal_record 740050 "$sha" acceptance-evidence-rejected
  if release_close_refusal_seen 740050 "$sha"; then echo same-acceptance-sha=skipped; else echo same-acceptance-sha=retried; fi
  if release_close_refusal_seen 740050 "$next_sha"; then echo new-acceptance-sha=skipped; else echo new-acceptance-sha=retried; fi
' _ "$SCRIPT_DIR" 2>&1)"
assert_eq "merged-after-requeue concludes with missing or old implement start" 2 \
  "$(grep -c 'merged-after-requeue=accepted' <<< "$RELEASE_CLOSE_OUT" || true)"
assert_contains "old PR merge refuses despite newer handoff timestamp" "$RELEASE_CLOSE_OUT" "old-merge=refused"
assert_contains "merge evidence for another PR cannot bypass stale guard" "$RELEASE_CLOSE_OUT" "other-pr=refused"
assert_contains "new merge does not authorize stale failed-run conclusion" "$RELEASE_CLOSE_OUT" "failed-run=refused"
assert_contains "unchanged state revision skips a different deployed SHA" "$RELEASE_CLOSE_OUT" "new-sha=skipped"
assert_contains "legacy SHA contract refusal is reassessed once" "$RELEASE_CLOSE_OUT" "legacy-contract=retried"
assert_contains "new requeue retries prior close refusal" "$RELEASE_CLOSE_OUT" "new-requeue=retried"
assert_contains "acceptance rejection skips same SHA" "$RELEASE_CLOSE_OUT" "same-acceptance-sha=skipped"
assert_contains "acceptance rejection retries new SHA" "$RELEASE_CLOSE_OUT" "new-acceptance-sha=retried"

# Unbounded reasons must stay out of jq argv through transitions and release
# refusal state, including both comment dedupe and first-comment paths.
RELEASE_CLOSE_LONG_REASON_HOME="$INBOX_HELPER_HOME/release-close-long-reason"
mkdir -p "$RELEASE_CLOSE_LONG_REASON_HOME/state"
cat > "$INBOX_HELPER_HOME/release-close-long-reason.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$1/lib.sh"
ensure_state_labels() { :; }
is_on_hold() { return 1; }
guarded_write() { :; }
reason="conclude:$(head -c 131072 /dev/zero | tr '\0' x)"
[ "${#reason}" -gt 131072 ] || { echo reason-not-long-enough >&2; exit 90; }
printf '%s\n' '{"state":"awaiting-release"}' > "$STATE_DIR/740051.json"
issue_transition 740051 concluded "$reason" . 1 || { echo transition-failed >&2; exit 91; }
expected_file="$(jq_arg_file "$reason")"
sha=0123456789abcdef0123456789abcdef01234567
release_close_refusal_record 740051 "$sha" "$reason" || { echo refusal-record-failed >&2; exit 92; }
gh() { printf '%s\n' '{"comments":[]}'; }
guarded_issue_comment() { :; }
release_close_refusal_comment_once 740051 "$reason" body || { echo large-comment-failed >&2; exit 93; }
jq --rawfile expected "$expected_file" --arg sha "$sha" -e \
  '.state == "concluded" and .release_close_refusals[$sha] == $expected and .release_close_last_comment_reason == $expected' \
  "$STATE_DIR/740051.json" >/dev/null || { echo large-reason-state-mismatch >&2; exit 94; }
rm -f -- "$expected_file"

printf '%s\n' '{}' > "$STATE_DIR/740052.json"
gh() {
  cat <<'JSON'
[ {"body":"this ticket's acceptance evidence did not satisfy its close contract"} ]
JSON
}
guarded_issue_comment() { echo called >> "$STATE_DIR/comment-attempted"; }
release_close_refusal_comment_once 740052 acceptance-evidence-rejected body || { echo dedupe-comment-failed >&2; exit 95; }
[ ! -e "$STATE_DIR/comment-attempted" ] || { echo dedupe-comment-was-posted >&2; exit 97; }
jq -e '.release_close_last_comment_reason == "acceptance-evidence-rejected"' \
  "$STATE_DIR/740052.json" >/dev/null || { echo dedupe-state-mismatch >&2; exit 96; }
EOF
chmod +x "$INBOX_HELPER_HOME/release-close-long-reason.sh"
RELEASE_CLOSE_LONG_REASON_OUT="$(AGENT_HOME="$RELEASE_CLOSE_LONG_REASON_HOME" DRY_RUN=0 AGENT_DRY_RUN=0 REPO=test/repo \
  bash "$INBOX_HELPER_HOME/release-close-long-reason.sh" "$SCRIPT_DIR" 2>&1 && printf '%s\n' LARGE_REASON_OK)" || FAILED=1
if [[ "$RELEASE_CLOSE_LONG_REASON_OUT" != *LARGE_REASON_OK* ]]; then
  printf 'large-reason fixture failed: %s\n' "$RELEASE_CLOSE_LONG_REASON_OUT" >&2
fi
assert_contains "128 KiB reasons survive transition, refusal record, and comment state" \
  "$RELEASE_CLOSE_LONG_REASON_OUT" "LARGE_REASON_OK"
if [ "${LIB_TEST_RELEASE_CLOSE_ONLY:-0}" = 1 ]; then lib_case_exit; fi

# A blocked local-check receipt must stop the existing success terminal.
# Keep this regression near startup so its red line is visible before the
# larger shell suite reaches its slow fixture runs.
CONCLUDE_RED_HOME="$INBOX_HELPER_HOME/conclude-red"
mkdir -p "$CONCLUDE_RED_HOME/state"
echo '{"attempts":1,"run":{"evidence":{"pr_number":776,"pr_head_sha":"0123456789abcdef0123456789abcdef01234567","mandatory_checks":{"status":"blocked","head_sha":"0123456789abcdef0123456789abcdef01234567"}}}}' \
  > "$CONCLUDE_RED_HOME/state/500026.json"
CONCLUDE_RED_OUT="$(
  AGENT_HOME="$CONCLUDE_RED_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500026 merged ""
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "blocked mandatory checks refuse merged outcome" \
  "$CONCLUDE_RED_OUT" "refusing outcome=merged for #500026 -- mandatory checks are blocked"
assert_not_contains "blocked mandatory checks never reach awaiting-release" \
  "$CONCLUDE_RED_OUT" "--add-label awaiting-release"

BLOCKED_CHECKS_HOME="$INBOX_HELPER_HOME/blocked-checks"
BLOCKED_CHECKS_LOG="$INBOX_HELPER_HOME/blocked-checks.log"
BLOCKED_CHECKS_GH_LOG="$INBOX_HELPER_HOME/blocked-checks-gh.log"
mkdir -p "$BLOCKED_CHECKS_HOME/state"
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$BLOCKED_CHECKS_HOME/model-policy.json"
printf '%s\n' 'BLOCKED-CHECKS: uv run pytest packages/example-pack/runtime/agent — connect EPERM 127.0.0.1:5432' \
  > "$BLOCKED_CHECKS_LOG"
BLOCKED_CHECKS_OUT="$(
  AGENT_HOME="$BLOCKED_CHECKS_HOME" AGENT_DRY_RUN=0 DRY_RUN=0 REPO="test/repo" \
    BLOCKED_CHECKS_GH_LOG="$BLOCKED_CHECKS_GH_LOG" BLOCKED_CHECKS_LOG="$BLOCKED_CHECKS_LOG" bash -c '
      source "$0/lib.sh"
      ensure_state_labels() { :; }
      guarded_write() { printf "%s\n" "$*" >> "$BLOCKED_CHECKS_GH_LOG"; }
      record_implement_blocked_checks 500027 "$0" "$BLOCKED_CHECKS_LOG"
      state_read 500027 | jq -r "[.state,.run.outcome,.run.evidence.mandatory_checks.status,.run.evidence.mandatory_checks.summary,(.run.concluded_at // \"no-conclusion\")] | @tsv"
    ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "blocked-check report routes ticket to open checks-blocked state" \
  "$BLOCKED_CHECKS_OUT" $'checks-blocked\tchecks-blocked\tblocked\tuv run pytest packages/example-pack/runtime/agent — connect EPERM 127.0.0.1:5432\tno-conclusion'
assert_true "blocked-check report removes dispatch labels and applies checks-blocked" \
  grep -Fq -- '--add-label checks-blocked' "$BLOCKED_CHECKS_GH_LOG"
printf '%s\n' 'BLOCKED-CHECKS: AGENT_HOME=/tmp/x bash engine/check-rulings.sh — systemd user bus: Operation not permitted' \
  > "$BLOCKED_CHECKS_LOG"
RULINGS_ONLY_STATUS=0
AGENT_HOME="$BLOCKED_CHECKS_HOME" REPO="test/repo" BLOCKED_CHECKS_LOG="$BLOCKED_CHECKS_LOG" bash -c '
  source "$0/lib.sh"
  guarded_write() { echo "unexpected write: $*" >&2; return 9; }
  record_implement_blocked_checks 500028 "$0" "$BLOCKED_CHECKS_LOG"
' "$SCRIPT_DIR" || RULINGS_ONLY_STATUS=$?
assert_eq "check-rulings is never a blocked check: push preflight runs it outside the sandbox" 1 "$RULINGS_ONLY_STATUS"
printf '%s\n' 'BLOCKED-CHECKS: git diff --check origin/main...HEAD — 无法创建提交；Git 元数据目录只读。' \
  > "$BLOCKED_CHECKS_LOG"
GIT_ONLY_STATUS=0
AGENT_HOME="$BLOCKED_CHECKS_HOME" REPO="test/repo" BLOCKED_CHECKS_LOG="$BLOCKED_CHECKS_LOG" bash -c '
  source "$0/lib.sh"
  guarded_write() { echo "unexpected write: $*" >&2; return 9; }
  record_implement_blocked_checks 500029 "$0" "$BLOCKED_CHECKS_LOG"
' "$SCRIPT_DIR" || GIT_ONLY_STATUS=$?
assert_eq "git diff --check and the commit are never blocked checks: the wrapper runs them" 1 "$GIT_ONLY_STATUS"
printf '%s\n' 'BLOCKED-CHECKS: node --test engine/*.test.mjs — Network access to "registry.npmjs.org" was blocked' \
  > "$BLOCKED_CHECKS_LOG"
SCRIPT_TEST_STATUS=0
AGENT_HOME="$BLOCKED_CHECKS_HOME" REPO="test/repo" BLOCKED_CHECKS_LOG="$BLOCKED_CHECKS_LOG" bash -c '
  source "$0/lib.sh"
  guarded_write() { echo "unexpected write: $*" >&2; return 9; }
  record_implement_blocked_checks 500030 "$0" "$BLOCKED_CHECKS_LOG"
' "$SCRIPT_DIR" || SCRIPT_TEST_STATUS=$?
assert_eq "script test suites are never blocked checks: the wrapper reruns changed ones" 1 "$SCRIPT_TEST_STATUS"
DOWNSTREAM_N=500031
for downstream_line in \
  'BLOCKED-CHECKS: `pnpm --filter @agent-runtime/shared test` — `tsx` 创建 `/tmp/tsx-1000/19.pipe` 失败：`listen EPERM`' \
  'BLOCKED-CHECKS: `gitnexus impact updateCloudClient --direction upstream` — index lock busy' \
  'BLOCKED-CHECKS: `docker run --rm zf-example-gateway:parity` — 本机无 Docker 命令或 daemon。' \
  'BLOCKED-CHECKS: `gh issue view 1937 --json state` — 本轮明确禁止运行 `gh`。' \
  'BLOCKED-CHECKS: `/admin/logs` 在 390px 的浏览器验收 — 无浏览器' \
  'BLOCKED-CHECKS: `git fetch origin main` — error: cannot open FETCH_HEAD: Read-only file system'; do
  printf '%s\n' "$downstream_line" > "$BLOCKED_CHECKS_LOG"
  DOWNSTREAM_STATUS=0
  AGENT_HOME="$BLOCKED_CHECKS_HOME" REPO="test/repo" BLOCKED_CHECKS_LOG="$BLOCKED_CHECKS_LOG" bash -c '
    source "$0/lib.sh"
    guarded_write() { echo "unexpected write: $*" >&2; return 9; }
    record_implement_blocked_checks "$1" "$0" "$BLOCKED_CHECKS_LOG"
  ' "$SCRIPT_DIR" "$DOWNSTREAM_N" || DOWNSTREAM_STATUS=$?
  assert_eq "downstream-owned check is never a blocked check: ${downstream_line:16:40}" 1 "$DOWNSTREAM_STATUS"
  DOWNSTREAM_N=$((DOWNSTREAM_N + 1))
done

SANDBOX_SIGNATURE_N=500040
for sandbox_signature in \
  'blocked by the sandbox policy' \
  'systemctl --user: Operation not permitted on user bus' \
  '`gh` disabled by execution policy' \
  'Read-only file system' \
  'tsx pipe EPERM'; do
  printf 'BLOCKED-CHECKS: uv run pytest tests/required_check.py — %s\n' "$sandbox_signature" \
    > "$BLOCKED_CHECKS_LOG"
  SANDBOX_MISREPORT_STATUS=0
  AGENT_HOME="$BLOCKED_CHECKS_HOME" ZF_CODEX_SANDBOX=danger-full-access REPO=test/repo \
    BLOCKED_CHECKS_LOG="$BLOCKED_CHECKS_LOG" bash -c '
      source "$0/lib.sh"
      ensure_state_labels() { :; }
      guarded_write() { echo "unexpected write: $*" >&2; return 9; }
      record_implement_blocked_checks "$1" "$0" "$BLOCKED_CHECKS_LOG"
    ' "$SCRIPT_DIR" "$SANDBOX_SIGNATURE_N" || SANDBOX_MISREPORT_STATUS=$?
  assert_eq "unsandboxed run ignores sandbox-only marker: $sandbox_signature" 1 "$SANDBOX_MISREPORT_STATUS"
  assert_false "unsandboxed sandbox marker does not create issue state: $SANDBOX_SIGNATURE_N" \
    test -e "$BLOCKED_CHECKS_HOME/state/$SANDBOX_SIGNATURE_N.json"
  SANDBOX_SIGNATURE_N=$((SANDBOX_SIGNATURE_N + 1))
done

BLOCKED_REPEAT_N=500050
BLOCKED_REPEAT_SHA="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
jq -cn --arg head "$BLOCKED_REPEAT_SHA" \
  '{attempts:1,state:"ready-for-agent",checks_blocked:{auto_requeued_head_sha:$head}}' \
  > "$BLOCKED_CHECKS_HOME/state/$BLOCKED_REPEAT_N.json"
printf '%s\n' 'BLOCKED-CHECKS: uv run pytest tests/required_check.py — connection refused at 127.0.0.1:5432' \
  > "$BLOCKED_CHECKS_LOG"
AGENT_HOME="$BLOCKED_CHECKS_HOME" AGENT_DRY_RUN=0 DRY_RUN=0 REPO=test/repo \
  BLOCKED_CHECKS_LOG="$BLOCKED_CHECKS_LOG" BLOCKED_CHECKS_GH_LOG="$BLOCKED_CHECKS_GH_LOG" \
  bash -c '
    source "$0/lib.sh"
    ensure_state_labels() { :; }
    for transition_state in "${ALL_STATE_LABELS[@]}" on-hold tracker untracked; do
      issue_transition_state_is_valid "$transition_state" || exit 13
    done
    issue_transition_allowed awaiting-release released deployment-proven || exit 14
    if issue_transition_allowed awaiting-release released pipeline-requeue; then exit 15; fi
    issue_transition_allowed untracked tracker intake-parent:roadmap-container:spec/ADR-pilot || exit 16
    issue_transition_allowed ready-for-agent tracker intake-parent:roadmap-container:has-sub-issues || exit 17
    if issue_transition_allowed needs-triage tracker intake-parent:roadmap-container:spec/ADR-pilot; then exit 18; fi
    issue_transition_allowed needs-recut tracker intake-parent:roadmap-container:split-delivery || exit 19
    if issue_transition_allowed needs-recut tracker intake-parent:roadmap-container:has-sub-issues; then exit 20; fi
    guarded_write() { printf "%s\n" "$*" >> "$BLOCKED_CHECKS_GH_LOG"; }
    record_implement_blocked_checks "$1" "$0" "$BLOCKED_CHECKS_LOG"
    record_implement_blocked_checks "$1" "$0" "$BLOCKED_CHECKS_LOG"
  ' "$SCRIPT_DIR" "$BLOCKED_REPEAT_N"
assert_eq 'same-head repeat block escalates once' 1 \
  "$(grep -cF 'checks-blocked-repeat issue=#500050' "$BLOCKED_CHECKS_HOME/supervisor-inbox" || true)"
assert_contains 'repeat escalation names blocked check and head' \
  "$(cat "$BLOCKED_CHECKS_HOME/supervisor-inbox")" \
  "checks-blocked-repeat issue=#500050 head=$BLOCKED_REPEAT_SHA action=review-required-checks checks=uv run pytest tests/required_check.py — connection refused at 127.0.0.1:5432"
assert_eq 'repeat escalation is recorded in issue state' "$BLOCKED_REPEAT_SHA" \
  "$(jq -r '.checks_blocked.escalated_head_sha' "$BLOCKED_CHECKS_HOME/state/$BLOCKED_REPEAT_N.json")"

EMPTY_EPOCH_NOW="$(date +%s)"
EMPTY_EPOCH_TZ_MIN=$(( (1440 - (EMPTY_EPOCH_NOW / 60) % 1440 + 1) % 1440 ))
export TZ="PIN-$((EMPTY_EPOCH_TZ_MIN / 60)):$((EMPTY_EPOCH_TZ_MIN % 60))"
assert_false 'shared epoch parser rejects empty timestamp' agent_epoch ''
assert_false 'empty PR updatedAt cannot enter the grace window as local midnight' \
  pr_untouched_for_grace '' 0 "$EMPTY_EPOCH_NOW"

INBOX_WRITER_VIOLATIONS="$(python3 - "$SCRIPT_DIR" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
violations = []
for path in sorted(root.rglob('*.sh')):
    if path.name.endswith('.test.sh'):
        continue
    lines = path.read_text(errors='replace').splitlines()
    inbox_vars = set()
    for line in lines:
        code = '' if line.lstrip().startswith('#') else line
        match = re.search(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*[^;\n]*supervisor-inbox', code)
        if match:
            inbox_vars.add(match.group(1))
    in_helper = False
    for number, line in enumerate(lines, 1):
        code = '' if line.lstrip().startswith('#') else line
        if (
            path == root / 'lib.sh'
            and re.match(r'^supervisor_inbox_append(?:_once)?\(\)\s*\{', line)
        ) or (
            path == root / 'model-policy-fast-forward.sh'
            and re.match(r'^model_policy_fast_forward_alert\(\)\s*\{', line)
        ):
            # This fallback must append when invalid policy prevents loading lib.sh.
            in_helper = True
        if '>>' in code:
            direct = 'supervisor-inbox' in code
            indirect = any(
                re.search(r""">>\s*["']?\$""" + re.escape(var) + r"\b", code)
                for var in inbox_vars
            )
            if (direct or indirect) and not in_helper:
                violations.append(f'{path.relative_to(root.parent.parent)}:{number}')
        if in_helper and line == '}':
            in_helper = False
print('\n'.join(violations))
PY
)"
assert_eq 'production inbox writes use shared helper or the lib-unavailable fallback' '' "$INBOX_WRITER_VIOLATIONS"
# Only main-targeted merged PRs may enter release state.
MERGED_PR_BASE_OUT="$(ZF_REPO=test/repo bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  gh() {
    [[ "$1" == api && "$#" -eq 2 ]] || return 1
    case "$2" in
      repos/test/repo/pulls/795)
        printf "%s\n" '\''{"number":795,"merged":true,"base":{"ref":"main"},"merge_commit_sha":"main-sha","merged_at":"2026-11-04T19:54:15Z"}'\''
        ;;
      repos/test/repo/pulls/796)
        printf "%s\n" '\''{"number":796,"merged":true,"base":{"ref":"agent/issue-795"},"merge_commit_sha":"feature-sha","merged_at":"2026-11-04T19:54:15Z"}'\''
        ;;
      repos/test/repo/pulls/797)
        printf "%s\n" '\''{"number":797,"merged":false,"base":{"ref":"main"},"merge_commit_sha":"test-merge-sha","merged_at":null}'\''
        ;;
      *) return 1 ;;
    esac
  }
  printf "main=%s\n" "$(merged_pr_main_row 795)"
  if merged_pr_main_row 796 >/dev/null; then echo feature=accepted; else echo feature=rejected; fi
  if merged_pr_main_row 797 >/dev/null; then echo unmerged=accepted; else echo unmerged=rejected; fi
' _ "$SCRIPT_DIR")"
assert_eq 'merged PR resolver requires a merged PR targeting main' $'main=795\tmain-sha\nfeature=rejected\nunmerged=rejected' "$MERGED_PR_BASE_OUT"

MERGED_PR_GUARD_HOME="$(mktemp -d)"
mkdir -p "$MERGED_PR_GUARD_HOME/state"
printf '%s\n' '{"state":"implement","attempts":1}' > "$MERGED_PR_GUARD_HOME/state/510008.json"
MERGED_PR_GUARD_OUT="$(AGENT_HOME="$MERGED_PR_GUARD_HOME" ZF_REPO=test/repo bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  gh() {
    [[ "$1" == api && "$2" == repos/test/repo/pulls/796 ]] || return 1
    printf "%s\n" '\''{"number":796,"merged":true,"base":{"ref":"agent/issue-795"},"merge_commit_sha":"feature-sha","merged_at":"2026-11-04T19:54:15Z"}'\''
  }
  if conclude_merged_run 510008 796; then echo accepted; else echo rejected; fi
  jq -c . "$STATE_DIR/510008.json"
' _ "$SCRIPT_DIR")"
assert_eq 'feature-branch merge leaves ticket state untouched' \
  $'rejected\n{"state":"implement","attempts":1}' "$MERGED_PR_GUARD_OUT"
rm -rf "$MERGED_PR_GUARD_HOME"

# --- path_in_expected_packages: the 2026-09-12 jq-shadowing regression -----
EXPECTED='["packages/example-gateway"]'

assert_true "a file under a declared package passes" \
  path_in_expected_packages "$EXPECTED" "packages/example-gateway/src/webhook.ts"

assert_true "the declared package path itself (exact match) passes" \
  path_in_expected_packages "$EXPECTED" "packages/example-gateway"

assert_false "a file outside the declared package fails" \
  path_in_expected_packages "$EXPECTED" "packages/other-package/src/x.ts"

assert_false "a sibling path that merely shares a prefix (no '/') fails" \
  path_in_expected_packages "$EXPECTED" "packages/example-gateway-extra/x.ts"

assert_false "an empty expected_packages array fails closed" \
  path_in_expected_packages "[]" "packages/anything/x.ts"

EXPECTED_EXACT_FILE='["packages/foo/exact-file.ts"]'
assert_true "an exact-file expected_packages entry matches itself" \
  path_in_expected_packages "$EXPECTED_EXACT_FILE" "packages/foo/exact-file.ts"

# --- normalize_expected_packages / path_in_expected_packages: #1178/PR #1186
# Triage pinned expected_packages to two sub-package paths inside
# example-pack; the implementer's on-scope fix legitimately also
# touched a third path in the SAME package, and this gate correctly
# rejected it as "outside expected_packages", parking a green PR on a human.
assert_eq "sub-package paths in the same package widen to one package-level entry" \
  '["packages/example-pack"]' \
  "$(normalize_expected_packages '["packages/example-pack/src","packages/example-pack/tests"]')"

assert_eq "an already package-level entry passes through unchanged" \
  '["packages/example-gateway"]' \
  "$(normalize_expected_packages '["packages/example-gateway"]')"

assert_eq "a path outside packages/ passes through unchanged (not this repo's package boundary)" \
  '["docs/agents"]' \
  "$(normalize_expected_packages '["docs/agents"]')"

# path_in_expected_packages() normalizes internally now, so this reproduces
# #1178 exactly: the RAW, un-normalized, already-persisted state-file value
# (no normalize_expected_packages call in this test) against the real third
# path PR #1186 touched -- this is what a resumed run-implement.sh sees
# today for a ticket triaged before this fix shipped, with no re-triage.
assert_true "gate 4's exact #1178/#1186 failure now passes against the raw, un-normalized state-file value" \
  path_in_expected_packages \
  '["packages/example-pack/src","packages/example-pack/tests"]' \
  "packages/example-pack/runtime/hooks/__init__.py"

assert_false "a path outside every declared package still fails -- the gate still fails closed" \
  path_in_expected_packages '["packages/example-pack/src"]' "packages/some-other-package/x.ts"

# The fix is retroactive by construction: it lives inside the shared
# predicate every consumer calls, not at the one site that writes
# expected_packages -- confirm no separate normalize call was (re-)added at
# the write site, since that would be a second, redundant source of truth
# for the same decision (see lib.sh's comment on path_in_expected_packages
# for why the single seam was chosen over that).

# --- normalize_expected_packages: #1215's trailing-slash regression --------
# An entry written as "templates/levels/" made the startswith($item + "/")
# check in path_in_expected_packages require "templates/levels//", which
# can never match -- a real, on-scope diff read as outside its own declared
# scope. The gate's own rejection comment on #1215 printed the exact entry
# that should have matched and nobody read it for hours; that PR (#1240)
# then stranded open and, via open_pr_file_collision()'s package-granularity
# comparison, blocked unrelated tickets #1144 and #1177 for hours more.
assert_eq "a trailing slash on a non-packages/ entry is stripped" \
  '["templates/levels"]' \
  "$(normalize_expected_packages '["templates/levels/"]')"

assert_true "#1215's exact reproduction: templates/levels/ now matches its own subpath" \
  path_in_expected_packages '["packages/example-service","templates/levels/"]' \
  "templates/levels/l1/TOOLS.md"

assert_eq "a trailing slash on a packages/... entry is stripped too" \
  '["packages/example-service"]' \
  "$(normalize_expected_packages '["packages/example-service/"]')"

assert_false "prefix safety holds after the slash-strip: example-service does not match example-service-extra" \
  path_in_expected_packages '["packages/example-service"]' \
  "packages/example-service-extra/foo.ts"

assert_true "exact-path equality still works after the slash-strip change" \
  path_in_expected_packages '["packages/foo/exact-file.ts"]' \
  "packages/foo/exact-file.ts"

assert_eq "an entry that is only slashes is dropped, not kept as an inert empty string" \
  '[]' \
  "$(normalize_expected_packages '["/"]')"

assert_eq "stripping can create a duplicate; the existing unique still collapses it" \
  '["templates/levels"]' \
  "$(normalize_expected_packages '["templates/levels","templates/levels/"]')"

# --- implement selection scope / decision ledger: pipeline self-heal -------
# `expected_packages` stays the merge boundary. A triage result may opt into
# a narrower `expected_paths` set only for dispatch collision scheduling;
# absent/empty paths must keep the legacy package-wide exclusion.
assert_eq "selection scope uses exact expected_paths when triage supplied them" \
  '["packages/example/src/one.ts"]' \
  "$(printf '%s\n' '{"expected_packages":["packages/example"],"expected_paths":["packages/example/src/one.ts"]}' | selection_scope_json 2>/dev/null || true)"

assert_eq "selection scope falls back to expected_packages when exact paths are absent" \
  '["packages/example"]' \
  "$(printf '%s\n' '{"expected_packages":["packages/example"]}' | selection_scope_json 2>/dev/null || true)"

assert_eq "selection scope keeps the package fallback when exact paths are empty" \
  '["packages/example"]' \
  "$(printf '%s\n' '{"expected_packages":["packages/example"],"expected_paths":[]}' | selection_scope_json 2>/dev/null || true)"

assert_eq "issue body paths provide an exact candidate scope" \
  '[".github/workflows/ci.yml","docs/agents/issue-pipeline.md","engine/lib.sh","packages/example/src/one.ts"]' \
  "$(issue_body_file_paths_json $'Fix paths:\n- .github/workflows/ci.yml\n- docs/agents/issue-pipeline.md\n- packages/example/src/one.ts\n- engine/lib.sh')"
assert_eq 'unlabelled historical file mentions are not factory-path evidence' '[]' \
  "$(issue_body_file_paths_json 'Prototype reference: docs/research/2026-10-08-pipeline.md')"
assert_false 'plan and ADR citations alone are not change-scope evidence' \
  issue_body_is_direct_main_lane $'Plan: docs/plans/roadmap.md\nDecision: docs/adr/065.md'
assert_false 'bare source filenames cannot establish non-product scope' \
  issue_body_is_direct_main_lane $'Update query-runtime.ts and source-adapter.ts'
assert_false 'product path mentions anywhere in body or comments veto fastlane scope' \
  issue_body_is_direct_main_lane $'Fix paths:\n- engine/lib.sh\n\nRelated code: packages/example-pack/src/query-runtime.ts'
assert_eq 'explicit path section can include blank lines and nested path roots' \
  '["Dockerfile","engine/lib.sh"]' \
  "$(issue_body_file_paths_json $'Fix paths:\n\n- engine/lib.sh\n- Dockerfile\n\nAcceptance criteria:\n- docs/agents/ignored.md')"
assert_false 'factory path plus Dockerfile evidence stays in product lane' \
  issue_body_is_direct_main_lane $'Fix paths:\n- engine/lib.sh\n- Dockerfile'
assert_true 'open blocked child marks ticket as parent tracker' \
  issue_is_parent_tracker '{"blockedBy":{"nodes":[{"number":2911,"state":"OPEN"}]}}'
assert_true 'sub-issue count marks ticket as parent tracker' \
  issue_is_parent_tracker '{"subIssuesSummary":{"total":2}}'
assert_false 'completed-only sub-issues do not mark a ticket as parent tracker' \
  issue_is_parent_tracker '{"subIssuesSummary":{"total":1,"completed":1}}'
assert_false 'ordinary issue without children is not a parent tracker' \
  issue_is_parent_tracker '{"number":2911,"blockedBy":{"nodes":[]},"subIssuesSummary":{"total":0}}'
assert_false "mixed product and infrastructure paths stay in product lane" \
  issue_body_is_direct_main_lane $'Fix paths:\n- engine/lib.sh\n- packages/example-admin/src/context/AuthContext.tsx'
assert_eq "file scopes collapse to package roots for fallback concurrency" \
  '["engine/lib.sh","packages/example"]' \
  "$(selection_scope_roots_json '["packages/example/src/one.ts","engine/lib.sh"]')"
declare -A PACKAGE_SCOPE_COUNT=()
declare -A PACKAGE_SCOPE_ISSUES=()
package_scope_add_issue 900001 '["packages/example/src/one.ts"]'
package_scope_add_issue 900002 '["packages/example/src/two.ts"]'
assert_true "unknown package scope admits no third concurrent issue" \
  package_scope_is_full 900003 '["packages/example"]' 2
assert_false "package cap excludes the candidate's own open PR from occupancy" \
  package_scope_is_full 900001 '["packages/example"]' 2
unset PACKAGE_SCOPE_COUNT PACKAGE_SCOPE_ISSUES

assert_false "two distinct exact expected_paths in one package do not collide" \
  expected_packages_collide \
  '["packages/example/src/one.ts"]' \
  '["packages/example/src/two.ts"]'

COLLISION_SNAPSHOT_HOME="$(mktemp -d)"
COLLISION_SNAPSHOT_RESULT="$(AGENT_HOME="$COLLISION_SNAPSHOT_HOME" REPO="test/repo" bash -c '
  source "$1/lib.sh"
  gh() { echo "unexpected GitHub lookup" >&2; return 99; }
  pr="{\"number\":1406,\"headRefName\":\"agent/issue-1406\",\"updatedAt\":\"2026-09-20T00:00:00Z\",\"files\":[{\"path\":\"packages/example/src/one.ts\"}]}"
  if open_pr_file_collision "[\"packages/example/src/one.ts\"]" "$pr"; then
    printf "overlap=%s\n" "$OPEN_PR_FILE_COLLISION_PATH"
  else
    printf "overlap=free\n"
  fi
  if open_pr_file_collision "[\"packages/example/src/two.ts\"]" "$pr"; then
    printf "disjoint=blocked\n"
  else
    printf "disjoint=free\n"
  fi
  manifest="{\"number\":1407,\"headRefName\":\"agent/issue-1407\",\"files\":[{\"path\":\"packages/example/package.json\"}]}"
  if open_pr_file_collision "[\"packages/example\"]" "$manifest"; then
    printf "manifest-package=blocked\n"
  else
    printf "manifest-package=free\n"
  fi
  if open_pr_file_collision "[\"packages/example/package.json\"]" "$manifest"; then
    printf "manifest-exact=blocked\n"
  else
    printf "manifest-exact=free\n"
  fi
  if open_pr_file_collision "[\"packages/example/src/one.ts\"]" "$pr" "agent/issue-1406"; then
    printf "own-pr=blocked\n"
  else
    printf "own-pr=free\n"
  fi
' _ "$SCRIPT_DIR")"
assert_eq "PR file snapshot blocks only its matching candidate path without per-candidate GitHub reads" \
  $'overlap=packages/example/src/one.ts\ndisjoint=free\nmanifest-package=free\nmanifest-exact=blocked\nown-pr=free' \
  "$COLLISION_SNAPSHOT_RESULT"
rm -rf "$COLLISION_SNAPSHOT_HOME"

assert_true "a legacy package declaration still collides with an exact path inside it" \
  expected_packages_collide \
  '["packages/example"]' \
  '["packages/example/src/two.ts"]'

COLLISION_TEST_HOME="$(mktemp -d)"
COLLISION_METADATA="$(AGENT_HOME="$COLLISION_TEST_HOME" REPO="test/repo" bash -c '
  source "$1/lib.sh"
  gh() {
    [ "$1 $2" = "pr view" ] || return 1
    printf "%s\\n" "packages/example/src/one.ts"
  }
  if open_pr_file_collision \
    "[\"packages/example/src/one.ts\"]" \
    "{\"number\":1406,\"headRefName\":\"agent/issue-1406\",\"updatedAt\":\"2026-09-20T00:00:00Z\"}"; then
    printf "pr=%s path=%s owner=%s updated=%s\\n" \
      "${OPEN_PR_FILE_COLLISION_PR:-}" \
      "${OPEN_PR_FILE_COLLISION_PATH:-}" \
      "${OPEN_PR_FILE_COLLISION_OWNER:-}" \
      "${OPEN_PR_FILE_COLLISION_UPDATED_AT:-}"
  fi
' _ "$SCRIPT_DIR" 2>&1 || true)"
assert_eq "open-PR collision records the blocking PR, changed path, owner, and freshness time" \
  "pr=1406 path=packages/example/src/one.ts owner=1406 updated=2026-09-20T00:00:00Z" \
  "$(grep '^pr=' <<< "$COLLISION_METADATA" || true)"
rm -rf "$COLLISION_TEST_HOME"

LEDGER_TEST_HOME="$(mktemp -d)"
LEDGER_OUTPUT="$(AGENT_HOME="$LEDGER_TEST_HOME" REPO="test/repo" DRY_RUN=0 bash -c '
  source "$1/lib.sh"
  record_implement_tick_decision 740010 20260921T000000Z skipped open-pr-file-collision \
    "打开的 PR 已改候选范围内文件" "PR #1406；packages/example/src/one.ts"
  jq -c .implement_tick_decision "$AGENT_HOME/state/740010.json"
' _ "$SCRIPT_DIR" 2>&1 || true)"
assert_contains "each skipped implement candidate persists its gate and concrete object" \
  "$LEDGER_OUTPUT" '"gate":"open-pr-file-collision"'
assert_contains "each skipped implement candidate leaves a journal decision line" \
  "$LEDGER_OUTPUT" "implement-decision tick=20260921T000000Z issue=#740010"
rm -rf "$LEDGER_TEST_HOME"

# --- state_merge: 2026-09-15 fix, #1204/#1206 live E2BIG --------------------
# jq's own argv used to carry $filter directly (`jq "$filter"`). A filter
# built by splicing a large JSON blob into it -- exactly what run-advisor.sh's
# `". + $PATCH"` call sites do with an advisor ruling's reasoning_md/
# decision_md -- could exceed Linux's MAX_ARG_STRLEN (128KiB per single argv
# element, independent of the much larger ARG_MAX rlimit); execve then
# refuses to even start jq (exit 126, "Argument list too long"), killing the
# caller outright under its own `set -e` before it ever reached its OWN
# state write. #1204's stored ruling alone reached 127.7K live. state_merge
# now writes $filter to a temp file and runs `jq -f` -- the filter's size no
# longer touches argv at all, regardless of caller.
#
# The 200000-byte payload below is comfortably past the 128KiB single-arg
# limit that actually killed #1204/#1206 (not just past the live incident's
# own 65-127K) -- and is threaded through as a FILE the whole way (never a
# bash -c argv element, never a function each other's argv), the same
# discipline the fix itself uses, so the test rig cannot reproduce the exact
# bug it's proving fixed.
SM_HOME="$(mktemp -d)"
mkdir -p "$SM_HOME/state"
echo '{"attempts":0}' > "$SM_HOME/state/600001.json"
SM_RAW_FILE="$(mktemp)"
{ printf 'SM_BIG_PAYLOAD_MARKER-'; head -c 200000 /dev/zero | tr '\0' 'x'; } > "$SM_RAW_FILE"
SM_FILTER_FILE="$(mktemp)"
jq -Rsr '". + " + ({brief_md: .} | tojson)' "$SM_RAW_FILE" > "$SM_FILTER_FILE"
SM_BIG_OUT="$(
  AGENT_HOME="$SM_HOME" REPO="test/repo" bash -c '
    source "$0/lib.sh"
    filter="$(cat "$1")"
    state_merge 600001 "$filter"
    echo "exit=$?"
  ' "$SCRIPT_DIR" "$SM_FILTER_FILE" 2>&1
)"
assert_contains "state_merge: a filter carrying a 200KB payload (past MAX_ARG_STRLEN) succeeds now" \
  "$SM_BIG_OUT" "exit=0"
SM_WRITTEN="$(cat "$SM_HOME/state/600001.json")"
assert_contains "...and the payload actually landed in the state file" \
  "$SM_WRITTEN" "SM_BIG_PAYLOAD_MARKER"
rm -f "$SM_RAW_FILE" "$SM_FILTER_FILE"

# A failed merge must be loud (a diagnostic naming the issue, not a bare
# exec error) and must never leave the state file half-written.
SM_HOME2="$(mktemp -d)"
mkdir -p "$SM_HOME2/state"
echo '{"attempts":0,"marker":"untouched"}' > "$SM_HOME2/state/600002.json"
SM_BAD_OUT="$(
  AGENT_HOME="$SM_HOME2" REPO="test/repo" bash -c '
    source "$0/lib.sh"
    state_merge 600002 ".this is not ((( valid jq"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "state_merge: an invalid jq filter fails loudly, naming the issue" \
  "$SM_BAD_OUT" "state_merge: jq failed for issue #600002"
assert_contains "...and returns non-zero, so the caller's own set -e still stops the run" \
  "$SM_BAD_OUT" "exit=1"
SM_UNCHANGED="$(cat "$SM_HOME2/state/600002.json")"
assert_contains "...and the state file is left exactly as it was -- no half-written file" \
  "$SM_UNCHANGED" "untouched"

# --- give_up_on_issue's label vocabulary stays in one place -----------------
# (bash arrays can't cross a subshell/exec boundary, so this checks the
# array directly rather than via assert_true's "$@" indirection.)
state_labels_complete() {
  local joined=" ${ALL_STATE_LABELS[*]} "
  [[ "$joined" == *" needs-triage "* ]] \
    && [[ "$joined" == *" ready-for-agent "* ]] \
    && [[ "$joined" == *" awaiting-release "* ]] \
    && [[ "$joined" == *" released "* ]] \
    && [[ "$joined" == *" checks-blocked "* ]] \
    && [[ "$joined" == *" duplicate "* ]] \
    && [[ "$joined" == *" finish-first "* ]]
}
assert_true "ALL_STATE_LABELS still contains every state give_up_on_issue must clear" \
  state_labels_complete

# --- cap_slots_remaining: the scheduler's cap arithmetic --------------------
assert_eq "an empty stage has its full cap free" "2" "$(cap_slots_remaining 2 0)"
assert_eq "a partially-occupied stage has the remainder free" "1" "$(cap_slots_remaining 2 1)"
assert_eq "a fully-occupied stage has nothing free" "0" "$(cap_slots_remaining 2 2)"
assert_eq "occupancy racing ahead of a stale cap read clamps at 0, not negative" \
  "0" "$(cap_slots_remaining 1 3)"
assert_eq "cap 1 (the intended first live configuration) behaves like today's serial poller" \
  "1" "$(cap_slots_remaining 1 0)"

# --- state_changed_at / lifecycle progress: issue #1480 --------------------
# A bookkeeping write (attempts, merge-sweep streak, etc.) must not make an
# unchanged lifecycle state look fresh.
STATE_TIME_HOME="$(mktemp -d)"
mkdir -p "$STATE_TIME_HOME/state"
printf '%s\n' '{"attempts":0,"state":"needs-triage"}' > "$STATE_TIME_HOME/state/740001.json"
STATE_TIME_OUTPUT="$(AGENT_HOME="$STATE_TIME_HOME" REPO="test/repo" bash -c '
  source "$1/lib.sh"
  state_merge 740001 '\'' .state = "ready-for-agent" '\''
  first="$(jq -r .state_changed_at "$AGENT_HOME/state/740001.json")"
  state_merge 740001 '\'' .attempts = 1 '\''
  second="$(jq -r .state_changed_at "$AGENT_HOME/state/740001.json")"
  printf "first=%s\\nsecond=%s\\n" "$first" "$second"
' _ "$SCRIPT_DIR" 2>&1)"
STATE_TIME_FIRST="$(grep '^first=' <<< "$STATE_TIME_OUTPUT" | cut -d= -f2-)"
STATE_TIME_SECOND="$(grep '^second=' <<< "$STATE_TIME_OUTPUT" | cut -d= -f2-)"
assert_true "state_merge records state_changed_at when .state changes" \
  test -n "$STATE_TIME_FIRST" -a "$STATE_TIME_FIRST" != "null"
assert_eq "a non-state bookkeeping write does not refresh state_changed_at" \
  "$STATE_TIME_FIRST" "$STATE_TIME_SECOND"
rm -rf "$STATE_TIME_HOME"

# --- single-writer issue state transitions ---------------------------------
ISSUE_TRANSITION_HOME="$(mktemp -d)"
mkdir -p "$ISSUE_TRANSITION_HOME/bin" "$ISSUE_TRANSITION_HOME/state"
cat > "$ISSUE_TRANSITION_HOME/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  issue:view) cat "$ISSUE_TRANSITION_ISSUE" ;;
  issue:edit)
    shift 3
    while (($#)); do
      case "$1" in
        --repo) shift 2 ;;
        --add-label)
          jq --arg name "$2" 'if any(.labels[]?; .name == $name) then . else .labels += [{name:$name}] end' \
            "$ISSUE_TRANSITION_ISSUE" > "$ISSUE_TRANSITION_ISSUE.tmp"
          mv "$ISSUE_TRANSITION_ISSUE.tmp" "$ISSUE_TRANSITION_ISSUE"
          shift 2
          ;;
        --remove-label)
          jq --arg name "$2" '.labels = [.labels[]? | select(.name != $name)]' \
            "$ISSUE_TRANSITION_ISSUE" > "$ISSUE_TRANSITION_ISSUE.tmp"
          mv "$ISSUE_TRANSITION_ISSUE.tmp" "$ISSUE_TRANSITION_ISSUE"
          shift 2
          ;;
        *) echo "unexpected fake gh args: $*" >&2; exit 2 ;;
      esac
    done
    ;;
  *) echo "unexpected fake gh call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$ISSUE_TRANSITION_HOME/bin/gh"
ISSUE_TRANSITION_OUTPUT="$(AGENT_HOME="$ISSUE_TRANSITION_HOME" REPO=test/repo \
  ISSUE_TRANSITION_ISSUE="$ISSUE_TRANSITION_HOME/issue.json" \
  PATH="$ISSUE_TRANSITION_HOME/bin:$PATH" bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    ensure_state_labels() { :; }
    recut_parent_has_open_child() { return 1; }
    roadmap_ensure_issue_parent() { :; }
    for retirement_state in untracked needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded on-hold tracker; do
      issue_transition_allowed "$retirement_state" tracker recut-parent-retired || exit 23
      if issue_transition_allowed "$retirement_state" tracker unrelated; then exit 24; fi
    done
    issue_transition_allowed finish-first needs-triage blocking-pr-cleared || exit 21
    if issue_transition_allowed finish-first needs-triage reopened-by-human; then exit 22; fi
    issue_transition_allowed finish-first awaiting-release merged-pr || exit 27
    if issue_transition_allowed finish-first awaiting-release pipeline-requeue; then exit 28; fi
    issue_transition_allowed needs-advisor released all-children-released || exit 25
    if issue_transition_allowed needs-advisor released unrelated; then exit 26; fi
    issue_transition_allowed needs-advisor awaiting-release merged-pr || exit 29
    if issue_transition_allowed needs-advisor awaiting-release unrelated; then exit 30; fi
    printf "all-state-tracker=allowed unrelated-reason=refused\n"
    printf "%s\n" '\''{"state":"ready-for-agent","labels":[{"name":"ready-for-agent"},{"name":"priority:top"}]}'\'' > "$ISSUE_TRANSITION_ISSUE"
    printf "%s\n" '\''{"state":"ready-for-agent","run":{"implement_started_at":"2026-10-07T08:00:00Z"}}'\'' > "$AGENT_HOME/state/740030.json"
    issue_transition 740030 needs-advisor advisor-route
    test "$(jq -r .state "$AGENT_HOME/state/740030.json")" = needs-advisor
    test "$(jq -r '\''[.labels[].name] | sort | join(",")'\'' "$ISSUE_TRANSITION_ISSUE")" = needs-advisor,priority:top

    printf "%s\n" '\''{"state":"awaiting-release","labels":[{"name":"awaiting-release"}]}'\'' > "$ISSUE_TRANSITION_ISSUE"
    printf "%s\n" '\''{"state":"awaiting-release","attempts":3,"deploy_state":"pending","run":{"outcome":"merged","evidence":{"pr_number":"2745"}}}'\'' > "$AGENT_HOME/state/740030.json"
    if issue_transition 740030 ready-for-agent pipeline-requeue; then exit 11; fi
    test "$(jq -r .state "$AGENT_HOME/state/740030.json")" = awaiting-release
    test "$(jq -r '\''[.labels[].name] | join(",")'\'' "$ISSUE_TRANSITION_ISSUE")" = awaiting-release
    state_requeue 740030 "" revert
    test "$(jq -r .state "$AGENT_HOME/state/740030.json")" = ready-for-agent
    test "$(jq -r .attempts "$AGENT_HOME/state/740030.json")" = 0

    printf "%s\n" '\''{"state":"concluded","labels":[{"name":"concluded"}]}'\'' > "$ISSUE_TRANSITION_ISSUE"
    printf "%s\n" '\''{"state":"concluded","deploy_state":"pending","run":{"outcome":"merged","evidence":{"pr_number":"2745"}}}'\'' > "$AGENT_HOME/state/740030.json"
    issue_transition 740030 awaiting-release merged-pr
    test "$(jq -r .state "$AGENT_HOME/state/740030.json")" = awaiting-release
    test "$(jq -r '\''[.labels[].name] | join(",")'\'' "$ISSUE_TRANSITION_ISSUE")" = awaiting-release

    printf "%s\n" '\''{"state":"ready-for-agent","labels":[{"name":"ready-for-agent"},{"name":"in-progress"},{"name":"released"},{"name":"priority:top"}]}'\'' > "$ISSUE_TRANSITION_ISSUE"
    printf "%s\n" '\''{"state":"ready-for-agent","requeued_at":"2026-10-07T09:00:00Z","run":{"implement_started_at":"2026-10-07T08:00:00Z"}}'\'' > "$AGENT_HOME/state/740030.json"
    if issue_transition 740030 concluded conclude:failed; then exit 12; fi
    test "$(jq -r .state "$AGENT_HOME/state/740030.json")" = ready-for-agent

    printf "%s\n" '\''{"state":"ready-for-agent","labels":[{"name":"ready-for-agent"},{"name":"in-progress"},{"name":"released"},{"name":"needs-info"},{"name":"priority:top"}]}'\'' > "$ISSUE_TRANSITION_ISSUE"
    printf "%s\n" '\''{"state":"ready-for-agent","run":{"implement_started_at":"2026-10-07T10:00:00Z"}}'\'' > "$AGENT_HOME/state/740030.json"
    issue_transition 740030 concluded conclude:deployed
    test "$(jq -r .state "$AGENT_HOME/state/740030.json")" = concluded
    test "$(jq -r '\''[.labels[].name] | sort | join(",")'\'' "$ISSUE_TRANSITION_ISSUE")" = concluded,priority:top,released
    for retirement_state in finish-first needs-info awaiting-release; do
      jq -cn --arg state "$retirement_state" "{state:\$state,labels:[{name:\$state},{name:\"needs-info\"},{name:\"awaiting-release\"},{name:\"in-progress\"},{name:\"priority:top\"}]}" > "$ISSUE_TRANSITION_ISSUE"
      jq -cn --arg state "$retirement_state" "{state:\$state,hold:{holder:\"supervisor\"},advisor_ruled_at:\"stale\"}" > "$AGENT_HOME/state/740030.json"
      retire_tracker_parent 740030
      test "$(jq -r .state "$AGENT_HOME/state/740030.json")" = tracker
      test "$(jq -r .tracker_parent "$AGENT_HOME/state/740030.json")" = true
      test "$(jq -r .hold "$AGENT_HOME/state/740030.json")" = null
      test "$(jq -r .advisor_ruled_at "$AGENT_HOME/state/740030.json")" = null
      test "$(jq -r .labels[].name "$ISSUE_TRANSITION_ISSUE" | sort | paste -sd, -)" = priority:top,tracker
    done
    printf "%s\n" '\''{"state":"tracker","labels":[{"name":"priority:top"}]}'\'' > "$ISSUE_TRANSITION_ISSUE"
    printf "%s\n" '\''{"state":"tracker"}'\'' > "$AGENT_HOME/state/740030.json"
    issue_transition 740030 tracker recut-parent-retired
    test "$(jq -r .labels[].name "$ISSUE_TRANSITION_ISSUE" | sort | paste -sd, -)" = priority:top,tracker
    printf "retired-finish-first-needs-info-awaiting-release=local-and-github\\n"
  ' _ "$SCRIPT_DIR" 2>&1)"
assert_not_contains "state transitions reject illegal merged requeue" "$ISSUE_TRANSITION_OUTPUT" "unexpected fake gh args"
assert_contains "state transitions log illegal merged requeue" "$ISSUE_TRANSITION_OUTPUT" \
  "issue_transition: refused #740030 awaiting-release -> ready-for-agent"
assert_contains "state transitions reject stale conclusion after requeue" "$ISSUE_TRANSITION_OUTPUT" \
  "issue_transition: refused stale conclusion for #740030"
assert_contains "tracker retirement needs its reason and cannot bypass merged release" \
  "$ISSUE_TRANSITION_OUTPUT" "all-state-tracker=allowed unrelated-reason=refused"
assert_contains "tracker retirement updates local state and GitHub labels from terminal and in-flight states" \
  "$ISSUE_TRANSITION_OUTPUT" "retired-finish-first-needs-info-awaiting-release=local-and-github"
rm -rf "$ISSUE_TRANSITION_HOME"

# State and state-label mutations in lib.sh must stay behind issue_transition.
LIB_STATE_WRITE_AUDIT="$(awk '
  /^issue_transition\(\) \($/ { inside_transition=1 }
  /^\)$/ && inside_transition { inside_transition=0; next }
  /\.state[[:space:]]*=[[:space:]]*[^=]/ && !inside_transition && $0 !~ /^[[:space:]]*#/ { print FNR ":" $0 }
  /--(add|remove)-label[[:space:]]+(needs-triage|needs-info|ready-for-agent|ready-for-human|needs-owner|checks-blocked|duplicate|finish-first|wontfix|needs-advisor|needs-recut|awaiting-release|awaiting-pipeline-sync|awaiting-pipeline-health|released|concluded|on-hold)/ && !inside_transition && $0 !~ /^[[:space:]]*#/ { print FNR ":" $0 }
' "$SCRIPT_DIR/lib.sh")"
assert_eq "lib.sh has no state writes outside issue_transition" "" "$LIB_STATE_WRITE_AUDIT"

# --- durable per-ticket stage transitions ----------------------------------
STAGE_EVENT_HOME="$(mktemp -d)"
STAGE_EVENT_OUTPUT="$(AGENT_HOME="$STAGE_EVENT_HOME" REPO="test/repo" bash -c '
  set -euo pipefail
  mkdir -p "$AGENT_HOME/bin"
  printf "%s\n" "#!/usr/bin/env bash" \
    "if [ \"\${1:-}\" = api ]; then echo \"[]\"; exit 0; fi" \
    "[ \"\${FAIL_WRITE:-0}\" != 1 ]" > "$AGENT_HOME/bin/gh"
  chmod +x "$AGENT_HOME/bin/gh"
  PATH="$AGENT_HOME/bin:$PATH"
  export PATH
  source "$1/lib.sh"
  printf "%s\n" '\''{"attempts":0,"state":"needs-triage"}'\'' > "$AGENT_HOME/state/740021.json"
  state_merge 740021 '\''.state = "ready-for-agent"'\''
  guarded_write gh issue edit 740021 --repo "$REPO" --remove-label needs-triage --add-label ready-for-agent
  state_merge 740021 '\''.state = "needs-advisor"'\''
  guarded_write gh issue edit 740021 --repo "$REPO" --remove-label ready-for-agent --add-label needs-advisor
  state_merge 740021 '\''.state = "ready-for-agent"'\''
  TICKET_STAGE_WRITE_KIND=requeue guarded_write gh issue edit 740021 --repo "$REPO" --remove-label needs-advisor --add-label ready-for-agent
  state_merge 740021 '\''.state = "needs-advisor"'\''
  if FAIL_WRITE=1 guarded_write gh issue edit 740021 --repo "$REPO" --remove-label ready-for-agent --add-label needs-advisor; then
    echo unexpected-success
    exit 1
  else
    echo failed-write-rejected
  fi
' _ "$SCRIPT_DIR" 2>&1)"
STAGE_EVENT_FILE="$STAGE_EVENT_HOME/state/ticket-transitions.jsonl"
assert_stage_record_shape() {
  jq -se 'length == 3 and .[0].from_stage == "needs-triage" and .[0].to_stage == "ready-for-agent" and .[0].kind == "advance" and .[0].progress == true and .[1].from_stage == "ready-for-agent" and .[1].to_stage == "needs-advisor" and .[1].kind == "flip" and .[1].progress == false and .[2].from_stage == "needs-advisor" and .[2].to_stage == "ready-for-agent" and .[2].kind == "requeue" and .[2].progress == false' "$STAGE_EVENT_FILE" >/dev/null
}
assert_eq "successful pipeline label writes append one transition each" 3 "$(wc -l < "$STAGE_EVENT_FILE" | tr -d '[:space:]')"
assert_true "stage record distinguishes advance, flip, and requeue" \
  assert_stage_record_shape
assert_contains "failed label write is rejected" "$STAGE_EVENT_OUTPUT" "failed-write-rejected"
assert_not_contains "failed label writes append no transition" "$STAGE_EVENT_OUTPUT" "unexpected-success"
rm -rf "$STAGE_EVENT_HOME"

IMPLEMENT_PROGRESS_HOME="$(mktemp -d)"
mkdir -p "$IMPLEMENT_PROGRESS_HOME/state"
printf '%s\n' '{"attempts":0,"state":"ready-for-agent"}' \
  > "$IMPLEMENT_PROGRESS_HOME/state/740022.json"
AGENT_HOME="$IMPLEMENT_PROGRESS_HOME" bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  state_merge 740022 '\''.run.evidence.pr_number = "913"'\''
  state_merge 740022 '\''.attempts = 1'\''
' _ "$SCRIPT_DIR"
assert_true "a produced PR records implementation progress once" \
  jq -se 'length == 1 and .[0].kind == "implement" and .[0].from_stage == "ready-for-agent" and .[0].to_stage == "ready-for-agent" and .[0].progress == true' \
  "$IMPLEMENT_PROGRESS_HOME/state/ticket-transitions.jsonl"
rm -rf "$IMPLEMENT_PROGRESS_HOME"

ON_HOLD_STAGE_HOME="$(mktemp -d)"
mkdir -p "$ON_HOLD_STAGE_HOME/bin" "$ON_HOLD_STAGE_HOME/state"
cat > "$ON_HOLD_STAGE_HOME/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ON_HOLD_STAGE_HOME/bin/gh"
printf '%s\n' '{"attempts":0,"state":"needs-advisor"}' \
  > "$ON_HOLD_STAGE_HOME/state/740023.json"
AGENT_HOME="$ON_HOLD_STAGE_HOME" PATH="$ON_HOLD_STAGE_HOME/bin:$PATH" bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  guarded_write gh issue edit 740023 --repo test/repo --remove-label needs-advisor --add-label on-hold
' _ "$SCRIPT_DIR"
assert_true "on-hold writes a parked stage transition without claiming progress" \
  jq -se 'length == 1 and .[0].from_stage == "needs-advisor" and .[0].to_stage == "on-hold" and .[0].kind == "park" and .[0].progress == false' \
  "$ON_HOLD_STAGE_HOME/state/ticket-transitions.jsonl"
rm -rf "$ON_HOLD_STAGE_HOME"

HELD_LANE_HOME="$(mktemp -d)"
mkdir -p "$HELD_LANE_HOME/bin"
# The shipped policy disables the advisor role; this fixture routes tickets to it.
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$HELD_LANE_HOME/model-policy.json"
cat > "$HELD_LANE_HOME/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  echo '[]'
  exit 0
fi
# The live label read that confirms a snapshot hold (#352) must see the same hold.
if [ "${1:-} ${2:-}" = "issue view" ] && [ "${HOLD_MODE:-}" = held ]; then
  echo on-hold
  exit 0
fi
printf '%s\n' "$*" >> "$HELD_LANE_COMMAND_LOG"
EOF
chmod +x "$HELD_LANE_HOME/bin/gh"
HELD_LANE_OUTPUT="$(AGENT_HOME="$HELD_LANE_HOME" SCRIPT_DIR="$SCRIPT_DIR" REPO=test/repo AGENT_DRY_RUN=0 \
  HELD_LANE_COMMAND_LOG="$HELD_LANE_HOME/commands.log" \
  HELD_LANE_SUPPRESSION_LOG="$HELD_LANE_HOME/suppressions.log" \
  PATH="$HELD_LANE_HOME/bin:$PATH" bash -c '
    set -euo pipefail
    source "$SCRIPT_DIR/lib.sh"
    REPO=test/repo
    DRY_RUN=0
    is_on_hold() { [ "${HOLD_MODE:-unheld}" = held ]; }
    roadmap_ensure_issue_parent() { :; }
    issue_label_cache_invalidate() { :; }
    ensure_state_labels() { :; }
    issue_verdict_snapshot_guard() { return 0; }
    pipeline_system_route_status() { return 1; }
    advisor_retry_admission() { return 0; }
    loop_break_check() { LOOP_BREAK_ESCALATED=0; }

    state_merge 740024 '\''{"attempts":1,"state":"concluded","model_policy":{"unit":"implement","step":"conclude"}}'\''
    HOLD_MODE=held state_requeue 740024 "" conclusion-requeue 2>>"$HELD_LANE_SUPPRESSION_LOG" || :
    state_merge 740025 '\''{"attempts":1,"state":"concluded","model_policy":{"unit":"implement","step":"conclude"}}'\''
    HOLD_MODE=unheld state_requeue 740025 "" conclusion-requeue 2>>"$HELD_LANE_SUPPRESSION_LOG"

    state_merge 740026 '\''{"attempts":0,"state":"needs-triage"}'\''
    HOLD_MODE=held route_to_advisor 740026 needs-triage 2>>"$HELD_LANE_SUPPRESSION_LOG" || :
    state_merge 740027 '\''{"attempts":0,"state":"needs-triage"}'\''
    HOLD_MODE=unheld route_to_advisor 740027 needs-triage 2>>"$HELD_LANE_SUPPRESSION_LOG"

    empty_lane_writer() {
      guarded_write gh issue edit 740028 --repo "$REPO" --add-label ready-for-agent
    }
    mixed_label_writer() {
      guarded_write gh issue edit 740029 --repo "$REPO" --remove-label needs-triage \
        --add-label ready-for-agent --add-label custom-lane --title "kept title"
    }
    HOLD_MODE=held empty_lane_writer 2>>"$HELD_LANE_SUPPRESSION_LOG"
    HOLD_MODE=held mixed_label_writer 2>>"$HELD_LANE_SUPPRESSION_LOG"
    HOLD_MODE=held guarded_write gh issue comment 740030 --repo "$REPO" --body "kept comment"
    state_merge 740033 '\''{"state":"awaiting-release","hold":{"holder":"test"},"deploy_state":"deployed","run":{"outcome":"merged","evidence":{"pr_number":740033,"merged_pr":{"number":740033,"merge_sha":"main-740033","merged_at":"2026-10-01T00:00:00Z"}}}}'\''
    HOLD_MODE=held issue_transition 740033 concluded conclude:deployed '\''.released = true'\''
    state_merge 740035 '\''{"state":"ready-for-agent","requeued_at":"2026-10-01T00:00:00Z","hold":{"holder":"hand-own-pr"}}'\''
    HOLD_MODE=held mark_awaiting_release 740035 977035
    state_merge 740034 '\''{"state":"awaiting-release","hold":{"holder":"test"},"deploy_state":"pending","run":{"outcome":"merged","evidence":{"pr_number":740034}}}'\''
    if HOLD_MODE=held issue_transition 740034 concluded operator-shortcut 2>>"$HELD_LANE_SUPPRESSION_LOG"; then
      echo unexpected-held-close
    else
      echo held-close-rejected
    fi
    # An unreadable hold fails closed in is_on_hold, but must not drop the lane write.
    is_on_hold() { ISSUE_LABEL_VIEW_STATE[$1]=failed; return 0; }
    guarded_write gh issue edit 740031 --repo "$REPO" --add-label awaiting-release 2>>"$HELD_LANE_SUPPRESSION_LOG"
    state_merge 740032 '\''{"state":"checks-blocked"}'\''
    issue_transition 740032 ready-for-agent pipeline-requeue 2>>"$HELD_LANE_SUPPRESSION_LOG"

    declare -gA ISSUE_LABEL_VIEW_STATE=()
    transient_hold_reads=0
    is_on_hold() {
      if [ "$1" = 740036 ]; then
        transient_hold_reads=$((transient_hold_reads + 1))
        if [ "$transient_hold_reads" = 1 ]; then
          ISSUE_LABEL_VIEW_STATE[$1]=failed
        else
          ISSUE_LABEL_VIEW_STATE[$1]=read
        fi
        return 0
      fi
      return 1
    }
    state_merge 740036 '\''{"state":"needs-advisor"}'\''
    if issue_transition 740036 ready-for-agent state-label-reconcile 2>>"$HELD_LANE_SUPPRESSION_LOG"; then
      echo unexpected-transient-held-transition
      exit 1
    fi
    jq -e '\''.state == "needs-advisor"'\'' "$STATE_DIR/740036.json" >/dev/null
    echo transient-held-transition-rolled-back
  ' 2>&1)"
HELD_LANE_COMMANDS="$(cat "$HELD_LANE_HOME/commands.log")"
HELD_LANE_SUPPRESSIONS="$(cat "$HELD_LANE_HOME/suppressions.log")"
HELD_REQUEUE_COMMAND="$(grep -F 'issue edit 740024 ' <<< "$HELD_LANE_COMMANDS" || true)"
assert_not_contains "held-lane fixture exercises guarded writes, not dry-run output" \
  "$HELD_LANE_OUTPUT" "[dry-run]"
assert_not_contains "held state_requeue drops ready-for-agent" \
  "$HELD_REQUEUE_COMMAND" "--add-label ready-for-agent"
assert_not_contains "held state_requeue leaves labels untouched" \
  "$HELD_LANE_COMMANDS" "issue edit 740024"
assert_eq "held state_requeue leaves local state untouched" concluded \
  "$(jq -r '.state' "$HELD_LANE_HOME/state/740024.json")"
HELD_UNHELD_REQUEUE_COMMAND="$(grep -F 'issue edit 740025 ' <<< "$HELD_LANE_COMMANDS")"
assert_contains "unheld state_requeue still adds ready-for-agent" \
  "$HELD_UNHELD_REQUEUE_COMMAND" "--add-label ready-for-agent"
HELD_ADVISOR_COMMAND="$(grep -F 'issue edit 740026 ' <<< "$HELD_LANE_COMMANDS")"
assert_contains "held route_to_advisor backfills the parked stage" \
  "$HELD_ADVISOR_COMMAND" "--add-label on-hold"
assert_not_contains "held route_to_advisor drops needs-advisor" \
  "$HELD_ADVISOR_COMMAND" "--add-label needs-advisor"
assert_eq "held route_to_advisor records on-hold locally" on-hold \
  "$(jq -r '.state' "$HELD_LANE_HOME/state/740026.json")"
HELD_UNHELD_ADVISOR_COMMAND="$(grep -F 'issue edit 740027 ' <<< "$HELD_LANE_COMMANDS")"
assert_contains "unheld route_to_advisor still adds needs-advisor" \
  "$HELD_UNHELD_ADVISOR_COMMAND" "--add-label needs-advisor"
assert_not_contains "held lane-only edit is skipped" \
  "$HELD_LANE_COMMANDS" "issue edit 740028"
assert_contains "held mixed edit drops only lane label and keeps other edits" \
  "$HELD_LANE_COMMANDS" "issue edit 740029 --repo test/repo --remove-label needs-triage --add-label custom-lane --title kept title"
assert_contains "held issue comments still pass through" \
  "$HELD_LANE_COMMANDS" "issue comment 740030 --repo test/repo --body kept comment"
HELD_PROVEN_CLOSE_COMMAND="$(grep -F 'issue edit 740033 ' <<< "$HELD_LANE_COMMANDS")"
assert_contains "held merged issue closes after explicit deployment proof" \
  "$HELD_PROVEN_CLOSE_COMMAND" "--remove-label on-hold"
assert_eq "explicit held close clears hold record" null \
  "$(jq -c '.hold // null' "$HELD_LANE_HOME/state/740033.json")"
assert_contains "held close without proof is refused" "$HELD_LANE_OUTPUT" "held-close-rejected"
HELD_MERGED_COMMAND="$(grep -F 'issue edit 740035 ' <<< "$HELD_LANE_COMMANDS")"
assert_contains "held ticket with a merged PR enters awaiting-release" \
  "$HELD_MERGED_COMMAND" "--add-label awaiting-release"
assert_contains "merged PR releases the hold label" "$HELD_MERGED_COMMAND" "--remove-label on-hold"
assert_eq "merged PR clears the hold record" null \
  "$(jq -c '.hold // null' "$HELD_LANE_HOME/state/740035.json")"
assert_eq "merged PR keeps requeued_at, so a later deploy close is not stale" "2026-10-01T00:00:00Z" \
  "$(jq -r '.requeued_at' "$HELD_LANE_HOME/state/740035.json")"
assert_contains "held close refusal names missing explicit reason" \
  "$HELD_LANE_SUPPRESSIONS" "issue_transition: refused held #740034 awaiting-release -> concluded (reason=operator-shortcut)"
assert_not_contains "held close refusal leaves GitHub untouched" \
  "$HELD_LANE_COMMANDS" "issue edit 740034"
assert_eq "held close refusal leaves local state untouched" awaiting-release \
  "$(jq -r '.state' "$HELD_LANE_HOME/state/740034.json")"
assert_contains "state_requeue suppression log identifies writer" \
  "$HELD_LANE_SUPPRESSIONS" "issue_transition: refused held #740024 concluded -> ready-for-agent (reason=conclusion-requeue)"
assert_contains "lane-only suppression log identifies writer" \
  "$HELD_LANE_SUPPRESSIONS" "guarded_write: suppressed ready-for-agent on held #740028 by empty_lane_writer"
assert_contains "mixed-edit suppression log identifies writer" \
  "$HELD_LANE_SUPPRESSIONS" "guarded_write: suppressed ready-for-agent on held #740029 by mixed_label_writer"
assert_contains "an unreadable hold keeps the lane write" \
  "$HELD_LANE_COMMANDS" "issue edit 740031 --repo test/repo --add-label awaiting-release"
HELD_UNREADABLE_TRANSITION_COMMAND="$(grep -F 'issue edit 740032 ' <<< "$HELD_LANE_COMMANDS")"
assert_contains "an unreadable hold allows the state transition to retain its stage label" \
  "$HELD_UNREADABLE_TRANSITION_COMMAND" "--add-label ready-for-agent"
assert_not_contains "an unreadable hold is not removed by a transition from another state" \
  "$HELD_UNREADABLE_TRANSITION_COMMAND" "--remove-label on-hold"
assert_eq "an unreadable hold state transition persists local stage" ready-for-agent \
  "$(jq -r '.state' "$HELD_LANE_HOME/state/740032.json")"
assert_contains "a hold that becomes readable mid-transition rolls durable state back" \
  "$HELD_LANE_OUTPUT" "transient-held-transition-rolled-back"
assert_not_contains "a refused transient-held transition does not reach GitHub" \
  "$HELD_LANE_COMMANDS" "issue edit 740036"
assert_contains "transient held transition is rejected by shared writer" \
  "$HELD_LANE_SUPPRESSIONS" "guarded_write: refusing partial stage transition for held #740036"
rm -rf "$HELD_LANE_HOME"

HOLD_LIFECYCLE_HOME="$(mktemp -d)"
mkdir -p "$HOLD_LIFECYCLE_HOME/bin"
cat > "$HOLD_LIFECYCLE_HOME/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_ACTIVE_UNITS:-}"
EOF
chmod +x "$HOLD_LIFECYCLE_HOME/bin/systemctl"
HOLD_DEAD_HOME="$HOLD_LIFECYCLE_HOME/dead"
mkdir -p "$HOLD_DEAD_HOME/state" "$HOLD_DEAD_HOME/night"
HOLD_FUTURE_EXPIRY="$(date -u -d '72 hours' +%Y-%m-%dT%H:%M:%SZ)"
jq -cn --arg expires "$HOLD_FUTURE_EXPIRY" \
  '{state:"on-hold",hold:{holder:"supervisor (hand-740040)",release_condition:"test",expires_at:$expires,stage_before:"needs-triage",kind:"hand-agent",created_at:(now|todate)}}' \
  > "$HOLD_DEAD_HOME/state/740040.json"
jq -cn --arg expires "$HOLD_FUTURE_EXPIRY" \
  '{state:"on-hold",hold:{holder:"hand-740041",release_condition:"test",expires_at:$expires,stage_before:"needs-info",kind:"hand",created_at:(now|todate)}}' \
  > "$HOLD_DEAD_HOME/state/740041.json"
jq -cn --arg expires "$HOLD_FUTURE_EXPIRY" \
  '{state:"on-hold",hold:{holder:"supervisor (hand-740046)",release_condition:"test",expires_at:$expires,stage_before:"needs-advisor",kind:"hand-dispatch",created_at:(now|todate)}}' \
  > "$HOLD_DEAD_HOME/state/740046.json"
jq -cn --arg expires "$HOLD_FUTURE_EXPIRY" \
  '{state:"on-hold",hold:{holder:"hand-740048",release_condition:"test",expires_at:$expires,stage_before:"needs-info",kind:"hand-dispatch",created_at:(now|todate)}}' \
  > "$HOLD_DEAD_HOME/state/740048.json"
printf 'recent hand report\n' > "$HOLD_DEAD_HOME/night/hand-740046-report.md"
HOLD_DEAD_RUN="$(AGENT_HOME="$HOLD_DEAD_HOME" ZF_NIGHT_DIR="$HOLD_DEAD_HOME/night" REPO=test/repo ZF_REPO=test/repo DRY_RUN=0 \
  HOLD_WRITE_LOG="$HOLD_LIFECYCLE_HOME/writes.log" HOLD_COMMENT_LOG="$HOLD_LIFECYCLE_HOME/comments.log" \
  FAKE_ACTIVE_UNITS=$'zf-hand-hand-740041-123.scope loaded active running hand' \
  PATH="$HOLD_LIFECYCLE_HOME/bin:$PATH" bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    source "$1/night/hand-agent-watchdog.sh"
    roadmap_ensure_issue_parent() { :; }
    owner_ticks="$(hand_agent_process_start_ticks "$$")"
    printf "%s\thand-740048-worker\tmodel\teffort\tworktree\tbrief\t\tlog\t0\t1\twork\t%s\t740048\t\n" \
      "$$" "$owner_ticks" > "$ZF_NIGHT_DIR/agents.txt"
    gh() {
      # #193: hold_sweep reads one batched issue-list snapshot (number/state/
      # labels/comments per row) instead of per-issue views; OPEN rows are the
      # live holds, so each fixture issue rides the snapshot like the old
      # issue-view stub below it.
      if [[ "$1 ${2:-}" == "issue list" ]]; then
        jq -cn '\''[740040,740041,740046,740048] | map({number:.,state:"OPEN",labels:[{name:"on-hold"}],comments:[],title:"hold fixture"})'\''
      else
        jq -cn '\''{state:"OPEN",labels:[{name:"on-hold"}],comments:[],title:"hold fixture"}'\''
      fi
    }
    guarded_write() { printf "%s\n" "$*" >> "$HOLD_WRITE_LOG"; }
    guarded_issue_comment() { printf "%s\n" "$2" >> "$HOLD_COMMENT_LOG"; }
    hold_sweep
    printf "dead=%s unit-live=%s report-live=%s roster-live=%s\n" \
      "$(jq -r .state "$AGENT_HOME/state/740040.json")" \
      "$(jq -r .state "$AGENT_HOME/state/740041.json")" \
      "$(jq -r .state "$AGENT_HOME/state/740046.json")" \
      "$(jq -r .state "$AGENT_HOME/state/740048.json")"
  ' _ "$SCRIPT_DIR" 2>&1)"
assert_contains "dead-owner hand hold returns to its recorded stage" \
  "$HOLD_DEAD_RUN" "dead=needs-triage unit-live=on-hold report-live=on-hold roster-live=on-hold"
assert_contains "dead-owner hold posts one comment naming its owner" \
  "$(cat "$HOLD_LIFECYCLE_HOME/comments.log")" "hand-740040"
assert_eq "dead-owner hold posts exactly one bot comment" 1 \
  "$(grep -c '<!-- vecta-hold-dead-owner issue=740040 ' "$HOLD_LIFECYCLE_HOME/comments.log")"
assert_contains "dead-owner hold replaces on-hold with stage label" \
  "$(cat "$HOLD_LIFECYCLE_HOME/writes.log")" "--remove-label on-hold"
assert_contains "dead-owner hold returns to its recorded state label" \
  "$(cat "$HOLD_LIFECYCLE_HOME/writes.log")" "--add-label needs-triage"
assert_not_contains "live systemd hand owner keeps its hold" \
  "$(cat "$HOLD_LIFECYCLE_HOME/writes.log")" "issue edit 740041"
assert_not_contains "recent hand report also keeps its owner hold" \
  "$(cat "$HOLD_LIFECYCLE_HOME/writes.log")" "issue edit 740046"
assert_not_contains "live roster PID/start ticks keep the exact hand owner hold" \
  "$(cat "$HOLD_LIFECYCLE_HOME/writes.log")" "issue edit 740048"

HOLD_AGE_HOME="$HOLD_LIFECYCLE_HOME/aging"
mkdir -p "$HOLD_AGE_HOME/state" "$HOLD_AGE_HOME/night"
HOLD_AGE_EXPIRY="$(date -u -d '120 hours' +%Y-%m-%dT%H:%M:%SZ)"
HOLD_AGE_CREATED_55H="$(date -u -d '55 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
jq -cn --arg expires "$HOLD_AGE_EXPIRY" --arg created "$HOLD_AGE_CREATED_55H" \
  '{state:"on-hold",hold:{holder:"supervisor",release_condition:"test",expires_at:$expires,stage_before:"needs-triage",kind:"supervisor",created_at:$created}}' \
  > "$HOLD_AGE_HOME/state/740042.json"
jq -cn --arg expires "$HOLD_AGE_EXPIRY" --arg created "$HOLD_AGE_CREATED_55H" \
  '{state:"on-hold",hold:{holder:"supervisor",release_condition:"test",expires_at:$expires,stage_before:"needs-triage",kind:"supervisor-inbox",created_at:$created}}' \
  > "$HOLD_AGE_HOME/state/740043.json"
jq -cn --arg expires "$HOLD_AGE_EXPIRY" --arg created "$HOLD_AGE_CREATED_55H" \
  '{state:"on-hold",hold:{holder:"manual",release_condition:"test",expires_at:$expires,stage_before:"needs-info",kind:"manual",created_at:$created}}' \
  > "$HOLD_AGE_HOME/state/740049.json"
HOLD_AGE_RUN="$(AGENT_HOME="$HOLD_AGE_HOME" ZF_NIGHT_DIR="$HOLD_AGE_HOME/night" REPO=test/repo ZF_REPO=test/repo DRY_RUN=0 \
  FAKE_ACTIVE_UNITS= PATH="$HOLD_LIFECYCLE_HOME/bin:$PATH" bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    gh() {
      # #193 batched snapshot rows: OPEN + on-hold label keeps each aging
      # fixture a live hold without any per-issue view.
      if [[ "$1 ${2:-}" == "issue list" ]]; then
        jq -cn '\''[740042,740043,740049] | map({number:.,state:"OPEN",labels:[{name:"on-hold"}],comments:[],title:"hold fixture"})'\''
      else
        jq -cn '\''{state:"OPEN",labels:[{name:"on-hold"}],comments:[],title:"hold fixture"}'\''
      fi
    }
    guarded_write() { :; }
    guarded_issue_comment() { :; }
    supervisor_inbox_append() { printf "%s\n" "$2" >> "$AGENT_HOME/supervisor-inbox"; }
    hold_sweep
    rm -f "$AGENT_HOME/supervisor-inbox.once"
    hold_sweep
    created="$(date -u -d "100 hours ago" +%Y-%m-%dT%H:%M:%SZ)"
    state_merge 740042 ".hold.created_at = \"$created\""
    state_merge 740049 ".hold.created_at = \"$created\""
    hold_sweep
    rm -f "$AGENT_HOME/supervisor-inbox.once"
    hold_sweep
  ' _ "$SCRIPT_DIR" 2>&1)"
assert_eq "supervisor hold aging emits once in each 48-hour window" 2 \
  "$(grep -c 'hold-aging issue=#740042 ' "$HOLD_AGE_HOME/supervisor-inbox" || true)"
assert_eq "manual hold aging also emits once in each 48-hour window" 2 \
  "$(grep -c 'hold-aging issue=#740049 ' "$HOLD_AGE_HOME/supervisor-inbox" || true)"
assert_not_contains "supervisor-inbox hold remains owned by advisor aging" \
  "$(cat "$HOLD_AGE_HOME/supervisor-inbox")" "issue=#740043"

AWAITING_RELEASE_HOME="$HOLD_LIFECYCLE_HOME/awaiting"
mkdir -p "$AWAITING_RELEASE_HOME/state"
MARK_AWAITING_OUTPUT="$(AGENT_HOME="$AWAITING_RELEASE_HOME" REPO=test/repo ZF_REPO=test/repo bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  roadmap_ensure_issue_parent() { :; }
  guarded_write() { printf "write:%s\n" "$*"; }
  merged_pr_main_row() { printf "%s\tmerge-sha\n" "$1"; }
  state_merge 740044 '\''{"state":"on-hold","run":{"evidence":{}}}'\''
  mark_awaiting_release 740044 987
  merged_pr_for_issue 740044
  state_merge 740047 '\''{"state":"on-hold","run":{"evidence":{}}}'\''
  mark_awaiting_release 740047 988
  state_merge 740047 '\''.run.merged_at = null'\''
  if merged_pr_for_issue 740047; then echo incomplete-state-accepted; else echo incomplete-state-rejected; fi
' _ "$SCRIPT_DIR" 2>&1)"
AWAITING_RELEASE_STATE="$(jq -c . "$AWAITING_RELEASE_HOME/state/740044.json")"
assert_true "mark_awaiting_release writes the complete merged state" \
  jq -e '.state == "awaiting-release" and .run.outcome == "merged" and .run.evidence.pr_number == "987" and (.run.merged_at | type == "string" and length > 0) and .deploy_state == "pending" and .hold == null' \
  <<< "$AWAITING_RELEASE_STATE"
assert_true "mark_awaiting_release output passes run-release batch-close predicate" \
  jq -e '.state == "awaiting-release" and .run.outcome == "merged" and (.run.evidence.pr_number | tostring | test("^[0-9]+$"))' \
  <<< "$AWAITING_RELEASE_STATE"
assert_contains "merged_pr_for_issue accepts the complete handoff and exact PR" \
  "$MARK_AWAITING_OUTPUT" $'987\tmerge-sha'
assert_contains "merged_pr_for_issue rejects incomplete merge metadata" \
  "$MARK_AWAITING_OUTPUT" "incomplete-state-rejected"
assert_contains "mark_awaiting_release moves the release label" \
  "$MARK_AWAITING_OUTPUT" "--add-label awaiting-release"
assert_contains "mark_awaiting_release clears a stale hold label" \
  "$MARK_AWAITING_OUTPUT" "--remove-label on-hold"

TRACKER_PARENT_HOME="$HOLD_LIFECYCLE_HOME/parent"
mkdir -p "$TRACKER_PARENT_HOME/state"
printf '%s\n' '{"state":"on-hold","hold":{"holder":"supervisor","kind":"manual"},"attempts":2}' \
  > "$TRACKER_PARENT_HOME/state/740045.json"
TRACKER_PARENT_RUN="$(AGENT_HOME="$TRACKER_PARENT_HOME" REPO=test/repo ZF_REPO=test/repo bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  guarded_write() { printf "write:%s\n" "$*"; }
  recut_parent_has_open_child() { return 0; }
  state_requeue 740045 release-hold
  state_read 740045
' _ "$SCRIPT_DIR" 2>&1)"
TRACKER_PARENT_STATE="$TRACKER_PARENT_HOME/state/740045.json"
assert_true "releasing a held parent with open children retires it as a tracker" \
  jq -e '.state == "tracker" and .tracker_parent == true and .hold == null' "$TRACKER_PARENT_STATE"
assert_contains "tracker retirement removes the hold label" \
  "$TRACKER_PARENT_RUN" "--remove-label on-hold"
assert_not_contains "tracker parent never re-enters ready-for-agent" \
  "$TRACKER_PARENT_RUN" "--add-label ready-for-agent"
rm -rf "$HOLD_LIFECYCLE_HOME"

LEGACY_TIME_HOME="$(mktemp -d)"
mkdir -p "$LEGACY_TIME_HOME/state"
LEGACY_TIME_EPOCH="$(date -u -d '40 hours ago' +%s)"
printf '%s\n' '{"attempts":0,"state":"ready-for-agent","state_changed_at":null}' \
  > "$LEGACY_TIME_HOME/state/740001.json"
touch -d "@$LEGACY_TIME_EPOCH" "$LEGACY_TIME_HOME/state/740001.json"
LEGACY_CHANGED_AT="$(AGENT_HOME="$LEGACY_TIME_HOME" REPO="test/repo" bash -c '
  source "$1/lib.sh"
  state_merge 740001 '\'' .attempts = 1 '\''
  jq -r .state_changed_at "$AGENT_HOME/state/740001.json"
' _ "$SCRIPT_DIR" 2>&1 | tail -n 1)"
LEGACY_CHANGED_EPOCH="$(date -u -d "$LEGACY_CHANGED_AT" +%s)"
assert_true "a legacy null timestamp takes its old mtime as baseline, not the bookkeeping write time" \
  test "$LEGACY_CHANGED_EPOCH" -le "$(( $(date +%s) - 39 * 60 * 60 ))"
rm -rf "$LEGACY_TIME_HOME"

# --- enforce_autonomy_gate: the #1098 fail-open fix ------------------------
# 2026-09-12: triage returned risk_class=P2 with state=ready-for-agent in
# the same response — see lib.sh's enforce_autonomy_gate() comment for the
# full incident. These cases exercise every branch of the gate directly,
# without making provider calls or touching GitHub.
assert_eq "P2 + L0 downgrades (risk_class outside P0/P1)" \
  "ready-for-human" "$(enforce_autonomy_gate ready-for-agent P2 L0 2)"

assert_eq "P1 + L3 downgrades (L3 never qualifies, at any phase)" \
  "ready-for-human" "$(enforce_autonomy_gate ready-for-agent P1 L3 2)"

assert_eq "P1 + L2 at phase 2 downgrades (L2 needs phase 3)" \
  "ready-for-human" "$(enforce_autonomy_gate ready-for-agent P1 L2 2)"

assert_eq "P1 + L2 at phase 3 passes through (admissible here; GitNexus impact check already ran in the prompt)" \
  "ready-for-agent" "$(enforce_autonomy_gate ready-for-agent P1 L2 3)"

assert_eq "P1 + L0 passes through untouched" \
  "ready-for-agent" "$(enforce_autonomy_gate ready-for-agent P1 L0 2)"

assert_eq "garbage risk_class/level fails closed" \
  "ready-for-human" "$(enforce_autonomy_gate ready-for-agent bogus bogus 2)"

assert_eq "empty risk_class/level fails closed" \
  "ready-for-human" "$(enforce_autonomy_gate ready-for-agent "" "" 2)"

assert_eq "a non-ready-for-agent state is left alone even with a P2/disqualifying level (the gate only ever narrows)" \
  "needs-info" "$(enforce_autonomy_gate needs-info P2 L0 2)"

# --- issue-pipeline.sh's dispatch-time gate recomputation (2026-09-12 review,
# item 1): section (c) now re-runs this exact function against the state
# file's OWN risk_class/level before ever dispatching a `ready-for-agent`
# candidate, instead of trusting the label alone (any of this repo's five
# `write`-holding teammates can apply that label by hand). It is the same
# call shape as run-triage.sh's, so no separate function exists to test —
# these are the two cases the incident (#1098: risk_class=P2, hand-labeled
# ready-for-agent) actually needs covered at dispatch time.
assert_eq "a hand-labeled ready-for-agent candidate whose stored risk_class is outside P0/P1 is caught at dispatch time, same as at triage time" \
  "ready-for-human" "$(enforce_autonomy_gate ready-for-agent P2 L1 2)"

assert_eq "a hand-labeled ready-for-agent candidate whose stored fields are legitimately admissible passes the dispatch-time recheck too" \
  "ready-for-agent" "$(enforce_autonomy_gate ready-for-agent P1 L1 2)"

# --- read_agent_phase: the fail-closed AGENT_PHASE read shared by
# run-triage.sh (per-run) and issue-pipeline.sh (per-tick, for the
# recomputation above). `gh` itself isn't exercised here — see PATH stub.
assert_eq "an unreadable/missing gh falls back to phase 2" \
  "2" "$(PATH=/nonexistent read_agent_phase)"

# --- triage_classification_status: the #1130-#1137 unmeasured-vs-corrupt
# gate. issue-pipeline.sh's section (c) calls this BEFORE ever calling
# enforce_autonomy_gate — see its comment in lib.sh for the full incident
# (a never-triaged issue, hand-stamped ready-for-agent by /wayfinder ->
# to-spec -> to-tickets, used to fall through the gate's `*` branch exactly
# like a genuinely oversized issue and got the same "adjust your permission
# settings" email, which nobody could act on).
TCS_TEST_DIR="$(mktemp -d)"
LIB_TEST_TMP_DIRS+=("$TCS_TEST_DIR")

assert_eq "no state file at all is unmeasured" \
  "unmeasured" "$(triage_classification_status "$TCS_TEST_DIR/missing.json")"

echo '{"attempts":2}' > "$TCS_TEST_DIR/attempts-only.json"
assert_eq "a valid state file with only .attempts (a failed prior triage/implement attempt, never classified) is unmeasured, same as no file at all" \
  "unmeasured" "$(triage_classification_status "$TCS_TEST_DIR/attempts-only.json")"

echo '{"attempts":1,"risk_class":"P2","level":"L0","state":"ready-for-human"}' > "$TCS_TEST_DIR/measured-oversized.json"
assert_eq "a state file carrying both fields is measured even when the values are disqualifying — that judgment belongs to enforce_autonomy_gate, not this function" \
  "measured" "$(triage_classification_status "$TCS_TEST_DIR/measured-oversized.json")"

echo '{"attempts":0,"risk_class":"P0","level":"L0","state":"ready-for-agent"}' > "$TCS_TEST_DIR/measured-admissible.json"
assert_eq "a state file carrying both fields with admissible values is measured" \
  "measured" "$(triage_classification_status "$TCS_TEST_DIR/measured-admissible.json")"

printf '{"attempts": broken json' > "$TCS_TEST_DIR/corrupt.json"
assert_eq "invalid JSON is malformed, deliberately NOT folded into unmeasured (see lib.sh comment: re-triaging real corruption forever, silently, is its own loop)" \
  "malformed" "$(triage_classification_status "$TCS_TEST_DIR/corrupt.json")"

rm -rf "$TCS_TEST_DIR"

# --- open_blocker_ids_from_rest_json / has_open_blocker: issue #1137 (live: blocked by
# #1132) — native GitHub Issue dependency edges this pipeline previously
# never read. open_blocker_ids_from_rest_json() is the pure decision over an
# already-fetched `dependencies/blocked_by` response, purely so it's testable
# without a live `gh api` call.
assert_eq "at least one open blocker is blocked" "1132" \
  "$(open_blocker_ids_from_rest_json '[{"number":1132,"state":"open"},{"number":1099,"state":"closed"}]')"

assert_eq "an open blocker awaiting release is cleared for implement" "" \
  "$(open_blocker_ids_from_rest_json '[{"number":1132,"state":"open","labels":[{"name":"awaiting-release"}]}]')"

assert_eq "an open released blocker is cleared for implement" "" \
  "$(open_blocker_ids_from_rest_json '[{"number":1132,"state":"open","labels":[{"name":"released"}]}]')"

assert_eq "an open blocker with another label still blocks" "1132" \
  "$(open_blocker_ids_from_rest_json '[{"number":1132,"state":"open","labels":[{"name":"ready-for-agent"}]}]')"

assert_eq "every blocker closed is not blocked" "" \
  "$(open_blocker_ids_from_rest_json '[{"number":1132,"state":"closed"}]')"

assert_eq "no blockers at all is not blocked" "" \
  "$(open_blocker_ids_from_rest_json '[]')"

# has_open_blocker() makes one live `gh api` call. Cover both its concrete
# blocker metadata and its fail-closed path (2026-09-13, #1163: 13 open
# blockers, one
# transient API failure plus one hand-applied ready-for-agent label was
# enough for the old fail-OPEN version to wave the issue through). With no
# `gh` reachable at all, the api call fails and has_open_blocker() must now
# return true (blocked) — same PATH-stub trick read_agent_phase's test above
# uses. The call site records the blocker IDs in the tick ledger before its
# `continue`, so a closed gate is observable without changing the issue.
assert_true "an unreachable/missing gh fails CLOSED — a lookup failure blocks the candidate this tick" \
  bash -c 'source "$1" >/dev/null 2>&1; PATH=/nonexistent has_open_blocker 1137' _ "$SCRIPT_DIR/lib.sh"

BLOCKER_METADATA="$(REPO=test/repo bash -c '
  source "$1/lib.sh"
  gh() { printf "[{\\\"number\\\":1132,\\\"state\\\":\\\"open\\\"},{\\\"number\\\":1099,\\\"state\\\":\\\"closed\\\"}]\\n"; }
  if has_open_blocker 1137; then
    printf "ids=%s query_failed=%s\\n" "$OPEN_BLOCKER_IDS" "$OPEN_BLOCKER_QUERY_FAILED"
  fi
' _ "$SCRIPT_DIR" 2>&1 || true)"
assert_eq "has_open_blocker exposes concrete open blocker IDs for the tick ledger" \
  "ids=1132 query_failed=0" "$(grep '^ids=' <<< "$BLOCKER_METADATA" || true)"

MIXED_BLOCKER_METADATA="$(REPO=test/repo bash -c '
  source "$1/lib.sh"
  gh() {
    printf "%s\n" "[{\"number\":1132,\"state\":\"open\",\"labels\":[{\"name\":\"awaiting-release\"}]},{\"number\":1133,\"state\":\"open\",\"labels\":[{\"name\":\"released\"}]},{\"number\":1134,\"state\":\"open\",\"labels\":[{\"name\":\"ready-for-agent\"}]},{\"number\":1135,\"state\":\"open\",\"labels\":[]},{\"number\":1136,\"state\":\"closed\",\"labels\":[{\"name\":\"released\"}]}]"
  }
  if has_open_blocker 1137; then
    printf "blocked=1 ids=%s query_failed=%s\n" "$OPEN_BLOCKER_IDS" "$OPEN_BLOCKER_QUERY_FAILED"
  else
    printf "blocked=0 ids=%s query_failed=%s\n" "$OPEN_BLOCKER_IDS" "$OPEN_BLOCKER_QUERY_FAILED"
  fi
' _ "$SCRIPT_DIR" 2>&1 || true)"
assert_eq "mixed dependencies report only blockers without cleared labels" \
  "blocked=1 ids=1134, 1135 query_failed=0" "$MIXED_BLOCKER_METADATA"

PROSE_BLOCKER_OPEN="$(REPO=test/repo bash -c '
  source "$1/lib.sh"
  gh() {
    [ "$1 $2" = "issue view" ] || return 64
    case "$3" in
      1131) echo '\''{"state":"OPEN","labels":[]} '\'' ;;
      1135) echo '\''{"state":"CLOSED","labels":[]} '\'' ;;
      1136) echo '\''{"state":"MERGED","labels":[]} '\'' ;;
      1141) echo '\''{"state":"OPEN","labels":["awaiting-release"]}'\'' ;;
      *) return 1 ;;
    esac
  }
  if has_open_prose_blocker 1496 $'"'"'Depends on #1131, #1135 and PR #1136.\nRelated: #1480.'"'"'; then
    printf "ids=%s query_failed=%s\\n" "$OPEN_BLOCKER_IDS" "$OPEN_BLOCKER_QUERY_FAILED"
  else
    echo clear
  fi
' _ "$SCRIPT_DIR" 2>&1)"
assert_eq "a prose-named open prerequisite blocks while unrelated, closed issues and merged PRs do not" \
  "ids=1131 query_failed=0" "$(grep '^ids=' <<< "$PROSE_BLOCKER_OPEN" || true)"

assert_false "a prose-named open blocker awaiting release is cleared" \
  bash -c '
    REPO=test/repo
    source "$1/lib.sh"
    gh() { echo '\''{"state":"OPEN","labels":["awaiting-release"]}'\''; }
    has_open_prose_blocker 1496 "Prerequisite: #1141"
  ' _ "$SCRIPT_DIR"

PROSE_BLOCKER_UNKNOWN="$(REPO=test/repo bash -c '
  source "$1/lib.sh"
  gh() { return 1; }
  if has_open_prose_blocker 1496 "Prerequisite: #1137"; then
    printf "blocked=%s query_failed=%s\\n" "$OPEN_BLOCKER_IDS" "$OPEN_BLOCKER_QUERY_FAILED"
  else
    echo clear
  fi
' _ "$SCRIPT_DIR" 2>&1)"
assert_eq "an unreadable prose-named prerequisite fails closed" \
  "blocked=1137 query_failed=1" "$(grep '^blocked=' <<< "$PROSE_BLOCKER_UNKNOWN" || true)"

assert_false "an unrelated issue mention does not create a prose blocker" \
  has_open_prose_blocker 1496 'Related: #1480, see also #1374.'

assert_false "a keyword binds only the issue in its own clause, not the whole line" \
  bash -c '
    REPO=test/repo
    source "$1/lib.sh"
    gh() { [ "$3" = 2568 ] && echo '\''{"state":"CLOSED","labels":[]}'\'' || echo '\''{"state":"OPEN","labels":[]}'\''; }
    has_open_prose_blocker 2681 "#2398（姊妹缺口）/ #2568（建档出口依赖）/ #2493 B1（落地后可完整实现；本票先收口运行时行为）"
  ' _ "$SCRIPT_DIR"

# --- recut leg (engine/run-recut.sh) ---------------------------------

# recut_categorically_oversized(): pure re-derivation from
# enforce_autonomy_gate() itself — recut exists only for a ticket that gate
# refuses at EVERY phase, never for one that's merely phase-gated (a policy
# dial the maintainer can turn by raising AGENT_PHASE, not a shape problem).
assert_true "P2 at any level is categorically oversized (risk_class alone refuses it at every phase)" \
  recut_categorically_oversized P2 L2
assert_false "P0/L0 is not categorically oversized (admissible at every phase)" \
  recut_categorically_oversized P0 L0
assert_false "P1/L2 is not categorically oversized (admissible at phase 3 — merely phase-gated)" \
  recut_categorically_oversized P1 L2
assert_true "P1/L3 is categorically oversized (L3 never admits, at any phase, whatever the risk_class)" \
  recut_categorically_oversized P1 L3
assert_true "P1/L4 is categorically oversized (L4 never admits, at any phase)" \
  recut_categorically_oversized P1 L4

# recut_child_count_ok(): the child cap. A tracker flooded with
# auto-generated tickets is a worse outcome than the parked ticket recut
# started from (task brief, "Scale discipline") — pinned here in isolation,
# same shape as cap_slots_remaining()'s own tests above.
assert_false "zero children is not a valid cut (that's a refusal, not this check)" \
  recut_child_count_ok 0 4
assert_true "one child is within a cap of 4" \
  recut_child_count_ok 1 4
assert_true "exactly the cap is within the cap" \
  recut_child_count_ok 4 4
assert_false "one over the cap is refused" \
  recut_child_count_ok 5 4

# recut_slice_verified(): the hard "never fabricate" gate — re-verifies every
# file and symbol a proposed child claims against the real checkout on disk,
# never trusting the model's own claim. 2026-09-14: 3 of 23 hand-cut slices
# were pure invention (freshly-declared types with no callers) because the
# domain had zero real implementation; this is the mechanical check that
# would have caught them (prompt-only compliance measures under 2% on this
# codebase).
RSV_DIR="$(mktemp -d)"
LIB_TEST_TMP_DIRS+=("$RSV_DIR")
echo "export function realSymbol() {}" > "$RSV_DIR/a.ts"
echo "export const anotherReal = 1;" > "$RSV_DIR/b.ts"

assert_true "a slice naming only real files and real symbols verifies" \
  recut_slice_verified '["a.ts","b.ts"]' '["realSymbol","anotherReal"]' "$RSV_DIR"
assert_false "a slice naming a symbol that appears nowhere in its own files fails — the invented-type shape" \
  recut_slice_verified '["a.ts","b.ts"]' '["fabricatedSymbol"]' "$RSV_DIR"
assert_false "a slice naming a file that doesn't exist fails" \
  recut_slice_verified '["nope-does-not-exist.ts"]' '[]' "$RSV_DIR"
assert_false "a symbol with no files to grep it in fails closed, not vacuously true" \
  recut_slice_verified '[]' '["x"]' "$RSV_DIR"
assert_true "no files and no symbols claimed verifies trivially" \
  recut_slice_verified '[]' '[]' "$RSV_DIR"

rm -rf "$RSV_DIR"

# recut_topo_order(): gh issue create --blocked-by needs its blockers to
# already exist as real issue numbers, but proposed children only know each
# other by array index until created — this orders creation so every
# blocker is already created, and refuses (prints nothing, exits non-zero)
# on a cycle rather than silently dropping an edge.
assert_eq "a valid chain orders blockers before what blocks on them" \
  "0
1
2" \
  "$(recut_topo_order '[{"blocked_by_child_indices":[]},{"blocked_by_child_indices":[0]},{"blocked_by_child_indices":[0,1]}]')"

assert_eq "independent children (no edges) can order either way, but all are present" \
  "0
1" \
  "$(recut_topo_order '[{"blocked_by_child_indices":[]},{"blocked_by_child_indices":[]}]')"

assert_false "a two-node cycle is refused, not silently resolved" \
  bash -c 'source "$1" >/dev/null 2>&1; recut_topo_order "$2"' _ "$SCRIPT_DIR/lib.sh" \
  '[{"blocked_by_child_indices":[1]},{"blocked_by_child_indices":[0]}]'

assert_eq "a cyclic batch prints nothing (never a partial/silently-wrong order)" \
  "" \
  "$(recut_topo_order '[{"blocked_by_child_indices":[1]},{"blocked_by_child_indices":[0]}]' 2>/dev/null || true)"

# --- render_pr_state_block: the #1098 stale-comment/finish-first loop fix --
# run-triage.sh gathers $2 live via `gh pr list`/`gh api .../branches/..`;
# this function only renders it, so these cases exercise the renderer
# against fixture JSON in the exact shape run-triage.sh builds (see lib.sh's
# comment on the function for the live #1098 incident this closes).
assert_eq "no PRs found says so plainly, not silently empty" \
  "## Live pull request state for issue #1098 (queried live via gh by the wrapper, not read from the thread)
No open, closed, or merged pull request currently references issue #1098 (checked head branch \`agent/issue-1098\` and any PR whose title or body mentions \`#1098\`)." \
  "$(render_pr_state_block 1098 '[]' 1)"

assert_eq "one open PR with a live branch reads as in-flight work" \
  "## Live pull request state for issue #1098 (queried live via gh by the wrapper, not read from the thread)
- PR #1099: OPEN, base branch \`main\`, head branch \`agent/issue-1098\`, branch still exists on the remote" \
  "$(render_pr_state_block 1098 '[{"number":1099,"state":"OPEN","isDraft":false,"headRefName":"agent/issue-1098","baseRefName":"main","branch_exists":true}]' 1)"

assert_eq "the live #1098 fixture: a closed draft PR with its branch deleted reads as abandoned, not in flight" \
  "## Live pull request state for issue #1098 (queried live via gh by the wrapper, not read from the thread)
- PR #1099: CLOSED (draft), base branch \`main\`, head branch \`agent/issue-1098\`, branch deleted from the remote" \
  "$(render_pr_state_block 1098 '[{"number":1099,"state":"CLOSED","isDraft":true,"headRefName":"agent/issue-1098","baseRefName":"main","branch_exists":false}]' 1)"

assert_eq "a merged PR renders its state as MERGED, not CLOSED" \
  "## Live pull request state for issue #1098 (queried live via gh by the wrapper, not read from the thread)
- PR #1099: MERGED, base branch \`main\`, head branch \`agent/issue-1098\`, branch deleted from the remote" \
  "$(render_pr_state_block 1098 '[{"number":1099,"state":"MERGED","isDraft":false,"headRefName":"agent/issue-1098","baseRefName":"main","branch_exists":false}]' 1)"

assert_eq "a query failure says so plainly instead of rendering an empty (indistinguishable from zero-PRs) block" \
  "## Live pull request state for issue #1098 (queried live via gh by the wrapper, not read from the thread)
PR query failed. Treat live PR state as unknown for this run -- proceed with triage on the evidence above; a \`gh\` hiccup here is not a reason to withhold or grant any state." \
  "$(render_pr_state_block 1098 '[]' 0)"

# --- comment_is_bot: item 3's quote-reply misfire fix -----------------------
# BOT_COMMENT_MARKER substring matching used to misfire on GitHub's "Quote
# reply", which copies the ENTIRE quoted bot comment (marker included) into
# the reporter's own new comment. comment_is_bot() tests a literal prefix
# instead (see its comment in lib.sh for why glob `[[ == ]]` isn't safe here).
assert_true "a genuine bot comment (starts with the disclaimer) is detected" \
  comment_is_bot "$BOT_DISCLAIMER
Some brief triage note."

assert_false "a reporter's plain reply carries no marker at all and is not mistaken for a bot comment" \
  comment_is_bot "Yes, that's the department key I meant — please retry."

assert_false "a reporter's GitHub quote-reply embeds the marker but does not START with the disclaimer, so it is correctly read as human" \
  comment_is_bot "> $BOT_DISCLAIMER
> Some brief triage note.

Yes, that's the department key I meant — please retry."

# --- expected_packages_collide: the derived package-exclusion predicate ----
# (replaces the old finish-first collision branch — see issue-pipeline.sh)
assert_true "the same package declared by both sides collides" \
  expected_packages_collide '["packages/example-gateway"]' '["packages/example-gateway"]'

assert_true "a candidate nested under an already-in-flight package collides" \
  expected_packages_collide '["packages/example-gateway/admin"]' '["packages/example-gateway"]'

assert_false "unrelated packages on both sides do not collide" \
  expected_packages_collide '["packages/example-gateway"]' '["packages/example-service"]'

assert_false "no other implement run in flight (empty union) never collides" \
  expected_packages_collide '["packages/example-gateway"]' '[]'

assert_false "a candidate with nothing declared has nothing to collide" \
  expected_packages_collide '[]' '["packages/example-gateway"]'

# --- issue_numbers_in_range / deploy_is_blocked: built against a throwaway --
# git repo, never the real $REPO_DIR, so these tests write nothing under
# ~/.zenoforge and make zero `gh`/network calls.
TEST_REPO="$(mktemp -d)"
LIB_TEST_TMP_DIRS+=("$TEST_REPO")
git -C "$TEST_REPO" init -q -b main
git -C "$TEST_REPO" config user.email test@example.com
git -C "$TEST_REPO" config user.name "lib.test.sh"
git -C "$TEST_REPO" commit -q --allow-empty -m "fix(#10): root commit"
SHA_10="$(git -C "$TEST_REPO" rev-parse HEAD)"
git -C "$TEST_REPO" commit -q --allow-empty -m "chore: unrelated human commit, no issue"
git -C "$TEST_REPO" commit -q --allow-empty -m "fix(#11): second agent commit"
SHA_11="$(git -C "$TEST_REPO" rev-parse HEAD)"
git -C "$TEST_REPO" commit -q --allow-empty -m "fix(#12): third agent commit, unrelated to the deploy below"
SHA_12="$(git -C "$TEST_REPO" rev-parse HEAD)"

assert_eq "issue_numbers_in_range extracts every fix(#N): subject in the range" \
  "$(printf '12\n11')" "$(issue_numbers_in_range "$SHA_10..$SHA_12" "$TEST_REPO")"

assert_eq "a narrower range only extracts the issues actually in it" \
  "11" "$(issue_numbers_in_range "$SHA_10..$SHA_11" "$TEST_REPO")"

git -C "$TEST_REPO" commit -q --allow-empty -m "chore: another human commit, no issue"
SHA_13="$(git -C "$TEST_REPO" rev-parse HEAD)"
NO_MATCH_STATUS=0
NO_MATCH_ISSUES="$(issue_numbers_in_range "$SHA_12..$SHA_13" "$TEST_REPO")" || NO_MATCH_STATUS=$?
assert_eq "an unattributed-only range produces no issue numbers" \
  "" "$NO_MATCH_ISSUES"
assert_eq "an unattributed-only range is a successful empty result" \
  "0" "$NO_MATCH_STATUS"

UNATTRIBUTED_TEST="$(git -C "$TEST_REPO" log --format=%s "$SHA_10..$SHA_11" | grep -vE '^fix\(#[0-9]+\):' || true)"
assert_eq "a human-authored commit in range is left for the caller to name as unattributed, not returned as an issue number" \
  "chore: unrelated human commit, no issue" "$UNATTRIBUTED_TEST"

MARKER_FILE="$TEST_REPO/.deploy-blocked-sha-test"

echo "$SHA_11" > "$MARKER_FILE"
assert_true "the exact blocked SHA is blocked" \
  deploy_is_blocked "$SHA_11" "$MARKER_FILE" "$TEST_REPO"
assert_false "a SHA descending from the blocked one may release (fix-forward, 2026-10-26 ruling)" \
  deploy_is_blocked "$SHA_12" "$MARKER_FILE" "$TEST_REPO"
assert_false "a SHA that predates the blocked one is not blocked" \
  deploy_is_blocked "$SHA_10" "$MARKER_FILE" "$TEST_REPO"

rm -f "$MARKER_FILE"
assert_false "no marker file at all means nothing is blocked" \
  deploy_is_blocked "$SHA_12" "$MARKER_FILE" "$TEST_REPO"

rm -rf "$TEST_REPO"

# --- bootstrap_old_deployed_sha: defect 2's fresh-install bootstrap range --
# Built against its own throwaway repo with REAL file changes (not
# --allow-empty), so the diff range this produces can be checked for real
# content, not just asserted about which SHA it names.
BOOTSTRAP_TEST_REPO="$(mktemp -d)"
LIB_TEST_TMP_DIRS+=("$BOOTSTRAP_TEST_REPO")
git -C "$BOOTSTRAP_TEST_REPO" init -q -b main
git -C "$BOOTSTRAP_TEST_REPO" config user.email test@example.com
git -C "$BOOTSTRAP_TEST_REPO" config user.name "lib.test.sh"

mkdir -p "$BOOTSTRAP_TEST_REPO/packages/pkg-a"
echo "before" > "$BOOTSTRAP_TEST_REPO/packages/pkg-a/x.txt"
git -C "$BOOTSTRAP_TEST_REPO" add packages/pkg-a/x.txt
git -C "$BOOTSTRAP_TEST_REPO" commit -q -m "root commit"

# This PR's own merge commit -- the one run-release.sh was invoked for.
echo "after" > "$BOOTSTRAP_TEST_REPO/packages/pkg-a/x.txt"
git -C "$BOOTSTRAP_TEST_REPO" add packages/pkg-a/x.txt
git -C "$BOOTSTRAP_TEST_REPO" commit -q -m "fix(#20): this PR's own change"
MERGE_SHA_TEST="$(git -C "$BOOTSTRAP_TEST_REPO" rev-parse HEAD)"

# A LATER, unrelated commit -- another queued issue landing on main after
# this PR merged (or an unrelated [skip ci] commit). This is what makes
# $DEPLOYED_SHA (current origin/main HEAD) diverge from $MERGE_SHA.
git -C "$BOOTSTRAP_TEST_REPO" commit -q --allow-empty -m "chore: unrelated later commit, no file changes"
DEPLOYED_SHA_TEST="$(git -C "$BOOTSTRAP_TEST_REPO" rev-parse HEAD)"

assert_eq "bootstraps from the triggering merge's own parent, not from current HEAD's parent" \
  "$(git -C "$BOOTSTRAP_TEST_REPO" rev-parse "${MERGE_SHA_TEST}^")" \
  "$(bootstrap_old_deployed_sha "$MERGE_SHA_TEST" "$BOOTSTRAP_TEST_REPO")"

OLD_DEPLOYED_SHA_TEST="$(bootstrap_old_deployed_sha "$MERGE_SHA_TEST" "$BOOTSTRAP_TEST_REPO")"
CORRECT_RANGE_FILES="$(git -C "$BOOTSTRAP_TEST_REPO" diff --name-only "$OLD_DEPLOYED_SHA_TEST" "$DEPLOYED_SHA_TEST" -- packages/)"
assert_true "the correct range includes the triggering PR's own changed file" \
  bash -c 'printf "%s" "$1" | grep -qF "packages/pkg-a/x.txt"' _ "$CORRECT_RANGE_FILES"

# The bug this replaces: diffing from $DEPLOYED_SHA^ instead of $MERGE_SHA^.
# Live #1098 reproduction: this range printed no changed images at all.
BUGGY_OLD_DEPLOYED_SHA="$(git -C "$BOOTSTRAP_TEST_REPO" rev-parse "${DEPLOYED_SHA_TEST}^")"
BUGGY_RANGE_FILES="$(git -C "$BOOTSTRAP_TEST_REPO" diff --name-only "$BUGGY_OLD_DEPLOYED_SHA" "$DEPLOYED_SHA_TEST" -- packages/)"
assert_false "the buggy range (current-HEAD^) silently drops the triggering PR's own changed file" \
  bash -c 'printf "%s" "$1" | grep -qF "packages/pkg-a/x.txt"' _ "$BUGGY_RANGE_FILES"

rm -rf "$BOOTSTRAP_TEST_REPO"

# --- acquire_merge_lock / release_merge_lock: the merge-queue mutex --------
# 2026-09-13 fix: run-implement.sh's merge-queue wait polled for a green
# main, then merged, with nothing serializing the gap between the two --
# two concurrent implement runs could both pass the check and merge inside
# the same Postsubmit window, exactly what the
# wait exists to prevent. Proven here against a throwaway lock file (never
# the real $MERGE_LOCK_FILE) with a real second process contending for it,
# not asserted in prose -- flock's exclusivity is per (file, open file
# description), so a second process opening its own fd on the same path is
# a genuine, independent contender, not a no-op self-check.
MERGE_LOCK_TEST_FILE="$(mktemp -u)"

acquire_merge_lock "$MERGE_LOCK_TEST_FILE"

assert_false "a concurrent process cannot acquire the lock while this one holds it" \
  bash -c 'exec 9>"$1" && flock -n 9' _ "$MERGE_LOCK_TEST_FILE"

release_merge_lock

assert_true "release_merge_lock actually frees it for the next acquirer" \
  bash -c 'exec 9>"$1" && flock -n 9' _ "$MERGE_LOCK_TEST_FILE"

rm -f "$MERGE_LOCK_TEST_FILE"

# --- acquire_merge_lock's -w bound: 2026-09-12 review, item 2 --------------
# Before this fix, acquire_merge_lock() called plain `flock 8` (no -w), which
# blocks forever while another process holds it -- exactly the "hung stage
# holds a slot forever" shape the rest of item 2 fixes elsewhere. A second,
# genuinely independent process (not just another fd in this same one) holds
# the lock on fd 7 here so the child process below contends against a real
# holder, the same discipline the test above already uses.
MERGE_LOCK_BOUND_TEST_FILE="$(mktemp -u)"
exec 7>"$MERGE_LOCK_BOUND_TEST_FILE"
flock 7

assert_false "a bounded -w wait gives up instead of blocking forever while another process holds the lock" \
  bash -c 'source "$1" >/dev/null 2>&1; acquire_merge_lock "$2" 1' _ "$SCRIPT_DIR/lib.sh" "$MERGE_LOCK_BOUND_TEST_FILE"

flock -u 7
exec 7>&-
rm -f "$MERGE_LOCK_BOUND_TEST_FILE"

# Keep the library reset that followed the GitNexus fixtures before their
# extraction; later cases must start with the original functions restored.
source "$SCRIPT_DIR/lib.sh"

# --- resolve_recipients (notify.sh): email recipient resolution -----------
# Pure function -- no gh call, no network, no email sent (lib.sh sources
# notify.sh, so it's already in scope here). Uses a throwaway roster file,
# never the real ~/.zenoforge/recipients.json. The SMTP/HTTP send itself
# (send_email) is deliberately NOT tested here, per the brief.
ROSTER_TEST_FILE="$(mktemp)"
cat > "$ROSTER_TEST_FILE" <<'JSON'
{
  "founder_login": "the-maintainer",
  "recipients": {
    "known-reporter": "reporter@example.com",
    "the-maintainer": "maintainer@example.com"
  }
}
JSON

recipients_only() { grep -v '^NOTE:' || true; }

assert_eq "a known reporter maps to their address plus the maintainer's" \
  "$(printf 'reporter@example.com\nmaintainer@example.com')" \
  "$(resolve_recipients "known-reporter" "$ROSTER_TEST_FILE" | recipients_only)"

assert_eq "the maintainer as reporter yields exactly one recipient (deduplicated)" \
  "maintainer@example.com" \
  "$(resolve_recipients "the-maintainer" "$ROSTER_TEST_FILE" | recipients_only)"

assert_eq "an unknown login falls back to the maintainer alone" \
  "maintainer@example.com" \
  "$(resolve_recipients "someone-unmapped" "$ROSTER_TEST_FILE" | recipients_only)"

# author_is_maintainer(): the needs-info author rule. A predicate, so assert on
# the exit status rather than on stdout.
author_is_maintainer_says() {
  if author_is_maintainer "$1" "${2:-$ROSTER_TEST_FILE}"; then echo yes; else echo no; fi
}

assert_eq "the maintainer's own login is recognized as the maintainer" \
  "yes" "$(author_is_maintainer_says "the-maintainer")"

assert_eq "a known reporter is not the maintainer" \
  "no" "$(author_is_maintainer_says "known-reporter")"

assert_eq "a login absent from the roster is not the maintainer" \
  "no" "$(author_is_maintainer_says "someone-unmapped")"

assert_eq "an empty login is not the maintainer" \
  "no" "$(author_is_maintainer_says "")"

# Fails closed toward "not the maintainer" so a broken roster can only leave
# behaviour as it was, never silently downgrade every ticket.
assert_eq "a missing roster file is not the maintainer" \
  "no" "$(author_is_maintainer_says "the-maintainer" "/nonexistent/roster.json")"

ROSTER_NO_MAINTAINER="$(mktemp)"
printf '%s' '{"recipients":{"the-maintainer":"maintainer@example.com"}}' > "$ROSTER_NO_MAINTAINER"
assert_eq "a roster with no founder_login is not the maintainer" \
  "no" "$(author_is_maintainer_says "the-maintainer" "$ROSTER_NO_MAINTAINER")"
rm -f "$ROSTER_NO_MAINTAINER"

unmapped_login_is_noted() {
  # Captured into a variable first, not piped straight into `grep -q`: under
  # this file's `pipefail` (inherited from sourcing lib.sh), `grep -q`
  # exiting the instant it matches can SIGPIPE a still-writing upstream
  # producer, and pipefail then reports THAT non-zero exit for the whole
  # pipeline even though grep itself matched -- a real gotcha hit while
  # writing this test, not a hypothetical one.
  local out
  out="$(resolve_recipients "someone-unmapped" "$ROSTER_TEST_FILE")"
  echo "$out" | grep -q '^NOTE:.*someone-unmapped'
}
assert_true "an unknown login is noted so a human can add it to the roster" \
  unmapped_login_is_noted

rm -f "$ROSTER_TEST_FILE"

MISSING_ROSTER_FILE="$(mktemp -u)"
assert_eq "a missing roster file yields no recipients, not a crash" \
  "" \
  "$(resolve_recipients "anyone" "$MISSING_ROSTER_FILE" | recipients_only)"

# --- pr_checks_outcome: defect 2's "skipping is not failure" predicate -----
# Fixtures shaped like `gh pr checks --json name,bucket` output. Since #4484 the
# required rows are the always-concluding aggregates; heavy-gate names appear as
# ordinary (legitimately skippable) rows. The first fixture is the live shape
# captured from PR #1099 plus the aggregate passes, that the old
# bucket=="skipping" check misclassified as `fail`.
PR_CHECKS_1099='[{"name":"Required CI gates","bucket":"pass"},{"name":"Required contract gates","bucket":"pass"},{"bucket":"pass","name":"contract"},{"bucket":"pass","name":"Enforce branch delivery policy"},{"bucket":"pass","name":"NUL bytes & lone negative assertions"},{"bucket":"pass","name":"Touched packages PR gate"},{"bucket":"pass","name":"Example pack PR gate"},{"bucket":"pass","name":"Repo-path regression PR gate"},{"bucket":"skipping","name":"Required CI gates"},{"bucket":"skipping","name":"Enforce branch delivery policy"},{"bucket":"skipping","name":"NUL bytes & lone negative assertions"},{"bucket":"skipping","name":"Example pack PR gate"},{"bucket":"skipping","name":"Touched packages PR gate"},{"bucket":"skipping","name":"Repo-path regression PR gate"},{"bucket":"skipping","name":"Postsubmit validate"},{"bucket":"skipping","name":"Postsubmit validate"}]'
assert_eq "the PR #1099 shape plus aggregates passes despite every skipping row" \
  "pass" "$(pr_checks_outcome "$PR_CHECKS_1099")"

# Heavy gates that legitimately did not run (only skipping rows) do not block:
# the aggregate row is the single required source of truth (#4484).
PR_CHECKS_AGGREGATE_ONLY='[{"name":"Required CI gates","bucket":"pass"},{"name":"Required contract gates","bucket":"pass"},{"bucket":"pass","name":"Enforce branch delivery policy"},{"bucket":"skipping","name":"Touched packages PR gate"},{"bucket":"skipping","name":"Example pack PR gate"},{"bucket":"skipping","name":"Repo-path regression PR gate"}]'
assert_eq "green aggregates with legitimately skipped heavy gates passes" \
  "pass" "$(pr_checks_outcome "$PR_CHECKS_AGGREGATE_ONLY")"

# PR #4024 shape, on the aggregate row: a startup_failure left no row while every gate passed.
PR_CHECKS_AGGREGATE_MISSING="$(jq -c 'map(select(.name != "Required contract gates"))' <<< "$PR_CHECKS_AGGREGATE_ONLY")"
assert_eq "a missing required aggregate fails closed despite other passing rows" \
  "fail" "$(pr_checks_outcome "$PR_CHECKS_AGGREGATE_MISSING")"
PR_CHECKS_AGGREGATE_SKIPPING="$(jq -c '. + [{name:"Required contract gates",bucket:"skipping"}]' <<< "$PR_CHECKS_AGGREGATE_MISSING")"
assert_eq "a skipping-only required aggregate fails closed despite other passing rows" \
  "fail" "$(pr_checks_outcome "$PR_CHECKS_AGGREGATE_SKIPPING")"

PR_CHECKS_AGGREGATE_RED='[{"name":"Required CI gates","bucket":"fail"},{"name":"Required contract gates","bucket":"pass"},{"bucket":"pass","name":"Enforce branch delivery policy"}]'
assert_eq "a red aggregate (a gate failed under it) fails" \
  "fail" "$(pr_checks_outcome "$PR_CHECKS_AGGREGATE_RED")"

PR_CHECKS_REAL_FAILURE='[{"name":"Required CI gates","bucket":"pass"},{"name":"Required contract gates","bucket":"pass"},{"bucket":"pass","name":"Enforce branch delivery policy"},{"bucket":"fail","name":"Touched packages PR gate"},{"bucket":"skipping","name":"Postsubmit validate"}]'
assert_eq "a real fail bucket on any check fails" \
  "fail" "$(pr_checks_outcome "$PR_CHECKS_REAL_FAILURE")"

PR_CHECKS_MISSING_REQUIRED='[{"name":"Required contract gates","bucket":"pass"},{"bucket":"pass","name":"Enforce branch delivery policy"}]'
assert_eq "a required aggregate absent entirely (job renamed) fails closed" \
  "fail" "$(pr_checks_outcome "$PR_CHECKS_MISSING_REQUIRED")"

PR_CHECKS_SKIPPING_ONLY_REQUIRED='[{"name":"Required contract gates","bucket":"pass"},{"bucket":"pass","name":"Enforce branch delivery policy"},{"bucket":"skipping","name":"Required CI gates"}]'
assert_eq "a required aggregate with only skipping rows fails closed" \
  "fail" "$(pr_checks_outcome "$PR_CHECKS_SKIPPING_ONLY_REQUIRED")"

PR_CHECKS_STILL_PENDING='[{"name":"Required contract gates","bucket":"pass"},{"bucket":"pass","name":"Enforce branch delivery policy"},{"bucket":"pending","name":"Required CI gates"}]'
assert_eq "a still-running required aggregate keeps waiting, not fails" \
  "pending" "$(pr_checks_outcome "$PR_CHECKS_STILL_PENDING")"

# Native GitHub auto-merge has no required-checks list on this private repo.
# Exercise the outward command boundary: refused forms must never reach gh.
AUTO_MERGE_GH_BIN="$(mktemp -d)"
export AUTO_MERGE_GH_LOG="$AUTO_MERGE_GH_BIN/calls"
cat > "$AUTO_MERGE_GH_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AUTO_MERGE_GH_LOG"
FAKE_GH
chmod +x "$AUTO_MERGE_GH_BIN/gh"
expect_auto_merge_refused() {
  local desc="$1" output status=0
  shift
  : > "$AUTO_MERGE_GH_LOG"
  output="$(PATH="$AUTO_MERGE_GH_BIN:$PATH" guarded_write "$@" 2>&1)" || status=$?
  assert_eq "$desc is refused" 64 "$status"
  assert_contains "$desc explains why" "$output" "no required-checks list"
  assert_eq "$desc never invokes gh" "" "$(cat "$AUTO_MERGE_GH_LOG")"
}
expect_auto_merge_refused "direct --auto" gh pr merge 42 --auto
expect_auto_merge_refused "direct --auto-merge" gh pr merge 42 --auto-merge
expect_auto_merge_refused "parent -R with --auto" gh -R test/repo pr merge 42 --auto
expect_auto_merge_refused "parent -R with --auto-merge" gh -R test/repo pr merge 42 --auto-merge
expect_auto_merge_refused "parent --repo with --auto" gh --repo test/repo pr merge 42 --auto
expect_auto_merge_refused "parent --repo= with --auto-merge" gh --repo=test/repo pr merge 42 --auto-merge
expect_auto_merge_refused "timeout with --auto" timeout 5s gh pr merge 42 --auto
expect_auto_merge_refused "timeout with --auto-merge" timeout 5s gh pr merge 42 --auto-merge
expect_auto_merge_refused "option-bearing timeout with --auto" timeout -k 1s --signal=TERM 5s gh -R test/repo pr merge 42 --auto
expect_auto_merge_refused "option-bearing timeout with --auto-merge" timeout --kill-after=1s --foreground 5s gh --repo test/repo pr merge 42 --auto-merge
expect_auto_merge_refused "timeout option terminator with --auto" timeout --kill-after=1s -- 5s gh pr merge 42 --auto

: > "$AUTO_MERGE_GH_LOG"
if [ "$(pr_checks_outcome "$PR_CHECKS_1099")" = pass ]; then
  PATH="$AUTO_MERGE_GH_BIN:$PATH" guarded_write gh pr merge 42 --squash --match-head-commit test-head
else
  echo "not ok - passing checks prerequisite for immediate merge"
  FAILED=1
fi
assert_eq "passing checks allow the immediate guarded merge" \
  "pr merge 42 --squash --match-head-commit test-head" "$(cat "$AUTO_MERGE_GH_LOG")"
rm -rf "$AUTO_MERGE_GH_BIN"

FIX_FORWARD_MAIN_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FIX_FORWARD_STALE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
FIX_FORWARD_RUN_JSON='{"id":990401,"status":"completed","conclusion":"failure","head_sha":"cccccccccccccccccccccccccccccccccccccccc"}'
FIX_FORWARD_JOBS_JSON='{"total_count":1,"jobs":[{"name":"Postsubmit validate","conclusion":"failure"}]}'
FIX_FORWARD_CHECKS_JSON='[{"name":"Required CI gates","bucket":"pass"},{"name":"Required contract gates","bucket":"pass"},{"name":"Enforce branch delivery policy","bucket":"pass"},{"name":"Touched packages PR gate","bucket":"pass"}]'
FIX_FORWARD_RESULT="$(main_fix_forward_assess "$FIX_FORWARD_RUN_JSON" "$FIX_FORWARD_JOBS_JSON" \
  "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_CHECKS_JSON" "")"
assert_eq "a covered main-red run with green checks on the current base admits the fix-forward merge" \
  "true" "$(jq -r '.eligible' <<< "$FIX_FORWARD_RESULT")"
assert_eq "fix-forward reason names red main job and its PR coverage" \
  "fix-forward: main red on Postsubmit validate; PR checks green on Touched packages PR gate, Required CI gates" \
  "$(jq -r '.reason' <<< "$FIX_FORWARD_RESULT")"
FIX_FORWARD_CARRIED_CHECKS='[{"name":"Required CI gates","bucket":"fail","link":"https://github.com/example-maintainer/example-repo/actions/runs/990410/job/990411"},{"name":"Required contract gates","bucket":"pass"},{"name":"Enforce branch delivery policy","bucket":"pass"},{"name":"Touched packages PR gate","bucket":"fail","link":"https://github.com/example-maintainer/example-repo/actions/runs/990410/job/990411"}]'
FIX_FORWARD_RESULT="$(main_fix_forward_assess "$FIX_FORWARD_RUN_JSON" "$FIX_FORWARD_JOBS_JSON" "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_CARRIED_CHECKS" "")"
assert_eq "a failed required PR check does not enter ordinary fix-forward" "false" "$(jq -r '.eligible' <<< "$FIX_FORWARD_RESULT")"
FIX_FORWARD_RESULT="$(main_fix_forward_assess "$FIX_FORWARD_RUN_JSON" "$FIX_FORWARD_JOBS_JSON" "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_CARRIED_CHECKS" "" 1 1)"
assert_eq "an explicitly verified carried capacity failure admits only Postsubmit fix-forward" "true" "$(jq -r '.eligible' <<< "$FIX_FORWARD_RESULT")"
assert_contains "carried exception keeps unrun source validation visible" "$(jq -r '.reason' <<< "$FIX_FORWARD_RESULT")" "source validation did not run"
FIX_FORWARD_UNCOVERED_JOBS="$(jq -c '.jobs[0].name = "Unmapped main job"' <<< "$FIX_FORWARD_JOBS_JSON")"
FIX_FORWARD_RESULT="$(main_fix_forward_assess "$FIX_FORWARD_RUN_JSON" "$FIX_FORWARD_UNCOVERED_JOBS" "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_CARRIED_CHECKS" "" 1 1)"
assert_eq "carried capacity exception refuses an unrelated failed main job" "false" "$(jq -r '.eligible' <<< "$FIX_FORWARD_RESULT")"

FIX_FORWARD_CAPACITY_CHECKS="$(jq -cn --arg repo "$REPO" '
  [
    {name:"Required CI gates",bucket:"fail",link:("https://github.com/"+$repo+"/actions/runs/990410/job/990412")},
    {name:"Required contract gates",bucket:"pass"},
    {name:"Enforce branch delivery policy",bucket:"pass"},
    {name:"NUL bytes & lone negative assertions",bucket:"pass"},
    {name:"Example pack PR gate",bucket:"pass"},
    {name:"Repo-path regression PR gate",bucket:"pass"},
    {name:"Touched packages PR gate",bucket:"fail",link:("https://github.com/"+$repo+"/actions/runs/990410/job/990411")}
  ]')"
FIX_FORWARD_CAPACITY_RUN="$(jq -cn --arg head "$FIX_FORWARD_MAIN_SHA" '{headSha:$head,status:"completed",conclusion:"failure",jobs:[{databaseId:990411,conclusion:"failure",steps:[{name:"Ensure CI runner has capacity before dependency install",conclusion:"failure"},{name:"Run touched package gates in Dagger",conclusion:"skipped"}]}]}')"
main_gh_saved="$(declare -f main_gh)"
main_gh() { printf '%s\n' "$FIX_FORWARD_CAPACITY_RUN"; }
assert_eq "carried capacity accepts only a failed Touched gate and its aggregate with every sibling green" \
  "true" "$(if main_fix_forward_carried_capacity_check "$FIX_FORWARD_CAPACITY_CHECKS" "$FIX_FORWARD_MAIN_SHA"; then echo true; else echo false; fi)"
FIX_FORWARD_CAPACITY_OTHER_RED="$(jq -c '. + [{name:"Repo-path regression PR gate",bucket:"fail"}]' <<< "$FIX_FORWARD_CAPACITY_CHECKS")"
assert_eq "carried capacity refuses a second red gate hidden by the aggregate failure" \
  "false" "$(if main_fix_forward_carried_capacity_check "$FIX_FORWARD_CAPACITY_OTHER_RED" "$FIX_FORWARD_MAIN_SHA"; then echo true; else echo false; fi)"
eval "$main_gh_saved"

FIX_FORWARD_RESULT="$(main_fix_forward_assess "$FIX_FORWARD_RUN_JSON" "$FIX_FORWARD_JOBS_JSON" \
  "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_STALE_SHA" "$FIX_FORWARD_CHECKS_JSON" "")"
assert_eq "a stale PR base refuses fix-forward" \
  "false" "$(jq -r '.eligible' <<< "$FIX_FORWARD_RESULT")"
FIX_FORWARD_UNCOVERED_JOBS="$(jq -c '.jobs[0].name = "Unmapped main job"' <<< "$FIX_FORWARD_JOBS_JSON")"
FIX_FORWARD_RESULT="$(main_fix_forward_assess "$FIX_FORWARD_RUN_JSON" "$FIX_FORWARD_UNCOVERED_JOBS" \
  "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_CHECKS_JSON" "")"
assert_eq "a red main job without a matching passing PR gate refuses fix-forward" \
  "false" "$(jq -r '.eligible' <<< "$FIX_FORWARD_RESULT")"
FIX_FORWARD_PENDING_RUN="$(jq -c '.status="in_progress" | .conclusion=null' <<< "$FIX_FORWARD_RUN_JSON")"
FIX_FORWARD_RESULT="$(main_fix_forward_assess "$FIX_FORWARD_PENDING_RUN" "$FIX_FORWARD_JOBS_JSON" \
  "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_CHECKS_JSON" "")"
assert_eq "a pending main run refuses fix-forward" \
  "false" "$(jq -r '.eligible' <<< "$FIX_FORWARD_RESULT")"
# The selector also owns quarantine's verdict and the historical PR cutoff.
FIX_FORWARD_HISTORY="$(jq -cn --argjson red "$FIX_FORWARD_RUN_JSON" \
  '{workflow_runs:[
    {id:990404,status:"queued",conclusion:null,created_at:"2026-10-12T03:00:00Z"},
    {id:990403,status:"in_progress",conclusion:null,created_at:"2026-10-12T02:00:00Z"},
    {id:990402,status:"completed",conclusion:"cancelled",created_at:"2026-10-12T01:00:00Z"},
    ($red + {created_at:"2026-10-12T00:00:00Z"})]}')"
FIX_FORWARD_VERDICT="$(ci_main_latest_completed_push_run "$FIX_FORWARD_HISTORY")"
FIX_FORWARD_RESULT="$(main_fix_forward_assess "$FIX_FORWARD_VERDICT" "$FIX_FORWARD_JOBS_JSON" \
  "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_CHECKS_JSON" "")"
assert_eq "pending and cancelled tips preserve the completed red fix-forward verdict" \
  "true" "$(jq -r '.eligible' <<< "$FIX_FORWARD_RESULT")"
assert_false "quarantine stays red while newer runs are pending" \
  ci_main_latest_completed_push_verdict "$FIX_FORWARD_HISTORY"
FIX_FORWARD_GREEN_HISTORY="$(jq -c '.workflow_runs[-1].conclusion="success"' <<< "$FIX_FORWARD_HISTORY")"
FIX_FORWARD_VERDICT="$(ci_main_latest_completed_push_run "$FIX_FORWARD_GREEN_HISTORY")"
FIX_FORWARD_RESULT="$(main_fix_forward_assess "$FIX_FORWARD_VERDICT" "$FIX_FORWARD_JOBS_JSON" \
  "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_CHECKS_JSON" "")"
assert_eq "pending and cancelled tips with a completed success refuse fix-forward" \
  "false" "$(jq -r '.eligible' <<< "$FIX_FORWARD_RESULT")"
assert_true "quarantine can lift on the completed success despite pending tips" \
  ci_main_latest_completed_push_verdict "$FIX_FORWARD_GREEN_HISTORY"
assert_eq "historical main verdict respects the PR creation cutoff" "990401" \
  "$(ci_main_latest_completed_push_run "$FIX_FORWARD_HISTORY" '2026-10-12T00:30:00Z' | jq -r '.id')"
assert_false "completed runs without a conclusion remain unknown" \
  ci_main_latest_completed_push_run '{"workflow_runs":[{"status":"completed","conclusion":null}]}'
assert_false "cancelled and skipped runs never supply a verdict" \
  ci_main_latest_completed_push_run '{"workflow_runs":[{"status":"completed","conclusion":"cancelled"},{"status":"completed","conclusion":"skipped"}]}'

main_fix_forward_reserve 990401 "$FIX_FORWARD_MAIN_SHA" 990402
assert_eq "fix-forward reservation records the consumed main run" "990401" \
  "$(main_fix_forward_reserved_run)"
FIX_FORWARD_RESULT="$(main_fix_forward_assess "$FIX_FORWARD_RUN_JSON" "$FIX_FORWARD_JOBS_JSON" \
  "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_MAIN_SHA" "$FIX_FORWARD_CHECKS_JSON" 990401)"
assert_eq "a second fix-forward cannot consume the same red main run" \
  "false" "$(jq -r '.eligible' <<< "$FIX_FORWARD_RESULT")"

if ! nested_suite_output="$(bash "$SCRIPT_DIR/main-release-ready-cache.test.sh" 2>&1)"; then
  printf '%s\n' "$nested_suite_output" >&2
  echo "not ok - main-release-ready-cache.test.sh failed" >&3
  FAILED=1
fi

# --- scrub_closing_keywords: shared PR title/body/merge-subject scrubber
assert_eq "bare #N form, capitalized keyword" \
  "Fixes issue 500" "$(scrub_closing_keywords <<< 'Fixes #500')"

assert_eq "lowercase keyword" \
  "closes issue 10" "$(scrub_closing_keywords <<< 'closes #10')"

assert_eq "uppercase keyword" \
  "RESOLVED issue 12" "$(scrub_closing_keywords <<< 'RESOLVED #12')"

assert_eq "colon separator with no space before the reference" \
  "Fixed issue 8" "$(scrub_closing_keywords <<< 'Fixed:#8')"

assert_eq "cross-repo owner/repo#N form" \
  "resolves issue 800" "$(scrub_closing_keywords <<< 'resolves octocat/Spoon-Knife#800')"

assert_eq "full github.com issue URL form" \
  "Closes issue 42" "$(scrub_closing_keywords <<< 'Closes https://github.com/foo/bar/issues/42')"

assert_eq "two closing references on one line, both scrubbed" \
  "This closed issue 3 and fixes issue 4 in one line" \
  "$(scrub_closing_keywords <<< 'This closed #3 and fixes #4 in one line')"

assert_eq "a word merely sharing a suffix with a keyword is left alone" \
  "prefix #10 should not match" "$(scrub_closing_keywords <<< 'prefix #10 should not match')"

assert_eq "a keyword not immediately adjacent to the reference is left alone (GitHub would not link it either)" \
  "Fix the bug described in #500" "$(scrub_closing_keywords <<< 'Fix the bug described in #500')"

assert_eq "a bare issue reference with no keyword is left alone" \
  "no keyword here #500" "$(scrub_closing_keywords <<< 'no keyword here #500')"

# PR merge body is untrusted markdown too. Keep it out of argv and prove the
# temporary file survives until gh consumes it.
PR_MERGE_BODY_BIN="$(mktemp -d)"
PR_MERGE_BODY_LOG="$(mktemp)"
PR_MERGE_BODY_HOME="$(mktemp -d)"
PR_MERGE_STATE_FILE="$PR_MERGE_BODY_HOME/merged"
PR_MERGE_RECONCILE_COUNT="$PR_MERGE_BODY_HOME/reconcile-count"
PR_MERGE_REPO="$PR_MERGE_BODY_HOME/repo"
mkdir -p "$PR_MERGE_REPO/.zenoforge/state"
printf '{"incidents":[]}\n' > "$PR_MERGE_REPO/.zenoforge/state/incident-guards.json"
git -C "$PR_MERGE_REPO" init -q -b main
git -C "$PR_MERGE_REPO" config user.name 'Merge lane test'
git -C "$PR_MERGE_REPO" config user.email merge-lane@example.invalid
git -C "$PR_MERGE_REPO" add .zenoforge/state/incident-guards.json
git -C "$PR_MERGE_REPO" commit -qm 'fixture incident registry'
REAL_BASH="$(command -v bash)"
PR_MERGE_HEAD_SHA=0123456789abcdef0123456789abcdef01234567
PR_MERGE_COMMIT_SHA=1234567890abcdef1234567890abcdef12345678
cat > "$PR_MERGE_BODY_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  if [[ " $* " == *' --json state,headRefOid,mergeCommit '* ]]; then
    if [ -f "$PR_MERGE_STATE_FILE" ]; then
      printf 'MERGED\t%s\t%s\n' "$PR_MERGE_HEAD_SHA" "$PR_MERGE_COMMIT_SHA"
    else
      printf 'OPEN\t%s\t\n' "$PR_MERGE_HEAD_SHA"
    fi
  elif [[ " $* " == *' --json headRefName,headRefOid,files,state,mergeCommit '* ]]; then
    if [ -f "$PR_MERGE_STATE_FILE" ]; then state=MERGED; merge="$PR_MERGE_COMMIT_SHA"; else state=OPEN; merge=""; fi
    if [[ "$*" == *'.zenoforge/state/incident-guards.json'* ]]; then touches=true; else touches=false; fi
    printf 'guard-path=%s\n' "$touches" >> "$PR_MERGE_BODY_LOG"
    printf 'agent/issue-42\t%s\t%s\t%s\t%s\n' "$PR_MERGE_HEAD_SHA" "$touches" "$state" "$merge"
  else
    echo "unexpected fake gh view: $*" >&2
    exit 2
  fi
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = merge ]; then
  printf 'gh-pr-merge\n' >> "$PR_MERGE_BODY_LOG"
  touch "$PR_MERGE_STATE_FILE"
fi
args=("$@")
for i in "${!args[@]}"; do
  [ "${args[$i]}" = "--body-file" ] || continue
  printf 'args=%s\n' "$*" >> "$PR_MERGE_BODY_LOG"
  printf 'body=%s\n' "$(cat "${args[$((i + 1))]}")" >> "$PR_MERGE_BODY_LOG"
  exit 0
done
exit 1
FAKE_GH
chmod +x "$PR_MERGE_BODY_BIN/gh"
cat > "$PR_MERGE_BODY_BIN/bash" <<EOF
#!$REAL_BASH
if [[ "\${1##*/}" == land-direct-main.sh && "\${2:-}" == --reconcile-pr ]]; then
  printf 'reconcile pr=%s\n' "\${3:-}" >> "$PR_MERGE_BODY_LOG"
  count=0
  [[ ! -r "\$PR_MERGE_RECONCILE_COUNT" ]] || count="\$(cat "\$PR_MERGE_RECONCILE_COUNT")"
  count=\$((count + 1))
  printf '%s\n' "\$count" > "\$PR_MERGE_RECONCILE_COUNT"
  [[ "\$count" != 1 ]] || exit 23
  exit 0
fi
exec "$REAL_BASH" "\$@"
EOF
chmod +x "$PR_MERGE_BODY_BIN/bash"
PR_MERGE_RESULT="$(PATH="$PR_MERGE_BODY_BIN:$PATH" PR_MERGE_BODY_LOG="$PR_MERGE_BODY_LOG" \
  AGENT_HOME="$PR_MERGE_BODY_HOME" AGENT_DRY_RUN=0 REPO="test/repo" \
  ZF_REPO_DIR="$PR_MERGE_REPO" ZF_CONFIG_ROOT="$PR_MERGE_REPO/.zenoforge" \
  ZF_ENGINE_DIR="$SCRIPT_DIR" ZF_PACK_DIR='' \
  PR_MERGE_HEAD_SHA="$PR_MERGE_HEAD_SHA" PR_MERGE_COMMIT_SHA="$PR_MERGE_COMMIT_SHA" \
  PR_MERGE_STATE_FILE="$PR_MERGE_STATE_FILE" PR_MERGE_RECONCILE_COUNT="$PR_MERGE_RECONCILE_COUNT" bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    if guarded_pr_merge 42 "safe title" "body from file" "$PR_MERGE_HEAD_SHA"; then first=0; else first=$?; fi
    if guarded_pr_merge 42 "safe title" "body from file" "$PR_MERGE_HEAD_SHA"; then second=0; else second=$?; fi
    printf "statuses=%s,%s\n" "$first" "$second"
  ' bash "$SCRIPT_DIR" 2>&1)"
PR_MERGE_BODY_CONTENT="$(cat "$PR_MERGE_BODY_LOG")"
PR_MERGE_MANIFEST="$(cat "$PR_MERGE_BODY_HOME/night/worktree-cleanup-manifest.txt")"
rm -rf "$PR_MERGE_BODY_BIN" "$PR_MERGE_BODY_HOME"
rm -f "$PR_MERGE_BODY_LOG"
assert_contains "guarded_pr_merge passes a body file" "$PR_MERGE_BODY_CONTENT" "--body-file"
assert_not_contains "guarded_pr_merge never passes literal --body" "$PR_MERGE_BODY_CONTENT" "--body body"
assert_contains "guarded_pr_merge preserves body text through the file" "$PR_MERGE_BODY_CONTENT" "body=body from file"
assert_eq "guarded_pr_merge detects the target config incident registry" 2 \
  "$(grep -c '^guard-path=true$' <<< "$PR_MERGE_BODY_CONTENT")"
assert_contains "post-merge failure is retryable" "$PR_MERGE_RESULT" 'statuses=23,0'
assert_contains "already-merged retry skips gh pr merge" "$PR_MERGE_RESULT" 'already merged as 1234567890abcdef1234567890abcdef12345678; merge skipped'
assert_eq "the merged PR is never merged twice" 1 "$(grep -c '^gh-pr-merge$' <<< "$PR_MERGE_BODY_CONTENT")"
assert_eq "only reconciliation is retried" 2 "$(grep -c '^reconcile pr=42$' <<< "$PR_MERGE_BODY_CONTENT")"
assert_contains "shared merge path records the PR head before deleting it" "$PR_MERGE_MANIFEST" $'merging-pr-head\tagent/issue-42\t'"$PR_MERGE_HEAD_SHA"
assert_contains "shared merge path records completed PR head deletion" "$PR_MERGE_MANIFEST" $'merged-pr-head\tagent/issue-42\t'"$PR_MERGE_HEAD_SHA"
assert_contains "failed reconciliation persists exact merge SHA" "$PR_MERGE_MANIFEST" $'pending-pr-reconciliation\tpr-42\t'"$PR_MERGE_COMMIT_SHA"
assert_contains "successful retry records reconciled merge SHA" "$PR_MERGE_MANIFEST" $'completed-pr-reconciliation\tpr-42\t'"$PR_MERGE_COMMIT_SHA"

# --- scrub_git_object_ids: CLAUDE.md hash ban / defect 8's brief scrubber --
# Pattern and marker per lib.sh's own comment; see there for the corpus
# measurement (real ~/.zenoforge/state/*.json briefs) behind each
# exclusion below.
assert_eq "a real short Git object id is scrubbed" \
  "commit [object-id-redacted] is the baseline" \
  "$(scrub_git_object_ids <<< 'commit 1845a5f1b is the baseline')"

assert_eq "a full 40-character object id is scrubbed" \
  "commit [object-id-redacted] is the baseline" \
  "$(scrub_git_object_ids <<< 'commit 367bb04770e30c28a80366e08f523a189c57c2e8 is the baseline')"

assert_eq "a prefixed id (t-XXXXXXXX) survives untouched" \
  "id t-73ff7fa9 flagged" \
  "$(scrub_git_object_ids <<< 'id t-73ff7fa9 flagged')"

assert_eq "a schema column name (source_image_sha256) survives untouched" \
  "SELECT source_image_sha256 FROM t" \
  "$(scrub_git_object_ids <<< 'SELECT source_image_sha256 FROM t')"

assert_eq "a second schema column name (preview_hash) survives untouched" \
  "preview_hash is NULL" \
  "$(scrub_git_object_ids <<< 'preview_hash is NULL')"

assert_eq "a bare-digit date is not mistaken for a hash" \
  "lot dated 20260811 across suppliers" \
  "$(scrub_git_object_ids <<< 'lot dated 20260811 across suppliers')"

assert_eq "a full UUID business/event id survives untouched" \
  "event 016bf172-d3c4-4e52-9ac8-fea48c97a594 recorded" \
  "$(scrub_git_object_ids <<< 'event 016bf172-d3c4-4e52-9ac8-fea48c97a594 recorded')"

assert_eq "text with no match is returned byte-identical" \
  "no hashes here, just prose" \
  "$(scrub_git_object_ids <<< 'no hashes here, just prose')"

# --- build_report_body (notify.sh): the manager-readable email template ---
# Pure function, no gh call and no network. Assert the shape a human cares
# about (issue number + plain-language sections present), and that untrusted
# title/reporter text is inserted as plain text, not interpreted.
REPORT_BODY_BASIC="$(build_report_body 1098 "部门名称对照表漏了三个旧名称" "example-maintainer" \
  "给部门名称对照表补了三个漏掉的旧名称。" \
  "以后这三个旧名称也能正确匹配到部门了。" \
  "不用，已经处理完了。")"

assert_true "the body carries the issue number" \
  bash -c 'echo "$1" | grep -q "#1098"' _ "$REPORT_BODY_BASIC"

assert_true "the body carries the plain-language summary" \
  bash -c 'echo "$1" | grep -q "给部门名称对照表补了三个漏掉的旧名称"' _ "$REPORT_BODY_BASIC"

assert_true "the body carries the reporter login" \
  bash -c 'echo "$1" | grep -q "example-maintainer"' _ "$REPORT_BODY_BASIC"

assert_true "the body carries the user-impact section" \
  bash -c 'echo "$1" | grep -q "以后这三个旧名称也能正确匹配到部门了"' _ "$REPORT_BODY_BASIC"

assert_true "the body carries the action-needed section" \
  bash -c 'echo "$1" | grep -q "不用，已经处理完了"' _ "$REPORT_BODY_BASIC"

# A title containing a GitHub closing-keyword-shaped string (the caller's job
# to scrub before calling this, same as every other title-display surface)
# is inserted as plain text here, not specially interpreted -- this function
# does no `eval` and builds no command string out of any argument.
REPORT_BODY_INJECTION="$(build_report_body 42 'Fixes issue 500 (already scrubbed)' 'weird-login```$(whoami)' \
  "什么都没做。" "没有影响。" "不用。")"
assert_true "untrusted title/reporter text passes through as literal plain text" \
  bash -c 'echo "$1" | grep -qF "weird-login\`\`\`\$(whoami)"' _ "$REPORT_BODY_INJECTION"

# --- email call-site boundaries --------------------------------------------
# Operational state remains on the issue/HEALTH. The release incident path
# uses the shared founder-mail ledger; decisions and outcomes use their routes.

# A no-single-container service is fleet-roll pending, not an incident.




# Preserve the targeted early-exit mode while model-policy cases run separately.
if [[ "${LIB_TEST_MODEL_POLICY_ONLY:-0}" == 1 ]]; then
  bash "$SCRIPT_DIR/lib-model-policy.test.sh" || FAILED=1
  lib_case_exit
fi

# --- give_up_on_issue's attempt threshold ---------------------------------
# Defect 2, 2026-09-14 (#1179): fail_attempt()'s give-up threshold moved
# from 3 to 4; every attempt resolves through the configured role policy.
# 2026-09-15 fix (#1221, live): this was the one give_up_on_issue() call
# site left behind when every other terminal in run-implement.sh moved to
# conclude_run() -- #1221 reached attempt 4 for real and got stuck on
# needs-owner with conclude_run never called. Assert the old CALL is fully
# gone (a bare string match would also flag this file's own comments
# explaining the fix, which is not what this checks) and the new terminal
# is conclude_run(), without claiming a model switch.
# conclude_run "$N" not-completed "$NEEDS_MD" is now a 5-way shared shape
# (every 4-attempt-cap terminal in this file uses it, this one included) --
# assert on fail_attempt()'s own honest-capability text instead, which is
# unique to this call site.
# issue-pipeline.sh's own belt-and-suspenders give-up (a dispatched unit
# killed mid-attempt) moved to the same threshold, but deliberately does NOT
# pass the stronger-model flag -- see that script's own comment for why.

# --- Defect 6, 2026-09-13 (#1094): the needs-info ask/read email loop ------
# Roster fixture reused across every test below in this section -- same
# shape as ROSTER_TEST_FILE above, kept separate (a distinct file, not a
# reused variable name) so nothing here depends on execution order against
# the resolve_recipients block above ever tearing its own fixture down.
EMAIL_LOOP_ROSTER="$(mktemp)"
cat > "$EMAIL_LOOP_ROSTER" <<'JSON'
{
  "founder_login": "the-maintainer",
  "recipients": {
    "known-reporter": "Reporter@Example.com",
    "the-maintainer": "maintainer@example.com"
  }
}
JSON

# trim_quoted_reply (lib.sh): cut a reply at the first quoted-original-message
# line, in either language this pipeline's replies show up in.
assert_eq "a plain reply with no quoted text passes through unchanged" \
  "好的，都同意。" \
  "$(trim_quoted_reply "好的，都同意。")"

assert_eq "a '>' quoted continuation line is cut" \
  "好的，都同意。" \
  "$(trim_quoted_reply "好的，都同意。
> 原始问题在这里
> 第二行")"

assert_eq "an 'On ... wrote:' quote header is cut" \
  "Sounds good, go with the defaults." \
  "$(trim_quoted_reply "Sounds good, go with the defaults.

On Sat, Sep 13, 2026 at 9:00 AM the product Agent wrote:
> original question")"

assert_eq "a Chinese '...写道：' quote header is cut" \
  "都可以，按默认来就行" \
  "$(trim_quoted_reply "都可以，按默认来就行

在 2026年9月13日 星期日 the product Agent 写道：
> 原始问题")"

# resolve_login_for_email (notify.sh): the read side's reverse roster
# lookup, case-insensitive (a real reply's From header capitalization is
# not something this pipeline controls).
assert_eq "a roster address (any case) resolves back to its GitHub login" \
  "known-reporter" \
  "$(resolve_login_for_email "reporter@example.com" "$EMAIL_LOOP_ROSTER")"

assert_eq "the roster's own stored capitalization still resolves the same way" \
  "known-reporter" \
  "$(resolve_login_for_email "REPORTER@EXAMPLE.COM" "$EMAIL_LOOP_ROSTER")"

assert_eq "an address with no roster entry (e.g. a mailer-daemon bounce) resolves to nothing" \
  "" \
  "$(resolve_login_for_email "mailer-daemon@googlemail.com" "$EMAIL_LOOP_ROSTER")"

# _reporter_email_only (notify.sh): notify_reporter_question()'s "roster
# only, never fall back to the maintainer" lookup, extracted so that guarantee
# is testable directly rather than only inferable from control flow.
assert_eq "a roster'd reporter login resolves to their own address" \
  "Reporter@Example.com" \
  "$(_reporter_email_only "known-reporter" "$EMAIL_LOOP_ROSTER")"

assert_eq "an unmapped reporter login resolves to NOTHING -- not the maintainer's address" \
  "" \
  "$(_reporter_email_only "someone-unmapped" "$EMAIL_LOOP_ROSTER")"

# gmail_message_is_human_reply (notify.sh) -- the three filters from the
# brief, each checked in isolation. The roster-membership one is the most
# important: "a reply from outside the roster is refused."
assert_true "a message from a roster address, no marker, no Auto-Submitted, is a human reply" \
  gmail_message_is_human_reply "reporter@example.com" "" "" "$EMAIL_LOOP_ROSTER"

assert_false "a message from an address with NO roster entry is refused, whatever else it looks like" \
  gmail_message_is_human_reply "stranger@example.com" "" "" "$EMAIL_LOOP_ROSTER"

assert_false "a mailer-daemon bounce (never a roster address) is refused the same way, confirming the roster check alone already excludes it" \
  gmail_message_is_human_reply "mailer-daemon@googlemail.com" "" "" "$EMAIL_LOOP_ROSTER"

assert_false "our own outgoing mail (carries the X-Zenoforge-Agent-Issue marker) is never treated as a reply, even from a roster address" \
  gmail_message_is_human_reply "reporter@example.com" "" "1094" "$EMAIL_LOOP_ROSTER"

assert_false "the maintainer's own address with the marker present is still refused -- marker wins over address" \
  gmail_message_is_human_reply "maintainer@example.com" "" "1094" "$EMAIL_LOOP_ROSTER"

assert_true "the maintainer's own GENUINE reply (roster address, no marker) counts as human -- not filtered by identity alone" \
  gmail_message_is_human_reply "maintainer@example.com" "" "" "$EMAIL_LOOP_ROSTER"

assert_false "an Auto-Submitted: auto-replied vacation responder from a roster address is refused" \
  gmail_message_is_human_reply "reporter@example.com" "auto-replied" "" "$EMAIL_LOOP_ROSTER"

assert_true "Auto-Submitted: no (some MTAs stamp this on ordinary mail) is NOT treated as automated" \
  gmail_message_is_human_reply "reporter@example.com" "no" "" "$EMAIL_LOOP_ROSTER"

rm -f "$EMAIL_LOOP_ROSTER"

# gmail_message_id_processed (notify.sh): the dedup check --
# "the same reply is never posted twice."
assert_true "a message id already in the processed array is recognized as processed" \
  gmail_message_id_processed "msg-1" '["msg-0","msg-1"]'

assert_false "a message id not yet in the processed array is not yet processed" \
  gmail_message_id_processed "msg-2" '["msg-0","msg-1"]'

assert_false "an empty processed array means nothing has been processed yet" \
  gmail_message_id_processed "msg-1" '[]'

# read_needs_info_email_replies (issue-pipeline.sh): the hard boundary --
# "an inbound message cannot change a label." Extracts the function's own
# body (from its `funcname() {` line to the matching top-level `}`) and
# asserts it contains none of the label/merge-mutating verbs every OTHER
# gh-writing block in this file uses. This fails the moment a future edit
# adds one of those calls inside this function, which is the point: the
# needs-info reply/default handlers consume the relayed comment and own the
# stage transition; the read side stays comment-only on GitHub.
READ_SIDE_FN_BODY="$(sed -n '/^read_needs_info_email_replies() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"

assert_true "read_needs_info_email_replies() is actually found in issue-pipeline.sh (fixture sanity check)" \
  bash -c '[ -n "$1" ]' _ "$READ_SIDE_FN_BODY"

assert_false "read_needs_info_email_replies() never adds a label" \
  bash -c 'echo "$1" | grep -qF -- "--add-label"' _ "$READ_SIDE_FN_BODY"

assert_false "read_needs_info_email_replies() never removes a label" \
  bash -c 'echo "$1" | grep -qF -- "--remove-label"' _ "$READ_SIDE_FN_BODY"

assert_false "read_needs_info_email_replies() never calls gh issue edit" \
  bash -c 'echo "$1" | grep -qF -- "gh issue edit"' _ "$READ_SIDE_FN_BODY"

assert_false "read_needs_info_email_replies() never calls gh pr merge" \
  bash -c 'echo "$1" | grep -qF -- "gh pr merge"' _ "$READ_SIDE_FN_BODY"

assert_true "read_needs_info_email_replies() posts through gh issue comment (its one allowed mutating verb)" \
  bash -c 'echo "$1" | grep -qF -- "gh issue comment"' _ "$READ_SIDE_FN_BODY"

assert_true "read_needs_info_email_replies() applies the dedup check before ever posting" \
  bash -c 'echo "$1" | grep -qF -- "gmail_message_id_processed"' _ "$READ_SIDE_FN_BODY"

assert_true "read_needs_info_email_replies() keeps applied-default threads eligible for late replies" \
  bash -c 'echo "$1" | grep -qF -- "needs_info_default_applied.thread_id"' _ "$READ_SIDE_FN_BODY"

POST_DISPATCH_MAINTENANCE_BODY="$(sed -n '/^run_post_dispatch_maintenance() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
MAINTENANCE_OPTIONAL_STEP_BODY="$(sed -n '/^maintenance_run_optional_step() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
NEEDS_INFO_RECONCILE_BODY="$(sed -n '/^reconcile_needs_info_issues() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
# #193 gave maintenance bounded slots with a resume cursor: the needs-info
# email poll stayed inline required work, while reply reconciliation moved to
# the optional suffix as the needs-info-loop step dispatched through
# maintenance_run_optional_step. The ordering contract now pins as: the inline
# email read precedes the suffix dispatch loop, and needs-info-loop still
# routes to reconcile_needs_info_issues.
assert_true "post-dispatch maintenance reads needs-info mail before reply reconciliation" \
  bash -c '
    read_side_line=$(grep -nF "read_needs_info_email_replies" <<< "$1" | head -n1 | cut -d: -f1)
    suffix_dispatch_line=$(grep -nF "maintenance_run_optional_step" <<< "$1" | tail -n1 | cut -d: -f1)
    [ -n "$read_side_line" ] && [ -n "$suffix_dispatch_line" ] && [ "$read_side_line" -lt "$suffix_dispatch_line" ]
  ' _ "$POST_DISPATCH_MAINTENANCE_BODY"
assert_true "the needs-info-loop suffix step still routes to reply reconciliation" \
  bash -c '
    step_line=$(grep -nF "needs-info-loop)" <<< "$1" | head -n1 | cut -d: -f1)
    reconcile_line=$(grep -nF "reconcile_needs_info_issues" <<< "$1" | head -n1 | cut -d: -f1)
    [ -n "$step_line" ] && [ -n "$reconcile_line" ] && [ "$step_line" -lt "$reconcile_line" ]
  ' _ "$MAINTENANCE_OPTIONAL_STEP_BODY"

# 2026-09-15 (restored maintainer verdict): needs-info reconciliation must route an
# advisor-origin needs-info answer back to needs-advisor (route_to_advisor,
# which also clears the stale advisor_ruled_at), never to needs-triage --
# that restart is only correct for the reporter/triage-origin case.
RESUME_ANSWERED_BODY="$(sed -n '/^needs_info_resume_answered_issue() {/,/^}/p' "$SCRIPT_DIR/lib.d/route-advisor.sh")"
TIMEOUT_STEP_BODY="$(sed -n '/^needs_info_timeout_step() {/,/^}/p' "$SCRIPT_DIR/lib.d/route-advisor.sh")"
assert_true "needs-info reconciliation and timeout share existing reply transition" \
  bash -c 'echo "$1" | grep -qF -- "needs_info_resume_answered_issue" && echo "$2" | grep -qF -- "needs_info_resume_answered_issue"' _ "$NEEDS_INFO_RECONCILE_BODY" "$TIMEOUT_STEP_BODY"
assert_true "shared reply transition branches on needs_info_origin" \
  bash -c 'echo "$1" | grep -qF -- "needs_info_origin"' _ "$RESUME_ANSWERED_BODY"
assert_true "shared advisor-origin reply transition calls route_to_advisor" \
  bash -c 'echo "$1" | grep -qF -- "route_to_advisor \"\$n\" needs-info"' _ "$RESUME_ANSWERED_BODY"
assert_true "shared ordinary reply transition moves needs-info state and label to needs-triage" \
  bash -c 'echo "$1" | grep -qF -- "issue_transition \"\$n\" needs-triage needs-info-answered"' _ "$RESUME_ANSWERED_BODY"

# A needs-info question with a stated default expires after the shared bound;
# the reply path applies that default once, while an unanswered open choice
# goes through the existing advisor route.
NEEDS_INFO_TIMEOUT_TEST_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$NEEDS_INFO_TIMEOUT_TEST_HOME/model-policy.json"
mkdir -p "$NEEDS_INFO_TIMEOUT_TEST_HOME/state"
NEEDS_INFO_TIMEOUT_TEST_WRITES="$(mktemp)"
NEEDS_INFO_TIMEOUT_ORIGINAL_ROUTE="$(declare -f route_to_advisor)"
NEEDS_INFO_TIMEOUT_ORIGINAL_WRITE="$(declare -f guarded_write)"
AGENT_HOME="$NEEDS_INFO_TIMEOUT_TEST_HOME"
STATE_DIR="$AGENT_HOME/state"
NEEDS_INFO_QUESTION_TIMEOUT_SECONDS=259200
NEEDS_INFO_TIMEOUT_TEST_NOW="$(date +%s)"

assert_eq 'question scanner captures a stated recommendation' '建议：A' \
  "$(needs_info_default_option $'问题：选哪项？\n建议：A\n请回复“A”')"
assert_eq 'question scanner captures an explicit unchanged-items default' '未修改的项目按默认处理' \
  "$(needs_info_default_option $'字段变更如下：\n未修改的项目按默认处理')"
assert_eq 'question scanner ignores generic email footer as a stated default' '' \
  "$(needs_info_default_option $'问题：选哪项？\n> 如果都同意上面写的默认处理方式，直接回复这封邮件说一声「好」就行')"

GMAIL_DATE_RAW="$(printf 'From: Agent <agent@example.com>\nDate: Tue, 29 Sep 2026 10:00:00 +0000\nContent-Type: text/plain; charset=utf-8\n\n建议：A\n' \
  | python3 -c 'import base64,sys; print(base64.urlsafe_b64encode(sys.stdin.buffer.read()).decode().rstrip("="))')"
GMAIL_DATE_PARSED="$(parse_gmail_message_raw "$GMAIL_DATE_RAW")"
assert_eq 'RFC822 Date fallback parses the Gmail first-message date' \
  "$(date -u -d '2026-09-29 10:00:00' +%s)" \
  "$(jq -r '.date_epoch' <<< "$GMAIL_DATE_PARSED")"

gh() {
  printf '%s\n' "$*" >> "$NEEDS_INFO_TIMEOUT_TEST_WRITES"
}

route_to_advisor() {
  local n="$1" remove_label="${2:-needs-info}"
  state_merge "$n" '.state = "needs-advisor"'
  guarded_write gh issue edit "$n" --repo "$REPO" --remove-label "$remove_label" --add-label needs-advisor
}

guarded_write() {
  printf '%s\n' "$*" >> "$NEEDS_INFO_TIMEOUT_TEST_WRITES"
}

write_needs_info_timeout_state() {
  local n="$1" sent_at="$2" option="$3" origin="${4:-triage}"
  jq -n --arg thread "thread-$n" --arg option "$option" --arg origin "$origin" \
    --argjson sent_at "$sent_at" \
    '{state:"needs-info",needs_info_thread_id:$thread,needs_info_origin:$origin,
      needs_info_question_thread_id:$thread,needs_info_question_sent_at:$sent_at,
      needs_info_default_option:(if $option == "" then null else $option end)}' \
    > "$STATE_DIR/$n.json"
}

needs_info_timeout_issue_json() {
  jq -cn --argjson n "$1" --arg want_label "${2:-needs-info}" \
    '{number:$n,labels:[{name:$want_label}],comments:[]}'
}

write_needs_info_timeout_state 950001 "$((NEEDS_INFO_TIMEOUT_TEST_NOW - NEEDS_INFO_QUESTION_TIMEOUT_SECONDS - 10))" '建议：A'
NEEDS_INFO_TIMEOUT_ISSUE="$(needs_info_timeout_issue_json 950001)"
NEEDS_INFO_TIMEOUT_ACTION=""
needs_info_timeout_step 950001 "$NEEDS_INFO_TIMEOUT_ISSUE" "$NEEDS_INFO_TIMEOUT_TEST_NOW" || true
assert_eq 'a stale question with a stated default applies it once' default-applied "$NEEDS_INFO_TIMEOUT_ACTION"
assert_eq 'default application records the quoted option in state' '建议：A' \
  "$(jq -r '.needs_info_default_applied.option // empty' "$STATE_DIR/950001.json")"
assert_eq 'default application reuses needs-triage reply transition' needs-triage \
  "$(jq -r '.state' "$STATE_DIR/950001.json")"
assert_true 'default comment explains unanswered days and later correction' \
  bash -c 'grep -qF "仍未收到回复" "$1" && grep -qF "之后如果你回复" "$1"' _ "$NEEDS_INFO_TIMEOUT_TEST_WRITES"
assert_eq 'default application posts one issue comment' 1 \
  "$(grep -cF 'issue comment 950001' "$NEEDS_INFO_TIMEOUT_TEST_WRITES")"

: > "$NEEDS_INFO_TIMEOUT_TEST_WRITES"
NEEDS_INFO_TIMEOUT_ACTION=""
needs_info_timeout_step 950001 "$(needs_info_timeout_issue_json 950001 needs-triage)" "$NEEDS_INFO_TIMEOUT_TEST_NOW" || true
assert_eq 'a second tick leaves an already-transitioned issue alone' unchanged "$NEEDS_INFO_TIMEOUT_ACTION"
assert_eq 'a second tick does not repeat the comment or transition' 0 \
  "$(wc -l < "$NEEDS_INFO_TIMEOUT_TEST_WRITES" | tr -d '[:space:]')"

write_needs_info_timeout_state 950002 "$((NEEDS_INFO_TIMEOUT_TEST_NOW - NEEDS_INFO_QUESTION_TIMEOUT_SECONDS - 10))" ''
: > "$NEEDS_INFO_TIMEOUT_TEST_WRITES"
NEEDS_INFO_TIMEOUT_ACTION=""
needs_info_timeout_step 950002 "$(needs_info_timeout_issue_json 950002)" "$NEEDS_INFO_TIMEOUT_TEST_NOW" || true
assert_eq 'a stale question without a default goes to the advisor' advisor-routed "$NEEDS_INFO_TIMEOUT_ACTION"
assert_eq 'advisor routing updates stage state' needs-advisor "$(jq -r '.state' "$STATE_DIR/950002.json")"
assert_true 'advisor routing moves needs-info label' \
  grep -qF -- '--remove-label needs-info --add-label needs-advisor' "$NEEDS_INFO_TIMEOUT_TEST_WRITES"
assert_false 'advisor routing sends no second email or comment' \
  grep -qF 'issue comment 950002' "$NEEDS_INFO_TIMEOUT_TEST_WRITES"

write_needs_info_timeout_state 950003 "$((NEEDS_INFO_TIMEOUT_TEST_NOW - 3600))" '建议：B'
: > "$NEEDS_INFO_TIMEOUT_TEST_WRITES"
NEEDS_INFO_TIMEOUT_ACTION=""
needs_info_timeout_step 950003 "$(needs_info_timeout_issue_json 950003)" "$NEEDS_INFO_TIMEOUT_TEST_NOW" || true
assert_eq 'a fresh question is left alone' unchanged "$NEEDS_INFO_TIMEOUT_ACTION"
assert_eq 'fresh question state stays needs-info' needs-info "$(jq -r '.state' "$STATE_DIR/950003.json")"
assert_eq 'fresh question causes no writes' 0 \
  "$(wc -l < "$NEEDS_INFO_TIMEOUT_TEST_WRITES" | tr -d '[:space:]')"

unset -f route_to_advisor guarded_write gh needs_info_timeout_issue_json write_needs_info_timeout_state
eval "$NEEDS_INFO_TIMEOUT_ORIGINAL_ROUTE"
eval "$NEEDS_INFO_TIMEOUT_ORIGINAL_WRITE"
AGENT_HOME="$LIB_TEST_AGENT_HOME"
STATE_DIR="$AGENT_HOME/state"
rm -rf -- "$NEEDS_INFO_TIMEOUT_TEST_HOME" "$NEEDS_INFO_TIMEOUT_TEST_WRITES"

# send_email()'s X-Zenoforge-Agent-Issue marker -- the mechanism the read side
# above depends on to tell "our own outgoing mail" apart from a genuine
# reply (both share the identical From address; see notify.sh).


# --- markdown_to_html_email / build_gmail_raw_message (notify.sh): the
# 2026-09-14 legibility fix -- maintainer: [...]
# . Both are pure functions, no gh call
# and no network (no gcloud, no curl) -- send_email() itself stays untested
# per its own comment; these are the message-building pieces it was split
# into specifically so they could be tested without touching the real
# credential or the real inbox.
ESCAPE_OUT="$(markdown_to_html_email 'Use <script>alert(1)</script> & "quotes" here')"
assert_not_contains "a raw <script> tag from the source is never emitted" \
  "$ESCAPE_OUT" "<script>alert(1)</script>"
assert_contains "the escaped form appears instead" "$ESCAPE_OUT" "&lt;script&gt;"
assert_contains "an ampersand in the source is escaped" "$ESCAPE_OUT" "&amp;"

BULLET_OUT="$(markdown_to_html_email '- first item
- second item')"
assert_contains "a markdown bullet list becomes a real <ul>" "$BULLET_OUT" "<ul"
assert_contains "each bullet becomes a real <li>" "$BULLET_OUT" "<li"
assert_contains "the first item's text survives" "$BULLET_OUT" "first item"
assert_contains "the second item's text survives" "$BULLET_OUT" "second item"

NUMBERED_OUT="$(markdown_to_html_email '1. step one
2. step two')"
assert_contains "a numbered list becomes a real <ol>" "$NUMBERED_OUT" "<ol"
assert_contains "a numbered item's text survives" "$NUMBERED_OUT" "step one"

CHECKBOX_OUT="$(markdown_to_html_email '- [ ] unchecked task
- [x] done task')"
assert_contains "an unchecked box renders as a real checkbox glyph" "$CHECKBOX_OUT" "☐"
assert_contains "a checked box renders as a real checkbox glyph" "$CHECKBOX_OUT" "☑"

BOLD_CODE_OUT="$(markdown_to_html_email 'This is **important** and here is `inline_code()`.')"
assert_contains "bold markdown becomes a real <strong> element" "$BOLD_CODE_OUT" "<strong>important</strong>"
assert_contains "inline code becomes a real <code> element" "$BOLD_CODE_OUT" "<code"
assert_contains "the inline code text survives" "$BOLD_CODE_OUT" "inline_code()"
assert_not_contains "the literal ** marker does not survive" "$BOLD_CODE_OUT" "**important**"

PARA_OUT="$(markdown_to_html_email 'Just a plain sentence with no markdown at all.')"
assert_contains "a plain paragraph survives, wrapped in a real <p>" "$PARA_OUT" "<p"
assert_contains "the plain paragraph's text survives" \
  "$PARA_OUT" "Just a plain sentence with no markdown at all."

HEADING_OUT="$(markdown_to_html_email '## Triage Notes
some body text')"
assert_not_contains "the literal ## marker does not survive into the output" \
  "$HEADING_OUT" "## Triage Notes"
assert_contains "the heading text survives" "$HEADING_OUT" "Triage Notes"

QUOTE_OUT="$(markdown_to_html_email '> 如果都同意，直接回复「好」')"
assert_contains "a blockquote line renders as a visually distinct callout (the \"what I need from you\" box)" \
  "$QUOTE_OUT" "border-left"
assert_contains "the blockquote's text survives" "$QUOTE_OUT" "如果都同意，直接回复「好」"

# build_gmail_raw_message: same message-building code path send_email() now
# calls, but reachable directly with zero network/credential risk.
MIME_TEST_BODY="Hello **world**
- one
- two"
RAW_MSG="$(build_gmail_raw_message "someone@example.com" "Test 主题" "$MIME_TEST_BODY" "1146")"

assert_true "build_gmail_raw_message produces a non-empty encoded message" \
  bash -c 'test -n "$1"' _ "$RAW_MSG"

mime_get_part() {
  # $1 = raw base64url message, $2 = 'plain' or 'html' -> that part's content
  python3 -c '
import base64, sys
from email import policy
from email.parser import BytesParser
raw, kind = sys.argv[1], sys.argv[2]
pad = "=" * (-len(raw) % 4)
msg = BytesParser(policy=policy.default).parsebytes(base64.urlsafe_b64decode(raw + pad))
part = msg.get_body(preferencelist=(kind,))
sys.stdout.write(part.get_content() if part is not None else "")
' "$1" "$2"
}

mime_get_header() {
  # $1 = raw base64url message, $2 = header name -> that header's value
  python3 -c '
import base64, sys
from email import policy
from email.parser import BytesParser
raw, name = sys.argv[1], sys.argv[2]
pad = "=" * (-len(raw) % 4)
msg = BytesParser(policy=policy.default).parsebytes(base64.urlsafe_b64decode(raw + pad))
sys.stdout.write(str(msg[name]) if msg[name] is not None else "")
' "$1" "$2"
}

MIME_PLAIN="$(mime_get_part "$RAW_MSG" plain)"
MIME_HTML="$(mime_get_part "$RAW_MSG" html)"

assert_contains "the plain-text alternative still contains the original markdown-ish text, unrendered" \
  "$MIME_PLAIN" "Hello **world**"
assert_contains "the plain-text alternative still contains the original bullet syntax" \
  "$MIME_PLAIN" "- one"

assert_contains "the html alternative renders the bold text as a real element" \
  "$MIME_HTML" "<strong>world</strong>"
assert_contains "the html alternative turns the bullet list into a real list" \
  "$MIME_HTML" "<li"

assert_eq "the message as a whole is multipart/alternative (plain + html, not plain-only)" \
  "multipart/alternative" "$(python3 -c '
import base64, sys
from email import policy
from email.parser import BytesParser
raw = sys.argv[1]
pad = "=" * (-len(raw) % 4)
msg = BytesParser(policy=policy.default).parsebytes(base64.urlsafe_b64decode(raw + pad))
sys.stdout.write(msg.get_content_type())
' "$RAW_MSG")"

assert_eq "the Subject header round-trips correctly (RFC 2047 Chinese encoding)" \
  "Test 主题" "$(mime_get_header "$RAW_MSG" Subject)"

assert_eq "the X-Zenoforge-Agent-Issue marker header is stamped with the issue number" \
  "1146" "$(mime_get_header "$RAW_MSG" X-Zenoforge-Agent-Issue)"

assert_eq "no From header is set -- the Gmail API fills in the authenticated account" \
  "" "$(mime_get_header "$RAW_MSG" From)"

INLINE_PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/otcAAAAASUVORK5CYII='
INLINE_IMAGES="$(jq -cn --arg data "$INLINE_PNG_B64" '[{cid:"owner-chart",filename:"owner-chart.png",data:$data}]')"
CHART_MSG="$(build_gmail_raw_message 'someone@example.com' '工厂日报' '纯文本备用内容' '' 'fixture' \
  '<html><body><img src="cid:owner-chart"></body></html>' "$INLINE_IMAGES")"
assert_eq 'inline PNG is nested inside the HTML alternative as multipart/related' \
  multipart/related "$(python3 -c '
import base64, sys
from email import policy
from email.parser import BytesParser
raw = sys.argv[1]
msg = BytesParser(policy=policy.default).parsebytes(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
sys.stdout.write(msg.get_payload()[1].get_content_type())
' "$CHART_MSG")"
assert_eq 'inline PNG keeps the requested CID and image/png type' \
  'owner-chart:image/png:inline' "$(python3 -c '
import base64, sys
from email import policy
from email.parser import BytesParser
raw = sys.argv[1]
msg = BytesParser(policy=policy.default).parsebytes(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
part = msg.get_payload()[1].get_payload()[1]
sys.stdout.write(": ".join((part["Content-ID"].strip("<>"), part.get_content_type(), part.get_content_disposition())))
' "$CHART_MSG" | tr -d ' ')"
assert_contains 'inline-image mail preserves its plain-text fallback' \
  "$(mime_get_part "$CHART_MSG" plain)" '纯文本备用内容'

# --- Defect 7, 2026-09-13: Gmail credential self-check ----------------------
# gmail_credential_alert_reason (notify.sh): pure decision logic, no gcloud/
# curl/network. notify.test.sh exercises the probe with fake gcloud and curl.
assert_true "a broken credential always produces a non-empty alert reason" \
  test -n "$(gmail_credential_alert_reason broken)"

assert_eq "one invalid_grant probe waits for confirmation" \
  "1" "$(gmail_credential_invalid_grant_checks invalid_grant "" 0)"

assert_eq "a second consecutive invalid_grant confirms the failure" \
  "2" "$(gmail_credential_invalid_grant_checks invalid_grant invalid_grant 1)"

assert_eq "a transport failure resets invalid_grant confirmation" \
  "0" "$(gmail_credential_invalid_grant_checks transient invalid_grant 1)"

assert_eq "an invalid_grant after transport failure starts confirmation over" \
  "1" "$(gmail_credential_invalid_grant_checks invalid_grant transient 0)"

assert_eq "an unconfirmed invalid_grant has no alert reason" \
  "" "$(gmail_credential_alert_reason unconfirmed)"

# --- notes_md_offending_matches (notify.sh): the 2026-09-14 email
# legibility gate -- the mechanical check added alongside the rewritten
# prompts/triage.md (prose alone has failed repeatedly here, see
# lessons/RULES.md V75/V76). Pure function, no gh/gcloud/curl/network.
CLEAN_NOTES_MD='这个功能上线以后，退货单要不要自动扣减库存？如果不扣，仓库那边手工核对会比较麻烦；如果扣，遇到部分退货可能会算错，你觉得哪种更合适？'
assert_eq "a clean Chinese question produces no offending matches" \
  "" "$(notes_md_offending_matches "$CLEAN_NOTES_MD")"

# Output captured into a variable first, not piped straight into `grep -q`
# -- same SIGPIPE-safety reasoning as unmapped_login_is_noted() above (a
# live pipe into a fast-exiting `grep -q` can SIGPIPE a still-writing
# producer under this file's inherited pipefail).
notes_md_rejects() {
  local expected_prefix="$1" text="$2" out
  out="$(notes_md_offending_matches "$text")"
  grep -qF "$expected_prefix" <<<"$out"
}

assert_true "a backtick is rejected" \
  notes_md_rejects "backtick:" '看一下 `foo()` 这个函数是不是要改'

assert_true "a file path (with a directory) is rejected" \
  notes_md_rejects "file-path:" '改一下 engine/notify.sh 里的这段逻辑'

assert_true "a bare code-ish filename (no directory) is rejected" \
  notes_md_rejects "file-path:" '这个问题出在 notify.sh 里'

assert_true "a timestamp reference is rejected" \
  notes_md_rejects "timestamp:" '这个问题从 2026-09-13T03:29 就卡住了，一直没处理'

assert_eq "the trailing issue URL alone does not cause rejection" \
  "" \
  "$(notes_md_offending_matches '这个问题要不要现在就处理？
https://github.com/example-maintainer/example-repo/issues/1145')"

# Every class of pipeline vocabulary named in the brief, each as the ONLY
# thing wrong with an otherwise-plain sentence.
for term in triage ready-for-agent ready-for-human needs-info needs-owner \
  risk_class level phase origin/main P0 P1 P2 L0 L1 L2 L3 L4; do
  assert_true "pipeline vocabulary '$term' is rejected as a standalone token" \
    notes_md_rejects "pipeline-vocab: $term" "这是一句测试：$term 在这里"
done

# False positives the brief specifically calls out -- none of these are
# pipeline-shaped, so none should trip any rule.
assert_eq "an ordinary Chinese sentence naming the the product product is not rejected" \
  "" "$(notes_md_offending_matches 'the product 现在是不是要给退货单加一个人工确认步骤？')"

assert_eq "a bare issue reference like #1145 is not rejected" \
  "" "$(notes_md_offending_matches '这个和 #1145 是不是同一个问题？')"

assert_eq "'phase'/'level' inside an ordinary English word is not rejected" \
  "" "$(notes_md_offending_matches 'We should emphasize testing the checkout phaseout, and check the levels carefully')"

assert_eq "a bare date (no time-of-day) is not rejected" \
  "" "$(notes_md_offending_matches '这个问题是 2026-09-13 报的')"

# --- GitNexus index refresh (2026-09-14): closes the stall 0edb11c4f's own
# fail-closed staleness fix created -- nothing refreshed the index, so
# every phase-3 L2 ticket parked on a human forever. Same pin-by-grep style
# as the AGENT_MODEL/fail_attempt section above: this logic lives inline in
# run-triage.sh's top-level flow, not a reusable decision function, so
# there is nothing pure to call directly the way implement_model_for_
# attempt() is exercised below.
#
# Revised after a live failure: refresh checks bounded origin/main age and
# commit lag under one shared lock, invokes remote builder only when stale, and
# keeps refresh failures non-fatal so an environment fault cannot charge a
# ticket attempt. The fake helper below pins this failure behavior.
#
# 2026-09-15 (#1094/#1147 root cause, lessons/RULES.md V86-V87): the cheap
# read used to be `gitnexus status` (no args), which is self-referential --
# it compares $REPO_DIR against gitnexus's own last scan of $REPO_DIR, not
# against origin/main, so it can say "up to date" while $REPO_DIR itself is
# stale or on the wrong branch (confirmed live on #1094/#1147). Replaced
# with gitnexus_index_matches_origin_main(), which resolves origin/main under
# the shared lock. All callers use the same age/commit bounds and bounded lock
# and 30-minute latest-wins throttle.
assert_eq "self-referential GitNexus status predicate is removed" \
  "0" "$( { grep -nF -- 'gitnexus_status_is_up_to_date' "$SCRIPT_DIR/lib.d/gitnexus.sh" "$SCRIPT_DIR/run-triage.sh" "$SCRIPT_DIR/run-triage-batch.sh" "$SCRIPT_DIR/run-advisor.sh" || true; } | wc -l | tr -d ' ')"
assert_eq "WSL refresh path never runs GitNexus analyze locally" \
  "0" "$( { grep -F -- 'gitnexus analyze "$repo_dir" --index-only' "$SCRIPT_DIR/lib.d/gitnexus.sh" || true; } | wc -l | tr -d ' ')"
GITNEXUS_LOCK_LINE="$(grep -nF -- 'if ! flock -w "$GITNEXUS_REFRESH_LOCK_WAIT_SECONDS"' "$SCRIPT_DIR/lib.d/gitnexus.sh" | cut -d: -f1)"
GITNEXUS_ORIGIN_MAIN_SNAPSHOT_LINE="$(grep -nF -- 'target_sha="$(git -C "$repo_dir" rev-parse --verify refs/remotes/origin/main' "$SCRIPT_DIR/lib.d/gitnexus.sh" | cut -d: -f1)"
GITNEXUS_CHECKOUT_SNAPSHOT_LINE="$(grep -nF -- 'target_sha="$(git -C "$repo_dir" rev-parse HEAD' "$SCRIPT_DIR/lib.d/gitnexus.sh" | cut -d: -f1)"
assert_true "origin/main SHA is sampled only after acquiring the refresh lock" \
  test "$GITNEXUS_ORIGIN_MAIN_SNAPSHOT_LINE" -gt "$GITNEXUS_LOCK_LINE"
assert_true "checkout SHA is sampled only after acquiring the refresh lock" \
  test "$GITNEXUS_CHECKOUT_SNAPSHOT_LINE" -gt "$GITNEXUS_LOCK_LINE"
for f in run-triage.sh run-advisor.sh run-recut.sh; do
  assert_false "$f has no direct, unlocked gitnexus analyze call" \
    grep -qF -- 'gitnexus analyze ' "$SCRIPT_DIR/$f"
done

# The defect this fixes: a refresh failure must NOT go through fail_attempt
# (that aborts the run and charges the ticket an attempt) -- confirm no such
# call exists for the index refresh, unlike every genuine local-tool failure
# above it in the same file (git worktree add), which correctly still does.
# 2026-09-15: a worktree-add failure is an environment fault too -- it now
# goes to the systemic-fault ledger (record_env_fault) instead of the
# ticket's attempt counter, in every wrapper that creates a worktree; and
# the bare `gh issue view` that V79 recorded as an open gap (a Gateway
# Timeout killing the whole run under set -e) is recorded the same way.
for f in run-triage.sh run-advisor.sh run-recut.sh; do
  assert_false "$f no longer charges a worktree-add failure to the ticket via fail_attempt" \
    grep -qF -- 'fail_attempt "git worktree add failed repeatedly' "$SCRIPT_DIR/$f"
  assert_eq "$f records a worktree-add failure to the env-fault ledger" \
    "1" "$(grep -cF -- 'record_env_fault env:worktree-add' "$SCRIPT_DIR/$f")"
done
# run-recut.sh has one env:gh-api site for its initial `gh issue view`
# (V79's open gap). run-triage.sh also records failure to persist the new
# founder-test label, so it has two sites with distinct error descriptions.
# run-advisor.sh has a SECOND one now --
# Defect 2, 2026-09-15 (zf-advisor-1205, live): its own initial `gh issue
# view` already had this (unchanged here), but the LATER mutating `gh`
# calls that actually apply a verdict (the Apply section) had no failure
# handling at all -- a TLS handshake timeout on api.github.com/graphql
# crashed the whole run under `set -e` after a paid-for advisor verdict
# was already computed, with nothing recorded. apply_gh_write() is the fix;
# both sites share the same env:gh-api signature so the systemic-fault
# ledger sees one class, not two.
#
# 2026-09-19: apply_gh_write() itself moved to advisor-core.sh (the shared
# resume-check/persist-pending/apply core extracted from run-advisor.sh --
# see that file's own header), so its own env:gh-api site and its own
# definition now live there instead of run-advisor.sh. Checked as a SUM
# across both files below, not a single-file count, so the assertion keeps
# proving "exactly two sites total, wherever they live" instead of silently
# passing at a lower count if a future refactor drops one.
for f in run-triage.sh run-recut.sh; do
  expected_sites=1
  [ "$f" != run-triage.sh ] || expected_sites=2
  assert_eq "$f records each gh API failure path to the env-fault ledger" \
    "$expected_sites" "$(grep -cF -- 'record_env_fault env:gh-api' "$SCRIPT_DIR/$f")"
done
RUN_ADVISOR_ENV_GH_API_SITES="$(grep -cF -- 'record_env_fault env:gh-api' "$SCRIPT_DIR/run-advisor.sh")"
ADVISOR_CORE_ENV_GH_API_SITES="$(grep -cF -- 'record_env_fault env:gh-api' "$SCRIPT_DIR/advisor-core.sh")"
assert_eq "run-advisor.sh's own initial gh issue view still records env:gh-api (V79, unchanged)" \
  "1" "$RUN_ADVISOR_ENV_GH_API_SITES"
assert_eq "advisor-core.sh's apply_gh_write() records the SECOND env:gh-api site (Defect 2, 2026-09-15 -- moved here 2026-09-19)" \
  "1" "$ADVISOR_CORE_ENV_GH_API_SITES"
assert_eq "run-advisor.sh + advisor-core.sh together still record env:gh-api at exactly TWO sites total" \
  "2" "$((RUN_ADVISOR_ENV_GH_API_SITES + ADVISOR_CORE_ENV_GH_API_SITES))"
# gh_failure_is_transient (lib.sh): the discrimination boundary itself --
# a TLS/timeout/5xx shape is transient, a 4xx refusal must never match.
assert_true "gh_failure_is_transient matches the exact live TLS handshake timeout text (zf-advisor-1205)" \
  gh_failure_is_transient 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout'
assert_true "...and a 502/503/504 from api.github.com" \
  gh_failure_is_transient 'gh: Bad Gateway (HTTP 502)'
assert_false "...but NOT a genuine 404 (issue not found -- a real refusal, must stay a real failure)" \
  gh_failure_is_transient 'gh: Could not resolve to an Issue with the number 999999 (HTTP 404)'
assert_false "...and NOT a permissions refusal" \
  gh_failure_is_transient 'gh: Resource not accessible by integration (HTTP 403)'
assert_false "...and NOT a malformed-query error (a genuine gh/API refusal, not a network fault)" \
  gh_failure_is_transient 'gh: Could not resolve to a node with the global id of...(HTTP 422)'

# The model is told what the wrapper found (fresh, or not confirmed and
# why) instead of being asked to re-verify it itself: its own on-cwd
# `gitnexus status` (no --repo) can only ever report on $WT, a worktree
# gitnexus never registers, so it always says "not indexed" regardless of
# the real index's freshness -- confirmed live on #1094 and #1144, both of
# which misread that structural non-signal as staleness and parked on
# ready-for-human for it while the real index was fresh.

# --- the ladder (2026-09-15): provenance ------------------------------------
# A body shaped like the manifest-managed to-tickets issue-template -- the
# exact shape of #1193-#1208, the 18 tickets the maintainer cut on his Mac.
PRECUT_BODY='## Parent

[总计划](https://github.com/example/repo/issues/1)

## What to build

员工在现有 /chat/ 交代一次任务，看到排队与成果。

## Acceptance criteria

- [ ] 刷新后仍是同一任务

## Blocked by

- #2'
# The local-file template variant, in case a ticket body is pasted from it.
PRECUT_BODY_LOCAL='# 03 — 某切片

**What to build:** 一条端到端路径。

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent'
# A raw bug report from the issue form (.github/ISSUE_TEMPLATE/bug-report.yml
# has no "What to build" heading at all).
RAW_BODY='### 入口

网页

### 发生了什么

导出报表时忽略了所选的分组，返回了全部 34 条。

### 期望

只返回所选分组的记录。'
# A recut child: same `## What to build` heading (prompts/recut.md), but born
# needs-triage for a fresh measurement -- run-recut.sh stamps it with
# RECUT_CHILD_MARKER so the predicate excludes it.
RECUT_CHILD_BODY="## Parent

由 #7 拆分而来的可独立交付子任务之一，${RECUT_CHILD_MARKER}。

## What to build

一个子切片。

## Acceptance criteria

- [ ] 可验证"

assert_true "issue_is_precut: a /to-tickets issue-template body is precut" \
  issue_is_precut "$PRECUT_BODY"
assert_true "issue_is_precut: the local-file template variant is precut too" \
  issue_is_precut "$PRECUT_BODY_LOCAL"
assert_false "issue_is_precut: a raw bug-report body is not" \
  issue_is_precut "$RAW_BODY"
assert_false "issue_is_precut: a recut child (same heading, RECUT_CHILD_MARKER present) is not" \
  issue_is_precut "$RECUT_CHILD_BODY"
assert_false "issue_is_precut: an empty body is not" \
  issue_is_precut ""

# --- the ladder: ladder_state never stops -----------------------------------
assert_eq "ladder_state: an admissible classification is the standard rung" \
  "ready-for-agent" "$(ladder_state P1 L1 2)"
assert_eq "ladder_state: L2 at phase 3 is admissible" \
  "ready-for-agent" "$(ladder_state P1 L2 3)"
assert_eq "ladder_state: L2 at phase 2 is the advisor rung, not a human" \
  "needs-advisor" "$(ladder_state P1 L2 2)"
assert_eq "ladder_state: P2 is the advisor rung at any phase" \
  "needs-advisor" "$(ladder_state P2 L0 3)"
assert_eq "ladder_state: L4 is the advisor rung" \
  "needs-advisor" "$(ladder_state P1 L4 3)"
assert_eq "ladder_state: empty fields fail closed to the advisor rung, never to admission" \
  "needs-advisor" "$(ladder_state "" "" 3)"
assert_not_contains "ladder_state can never say ready-for-human" \
  "$(ladder_state P2 L4 2)$(ladder_state "" "" "")$(ladder_state garbage garbage 3)" "ready-for-human"

# --- the ladder: admit_guarded writes the contract, applies one label -----
GUARDED_HOME="$(mktemp -d)"
GUARDED_OUT="$(
  AGENT_HOME="$GUARDED_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    roadmap_ensure_issue_parent() { :; }
    recut_parent_has_open_child() { return 1; }
    admit_guarded 424242 P2 L3 "拆不动" "- [ ] 另一租户看不到" 2>&1
  ' "$SCRIPT_DIR"
)"
rm -rf "$GUARDED_HOME"
assert_contains "admit_guarded: applies ready-for-agent" "$GUARDED_OUT" "--add-label ready-for-agent"
assert_contains "admit_guarded: strips needs-recut" "$GUARDED_OUT" "--remove-label needs-recut"
assert_contains "admit_guarded: strips ready-for-human" "$GUARDED_OUT" "--remove-label ready-for-human"
assert_not_contains "admit_guarded: never adds ready-for-human" "$GUARDED_OUT" "--add-label ready-for-human"
assert_contains "admit_guarded: state carries guarded:true" "$GUARDED_OUT" '"guarded": true'
assert_contains "admit_guarded: state carries the reason" "$GUARDED_OUT" "拆不动"
assert_contains "admit_guarded: state carries the merge conditions" "$GUARDED_OUT" "另一租户看不到"
assert_contains "admit_guarded: the comment names the configured work reviewer" \
  "$GUARDED_OUT" "work role"
assert_contains "admit_guarded: ...and names the persistent work role for implementation" \
  "$GUARDED_OUT" "work role"
assert_not_contains "admit_guarded: the banner never names an empty implementer" "$GUARDED_OUT" "实现用 ，"
# Model policy keeps guarded review and implementation on the work role.
assert_contains "admit_guarded: called with only 5 args (run-recut.sh's own call site, predating required_test_paths) defaults it to an empty array, not an error" \
  "$GUARDED_OUT" '"required_test_paths": []'

# admit_guarded's optional 6th arg (required_test_paths): run-advisor.sh's
# own guarded verdict passes it; run-recut.sh's call site (above) doesn't
# have to.
GUARDED_HOME2="$(mktemp -d)"
GUARDED_OUT2="$(
  AGENT_HOME="$GUARDED_HOME2" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    roadmap_ensure_issue_parent() { :; }
    recut_parent_has_open_child() { return 1; }
    admit_guarded 424243 P2 L3 "拆不动" "- [ ] 反例测试" "[\"packages/x/tests/replay.test.ts\"]" 2>&1
  ' "$SCRIPT_DIR"
)"
rm -rf "$GUARDED_HOME2"
assert_contains "admit_guarded: the 6th arg (required_test_paths), when given, is stored" \
  "$GUARDED_OUT2" '"required_test_paths": ['
assert_contains "admit_guarded: ...with its actual content" \
  "$GUARDED_OUT2" "packages/x/tests/replay.test.ts"

# --- sweep_reopened_issues: an issue THIS PIPELINE closed, reopened -------
# 2026-09-15 maintainer ruling: a human's only
# correction path on an unconditionally-closed ticket is GitHub's own
# Reopen button, so it must not land somewhere no candidate-selection loop
# ever looks. Fake `gh` on PATH: `issue list --state open` returns a fixed
# roster (a SEARCH-INDEX read, can lag); `issue view
# --json state` returns each fixture's REAL current state (a point read);
# `issue edit`/`issue comment` are captured via guarded_write's own dry-run
# print (no fake needed under AGENT_DRY_RUN=1); `issue view --json labels`
# (is_on_hold) returns no labels for every issue here -- none of this
# fixture is on-hold.
SWEEP_REOPEN_HOME="$(mktemp -d)"
mkdir -p "$SWEEP_REOPEN_HOME/state"
# #700001: we closed it (marker set), currently open under `concluded` --
# a genuine reopen, must sweep.
echo '{"state":"concluded","closed_by_pipeline":true,"released":true,"deploy_state":"deployed","deployed_sha":"abc1234","run":{"evidence":{"real_user_path":"URL: https://example.example/; Visible DOM: the product; Same-run network: GET /api -> 200"}}}' > "$SWEEP_REOPEN_HOME/state/700001.json"
# #700002: open under `concluded` too, but WE never closed it (no marker,
# e.g. a stale/hand-applied label, or this repo's own still-open pr-open/
# not-completed outcomes that legitimately carry `concluded` while open) --
# must be left alone.
echo '{"state":"concluded"}' > "$SWEEP_REOPEN_HOME/state/700002.json"
# #700003: we closed it as wontfix (marker set), reopened -- also swept,
# under a different source label.
echo '{"state":"wontfix","closed_by_pipeline":true}' > "$SWEEP_REOPEN_HOME/state/700003.json"
# #700004: the live #1180 race -- marker set (we just closed it), the
# search-index list STILL reports it open (staleness), but a direct view
# confirms it is actually CLOSED. Must NOT be swept.
echo '{"state":"concluded","closed_by_pipeline":true}' > "$SWEEP_REOPEN_HOME/state/700004.json"
# #700005: pipeline closed it, then a reopen flow replaced `concluded` with
# `needs-triage` before recovery. The durable marker must still find it.
echo '{"state":"concluded","closed_by_pipeline":true}' > "$SWEEP_REOPEN_HOME/state/700005.json"

SWEEP_REOPEN_BIN="$(mktemp -d)"
cat > "$SWEEP_REOPEN_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Mimics gh's OWN -q (jq) filtering, not raw JSON -- callers here rely on
# bare-number/empty-line output exactly like the real `-q '.[].number'` /
# `-q '.labels[].name'` / `-q '.state'` would produce.
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  label=""
  for ((i=1; i<=$#; i++)); do
    if [ "${!i}" = "--label" ]; then j=$((i+1)); label="${!j}"; fi
  done
  if [ -z "$label" ] && [ "${FAKE_OPEN_LIST_FAILURE:-0}" = 1 ]; then exit 1; fi
  case "$label" in
    concluded) printf '700001\n700002\n700004\n' ;;
    wontfix) printf '700003\n' ;;
    duplicate) : ;;
    "") printf '700001\n700002\n700003\n700004\n700005\n' ;;
  esac
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  n="$3"
  args=("$@")
  last="${args[-1]}"
  if [ "$last" = ".state" ]; then
    if [ "$n" = "700004" ]; then echo "CLOSED"; else echo "OPEN"; fi
  fi
  # else: -q '.labels[].name' (is_on_hold) on an empty labels array prints nothing
  exit 0
fi
echo "unexpected fake gh invocation: $*" >&2
exit 1
FAKE_GH
chmod +x "$SWEEP_REOPEN_BIN/gh"

SWEEP_REOPEN_OUT="$(
  PATH="$SWEEP_REOPEN_BIN:$PATH" AGENT_HOME="$SWEEP_REOPEN_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    roadmap_ensure_issue_parent() { :; }
    sweep_reopened_issues
  ' "$SCRIPT_DIR" 2>&1
)"
SWEEP_REOPEN_WRITE_1="$(grep -F 'issue edit 700001 ' <<< "$SWEEP_REOPEN_OUT" || true)"
assert_contains "sweep_reopened_issues: reopens a pipeline-closed issue (concluded)" \
  "$SWEEP_REOPEN_WRITE_1" "--remove-label concluded"
assert_contains "...clears previous release state labels" \
  "$SWEEP_REOPEN_WRITE_1" "--remove-label awaiting-release"
assert_contains "...adds the new triage label" \
  "$SWEEP_REOPEN_WRITE_1" "--add-label needs-triage"
assert_contains "...records the new triage episode" \
  "$SWEEP_REOPEN_OUT" '"state": "needs-triage"'
assert_not_contains "...clears the prior deploy record for the new triage episode" \
  "$SWEEP_REOPEN_OUT" '"deploy_state"'
assert_contains "...names #700001" "$SWEEP_REOPEN_OUT" "issue edit 700001"
assert_contains "...also sweeps one closed as wontfix (#700003)" "$SWEEP_REOPEN_OUT" "issue edit 700003"
assert_contains "...recovers #700005 after its terminal label was replaced before the sweep" \
  "$SWEEP_REOPEN_OUT" "issue edit 700005"
assert_not_contains "...never touches #700002 -- concluded but no closed_by_pipeline marker" \
  "$SWEEP_REOPEN_OUT" "issue edit 700002"
assert_not_contains "...never touches #700004 -- the list said open but a direct view says CLOSED (live #1180 staleness race)" \
  "$SWEEP_REOPEN_OUT" "issue edit 700004"
if SWEEP_REOPEN_FAILURE_OUT="$(PATH="$SWEEP_REOPEN_BIN:$PATH" FAKE_OPEN_LIST_FAILURE=1 \
    AGENT_HOME="$SWEEP_REOPEN_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
      source "$0/lib.sh"
      roadmap_ensure_issue_parent() { :; }
      sweep_reopened_issues
    ' "$SCRIPT_DIR" 2>&1)"; then
  SWEEP_REOPEN_FAILURE_STATUS=0
else
  SWEEP_REOPEN_FAILURE_STATUS=$?
fi
assert_eq "a failed open-issue snapshot fails closed" 1 "$SWEEP_REOPEN_FAILURE_STATUS"
assert_contains "a failed open-issue snapshot names the read failure" \
  "$SWEEP_REOPEN_FAILURE_OUT" "could not list open issues"
assert_not_contains "a failed open-issue snapshot performs no issue edits" \
  "$SWEEP_REOPEN_FAILURE_OUT" "issue edit"
rm -rf "$SWEEP_REOPEN_HOME" "$SWEEP_REOPEN_BIN"

# record_run_decision: append-only -- a second call must never clobber the
# first. Real (non-dry-run) writes: this function only ever calls
# state_merge, never gh, so there is no network/gh risk in letting it write
# for real.
RECORD_DECISION_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$RECORD_DECISION_HOME/model-policy.json"
mkdir -p "$RECORD_DECISION_HOME/state"
AGENT_HOME="$RECORD_DECISION_HOME" REPO="test/repo" bash -c '
  source "$0/lib.sh"
  record_run_decision 500009 advisor "corrected risk_class P2 -> P1" 0
  record_run_decision 500009 wrapper "retry role came from model-policy on attempt 4" 1
' "$SCRIPT_DIR"
RECORD_DECISION_STATE="$(cat "$RECORD_DECISION_HOME/state/500009.json")"
rm -rf "$RECORD_DECISION_HOME"
assert_contains "record_run_decision: the first call's entry survives a second call (append, not overwrite)" \
  "$RECORD_DECISION_STATE" "corrected risk_class P2 -> P1"
assert_contains "record_run_decision: the second call's entry is also present" \
  "$RECORD_DECISION_STATE" "retry role came from model-policy on attempt 4"
assert_contains "record_run_decision: forced=true recorded for the second entry" \
  "$RECORD_DECISION_STATE" '"forced": true'
assert_eq "record_run_decision: exactly two decisions accumulated, neither overwrote the other" \
  "2" "$(echo "$RECORD_DECISION_STATE" | jq '.run.decisions | length')"

# --- route_to_advisor: the shared write path for a NEW advisor episode ----
# 2026-09-15 fix, live incident: issue-pipeline.sh's advisor-dispatch loop
# (line 413) skips any issue `has("advisor_ruled_at")`, on the assumption
# that needs-advisor is applied once per issue lifetime. False -- it is
# legitimately re-applied for a second episode, and advisor_ruled_at is a
# permanent field run-advisor.sh never clears -- so a second episode was
# undispatchable forever (not ready-for-agent, not advisor-eligible). 15 of
# 21 open needs-advisor issues were stuck this way when found. Real
# (non-dry-run) writes: this exercises the actual clear, not its dry-run
# print, so a regression (route_to_advisor stops clearing the field) fails
# this test even though it wouldn't change any dry-run string.
ROUTE_TEST_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$ROUTE_TEST_HOME/model-policy.json"
mkdir -p "$ROUTE_TEST_HOME/state"
echo '{"attempts":2,"risk_class":"P1","advisor_ruled_at":"2026-09-01T00:00:00Z"}' \
  > "$ROUTE_TEST_HOME/state/700001.json"
echo '{"attempts":1,"advisor_ruled_at":"2026-08-20T00:00:00Z"}' \
  > "$ROUTE_TEST_HOME/state/700002.json"
echo '{"attempts":1,"risk_class":"P1","advisor_ruled_at":"2026-09-01T00:00:00Z","pending_advisor_verdict":{"verdict":"recut"},"web_advisor_provider_job_id":"old-job","advisor_episode_seq":4}' \
  > "$ROUTE_TEST_HOME/state/700003.json"
echo '{"attempts":1,"advisor_ruled_at":"2026-09-01T00:00:00Z"}' > "$ROUTE_TEST_HOME/state/700004.json"
echo '{"attempts":1,"state":"awaiting-release","deploy_state":"pending","run":{"outcome":"merged","evidence":{"pr_number":1844}}}' \
  > "$ROUTE_TEST_HOME/state/700005.json"
echo '{"pipeline_system":{"enabled":true}}' > "$ROUTE_TEST_HOME/state/700006.json"
echo '{"attempts":1,"state":"needs-advisor","tracker_parent":true,"advisor_episode_seq":2,"advisor_ruled_at":"2026-09-28T00:00:00Z"}' \
  > "$ROUTE_TEST_HOME/state/700007.json"
echo '{"attempts":1,"state":"needs-advisor","tracker_parent":true,"advisor_episode_seq":2}' \
  > "$ROUTE_TEST_HOME/state/700008.json"
ROUTE_BIN="$(mktemp -d)"
ROUTE_GH_LOG="$ROUTE_TEST_HOME/gh.log"
: > "$ROUTE_GH_LOG"
cat > "$ROUTE_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$ROUTE_GH_LOG"
if [ "\$1 \${2:-}" = "issue view" ]; then
  state=OPEN
  [ "\${3:-}" = 700004 ] && state=CLOSED
  jq -n --arg state "\$state" '{state:\$state,labels:[]}'
fi
exit 0
EOF
chmod +x "$ROUTE_BIN/gh"
ROUTE_OUTPUT="$(PATH="$ROUTE_BIN:$PATH" AGENT_HOME="$ROUTE_TEST_HOME" ZF_REPO="test/repo" bash -c '
  source "$0/lib.sh"
  roadmap_ensure_issue_parent() { :; }
  route_to_advisor 700001
  route_to_advisor 700002 ready-for-human
  route_to_advisor 700003 needs-advisor
  route_to_advisor 700004
  route_to_advisor 700005
  route_to_advisor 700006
  route_to_advisor 700007 needs-advisor
  if issue_transition 700008 needs-advisor advisor-route; then echo TRACKER-TRANSITION-ALLOWED; else echo TRACKER-TRANSITION-BLOCKED; fi
' "$SCRIPT_DIR" 2>&1)"
ROUTE_STATE_1="$(cat "$ROUTE_TEST_HOME/state/700001.json")"
ROUTE_STATE_2="$(cat "$ROUTE_TEST_HOME/state/700002.json")"
ROUTE_STATE_3="$(cat "$ROUTE_TEST_HOME/state/700003.json")"
ROUTE_STATE_4="$(cat "$ROUTE_TEST_HOME/state/700004.json")"
ROUTE_STATE_5="$(cat "$ROUTE_TEST_HOME/state/700005.json")"
ROUTE_STATE_6="$(cat "$ROUTE_TEST_HOME/state/700006.json")"
ROUTE_STATE_7="$(cat "$ROUTE_TEST_HOME/state/700007.json")"
ROUTE_STATE_8="$(cat "$ROUTE_TEST_HOME/state/700008.json")"
ROUTE_GH_LOG_CONTENT="$(cat "$ROUTE_GH_LOG")"
ROUTE_WRITE_1="$(grep -F 'gh issue edit 700001 ' <<< "$ROUTE_GH_LOG_CONTENT" || true)"
ROUTE_WRITE_2="$(grep -F 'gh issue edit 700002 ' <<< "$ROUTE_GH_LOG_CONTENT" || true)"
ROUTE_WRITE_6="$(grep -F 'gh issue edit 700006 ' <<< "$ROUTE_GH_LOG_CONTENT" || true)"
rm -rf "$ROUTE_TEST_HOME" "$ROUTE_BIN"

assert_eq "route_to_advisor clears a stale advisor_ruled_at from a prior episode" \
  "false" "$(echo "$ROUTE_STATE_1" | jq 'has("advisor_ruled_at")')"
assert_contains "route_to_advisor preserves the rest of the state file (risk_class untouched)" \
  "$ROUTE_STATE_1" '"risk_class": "P1"'
assert_eq "route_to_advisor preserves attempts" \
  "2" "$(echo "$ROUTE_STATE_1" | jq '.attempts')"
assert_contains "route_to_advisor: default remove-label is ready-for-agent (the 5 known call sites)" \
  "$ROUTE_WRITE_1" "--remove-label ready-for-agent"
assert_contains "route_to_advisor adds needs-advisor through the transition helper" \
  "$ROUTE_WRITE_1" "--add-label needs-advisor"
assert_eq "route_to_advisor with an explicit remove-label (sweep-parked-backlog.sh's ready-for-human site) also clears advisor_ruled_at" \
  "false" "$(echo "$ROUTE_STATE_2" | jq 'has("advisor_ruled_at")')"
assert_contains "route_to_advisor: an explicit remove-label argument is honored" \
  "$ROUTE_WRITE_2" "--remove-label ready-for-human"
assert_contains "route_to_advisor applies the explicit advisor destination" \
  "$ROUTE_WRITE_2" "--add-label needs-advisor"
assert_eq "route_to_advisor leaves a closed issue state untouched" \
  "true" "$(echo "$ROUTE_STATE_4" | jq 'has("advisor_ruled_at")')"
assert_not_contains "route_to_advisor does not relabel a closed issue" "$ROUTE_GH_LOG_CONTENT" "issue edit 700004"
assert_contains "route_to_advisor logs the closed issue skip" "$ROUTE_OUTPUT" "issue is closed"
assert_eq "merged pending deploy stays owned by release" \
  "awaiting-release" "$(echo "$ROUTE_STATE_5" | jq -r '.state')"
assert_not_contains "merged pending deploy does not gain advisor label" "$ROUTE_GH_LOG_CONTENT" "issue edit 700005"
assert_eq "product live labels clear stale pipeline-system state before advisor routing" \
  "false" "$(jq -r '.pipeline_system.enabled // false' <<< "$ROUTE_STATE_6")"
assert_contains "product issue with stale pipeline-system state returns to advisor lane" \
  "$ROUTE_WRITE_6" "--remove-label ready-for-agent"
assert_contains "product issue reaches advisor through transition helper" \
  "$ROUTE_WRITE_6" "--add-label needs-advisor"
assert_eq "route_to_advisor retires tracker parents instead of rearming them" \
  "tracker" "$(jq -r '.state' <<< "$ROUTE_STATE_7")"
assert_eq "tracker retirement preserves the parent marker" \
  "true" "$(jq -r '.tracker_parent' <<< "$ROUTE_STATE_7")"
assert_eq "tracker retirement clears the stale advisor ruling" \
  "false" "$(jq 'has("advisor_ruled_at")' <<< "$ROUTE_STATE_7")"
assert_contains "tracker retirement removes the stale advisor label" \
  "$(grep -F 'gh issue edit 700007 ' <<< "$ROUTE_GH_LOG_CONTENT" || true)" "--remove-label needs-advisor"
assert_not_contains "tracker retirement never re-adds the advisor label" \
  "$(grep -F 'gh issue edit 700007 ' <<< "$ROUTE_GH_LOG_CONTENT" || true)" "--add-label needs-advisor"
assert_contains "issue_transition refuses to route a tracker parent back into an active lane" \
  "$ROUTE_OUTPUT" "TRACKER-TRANSITION-BLOCKED"
assert_eq "refused tracker transition leaves local state unchanged" \
  "needs-advisor" "$(jq -r '.state' <<< "$ROUTE_STATE_8")"
assert_not_contains "refused tracker transition does not write an advisor label" \
  "$(grep -F 'gh issue edit 700008 ' <<< "$ROUTE_GH_LOG_CONTENT" || true)" "--add-label needs-advisor"

# 2026-09-19: the episode-sequence guard (advisor-core.sh) -- route_to_
# advisor() must bump advisor_episode_seq every time it starts a fresh
# episode, a real (non-dry-run) write, same as the advisor_ruled_at clear
# just above. Both fixtures started with no advisor_episode_seq field at
# all (state_read()'s own default, and this fixture's seed JSON), so `// 0`
# plus one increment lands on 1.
assert_eq "route_to_advisor increments advisor_episode_seq (the episode-sequence guard)" \
  "1" "$(echo "$ROUTE_STATE_1" | jq '.advisor_episode_seq')"
assert_eq "route_to_advisor increments advisor_episode_seq regardless of which remove-label was passed" \
  "1" "$(echo "$ROUTE_STATE_2" | jq '.advisor_episode_seq')"
assert_eq "route_to_advisor re-arms an already-active needs-advisor label" \
  "false" "$(echo "$ROUTE_STATE_3" | jq 'has("advisor_ruled_at")')"
assert_eq "same-label rearm clears pending verdict and prior web-advisor-provider job" \
  "false" "$(echo "$ROUTE_STATE_3" | jq 'has("pending_advisor_verdict") or has("web_advisor_provider_job_id")')"
assert_eq "same-label rearm increments the existing episode sequence" \
  "5" "$(echo "$ROUTE_STATE_3" | jq '.advisor_episode_seq')"
assert_not_contains "same-label rearm avoids redundant GitHub label edit" \
  "$ROUTE_GH_LOG_CONTENT" "gh issue edit 700003"

# Static guard: a bare `--add-label needs-advisor` outside route_to_advisor()
# is exactly the defect this fix closes -- a label applied without the
# accompanying advisor_ruled_at clear. Every real call site (run-implement.sh,
# run-release.sh, issue-pipeline.sh, sweep-parked-backlog.sh) must go through
# the function; lib.sh's own definition is one legitimate occurrence. Excludes
# *.test.sh, which asserts on the resulting dry-run/gh-log string, not a
# call site.
#
# All needs-advisor state-label writes now use issue_transition's computed
# label set; no literal add-label write may remain in lib.sh.
BARE_NEEDS_ADVISOR_SITES="$(grep -rn -- '--add-label needs-advisor' "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/lib.d/*.sh \
  | grep -v '\.test\.sh:' | grep -v "^$SCRIPT_DIR/lib.sh:" | grep -v "^$SCRIPT_DIR/lib.d/issue-state.sh:" || true)"
assert_eq "no direct needs-advisor label writes remain outside lib.sh" \
  "" "$BARE_NEEDS_ADVISOR_SITES"
LIB_NEEDS_ADVISOR_COUNT="$({ grep -h -- '--add-label needs-advisor' "$SCRIPT_DIR/lib.sh" "$SCRIPT_DIR"/lib.d/*.sh || true; } | wc -l | tr -d ' ')"
assert_eq "lib.sh has no direct needs-advisor label writes outside issue_transition" \
  "0" "$LIB_NEEDS_ADVISOR_COUNT"
# 2026-09-19: the filter this asserts against grew a third clause
# (advisor_episode_seq's own increment, the episode-sequence guard --
# advisor-core.sh's own header has the race this closes) in the SAME
# state_merge call as the del(), not a second write -- see that function's
# own comment for why splitting it into two calls would reopen exactly the
# inconsistent-state window this mechanism exists to close. The pattern
# below was updated to match; it is still an EXACT match on the whole
# filter argument (not a substring grep), so a future edit that silently
# drops either clause, or moves the increment out of this one call, still
# fails this test.
assert_eq "give_up_on_issue() clears a stale advisor_ruled_at (and pending_advisor_verdict) AND bumps advisor_episode_seq, all in one atomic state_merge call, before its own needs-advisor add, same guarantee as route_to_advisor()" \
  "1" "$(awk '/^give_up_on_issue\(\) \{/,/^\}/' "$SCRIPT_DIR/lib.d/release-close.sh" | grep -cF 'del(.advisor_ruled_at, .pending_advisor_verdict, .web_advisor_provider_job_id')"

# give_up_on_issue(): the same episode-sequence bump, exercised as a real
# (non-dry-run) write -- the static check just above only proves the source
# text has the right shape, not that state_merge() actually applies it.
# Seeded with an existing advisor_episode_seq (3, simulating a ticket
# already a few episodes in) so this also proves the increment is relative
# to whatever was there, not a hardcoded reset to 1.
GIVEUP_TEST_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$GIVEUP_TEST_HOME/model-policy.json"
mkdir -p "$GIVEUP_TEST_HOME/state"
echo '{"attempts":3,"risk_class":"P1","advisor_ruled_at":"2026-09-01T00:00:00Z","advisor_episode_seq":3}' \
  > "$GIVEUP_TEST_HOME/state/700003.json"
GIVEUP_BIN="$(mktemp -d)"
GIVEUP_GH_LOG="$GIVEUP_TEST_HOME/gh.log"
: > "$GIVEUP_GH_LOG"
cat > "$GIVEUP_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GIVEUP_GH_LOG"
if [ "\$1" = issue ] && [ "\$2" = view ]; then printf '%s\\n' '{"labels":[]}'; fi
exit 0
EOF
chmod +x "$GIVEUP_BIN/gh"
# ZF_GCLOUD_BIN points at a nonexistent path so give_up_on_issue()'s own
# notify_email() call (send_email(), notify.sh) hits its own "gcloud binary
# not found -- skipping send" no-op and returns 0 without ever attempting a
# real network call -- this test wants a REAL (non-dry-run) state_merge
# write (same reasoning as route_to_advisor's own ROUTE_TEST_HOME above),
# so DRY_RUN=1 is not an option here (it would no-op state_merge too).
PATH="$GIVEUP_BIN:$PATH" AGENT_HOME="$GIVEUP_TEST_HOME" ZF_REPO="test/repo" ZF_GCLOUD_BIN="/nonexistent/gcloud" bash -c '
  source "$0/lib.sh"
  roadmap_ensure_issue_parent() { :; }
  give_up_on_issue 700003 "test reason"
' "$SCRIPT_DIR" >/dev/null 2>&1
GIVEUP_STATE="$(cat "$GIVEUP_TEST_HOME/state/700003.json")"
rm -rf "$GIVEUP_TEST_HOME" "$GIVEUP_BIN"

assert_eq "give_up_on_issue increments advisor_episode_seq relative to its prior value (3 -> 4)" \
  "4" "$(echo "$GIVEUP_STATE" | jq '.advisor_episode_seq')"
assert_eq "give_up_on_issue: the real write also clears advisor_ruled_at (unchanged behavior)" \
  "false" "$(echo "$GIVEUP_STATE" | jq 'has("advisor_ruled_at")')"

# --- route_to_recut: the shared write path for a NEW recut episode --------
# 2026-09-16 fix, live incident (exact twin of route_to_advisor's own
# V102): issue-pipeline.sh's needs-recut dispatch loop and run-recut.sh's
# own idempotency check both skip any issue whose state file
# has("recut_children") or has("recut_refused_at"). recut_refused_at is
# NOT permanent -- refuse_and_exit() (run-recut.sh) routes a refused parent
# to admit_guarded() -> ready-for-agent, which can fail in run-implement.sh,
# bounce to needs-advisor via route_to_advisor(), and get ruled `recut`
# again: a genuinely new episode, with the FIRST episode's recut_refused_at
# never cleared. recut_children is different: it is the permanent record of
# a completed split, so complete_recut_parent() retires its needs-recut label
# and route_to_recut() refuses to erase the marker or reapply that label.
ROUTE_RECUT_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$ROUTE_RECUT_HOME/model-policy.json"
mkdir -p "$ROUTE_RECUT_HOME/state"
echo '{"attempts":1,"risk_class":"P1","recut_refused_at":"2026-09-15T15:22:44Z"}' \
  > "$ROUTE_RECUT_HOME/state/800001.json"
echo '{"attempts":0,"recut_children":[900,901]}' \
  > "$ROUTE_RECUT_HOME/state/800002.json"
ROUTE_RECUT_BIN="$(mktemp -d)"
ROUTE_RECUT_GH_LOG="$ROUTE_RECUT_HOME/gh.log"
: > "$ROUTE_RECUT_GH_LOG"
cat > "$ROUTE_RECUT_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$ROUTE_RECUT_GH_LOG"
if [ "\$1" = issue ] && [ "\$2" = view ]; then printf '%s\\n' '{"labels":[]}'; fi
exit 0
EOF
chmod +x "$ROUTE_RECUT_BIN/gh"
PATH="$ROUTE_RECUT_BIN:$PATH" AGENT_HOME="$ROUTE_RECUT_HOME" ZF_REPO="test/repo" bash -c '
  source "$0/lib.sh"
  roadmap_ensure_issue_parent() { :; }
  route_to_recut 800001
' "$SCRIPT_DIR"
ROUTE_RECUT_CHILD_STATUS="$(PATH="$ROUTE_RECUT_BIN:$PATH" AGENT_HOME="$ROUTE_RECUT_HOME" ZF_REPO="test/repo" bash -c '
  source "$0/lib.sh"
  roadmap_ensure_issue_parent() { :; }
  route_to_recut 800002
  printf "%s" "$?"
' "$SCRIPT_DIR" 2>/dev/null)"
ROUTE_RECUT_STATE_1="$(cat "$ROUTE_RECUT_HOME/state/800001.json")"
ROUTE_RECUT_STATE_2="$(cat "$ROUTE_RECUT_HOME/state/800002.json")"
ROUTE_RECUT_GH_LOG_CONTENT="$(cat "$ROUTE_RECUT_GH_LOG")"
ROUTE_RECUT_WRITE_1="$(grep -F 'gh issue edit 800001 ' <<< "$ROUTE_RECUT_GH_LOG_CONTENT" || true)"
rm -rf "$ROUTE_RECUT_HOME" "$ROUTE_RECUT_BIN"

assert_eq "route_to_recut clears a stale recut_refused_at from a prior episode" \
  "false" "$(echo "$ROUTE_RECUT_STATE_1" | jq 'has("recut_refused_at")')"
assert_contains "route_to_recut preserves the rest of the state file (risk_class untouched)" \
  "$ROUTE_RECUT_STATE_1" '"risk_class": "P1"'
assert_contains "route_to_recut applies needs-recut and strips the other state labels" \
  "$ROUTE_RECUT_WRITE_1" "--remove-label ready-for-agent"
assert_contains "route_to_recut applies needs-recut through transition helper" \
  "$ROUTE_RECUT_WRITE_1" "--add-label needs-recut"
assert_eq "route_to_recut does NOT clear recut_children -- it is a one-way terminal marker, not a per-episode flag" \
  "true" "$(echo "$ROUTE_RECUT_STATE_2" | jq 'has("recut_children")')"
assert_eq "route_to_recut rejects a recut_children ticket instead of reapplying needs-recut" \
  "1" "$ROUTE_RECUT_CHILD_STATUS"
assert_eq "route_to_recut never edits labels for a child-completed parent" \
  "0" "$(grep -c "gh issue edit 800002" <<< "$ROUTE_RECUT_GH_LOG_CONTENT")"

# --- recut_marker_blocks: the one predicate both needs-recut skip sites use --
# Live shape (row 148, synthetic ids; run-recut.test.sh runs the whole path).
# A stale refusal is ignored only on needs-recut, when the label came after it.
recut_marker_rc() { bash -c 'source "$0/lib.sh"; printf "%s" "$1" | recut_marker_blocks; echo $?' "$SCRIPT_DIR" "$1" 2>/dev/null; }
assert_eq "recut_marker_blocks: needs-recut re-applied after a refusal does not block (#5139 live shape)" \
  "1" "$(recut_marker_rc '{"state":"needs-recut","attempts":1,"recut_refused_at":"2026-11-04T18:10:45Z","state_changed_at":"2026-11-05T05:25:05Z"}')"
assert_eq "recut_marker_blocks: refusal not older than the needs-recut label still blocks" \
  "0" "$(recut_marker_rc '{"state":"needs-recut","recut_refused_at":"2026-11-05T06:00:00Z","state_changed_at":"2026-11-05T05:25:05Z"}')"
assert_eq "recut_marker_blocks: stale refusal on a non-needs-recut state still blocks" \
  "0" "$(recut_marker_rc '{"state":"ready-for-agent","recut_refused_at":"2026-11-04T18:10:45Z","state_changed_at":"2026-11-05T05:25:05Z"}')"
assert_eq "recut_marker_blocks: refusal with no state_changed_at still blocks" \
  "0" "$(recut_marker_rc '{"state":"needs-recut","recut_refused_at":"2026-11-04T18:10:45Z"}')"
assert_eq "recut_marker_blocks: recut_children blocks even past a stale refusal" \
  "0" "$(recut_marker_rc '{"state":"needs-recut","recut_refused_at":"2026-11-04T18:10:45Z","state_changed_at":"2026-11-05T05:25:05Z","recut_children":[900,901]}')"
assert_eq "recut_marker_blocks: no marker does not block" \
  "1" "$(recut_marker_rc '{"state":"needs-recut","attempts":0}')"
assert_eq "issue-pipeline.sh needs-recut pre-filter calls recut_marker_blocks" \
  "1" "$(grep -cF 'state_read "$next_recut" | recut_marker_blocks && continue' "$SCRIPT_DIR/issue-pipeline.sh" || true)"

# Static guard: no script may add needs-recut outside issue_transition.
# Exclude *.test.sh (which asserts on resulting gh-log strings, not call sites).
BARE_NEEDS_RECUT_SITES="$(grep -rn -- '--add-label needs-recut' "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/lib.d/*.sh \
  | grep -v '\.test\.sh:' | grep -v "^$SCRIPT_DIR/lib.sh:" | grep -v "^$SCRIPT_DIR/lib.d/issue-state.sh:" || true)"
assert_eq "no direct needs-recut label writes remain outside lib.sh" \
  "" "$BARE_NEEDS_RECUT_SITES"
LIB_NEEDS_RECUT_COUNT="$({ grep -h -- '--add-label needs-recut' "$SCRIPT_DIR/lib.sh" "$SCRIPT_DIR"/lib.d/*.sh || true; } | wc -l | tr -d ' ')"
assert_eq "lib.sh has no direct needs-recut label writes outside issue_transition" \
  "0" "$LIB_NEEDS_RECUT_COUNT"
assert_eq "route_to_recut() clears a stale recut_refused_at before its own needs-recut add" \
  "1" "$(awk '/^route_to_recut\(\) \{/,/^\}/' "$SCRIPT_DIR/lib.d/recut.sh" | grep -cF 'del(.recut_refused_at, .advisor_convergence_pass, .advisor_convergence_pass_attempt, .web_advisor_provider_job_id')"

# --- V102's third recurrence: a state_merge FAILURE must not still move the
# --- label -----------------------------------------------------------------
# 2026-09-16 fix, live incident: #1245 and #1256 both wedged with the
# marker route_to_advisor()/route_to_recut() are supposed to clear still on
# disk, EVEN THOUGH both functions already call state_merge's del() (the
# V102/its-twin fix above). The three tests above only prove the del()
# clears the field when state_merge SUCCEEDS. They say nothing about what
# happens when it fails -- and until this fix, every one of
# route_to_advisor()/route_to_recut()/give_up_on_issue() called it as a
# bare statement, trusting `set -e` to stop the label move on failure. That
# trust is misplaced: `set -e` is disabled for everything a function runs
# while the function itself is the condition of an if/while/&&/|| --
# run-advisor-batch.sh calls route_to_recut() (via apply_one_ruling) from
# exactly such a position (`if apply_one_ruling ...; then`), proven live by
# #1256. A malformed state file is the deterministic way to make
# state_merge actually fail here (its `state_read "$n" | jq -f filter`
# errors on unparseable JSON) without needing to reproduce the live race
# itself -- state_merge's own failure path doesn't care WHY the write
# failed, so this exercises the same guard the live incident needed.
UNCHECKED_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$UNCHECKED_HOME/model-policy.json"
mkdir -p "$UNCHECKED_HOME/state"
printf '{not valid json' > "$UNCHECKED_HOME/state/710001.json"
printf '{not valid json' > "$UNCHECKED_HOME/state/810001.json"
printf '{not valid json' > "$UNCHECKED_HOME/state/910001.json"
UNCHECKED_BIN="$(mktemp -d)"
UNCHECKED_GH_LOG="$UNCHECKED_HOME/gh.log"
: > "$UNCHECKED_GH_LOG"
cat > "$UNCHECKED_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$UNCHECKED_GH_LOG"
if [ "\$1 \${2:-}" = "issue view" ]; then
  printf '%s\n' '{"state":"OPEN","labels":[]}'
fi
exit 0
EOF
chmod +x "$UNCHECKED_BIN/gh"
UNCHECKED_STDERR="$UNCHECKED_HOME/stderr.log"
UNCHECKED_STDOUT="$UNCHECKED_HOME/stdout.log"
PATH="$UNCHECKED_BIN:$PATH" AGENT_HOME="$UNCHECKED_HOME" ZF_REPO="test/repo" bash -c '
  source "$0/lib.sh"
  route_to_advisor 710001; echo "route_to_advisor exit=$?"
  route_to_recut 810001; echo "route_to_recut exit=$?"
  give_up_on_issue 910001 "test reason"; echo "give_up_on_issue exit=$?"
' "$SCRIPT_DIR" > "$UNCHECKED_STDOUT" 2> "$UNCHECKED_STDERR"
UNCHECKED_STDOUT_CONTENT="$(cat "$UNCHECKED_STDOUT")"
UNCHECKED_STDERR_CONTENT="$(cat "$UNCHECKED_STDERR")"
UNCHECKED_GH_LOG_CONTENT="$(cat "$UNCHECKED_GH_LOG")"
rm -rf "$UNCHECKED_HOME" "$UNCHECKED_BIN"

assert_contains "route_to_advisor: returns non-zero when state_merge fails to clear the stale marker" \
  "$UNCHECKED_STDOUT_CONTENT" "route_to_advisor exit=1"
assert_contains "route_to_recut: returns non-zero when state_merge fails to clear the stale marker" \
  "$UNCHECKED_STDOUT_CONTENT" "route_to_recut exit=1"
assert_contains "give_up_on_issue: returns non-zero when state_merge fails to clear the stale marker" \
  "$UNCHECKED_STDOUT_CONTENT" "give_up_on_issue exit=1"

assert_eq "route_to_advisor: THE BUG THIS CLOSES -- a failed state_merge must not move the label (no gh issue edit for #710001)" \
  "" "$(grep "issue edit 710001" <<< "$UNCHECKED_GH_LOG_CONTENT")"
assert_eq "route_to_recut: THE BUG THIS CLOSES -- a failed state_merge must not move the label (no gh issue edit for #810001)" \
  "" "$(grep "issue edit 810001" <<< "$UNCHECKED_GH_LOG_CONTENT")"
assert_eq "give_up_on_issue: THE BUG THIS CLOSES -- a failed state_merge must not move the label (no gh issue edit for #910001)" \
  "" "$(grep "issue edit 910001" <<< "$UNCHECKED_GH_LOG_CONTENT")"

assert_contains "route_to_advisor reports its invalid-state failure" \
  "$UNCHECKED_STDERR_CONTENT" "issue_transition: invalid state JSON for #710001"
assert_contains "route_to_recut reports its invalid-state failure" \
  "$UNCHECKED_STDERR_CONTENT" "issue_transition: invalid state JSON for #810001"
assert_contains "give_up_on_issue reports its invalid-state failure" \
  "$UNCHECKED_STDERR_CONTENT" "issue_transition: invalid state JSON for #910001"

# --- the ladder: every leg that edits state labels heals them first -------
# (the 2026-09-15 zf-triage-1203 death: ALL_STATE_LABELS gained two labels
# only run-advisor.sh created, which cannot run before triage first applies
# one of them).
for f in run-triage.sh run-advisor.sh issue-pipeline.sh; do
  assert_eq "$f calls ensure_state_labels before any label edit" \
    "1" "$(grep -cE '^ensure_state_labels$' "$SCRIPT_DIR/$f")"
done

# --- ready-for-human and needs-owner are abolished human-decision terminals -
# 2026-09-15 maintainer ruling, verbatim: [...]
#  -- a state meaning "a human should look at this"
# becomes a place where work goes to die when no human is ever coming to
# look; a queue nobody is assigned to drain is not a queue. No code path
# under engine/ may ADD either label any more -- reading or removing
# them stays allowed (a human-applied label must still be handled). This
# used to be a single narrow check ("run-advisor.sh maps exactly one verdict
# (maintainer) to ready-for-human") back when maintainer was the one carved-out
# exception; that exception is gone too (folded into the guarded rung), so
# the guard widens to cover every file, every literal form that ends up in
# a `gh issue edit --add-label ...` call: the bare CLI flag, and the
# NEW_LABEL=/STATE= variables run-advisor.sh and run-triage.sh interpolate
# into their own `--add-label "$VAR"` calls.
for f in "$SCRIPT_DIR"/*.sh; do
  case "$(basename "$f")" in *.test.sh) continue ;; esac
  assert_false "$(basename "$f") never adds ready-for-human (--add-label)" \
    grep -qE -- '--add-label ready-for-human\b' "$f"
  assert_false "$(basename "$f") never assigns NEW_LABEL/STATE=ready-for-human" \
    grep -qE -- '(NEW_LABEL|STATE)=ready-for-human\b' "$f"
  assert_false "$(basename "$f") never adds needs-owner (--add-label)" \
    grep -qE -- '--add-label needs-owner\b' "$f"
  assert_false "$(basename "$f") never assigns NEW_LABEL/STATE=needs-owner" \
    grep -qE -- '(NEW_LABEL|STATE)=needs-owner\b' "$f"
done

# --- systemic environmental faults: ledger -> detection -> quarantine ------
# All pure over a throwaway AGENT_HOME with an explicit `now`, so nothing
# here waits, emails, or touches the real ledger. DRY_RUN is NOT set: the
# ledger and quarantine files must really be written to be read back.
EF_HOME="$(mktemp -d)"
EF_ENV="$EF_HOME/env"
: > "$EF_ENV"
EF_REPO="$EF_HOME/repo"
mkdir -p "$EF_REPO/engine"
# Fake gh for env_fault_repair's `gh api user` (never reaches GitHub).
EF_BIN="$(mktemp -d)"
cat > "$EF_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# `.name // .login` contains ".login" too -- match the name query first.
case "$*" in
  *"issue list"*) echo "601" ;;
  *".name"*) echo "Test Name" ;;
  *".login"*) echo "test-login" ;;
  *".id"*) echo "424242" ;;
  *) echo "" ;;
esac
EOF
chmod +x "$EF_BIN/gh"
# This fixture exercises a still-broken Docker environment.  A runner with
# Docker installed must not turn the quarantine test into a live probe.
cat > "$EF_BIN/docker" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$EF_BIN/docker"
cat > "$EF_BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit "${EF_NETWORK_PROBE_STATUS:-0}"
EOF
chmod +x "$EF_BIN/curl"
T0=1800000000
EF_OUT="$(
  PATH="$EF_BIN:$PATH" TEST_BIN="$EF_BIN" AGENT_HOME="$EF_HOME" AGENT_DRY_RUN=0 ENV_FAULT_LIB_DIR="$SCRIPT_DIR" ENV_FAULT_ENV_FILE="$EF_ENV" REPO="test/repo" EF_NETWORK_PROBE_STATUS=0 \
  ZF_REPO_DIR="$EF_REPO" ZF_ENGINE_DIR="$EF_REPO/engine" \
  ZF_GCLOUD_BIN=/nonexistent/gcloud bash -c '
    # No set -e here on purpose: this block OBSERVES non-zero return codes
    # (probe=2 "unknown", repair=1 "not allowlisted") as data.
    set +e
    set -uo pipefail
    source "$ENV_FAULT_LIB_DIR/lib.sh"
    t0='"$T0"'
    echo "systemic(empty)=$(env_fault_is_systemic env:x $t0 && echo yes || echo no)"
    record_env_fault env:test-gate:docker implement 101 "Could not find a working container runtime strategy" packages/shared "$t0"
    echo "systemic(one hit)=$(env_fault_is_systemic env:test-gate:docker $t0 && echo yes || echo no)"
    record_env_fault env:test-gate:docker implement 102 "Could not find a working container runtime strategy" packages/shared "$((t0 + 60))"
    echo "systemic(two issues)=$(env_fault_is_systemic env:test-gate:docker $((t0 + 120)) && echo yes || echo no)"
    echo "systemic(outside window)=$(env_fault_is_systemic env:test-gate:docker $((t0 + 7200)) && echo yes || echo no)"
    record_env_fault env:gh-api triage 201 "timeout" "" "$t0"
    record_env_fault env:gh-api triage 201 "timeout" "" "$((t0 + 10))"
    echo "systemic(same issue twice)=$(env_fault_is_systemic env:gh-api $((t0 + 20)) && echo yes || echo no)"
    record_env_fault env:gh-api triage 201 "timeout" "" "$((t0 + 20))"
    echo "systemic(same issue thrice)=$(env_fault_is_systemic env:gh-api $((t0 + 30)) && echo yes || echo no)"
    echo "latest_scope=$(env_fault_latest_scope env:test-gate:docker)"
    # attempts refund for implement only
    mkdir -p "$AGENT_HOME/state"; echo "{\"attempts\":2}" > "$AGENT_HOME/state/303.json"
    record_env_fault env:worktree-add implement 303 "x" "" "$t0"
    echo "refunded=$(jq -r .attempts "$AGENT_HOME/state/303.json")"
    echo "{\"attempts\":2}" > "$AGENT_HOME/state/304.json"
    record_env_fault env:worktree-add triage 304 "x" "" "$t0"
    echo "not_refunded_for_triage=$(jq -r .attempts "$AGENT_HOME/state/304.json")"
    # reconcile: docker signature is systemic -> quarantine scoped to the package
    reconcile_quarantines "$((t0 + 120))" 2>/dev/null
    echo "q_docker_exists=$([ -f "$(quarantine_file implement@packages/shared)" ] && echo yes || echo no)"
    echo "q_stagewide_implement_exists=$([ -f "$(quarantine_file implement)" ] && echo yes || echo no)"
    echo "q_triage_exists=$([ -f "$(quarantine_file triage)" ] && echo yes || echo no)"
    # Repeated GH read timeouts stay per-call while the independent API probe
    # succeeds; only a currently failing probe makes the shared fault systemic.
    record_env_fault env:network-timeout implement 501 "gh: read timed out twice: gh pr checks 1655" "" "$t0"
    record_env_fault env:network-timeout implement 502 "gh: read timed out twice: gh pr checks 1669" "" "$((t0 + 10))"
    reconcile_quarantines "$((t0 + 20))" 2>/dev/null
    echo "network_timeout_healthy_probe_quarantined=$([ -f "$(quarantine_file implement)" ] && echo yes || echo no)"
    export EF_NETWORK_PROBE_STATUS=28
    reconcile_quarantines "$((t0 + 30))" 2>/dev/null
    echo "network_timeout_failed_probe_quarantined=$([ -f "$(quarantine_file implement)" ] && echo yes || echo no)"
    export EF_NETWORK_PROBE_STATUS=0
    reconcile_quarantines "$((t0 + 40))" 2>/dev/null
    echo "network_timeout_recovery_lifted=$([ -f "$(quarantine_file implement)" ] && echo no || echo yes)"
    # dispatch decisions: the package is blocked, another package is free
    echo "shared_blocked=$(stage_dispatch_allowed implement "[\"packages/shared\"]" $((t0 + 130)) 2>/dev/null && echo no || echo yes)"
    echo "other_free=$(stage_dispatch_allowed implement "[\"packages/other\"]" $((t0 + 130)) 2>/dev/null && echo yes || echo no)"
    echo "triage_blocked=$(stage_dispatch_allowed triage "[]" $((t0 + 130)) 2>/dev/null && echo no || echo yes)"
    echo "advisor_free=$(stage_dispatch_allowed advisor "[]" $((t0 + 130)) 2>/dev/null && echo yes || echo no)"
    # A slice that stops before a job exists must not spend the canary.
    tq=$((t0 + 120))
    echo "canary_let_through=$(stage_dispatch_allowed triage "[]" $((tq + 16 * 60)) 2>/dev/null && echo yes || echo no)"
    (
    mkdir -p "$ZF_ENGINE_DIR"
    cat > "$ZF_ENGINE_DIR/run-triage.sh" <<"EOF"
#!/usr/bin/env bash
exit "${RUN_RC:-0}"
EOF
    cat > "$ZF_ENGINE_DIR/run-advisor.sh" <<"EOF"
#!/usr/bin/env bash
source "$ENV_FAULT_LIB_DIR/lib.sh"
eval "$(sed -n "/^web_advisor_provider_dispatch_question_async() {/,/^}/p" "$ENV_FAULT_LIB_DIR/providers/web-advisor-provider.sh")"
WEB_ADVISOR_PROVIDER_JOB_DIR="$AGENT_HOME/jobs"
WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS=600
web_advisor_provider_start_job_unit() { return 0; }
printf "question\n" > "$AGENT_HOME/question"
printf "%s" "$ZF_QUARANTINE_CANARY_SCOPES" | tr "\n" "," > "$ADVISOR_CHILD_SCOPES"
web_advisor_provider_dispatch_question_async child "$AGENT_HOME/question"
jq -r .canaries "$(quarantine_file advisor)" > "$ADVISOR_FIRST_CANARIES"
web_advisor_provider_dispatch_question_async child-reask "$AGENT_HOME/question"
jq -r .canaries "$(quarantine_file advisor)" > "$ADVISOR_REASK_CANARIES"
EOF
    chmod +x "$ZF_ENGINE_DIR/run-triage.sh" "$ZF_ENGINE_DIR/run-advisor.sh"
    ln -s run-triage.sh "$ZF_ENGINE_DIR/run-implement.sh"
    cat > "$TEST_BIN/systemd-run" <<"EOF"
#!/usr/bin/env bash
args=("$@"); script=-1
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == -E ]]; then next=$((i + 1)); [[ "${args[$next]}" != ZF_QUARANTINE_CANARY_SCOPES=* ]] || export "${args[$next]}"; fi
  [[ "${args[$i]}" != */run-triage.sh && "${args[$i]}" != */run-advisor.sh && "${args[$i]}" != */run-implement.sh ]] || { script=$i; break; }
done
(( script >= 0 )) || exit 97
[[ "${FAIL_SYSTEMD_LAUNCH:-0}" != 1 ]] || exit 1
exec "${args[@]:$script}"
EOF
    chmod +x "$TEST_BIN/systemd-run"
    eval "$(sed -n "/^dispatch() {/,/^}/p" "$ENV_FAULT_LIB_DIR/issue-pipeline.sh")"
    SCRIPT_DIR="$ENV_FAULT_LIB_DIR"
    eval "$(declare -f quarantine_mark_stage_dispatch_canaries | sed -e s/quarantine_mark_stage_dispatch_canaries/real_quarantine_mark_stage_dispatch_canaries/g)"
    MARK_LOG="$AGENT_HOME/mark-calls"
    quarantine_mark_stage_dispatch_canaries() { printf "%s\n" "$1" >> "$MARK_LOG"; real_quarantine_mark_stage_dispatch_canaries "$1" "$((tq + 16 * 60))"; }
    coord_issue_key() { printf "issue:%s\n" "$1"; }
    pipeline_claim_begin() { PIPELINE_CLAIM_KEY="issue:$1"; PIPELINE_CLAIM_STAGE="$2"; PIPELINE_CLAIM_UNIT="$3"; PIPELINE_CLAIM_OWNER=fixture; }
    coord_assert_owned() { return 0; }
    pipeline_claim_drop() { PIPELINE_CLAIM_KEY=""; PIPELINE_CLAIM_STAGE=""; PIPELINE_CLAIM_UNIT=""; PIPELINE_CLAIM_OWNER=""; }
    pipeline_claim_keep() { pipeline_claim_drop; }
    # This fixture needs the normal no-OOM result; issue-pipeline.test.sh covers the memory retry branch.
    consume_unit_memory_oom() { return 1; }
    record_env_fault() { :; }
    guarded_write() { "$@"; }
    UNIT_PREFIX_TRANSIENT=zf TRIAGE_RUNTIME_MAX_SEC=60 ADVISOR_RUNTIME_MAX_SEC=60 IMPLEMENT_RUNTIME_MAX_SEC=60
    PIPELINE_CLAIM_KEY="" PIPELINE_CLAIM_UNIT="" PIPELINE_CLAIM_STAGE="" PIPELINE_CLAIM_OWNER=""
    dispatch_status=0; RUN_RC=124; export RUN_RC; dispatch triage 929 || dispatch_status=$?
    echo "dispatch_124_status=$dispatch_status"
    echo "dispatch_124_mark_calls=$(wc -l < "$MARK_LOG" 2>/dev/null || echo 0)"
    echo "canary_overrun_unchanged=$(jq -e --argjson next "$((tq + QUARANTINE_CANARY_INITIAL_SECONDS))" ".canaries == 0 and .next_canary_at == \$next" "$(quarantine_file triage)" >/dev/null && echo yes || echo no)"
    echo "before_canary=$(quarantine_decision triage $((tq + 14 * 60)))"
    echo "canary_due=$(quarantine_decision triage $((tq + 16 * 60)))"
    quarantine_open advisor env:test-gate:advisor "d" 2 "$tq" 2>/dev/null
    quarantine_open advisor@packages/advisor-test env:test-gate:advisor "d" 2 "$tq" 2>/dev/null
    stage_dispatch_allowed triage "[]" $((tq + 16 * 60)) >/dev/null 2>&1
    stage_dispatch_allowed advisor "[\"packages/advisor-test\"]" $((tq + 16 * 60)) >/dev/null 2>&1
    ADVISOR_CHILD_SCOPES="$AGENT_HOME/advisor-child-scopes"
    ADVISOR_FIRST_CANARIES="$AGENT_HOME/advisor-first-canaries"
    ADVISOR_REASK_CANARIES="$AGENT_HOME/advisor-reask-canaries"
    export ADVISOR_CHILD_SCOPES ADVISOR_FIRST_CANARIES ADVISOR_REASK_CANARIES
    dispatch_status=0; dispatch advisor 930 || dispatch_status=$?
    echo "advisor_child_status=$dispatch_status"
    echo "advisor_child_scopes=$(cat "$ADVISOR_CHILD_SCOPES")"
    echo "advisor_child_triage_canaries=$(jq -r .canaries "$(quarantine_file triage)")"
    echo "advisor_child_stage_canaries=$(jq -r .canaries "$(quarantine_file advisor)")"
    echo "advisor_child_package_canaries=$(jq -r .canaries "$(quarantine_file advisor@packages/advisor-test)")"
    STAGE_DISPATCH_CANARY_SCOPES=""
    stage_dispatch_allowed triage "[]" $((tq + 16 * 60)) >/dev/null 2>&1
    echo "real_job_canaries_before=$(jq -r .canaries "$(quarantine_file triage)")"
    dispatch_status=0; RUN_RC=0; export RUN_RC; dispatch triage 931 || dispatch_status=$?
    echo "real_job_started=$(if [ "$dispatch_status" -eq 0 ]; then echo marked; else echo not-marked; fi)"
    echo "real_job_canaries_after=$(jq -r .canaries "$(quarantine_file triage)")"
    echo "second_same_tick=$(stage_dispatch_allowed triage "[]" $((tq + 16 * 60)) 2>/dev/null && echo yes || echo no)"
    echo "real_job_canaries=$(jq -r .canaries "$(quarantine_file triage)")"
    echo "next_canary_in=$(( $(jq -r .next_canary_at "$(quarantine_file triage)") - (tq + 16 * 60) ))"
    echo "advisor_reask_stage_canaries=$(cat "$ADVISOR_REASK_CANARIES")"
    echo "advisor_reask_first_canaries=$(cat "$ADVISOR_FIRST_CANARIES")"
    eval "$(sed -n "/^dispatch_advisor_batch() {/,/^}/p" "$ENV_FAULT_LIB_DIR/issue-pipeline.sh")"
    zf_advisor_batch_runner() { printf "%s\n" "$ZF_ENGINE_DIR/run-advisor.sh"; }
    agent_memory_floor_allows() { return 0; }; stage_unit_active() { return 1; }
    NEEDS_ADVISOR_IDS=""; ZF_ADVISOR_BATCH_UNIT_ENV=(); ADVISOR_RUNTIME_MAX_SEC=60; UNIT_PREFIX_TRANSIENT=zf
    dispatch_advisor_batch 1 "advisor,advisor@packages/advisor-test"; echo "advisor_batch_child_scopes=$(cat "$ADVISOR_CHILD_SCOPES")"
    # Trace requeue persistence, issue-pipeline launch, and scheduler bridge in one shell.
    now="$(date +%s)"; quarantine_open implement env:test-gate:requeue fixture 2 "$now" >/dev/null 2>&1; qf="$(quarantine_file implement)"
    jq --argjson now "$now" ".next_canary_at = \$now" "$qf" > "$qf.tmp" && mv "$qf.tmp" "$qf"
    printf "%s\n" "{\"attempts\":0,\"unit_memory_ooms\":{},\"run\":{\"conclusion\":{}}}" > "$AGENT_HOME/state/932.json"
    STAGE_DISPATCH_CANARY_SCOPES=""; quarantine_stage_canary_reserve implement
    state_merge 932 ".run.conclusion.canary_reserved_scopes = \"$(quarantine_canary_scope_list_for_stage implement)\""
    quarantine_stage_canary_forget_stage implement; implement_runs_since_last_hold_lift() { IMPLEMENT_REPEAT_RUN_COUNT=0; }
    RUN_RC=0; export RUN_RC; dispatch implement 932 || :
    ROOT="$ZF_REPO_DIR" SCHEDULER_AGENT_LIB="$ENV_FAULT_LIB_DIR/lib.sh" SCHEDULER_SCOPE_LIB_DIR="$ENV_FAULT_LIB_DIR/lib.d"; scheduler_issue_state() { state_read "$1"; }
    jqf() { command jq "$@"; }
    eval "$(sed -n "/^scheduler_mark_canary_after_worker_start() (/,/^)/p" "$ENV_FAULT_LIB_DIR/mac-autopilot/scheduler.d/dispatch.sh")"
    scheduler_bridge_status=0; scheduler_mark_canary_after_worker_start 932 || scheduler_bridge_status=$?
    echo "scheduler_bridge_status=$scheduler_bridge_status"
    echo "requeue_scheduler_canaries=$(jq -r .canaries "$qf")"; echo "requeue_scheduler_reservation=$(state_read 932 | jq -r ".run.conclusion.canary_reserved_scopes // empty")"
    state_merge 932 ".run.conclusion.canary_reserved_scopes = \"implement\""; STAGE_DISPATCH_CANARY_SCOPES=implement
    FAIL_SYSTEMD_LAUNCH=1; RUN_RC=0; export FAIL_SYSTEMD_LAUNCH RUN_RC; dispatch implement 932 || :
    unset FAIL_SYSTEMD_LAUNCH
    echo "failed_launch_canaries=$(jq -r .canaries "$qf")"; echo "failed_launch_memory_reserved=$(quarantine_stage_canary_pending implement && echo yes || echo no)"
    echo "failed_launch_state_reserved=$(state_read 932 | jq -r ".run.conclusion.canary_reserved_scopes // empty")"
    )
    # canary survived (no new fault within grace) -> lifted
    reconcile_quarantines "$((tq + 16 * 60 + 31 * 60))" 2>/dev/null
    echo "triage_lifted=$([ -f "$(quarantine_file triage)" ] && echo no || echo yes)"
    # canary failed (a new fault after the canary) -> stays
    quarantine_open implement@packages/shared env:test-gate:docker "d" 2 "$((t0 + 120))" 2>/dev/null || true
    quarantine_mark_canary implement@packages/shared "$((t0 + 20 * 60))"
    record_env_fault env:test-gate:docker implement 105 "Could not find a working container runtime strategy" packages/shared "$((t0 + 25 * 60))"
    reconcile_quarantines "$((t0 + 20 * 60 + 31 * 60))" 2>/dev/null
    echo "docker_still_quarantined=$([ -f "$(quarantine_file implement@packages/shared)" ] && echo yes || echo no)"
    # repair: git identity is derivable, appended once, then the probe passes and lifts
    record_env_fault env:git-identity implement 401 "unset" "" "$t0"
    record_env_fault env:git-identity implement 402 "unset" "" "$((t0 + 5))"
    echo "probe_before=$(env_fault_probe env:git-identity && echo pass || echo fail)"
    reconcile_quarantines "$((t0 + 10))" 2>/dev/null
    echo "identity_lifted=$([ -f "$(quarantine_file implement)" ] && echo no || echo yes)"
    echo "env_has_name=$(grep -c "^ZF_AGENT_GIT_USER_NAME=Test Name$" "$ENV_FAULT_ENV_FILE")"
    echo "env_has_noreply=$(grep -c "^ZF_AGENT_GIT_USER_EMAIL=424242+test-login@users.noreply.github.com$" "$ENV_FAULT_ENV_FILE")"
    echo "probe_after=$(env_fault_probe env:git-identity && echo pass || echo fail)"
    # repair never overwrites a human-set value
    reconcile_quarantines "$((t0 + 20))" 2>/dev/null
    echo "env_lines=$(wc -l < "$ENV_FAULT_ENV_FILE")"
    # unknown signature: no probe (2), no repair (1)
    rc=0; env_fault_probe env:nothing-known || rc=$?; echo "probe_unknown_rc=$rc"
    rc=0; env_fault_repair env:nothing-known || rc=$?; echo "repair_unknown_rc=$rc"
    echo "key_sanitized=$(env_fault_key "env:test-gate:../../x y")"
    ' 2>&1
  )"
rm -rf "$EF_HOME" "$EF_BIN"
ef() { printf '%s\n' "$EF_OUT" | grep -m1 "^$1=" | cut -d= -f2-; }
assert_eq "env_fault_is_systemic: nothing recorded is not systemic" "no" "$(ef 'systemic(empty)')"
assert_eq "env_fault_is_systemic: one hit is not systemic" "no" "$(ef 'systemic(one hit)')"
assert_eq "env_fault_is_systemic: two distinct issues inside the window is" "yes" "$(ef 'systemic(two issues)')"
assert_eq "env_fault_is_systemic: the same hits outside the window are not" "no" "$(ef 'systemic(outside window)')"
assert_eq "env_fault_is_systemic: one issue twice is not yet" "no" "$(ef 'systemic(same issue twice)')"
assert_eq "env_fault_is_systemic: one issue three times is (re-dispatched into the same wall)" "yes" "$(ef 'systemic(same issue thrice)')"
assert_eq "record_env_fault: scope carries stage@package" "implement@packages/shared" "$(ef latest_scope)"
assert_eq "record_env_fault: refunds the dispatch-time attempt for implement (V79)" "1" "$(ef refunded)"
assert_eq "record_env_fault: does not touch attempts for other stages (they never bumped)" "2" "$(ef not_refunded_for_triage)"
assert_eq "reconcile: a systemic package-scoped fault quarantines that package, not the stage" "yes" "$(ef q_docker_exists)"
assert_eq "reconcile: repeated read timeouts with a healthy GitHub probe stay per-call" "no" "$(ef network_timeout_healthy_probe_quarantined)"
assert_eq "reconcile: repeated network timeouts plus a failed GitHub probe quarantine the stage" "yes" "$(ef network_timeout_failed_probe_quarantined)"
assert_eq "reconcile: recovered GitHub probe lifts the network quarantine" "yes" "$(ef network_timeout_recovery_lifted)"
assert_eq "reconcile: ...and NOT implement stage-wide" "no" "$(ef q_stagewide_implement_exists)"
assert_eq "reconcile: a systemic stage-wide fault quarantines the stage" "yes" "$(ef q_triage_exists)"
assert_eq "stage_dispatch_allowed: a ticket touching the quarantined package is blocked" "yes" "$(ef shared_blocked)"
assert_eq "stage_dispatch_allowed: a ticket in another package proceeds (quarantine the class, not the queue)" "yes" "$(ef other_free)"
assert_eq "stage_dispatch_allowed: the quarantined stage is blocked" "yes" "$(ef triage_blocked)"
assert_eq "stage_dispatch_allowed: an unrelated stage keeps running" "yes" "$(ef advisor_free)"
assert_eq "quarantine_decision: open before the first canary is due" "open" "$(ef before_canary)"
assert_eq "quarantine_decision: canary due after 15 minutes" "canary" "$(ef canary_due)"
assert_eq "a canary slice overrun before job creation leaves its schedule unchanged" "yes" "$(ef canary_overrun_unchanged)"
assert_eq "dispatch() sees the run-triage stub return 124" "1" "$(ef dispatch_124_status)"
assert_eq "dispatch() does not mark a canary when run-triage returns 124" "0" "$(ef dispatch_124_mark_calls)"
assert_eq "stage_dispatch_allowed: the canary goes through" "yes" "$(ef canary_let_through)"
assert_eq "stage dispatch charges the canary after a real job starts" "marked" "$(ef real_job_started)"
assert_eq "stage_dispatch_allowed: a second candidate the same tick does not" "no" "$(ef second_same_tick)"
assert_eq "advisor child receives only advisor canary scopes" "advisor,advisor@packages/advisor-test" "$(ef advisor_child_scopes)"
assert_eq "advisor child leaves a reserved triage scope uncharged" "0" "$(ef advisor_child_triage_canaries)"
assert_eq "advisor child marks its stage canary" "1" "$(ef advisor_child_stage_canaries)"
assert_eq "advisor child marks its package canary" "1" "$(ef advisor_child_package_canaries)"
assert_eq "advisor re-ask does not charge its inherited canary again" "1" "$(ef advisor_reask_stage_canaries)"
assert_eq "advisor first job charges its canary once" "1" "$(ef advisor_reask_first_canaries)"
assert_eq "a real job starts with canaries at zero before the mark" "0" "$(ef real_job_canaries_before)"
assert_eq "a real job start increments the canary count once" "1" "$(ef real_job_canaries_after)"
assert_eq "quarantine_mark_canary: the next canary waits twice as long" "1800" "$(ef next_canary_in)"
assert_eq "same-process requeue and issue-pipeline plus scheduler charge one canary" "1" "$(ef requeue_scheduler_canaries)"
assert_eq "scheduler consumes the persisted canary reservation" "" "$(ef requeue_scheduler_reservation)"
assert_eq "scheduler canary bridge runs successfully in its fixture" "0" "$(ef scheduler_bridge_status)"
assert_eq "failed issue-pipeline launch leaves the canary uncharged" "1" "$(ef failed_launch_canaries)"
assert_eq "failed issue-pipeline launch clears in-memory canary reservation" "no" "$(ef failed_launch_memory_reserved)"
assert_eq "failed issue-pipeline launch clears persisted canary reservation" "" "$(ef failed_launch_state_reserved)"
assert_eq "advisor batch passes its reserved scopes to the launched runner" "advisor,advisor@packages/advisor-test" "$(ef advisor_batch_child_scopes)"
PROVIDER_DISPATCH_BODY="$(sed -n '/^web_advisor_provider_dispatch_question_async() {/,/^}/p' "$SCRIPT_DIR/providers/web-advisor-provider.sh")"
assert_contains "advisor provider uses the shared canary mark" "$PROVIDER_DISPATCH_BODY" 'quarantine_mark_canary_scope_list'
assert_contains "advisor provider reports a failed canary mark" "$PROVIDER_DISPATCH_BODY" 'quarantine canary mark failed'
QUARANTINE_MARK_BODY="$(sed -n '/^quarantine_mark_canary() {/,/^}/p' "$SCRIPT_DIR/lib.d/quarantine.sh")"
assert_contains "canary read-modify-write takes a per-scope flock" "$QUARANTINE_MARK_BODY" 'flock -x'
BLOCKER_REQUEUE_BODY="$(sed -n '/^reconcile_blocking_issue_root() {/,/^}/p' "$SCRIPT_DIR/lib.d/blockers.sh")"
assert_contains "blocker requeue persists its canary reservation" "$BLOCKER_REQUEUE_BODY" 'canary_reserved_scopes'
assert_contains "blocker requeue clears its in-memory reservation after persistence" "$BLOCKER_REQUEUE_BODY" 'quarantine_stage_canary_forget_stage implement'
assert_contains "scheduler consumes blocker reservations in the worker-start bridge" "$(cat "$SCRIPT_DIR/mac-autopilot/scheduler.d/dispatch.sh")" 'quarantine_mark_canary_scope_list "$scope"'
assert_eq "reconcile: a canary with no new fault inside the grace period lifts the quarantine" "yes" "$(ef triage_lifted)"
assert_eq "reconcile: a canary followed by the same fault keeps it" "yes" "$(ef docker_still_quarantined)"
assert_eq "env_fault_probe: git identity fails against an env file without the keys" "fail" "$(ef probe_before)"
assert_eq "reconcile: the allowlisted git-identity repair runs, the probe passes, the quarantine lifts" "yes" "$(ef identity_lifted)"
assert_eq "env_fault_repair: writes the account name to the EnvironmentFile" "1" "$(ef env_has_name)"
assert_eq "env_fault_repair: writes GitHub's own noreply form, never a real mailbox" "1" "$(ef env_has_noreply)"
assert_eq "env_fault_probe: passes afterwards" "pass" "$(ef probe_after)"
assert_eq "env_fault_repair: idempotent -- a second reconcile appends nothing" "2" "$(ef env_lines)"
assert_eq "env_fault_probe: an unknown signature has no probe (canary only)" "2" "$(ef probe_unknown_rc)"
assert_eq "env_fault_repair: an unknown signature has no repair (the allowlist is closed)" "1" "$(ef repair_unknown_rc)"
assert_eq "env_fault_key: a signature cannot escape the ledger directory (no slash survives; a dot is harmless inside one file name)" "env:test-gate:.._.._x_y" "$(ef key_sanitized)"

OPS_PAUSE_HOME="$(mktemp -d)"
OPS_PAUSE_OUT="$(AGENT_HOME="$OPS_PAUSE_HOME" AGENT_DRY_RUN=0 OPS_LIB_DIR="$SCRIPT_DIR" bash -c '
  set +e
  set -uo pipefail
  source "$OPS_LIB_DIR/lib.sh"
  quarantine_open advisor ops:advisor-dispatch-pause "operator pause" 1 1800000000
  echo "ops_pause_decision=$(quarantine_decision advisor 1900000000)"
' 2>&1)"
rm -rf "$OPS_PAUSE_HOME"
assert_contains "operator pause quarantine never admits a timed canary" "$OPS_PAUSE_OUT" 'ops_pause_decision=open'

# 2026-11-04: a tick runs the engine it started from for its whole run (the
# units pin ZF_ENGINE_DIR to one immutable version directory), so a canary
# dispatched after an engine-live swap tests the retired engine. A due canary
# defers -- stays open, canaries/next_canary_at untouched -- until a tick on
# the engine engine-live now selects; with no engine-live at all, canaries
# keep today's behaviour.
CANARY_PIN_HOME="$(mktemp -d)"
mkdir -p "$CANARY_PIN_HOME/engine-versions/dbfe584-3b86/engine" \
  "$CANARY_PIN_HOME/engine-versions/c5e34384e4e2/engine" "$CANARY_PIN_HOME/repo/engine"
ln -sfn -- "$CANARY_PIN_HOME/engine-versions/c5e34384e4e2/engine" "$CANARY_PIN_HOME/engine-live"
CANARY_PIN_OUT="$(AGENT_HOME="$CANARY_PIN_HOME" ZF_REPO_DIR="$CANARY_PIN_HOME/repo" \
  ZF_ENGINE_DIR="$CANARY_PIN_HOME/engine-versions/dbfe584-3b86/engine" \
  CANARY_PIN_NEW_ENGINE="$CANARY_PIN_HOME/engine-versions/c5e34384e4e2/engine" \
  CANARY_PIN_LIB_DIR="$SCRIPT_DIR" bash -c '
  set +e
  set -uo pipefail
  source "$CANARY_PIN_LIB_DIR/lib.sh"
  t0=1800000000
  quarantine_open advisor env:test-gate:advisor "advisor gate down" 2 "$t0" 2>/dev/null
  echo "old_engine_decision=$(quarantine_decision advisor $((t0 + 16 * 60)))"
  echo "old_engine_canaries=$(jq -r .canaries "$(quarantine_file advisor)")"
  echo "old_engine_next_canary_at=$(jq -r .next_canary_at "$(quarantine_file advisor)")"
  ZF_ENGINE_DIR="$CANARY_PIN_NEW_ENGINE"
  echo "new_engine_decision=$(quarantine_decision advisor $((t0 + 16 * 60)) 2>/dev/null)"
  rm -f -- "$AGENT_HOME/engine-live"
  echo "no_live_decision=$(quarantine_decision advisor $((t0 + 17 * 60)))"
' 2>&1)"
rm -rf "$CANARY_PIN_HOME"
assert_contains "engine pin: a due canary defers while this tick's engine is not engine-live" "$CANARY_PIN_OUT" "old_engine_decision=open"
assert_contains "engine pin: a deferred canary advances neither canaries nor next_canary_at" "$CANARY_PIN_OUT" "old_engine_canaries=0"
assert_contains "engine pin: next_canary_at keeps the original schedule" "$CANARY_PIN_OUT" "old_engine_next_canary_at=$((1800000000 + 15 * 60))"
assert_contains "engine pin: the deferral log names both engine versions" "$CANARY_PIN_OUT" "this tick runs engine dbfe584-3b86, engine-live is c5e34384e4e2"
assert_contains "engine pin: the next tick, on the live engine, takes the canary" "$CANARY_PIN_OUT" "new_engine_decision=canary"
assert_contains "engine pin: no engine-live keeps today's canary behaviour" "$CANARY_PIN_OUT" "no_live_decision=canary"
assert_contains "engine pin: an unresolvable engine-live is logged, not fatal" "$CANARY_PIN_OUT" "engine-live cannot be resolved"

CAPACITY_PROBE_HOME="$(mktemp -d)"
CAPACITY_PROBE_OUT="$(AGENT_HOME="$CAPACITY_PROBE_HOME" AGENT_DRY_RUN=0 CAPACITY_LIB_DIR="$SCRIPT_DIR" bash -c '
  set +e
  set -uo pipefail
  source "$CAPACITY_LIB_DIR/lib.sh"
  mkdir -p "$AGENT_HOME/bin"
  printf "%s\n" "#!/usr/bin/env bash" "printf \"Filesystem 1K-blocks Used Available Use%% Mounted\\n/dev/fake %s 1 %s 1%% /\\n\" \"\${FAKE_CIHOST_TOTAL_KB:-1000000000}\" \"\${FAKE_CIHOST_AVAIL_KB:-125829120}\"" > "$AGENT_HOME/bin/ssh"
  chmod +x "$AGENT_HOME/bin/ssh"
  export PATH="$AGENT_HOME/bin:$PATH"
  export FAKE_CIHOST_TOTAL_KB=1258291200 FAKE_CIHOST_AVAIL_KB=104857600
  rc=0; env_fault_probe env:ci-runner-capacity || rc=$?; echo "ci_capacity_at_build_warning_rc=$rc"
  rc=0; env_fault_probe env:build-capacity || rc=$?; echo "build_capacity_at_warning_rc=$rc"
  export FAKE_CIHOST_AVAIL_KB=103809024
  rc=0; env_fault_probe env:ci-runner-capacity || rc=$?; echo "ci_capacity_below_build_warning_rc=$rc"
  rc=0; env_fault_probe env:build-capacity || rc=$?; echo "build_capacity_low_rc=$rc"
  export FAKE_CIHOST_AVAIL_KB=40894463
  rc=0; env_fault_probe env:ci-runner-capacity || rc=$?; echo "ci_capacity_below_shared_floor_rc=$rc"
  quarantine_open implement env:ci-runner-capacity "CI runner capacity low" 1 1800000000
  quarantine_open release env:build-capacity "build capacity low" 1 1800000000
  reconcile_quarantines 1800000021
  echo "capacity_quarantines_stay=$([ -f "$(quarantine_file implement)" ] && [ -f "$(quarantine_file release)" ] && echo yes || echo no)"
  echo "capacity_canary_blocked=$(stage_dispatch_allowed release "[]" 1800003600 >/dev/null 2>&1 && echo no || echo yes)"
  export FAKE_CIHOST_AVAIL_KB=125829120
  reconcile_quarantines 1800000022
  if [ -f "$(quarantine_file implement)" ] || [ -f "$(quarantine_file release)" ]; then echo "capacity_quarantines_lift=no"; else echo "capacity_quarantines_lift=yes"; fi
  stage_dispatch_allowed release "[]" 1800000023 >/dev/null 2>&1 && echo "capacity_dispatch_resumes=yes" || echo "capacity_dispatch_resumes=no"
' 2>&1)"
rm -rf "$CAPACITY_PROBE_HOME"
assert_contains "CI capacity probe uses the shared capped floor at the 100 GiB build warning" "$CAPACITY_PROBE_OUT" 'ci_capacity_at_build_warning_rc=0'
assert_contains "CI capacity probe remains clear below the separate build warning" "$CAPACITY_PROBE_OUT" 'ci_capacity_below_build_warning_rc=0'
assert_contains "build capacity probe passes at 100 GiB free" "$CAPACITY_PROBE_OUT" 'build_capacity_at_warning_rc=0'
assert_contains "build capacity probe waits below 100 GiB warning" "$CAPACITY_PROBE_OUT" 'build_capacity_low_rc=1'
assert_contains "CI capacity probe blocks below the shared capped floor" "$CAPACITY_PROBE_OUT" 'ci_capacity_below_shared_floor_rc=1'
assert_contains "capacity quarantine stays open below stage gates" "$CAPACITY_PROBE_OUT" 'capacity_quarantines_stay=yes'
assert_contains "capacity stage quarantine never admits timed canary" "$CAPACITY_PROBE_OUT" 'capacity_canary_blocked=yes'
assert_contains "capacity probes automatically lift both quarantines after cihost capacity recovers" "$CAPACITY_PROBE_OUT" 'capacity_quarantines_lift=yes'
assert_contains "release dispatch resumes automatically after capacity recovery" "$CAPACITY_PROBE_OUT" 'capacity_dispatch_resumes=yes'

MAIN_CI_QUARANTINE_HOME="$(mktemp -d)"
MAIN_CI_QUARANTINE_OUT="$(AGENT_HOME="$MAIN_CI_QUARANTINE_HOME" bash -c '
  set -euo pipefail
  source "$0/lib.sh"
  REPO=test/repo
  mkdir -p "$AGENT_HOME/bin"
  cat > "$AGENT_HOME/bin/gh" <<\GH
#!/usr/bin/env bash
[[ "${MAIN_CI_CASE:-}" != lookup-failed ]] || exit 1
case "${1:-} ${2:-}" in
  "api repos/test/repo/git/ref/heads/main")
    echo "{\"object\":{\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}" ;;
  "api repos/test/repo/actions/runs?head_sha="*)
    if [[ "$MAIN_CI_CASE" == green ]]; then conclusion=success; else conclusion=failure; fi
    printf "{\"workflow_runs\":[{\"id\":7,\"run_attempt\":1,\"event\":\"push\",\"head_branch\":\"main\",\"head_sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"path\":\".github/workflows/ci.yml\",\"status\":\"completed\",\"conclusion\":\"%s\",\"created_at\":\"2026-10-05T01:00:00Z\"}]}\\n" "$conclusion" ;;
  "api repos/test/repo/actions/runs/7/jobs?per_page=100&page=1")
    echo "{\"jobs\":[{\"name\":\"Postsubmit validate\",\"status\":\"completed\",\"conclusion\":\"success\"},{\"name\":\"NUL bytes & lone negative assertions\",\"status\":\"completed\",\"conclusion\":\"success\"}]}" ;;
  *) exit 98 ;;
esac
GH
  chmod +x "$AGENT_HOME/bin/gh"
  PATH="$AGENT_HOME/bin:$PATH"; export PATH
  ZF_ENGINE_DIR="$AGENT_HOME/engine"; export ZF_ENGINE_DIR
  mkdir -p "$ZF_ENGINE_DIR/night"
  printf "%s\n" "#!/usr/bin/env bash" "exit 0" > "$ZF_ENGINE_DIR/night/main-ci-recovery.sh"
  chmod +x "$ZF_ENGINE_DIR/night/main-ci-recovery.sh"
  gh() { command gh "$@"; }
  for scenario in red green lookup-failed; do
    MAIN_CI_CASE="$scenario"
    export MAIN_CI_CASE
    QUARANTINE_DIR="$AGENT_HOME/quarantine-$scenario"
    ENV_FAULT_DIR="$AGENT_HOME/faults-$scenario"
    record_env_fault env:main-ci-red implement 991001 "main push failed" "" 1800000000 0
    quarantine_open implement env:main-ci-red "main push failed" 1 1800000000
    echo "$scenario-before=$(quarantine_decision implement 1800000100)"
    reconcile_quarantines 1800000100
    echo "$scenario-after=$([ -f "$(quarantine_file implement)" ] && echo open || echo lifted)"
  done
' "$SCRIPT_DIR" 2>&1)"
rm -rf "$MAIN_CI_QUARANTINE_HOME"
ANSI_FAIL_IDS="$(bash -c 'source "$0/lib.sh"; ci_failed_test_ids "$(printf "job\tstep\t2026-10-05T00:06:24Z \033[41m\033[1m FAIL \033[22m\033[49m tests/a.test.ts\033[2m > \033[22msuite > case\n")"' "$SCRIPT_DIR" 2>/dev/null)"
assert_eq "failed test ids read through the runner colour codes in GitHub job logs" $'vitest\ttests/a.test.ts > suite > case' "$ANSI_FAIL_IDS"
assert_contains "main-red quarantine does not admit timed canaries" "$MAIN_CI_QUARANTINE_OUT" 'red-before=open'
assert_contains "main-red quarantine stays while main CI is not green" "$MAIN_CI_QUARANTINE_OUT" 'red-after=open'
assert_contains "main-red quarantine lifts after newest completed main CI succeeds" "$MAIN_CI_QUARANTINE_OUT" 'green-after=lifted'
assert_contains "main-red quarantine stays closed when verdict lookup fails" "$MAIN_CI_QUARANTINE_OUT" 'lookup-failed-after=open'

# #1608: opening/lifting/reopening one quarantine inside the notification
# window is one internal notice per incident, never a maintainer email.
QUARANTINE_FLAP_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$QUARANTINE_FLAP_HOME/model-policy.json"
QUARANTINE_FLAP_OUT="$(
  AGENT_HOME="$QUARANTINE_FLAP_HOME" bash -c '
    set -uo pipefail
    source "$0/lib.sh"
    : > "$AGENT_HOME/mails"
    notify_maintainer() { printf "%s\\n" "$1" >> "$AGENT_HOME/mails"; }
    quarantine_open implement env:test-gate:docker "docker unavailable" 2 1000
    qfile="$(quarantine_file implement)"
    echo "QUARANTINE-OPEN:$([ -f "$qfile" ] && echo yes || echo no)"
    quarantine_lift implement "probe passed" 1100
    echo "QUARANTINE-LIFTED:$([ ! -f "$qfile" ] && echo yes || echo no)"
    quarantine_open implement env:test-gate:docker "docker unavailable" 2 1200
    quarantine_lift implement "probe passed" 1300
    echo "QUARANTINE-MAILS:$(cat "$AGENT_HOME/mails" 2>/dev/null | wc -l)"
    echo "QUARANTINE-NOTICES:$(grep -c . "$AGENT_HOME/supervisor-inbox" 2>/dev/null || true)"
    echo "QUARANTINE-INBOX:$(cat "$AGENT_HOME/supervisor-inbox" 2>/dev/null || true)"
  ' "$SCRIPT_DIR" 2>&1
)"
rm -rf "$QUARANTINE_FLAP_HOME"
assert_contains "#1608: repeated quarantine edges inside one window never email the maintainer" \
  "$QUARANTINE_FLAP_OUT" "QUARANTINE-MAILS:0"
assert_contains "#1608: repeated quarantine edges queue one supervisor notice" \
  "$QUARANTINE_FLAP_OUT" "QUARANTINE-NOTICES:1"
assert_contains "#1608: quarantine notice names scope and edge" \
  "$QUARANTINE_FLAP_OUT" "pipeline-quarantine scope=implement edge=open"
# --- (b2-stored): the stored-verdict resume advisor candidate source -------
# (2026-09-19, advisor execution locking task; ONE owning pool since
# 2026-11-04 -- see issue-pipeline.sh's ownership comment). No dynamic harness
# exists for issue-pipeline.sh's own dispatch loop (systemd-run, live gh
# calls) -- same level of testing already established for this file just above
# (DISPATCH_BODY/STAGE_ACTIVE_LINE, further down) and the ROUTE_TEST_HOME
# fixture above, which instead runs the underlying primitive
# (advisor_pending_orphan_candidates itself) directly and for real -- see
# that function's own dedicated tests near advisor_current_brief_md's,
# above. advisor-stored-verdict.test.sh runs the filter+pool pair itself
# against fixtures.
# This recovery path only resumes an already-produced verdict; changed input
# is returned to the batch queue by run-advisor.sh.
STORED_VERDICT_LOOP_BODY="$(sed -n '/^advisor_dispatch_stored_verdict_pool() {/,/^}$/p' "$SCRIPT_DIR/issue-pipeline.sh")"
assert_true "issue-pipeline.sh: the (b2-stored) resume pool is actually present (fixture sanity check)" \
  test -n "$STORED_VERDICT_LOOP_BODY"
assert_contains "...calls advisor_pending_orphan_candidates() as its candidate source" \
  "$STORED_VERDICT_LOOP_BODY" 'for next_verdict in $(advisor_pending_orphan_candidates)'
assert_contains "...dedups against the SAME needs-advisor id list the ordinary loop already fetched (never a fresh gh query per candidate)" \
  "$STORED_VERDICT_LOOP_BODY" 'grep -qx "$next_verdict" <<< "$NEEDS_ADVISOR_IDS" && continue'
assert_contains "...refuses to resume a verdict past its age bound or after a failed apply, and discards it instead" \
  "$STORED_VERDICT_LOOP_BODY" 'advisor_discard_stored_verdict "$next_verdict" "$verdict_disposition"'
assert_contains "...still respects is_on_hold" "$STORED_VERDICT_LOOP_BODY" 'is_on_hold "$next_verdict" && continue'
assert_contains "...still respects stage_unit_active(advisor)" "$STORED_VERDICT_LOOP_BODY" 'stage_unit_active advisor "$next_verdict" && continue'
assert_contains "...still respects stage_dispatch_allowed(advisor) and records quarantined wait" \
  "$STORED_VERDICT_LOOP_BODY" 'if ! stage_dispatch_allowed advisor; then'
assert_contains "...records why the advisor rung waits" "$STORED_VERDICT_LOOP_BODY" 'record_advisor_decision skipped quarantine'
assert_contains "...dispatches with resume-only mode, so stale input returns to the batch queue" \
  "$STORED_VERDICT_LOOP_BODY" 'dispatch advisor "$next_verdict" -E ADVISOR_RESUME_ONLY=1'
assert_contains "...breaks out once the shared advisor_slots cap is exhausted" \
  "$STORED_VERDICT_LOOP_BODY" '[ "$advisor_slots" -gt 0 ] || break'
assert_contains "...decrements the shared \$advisor_slots cap" \
  "$STORED_VERDICT_LOOP_BODY" 'advisor_slots=$((advisor_slots - 1))'
assert_eq "exactly ONE pool owns stored-verdict resumes (the retired orphan + roadmap-parent-pending pair deadlocked #5298/#5302)" \
  "1" "$(grep -cF 'for next_verdict in $(advisor_pending_orphan_candidates)' "$SCRIPT_DIR/issue-pipeline.sh" || true)"

POLL_LOOP_BODY="$(sed -n '/^advisor_dispatch_pending_job_pool() {/,/^}$/p' "$SCRIPT_DIR/issue-pipeline.sh")"
assert_true "issue-pipeline.sh: the pending-web-advisor-provider poll loop is present (fixture sanity check)" \
  test -n "$POLL_LOOP_BODY"
assert_contains "...takes only local web-advisor-provider job markers already owned by advisor candidates" \
  "$POLL_LOOP_BODY" 'for next_poll in $ADVISOR_PENDING_JOB_IDS'
assert_contains "...still honors the maintainer on-hold kill switch" \
  "$POLL_LOOP_BODY" 'is_on_hold "$next_poll" && continue'
assert_contains "...still honors an already-active per-ticket advisor unit" \
  "$POLL_LOOP_BODY" 'stage_unit_active advisor "$next_poll" && continue'
assert_contains "...re-dispatches through the existing advisor unit path so run-advisor.sh polls, not a new web call" \
  "$POLL_LOOP_BODY" 'dispatch advisor "$next_poll"'
assert_not_contains "...does not run stage_dispatch_allowed: polling an existing job is not a new canary call" \
  "$POLL_LOOP_BODY" 'stage_dispatch_allowed advisor'
assert_eq "fresh needs-advisor questions have no per-ticket dispatch path" \
  "0" "$(grep -cF 'dispatch advisor "$next_advisor"' "$SCRIPT_DIR/issue-pipeline.sh" || true)"
assert_eq "the scheduler has no ordinary per-ticket advisor pool" \
  "0" "$(grep -cF 'advisor_dispatch_ordinary_pool' "$SCRIPT_DIR/issue-pipeline.sh" || true)"
assert_contains "stale stored orphan verdicts are re-queued instead of re-asked singly" \
  "$(sed -n '/^if \[ "\${ADVISOR_RESUME_ONLY:-0}" = "1" \]/,/^fi$/p' "$SCRIPT_DIR/run-advisor.sh")" \
  'route_to_advisor "$N"'
assert_eq "run-advisor.sh routes all three environmental fault exits through advisor classification" \
  "3" "$(awk '/^[[:space:]]*record_web_advisor_provider_fault / { n++ } END { print n + 0 }' "$SCRIPT_DIR/run-advisor.sh")"
assert_eq "run-advisor.sh has no direct bare advisor signature left" \
  "0" "$(awk '/^[[:space:]]*record_env_fault env:web-advisor-provider/ { n++ } END { print n + 0 }' "$SCRIPT_DIR/run-advisor.sh")"

# Pending polls, fresh batch questions, and stored-verdict recovery have
# separate scheduler paths; no capacity or systemd unit contract changed.

# --- spend ledger remains accounting-only; model comes from policy --------
PM_HOME="$(mktemp -d)"
PM_T0=1800000000
PM_OUT="$(
  AGENT_HOME="$PM_HOME" REPO="test/repo" ZF_GCLOUD_BIN=/nonexistent/gcloud bash -c '
    set -uo pipefail
    source "$0/lib.sh"
    t0='"$PM_T0"'
    record_premium_spend review "$(model_policy identity work)" 2 "" "$t0" 714051
    record_premium_spend advisor-batch "$(model_policy identity advisor)" batch:7 "" "$t0" "" "advisor consulted"
    echo "ledger_line_count=$(wc -l < "$(spend_file_for_day "$t0")")"
    echo "ledger_model=$(sed -n "1p" "$(spend_file_for_day "$t0")" | cut -f3)"
    echo "ledger_tokens=$(sed -n "1p" "$(spend_file_for_day "$t0")" | cut -f6)"
    echo "ledger_fallback=$(sed -n "2p" "$(spend_file_for_day "$t0")" | cut -f7)"
    echo "quota_429_status=$(premium_call_is_quota_refused "{\"api_error_status\":429}" 1 && echo yes || echo no)"
    echo "quota_text=$(premium_call_is_quota_refused "rate limit exceeded, try again later" 1 && echo yes || echo no)"
    echo "genuine_error=$(premium_call_is_quota_refused "{\"is_error\":true,\"result\":\"invalid json schema in response\"}" 1 && echo yes || echo no)"
  ' "$SCRIPT_DIR" 2>&1
)"
rm -rf "$PM_HOME"
pm() { printf '%s\n' "$PM_OUT" | grep -m1 "^$1=" | cut -d= -f2-; }
assert_eq "spend ledger records only role-resolved model identities" "2" "$(pm ledger_line_count)"
assert_contains "spend ledger records the configured work identity" "$(pm ledger_model)" "$POLICY_WORK_IDENTITY"
assert_eq "spend ledger records measured token count" "714051" "$(pm ledger_tokens)"
assert_eq "spend ledger preserves the optional advisor note" "advisor consulted" "$(pm ledger_fallback)"
assert_eq "premium_call_is_quota_refused: HTTP 429 api_error_status" "yes" "$(pm quota_429_status)"
assert_eq "premium_call_is_quota_refused: agent rate-limit text" "no" "$(pm quota_text)"
assert_eq "premium_call_is_quota_refused: a genuine content error is not a refusal" "no" "$(pm genuine_error)"
assert_false "premium_call_is_quota_refused: bare HTTP 429 status text" \
  premium_call_is_quota_refused 'HTTP 429 Too Many Requests' 1
assert_false "premium_call_is_quota_refused: 429 in signal diagnostic path is not a refusal" \
  premium_call_is_quota_refused \
  'model_call_exit_status=143 termination_class=signal_termination signal=SIGTERM log_path=/tmp/zenoforge-agent-test-429/signal.log transcript_empty=true' 143

# --- Codex token transcript parser -----------------------------------------
TOKEN_PARSER_DIR="$(mktemp -d)"
TOKEN_TAIL_FILE="$TOKEN_PARSER_DIR/real-tail.log"
printf '%s\n' 'assistant work complete' 'tokens used' '714,051' > "$TOKEN_TAIL_FILE"
TOKEN_TRUNCATED_FILE="$TOKEN_PARSER_DIR/truncated.log"
printf '%s\n' 'assistant work was interrupted' 'process terminated' > "$TOKEN_TRUNCATED_FILE"
TOKEN_ELSEWHERE_FILE="$TOKEN_PARSER_DIR/number-elsewhere.log"
printf '%s\n' '714,051 appeared in an earlier diagnostic line' 'tokens used' 'not available' > "$TOKEN_ELSEWHERE_FILE"
TOKEN_MULTI_RUN_FILE="$TOKEN_PARSER_DIR/multi-run.log"
printf '%s\n' 'first run' 'tokens used' '111,222' 'second run' 'tokens used' '333,444' > "$TOKEN_MULTI_RUN_FILE"
token_parser_status() {
  local status=0
  codex_tokens_used "$1" >/dev/null 2>&1 || status=$?
  echo "$status"
}
assert_eq "codex_tokens_used: parses a transcript tail with thousands separators" \
  "714051" "$(codex_tokens_used "$TOKEN_TAIL_FILE" || true)"
assert_eq "codex_tokens_used: a real transcript tail is a successful parse" \
  "0" "$(token_parser_status "$TOKEN_TAIL_FILE")"
assert_eq "codex_tokens_used: a truncated transcript with no marker is empty" \
  "" "$(codex_tokens_used "$TOKEN_TRUNCATED_FILE" || true)"
assert_eq "codex_tokens_used: a truncated transcript is still a successful empty parse" \
  "0" "$(token_parser_status "$TOKEN_TRUNCATED_FILE")"
assert_eq "codex_tokens_used: a number elsewhere in the log is not mistaken for usage" \
  "" "$(codex_tokens_used "$TOKEN_ELSEWHERE_FILE" || true)"
assert_eq "codex_tokens_used: an unrelated number is still a successful empty parse" \
  "0" "$(token_parser_status "$TOKEN_ELSEWHERE_FILE")"
assert_eq "codex_tokens_used: the last marker wins in a multi-run log" \
  "333444" "$(codex_tokens_used "$TOKEN_MULTI_RUN_FILE" || true)"
assert_eq "codex_tokens_used: a multi-run transcript is a successful parse" \
  "0" "$(token_parser_status "$TOKEN_MULTI_RUN_FILE")"

# --- zcode result-line token parser ----------------------------------------
# zcode 一次调用以一行 {"type":"result"} 收尾，usage 是该次调用自己的总量：缓存读/写都算输入侧。
ZCODE_RESULT_FILE="$TOKEN_PARSER_DIR/zcode-result.log"
printf '%s\n' '{"type":"event"}' \
  '{"type":"result","subtype":"success","usage":{"input_tokens":100000,"cache_read_input_tokens":40000,"cache_creation_input_tokens":10000,"output_tokens":5000}}' > "$ZCODE_RESULT_FILE"
ZCODE_CODEX_STYLE_FILE="$TOKEN_PARSER_DIR/zcode-codex-style.log"
printf '%s\n' '{"type":"result","usage":{"input_tokens":100000,"cached_input_tokens":60000,"output_tokens":5000}}' > "$ZCODE_CODEX_STYLE_FILE"
ZCODE_NO_RESULT_FILE="$TOKEN_PARSER_DIR/zcode-no-result.log"
printf '%s\n' '{"type":"event"}' 'stream interrupted' > "$ZCODE_NO_RESULT_FILE"
assert_eq "zcode_tokens_used: cache read and creation count as input-side tokens" \
  "155000" "$(zcode_tokens_used "$ZCODE_RESULT_FILE" || true)"
assert_eq "zcode_tokens_used: codex-style cached_input_tokens is a subset of input, not added" \
  "105000" "$(zcode_tokens_used "$ZCODE_CODEX_STYLE_FILE" || true)"
assert_eq "zcode_tokens_used: no result line is an empty parse, never zero" \
  "" "$(zcode_tokens_used "$ZCODE_NO_RESULT_FILE" || true)"
rm -rf "$TOKEN_PARSER_DIR"
# --- policy roles replace per-level and provider fallback tables -----------
assert_eq "work role identity is the configured work model" "$AGENT_MODEL" "$(model_policy identity work)"
assert_eq "attempt selection resolves persisted work role" "$AGENT_MODEL" "$(implement_model_for_attempt)"

# Model usage has no local spend gate; accounting remains observational.
assert_eq "no local budget gate is called anywhere in engine/" \
  "0" "$(grep -rlE '\$\(premium_model_for |premium_model_for (advisor|guarded)|^(PREMIUM_CALLS_PER_ISSUE|read_premium_budget|premium_spent_today)\(\)|premium_spent_today "' "$SCRIPT_DIR"/*.sh 2>/dev/null | grep -v '\.test\.sh$' | wc -l)"
assert_true "probe-codex-sandbox.sh exists and is executable" test -x "$SCRIPT_DIR/probe-codex-sandbox.sh"

# --- run_codex_json: the one Codex runner, normalized to {is_error, ------
# --- structured_output} for the Codex JSON runner ------------------------
RCJ_BIN="$(mktemp -d)"
cat > "$RCJ_BIN/codex" <<'CODEXEOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" > "${FAKE_CODEX_ARGS_FILE:-/dev/null}"
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output-last-message) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
case "${FAKE_CODEX_MODE:-success}" in
  success) echo '{"verdict":"misclassified"}' > "$out"; exit 0 ;;
  quota) echo "ERROR: You’ve hit your usage limit. Try again later." >&2; exit 1 ;;
  genuine) echo "Error: schema validation failed" >&2; exit 1 ;;
esac
CODEXEOF
chmod +x "$RCJ_BIN/codex"
RCJ_PROMPT="$(mktemp)"; echo "hello" > "$RCJ_PROMPT"
RCJ_SCHEMA="$(mktemp)"; echo '{}' > "$RCJ_SCHEMA"
RCJ_ARGS="$(mktemp)"
RCJ_OUT="$(
  PATH="$RCJ_BIN:$PATH" FAKE_CODEX_MODE=success FAKE_CODEX_ARGS_FILE="$RCJ_ARGS" bash -c '
    source "$0/lib.sh"
    run_codex_json /tmp "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT" '"$RCJ_SCHEMA"' '"$RCJ_PROMPT"'
    echo "status=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "run_codex_json: a clean response normalizes to is_error:false + structured_output" "$RCJ_OUT" '"is_error":false'
assert_contains "run_codex_json: carries codex own structured verdict through" "$RCJ_OUT" '"verdict":"misclassified"'
assert_contains "run_codex_json: the function exit mirrors codex own exit (0)" "$RCJ_OUT" "status=0"
assert_contains "run_codex_json: disables GitNexus MCP" "$(cat "$RCJ_ARGS")" "mcp_servers.gitnexus.enabled=false"
assert_contains "run_codex_json: forwards policy service tier" "$(cat "$RCJ_ARGS")" "service_tier=\"$POLICY_WORK_TIER\""

RCJ_QUOTA_OUT="$(
  PATH="$RCJ_BIN:$PATH" FAKE_CODEX_MODE=quota bash -c '
    source "$0/lib.sh"
    out="$(run_codex_json /tmp "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT" '"$RCJ_SCHEMA"' '"$RCJ_PROMPT"')"
    echo "$out"
    echo "is_quota=$(premium_call_is_quota_refused "$out" 1 && echo yes || echo no)"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "run_codex_json: a codex refusal normalizes to is_error:true with the transcript captured" "$RCJ_QUOTA_OUT" '"is_error":true'
assert_contains "run_codex_json: ...and the quota detector reads it as a refusal" "$RCJ_QUOTA_OUT" "is_quota=yes"

# 2026-09-16 P0 regression (#1350, GitHub issue -- see run_codex_json()'s own
# comment in lib.sh): the QUOTA_OUT fixture above is short enough that `head
# -c 2000` and `tail -c 2000` capture the identical bytes, so it would keep
# "passing" whichever end the function kept -- it never actually exercised
# the bug. The real incident's transcript ($HOME/.zenoforge/logs/
# advisor-1327-20260917T033841Z.log) had the codex banner + echoed prompt
# ALONE exceed 2000 bytes, with the real error only at the very end. This
# fixture reproduces that shape: >2000 bytes of banner-shaped padding first,
# the actual usage-limit error last.
cat > "$RCJ_BIN/codex" <<'CODEXEOF'
#!/usr/bin/env bash
set -u
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output-last-message) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
printf 'model: %s\nsandbox: read-only\nsession id: fake-session\n' "$POLICY_WORK_MODEL" >&2
head -c 2500 /dev/zero | tr '\0' 'x' >&2
printf '\n' >&2
echo "ERROR: You've hit your usage limit. Visit https://example.com/codex/settings/usage to purchase more credits or try again at Sep 19th, 2026 1:10 AM." >&2
exit 1
CODEXEOF
chmod +x "$RCJ_BIN/codex"
RCJ_LONG_OUT="$(
  PATH="$RCJ_BIN:$PATH" bash -c '
    source "$0/lib.sh"
    out="$(run_codex_json /tmp "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT" '"$RCJ_SCHEMA"' '"$RCJ_PROMPT"')"
    echo "$out"
    echo "is_quota=$(premium_call_is_quota_refused "$out" 1 && echo yes || echo no)"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "run_codex_json: a transcript whose banner+echoed-prompt alone exceeds 2000 bytes still surfaces the real error, which sits at the END (tail -c 2000, not head -c 2000 -- #1350)" \
  "$RCJ_LONG_OUT" "usage limit"
assert_contains "run_codex_json: ...so the quota detector recognizes this shape as a refusal too, not just the short-transcript case above" \
  "$RCJ_LONG_OUT" "is_quota=yes"
assert_not_contains "run_codex_json: ...and the kept 2000 bytes no longer include the banner (proves the END was kept, not the START)" \
  "$RCJ_LONG_OUT" "session id: fake-session"

# A local wall-clock kill is its own failure shape: the runner must preserve
# the limit and observed elapsed time in the normalized failure, so the
# caller can tell a timeout from a model/provider refusal without reopening
# the shell's bare timeout default.
cat > "$RCJ_BIN/codex" <<'CODEXEOF'
#!/usr/bin/env bash
set -u
while [ $# -gt 0 ]; do
  case "$1" in
    --output-last-message) shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
sleep 2
CODEXEOF
chmod +x "$RCJ_BIN/codex"
RCJ_TIMEOUT_OUT="$([[ -x "$RCJ_BIN/codex" ]] && \
  PATH="$RCJ_BIN:$PATH" CODEX_JSON_TIMEOUT_SECONDS=1 bash -c '
    source "$0/lib.sh"
    out="$(run_codex_json /tmp "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT" '"$RCJ_SCHEMA"' '"$RCJ_PROMPT"')"
    echo "$out"
    echo "status=$?"
  ' "$SCRIPT_DIR" 2>&1)"
assert_contains "run_codex_json: exit 124 names its configured wall-clock limit" \
  "$RCJ_TIMEOUT_OUT" "timed out after 1s"
assert_contains "run_codex_json: exit 124 names observed elapsed time" \
  "$RCJ_TIMEOUT_OUT" "elapsed "
assert_contains "run_codex_json: timeout remains a nonzero runner result" \
  "$RCJ_TIMEOUT_OUT" '"codex_exit_status":124'

rm -rf "$RCJ_BIN"; rm -f "$RCJ_PROMPT" "$RCJ_SCHEMA"

RWA_PROMPT="$(mktemp)"; echo "hello" > "$RWA_PROMPT"
RWA_SCHEMA="$(mktemp)"; echo '{}' > "$RWA_SCHEMA"

# --- provider dispatcher rejects identities outside persistent roles -------
RMD_BIN="$(mktemp -d)"
RMD_UNEXPECTED_PROVIDER_CALLED="$(mktemp)"
RMD_IMPLEMENT_LOG="$(mktemp)"
rm -f "$RMD_UNEXPECTED_PROVIDER_CALLED"
cat > "$RMD_BIN/unexpected-provider" <<'PROVIDEREOF'
#!/usr/bin/env bash
: > "${FAKE_UNEXPECTED_PROVIDER_CALLED:?}"
exit 0
PROVIDEREOF
chmod +x "$RMD_BIN/unexpected-provider"
RMD_DENIED_OUT="$(
  PATH="$RMD_BIN:$PATH" FAKE_UNEXPECTED_PROVIDER_CALLED="$RMD_UNEXPECTED_PROVIDER_CALLED" bash -c '
    source "$0/lib.sh"
    run_model_json /tmp "codex:unconfigured-$POLICY_WORK_MODEL:$POLICY_WORK_EFFORT" 7 "$1" "$2" "$3"
    echo "status=$?"
  ' "$SCRIPT_DIR" "$RWA_SCHEMA" "$RWA_PROMPT" "$SCRIPT_DIR/prompts/agent-settings.json" 2>&1
)"
assert_contains "run_model_json rejects identity outside policy roles" "$RMD_DENIED_OUT" '"subtype":"unsupported_model_identity"'
assert_contains "run_model_json returns caller-visible denial" "$RMD_DENIED_OUT" "status=64"
assert_false "rejected identity never starts an unexpected provider" test -e "$RMD_UNEXPECTED_PROVIDER_CALLED"
RMD_IMPLEMENT_OUT="$(
  bash -c '
    source "$0/lib.sh"
    run_model_implement /tmp "codex:unconfigured-$POLICY_WORK_MODEL:$POLICY_WORK_EFFORT" 7 "$1" "$2" "$3"
    echo "status=$?"
  ' "$SCRIPT_DIR" "$RWA_PROMPT" "$RMD_IMPLEMENT_LOG" "$SCRIPT_DIR/prompts/agent-settings.json" 2>&1
)"
assert_contains "run_model_implement rejects identity outside policy roles" "$RMD_IMPLEMENT_OUT" "status=64"
assert_false "rejected implementation identity starts no unexpected provider" test -e "$RMD_UNEXPECTED_PROVIDER_CALLED"
# No web advisor provider is installed in this distribution: its identity fails closed, and every entry point the
# pipeline calls reports "unavailable" instead of dying on "command not found" (which would kill a tick under set -e).
RMD_WEB_OUT="$(
  bash -c '
    source "$0/lib.sh"
    run_model_json /tmp "$POLICY_ADVISOR_IDENTITY" 7 "$1" "$2" "$3" advisor
    echo "status=$?"
  ' "$SCRIPT_DIR" "$RWA_SCHEMA" "$RWA_PROMPT" "$SCRIPT_DIR/prompts/agent-settings.json" 2>&1
)"
assert_contains "run_model_json: the advisor identity fails closed without a provider" "$RMD_WEB_OUT" '"subtype":"unsupported_model_provider"'
assert_contains "...with the denial status callers record as the role's config fault" "$RMD_WEB_OUT" "status=64"
RMD_SEAM_OUT="$(
  bash -c '
    source "$0/lib.sh"
    echo "usable=$(web_advisor_provider_usable && echo yes || echo no)"
    echo "candidates=[$(web_advisor_provider_job_candidates 1 2)]"
    rc=0; env_fault_probe env:web-advisor-provider:tab-unresponsive || rc=$?; echo "probe_rc=$rc"
    rc=0; env_fault_repair env:web-advisor-provider:tab-unresponsive || rc=$?; echo "repair_rc=$rc"
    rc=0; run_model_advisor_batch_async "$(model_policy identity advisor)" job-1 /dev/null 2>/dev/null || rc=$?; echo "batch_rc=$rc"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "provider seam: no provider is never usable" "$RMD_SEAM_OUT" "usable=no"
assert_contains "provider seam: no job is ever a pending candidate" "$RMD_SEAM_OUT" "candidates=[]"
assert_contains "provider seam: an advisor env fault has no probe (canary only)" "$RMD_SEAM_OUT" "probe_rc=2"
assert_contains "provider seam: an advisor env fault has no repair" "$RMD_SEAM_OUT" "repair_rc=1"
assert_contains "provider seam: the batch dispatch is refused with the config-fault status" "$RMD_SEAM_OUT" "batch_rc=64"
rm -rf "$RMD_BIN"; rm -f "$RMD_UNEXPECTED_PROVIDER_CALLED"
rm -f "$RMD_IMPLEMENT_LOG"

rm -f "$RWA_PROMPT" "$RWA_SCHEMA"

# --- run_codex_text: the NDJSON-friendly Codex runner (run-advisor- -------
# --- batch.sh) -- raw --output-last-message content, no --output-schema, --
# --- unconditional on exit status -------------------------------------------
# The one caller asks for NDJSON, not a single schema-conformant document,
# specifically so a response cut off by the model's own output budget still
# yields every COMPLETE line before the cutoff -- so this function must
# never gate its output on `status`, and must never validate it as one JSON
# value the way run_codex_json() above deliberately does.
RCT_BIN="$(mktemp -d)"
cat > "$RCT_BIN/codex" <<'CODEXEOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" > "${FAKE_CODEX_ARGS_FILE:-/dev/null}"
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output-last-message) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
case "${FAKE_CODEX_MODE:-success}" in
  success)
    printf '%s\n%s\n' '{"kind":"cross_ticket_findings","ordering":[]}' '{"kind":"ruling","issue":1234,"verdict":"misclassified"}' > "$out"
    exit 0 ;;
  truncated_but_status_zero)
    # A real truncation shape: codex itself exits 0 (it did not crash, it
    # just ran out of its own output budget) but --output-last-message
    # holds a cut-off final line -- the exact case this function must NOT
    # discard just because it looks incomplete; that judgment belongs to
    # the CALLER's own line-by-line jq parse, not to this function.
    printf '%s\n%s' '{"kind":"cross_ticket_findings","ordering":[]}' '{"kind":"ruling","issue":1234,"verd' > "$out"
    exit 0 ;;
  crash_after_partial_flush)
    printf '%s\n' '{"kind":"cross_ticket_findings","ordering":[]}' > "$out"
    echo "Error: killed" >&2
    exit 1 ;;
  no_output_at_all)
    echo "Error: rate limit exceeded for this account" >&2
    exit 1 ;;
esac
CODEXEOF
chmod +x "$RCT_BIN/codex"
RCT_PROMPT="$(mktemp)"; echo "hello" > "$RCT_PROMPT"
RCT_TRANSCRIPT="$(mktemp)"
RCT_ARGS="$(mktemp)"

RCT_OK_OUT="$(
  PATH="$RCT_BIN:$PATH" FAKE_CODEX_MODE=success FAKE_CODEX_ARGS_FILE="$RCT_ARGS" bash -c '
    source "$0/lib.sh"
    out="$(run_codex_text /tmp "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT" 5 '"$RCT_PROMPT"' '"$RCT_TRANSCRIPT"')"
    status=$?
    echo "$out"
    echo "status=$status"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "run_codex_text: a clean response prints both NDJSON lines verbatim" "$RCT_OK_OUT" '"kind":"cross_ticket_findings"'
assert_contains "run_codex_text: ...second line too" "$RCT_OK_OUT" '"issue":1234'
assert_contains "run_codex_text: the function exit mirrors codex's own exit (0)" "$RCT_OK_OUT" "status=0"
assert_not_contains "run_codex_text: no {is_error, ...} envelope -- raw text only" "$RCT_OK_OUT" "is_error"
assert_contains "run_codex_text: disables GitNexus MCP" "$(cat "$RCT_ARGS")" "mcp_servers.gitnexus.enabled=false"
assert_contains "run_codex_text: forwards policy service tier" "$(cat "$RCT_ARGS")" "service_tier=\"$POLICY_WORK_TIER\""

RCT_TRUNCATED_OUT="$(
  PATH="$RCT_BIN:$PATH" FAKE_CODEX_MODE=truncated_but_status_zero bash -c '
    source "$0/lib.sh"
    out="$(run_codex_text /tmp "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT" 5 '"$RCT_PROMPT"' '"$RCT_TRANSCRIPT"')"
    status=$?
    echo "$out"
    echo "status=$status"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "run_codex_text: a truncated-but-exit-0 response still prints the complete first line" \
  "$RCT_TRUNCATED_OUT" '"kind":"cross_ticket_findings"'
assert_contains "run_codex_text: ...and the incomplete second line too, verbatim, undiscarded -- the caller's jq parse decides, not this function" \
  "$RCT_TRUNCATED_OUT" '"verd'

RCT_CRASH_OUT="$(
  PATH="$RCT_BIN:$PATH" FAKE_CODEX_MODE=crash_after_partial_flush bash -c '
    source "$0/lib.sh"
    out="$(run_codex_text /tmp "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT" 5 '"$RCT_PROMPT"' '"$RCT_TRANSCRIPT"')"
    status=$?
    echo "$out"
    echo "status=$status"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "run_codex_text: a nonzero exit still surfaces whatever WAS flushed to --output-last-message" \
  "$RCT_CRASH_OUT" '"kind":"cross_ticket_findings"'
assert_contains "run_codex_text: ...and reports codex's own nonzero exit, not silently swallowed" \
  "$RCT_CRASH_OUT" "status=1"

RCT_EMPTY_OUT="$(
  PATH="$RCT_BIN:$PATH" FAKE_CODEX_MODE=no_output_at_all bash -c '
    source "$0/lib.sh"
    out="$(run_codex_text /tmp "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT" 5 '"$RCT_PROMPT"' '"$RCT_TRANSCRIPT"')"
    status=$?
    echo "out=[$out]"
    echo "status=$status"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "run_codex_text: a total refusal (nothing ever flushed) prints empty output" "$RCT_EMPTY_OUT" "out=[]"
assert_contains "run_codex_text: ...and a nonzero exit for the caller to notice" "$RCT_EMPTY_OUT" "status=1"
assert_contains "run_codex_text: the refusal text lands in the caller-owned transcript file, not discarded" \
  "$(cat "$RCT_TRANSCRIPT")" "rate limit exceeded"
rm -rf "$RCT_BIN"; rm -f "$RCT_PROMPT" "$RCT_TRANSCRIPT"

# --- run_codex_implement: the freeform (write-capable) Codex runner, -----
# --- used by run-implement.sh's own fresh-implement call site ------------
# 2026-09-15 (Codex implement leg): unlike run_codex_json() above (a
# structured decision, --sandbox read-only), this is the write-capable
# role -- asserts the executor identity is spelled and dispatched
# correctly: --sandbox workspace-write (not read-only), --cd at the given
# cwd, -m/-c model_reasoning_effort split exactly like run_codex_json()'s
# own (never a hyphenated single string -- lessons/RULES.md V101), the
# prompt file's content reaching codex on stdin, and the function's return
# status mirroring codex's own exit code so run-implement.sh's existing
# `STATUS=$?` / fail_attempt() handling needs no changes to read it.
RCI_BIN="$(mktemp -d)"
cat > "$RCI_BIN/codex" <<'CODEXEOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" > "${FAKE_CODEX_IMPLEMENT_ARGS:-/dev/null}"
stdin_content="$(cat)"
printf '%s' "$stdin_content" > "${FAKE_CODEX_IMPLEMENT_STDIN:-/dev/null}"
out_file=""; previous=""
for arg in "$@"; do
  [ "$previous" = "--output-last-message" ] && out_file="$arg"
  previous="$arg"
done
if [ -n "$out_file" ] && [ -n "${FAKE_CODEX_IMPLEMENT_FINAL_OUTPUT_FILE:-}" ]; then
  cat "$FAKE_CODEX_IMPLEMENT_FINAL_OUTPUT_FILE" > "$out_file"
fi
case "${FAKE_CODEX_IMPLEMENT_MODE:-success}" in
  success) echo "codex implement: wrote the diff"; exit 0 ;;
  quota) echo "ERROR: You’ve hit your usage limit. Try again later." >&2; exit 1 ;;
  genuine) echo "Error: unexpected internal failure" >&2; exit 1 ;;
  signal) sh -c 'kill -TERM "$PPID"'; sleep 30 ;;
  timeout) exec sleep 30 ;;
esac
CODEXEOF
chmod +x "$RCI_BIN/codex"
RCI_PROMPT="$(mktemp)"; echo "implement this issue" > "$RCI_PROMPT"
RCI_LOG="$(mktemp)"
RCI_ARGS="$(mktemp)"
RCI_STDIN="$(mktemp)"
RCI_STATUS="$(
  PATH="$RCI_BIN:$PATH" FAKE_CODEX_IMPLEMENT_MODE=success \
  FAKE_CODEX_IMPLEMENT_ARGS="$RCI_ARGS" FAKE_CODEX_IMPLEMENT_STDIN="$RCI_STDIN" \
  bash -c '
    source "$0/lib.sh"
    run_codex_implement /tmp/some-worktree "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT" '"$RCI_PROMPT"' '"$RCI_LOG"'
    echo $?
  ' "$SCRIPT_DIR"
)"
RCI_ARGS_CONTENT="$(cat "$RCI_ARGS")"
assert_eq "run_codex_implement: mirrors codex's own successful exit status" "0" "$RCI_STATUS"
assert_contains "run_codex_implement: no sandbox (maintainer 2026-10-06: speed over sandbox)" "$RCI_ARGS_CONTENT" "danger-full-access"
assert_contains "run_codex_implement: --cd points at the given worktree" "$RCI_ARGS_CONTENT" "/tmp/some-worktree"
assert_contains "run_codex_implement: -m carries the bare model, never a hyphenated model-effort string (V101)" "$RCI_ARGS_CONTENT" "-m
${POLICY_WORK_MODEL}"
assert_contains "run_codex_implement: effort is the SEPARATE model_reasoning_effort setting" "$RCI_ARGS_CONTENT" "model_reasoning_effort=$POLICY_WORK_EFFORT"
assert_contains "run_codex_implement: forwards policy service tier" "$RCI_ARGS_CONTENT" "service_tier=\"$POLICY_WORK_TIER\""
assert_contains "run_codex_implement: disables GitNexus MCP" "$RCI_ARGS_CONTENT" "mcp_servers.gitnexus.enabled=false"
assert_eq "run_codex_implement: the prompt file's content reaches codex on stdin" "implement this issue" "$(cat "$RCI_STDIN")"
assert_contains "run_codex_implement: codex's combined stdout/stderr lands in the given log file" "$(cat "$RCI_LOG")" "codex implement: wrote the diff"

RCI_FINAL_OUTPUT="$(mktemp)"
RCI_LONG_LOG="$(mktemp)"
printf '%s\n' 'BLOCKED-CHECKS: pnpm --filter @agent-runtime/shared test — connect EPERM 127.0.0.1:5432' > "$RCI_FINAL_OUTPUT"
awk 'BEGIN { for (i = 0; i < 5000; i++) printf "x" }' >> "$RCI_FINAL_OUTPUT"
PATH="$RCI_BIN:$PATH" FAKE_CODEX_IMPLEMENT_MODE=success \
  FAKE_CODEX_IMPLEMENT_FINAL_OUTPUT_FILE="$RCI_FINAL_OUTPUT" \
  bash -c '
    source "$0/lib.sh"
    run_codex_implement /tmp/some-worktree "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT" '"$RCI_PROMPT"' '"$RCI_LONG_LOG"'
  ' "$SCRIPT_DIR"
assert_contains "run_codex_implement: blocked-check marker survives 4,000-character final-output truncation" \
  "$(cat "$RCI_LONG_LOG")" 'BLOCKED-CHECKS: pnpm --filter @agent-runtime/shared test — connect EPERM 127.0.0.1:5432'

RCI_QUOTA_STATUS="$(
  PATH="$RCI_BIN:$PATH" FAKE_CODEX_IMPLEMENT_MODE=quota bash -c '
    source "$0/lib.sh"
    run_codex_implement /tmp/some-worktree "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT" '"$RCI_PROMPT"' '"$RCI_LOG"'
    echo $?
  ' "$SCRIPT_DIR"
)"
assert_eq "run_codex_implement: a refusal mirrors codex's own nonzero exit (the caller, not this function, decides refusal-vs-failure)" "1" "$RCI_QUOTA_STATUS"
# run_codex_implement() does not itself normalize a refusal shape (there is
# no {is_error,...} envelope for a freeform task) -- the caller (run-
# implement.sh) reads the plain log file it was given, exactly like it
# already does for a Codex implement failure. premium_call_is_quota_
# refused() is a plain text-grep, so it reads that log file's content fine
# either way.
assert_true "run_codex_implement: the caller can read the refusal shape straight out of the log file it was given" \
  premium_call_is_quota_refused "$(cat "$RCI_LOG")" 1

# Model exits keep structured evidence even when the child wrote nothing.
# The signal case kills the real fake-Codex process from a child process;
# it does not pass 143 into the classifier.
cat > "$RCI_BIN/systemctl" <<'SYSTEMCTLEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SYSTEMCTL_LOG:-/dev/null}"
case "${FAKE_SYSTEMCTL_MODE:-running}" in
  signal) printf 'ActiveState=failed\nSubState=failed\nResult=signal\nExecMainCode=killed\nExecMainStatus=15\n' ;;
  *) printf 'ActiveState=active\nSubState=running\nResult=success\nExecMainCode=0\nExecMainStatus=0\n' ;;
esac
SYSTEMCTLEOF
chmod +x "$RCI_BIN/systemctl"
RCI_TIMEOUT_BIN="$(mktemp -d)"
ln -s "$RCI_BIN/codex" "$RCI_TIMEOUT_BIN/codex"
ln -s "$RCI_BIN/systemctl" "$RCI_TIMEOUT_BIN/systemctl"
REAL_TIMEOUT="$(command -v timeout)"
cat > "$RCI_TIMEOUT_BIN/timeout" <<'TIMEOUTEOF'
#!/usr/bin/env bash
shift
exec "$REAL_TIMEOUT" --signal=TERM 0.05s "$@"
TIMEOUTEOF
chmod +x "$RCI_TIMEOUT_BIN/timeout"

run_rci_failure_case() {
  local mode="$1" issue="$2" home="$3" log="$4" runner_bin="$RCI_BIN" codex_mode="$1" systemctl_mode=running out
  if [ "$mode" = signal_supervisor ]; then
    codex_mode=signal
    systemctl_mode=signal
  fi
  [ "$mode" = timeout ] && runner_bin="$RCI_TIMEOUT_BIN"
  out="$(AGENT_HOME="$home" PATH="$runner_bin:$PATH" \
    FAKE_CODEX_IMPLEMENT_MODE="$codex_mode" FAKE_SYSTEMCTL_MODE="$systemctl_mode" REAL_TIMEOUT="$REAL_TIMEOUT" \
    FAKE_SYSTEMCTL_LOG="$home/systemctl.log" bash -c '
      set -uo pipefail
      source "$0/lib.sh"
      N="$1"
      prompt="$2"
      log="$3"
      mkdir -p "$STATE_DIR"
      printf "{\"attempts\":1}\n" > "$STATE_DIR/$N.json"
      notify_maintainer() { :; }
      run_codex_implement /tmp/some-worktree "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT" "$prompt" "$log" 120 run-implement:implement
      status=$?
      pause_for_backoff "$N" "$(tail -c 4000 "$log")" "$status" 1 codex "$POLICY_WORK_IDENTITY" run-implement:implement \
        "${MODEL_CALL_LOG_PATH:-$log}" "${MODEL_CALL_EXIT_CLASS:-}" "${MODEL_CALL_TERMINATION_SOURCE:-}" \
        "${MODEL_CALL_TERMINATION_EVIDENCE:-}" "${MODEL_CALL_TRANSCRIPT_EMPTY:-false}"
      printf "CALL-STATUS=%s\n" "$status"
      printf "LAST-CALL=%s\n" "$(jq -c .last_model_call_failure "$STATE_DIR/$N.json")"
      printf "BACKOFF=%s\n" "$(jq -c .model_failure_backoff "$STATE_DIR/$N.json" 2>/dev/null || echo null)"
      printf "LOG-BEGIN\n"
      cat "$log"
    ' "$SCRIPT_DIR" "$issue" "$RCI_PROMPT" "$log" 2>&1)"
  printf '%s\n' "$out"
}

RCI_ORDINARY_HOME="$(mktemp -d)"; RCI_ORDINARY_LOG="$(mktemp)"
TMP_DIRS+=("$RCI_ORDINARY_HOME" "$RCI_ORDINARY_LOG")
RCI_ORDINARY_OUT="$(run_rci_failure_case genuine 700111 "$RCI_ORDINARY_HOME" "$RCI_ORDINARY_LOG")"
assert_contains "ordinary model exit keeps numeric status and application classification" \
  "$RCI_ORDINARY_OUT" '"exit_status":1,"termination_class":"application_exit"'
assert_contains "ordinary model exit keeps issue, stage, caller, provider, model and log path" \
  "$RCI_ORDINARY_OUT" "\"issue\":\"700111\",\"stage\":\"implement\",\"caller\":\"run-implement:implement\",\"provider\":\"codex\",\"model\":\"$POLICY_WORK_IDENTITY\""
assert_contains "ordinary model exit stores its log location" "$RCI_ORDINARY_OUT" "\"log_path\":\"$RCI_ORDINARY_LOG\""
assert_contains "ordinary model exit records timestamp and timeout-independent backoff fields" \
  "$RCI_ORDINARY_OUT" '"timestamp":"'
assert_contains "ordinary model exit is distinguishable in the transcript" \
  "$RCI_ORDINARY_OUT" 'model_call_exit_status=1 termination_class=application_exit'

RCI_TIMEOUT_HOME="$(mktemp -d)"; RCI_TIMEOUT_LOG="$(mktemp)"
TMP_DIRS+=("$RCI_TIMEOUT_HOME" "$RCI_TIMEOUT_LOG" "$RCI_TIMEOUT_BIN")
RCI_TIMEOUT_OUT="$(run_rci_failure_case timeout 700112 "$RCI_TIMEOUT_HOME" "$RCI_TIMEOUT_LOG")"
assert_contains "real wall-clock timeout keeps exit 124 and timeout classification" \
  "$RCI_TIMEOUT_OUT" 'CALL-STATUS=124'
assert_contains "timeout is independently recorded with structured status" \
  "$RCI_TIMEOUT_OUT" '"exit_status":124,"termination_class":"wall_clock_timeout"'
assert_contains "timeout log states its classification and empty transcript" \
  "$RCI_TIMEOUT_OUT" 'model_call_exit_status=124 termination_class=wall_clock_timeout'

RCI_SIGNAL_HOME="$(mktemp -d)"; RCI_SIGNAL_LOG="$(mktemp)"
TMP_DIRS+=("$RCI_SIGNAL_HOME" "$RCI_SIGNAL_LOG")
# Force admission telemetry to fail while the model itself writes nothing.
: > "$RCI_SIGNAL_HOME/metrics"
RCI_SIGNAL_OUT="$(run_rci_failure_case signal 700113 "$RCI_SIGNAL_HOME" "$RCI_SIGNAL_LOG")"
assert_contains "controlled child really terminates model process with SIGTERM" "$RCI_SIGNAL_OUT" 'CALL-STATUS=143'
assert_contains "signal exit is structured and never quota-shaped" \
  "$RCI_SIGNAL_OUT" '"exit_status":143,"termination_class":"signal_termination","termination_source":"unknown"'
assert_contains "empty signal transcript leaves nonempty log diagnostic" \
  "$RCI_SIGNAL_OUT" 'model_call_exit_status=143 termination_class=signal_termination signal=SIGTERM'
assert_contains "empty signal transcript is marked explicitly" "$RCI_SIGNAL_OUT" 'transcript_empty=true'
assert_contains "admission telemetry errors remain in the model log" "$RCI_SIGNAL_OUT" 'execution metrics: append failed'
assert_eq "signal state records transcript emptiness" "true" \
  "$(jq -r '.last_model_call_failure.transcript_empty' "$RCI_SIGNAL_HOME/state/700113.json")"
assert_contains "signal evidence query targets issue owning implement unit" \
  "$(cat "$RCI_SIGNAL_HOME/systemctl.log" 2>/dev/null || true)" '--user show zf-implement-700113.service'
assert_contains "signal record retains available owner-unit evidence" \
  "$RCI_SIGNAL_OUT" 'termination_evidence=signal=SIGTERM; ActiveState=active;SubState=running;Result=success;ExecMainCode=0;ExecMainStatus=0'
assert_false "signal-killed run is never classified as quota/refusal" \
  premium_call_is_quota_refused "$(cat "$RCI_SIGNAL_LOG")" 143

RCI_SUPERVISOR_HOME="$(mktemp -d)"; RCI_SUPERVISOR_LOG="$(mktemp)"
TMP_DIRS+=("$RCI_SUPERVISOR_HOME" "$RCI_SUPERVISOR_LOG")
RCI_SUPERVISOR_OUT="$(run_rci_failure_case signal_supervisor 700114 "$RCI_SUPERVISOR_HOME" "$RCI_SUPERVISOR_LOG")"
assert_contains "supervisor-terminated child preserves actual SIGTERM exit" "$RCI_SUPERVISOR_OUT" 'CALL-STATUS=143'
assert_contains "supervisor Result=signal is retained as termination source" \
  "$RCI_SUPERVISOR_OUT" '"termination_class":"signal_termination","termination_source":"systemd unit zf-implement-700114.service reported Result=signal"'
assert_contains "supervisor ExecMainStatus is retained as trigger evidence" \
  "$RCI_SUPERVISOR_OUT" 'termination_evidence=signal=SIGTERM; ActiveState=failed;SubState=failed;Result=signal;ExecMainCode=killed;ExecMainStatus=15'
assert_eq "supervisor source reaches issue backoff state" \
  "systemd unit zf-implement-700114.service reported Result=signal" \
  "$(jq -r '.model_failure_backoff.termination_source // empty' "$RCI_SUPERVISOR_HOME/state/700114.json")"
assert_false "supervisor SIGTERM still cannot become quota/refusal" \
  premium_call_is_quota_refused "$(cat "$RCI_SUPERVISOR_LOG")" 143

rm -rf "$RCI_BIN"; rm -f "$RCI_PROMPT" "$RCI_LOG" "$RCI_ARGS" "$RCI_STDIN" "$RCI_FINAL_OUTPUT" "$RCI_LONG_LOG"

# --- run_codex_implement: containment gap closed 2026-09-18 (issue #1347 -
# --- follow-up) -----------------------------------------------------------
# The 2026-09-18 network unblock (config.toml's global
# sandbox_workspace_write.network_access=true, since scoped down and
# removed from that file) turned network denial from this function's own
# containment story into nothing -- GH_TOKEN reaches this shell from the
# systemd unit's EnvironmentFile (~/.zenoforge/env), and with network
# open an unattended run could reach GitHub as the maintainer. Two properties,
# both must hold: (1) the network grant is scoped to THIS call
# (`-c sandbox_workspace_write.network_access=true` on the codex exec argv
# itself, not read from a global file this test cannot see), and (2)
# GH_TOKEN/GITHUB_TOKEN never reach codex's child environment even though
# the wrapper's own shell has them (for the `gh`/`git push` calls
# run-implement.sh performs itself, outside the sandbox). Isolated AGENT_
# HOME via mktemp -d (same pattern as the model-policy
# assertions above) -- run_codex_implement() itself never reads AGENT_HOME,
# but sourcing lib.sh does other AGENT_HOME-relative work at load time, and
# this suite has already gone red once from reading the real box's state
# instead of an isolated one.
RCI2_BIN="$(mktemp -d)"
cat > "$RCI2_BIN/codex" <<'CODEXEOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" > "${FAKE_CODEX_IMPLEMENT_ARGS2:-/dev/null}"
: > "${FAKE_CODEX_IMPLEMENT_ENV2:-/dev/null}"
# Only ever record PRESENCE, never the value -- a leaked test decoy value
# is still a leak of the pattern this test exists to catch.
[ -n "${GH_TOKEN:-}" ] && echo "GH_TOKEN_PRESENT" >> "${FAKE_CODEX_IMPLEMENT_ENV2:-/dev/null}"
[ -n "${GITHUB_TOKEN:-}" ] && echo "GITHUB_TOKEN_PRESENT" >> "${FAKE_CODEX_IMPLEMENT_ENV2:-/dev/null}"
cat > /dev/null
echo "codex implement: wrote the diff"
exit 0
CODEXEOF
chmod +x "$RCI2_BIN/codex"
RCI2_PROMPT="$(mktemp)"; echo "implement this issue" > "$RCI2_PROMPT"
RCI2_LOG="$(mktemp)"
RCI2_ARGS="$(mktemp)"
RCI2_ENV="$(mktemp)"
RCI2_HOME="$(mktemp -d)"
RCI2_OUT="$(
  PATH="$RCI2_BIN:$PATH" AGENT_HOME="$RCI2_HOME" \
  GH_TOKEN="decoy-gh-token-test-only" GITHUB_TOKEN="decoy-github-token-test-only" \
  FAKE_CODEX_IMPLEMENT_ARGS2="$RCI2_ARGS" FAKE_CODEX_IMPLEMENT_ENV2="$RCI2_ENV" \
  bash -c '
    source "$0/lib.sh"
    run_codex_implement /tmp/some-worktree "$POLICY_WORK_MODEL" "$POLICY_WORK_EFFORT" '"$RCI2_PROMPT"' '"$RCI2_LOG"'
    echo "status=$?"
    echo "caller_gh_token_still_set=${GH_TOKEN:+yes}"
    echo "caller_github_token_still_set=${GITHUB_TOKEN:+yes}"
  ' "$SCRIPT_DIR"
)"
RCI2_ARGS_CONTENT="$(cat "$RCI2_ARGS")"
RCI2_ENV_CONTENT="$(cat "$RCI2_ENV")"
assert_contains "run_codex_implement: mirrors codex's own successful exit status" "$RCI2_OUT" "status=0"
assert_contains "run_codex_implement: carries the network grant scoped to this one invocation (-c sandbox_workspace_write.network_access=true), not read from a global config.toml" \
  "$RCI2_ARGS_CONTENT" "sandbox_workspace_write.network_access=true"
assert_not_contains "run_codex_implement: does not leak GH_TOKEN into codex's child environment" \
  "$RCI2_ENV_CONTENT" "GH_TOKEN_PRESENT"
assert_not_contains "run_codex_implement: does not leak GITHUB_TOKEN into codex's child environment" \
  "$RCI2_ENV_CONTENT" "GITHUB_TOKEN_PRESENT"
assert_contains "run_codex_implement: env -u is scoped to codex's own argv only -- the wrapper's shell (which needs GH_TOKEN for its own gh/git push calls) keeps it" \
  "$RCI2_OUT" "caller_gh_token_still_set=yes"
assert_contains "run_codex_implement: ...and keeps GITHUB_TOKEN too, same reasoning" \
  "$RCI2_OUT" "caller_github_token_still_set=yes"
rm -rf "$RCI2_BIN" "$RCI2_HOME"; rm -f "$RCI2_PROMPT" "$RCI2_LOG" "$RCI2_ARGS" "$RCI2_ENV"

# --- same_failure_streak: the anti-stuck-on-repeat signal (#1221) -------
SFS_OUT="$(
  bash -c '
    source "$0/lib.sh"
    echo "first_ever=$(same_failure_streak "" "" "boom" "trace" 0)"
    echo "same_again=$(same_failure_streak "boom" "trace" "boom" "trace" 0)"
    echo "same_third=$(same_failure_streak "boom" "trace" "boom" "trace" 1)"
    echo "different=$(same_failure_streak "boom" "trace" "kaboom" "trace2" 1)"
    echo "same_reason_diff_tail=$(same_failure_streak "boom" "trace" "boom" "trace2" 3)"
  ' "$SCRIPT_DIR" 2>&1
)"
sfs() { printf '%s\n' "$SFS_OUT" | grep -m1 "^$1=" | cut -d= -f2-; }
assert_eq "same_failure_streak: nothing stored yet -- not a repeat" "0" "$(sfs first_ever)"
assert_eq "same_failure_streak: an exact repeat increments" "1" "$(sfs same_again)"
assert_eq "same_failure_streak: a second exact repeat increments again" "2" "$(sfs same_third)"
assert_eq "same_failure_streak: a different failure resets the streak (progress, not a stall)" "0" "$(sfs different)"
assert_eq "same_failure_streak: same reason but a different tail does not count as the same wall" "0" "$(sfs same_reason_diff_tail)"

# Issue 2056: failure normalization removes volatile run details but preserves
# distinct causes before either consecutive-failure comparison uses it.
FAILURE_FINGERPRINT_OUT="$(bash -s -- "$SCRIPT_DIR" <<'FINGERPRINT_TEST'
set -euo pipefail
source "$1/lib.sh"
reason_a='pipeline-system direct-main delivery failed for issue #1878'
reason_b='pipeline-system direct-main delivery failed for issue #1901'
tail_a=$'not ok - invalid lesson fragment at /tmp/zf-check-a1b2c3d4/fragment.json commit abc1234 at 2026-10-06T09:42:03.123Z elapsed=11.2s'
tail_b=$'not ok - invalid lesson fragment at /tmp/zf-check-f00dbabe/fragment.json commit 0123456789abcdef0123456789abcdef01234567 at 2026-10-07T13:18:55Z elapsed=93.7s'
fingerprint_a="$(failure_fingerprint "$reason_a" "$tail_a")"
fingerprint_b="$(failure_fingerprint "$reason_b" "$tail_b")"
different="$(failure_fingerprint 'rebase conflict' 'fatal: could not apply fix')"
test_reason="$(model_policy_normalize_failure_reason 'test suite failed at 2026-10-06T09:42:03Z after 11s')"
test_reason_later="$(model_policy_normalize_failure_reason 'test suite failed at 2026-10-07T13:18:55Z after 93s')"
printf 'same=%s\nstreak=%s\ndifferent=%s\npolicy_same=%s\n' \
  "$([ "$fingerprint_a" = "$fingerprint_b" ] && echo true || echo false)" \
  "$(same_failure_streak "$reason_a" "$tail_a" "$reason_b" "$tail_b" 0)" \
  "$([ "$fingerprint_a" != "$different" ] && echo true || echo false)" \
  "$([ "$test_reason" = "$test_reason_later" ] && echo true || echo false)"
FINGERPRINT_TEST
)"
assert_contains "failure fingerprint ignores temp paths, hashes, timestamps, durations, and issue numbers" \
  "$FAILURE_FINGERPRINT_OUT" $'same=true\nstreak=1'
assert_contains "failure fingerprint keeps rebase conflict distinct from test failure" \
  "$FAILURE_FINGERPRINT_OUT" 'different=true'
assert_contains "model-policy normalization shares failure fingerprint rules" \
  "$FAILURE_FINGERPRINT_OUT" 'policy_same=true'

# --- implement_model_for_attempt: escalates on attempt 4 OR a repeat ----
IMFA_OUT="$(
  bash -c '
    source "$0/lib.sh"
    echo "attempt1_no_streak=$(implement_model_for_attempt 1 0)"
    echo "attempt2_no_streak=$(implement_model_for_attempt 2 0)"
    echo "attempt2_streak=$(implement_model_for_attempt 2 1)"
    echo "attempt3_streak=$(implement_model_for_attempt 3 1)"
    echo "attempt4_no_streak=$(implement_model_for_attempt 4 0)"
    echo "attempt1_default_streak=$(implement_model_for_attempt 1)"
  ' "$SCRIPT_DIR" 2>&1
)"
imfa() { printf '%s\n' "$IMFA_OUT" | grep -m1 "^$1=" | cut -d= -f2-; }
assert_eq "implement_model_for_attempt: attempt 1-3, no repeat -- the cheap model, unchanged behavior" "$AGENT_MODEL" "$(imfa attempt1_no_streak)"
assert_eq "implement_model_for_attempt: ...still true at attempt 2 with no repeat" "$AGENT_MODEL" "$(imfa attempt2_no_streak)"
assert_eq "implement_model_for_attempt: a repeat (streak>=1) escalates as early as attempt 2 -- #1221's fix, not waiting for attempt 4" "$AGENT_MODEL_RETRY" "$(imfa attempt2_streak)"
assert_eq "implement_model_for_attempt: ...and stays escalated on the next attempt too" "$AGENT_MODEL_RETRY" "$(imfa attempt3_streak)"
assert_eq "implement_model_for_attempt: attempt 4 still escalates unconditionally (the old rule, still a backstop)" "$AGENT_MODEL_RETRY" "$(imfa attempt4_no_streak)"
assert_eq "implement_model_for_attempt: streak defaults to 0 when the caller omits it" "$AGENT_MODEL" "$(imfa attempt1_default_streak)"

# --- #1257: notify_maintainer()'s stdout stays clean even if the notifier --
# --- (send_email) itself leaks something onto stdout, exactly like a ----
# --- real Gmail threadId does on a genuine successful send --------------
NF_HOME="$(mktemp -d)"
mkdir -p "$NF_HOME"
echo '{"founder_login":"f","recipients":{"f":"f@example.test"}}' > "$NF_HOME/recipients.json"
NF_OUT="$(
  AGENT_HOME="$NF_HOME" bash -c '
    set -uo pipefail
    source "$0/lib.sh"
    # Todays stub (ZF_GCLOUD_BIN=/nonexistent/gcloud) never reaches this
    # deep -- send_email short-circuits on the missing gcloud binary before
    # it would ever print anything, which is exactly why the original bug
    # (#1257) escaped the existing suite ("todays stub is silent"). Override
    # send_email() to behave like a REAL successful send instead -- echoing
    # something on stdout, per ITS OWN documented contract (a Gmail
    # threadId) -- so this test actually exercises the leak path.
    send_email() { echo "18abc0000000leak"; return 0; }
    echo "notify_stdout=[$(notify_maintainer "subject" "body")]"
  ' "$SCRIPT_DIR" 2>/dev/null
)"
rm -rf "$NF_HOME"
nf() { printf '%s\n' "$NF_OUT" | grep -m1 "^$1=" | cut -d= -f2-; }
assert_eq "#1257: notify_maintainer's own stdout stays empty even when the notifier (send_email) leaks a threadId" "[]" "$(nf notify_stdout)"

# --- every leg is executable, in git and on disk (zf-advisor-1131, ------
# --- 203/EXEC: run-advisor.sh was committed 644) ---------------------------
for leg in run-triage.sh run-advisor.sh run-recut.sh run-tick.sh issue-pipeline.sh probe-codex-sandbox.sh; do
  assert_true "$leg is executable on disk" test -x "$SCRIPT_DIR/$leg"
  # The remote toolchain gate runs a git archive (which keeps the mode bit but
  # has no .git index); the local checkout run below also verifies the index.
  if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    assert_eq "$leg is executable in git (mode 100755), not just on disk" \
      "100755" "$(git -C "$SCRIPT_DIR" ls-files -s -- "$leg" | awk '{print $1}')"
  fi
done
# The startup check opens a stage quarantine (an outage with a probe), and
# the probe lifts it once the bit is back -- proven on a throwaway checkout.
LEG_HOME="$(mktemp -d)"
LEG_REPO="$(mktemp -d)"
mkdir -p "$LEG_REPO/engine"
for leg in triage advisor recut release; do printf '#!/usr/bin/env bash\n' > "$LEG_REPO/engine/run-$leg.sh"; chmod 755 "$LEG_REPO/engine/run-$leg.sh"; done
chmod 644 "$LEG_REPO/engine/run-advisor.sh"
LEG_OUT="$(
  AGENT_HOME="$LEG_HOME" ZF_REPO_DIR="$LEG_REPO" ZF_ENGINE_DIR="$LEG_REPO/engine" REPO="test/repo" ZF_GCLOUD_BIN=/nonexistent/gcloud bash -c '
    set -uo pipefail
    source "$0/lib.sh"
    legs_executable_check 2>/dev/null
    echo "advisor_quarantined=$([ -f "$(quarantine_file advisor)" ] && echo yes || echo no)"
    echo "triage_free=$([ -f "$(quarantine_file triage)" ] && echo no || echo yes)"
    echo "sig=$(jq -r .signature "$(quarantine_file advisor)")"
    echo "advisor_blocked=$(stage_dispatch_allowed advisor "[]" 2>/dev/null && echo no || echo yes)"
    chmod 755 "$ZF_REPO_DIR/engine/run-advisor.sh"
    reconcile_quarantines 2>/dev/null
    echo "lifted_after_fix=$([ -f "$(quarantine_file advisor)" ] && echo no || echo yes)"
  ' "$SCRIPT_DIR" 2>&1
)"
rm -rf "$LEG_HOME" "$LEG_REPO"
lg() { printf '%s\n' "$LEG_OUT" | grep -m1 "^$1=" | cut -d= -f2-; }
assert_eq "legs_executable_check: a non-executable leg opens a quarantine on that stage" "yes" "$(lg advisor_quarantined)"
assert_eq "legs_executable_check: ...and only that stage" "yes" "$(lg triage_free)"
assert_eq "legs_executable_check: ...under a signature that names the leg" "env:leg-not-executable:advisor" "$(lg sig)"
assert_eq "legs_executable_check: ...which blocks that stage's dispatch (an outage, not a verdict)" "yes" "$(lg advisor_blocked)"
assert_eq "legs_executable_check: the probe lifts it on the tick after the mode bit is fixed" "yes" "$(lg lifted_after_fix)"

# --- 2026-09-16 fix (instance 1): dispatch()/dispatch_merge_sweeper() used
# to swallow a systemd-run failure via `|| echo ... >&2` -- `echo` exits 0,
# so the function always returned success even when NO unit was created,
# and the caller's own `slots=$((slots - 1))` counted it as dispatched
# anyway. Static, same style already established for this exact function
# just above (legs_executable_check's own dispatch() assertion): the
# per-stage `for` loops call dispatch() as a bare statement, never inside
# an if/while/&&/||, so a real error propagation is testable by source
# shape (does it still return success on failure) without standing up a
# whole tick's worth of gh/systemd-run fakes -- no dynamic harness exists
# for this dispatch loop (see the autonomy-gate-recheck comment above).
DISPATCH_BODY="$(sed -n '/^dispatch() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
assert_not_contains "dispatch(): the old swallow-into-success shape is gone" \
  "$DISPATCH_BODY" '|| echo "issue-pipeline: systemd-run dispatch failed for zf-$stage-$n" >&2'
assert_contains "dispatch(): a systemd-run failure now records a persistent fault" \
  "$DISPATCH_BODY" 'record_env_fault "env:systemd-run-dispatch-failed:$stage"'
assert_contains "...and returns non-zero instead of falling through to success" \
  "$DISPATCH_BODY" 'return 1'

# =============================================================================
# 2026-09-16: "an unreadable fact is treated as a permissive answer" class
# (the adversarial review that produced lessons/RULES.md's V1xx entry for
# this). Every case below proves a read failure fails CLOSED (refuses the
# action / reports "unknown"), never collapses into the same answer as a
# confirmed negative.
# =============================================================================

# A transient 60s-class proxy stall retries through the shared gh() wrapper,
# within its configured attempt cap, so recovery does not become a fail-closed skip.
GH_RETRY_BIN="$(mktemp -d)"
GH_RETRY_COUNT_FILE="$(mktemp)"
cat > "$GH_RETRY_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
count=0
[ ! -f "$GH_RETRY_COUNT_FILE" ] || count="$(cat "$GH_RETRY_COUNT_FILE")"
count=$((count + 1))
printf '%s\n' "$count" > "$GH_RETRY_COUNT_FILE"
if [ "$GH_RETRY_MODE" = gateway ] && [ "$count" -eq 1 ]; then
  echo 'gh: Gateway Timeout (HTTP 504)' >&2
  exit 1
fi
if [ "$count" -eq 1 ]; then sleep 2; else echo GH_RETRY_OK; fi
FAKE_GH
chmod +x "$GH_RETRY_BIN/gh"
GH_RETRY_OUT="$(PATH="$GH_RETRY_BIN:$PATH" GH_CALL_TIMEOUT_SEC=1 GH_RETRY_COUNT_FILE="$GH_RETRY_COUNT_FILE" GH_RETRY_MODE=timeout bash -c '
  source "$0/lib.sh"
  gh issue view 999
' "$SCRIPT_DIR" 2>&1)"
assert_eq "gh(): retries one timed-out API read exactly once" "2" "$(cat "$GH_RETRY_COUNT_FILE")"
assert_contains "gh(): reports the transient timeout before retry" "$GH_RETRY_OUT" "retrying after 2s backoff (attempt 2/3)"
assert_contains "gh(): returns the recovered API result" "$GH_RETRY_OUT" "GH_RETRY_OK"

: > "$GH_RETRY_COUNT_FILE"
GH_GATEWAY_OUT="$(PATH="$GH_RETRY_BIN:$PATH" GH_CALL_TIMEOUT_SEC=1 GH_RETRY_COUNT_FILE="$GH_RETRY_COUNT_FILE" GH_RETRY_MODE=gateway bash -c '
  source "$0/lib.sh"
  gh issue view 999
' "$SCRIPT_DIR" 2>&1)"
assert_eq "gh(): retries a transient Gateway Timeout read exactly once" "2" "$(cat "$GH_RETRY_COUNT_FILE")"
assert_contains "gh(): reports the Gateway Timeout retry" "$GH_GATEWAY_OUT" "retrying after 2s backoff (attempt 2/3)"
assert_contains "gh(): returns the recovered Gateway Timeout read" "$GH_GATEWAY_OUT" "GH_RETRY_OK"

: > "$GH_RETRY_COUNT_FILE"
if GH_WRITE_OUT="$(PATH="$GH_RETRY_BIN:$PATH" GH_CALL_TIMEOUT_SEC=1 GH_RETRY_COUNT_FILE="$GH_RETRY_COUNT_FILE" GH_RETRY_MODE=timeout bash -c '
  source "$0/lib.sh"
  if gh issue comment 999 --body test; then echo WRITE_STATUS=0; else echo WRITE_STATUS=$?; fi
' "$SCRIPT_DIR" 2>&1)"; then
  GH_WRITE_STATUS=0
else
  GH_WRITE_STATUS=$?
fi
assert_eq "gh(): does not replay a timed-out comment write" "1" "$(cat "$GH_RETRY_COUNT_FILE")"
assert_contains "gh(): timed-out write preserves its failure" "$GH_WRITE_OUT" "WRITE_STATUS=124"
assert_not_contains "gh(): timed-out write gets no retry" "$GH_WRITE_OUT" "retrying once"

: > "$GH_RETRY_COUNT_FILE"
if GH_API_WRITE_OUT="$(PATH="$GH_RETRY_BIN:$PATH" GH_CALL_TIMEOUT_SEC=1 GH_RETRY_COUNT_FILE="$GH_RETRY_COUNT_FILE" GH_RETRY_MODE=timeout bash -c '
  source "$0/lib.sh"
  if gh api repos/test/repo/issues/999/comments --method POST --raw-field body=test; then echo API_WRITE_STATUS=0; else echo API_WRITE_STATUS=$?; fi
' "$SCRIPT_DIR" 2>&1)"; then
  GH_API_WRITE_STATUS=0
else
  GH_API_WRITE_STATUS=$?
fi
assert_eq "gh(): does not replay a POST API write" "1" "$(cat "$GH_RETRY_COUNT_FILE")"
assert_contains "gh(): timed-out POST preserves its failure" "$GH_API_WRITE_OUT" "API_WRITE_STATUS=124"
assert_not_contains "gh(): timed-out POST gets no retry" "$GH_API_WRITE_OUT" "retrying once"
rm -rf "$GH_RETRY_BIN" "$GH_RETRY_COUNT_FILE"

# Owner admission opts into an absolute parent-local cutoff. Each GH attempt
# and retry rechecks the fake clock; nested calls stop before starting work
# that cannot fit, while callers with no opt-in retain their usual timeout.
GH_DEADLINE_BIN="$(mktemp -d)"
GH_DEADLINE_NOW_FILE="$(mktemp)"
GH_DEADLINE_COUNT_FILE="$(mktemp)"
cat > "$GH_DEADLINE_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
count=0
[ ! -r "$GH_DEADLINE_COUNT_FILE" ] || count="$(cat "$GH_DEADLINE_COUNT_FILE")"
count=$((count + 1))
printf '%s\n' "$count" > "$GH_DEADLINE_COUNT_FILE"
case "$GH_DEADLINE_MODE:$count" in
  nested:1)
    printf '%s\n' "$GH_DEADLINE_AFTER_FIRST_MS" > "$GH_DEADLINE_NOW_FILE"
    echo FIRST_READ_OK
    ;;
  retry-allowed:1)
    printf '%s\n' "$GH_DEADLINE_AFTER_FIRST_MS" > "$GH_DEADLINE_NOW_FILE"
    echo 'gh: Gateway Timeout (HTTP 504)' >&2
    exit 1
    ;;
  retry-allowed:2) echo RETRY_OK ;;
  retry-refused:1)
    printf '%s\n' "$GH_DEADLINE_AFTER_FIRST_MS" > "$GH_DEADLINE_NOW_FILE"
    echo 'gh: Gateway Timeout (HTTP 504)' >&2
    exit 1
    ;;
  *) echo "unexpected fake gh call $count" >&2; exit 90 ;;
esac
FAKE_GH
cat > "$GH_DEADLINE_BIN/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
now="$(cat "$GH_DEADLINE_NOW_FILE")"
printf '%s\n' "$((now + ${1:-0} * 1000))" > "$GH_DEADLINE_NOW_FILE"
FAKE_SLEEP
chmod +x "$GH_DEADLINE_BIN/gh" "$GH_DEADLINE_BIN/sleep"
: > "$GH_DEADLINE_COUNT_FILE"
GH_DEADLINE_MODE=nested GH_DEADLINE_NOW_FILE="$GH_DEADLINE_NOW_FILE" \
  GH_DEADLINE_COUNT_FILE="$GH_DEADLINE_COUNT_FILE" GH_DEADLINE_AFTER_FIRST_MS=1014000 \
  GH_CALL_TIMEOUT_SEC=5 PATH="$GH_DEADLINE_BIN:$PATH" bash -c '
    source "$1/lib.sh"
    gh_call_now_ms() { cat "$GH_DEADLINE_NOW_FILE"; }
    unset ZF_GH_CALL_DEADLINE_EPOCH_MS
    ZF_GH_CALL_DEADLINE_EPOCH_MS=1020000
    export -n ZF_GH_CALL_DEADLINE_EPOCH_MS
    nested_owner_operation() {
      gh issue view 999 >/dev/null || return $?
      gh label list --repo test/repo >/dev/null
    }
    if nested_owner_operation; then result=0; else result=$?; fi
    printf "RESULT=%s\n" "$result"
  ' _ "$SCRIPT_DIR" > "$GH_DEADLINE_NOW_FILE.out" 2>&1
assert_eq 'gh(): nested calls recheck the deadline before each real API call' 1 "$(cat "$GH_DEADLINE_COUNT_FILE")"
assert_contains 'gh(): a later nested read is refused before its API call' "$(cat "$GH_DEADLINE_NOW_FILE.out")" 'RESULT=124'
assert_contains 'gh(): reports a nested deadline refusal' "$(cat "$GH_DEADLINE_NOW_FILE.out")" 'cannot fit one bounded attempt'

: > "$GH_DEADLINE_COUNT_FILE"
printf '2000000\n' > "$GH_DEADLINE_NOW_FILE"
GH_DEADLINE_MODE=retry-allowed GH_DEADLINE_NOW_FILE="$GH_DEADLINE_NOW_FILE" \
  GH_DEADLINE_COUNT_FILE="$GH_DEADLINE_COUNT_FILE" GH_DEADLINE_AFTER_FIRST_MS=2009000 \
  GH_CALL_TIMEOUT_SEC=5 PATH="$GH_DEADLINE_BIN:$PATH" bash -c '
    source "$1/lib.sh"
    gh_call_now_ms() { cat "$GH_DEADLINE_NOW_FILE"; }
    ZF_GH_CALL_DEADLINE_EPOCH_MS=2020000
    export -n ZF_GH_CALL_DEADLINE_EPOCH_MS
    gh issue view 999
  ' _ "$SCRIPT_DIR" > "$GH_DEADLINE_NOW_FILE.retry-ok" 2>&1
assert_eq 'gh(): a retry that still fits the deadline runs once' 2 "$(cat "$GH_DEADLINE_COUNT_FILE")"
assert_contains 'gh(): bounded read retry returns its result' "$(cat "$GH_DEADLINE_NOW_FILE.retry-ok")" RETRY_OK

: > "$GH_DEADLINE_COUNT_FILE"
printf '3000000\n' > "$GH_DEADLINE_NOW_FILE"
GH_DEADLINE_MODE=retry-refused GH_DEADLINE_NOW_FILE="$GH_DEADLINE_NOW_FILE" \
  GH_DEADLINE_COUNT_FILE="$GH_DEADLINE_COUNT_FILE" GH_DEADLINE_AFTER_FIRST_MS=3012000 \
  GH_CALL_TIMEOUT_SEC=5 PATH="$GH_DEADLINE_BIN:$PATH" bash -c '
    source "$1/lib.sh"
    gh_call_now_ms() { cat "$GH_DEADLINE_NOW_FILE"; }
    ZF_GH_CALL_DEADLINE_EPOCH_MS=3020000
    export -n ZF_GH_CALL_DEADLINE_EPOCH_MS
    if gh issue view 999; then result=0; else result=$?; fi
    printf "RESULT=%s\n" "$result"
  ' _ "$SCRIPT_DIR" > "$GH_DEADLINE_NOW_FILE.retry-refused" 2>&1
assert_eq 'gh(): a retry is not started if its backoff and attempt cross the deadline' 1 "$(cat "$GH_DEADLINE_COUNT_FILE")"
assert_contains 'gh(): reports a refused read retry' "$(cat "$GH_DEADLINE_NOW_FILE.retry-refused")" 'skipping read retry'

if ! (
  unset ZF_GH_CALL_DEADLINE_EPOCH_MS
  GH_CALL_TIMEOUT_SEC=7
  [ "$(gh_tick_attempt_timeout_sec)" = 7 ]
  owner_deadline_scope() {
    local ZF_GH_CALL_DEADLINE_EPOCH_MS=1234567890000
    export -n ZF_GH_CALL_DEADLINE_EPOCH_MS
    [ "$(bash -c 'printf %s "${ZF_GH_CALL_DEADLINE_EPOCH_MS:-unset}"')" = unset ]
  }
  owner_deadline_scope
); then
  echo 'not ok - gh(): opt-in deadline is parent-local and no-deadline behavior keeps configured timeout' >&2
  exit 1
fi
ok 'gh(): owner deadline bounds nested calls and retries without reaching children or other callers'
rm -rf "$GH_DEADLINE_BIN" "$GH_DEADLINE_NOW_FILE" "$GH_DEADLINE_COUNT_FILE" \
  "$GH_DEADLINE_NOW_FILE.out" "$GH_DEADLINE_NOW_FILE.retry-ok" "$GH_DEADLINE_NOW_FILE.retry-refused"

# --- is_on_hold(): a failed gh read must read as ON-HOLD, not "no labels" --
IOH_BIN="$(mktemp -d)"
cat > "$IOH_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = issue ] && [ "$2" = list ]; then
  case "$ISSUE_VIEW_MODE" in
    fail) echo "gh: TLS handshake timeout" >&2; exit 1 ;;
    onhold) echo 999 ;;
    none) : ;;
  esac
  exit 0
fi
case "$ISSUE_VIEW_MODE" in
  fail) echo "gh: TLS handshake timeout" >&2; exit 1 ;;
  onhold) echo "on-hold" ;;
  none) : ;;
esac
exit 0
FAKE_GH
chmod +x "$IOH_BIN/gh"

IOH_FAIL_OUT="$(PATH="$IOH_BIN:$PATH" ISSUE_VIEW_MODE=fail REPO=test/repo bash -c '
  source "$0/lib.sh"
  if is_on_hold 999; then echo "RESULT=on-hold"; else echo "RESULT=not-on-hold"; fi
  echo "FAILURE-COUNT=$ON_HOLD_QUERY_FAILURE_COUNT"
  echo "FAILURE-ISSUES=$ON_HOLD_QUERY_FAILURE_ISSUES"
' "$SCRIPT_DIR" 2>&1)"
assert_contains "is_on_hold: a failed gh read fails closed as ON-HOLD, not as clear" \
  "$IOH_FAIL_OUT" "RESULT=on-hold"
assert_contains "...and says so loudly on stderr, naming the issue" \
  "$IOH_FAIL_OUT" "is_on_hold: gh issue view failed for #999"
assert_contains "is_on_hold: records unreadable pause checks for tick-level visibility" \
  "$IOH_FAIL_OUT" "FAILURE-COUNT=1"
assert_contains "is_on_hold: records the skipped issue number once" \
  "$IOH_FAIL_OUT" "FAILURE-ISSUES=999"

IOH_NONE_OUT="$(PATH="$IOH_BIN:$PATH" ISSUE_VIEW_MODE=none REPO=test/repo bash -c '
  source "$0/lib.sh"
  if is_on_hold 999; then echo "RESULT=on-hold"; else echo "RESULT=not-on-hold"; fi
' "$SCRIPT_DIR" 2>&1)"
assert_contains "is_on_hold: a genuinely label-less issue (gh succeeds) still reads as not on-hold" \
  "$IOH_NONE_OUT" "RESULT=not-on-hold"

IOH_ONHOLD_OUT="$(PATH="$IOH_BIN:$PATH" ISSUE_VIEW_MODE=onhold REPO=test/repo bash -c '
  source "$0/lib.sh"
  if is_on_hold 999; then echo "RESULT=on-hold"; else echo "RESULT=not-on-hold"; fi
' "$SCRIPT_DIR" 2>&1)"
assert_contains "is_on_hold: a genuinely on-hold issue still reads as on-hold" \
  "$IOH_ONHOLD_OUT" "RESULT=on-hold"

# --- has_label(): a failed gh read must return a third, distinct "unknown" -
# code (2), not collapse into the same code as a confirmed-absent label (1)
# -- has_label()'s callers use it in BOTH directions (issue-pipeline.sh's
# `&&`-gates want presence to block; run-recut.sh's `||` wants presence
# required), so only a distinct code lets every caller fail closed.
HL_BIN="$(mktemp -d)"
cat > "$HL_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = issue ] && [ "$2" = list ]; then
  case "$ISSUE_VIEW_MODE" in
    fail) echo "gh: TLS handshake timeout" >&2; exit 1 ;;
    present) echo 999 ;;
    absent) : ;;
  esac
  exit 0
fi
case "$ISSUE_VIEW_MODE" in
  fail) echo "gh: TLS handshake timeout" >&2; exit 1 ;;
  present) echo "needs-owner" ;;
  absent) : ;;
esac
exit 0
FAKE_GH
chmod +x "$HL_BIN/gh"

HL_FAIL_OUT="$(PATH="$HL_BIN:$PATH" ISSUE_VIEW_MODE=fail REPO=test/repo bash -c '
  source "$0/lib.sh"
  has_label 999 needs-owner
  echo "RC=$?"
' "$SCRIPT_DIR" 2>&1)"
assert_contains "has_label: a failed gh read returns the distinct unknown code 2, not the confirmed-absent code 1" \
  "$HL_FAIL_OUT" "RC=2"
assert_contains "...and says so loudly, naming the issue and the label" \
  "$HL_FAIL_OUT" 'has_label: gh issue view failed for #999 while checking for label "needs-owner"'

HL_PRESENT_OUT="$(PATH="$HL_BIN:$PATH" ISSUE_VIEW_MODE=present REPO=test/repo bash -c '
  source "$0/lib.sh"
  has_label 999 needs-owner
  echo "RC=$?"
' "$SCRIPT_DIR" 2>&1)"
assert_contains "has_label: confirmed present returns 0" "$HL_PRESENT_OUT" "RC=0"

HL_ABSENT_OUT="$(PATH="$HL_BIN:$PATH" ISSUE_VIEW_MODE=absent REPO=test/repo bash -c '
  source "$0/lib.sh"
  has_label 999 needs-owner
  echo "RC=$?"
' "$SCRIPT_DIR" 2>&1)"
assert_contains "has_label: confirmed absent returns 1" "$HL_ABSENT_OUT" "RC=1"

# Per-tick label reads batch once per label, then invalidate after a local
# label edit so the next hold gate sees the changed issue state.
LABEL_CACHE_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$LABEL_CACHE_HOME/model-policy.json"
LABEL_CACHE_BIN="$(mktemp -d)"
cat > "$LABEL_CACHE_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LABEL_CACHE_LOG"
if [ "$1" = issue ] && [ "$2" = list ]; then
  label=""
  for ((i=1; i<=$#; i++)); do
    if [ "${!i}" = --label ]; then j=$((i+1)); label="${!j}"; fi
  done
  case "$label" in
    on-hold)
      count="$(cat "$LABEL_CACHE_HOLD_COUNT" 2>/dev/null || echo 0)"
      count=$((count + 1))
      echo "$count" > "$LABEL_CACHE_HOLD_COUNT"
      if [ "$count" -eq 1 ]; then echo 999; else printf '998\n999\n'; fi
      ;;
    needs-owner) echo 999 ;;
    *) echo "unexpected label query: $label" >&2; exit 1 ;;
  esac
  exit 0
fi
if [ "$1" = issue ] && [ "$2" = edit ]; then exit 0; fi
echo "unexpected fake gh invocation: $*" >&2
exit 1
FAKE_GH
chmod +x "$LABEL_CACHE_BIN/gh"
LABEL_CACHE_OUT="$(
  PATH="$LABEL_CACHE_BIN:$PATH" AGENT_HOME="$LABEL_CACHE_HOME" AGENT_DRY_RUN=0 REPO=test/repo \
    LABEL_CACHE_LOG="$LABEL_CACHE_HOME/gh.log" LABEL_CACHE_HOLD_COUNT="$LABEL_CACHE_HOME/hold-count" \
    bash -c '
      source "$0/lib.sh"
      is_on_hold 999 && held=1 || held=0
      is_on_hold 998 && other_held=1 || other_held=0
      has_label 999 needs-owner && owns=1 || owns=0
      has_label 998 needs-owner; absent_rc=$?
      guarded_write gh issue edit 998 --repo test/repo --add-label on-hold || exit 1
      is_on_hold 998 && changed_held=1 || changed_held=0
      printf "held=%s other_held=%s owns=%s absent_rc=%s changed_held=%s\n" \
        "$held" "$other_held" "$owns" "$absent_rc" "$changed_held"
      printf "bulk_queries=%s point_views=%s\n" \
        "$ISSUE_LABEL_BULK_QUERY_COUNT" "$ISSUE_LABEL_POINT_QUERY_COUNT"
    ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "label cache keeps hold and presence checks exact" "$LABEL_CACHE_OUT" \
  "held=1 other_held=0 owns=1 absent_rc=1 changed_held=1"
assert_contains "label cache batches per label and reloads after an issue edit" "$LABEL_CACHE_OUT" \
  "bulk_queries=3 point_views=0"
assert_eq "label cache avoids one GitHub view per candidate" "0" \
  "$(grep -c '^issue view' "$LABEL_CACHE_HOME/gh.log" || true)"
rm -rf "$LABEL_CACHE_HOME" "$LABEL_CACHE_BIN"

# --- stage_unit_active()/stage_unit_count(): a failed systemctl query must -
# fail closed as "active"/"full", never as "confirmed idle". `--quiet`
# suppresses is-active's normal state text entirely (measured live), so ANY
# output on a non-zero exit already means systemctl itself is complaining;
# list-units genuinely can print nothing on a normal zero-match success, so
# there the signal is the exit code, not output emptiness.
SUA_BIN="$(mktemp -d)"
cat > "$SUA_BIN/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
case "$SYSTEMCTL_MODE" in
  fail) echo "Failed to connect to user scope bus via local transport: No such file or directory" >&2; exit 1 ;;
  active) exit 0 ;;
  inactive) exit 4 ;;
  empty-list) exit 0 ;;
  two-units) printf 'zf-implement-1.service loaded active running\nzf-implement-2.service loaded active running\n'; exit 0 ;;
  train-and-release) printf 'zf-release-train.service loaded active running\nzf-release-batch.service loaded active running\n'; exit 0 ;;
  train-only) printf 'zf-release-train.service loaded active running\n'; exit 0 ;;
  fail-list) echo "Failed to connect to user scope bus via local transport: No such file or directory" >&2; exit 1 ;;
esac
FAKE_SYSTEMCTL
chmod +x "$SUA_BIN/systemctl"

SUA_FAIL_OUT="$(PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=fail bash -c '
  source "$0/lib.sh"
  if stage_unit_active implement 123; then echo "RESULT=active"; else echo "RESULT=inactive"; fi
' "$SCRIPT_DIR" 2>&1)"
assert_contains "stage_unit_active: a failed systemctl query fails closed as ACTIVE, not confirmed-inactive" \
  "$SUA_FAIL_OUT" "RESULT=active"
assert_contains "...loudly, naming the unit" \
  "$SUA_FAIL_OUT" "stage_unit_active: systemctl --user is-active could not be queried for zf-implement-123"

SUA_INACTIVE_OUT="$(PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=inactive bash -c '
  source "$0/lib.sh"
  if stage_unit_active implement 123; then echo "RESULT=active"; else echo "RESULT=inactive"; fi
' "$SCRIPT_DIR" 2>&1)"
assert_contains "stage_unit_active: a genuinely inactive unit (no output, non-zero exit) reads as inactive" \
  "$SUA_INACTIVE_OUT" "RESULT=inactive"

SUA_ACTIVE_OUT="$(PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=active bash -c '
  source "$0/lib.sh"
  if stage_unit_active implement 123; then echo "RESULT=active"; else echo "RESULT=inactive"; fi
' "$SCRIPT_DIR" 2>&1)"
assert_contains "stage_unit_active: a genuinely active unit reads as active" "$SUA_ACTIVE_OUT" "RESULT=active"

# `|| true` on the last line inside each inner bash -c: stage_unit_count()
# deliberately returns non-zero on the failure scenario, and as the LAST
# command of an inner `bash -c` script, that becomes the subprocess's own
# exit code -- which the OUTER `SUC_FAIL_OUT="$(...)"` bare assignment,
# under this file's own `set -e`, would otherwise treat as this test
# harness's own failure and abort the whole suite (not a "not ok", a
# silent death). The captured text is unaffected either way.
SUC_FAIL_OUT="$(PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=fail-list bash -c '
  source "$0/lib.sh"
  stage_unit_count implement || true
' "$SCRIPT_DIR" 2>&1)"
assert_contains "stage_unit_count: a failed systemctl query fails closed to a huge sentinel count, not zero" \
  "$SUC_FAIL_OUT" "999999999"
assert_contains "...loudly, naming the stage" \
  "$SUC_FAIL_OUT" "stage_unit_count: systemctl --user list-units could not be queried for stage implement"

SUC_TRAIN_OUT="$(PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=train-only bash -c '
  source "$0/lib.sh"
  stage_unit_count release || true
' "$SCRIPT_DIR" 2>&1)"
assert_eq "stage_unit_count: a running release train leaves the release slot free" "0" "$SUC_TRAIN_OUT"
SUC_TRAIN_BATCH_OUT="$(PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=train-and-release bash -c '
  source "$0/lib.sh"
  stage_unit_count release || true
' "$SCRIPT_DIR" 2>&1)"
assert_eq "stage_unit_count: a real release unit still counts beside the train" "1" "$SUC_TRAIN_BATCH_OUT"

SUC_EMPTY_OUT="$(PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=empty-list bash -c '
  source "$0/lib.sh"
  stage_unit_count implement || true
' "$SCRIPT_DIR" 2>&1)"
assert_eq "stage_unit_count: a genuine zero-unit answer (systemctl exits 0, no output) still reads as 0" \
  "0" "$SUC_EMPTY_OUT"

# 2026-09-16: the assertion above passed all along -- it reads stdout, and
# stdout was always right. What was wrong was the EXIT STATUS: `grep -c .`
# exits 1 when it counts zero, and that became this function's status. The
# `|| true` in the harness above hides exactly that, so it needed its own
# assertion. The second check below is the shape that actually died in
# production: send_heartbeat()'s bare `running=$((running + $(stage_unit_
# count "$stage")))`, where a command substitution's status becomes the
# assignment's status and `set -e` takes it. The five call sites in
# issue-pipeline.sh pass the same function through as an ARGUMENT to
# cap_slots_remaining, where the outer command's status wins -- which is why
# the scheduler ran fine for days while the once-a-day heartbeat path died
# the first time it was walked with every stage idle.
SUC_EMPTY_STATUS=0
PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=empty-list bash -c '
  source "$0/lib.sh"
  stage_unit_count implement >/dev/null
' "$SCRIPT_DIR" 2>/dev/null || SUC_EMPTY_STATUS=$?
assert_eq "stage_unit_count: a genuine zero-unit answer also EXITS 0 (zero is an answer, not a failure)" \
  "0" "$SUC_EMPTY_STATUS"

SUC_SETE_STATUS=0
PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=empty-list bash -c '
  set -euo pipefail
  source "$0/lib.sh"
  running=0
  running=$((running + $(stage_unit_count implement)))
  [ "$running" = "0" ]
' "$SCRIPT_DIR" 2>/dev/null || SUC_SETE_STATUS=$?
assert_eq "stage_unit_count: a bare assignment from it does not kill a set -e caller when every unit is idle (local metrics shape)" \
  "0" "$SUC_SETE_STATUS"

SUC_TWO_OUT="$(PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=two-units bash -c '
  source "$0/lib.sh"
  stage_unit_count implement || true
' "$SCRIPT_DIR" 2>&1)"
assert_eq "stage_unit_count: two loaded units still count as 2" "2" "$SUC_TWO_OUT"

assert_eq "cap_slots_remaining: the fail-closed sentinel count clamps a real cap to zero free slots" \
  "0" "$(cap_slots_remaining 4 999999999)"

# --- loop_break_check(): the escalation-marker read must capture-then-grep,
# never pipe a live `gh api --paginate` producer straight into `grep -q` --
# same SIGPIPE-under-pipefail class supervise-pipeline.sh's issue_comment_
# has_marker()/check_dispatch_stall() were already fixed for (comments name
# it there). Not reliably reproducible as a timing race in a unit test (the
# codebase's own fix for the sibling instances took the same approach:
# supervise-pipeline.test.sh's scenario 5/6 proves correct multi-line
# detection rather than forcing the race) -- this is the static half of
# that same proof: the vulnerable shape is gone from the source.
LBC_LINE="$(grep -n 'gh api "repos/\$REPO/issues/\$n/comments" --paginate' "$SCRIPT_DIR/lib.d/supervisor-inbox.sh" | head -1 | cut -d: -f1)"
LBC_BODY="$(sed -n "${LBC_LINE},+6p" "$SCRIPT_DIR/lib.d/supervisor-inbox.sh")"
assert_not_contains "loop_break_check: the escalation-marker read no longer pipes gh api directly into grep -q" \
  "$LBC_BODY" '| grep -qF "$LOOP_ESCALATION_MARKER"'
assert_contains "...it captures into a variable first, then greps the captured text" \
  "$LBC_BODY" 'comment_bodies="$(gh api'

# label_transition_events() counts alternations between consecutive selected labels.
# Issue 1703's real timeline on 2026-09-29, ready -> advisor -> recut -> ready,
# was held as a four-flip loop when unlabeled events counted too. #3685 also
# shows repeated adds of the same label must collapse before counting flips.
LTE_TIMELINE='[{"event":"labeled","label":{"name":"needs-advisor"},"created_at":"2026-09-29T10:24:21Z"},{"event":"unlabeled","label":{"name":"ready-for-agent"},"created_at":"2026-09-29T10:24:21Z"},{"event":"labeled","label":{"name":"needs-recut"},"created_at":"2026-09-29T11:56:59Z"},{"event":"unlabeled","label":{"name":"needs-advisor"},"created_at":"2026-09-29T11:56:59Z"},{"event":"labeled","label":{"name":"ready-for-agent"},"created_at":"2026-09-29T15:44:59Z"},{"event":"unlabeled","label":{"name":"needs-recut"},"created_at":"2026-09-29T15:44:59Z"}]'
LTE_PINGPONG='[{"event":"labeled","label":{"name":"ready-for-agent"},"created_at":"2026-09-29T09:50:00Z"},{"event":"labeled","label":{"name":"needs-advisor"},"created_at":"2026-09-29T10:00:00Z"},{"event":"unlabeled","label":{"name":"ready-for-agent"},"created_at":"2026-09-29T10:00:00Z"},{"event":"labeled","label":{"name":"ready-for-agent"},"created_at":"2026-09-29T10:10:00Z"},{"event":"unlabeled","label":{"name":"needs-advisor"},"created_at":"2026-09-29T10:10:00Z"},{"event":"labeled","label":{"name":"needs-advisor"},"created_at":"2026-09-29T10:20:00Z"},{"event":"unlabeled","label":{"name":"ready-for-agent"},"created_at":"2026-09-29T10:20:00Z"},{"event":"labeled","label":{"name":"ready-for-agent"},"created_at":"2026-09-29T10:30:00Z"},{"event":"unlabeled","label":{"name":"needs-advisor"},"created_at":"2026-09-29T10:30:00Z"}]'
LTE_3685='[{"event":"labeled","label":{"name":"ready-for-agent"},"created_at":"2026-10-13T02:12:00Z"},{"event":"unlabeled","label":{"name":"ready-for-agent"},"created_at":"2026-10-13T02:38:00Z"},{"event":"labeled","label":{"name":"ready-for-agent"},"created_at":"2026-10-13T02:41:00Z"},{"event":"labeled","label":{"name":"needs-advisor"},"created_at":"2026-10-13T04:25:00Z"},{"event":"unlabeled","label":{"name":"ready-for-agent"},"created_at":"2026-10-13T04:25:00Z"},{"event":"labeled","label":{"name":"ready-for-agent"},"created_at":"2026-10-13T04:55:00Z"},{"event":"unlabeled","label":{"name":"needs-advisor"},"created_at":"2026-10-13T04:55:00Z"}]'
lte_count() {
  (
    LTE_JSON="$1"
    gh() { local q=""; while [ $# -gt 0 ]; do [ "$1" = --jq ] && q="$2"; shift; done; jq -r "$q" <<< "$LTE_JSON"; }
    label_transition_events 1703 ready-for-agent needs-advisor 2026-09-28T00:00:00Z | grep -c . || true
  )
}
assert_eq "label_transition_events: forward route through recut has one watched-label alternation" "1" "$(lte_count "$LTE_TIMELINE")"
assert_eq "label_transition_events: #3685 repeated ready label plus one advisor round trip counts two flips" "2" "$(lte_count "$LTE_3685")"
assert_eq "label_transition_events: two full ready/advisor round trips count four flips" "4" "$(lte_count "$LTE_PINGPONG")"

# --- codex_quota_exhausted / state_unbump_attempts
# 2026-09-17: the Codex subscription hit its account-wide usage limit and
# every identity refused. The refusal was handled; the BOOKKEEPING was not --
# attempts are bumped at dispatch, so each refusal spent one of the ticket's
# four give-up attempts, and four of those conclude the ticket as
# `not-completed` with a maintainer-visible issue comment. Over a multi-day
# window and a 101-ticket queue that falsely concludes the whole queue. ------
CQE_HOME="$(mktemp -d)"
CQE_OUT="$(
  AGENT_HOME="$CQE_HOME" bash -c '
    set -uo pipefail
    source "$0/lib.sh"
    mkdir -p "$STATE_DIR"
    notify_maintainer() { :; }

    codex_quota_exhausted && echo "MARKER-ABSENT:exhausted" || echo "MARKER-ABSENT:open"

    printf "%s\n" "$(( $(date +%s) + 600 ))" > "$CODEX_EXHAUSTED_MARKER_FILE"
    codex_quota_exhausted && echo "FUTURE:exhausted" || echo "FUTURE:open"

    printf "%s\n" "$(( $(date +%s) - 600 ))" > "$CODEX_EXHAUSTED_MARKER_FILE"
    codex_quota_exhausted && echo "PAST:exhausted" || echo "PAST:open"

    printf "%s\n" "not-a-number" > "$CODEX_EXHAUSTED_MARKER_FILE"
    codex_quota_exhausted && echo "CORRUPT:exhausted" || echo "CORRUPT:open"

    echo "{\"attempts\": 3}" > "$STATE_DIR/700001.json"
    state_unbump_attempts 700001
    echo "UNBUMP3:$(jq -r .attempts "$STATE_DIR/700001.json")"

    echo "{\"attempts\": 0}" > "$STATE_DIR/700002.json"
    state_unbump_attempts 700002
    echo "UNBUMP0:$(jq -r .attempts "$STATE_DIR/700002.json")"
  ' "$SCRIPT_DIR" 2>/dev/null
)" || true
# `|| true` is load-bearing and is NOT the stage_unit_count mistake (V136).
# There the `|| true` hid the only thing under test; here the assertions below
# check the CONTENT of $CQE_OUT, and the red case -- lib.sh without these
# functions -- makes the subshell exit 127. Without this the bare assignment
# would take that 127 under `set -e` and kill this whole suite before a single
# assertion ran, which reads as "no failures" rather than as red. Verified:
# with lib.sh stashed the suite exited 127 having printed zero `not ok` lines.
rm -rf "$CQE_HOME"
assert_contains "codex_quota_exhausted: no marker file means not exhausted (fail OPEN -- a wrong 'exhausted' would idle the whole pipeline)" \
  "$CQE_OUT" "MARKER-ABSENT:open"
assert_contains "codex_quota_exhausted: a deadline in the future means exhausted" \
  "$CQE_OUT" "FUTURE:exhausted"
assert_contains "codex_quota_exhausted: a deadline that has passed means not exhausted (the window reopens on its own, no cleanup step)" \
  "$CQE_OUT" "PAST:open"
assert_contains "codex_quota_exhausted: a non-numeric marker reads as not exhausted, not as a permanent outage" \
  "$CQE_OUT" "CORRUPT:open"
assert_contains "state_unbump_attempts: gives back exactly one attempt" \
  "$CQE_OUT" "UNBUMP3:2"
assert_contains "state_unbump_attempts: floors at zero, never goes negative" \
  "$CQE_OUT" "UNBUMP0:0"

# resolve_guarded_reviewer during the outage. Both matter for
# the same reason: run-advisor.sh walks its ladder on a refusal, and reaching
# the END of that ladder writes the PAUSE file, which stops EVERY stage for
# an hour. So including a Codex rung during a quota window did not merely
# waste that rung -- one provider outage idled the Claude legs too.
CU_HOME="$(mktemp -d)"
CU_OUT="$(
  AGENT_HOME="$CU_HOME" bash -c '
    set -uo pipefail
    source "$0/lib.sh"
    touch "$CODEX_PROBE_MARKER"
    echo "REVIEWER-OPEN:$(resolve_guarded_reviewer "$POLICY_WORK_IDENTITY" 2>/dev/null)"
    printf "%s\n" "$(( $(date +%s) + 600 ))" > "$CODEX_EXHAUSTED_MARKER_FILE"
    codex_probe_ok && echo "PROBE-STILL-OK:yes" || echo "PROBE-STILL-OK:no"
    echo "REVIEWER-CLOSED:$(resolve_guarded_reviewer "$POLICY_WORK_IDENTITY" 2>/dev/null)"
    echo "NON-CODEX-REVIEWER:$(resolve_guarded_reviewer "codex:unconfigured-$POLICY_WORK_MODEL:$POLICY_WORK_EFFORT" 2>/dev/null)"
  ' "$SCRIPT_DIR" 2>/dev/null
)" || true
rm -rf "$CU_HOME"
assert_contains "a closed quota window does NOT touch codex_probe_ok -- safety and availability stay separate predicates" \
  "$CU_OUT" "PROBE-STILL-OK:yes"
assert_contains "resolve_guarded_reviewer: admits a codex identity while the quota window is open" \
  "$CU_OUT" "REVIEWER-OPEN:$POLICY_WORK_IDENTITY"
assert_contains "resolve_guarded_reviewer: falls back to the work identity when the quota window is closed" \
  "$CU_OUT" "REVIEWER-CLOSED:$POLICY_WORK_IDENTITY"
assert_contains "resolve_guarded_reviewer: a non-codex identity is returned untouched, outage or not" \
  "$CU_OUT" "NON-CODEX-REVIEWER:$POLICY_WORK_IDENTITY"

# --- provider-specific quota holds: Codex and web-advisor-provider stay independent ---
MIXED_CONFIG_HOME="$(mktemp -d)"
MIXED_CONFIG_OUT="$(AGENT_HOME="$MIXED_CONFIG_HOME" bash -c '
  set -euo pipefail
  source "$0/lib.sh"
  mkdir -p "$STATE_DIR"
  jq ".roles.advisor.disabled = false" "$MODEL_POLICY_DEFAULT" > "$MODEL_POLICY_FILE"
  printf "%s\n" "{\"attempts\":1,\"model_policy\":{\"active\":{\"role\":\"work\"}}}" > "$STATE_DIR/700100.json"
  failure="$(printf "%s\n" "stream disconnected before completion" "ERROR: unexpected status 404: The model $POLICY_WORK_MODEL may not exist or you may not have access")"
  pause_for_backoff 700100 "$failure" 1 1 codex "$POLICY_WORK_IDENTITY" run-implement:implement
  echo "BLOCKED:$(model_config_fault_blocked work "$POLICY_WORK_IDENTITY" && echo yes || echo no)"
  echo "ATTEMPTS:$(jq -r .attempts "$STATE_DIR/700100.json")"
  echo "FAULTS:$(wc -l < "$ENV_FAULT_DIR/env:model-config:work:$POLICY_WORK_IDENTITY.log")"
  echo "OUTAGE-EVENTS:$([ -s "$CODEX_PROVIDER_FAILURE_EVENTS_FILE" ] && echo yes || echo no)"
  echo "HOLD:$([ -e "$CODEX_EXHAUSTED_MARKER_FILE" ] && echo yes || echo no)"
  echo "BACKOFF:$(jq -r ".model_failure_backoff // null" "$STATE_DIR/700100.json")"
' "$SCRIPT_DIR" 2>&1)" || true
rm -rf "$MIXED_CONFIG_HOME"
assert_contains "mixed disconnect and final 404 blocks the bad configuration" "$MIXED_CONFIG_OUT" 'BLOCKED:yes'
assert_contains "mixed disconnect and final 404 refunds the attempt" "$MIXED_CONFIG_OUT" 'ATTEMPTS:0'
assert_contains "mixed disconnect and final 404 records a configuration fault" "$MIXED_CONFIG_OUT" 'FAULTS:1'
assert_contains "mixed disconnect and final 404 does not count as provider outage" "$MIXED_CONFIG_OUT" 'OUTAGE-EVENTS:no'
assert_contains "mixed disconnect and final 404 leaves Codex circuit open" "$MIXED_CONFIG_OUT" 'HOLD:no'
assert_contains "mixed disconnect and final 404 has no timed issue backoff" "$MIXED_CONFIG_OUT" 'BACKOFF:null'

CONFIG_HOME="$(mktemp -d)"
CONFIG_OUT="$(AGENT_HOME="$CONFIG_HOME" bash -c '
  set -euo pipefail
  source "$0/lib.sh"
  mkdir -p "$STATE_DIR"
  jq ".roles.advisor.disabled = false" "$MODEL_POLICY_DEFAULT" > "$MODEL_POLICY_FILE"
  printf "%s\n" "{\"attempts\":1,\"model_policy\":{\"active\":{\"role\":\"work\"}}}" > "$STATE_DIR/700101.json"
  failure="{\"is_error\":true,\"api_error_status\":404,\"result\":\"model ($POLICY_WORK_MODEL) may not exist\"}"
  pause_for_backoff 700101 "$failure" 1 1 codex "$POLICY_WORK_IDENTITY" run-implement:implement
  echo "KIND:$(model_call_failure_kind "$failure" 1)"
  echo "FAULTS:$(wc -l < "$ENV_FAULT_DIR/env:model-config:work:$POLICY_WORK_IDENTITY.log")"
  echo "FIRST-ALERTS:$(grep -cF "env:model-config:work:$POLICY_WORK_IDENTITY" "$AGENT_HOME/supervisor-inbox")"
  echo "ATTEMPTS:$(jq -r .attempts "$STATE_DIR/700101.json")"
  echo "PAUSE:$([ -e "$PAUSE_FILE" ] && echo yes || echo no)"
  echo "HOLD:$([ -e "$CODEX_EXHAUSTED_MARKER_FILE" ] && echo yes || echo no)"
  echo "BLOCKED:$(model_config_fault_blocked work "$POLICY_WORK_IDENTITY" && echo yes || echo no)"
  touch -d "2 days ago" "$AGENT_HOME/model-config-work.json"
  echo "OLD-BLOCKED:$(model_config_fault_blocked work "$POLICY_WORK_IDENTITY" && echo yes || echo no)"
  echo "UNSUPPORTED:$(model_call_is_configuration_error "unsupported identity" 64 && echo config || echo other)"
  echo "BAD-ARGUMENT:$(model_call_is_configuration_error "error: unexpected argument --effort found" 2 && echo config || echo other)"
  pause_for_backoff 700101 "$failure" 1 1 codex "$POLICY_WORK_IDENTITY" run-implement:implement
  echo "REPEAT-FAULTS:$(wc -l < "$ENV_FAULT_DIR/env:model-config:work:$POLICY_WORK_IDENTITY.log")"
  echo "REPEAT-ALERTS:$(grep -cF "env:model-config:work:$POLICY_WORK_IDENTITY" "$AGENT_HOME/supervisor-inbox")"
  printf "%s\n" "{\"attempts\":1}" > "$STATE_DIR/700102.json"
  pause_for_backoff 700102 "{\"is_error\":true,\"api_error_status\":404,\"result\":\"model slug missing\"}" 1 1 web-advisor-provider "$POLICY_ADVISOR_IDENTITY" run-advisor:advisor
  echo "ADVISOR-FAULT:$(wc -l < "$ENV_FAULT_DIR/env:model-config:advisor:$POLICY_ADVISOR_IDENTITY.log")"
  echo "ADVISOR-HOLD:$([ -e "$WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE" ] && echo yes || echo no)"
  printf "%s\n" "{\"attempts\":1}" > "$STATE_DIR/700103.json"
  pause_for_backoff 700103 "{\"is_error\":true,\"api_error_status\":503,\"result\":\"Service Unavailable\"}" 1 1 web-advisor-provider "$POLICY_ADVISOR_IDENTITY" run-advisor:advisor
  echo "WEB-TRANSPORT-HOLD:$([ -e "$WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE" ] && echo yes || echo no)"
  echo "WEB-TRANSPORT-CODEX:$([ -e "$CODEX_EXHAUSTED_MARKER_FILE" ] && echo yes || echo no)"
  POLICY_CHANGED_MODEL="changed-$POLICY_WORK_MODEL"
  jq --arg model "$POLICY_CHANGED_MODEL" ".roles.work.model = \$model" "$MODEL_POLICY_FILE" > "$MODEL_POLICY_FILE.tmp"
  mv "$MODEL_POLICY_FILE.tmp" "$MODEL_POLICY_FILE"
  echo "CHANGED:$(model_config_fault_blocked work "codex:$POLICY_CHANGED_MODEL:$POLICY_WORK_EFFORT" && echo blocked || echo open)"
  jq --arg model "$POLICY_WORK_MODEL" ".roles.work.model = \$model | .roles.work.revision = 2" "$MODEL_POLICY_FILE" > "$MODEL_POLICY_FILE.tmp"
  mv "$MODEL_POLICY_FILE.tmp" "$MODEL_POLICY_FILE"
  printf "%s\n" "{\"attempts\":1}" > "$STATE_DIR/700104.json"
  pause_for_backoff 700104 "$failure" 1 1 codex "$POLICY_WORK_IDENTITY" run-implement:implement
  reconcile_quarantines
  echo "GENERIC-QUARANTINE:$([ -e "$QUARANTINE_DIR/implement.json" ] && echo yes || echo no)"
' "$SCRIPT_DIR" 2>&1)" || true
rm -rf "$CONFIG_HOME"
assert_contains "configuration 404 is execution" "$CONFIG_OUT" 'KIND:execution'
assert_contains "configuration fault enters ledger once" "$CONFIG_OUT" 'FAULTS:1'
assert_contains "first configuration fault alerts once" "$CONFIG_OUT" 'FIRST-ALERTS:1'
assert_contains "configuration fault refunds issue attempt" "$CONFIG_OUT" 'ATTEMPTS:0'
assert_contains "configuration fault never writes PAUSE" "$CONFIG_OUT" 'PAUSE:no'
assert_contains "configuration fault never opens provider hold" "$CONFIG_OUT" 'HOLD:no'
assert_contains "same role and identity remains blocked" "$CONFIG_OUT" 'BLOCKED:yes'
assert_contains "same configuration has no timed canary" "$CONFIG_OUT" 'OLD-BLOCKED:yes'
assert_contains "unsupported identity is configuration" "$CONFIG_OUT" 'UNSUPPORTED:config'
assert_contains "unsupported CLI argument is configuration" "$CONFIG_OUT" 'BAD-ARGUMENT:config'
assert_contains "repeat fault does not append or alert again" "$CONFIG_OUT" 'REPEAT-FAULTS:1'
assert_contains "repeat configuration fault does not alert again" "$CONFIG_OUT" 'REPEAT-ALERTS:1'
assert_contains "advisor configuration fault uses advisor role" "$CONFIG_OUT" 'ADVISOR-FAULT:1'
assert_contains "advisor configuration fault does not open web quota hold" "$CONFIG_OUT" 'ADVISOR-HOLD:no'
assert_contains "web transport failure opens only web provider hold" "$CONFIG_OUT" 'WEB-TRANSPORT-HOLD:yes'
assert_contains "web transport failure leaves Codex open" "$CONFIG_OUT" 'WEB-TRANSPORT-CODEX:no'
assert_contains "changed model identity resumes dispatch" "$CONFIG_OUT" 'CHANGED:open'
assert_contains "model config faults never acquire timed stage canary" "$CONFIG_OUT" 'GENERIC-QUARANTINE:no'

PROVIDER_LEDGER_HOME="$(mktemp -d)"
PROVIDER_LEDGER_OUT="$(AGENT_HOME="$PROVIDER_LEDGER_HOME" AGENT_DRY_RUN=0 PROVIDER_LIB_DIR="$SCRIPT_DIR" bash -c '
  set +e
  set -uo pipefail
  source "$PROVIDER_LIB_DIR/lib.sh"
  mkdir -p "$STATE_DIR"
  printf "%s\n" "{\"attempts\":1}" > "$STATE_DIR/700105.json"
  pause_for_backoff 700105 "stream disconnected before completion" 1 1 codex "$POLICY_WORK_IDENTITY" run-implement:implement
  echo "fault=$(wc -l < "$ENV_FAULT_DIR/env:provider-outage.log")"
  echo "attempts=$(jq -r .attempts "$STATE_DIR/700105.json")"
  echo "breaker_event=$([ -s "$CODEX_PROVIDER_FAILURE_EVENTS_FILE" ] && echo yes || echo no)"
' 2>&1)"
rm -rf "$PROVIDER_LEDGER_HOME"
assert_contains "Codex provider outage enters shared env fault ledger" "$PROVIDER_LEDGER_OUT" 'fault=1'
assert_contains "shared provider taxonomy does not change existing issue attempt behavior" "$PROVIDER_LEDGER_OUT" 'attempts=1'
assert_contains "existing Codex outage breaker still records its event" "$PROVIDER_LEDGER_OUT" 'breaker_event=yes'

WEBQ_HOME="$(mktemp -d)"
WEBQ_OUT="$(
  AGENT_HOME="$WEBQ_HOME" bash -c '
    set -uo pipefail
    source "$0/lib.sh"
    mkdir -p "$STATE_DIR"
    provider_quota_exhausted web-advisor-provider && echo "ABSENT:held" || echo "ABSENT:open"
    printf "%s\n" "$(( $(date +%s) + 600 ))" > "$WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE"
    provider_quota_exhausted web-advisor-provider && echo "FUTURE:held" || echo "FUTURE:open"
    codex_quota_exhausted && echo "CODEX:held" || echo "CODEX:open"
    printf "%s\n" "$(( $(date +%s) - 600 ))" > "$WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE"
    provider_quota_exhausted web-advisor-provider && echo "PAST:held" || echo "PAST:open"
    echo "{\"attempts\":2}" > "$STATE_DIR/700003.json"
    note_provider_quota_exhausted web-advisor-provider 700003 "unclassified refusal"
    echo "REFUND:$(jq -r .attempts "$STATE_DIR/700003.json")"
    codex_shape_epoch="$(parse_quota_reset_epoch "try again at Sep 30th, 2026 1:10 AM")"
    expected_epoch="$(date -d "Sep 30, 2026 1:10 AM" +%s)"
    echo "CODEX-SHAPE:$([ "$codex_shape_epoch" = "$expected_epoch" ] && echo yes || echo no)"
    if parse_quota_reset_epoch "ordinary failure without reset deadline" >/dev/null 2>&1; then
      echo "UNPARSEABLE:wrong"
    else
      echo "UNPARSEABLE:correct"
    fi
    before="$(date +%s)"
    note_provider_quota_exhausted web-advisor-provider 700003 "ordinary failure without reset deadline"
    after="$(date +%s)"
    held_until="$(cat "$WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE")"
    lo=$(( before + PREMIUM_QUOTA_BACKOFF_SECONDS ))
    hi=$(( after + PREMIUM_QUOTA_BACKOFF_SECONDS ))
    if [ "$held_until" -ge "$lo" ] && [ "$held_until" -le "$hi" ]; then
      echo "FALLBACK:HOLD"
    else
      echo "FALLBACK:WRONG"
    fi
  ' "$SCRIPT_DIR" 2>/dev/null
)" || true
rm -rf "$WEBQ_HOME"
assert_contains "web-advisor-provider quota marker absent means dispatch is open" "$WEBQ_OUT" "ABSENT:open"
assert_contains "web-advisor-provider quota marker holds only until its deadline" "$WEBQ_OUT" "FUTURE:held"
assert_contains "web-advisor-provider hold does not close Codex" "$WEBQ_OUT" "CODEX:open"
assert_contains "expired web-advisor-provider hold permits a fresh probe" "$WEBQ_OUT" "PAST:open"
assert_contains "web-advisor-provider quota refusal refunds its charged attempt" "$WEBQ_OUT" "REFUND:1"
assert_contains "Codex stated reset deadline parses exactly" "$WEBQ_OUT" "CODEX-SHAPE:yes"
assert_contains "unsupported reset text fails without guessing" "$WEBQ_OUT" "UNPARSEABLE:correct"
assert_contains "unparseable web-advisor-provider refusal uses fixed backoff" "$WEBQ_OUT" "FALLBACK:HOLD"

# --- #1377: quota holds stay local; attempts are refunded ------------------
# Drive the public pause_for_backoff() seam twice with the same web-advisor-provider 429.
QUOTA_ALERT_HOME="$(mktemp -d)"
QUOTA_ALERT_OUT="$(
  AGENT_HOME="$QUOTA_ALERT_HOME" bash -c '
    set -uo pipefail
    source "$0/lib.sh"
    mkdir -p "$STATE_DIR"
    : > "$AGENT_HOME/mails"
    notify_maintainer() { printf "%s\n%s\n---\n" "$1" "$2" >> "$AGENT_HOME/mails"; }

    echo "{\"attempts\":1}" > "$STATE_DIR/700004.json"
    echo "{\"attempts\":1}" > "$STATE_DIR/700005.json"
    refusal="{\"api_error_status\":429,\"result\":\"weekly usage limit reached\"}"
    pause_for_backoff 700004 "$refusal" 1 1 web-advisor-provider "$POLICY_ADVISOR_IDENTITY" run-advisor:advisor
    pause_for_backoff 700005 "$refusal" 1 1 web-advisor-provider "$POLICY_ADVISOR_IDENTITY" run-advisor:advisor
    echo "OPEN-MAILS:$(grep -cF "[example] web-advisor-provider 配额暂时不可用" "$AGENT_HOME/mails" || true)"
    echo "OPEN-DETAIL:$(grep -cE "web-advisor-provider.*预计恢复时间.*2 张票" "$AGENT_HOME/mails" || true)"
    echo "REFUND-700004:$(jq -r .attempts "$STATE_DIR/700004.json")"
    echo "REFUND-700005:$(jq -r .attempts "$STATE_DIR/700005.json")"

    # Deadline expiry permits a fresh probe but is not recovery by itself.
    # A still-refused probe extends the same local outage marker.
    printf "%s\n" "$(( $(date +%s) - 1 ))" > "$WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE"
    provider_quota_exhausted web-advisor-provider && echo "EXPIRED:still-held" || echo "EXPIRED:probe-allowed"
    pause_for_backoff 700005 "$refusal" 1 1 web-advisor-provider "$POLICY_ADVISOR_IDENTITY" run-advisor:advisor
    echo "OPEN-AFTER-EXPIRED-429:$(grep -cF "[example] web-advisor-provider 配额暂时不可用" "$AGENT_HOME/mails" || true)"
    echo "RECOVERY-BEFORE-SUCCESS:$(grep -cF "[example] web-advisor-provider 配额窗口已恢复" "$AGENT_HOME/mails" || true)"
    provider_quota_recovered web-advisor-provider || true
    provider_quota_recovered web-advisor-provider || true
    echo "RECOVERY-MAILS:$(grep -cF "[example] web-advisor-provider 配额窗口已恢复" "$AGENT_HOME/mails" || true)"

    pause_for_backoff 700006 "{\"result\":\"transient contention\"}" 143 1 codex "$POLICY_WORK_IDENTITY" run-implement:implement
    echo "CONTENTION-MAILS:$(grep -c "模型调用暂不可用" "$AGENT_HOME/mails" || true)"
    echo "CONTENTION-BACKOFF:$(jq -r .model_failure_backoff.reason "$STATE_DIR/700006.json")|$(jq -r .model_failure_backoff.caller "$STATE_DIR/700006.json")|$(jq -r .model_failure_backoff.issue "$STATE_DIR/700006.json")|$(jq -r .model_failure_backoff.provider "$STATE_DIR/700006.json")|$(jq -r .model_failure_backoff.model "$STATE_DIR/700006.json")"
    remaining="$(issue_model_failure_backoff_remaining 700006)"
    # Several jq/grep/mail calls run between the write and this read; 1s of slack failed under load (2026-09-30).
    [ "$remaining" -ge 3540 ] && [ "$remaining" -le 3600 ] && echo "CONTENTION-REMAINING:one-hour" || echo "CONTENTION-REMAINING:wrong ($remaining)"
    jq -e ".model_failure_backoff | [.reason,.caller,.issue,.provider,.model,.timestamp] | all(length>0)" "$STATE_DIR/700006.json" >/dev/null \
      && echo "CONTENTION-METADATA:complete" || echo "CONTENTION-METADATA:incomplete"
    echo "CONTENTION-SUMMARY:$(model_failure_backoff_summary)"
    [ -e "$PAUSE_FILE" ] && echo "CONTENTION-PAUSE:present" || echo "CONTENTION-PAUSE:missing"
    pause_for_backoff "" "{\"result\":\"transient contention\"}" 143 1 codex "$POLICY_WORK_IDENTITY" run-implement:implement
    [ -e "$PAUSE_FILE" ] && echo "NO-ISSUE-PAUSE:present" || echo "NO-ISSUE-PAUSE:missing"
    : > "$PAUSE_FILE"
    manual_pause_is_valid && echo "EMPTY-PAUSE:valid" || echo "EMPTY-PAUSE:invalid"
    printf "{\"reason\":\"operator stop\",\"caller\":\"operator\",\"issue\":\"none\",\"provider\":\"none\",\"model\":\"none\",\"timestamp\":\"2026-99-99T99:99:99Z\"}\n" > "$PAUSE_FILE"
    manual_pause_is_valid && echo "BAD-TIME-PAUSE:valid" || echo "BAD-TIME-PAUSE:invalid"
    printf "head: prod import window\n" > "$PAUSE_FILE"
    manual_pause_is_valid && echo "PLAIN-TEXT-PAUSE:valid" || echo "PLAIN-TEXT-PAUSE:invalid"
    printf "{\"reason\":\"operator stop\",\"caller\":\"operator\",\"issue\":\"none\",\"provider\":\"none\",\"model\":\"none\",\"timestamp\":\"%s\"}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PAUSE_FILE"
    manual_pause_is_valid && echo "MANUAL-PAUSE:valid" || echo "MANUAL-PAUSE:invalid"
    # 线级 hold 元数据（owner/expires_at，可选）：不改变 PAUSE 的有效性；过期也不解除暂停
    # （到期只由 node_health 的 holds.line_violations 每天告警，绝不自动恢复）。
    # expires_at 用 epoch 运算生成：外层是单引号 heredoc，不能再出现单引号。
    printf "{\"reason\":\"operator stop\",\"caller\":\"operator\",\"issue\":\"none\",\"provider\":\"none\",\"model\":\"none\",\"timestamp\":\"%s\",\"owner\":\"founder\",\"expires_at\":\"%s\"}\n" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u -d "@$(( $(date +%s) + 7200 ))" +%Y-%m-%dT%H:%M:%SZ)" > "$PAUSE_FILE"
    manual_pause_is_valid && echo "OWNER-PAUSE:valid" || echo "OWNER-PAUSE:invalid"
    printf "{\"reason\":\"operator stop\",\"caller\":\"operator\",\"issue\":\"none\",\"provider\":\"none\",\"model\":\"none\",\"timestamp\":\"%s\",\"owner\":\"founder\",\"expires_at\":\"%s\"}\n" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u -d "@$(( $(date +%s) - 7200 ))" +%Y-%m-%dT%H:%M:%SZ)" > "$PAUSE_FILE"
    manual_pause_is_valid && echo "EXPIRED-PAUSE:valid" || echo "EXPIRED-PAUSE:invalid"

    web_provider="$(provider_quota_provider_for_model "$POLICY_ADVISOR_IDENTITY")"
    if provider_quota_provider_for_model "other-model:$POLICY_WORK_EFFORT" >/dev/null 2>&1; then echo "UNSUPPORTED-MODEL-PROVIDER:accepted"; else echo "UNSUPPORTED-MODEL-PROVIDER:rejected"; fi
    if provider_quota_provider_for_model unknown:model:effort >/dev/null; then
      echo "UNKNOWN-PREFIX-REFUSED:no"
    else
      echo "UNKNOWN-PREFIX-REFUSED:yes"
    fi
    codex_until=$(( $(date +%s) + 9999 ))
    printf "%s\n" "$codex_until" > "$CODEX_EXHAUSTED_MARKER_FILE"
    : > "$CODEX_EXHAUSTED_MARKER_FILE.alerted"
    pause_for_backoff "" "$refusal" 1 1 "$web_provider"
    echo "WEB-PROVIDER:$web_provider"
    [ -f "$WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE" ] && echo "WEB-HOLD:yes" || echo "WEB-HOLD:no"
    [ "$(cat "$CODEX_EXHAUSTED_MARKER_FILE")" = "$codex_until" ] && echo "WEB-CODEX-UNTOUCHED:yes" || echo "WEB-CODEX-UNTOUCHED:no"
    provider_quota_recovered "$web_provider" || true
    [ -f "$WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE" ] && echo "WEB-RECOVERED:no" || echo "WEB-RECOVERED:yes"
    [ "$(cat "$CODEX_EXHAUSTED_MARKER_FILE")" = "$codex_until" ] && echo "WEB-CODEX-STILL-UNTOUCHED:yes" || echo "WEB-CODEX-STILL-UNTOUCHED:no"
  ' "$SCRIPT_DIR" 2>/dev/null
)" || true
rm -rf "$QUOTA_ALERT_HOME"
assert_contains "quota refusals keep provider hold in local state" \
  "$QUOTA_ALERT_OUT" "OPEN-MAILS:0"
assert_contains "quota refusal does not create an operational maintainer email" \
  "$QUOTA_ALERT_OUT" "OPEN-DETAIL:0"
assert_contains "#1377: every quota-refused ticket gets its charged attempt back" \
  "$QUOTA_ALERT_OUT" "REFUND-700004:0"
assert_contains "#1377: ...including later refusals during the same outage" \
  "$QUOTA_ALERT_OUT" "REFUND-700005:0"
assert_contains "#1377: an expired provider hold permits a probe but does not claim recovery" \
  "$QUOTA_ALERT_OUT" "EXPIRED:probe-allowed"
assert_contains "post-expiry refusal stays within the same local outage" \
  "$QUOTA_ALERT_OUT" "OPEN-AFTER-EXPIRED-429:0"
assert_contains "#1377: recovery is silent until a genuine non-refused provider success" \
  "$QUOTA_ALERT_OUT" "RECOVERY-BEFORE-SUCCESS:0"
assert_contains "provider recovery clears the local hold without mail" \
  "$QUOTA_ALERT_OUT" "RECOVERY-MAILS:0"
# 2026-10-04: a per-issue model-call backoff is an internal alert, not maintainer mail (bell flagged
# "[example] 模型调用暂不可用" as off-contract). A stalled node reaches him through the health mail.
assert_contains "a non-quota model-call backoff sends no maintainer mail" \
  "$QUOTA_ALERT_OUT" "CONTENTION-MAILS:0"
# One invalid record in a good batch keeps its scoped backoff but sends no maintainer incident mail.
NONQUOTA_HOME="$(mktemp -d)"
NO_MAIL_OUT="$(SCRIPT_DIR="$SCRIPT_DIR" AGENT_HOME="$NONQUOTA_HOME" bash -c '
  source "$SCRIPT_DIR/lib.sh"
  notify_maintainer() { printf "%s\n" "$1" >> "$AGENT_HOME/mails"; }
  pause_for_backoff 710009 "invalid triage.schema.json record" 1 1 codex codex:gpt-6-luna:max \
    run-triage-batch:triage-result "" "" "" "" 0 triage 2>/dev/null
  printf "MAILS:%s BACKOFF:%s\n" "$(cat "$AGENT_HOME/mails" 2>/dev/null | wc -l | tr -d "[:space:]")" \
    "$(state_read 710009 | jq -r ".model_failure_backoff.caller // \"none\"")"
')"
assert_contains "an invalid batch record backs off its issue without a maintainer incident mail" \
  "$NO_MAIL_OUT" "MAILS:0 BACKOFF:run-triage-batch:triage-result"
rm -rf "$NONQUOTA_HOME"
assert_contains "non-quota contention stores reason, caller, issue, provider, model, and timestamp" \
  "$QUOTA_ALERT_OUT" "CONTENTION-BACKOFF:unclassified model call failure (exit 143)|run-implement:implement|700006|codex|$POLICY_WORK_IDENTITY"
assert_contains "non-quota contention stores a nonempty timestamp" \
  "$QUOTA_ALERT_OUT" "CONTENTION-METADATA:complete"
assert_contains "non-quota contention scopes one-hour retry to the failed issue" \
  "$QUOTA_ALERT_OUT" "CONTENTION-REMAINING:one-hour"
assert_contains "HEALTH backoff summary names failed issue and model" \
  "$QUOTA_ALERT_OUT" "CONTENTION-SUMMARY:#700006 codex/$POLICY_WORK_IDENTITY"
BACKOFF_SUMMARY_HOME="$(mktemp -d)"
BACKOFF_SUMMARY_BIN="$(mktemp -d)"
BACKOFF_REAL_PYTHON3="$(command -v python3)"
export BACKOFF_REAL_PYTHON3
cat >"$BACKOFF_SUMMARY_BIN/python3" <<'PYTHON_STUB'
#!/usr/bin/env bash
if [[ "${BACKOFF_TEST_READ_FAILURE:-0}" == 1 ]]; then
  shift
  rm -f -- "$4"
  exec "$BACKOFF_REAL_PYTHON3" - "$@"
fi
printf '%s\0' '/partial-prefilter-result'
exit 17
PYTHON_STUB
chmod +x "$BACKOFF_SUMMARY_BIN/python3"
BACKOFF_SUMMARY_OUT="$(
  AGENT_HOME="$BACKOFF_SUMMARY_HOME" bash -s -- "$SCRIPT_DIR" "$BACKOFF_SUMMARY_BIN" <<'BACKOFF_SUMMARY_TEST'
source "$1/lib.sh"
mkdir -p "$STATE_DIR"
printf '%s\n' '{"attempts":0}' > "$STATE_DIR/710011.json"
printf 'ZERO-CANDIDATES:[%s]\n' "$(model_failure_backoff_summary 1000)"

# The escaped key must be decoded, while the existing jq path keeps deciding
# expired, null, false, empty, and malformed state behavior for each candidate.
printf '%s\n' '{"model_failure_\u0062ackoff":{"until_epoch":1100,"provider":"codex","model":"escaped-model","caller":"escaped"}}' > "$STATE_DIR/710012.json"
printf '%s\n' '{"model_failure_backoff":{"until_epoch":999,"provider":"codex","model":"inactive","caller":"inactive"}}' > "$STATE_DIR/710013.json"
printf '%s\n' '{"model_failure_backoff":' > "$STATE_DIR/710014.json"
printf '%s\n' '{"model_failure_backoff":null}' > "$STATE_DIR/710015.json"
printf '%s\n' '{"model_failure_backoff":false}' > "$STATE_DIR/710016.json"
printf '%s\n' '{"model_failure_backoff":""}' > "$STATE_DIR/710017.json"
printf '%s\n' '{"model_failure_backoff":{}}' > "$STATE_DIR/710018.json"
printf '%s\n' '{"model_failure_backoff":{"until_epoch":1060}}' > "$STATE_DIR/710019.json"
printf 'NORMAL:%s\n' "$(model_failure_backoff_summary 1000)"

# A failed preselector may have emitted partial candidates; discard them and
# verify the original full scan still finds the active issue.
PATH="$2:$PATH"
printf 'FALLBACK:%s\n' "$(model_failure_backoff_summary 1000)"

# A read failure after an earlier candidate also discards partial output and
# retries the original path list, including later active states.
export BACKOFF_TEST_READ_FAILURE=1
printf 'READ-FALLBACK:%s\n' "$(model_failure_backoff_summary 1000)"
BACKOFF_SUMMARY_TEST
)"
rm -rf -- "$BACKOFF_SUMMARY_HOME" "$BACKOFF_SUMMARY_BIN"
unset BACKOFF_REAL_PYTHON3
assert_contains "backoff summary returns immediately for zero key candidates" \
  "$BACKOFF_SUMMARY_OUT" "ZERO-CANDIDATES:[]"
assert_contains "backoff summary decodes escaped keys and preserves the existing active/inactive jq result and metadata defaults" \
  "$BACKOFF_SUMMARY_OUT" "NORMAL:#710012 codex/escaped-model caller=escaped remaining=100s; #710019 unknown/unknown caller=unknown remaining=60s"
assert_not_contains "malformed, null, false, and empty backoff values do not create summary rows" \
  "$BACKOFF_SUMMARY_OUT" "#710014"
assert_not_contains "null backoff state keeps its existing zero result" \
  "$BACKOFF_SUMMARY_OUT" "#710015"
assert_not_contains "false backoff state keeps its existing zero result" \
  "$BACKOFF_SUMMARY_OUT" "#710016"
assert_not_contains "empty backoff states keep their existing zero result" \
  "$BACKOFF_SUMMARY_OUT" "#710017"
assert_not_contains "empty backoff objects keep their existing zero result" \
  "$BACKOFF_SUMMARY_OUT" "#710018"
assert_contains "failed preselection discards partial candidates and falls back to the full scan" \
  "$BACKOFF_SUMMARY_OUT" "FALLBACK:#710012 codex/escaped-model caller=escaped remaining=100s; #710019 unknown/unknown caller=unknown remaining=60s"
assert_contains "preselection read failure discards partial candidates and falls back to the full scan" \
  "$BACKOFF_SUMMARY_OUT" "READ-FALLBACK:#710012 codex/escaped-model caller=escaped remaining=100s; #710019 unknown/unknown caller=unknown remaining=60s"
assert_contains "non-quota contention never writes global PAUSE" \
  "$QUOTA_ALERT_OUT" "CONTENTION-PAUSE:missing"
assert_contains "missing issue never writes global PAUSE" \
  "$QUOTA_ALERT_OUT" "NO-ISSUE-PAUSE:missing"
assert_contains "empty PAUSE is invalid manual-stop metadata" \
  "$QUOTA_ALERT_OUT" "EMPTY-PAUSE:invalid"
assert_contains "syntactically invalid timestamp cannot pause the pipeline" \
  "$QUOTA_ALERT_OUT" "BAD-TIME-PAUSE:invalid"
assert_contains "a plain-text PAUSE is a pause" \
  "$QUOTA_ALERT_OUT" "PLAIN-TEXT-PAUSE:valid"
assert_contains "complete operator PAUSE metadata is valid" \
  "$QUOTA_ALERT_OUT" "MANUAL-PAUSE:valid"
assert_contains "PAUSE with hold owner and future expiry stays a valid pause" \
  "$QUOTA_ALERT_OUT" "OWNER-PAUSE:valid"
assert_contains "an expired PAUSE hold stays a valid pause: expiry alarms, it never un-pauses" \
  "$QUOTA_ALERT_OUT" "EXPIRED-PAUSE:valid"
assert_contains "#1457: web model resolves to its own quota provider" \
  "$QUOTA_ALERT_OUT" "WEB-PROVIDER:web-advisor-provider"
assert_contains "#1457: unconfigured model identity cannot borrow provider quota state" \
  "$QUOTA_ALERT_OUT" "UNSUPPORTED-MODEL-PROVIDER:rejected"
assert_contains "#1457: unknown provider:model:effort cannot borrow quota state" \
  "$QUOTA_ALERT_OUT" "UNKNOWN-PREFIX-REFUSED:yes"
assert_contains "#1457: web quota refusal opens a web-only hold" \
  "$QUOTA_ALERT_OUT" "WEB-HOLD:yes"
assert_contains "#1457: web quota refusal leaves Codex hold untouched" \
  "$QUOTA_ALERT_OUT" "WEB-CODEX-UNTOUCHED:yes"
assert_contains "#1457: web quota recovery clears only web state" \
  "$QUOTA_ALERT_OUT" "WEB-RECOVERED:yes"
assert_contains "#1457: web recovery still leaves Codex hold untouched" \
  "$QUOTA_ALERT_OUT" "WEB-CODEX-STILL-UNTOUCHED:yes"

# #1608: exit 124 is a local wall-clock timeout, not quota. It records an
# environment fault, leaves the pipeline-wide pause marker absent, keeps the
# attempt charged because wall-clock work really ran, and gives the next
# attempt a larger model-call budget.
TIMEOUT_OUT="$({
  AGENT_HOME="$(mktemp -d)" bash -c '
    set -uo pipefail
    source "$0/lib.sh"
    mkdir -p "$STATE_DIR"
    printf "%s\n" "{\"attempts\":2}" > "$STATE_DIR/700099.json"
    echo "BUDGET-BASE:$(model_timeout_for_attempt 30 700099)"
    printf "%s\n" "{\"attempts\":2,\"last_failure_kind\":\"timeout\"}" > "$STATE_DIR/700099.json"
    echo "BUDGET-AFTER:$(model_timeout_for_attempt 30 700099)"
    : > "$AGENT_HOME/mails"
    notify_maintainer() { printf "%s\n" "$1" >> "$AGENT_HOME/mails"; }
    GH_ENV_FAULT_STAGE=implement
    pause_for_backoff 700099 "codex exec timed out after 1s (elapsed 1s)" 124 1
    echo "TIMEOUT-PAUSE:$([ -f "$PAUSE_FILE" ] && echo present || echo missing)"
    echo "TIMEOUT-ATTEMPTS:$(jq -r .attempts "$STATE_DIR/700099.json")"
    echo "TIMEOUT-MAILS:$(grep -c . "$AGENT_HOME/mails" 2>/dev/null || true)"
    echo "TIMEOUT-FAULT:$(cat "$ENV_FAULT_DIR/env:network-timeout.log")"
  ' "$SCRIPT_DIR"
} 2>&1)"
assert_contains "#1608: a timeout raises the next attempt's model-call budget" \
  "$TIMEOUT_OUT" "BUDGET-BASE:30"
assert_contains "#1608: timeout budget escalation is larger, not a refund" \
  "$TIMEOUT_OUT" "BUDGET-AFTER:60"
assert_contains "#1608: exit 124 does not write the pipeline-wide PAUSE marker" \
  "$TIMEOUT_OUT" "TIMEOUT-PAUSE:missing"
assert_contains "#1608: timeout keeps the attempt charged" \
  "$TIMEOUT_OUT" "TIMEOUT-ATTEMPTS:2"
assert_contains "#1608: timeout produces no maintainer mail, quota-named or otherwise" \
  "$TIMEOUT_OUT" "TIMEOUT-MAILS:0"
assert_contains "#1608: timeout ledger entry preserves limit and elapsed time" \
  "$TIMEOUT_OUT" "codex exec timed out after 1s (elapsed 1s)"

QUOTA_CONCURRENT_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$QUOTA_CONCURRENT_HOME/model-policy.json"
QUOTA_CONCURRENT_OUT="$(
  AGENT_HOME="$QUOTA_CONCURRENT_HOME" bash -c '
    set -uo pipefail
    source "$0/lib.sh"
    mkdir -p "$STATE_DIR"
    : > "$AGENT_HOME/mails"
    notify_maintainer() { printf "%s\n" "$1" >> "$AGENT_HOME/mails"; sleep 0.05; }
    refusal="{\"api_error_status\":429,\"result\":\"weekly usage limit reached\"}"
    pids=()
    for n in 700011 700012 700013 700014; do
      echo "{\"attempts\":1}" > "$STATE_DIR/$n.json"
      ( pause_for_backoff "$n" "$refusal" 1 1 ) &
      pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    echo "PARALLEL-OPEN:$(grep -cF "[example] Codex quota temporarily unavailable" "$AGENT_HOME/mails" || true)"
    echo "PARALLEL-REFUNDS:$(jq -r .attempts "$STATE_DIR/700011.json"),$(jq -r .attempts "$STATE_DIR/700012.json"),$(jq -r .attempts "$STATE_DIR/700013.json"),$(jq -r .attempts "$STATE_DIR/700014.json")"
    pids=()
    for _ in 1 2 3 4; do
      ( provider_quota_recovered codex || true ) &
      pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    echo "PARALLEL-RECOVERY:$(grep -cF "[example] Codex quota recovered" "$AGENT_HOME/mails" || true)"
  ' "$SCRIPT_DIR" 2>/dev/null
)" || true
rm -rf "$QUOTA_CONCURRENT_HOME"
assert_contains "#1377: concurrent quota refusals send no operational email" \
  "$QUOTA_CONCURRENT_OUT" "PARALLEL-OPEN:0"
assert_contains "#1377: concurrent quota refusals still refund every affected ticket" \
  "$QUOTA_CONCURRENT_OUT" "PARALLEL-REFUNDS:0,0,0,0"
assert_contains "#1377: concurrent confirmed recoveries send no operational email" \
  "$QUOTA_CONCURRENT_OUT" "PARALLEL-RECOVERY:0"
assert_contains "#1457: triage confirms recovery for selected model provider" \
  "$(cat "$SCRIPT_DIR/run-triage.sh")" 'provider_quota_recovered "$(provider_quota_provider_for_model "$MODEL_POLICY_IDENTITY")"'
assert_contains "#1457: recut confirms recovery for selected model provider" \
  "$(cat "$SCRIPT_DIR/run-recut.sh")" 'provider_quota_recovered "$(provider_quota_provider_for_model "$MODEL_POLICY_IDENTITY")"'
assert_contains "#1457: triage passes selected provider into quota refusal handling" \
  "$(sed -n '/^fail_attempt()/,/^}/p' "$SCRIPT_DIR/run-triage.sh")" 'pause_for_backoff "$N" "$call_output" "$status" "$should_pause" "$call_provider" "$model" "$caller"'
assert_contains "#1457: recut passes selected provider into quota refusal handling" \
  "$(sed -n '/^fail_attempt()/,/^}/p' "$SCRIPT_DIR/run-recut.sh")" 'pause_for_backoff "$N" "$call_output" "$status" "$should_pause" "$call_provider" "$model" "$caller"'

# Implement dispatch must derive its identity and stale recovery from policy state.
DISPATCH_POLICY_BODY="$(sed -n '/^dispatch_policy_unit() {$/,/^}$/p' "$SCRIPT_DIR/issue-pipeline.sh")"
STALE_POLICY_RECOVERY_BODY="$(sed -n '/^recover_stale_policy_unit() {$/,/^}$/p' "$SCRIPT_DIR/issue-pipeline.sh")"
assert_true "dispatch helper is present" bash -c '[ -n "$1" ]' _ "$DISPATCH_POLICY_BODY"
assert_contains "dispatch resolves capacity-aware role identity through model policy" "$DISPATCH_POLICY_BODY" 'identity="$(model_policy dispatch-identity "$role")"'
assert_contains "dispatch persists active unit and policy step for stall recovery" "$DISPATCH_POLICY_BODY" 'active:{unit:$u,queue_label:$q,step:$s,role:$r,identity:$i'
assert_contains "dispatch delegates stale active markers to shared recovery" "$DISPATCH_POLICY_BODY" 'recover_stale_policy_unit "$n" "$queue_label"'
assert_contains "stalled dispatch enters configured failure ladder" "$STALE_POLICY_RECOVERY_BODY" 'model_policy_record_failure "$n" "$active_step" "$active_unit"'
assert_contains "advisor step restores the failed unit's queue label" "$DISPATCH_POLICY_BODY" 'route_to_advisor "$n" "$queue_label" true'
assert_false "dispatch helper no longer selects models from executor environment" grep -q 'AGENT_IMPLEMENT_EXECUTOR' <<< "$DISPATCH_POLICY_BODY"

# Every worktree owner now routes its exit through the same safety-checked
# lifecycle helper. Keep-flag behavior is intentionally gone.
assert_true "worktree lifecycle: an empty path is a no-op" \
  worktree_lifecycle_finish "" "$REPO_DIR"

# --- advisor_prune_own_comments / advisor_current_brief_md: extracted
# 2026-09-19 from run-advisor-batch.sh's own per-ticket trim loop so
# run-advisor.sh's single-ticket leg can apply the identical rule instead
# of feeding the model its own past chatter on every dispatch (see both
# functions' own comments in lib.sh for the full 2026-09-16 sizing
# incident this closes). run-advisor-batch.test.sh's scenario J covers the
# SAME behavior end-to-end through the batch wrapper's real prompt; these
# are the unit-level checks on the shared functions themselves.
APOC_ISSUE="$(jq -nc --arg d "$BOT_DISCLAIMER" '{number: 1, comments: [
  {body: ($d + "\n\nguarded-brief banner")},
  {body: "不对，这张票的范围理解错了。"},
  {body: ($d + "\n\nrelabel notice")}
]}')"
APOC_OUT="$(advisor_prune_own_comments "$APOC_ISSUE")"
assert_eq "advisor_prune_own_comments: drops every comment starting with BOT_DISCLAIMER" \
  "1" "$(jq '.comments | length' <<< "$APOC_OUT")"
assert_contains "advisor_prune_own_comments: the genuine human comment survives" \
  "$APOC_OUT" "范围理解错了"
assert_not_contains "advisor_prune_own_comments: neither bot comment survives" \
  "$APOC_OUT" "guarded-brief banner"

APOC_EMPTY_LIST="$(advisor_prune_own_comments '{"number":1,"comments":[]}')"
assert_eq "advisor_prune_own_comments: an already-empty comment list stays empty, no crash" \
  "0" "$(jq '.comments | length' <<< "$APOC_EMPTY_LIST")"

APOC_NO_COMMENTS_FIELD="$(advisor_prune_own_comments '{"number":1}')"
assert_eq "advisor_prune_own_comments: a ticket with no .comments field at all trims to an empty list, no crash" \
  "0" "$(jq '.comments | length' <<< "$APOC_NO_COMMENTS_FIELD")"

assert_eq "advisor_prune_own_comments: an empty/missing argument does not crash the caller" \
  "0" "$(jq '.comments | length' <<< "$(advisor_prune_own_comments "")")"

ACBM_SUPERSEDED="$(jq -nc '{brief_md: "LATEST_BANNER\n---\n\nOLD_SUPERSEDED_TEXT"}')"
ACBM_OUT="$(advisor_current_brief_md "$ACBM_SUPERSEDED")"
assert_eq "advisor_current_brief_md: keeps only the current banner, ahead of the \\n---\\n\\n boundary" \
  "LATEST_BANNER" "$(jq -r '.brief_md' <<< "$ACBM_OUT")"

ACBM_UNCLASSIFIED="$(jq -nc '{brief_md: "A single, never-superseded brief with its own text."}')"
assert_eq "advisor_current_brief_md: a ticket classified once (no banner boundary) passes through unchanged" \
  "A single, never-superseded brief with its own text." \
  "$(jq -r '.brief_md' <<< "$(advisor_current_brief_md "$ACBM_UNCLASSIFIED")")"

ACBM_NO_BRIEF="$(advisor_current_brief_md '{"risk_class":"P1"}')"
assert_eq "advisor_current_brief_md: a ticket with no brief_md yet stays null, no crash" \
  "null" "$(jq -c '.brief_md' <<< "$ACBM_NO_BRIEF")"

assert_eq "advisor_current_brief_md: an empty/missing argument does not crash the caller" \
  "null" "$(jq -c '.brief_md' <<< "$(advisor_current_brief_md "")")"

# --- advisor_pending_orphan_candidates: issue-pipeline.sh's pending- --------
# --- recovery candidate source (2026-09-19) ---------------------------------
# Reads $STATE_DIR directly, which is derived from $AGENT_HOME at lib.sh
# source time -- same reason route_to_advisor()'s own test above (search
# "ROUTE_TEST_HOME") re-sources lib.sh fresh inside a `bash -c` with a
# throwaway AGENT_HOME, rather than trying to repoint the already-sourced
# $STATE_DIR in THIS process.
APOC_HOME="$(mktemp -d)"
mkdir -p "$APOC_HOME/state"
# #9/#10: both carry an unresolved pending verdict -- Apply started (or, for
# #10, is mid-episode) but the atomic completion write never ran. Numbered
# so a naive lexical/default sort would misorder them against each other
# ("10" < "9" as strings) -- proves this returns them numerically sorted,
# not string-sorted.
echo '{"attempts":0,"pending_advisor_verdict":{"result":{},"episode_seq":0,"effects":{}}}' \
  > "$APOC_HOME/state/9.json"
echo '{"attempts":0,"pending_advisor_verdict":{"result":{},"episode_seq":1,"effects":{}}}' \
  > "$APOC_HOME/state/10.json"
# #20: also unresolved, sorts after #9/#10.
echo '{"attempts":0,"pending_advisor_verdict":{"result":{},"episode_seq":0,"effects":{}}}' \
  > "$APOC_HOME/state/20.json"
# #30: a fully completed episode -- advisor_ruled_at set, and the SAME
# atomic state_merge call that set it already cleared pending_advisor_
# verdict (advisor-core.sh's own atomic-completion comment) -- must not be
# surfaced again as if it were still unresolved.
echo '{"attempts":0,"advisor_ruled_at":"2026-09-01T00:00:00Z"}' \
  > "$APOC_HOME/state/30.json"
# #40: never touched by the advisor at all (a plain triage-stage ticket).
echo '{"attempts":0}' > "$APOC_HOME/state/40.json"
# #50: a corrupt state file -- jq -e itself fails to parse it. Must be
# skipped, not fatal to the rest of the scan (one bad file must not hide
# every other ticket's own orphaned verdict).
echo 'not valid json{{{' > "$APOC_HOME/state/50.json"

APOC_OUTPUT="$(AGENT_HOME="$APOC_HOME" bash -c 'source "$0/lib.sh"; advisor_pending_orphan_candidates' "$SCRIPT_DIR")"
rm -rf "$APOC_HOME"

assert_contains "advisor_pending_orphan_candidates: surfaces a ticket with an unresolved pending verdict" \
  "$APOC_OUTPUT" "9"
assert_not_contains "...does not surface a fully completed episode (pending marker already cleared)" \
  "$APOC_OUTPUT" "30"
assert_not_contains "...does not surface a ticket the advisor never touched" \
  "$APOC_OUTPUT" "40"
assert_not_contains "...a corrupt state file is skipped rather than crashing the scan" \
  "$APOC_OUTPUT" "50"
assert_eq "...exactly the unresolved tickets, numerically sorted (9, 10, 20 -- not lexical)" \
  "9
10
20" "$APOC_OUTPUT"

# --- try_lock_nonblocking / unlock_fd / run_with_fd_closed: advisor claim --
# primitives (2026-09-20). Same discipline as acquire_merge_lock() above:
# proven against THROWAWAY lock files, with a real second PROCESS contending
# where that distinction matters -- flock's exclusivity is per (file, open
# file description), so a second process opening its own fd on the same path
# is a genuine, independent contender.
TLNB_CALLER_FD_FILE="$(mktemp -u)"
try_lock_with_caller_named_fd() {
  local fd=""
  try_lock_nonblocking "$1" fd || return 1
  printf '%s' "$fd"
  unlock_fd "$fd"
}
TLNB_CALLER_FD="$(try_lock_with_caller_named_fd "$TLNB_CALLER_FD_FILE")"
assert_true "try_lock_nonblocking: writes a caller out-variable named fd" \
  test -n "$TLNB_CALLER_FD"
rm -f "$TLNB_CALLER_FD_FILE"

LEASE_AVAILABLE_FILE="$(mktemp -u)"
assert_true "web_session_lease_available: a free lease is available twice in one process" \
  bash -c 'WEB_SESSION_LEASE_FILE="$2"; source "$1/lib.sh"; web_session_lease_available && web_session_lease_available' \
  _ "$SCRIPT_DIR" "$LEASE_AVAILABLE_FILE"
rm -f "$LEASE_AVAILABLE_FILE"

EMPTY_UNLOCK_OUTPUT="$(unlock_fd "" 2>&1)"
EMPTY_UNLOCK_STATUS=$?
assert_eq "unlock_fd: an empty fd is a quiet no-op" "0" "$EMPTY_UNLOCK_STATUS"
assert_eq "unlock_fd: an empty fd emits no failed-release diagnostic" "" "$EMPTY_UNLOCK_OUTPUT"

if INVALID_UNLOCK_OUTPUT="$(unlock_fd 999999 2>&1)"; then
  INVALID_UNLOCK_STATUS=0
else
  INVALID_UNLOCK_STATUS=$?
fi
assert_eq "unlock_fd: a non-empty invalid fd fails" "1" "$INVALID_UNLOCK_STATUS"
assert_contains "unlock_fd: a non-empty invalid fd reports the failed release" \
  "$INVALID_UNLOCK_OUTPUT" "unlock_fd: failed to unlock fd 999999"

UNLOCK_STDERR_LOCK="$(mktemp -u)"
UNLOCK_STDERR="$(
  (
    try_lock_nonblocking "$UNLOCK_STDERR_LOCK" UNLOCK_STDERR_FD
    unlock_fd "$UNLOCK_STDERR_FD"
    printf 'unlock_fd stderr remains attached\n' >&2
  ) 2>&1
)"
rm -f "$UNLOCK_STDERR_LOCK"
assert_contains "unlock_fd: closes only its lock fd, not caller stderr" \
  "$UNLOCK_STDERR" "unlock_fd stderr remains attached"

TLNB_FILE="$(mktemp -u)"

assert_true "try_lock_nonblocking: acquire succeeds when free" \
  try_lock_nonblocking "$TLNB_FILE" TLNB_FD1

assert_false "try_lock_nonblocking: a concurrent process cannot acquire while this one holds it" \
  bash -c 'exec 9>"$1" && flock -n 9' _ "$TLNB_FILE"

assert_false "try_lock_nonblocking: a second in-process attempt against the same file also fails (genuinely exclusive, not just advisory per caller)" \
  try_lock_nonblocking "$TLNB_FILE" TLNB_FD_UNUSED

# fd hygiene: a naively spawned child inherits the open lock fd by default
# (this IS the real risk -- #1204's own comment above, gh()/
# git_fetch_bounded(), was exactly a child inheriting a lock fd its parent
# no longer controlled) -- proven here, not assumed, then proven fixed by
# run_with_fd_closed(). A plain `bash -c` child of this process inherits
# every fd this process has open by default, unless told otherwise -- no
# extra redirection tricks needed to observe it.
NAIVE_CHILD_FD_LIST="$(bash -c 'ls /proc/self/fd' 2>/dev/null)"
assert_contains "try_lock_nonblocking: fd hygiene baseline -- a naive child DOES inherit the open lock fd (the bug run_with_fd_closed exists to prevent)" \
  "$NAIVE_CHILD_FD_LIST" "$TLNB_FD1"

HYGIENIC_CHILD_FD_LIST="$(run_with_fd_closed "$TLNB_FD1" -- bash -c 'ls /proc/self/fd')"
assert_not_contains "run_with_fd_closed: the same child does NOT see the lock fd when spawned through it" \
  "$HYGIENIC_CHILD_FD_LIST" "$TLNB_FD1"

HYGIENIC_CHILD_STDERR="$(run_with_fd_closed "$TLNB_FD1" -- bash -c 'printf "%s\\n" "run_with_fd_closed stderr survived" >&2' 2>&1)"
assert_contains "run_with_fd_closed: the wrapped command's stderr survives fd close" \
  "$HYGIENIC_CHILD_STDERR" "run_with_fd_closed stderr survived"

TLNB_FILE_2="$(mktemp -u)"
assert_true "try_lock_nonblocking: a second claim can be held in the same process" \
  try_lock_nonblocking "$TLNB_FILE_2" TLNB_FD2
MULTI_CHILD_FD_LIST="$(run_with_fd_closed "$TLNB_FD1" "$TLNB_FD2" -- bash -c 'ls /proc/self/fd')"
assert_not_contains "run_with_fd_closed: closes every listed claim fd in the child" \
  "$MULTI_CHILD_FD_LIST" "$TLNB_FD1"
assert_not_contains "run_with_fd_closed: closes the second listed claim fd too" \
  "$MULTI_CHILD_FD_LIST" "$TLNB_FD2"

# run_with_fd_closed's close is subshell-scoped only -- the parent (this
# script) must still hold the lock afterward. Proven with a FRESH in-process
# fd against the same file (same idiom as the "second in-process attempt"
# assertion above): if the parent had lost the lock, this would succeed.
exec {TLNB_PROBE_FD}>"$TLNB_FILE"
assert_false "run_with_fd_closed: does not release the lock for the parent, only hides it from the spawned child" \
  flock -n "$TLNB_PROBE_FD"
exec {TLNB_PROBE_FD}>&-

unlock_fd "$TLNB_FD1"
unlock_fd "$TLNB_FD2"

assert_true "unlock_fd: releases it for the next acquirer" \
  bash -c 'exec 9>"$1" && flock -n 9' _ "$TLNB_FILE"

rm -f "$TLNB_FILE"
rm -f "$TLNB_FILE_2"

# --- Per-ticket claims are independent of each other -----------------------
assert_eq "advisor_ticket_lock_file: builds the documented locks/issue-N.lock path" \
  "$ADVISOR_LOCKS_DIR/issue-777.lock" "$(advisor_ticket_lock_file 777)"

TICKET_LOCK_A="$(mktemp -u)"
TICKET_LOCK_B="$(mktemp -u)"

assert_true "per-ticket claim: ticket A's claim succeeds" \
  try_lock_nonblocking "$TICKET_LOCK_A" TICKET_FD_A
assert_true "per-ticket claim: a DIFFERENT ticket's claim succeeds at the same time (per-ticket, not global)" \
  try_lock_nonblocking "$TICKET_LOCK_B" TICKET_FD_B
assert_false "per-ticket claim: a second attempt on ticket A's own file still fails while A is held (this ticket's claim IS exclusive)" \
  bash -c 'exec 9>"$1" && flock -n 9' _ "$TICKET_LOCK_A"

unlock_fd "$TICKET_FD_A"
unlock_fd "$TICKET_FD_B"
rm -f "$TICKET_LOCK_A" "$TICKET_LOCK_B"

# --- advisor_worktree_new / advisor_worktree_cleanup -----------------------
# Built against a throwaway git repo and a throwaway $HOME (never the real
# checkout or the real ~/wt), so these tests write nothing under the real
# $HOME and make zero `gh`/network calls. `git worktree add` needs a
# committish that is not ALREADY checked out somewhere (the repo's own
# working tree is on `main`) -- production passes `origin/main` (a
# remote-tracking ref, always a detached checkout, shareable across many
# worktrees at once); this fixture has no remote, so a bare commit SHA
# stands in for the same "always detached, always shareable" property.
WT_FIXTURE_REPO="$(mktemp -d)"
git -C "$WT_FIXTURE_REPO" init -q -b main
git -C "$WT_FIXTURE_REPO" config user.email test@example.com
git -C "$WT_FIXTURE_REPO" config user.name "lib.test.sh"
git -C "$WT_FIXTURE_REPO" commit -q --allow-empty -m "seed"
WT_FIXTURE_SHA="$(git -C "$WT_FIXTURE_REPO" rev-parse HEAD)"
WT_FIXTURE_REMOTE="$(mktemp -d)"
git init -q --bare "$WT_FIXTURE_REMOTE"
git -C "$WT_FIXTURE_REPO" remote add origin "$WT_FIXTURE_REMOTE"
git -C "$WT_FIXTURE_REPO" push -qu origin main
git -C "$WT_FIXTURE_REPO" fetch -q origin

WT_TEST_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$WT_TEST_HOME/model-policy.json"
WT_REAL_HOME="$HOME"
HOME="$WT_TEST_HOME"
# INVOCATION_ID is deliberately NOT unset here. Production runs under
# systemd, where it is always set, so unsetting it would leave the one
# configuration that actually ships untested -- and "two calls in one unit"
# under a real invocation id is exactly the case that broke CI on
# 2026-09-20. CI (a systemd-run runner) supplies one; a developer shell does
# not, so both branches of advisor_worktree_new()'s id get exercised
# somewhere, and the assertions below hold either way.

assert_eq "advisor_worktree_new: need_worktree=0 creates nothing, prints nothing" \
  "" "$(advisor_worktree_new 0 "$WT_FIXTURE_SHA" "$WT_FIXTURE_REPO")"
assert_eq "...and registers no new worktree" \
  "1" "$(git -C "$WT_FIXTURE_REPO" worktree list | wc -l)"

WT_RUN_A="$(advisor_worktree_new 1 "$WT_FIXTURE_SHA" "$WT_FIXTURE_REPO")"
assert_true "advisor_worktree_new: need_worktree=1 creates a real worktree directory" \
  test -d "$WT_RUN_A"
assert_contains "...under \$HOME/wt/advisor-run-<id>, not a fixed name" \
  "$WT_RUN_A" "$WT_TEST_HOME/wt/advisor-run-"

WT_RUN_B="$(advisor_worktree_new 1 "$WT_FIXTURE_SHA" "$WT_FIXTURE_REPO")"
assert_false "advisor_worktree_new: two invocations get different directories (unique per run, not a fixed reused path)" \
  test "$WT_RUN_A" = "$WT_RUN_B"
assert_true "...and both coexist as independent, non-colliding worktrees (git sees both registered at once)" \
  test -d "$WT_RUN_A" -a -d "$WT_RUN_B"

export INVOCATION_ID="test-invocation-abc123"
WT_RUN_INV="$(advisor_worktree_new 1 "$WT_FIXTURE_SHA" "$WT_FIXTURE_REPO")"
assert_contains "advisor_worktree_new: uses \$INVOCATION_ID as the id when systemd set one, instead of a random id" \
  "$WT_RUN_INV" "advisor-run-test-invocation-abc123"
unset INVOCATION_ID

# --- cleanup: one safe exit rule, scoped to the current run -----------------
ZF_NIGHT_DIR="$WT_TEST_HOME/night" worktree_lifecycle_finish "" "$WT_FIXTURE_REPO"
PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=empty-list ZF_NIGHT_DIR="$WT_TEST_HOME/night" worktree_lifecycle_finish "$WT_RUN_A" "$WT_FIXTURE_REPO"
assert_false "worktree lifecycle removes this run's clean tree" test -d "$WT_RUN_A"
PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=empty-list ZF_NIGHT_DIR="$WT_TEST_HOME/night" worktree_lifecycle_finish "$WT_RUN_B" "$WT_FIXTURE_REPO"
assert_false "worktree lifecycle removes another clean run when that run ends" test -d "$WT_RUN_B"

# "only touches the directory this run made": a pre-existing, unrelated
# leftover directory under the same $HOME/wt/ tree (simulating a prior
# run's own worktree, or anything else already there) must survive a
# DIFFERENT run's own create-then-cleanup untouched -- no sweeping.
mkdir -p "$WT_TEST_HOME/wt/advisor-run-unrelated-leftover"
: > "$WT_TEST_HOME/wt/advisor-run-unrelated-leftover/marker"
WT_RUN_C="$(advisor_worktree_new 1 "$WT_FIXTURE_SHA" "$WT_FIXTURE_REPO")"
PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=empty-list ZF_NIGHT_DIR="$WT_TEST_HOME/night" worktree_lifecycle_finish "$WT_RUN_C" "$WT_FIXTURE_REPO"
assert_true "advisor_worktree_cleanup: a pre-existing unrelated leftover directory is left alone" \
  test -f "$WT_TEST_HOME/wt/advisor-run-unrelated-leftover/marker"

# Lock release and worktree cleanup remain independent: cleanup must not
# keep an execution lock held after the unit ends.
INDEP_LOCK_FILE="$(mktemp -u)"
assert_true "independence setup: acquire the lock for this simulated run" \
  try_lock_nonblocking "$INDEP_LOCK_FILE" INDEP_FD
WT_RUN_D="$(advisor_worktree_new 1 "$WT_FIXTURE_SHA" "$WT_FIXTURE_REPO")"
unlock_fd "$INDEP_FD"
PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=empty-list ZF_NIGHT_DIR="$WT_TEST_HOME/night" worktree_lifecycle_finish "$WT_RUN_D" "$WT_FIXTURE_REPO"
assert_false "independence: clean worktree closes after lock release" test -d "$WT_RUN_D"
assert_true "independence: lifecycle cleanup does not gate lock release" \
  bash -c 'exec 9>"$1" && flock -n 9' _ "$INDEP_LOCK_FILE"
rm -f "$INDEP_LOCK_FILE"

# --- pipeline-system routing and live-checkout completion -------------------
PIPELINE_TEST_HOME="$HOME"
HOME="$WT_REAL_HOME"
assert_eq "pipeline-system issue labels come from the ruling" \
  '["pipeline-system"]' "$(pipeline_system_issue_labels_json)"
assert_true "pipeline-system label matches configured lane" \
  pipeline_system_issue_matches '{"labels":[{"name":"pipeline-system"}]}'
assert_false "product state label does not match configured lane" \
  pipeline_system_issue_matches '{"labels":[{"name":"ready-for-agent"}]}'
assert_eq "malformed issue snapshot fails lane classification closed" '2' \
  "$(pipeline_system_issue_matches 'not-json' >/dev/null 2>&1; echo $?)"
ADVISOR_QUEUE_FIXTURE='[{"number":991010,"labels":[{"name":"needs-advisor"}]},{"number":991011,"labels":[{"name":"needs-advisor"},{"name":"on-hold"}]},{"number":991012,"labels":[{"name":"needs-advisor"},{"name":"pipeline-system"}]}]'
mkdir -p "$AGENT_HOME/state"
rm -f "$AGENT_HOME/state/991012.json"
assert_eq "advisor queue excludes on-hold and pipeline-system issues" \
  '[991010]' "$(advisor_queue_filter_json "$ADVISOR_QUEUE_FIXTURE" | jq -c '[.[].number]')"
printf '%s\n' '{"hand_loop_breaker":{"advisor_pending":true},"model_policy":{"step":"advisor"}}' \
  > "$AGENT_HOME/state/991012.json"
assert_eq "advisor queue admits only the marked pipeline-system loop-breaker issue" \
  '[991010,991012]' "$(advisor_queue_filter_json "$ADVISOR_QUEUE_FIXTURE" | jq -c '[.[].number]')"
rm -f "$AGENT_HOME/state/991012.json"

PIPELINE_RETURN_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$PIPELINE_RETURN_HOME/model-policy.json"
PIPELINE_RETURN_OUTPUT="$(AGENT_HOME="$PIPELINE_RETURN_HOME" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  set -euo pipefail
  source "$SCRIPT_DIR/lib.sh"
  roadmap_ensure_issue_parent() { :; }
  gh() {
    if [ "${1:-}" = api ]; then echo '[]'; return 0; fi
    echo "gh:$*" >> "$AGENT_HOME/route-writes"
    if [ "$1 $2" = "issue view" ]; then
      echo '\''{"number":991004,"labels":[{"name":"pipeline-system"}]}'\''
    fi
  }
  issue_verdict_snapshot_guard() { ISSUE_VERDICT_GUARD_SKIPPED=0; return 0; }
  state_merge 991004 '\''{"model_policy":{"unit":"implement","step":"advisor","failure":{"reason":"stale advisor state"}}}'\''
  route_to_advisor 991004 needs-info false '\''{"labels":[{"name":"pipeline-system"}]}'\''
  route_to_recut 991004
  give_up_on_issue 991004 "repeated failure"
  state_read 991004 | jq -r '\''[.state,.model_policy.step,.pipeline_system.enabled] | @tsv'\''
  cat "$AGENT_HOME/route-writes"
')"
assert_eq "pipeline-system forced advisor and recut routes return to implement policy" \
  $'ready-for-agent\twork\ttrue' "$(head -n1 <<< "$PIPELINE_RETURN_OUTPUT")"
for off_lane_label in needs-info needs-triage needs-advisor needs-recut ready-for-human needs-owner awaiting-release; do
  assert_contains "pipeline-system route helpers remove $off_lane_label" \
    "$PIPELINE_RETURN_OUTPUT" "--remove-label $off_lane_label"
done
assert_not_contains "pipeline-system route helpers never add needs-advisor or needs-recut" \
  "$PIPELINE_RETURN_OUTPUT" '--add-label needs-advisor'
assert_not_contains "pipeline-system route helpers never add needs-advisor or needs-recut" \
  "$PIPELINE_RETURN_OUTPUT" '--add-label needs-recut'
rm -rf "$PIPELINE_RETURN_HOME"

PIPELINE_LOOP_ADVISOR_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$PIPELINE_LOOP_ADVISOR_HOME/model-policy.json"
PIPELINE_LOOP_ADVISOR_STATE="$(AGENT_HOME="$PIPELINE_LOOP_ADVISOR_HOME" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  set -euo pipefail
  source "$SCRIPT_DIR/lib.sh"
  gh() { printf "%s\n" "{\"number\":991005,\"state\":\"OPEN\",\"labels\":[{\"name\":\"pipeline-system\"}]}"; }
  loop_break_check() { LOOP_BREAK_ESCALATED=0; }
  issue_transition() { printf "%s\t%s\n" "$2" "$3" >> "$AGENT_HOME/transitions"; }
  state_merge 991005 '\''{"pipeline_system":{"enabled":true},"model_policy":{"unit":"implement","step":"advisor","failure":{"unit":"implement","step":"work","transition":"advisor","same_failure_streak":2}}}'\''
  route_to_advisor 991005 ready-for-agent true '\''{"state":"OPEN","labels":[{"name":"pipeline-system"}]}'\'' hand-loop-breaker
  printf "%s\t%s\n" "$(state_read 991005 | jq -r .hand_loop_breaker.advisor_pending)" "$(cut -f2 "$AGENT_HOME/transitions")"
')"
assert_eq "pipeline-system loop breaker alone enters advisor lane after two matching failures" \
  $'true\tadvisor-route' "$PIPELINE_LOOP_ADVISOR_STATE"
rm -rf "$PIPELINE_LOOP_ADVISOR_HOME"

PIPELINE_CLOSE_FIXTURE="$(mktemp -d)"
PIPELINE_CLOSE_OUT="$(AGENT_HOME="$PIPELINE_CLOSE_FIXTURE" REPO_DIR="$PIPELINE_CLOSE_FIXTURE/missing" REPO=test/repo bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  mkdir -p "$AGENT_HOME/state"
  printf "%s\n" '\''{"pipeline_system":{"enabled":true}}'\'' > "$AGENT_HOME/state/991001.json"
  if conclude_run 991001 pipeline-system missing-live-sha; then echo accepted; else echo rejected; fi
' _ "$SCRIPT_DIR")"
assert_contains "pipeline-system close refuses without a recorded live commit" \
  "$PIPELINE_CLOSE_OUT" 'rejected'

mkdir -p "$PIPELINE_CLOSE_FIXTURE/home" "$PIPELINE_CLOSE_FIXTURE/repo/engine" \
  "$PIPELINE_CLOSE_FIXTURE/bin"
git -C "$PIPELINE_CLOSE_FIXTURE/repo" init -b main >/dev/null
git -C "$PIPELINE_CLOSE_FIXTURE/repo" config user.name 'Pipeline Test'
git -C "$PIPELINE_CLOSE_FIXTURE/repo" config user.email 'pipeline-test'
printf '%s\n' 'live' > "$PIPELINE_CLOSE_FIXTURE/repo/engine/live.sh"
git -C "$PIPELINE_CLOSE_FIXTURE/repo" add engine/live.sh
git -C "$PIPELINE_CLOSE_FIXTURE/repo" commit -m 'live fixture for #991002' >/dev/null
PIPELINE_CLOSE_SHA="$(git -C "$PIPELINE_CLOSE_FIXTURE/repo" rev-parse HEAD)"
git -C "$PIPELINE_CLOSE_FIXTURE/repo" update-ref refs/remotes/origin/main "$PIPELINE_CLOSE_SHA"
cat > "$PIPELINE_CLOSE_FIXTURE/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PIPELINE_GH_LOG"
if [ "$1" = issue ] && [ "$2" = comment ]; then
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [ "${args[$i]}" = --body-file ]; then
      cat "${args[$((i + 1))]}" >> "$PIPELINE_GH_LOG"
      break
    fi
  done
fi
if [ "$1" = issue ] && [ "$2" = view ]; then
  case "$*" in
    *'--json state'*) printf '%s\n' OPEN ;;
    *'--json title,body,subIssuesSummary'*)
      case "$3" in
        991007) printf '%s\n' '{"title":"tracker umbrella","body":"","subIssuesSummary":{"total":1,"completed":0}}' ;;
        *) printf '%s\n' '{"title":"tracker leaf","body":"","subIssuesSummary":{"total":0,"completed":0}}' ;;
      esac ;;
    *) printf '%s\n' '{"state":"OPEN"}' ;;
  esac
fi
if [ "$1" = api ] && [[ "${2:-}" == repos/test/repo/pulls/* ]]; then
  pr_number="${2##*/}"
  case "$pr_number" in
    991005) printf '{"number":%s,"merged":true,"base":{"ref":"main"},"merge_commit_sha":"%s"}\n' "$pr_number" "$PIPELINE_CLOSE_LINKED_SHA" ;;
    991006) printf '{"number":%s,"merged":true,"base":{"ref":"main"},"merge_commit_sha":"%s"}\n' "$pr_number" "$PIPELINE_CLOSE_UNLINKED_SHA" ;;
    991007) printf '{"number":%s,"merged":true,"base":{"ref":"main"},"merged_at":"2026-10-12T18:01:06Z","merge_commit_sha":"%s"}\n' "$pr_number" "$PIPELINE_CLOSE_UNLINKED_SHA" ;;
    991010) printf '{"number":%s,"merged":true,"base":{"ref":"main"},"merged_at":"2026-10-12T18:01:06Z","merge_commit_sha":"%s"}\n' "$pr_number" "$PIPELINE_CLOSE_UNLINKED_SHA" ;;
  esac
fi
if [ "$1" = api ] && [[ "${2:-}" == repos/test/repo/issues/*/sub_issues?per_page=100 ]]; then
  issue_number="${2#repos/test/repo/issues/}"
  issue_number="${issue_number%%/*}"
  if [ "$issue_number" = 991007 ]; then
    printf '%s\n' '[{"number":991009,"state":"open","closed_at":null,"labels":[]}]'
  else
    printf '%s\n' '[]'
  fi
fi
if [ "$1" = api ] && [[ " $* " == *"/comments?"* ]]; then printf '[[]]\n'; fi
EOF
chmod +x "$PIPELINE_CLOSE_FIXTURE/bin/gh"
PIPELINE_GH_LOG="$PIPELINE_CLOSE_FIXTURE/gh.log"

git -C "$PIPELINE_CLOSE_FIXTURE/repo" commit --allow-empty -m 'fix(agent): pipeline issue #991005' >/dev/null
PIPELINE_CLOSE_LINKED_SHA="$(git -C "$PIPELINE_CLOSE_FIXTURE/repo" rev-parse HEAD)"
git -C "$PIPELINE_CLOSE_FIXTURE/repo" commit --allow-empty -m 'fix(agent): unrelated pipeline cleanup' >/dev/null
PIPELINE_CLOSE_UNLINKED_SHA="$(git -C "$PIPELINE_CLOSE_FIXTURE/repo" rev-parse HEAD)"
git -C "$PIPELINE_CLOSE_FIXTURE/repo" update-ref refs/remotes/origin/main "$PIPELINE_CLOSE_UNLINKED_SHA"
PIPELINE_MERGED_LINKED_OUT="$(AGENT_HOME="$PIPELINE_CLOSE_FIXTURE/home" \
  ZF_REPO_DIR="$PIPELINE_CLOSE_FIXTURE/repo" ZF_REPO=test/repo \
  PIPELINE_GH_LOG="$PIPELINE_GH_LOG" PIPELINE_CLOSE_LINKED_SHA="$PIPELINE_CLOSE_LINKED_SHA" \
  PIPELINE_CLOSE_UNLINKED_SHA="$PIPELINE_CLOSE_UNLINKED_SHA" PATH="$PIPELINE_CLOSE_FIXTURE/bin:$PATH" \
  bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    roadmap_ensure_issue_parent() { :; }
    web_advisor_provider_clear_job_state() { return 0; }
    state_merge 991005 ".pipeline_system.enabled = true"
    conclude_merged_run 991005 991005 "PR #991005 merged as $2"
    state_read 991005 | jq -r "[.run.outcome,.state,.pipeline_system.commit_sha,.pipeline_system.delivery_state,.closed_by_pipeline]|@tsv"
  ' _ "$SCRIPT_DIR" "$PIPELINE_CLOSE_LINKED_SHA")"
assert_eq "merged pipeline-system PR closes as pipeline-system when commit cites issue" \
  $'pipeline-system\tconcluded\t'"$PIPELINE_CLOSE_LINKED_SHA"$'\tconcluded\ttrue' "$PIPELINE_MERGED_LINKED_OUT"

PIPELINE_MERGED_UNLINKED_OUT="$(AGENT_HOME="$PIPELINE_CLOSE_FIXTURE/home" \
  ZF_REPO_DIR="$PIPELINE_CLOSE_FIXTURE/repo" ZF_REPO=test/repo \
  PIPELINE_GH_LOG="$PIPELINE_GH_LOG" PIPELINE_CLOSE_LINKED_SHA="$PIPELINE_CLOSE_LINKED_SHA" \
  PIPELINE_CLOSE_UNLINKED_SHA="$PIPELINE_CLOSE_UNLINKED_SHA" PATH="$PIPELINE_CLOSE_FIXTURE/bin:$PATH" \
  bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    roadmap_ensure_issue_parent() { :; }
    web_advisor_provider_clear_job_state() { return 0; }
    state_merge 991006 ".pipeline_system.enabled = true | .run.evidence.pr_head_sha = \"$2\" | .run.evidence.mandatory_checks = {status:\"passed\",head_sha:\"$2\"}"
    conclude_merged_run 991006 991006 "PR #991006 merged as $2"
    state_read 991006 | jq -r "[.run.outcome,.state,.pipeline_system.commit_sha,.deploy_state]|@tsv"
  ' _ "$SCRIPT_DIR" "$PIPELINE_CLOSE_UNLINKED_SHA")"
assert_eq "unlinked pipeline-system PR falls back to merged with commit recorded" \
  $'merged\tawaiting-release\t'"$PIPELINE_CLOSE_UNLINKED_SHA"$'\tpending' "$PIPELINE_MERGED_UNLINKED_OUT"
assert_not_contains "unlinked PR close evidence does not close issue" \
  "$(cat "$PIPELINE_GH_LOG")" 'issue close 991006'

mkdir -p "$PIPELINE_CLOSE_FIXTURE/home/state"
jq -n '{state:"tracker",tracker_parent:true,recut_children:[],run:{outcome:"not-completed",evidence:{}}}' \
  > "$PIPELINE_CLOSE_FIXTURE/home/state/991007.json"
TRACKER_GH_LOG="$PIPELINE_CLOSE_FIXTURE/tracker-gh.log"
PIPELINE_TRACKER_MERGED_OUT="$(AGENT_HOME="$PIPELINE_CLOSE_FIXTURE/home" \
  ZF_REPO_DIR="$PIPELINE_CLOSE_FIXTURE/repo" ZF_REPO=test/repo \
  PIPELINE_GH_LOG="$TRACKER_GH_LOG" PIPELINE_CLOSE_UNLINKED_SHA="$PIPELINE_CLOSE_UNLINKED_SHA" \
  PATH="$PIPELINE_CLOSE_FIXTURE/bin:$PATH" bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    if conclude_merged_run 991007 991007 "PR #991007 merged"; then result=0; else result=$?; fi
    state_read 991007 | jq -r --arg result "$result" \
      "[\$result,.state,.tracker_parent,.run.outcome,.run.evidence.pr_number,.run.evidence.merged_pr.number,.run.evidence.merged_pr.merge_sha,.run.evidence.merged_pr.merged_at] | @tsv"
  ' _ "$SCRIPT_DIR")"
assert_eq "tracker with an open GitHub sub-issue records exact merge without entering release state" \
  $'0\ttracker\ttrue\tnot-completed\t991007\t991007\t'"$PIPELINE_CLOSE_UNLINKED_SHA"$'\t2026-10-12T18:01:06Z' \
  "$PIPELINE_TRACKER_MERGED_OUT"
assert_not_contains "tracker parent merge evidence does not mutate issue labels or close" \
  "$(cat "$TRACKER_GH_LOG")" 'issue edit'
assert_not_contains "tracker parent merge evidence does not close the issue" \
  "$(cat "$TRACKER_GH_LOG")" 'issue close'

jq -n '{state:"tracker",tracker_parent:true,recut_children:[],run:{outcome:"not-completed",evidence:{}}}' \
  > "$PIPELINE_CLOSE_FIXTURE/home/state/991010.json"
TRACKER_LEAF_GH_LOG="$PIPELINE_CLOSE_FIXTURE/tracker-leaf-gh.log"
PIPELINE_TRACKER_LEAF_MERGED_OUT="$(AGENT_HOME="$PIPELINE_CLOSE_FIXTURE/home" \
  ZF_REPO_DIR="$PIPELINE_CLOSE_FIXTURE/repo" ZF_REPO=test/repo \
  PIPELINE_GH_LOG="$TRACKER_LEAF_GH_LOG" PIPELINE_CLOSE_UNLINKED_SHA="$PIPELINE_CLOSE_UNLINKED_SHA" \
  PATH="$PIPELINE_CLOSE_FIXTURE/bin:$PATH" bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    roadmap_ensure_issue_parent() { :; }
    conclude_merged_run 991010 991010 "PR #991010 merged"
    state_read 991010 | jq -r "[.state,(.tracker_parent // false),.run.outcome,.run.evidence.pr_number,.deploy_state]|@tsv"
  ' _ "$SCRIPT_DIR")"
assert_eq "merged childless tracker enters awaiting-release and clears its parent flag" \
  $'awaiting-release\tfalse\tmerged\t991010\tpending' "$PIPELINE_TRACKER_LEAF_MERGED_OUT"
assert_contains "merged tracker leaf removes the tracker label" \
  "$(cat "$TRACKER_LEAF_GH_LOG")" '--remove-label tracker'
assert_contains "merged tracker leaf adds the awaiting-release label" \
  "$(cat "$TRACKER_LEAF_GH_LOG")" '--add-label awaiting-release'
assert_not_contains "merged tracker leaf does not close the issue" \
  "$(cat "$TRACKER_LEAF_GH_LOG")" 'issue close 991010'

PIPELINE_CLOSE_SUCCESS_OUT="$(AGENT_HOME="$PIPELINE_CLOSE_FIXTURE/home" \
  ZF_REPO_DIR="$PIPELINE_CLOSE_FIXTURE/repo" REPO=test/repo \
  PIPELINE_GH_LOG="$PIPELINE_GH_LOG" PATH="$PIPELINE_CLOSE_FIXTURE/bin:$PATH" \
  bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    web_advisor_provider_clear_job_state() { return 0; }
    state_merge 991002 " .pipeline_system.enabled = true | .pipeline_system.commit_sha = \"$2\""
    if ! conclude_run 991002 pipeline-system "commit is live"; then echo refused; exit 1; fi
    state_read 991002 | jq -r "[.run.outcome,.state,.pipeline_system.delivery_state,.closed_by_pipeline]|@tsv"
  ' _ "$SCRIPT_DIR" "$PIPELINE_CLOSE_SHA")"
assert_eq "pipeline-system closes as soon as commit is live" \
  $'pipeline-system\tconcluded\tconcluded\ttrue' "$PIPELINE_CLOSE_SUCCESS_OUT"
assert_contains "pipeline-system close records an issue close" \
  "$(cat "$PIPELINE_GH_LOG")" 'issue close'
assert_contains "pipeline-system close finishes state labels after issue close" \
  "$(cat "$PIPELINE_GH_LOG")" 'issue edit'
assert_contains "pipeline-system conclusion clears a stale in-progress label" \
  "$(grep '^issue edit' "$PIPELINE_GH_LOG")" '--remove-label in-progress'
assert_contains "pipeline-system close comment cites its issue-linked commit" \
  "$(cat "$PIPELINE_GH_LOG")" "Commit: $PIPELINE_CLOSE_SHA"
assert_not_contains "pipeline-system close does not claim product release" \
  "$(grep '^issue edit' "$PIPELINE_GH_LOG")" '--add-label released'

git -C "$PIPELINE_CLOSE_FIXTURE/repo" commit --allow-empty -m 'fix(agent): pipeline issue #991004' >/dev/null
PIPELINE_CLOSE_RETRY_SHA="$(git -C "$PIPELINE_CLOSE_FIXTURE/repo" rev-parse HEAD)"
git -C "$PIPELINE_CLOSE_FIXTURE/repo" update-ref refs/remotes/origin/main "$PIPELINE_CLOSE_RETRY_SHA"
PIPELINE_CLOSE_RETRY_OUT="$(AGENT_HOME="$PIPELINE_CLOSE_FIXTURE/home" \
  ZF_REPO_DIR="$PIPELINE_CLOSE_FIXTURE/repo" REPO=test/repo \
  PIPELINE_GH_LOG="$PIPELINE_GH_LOG" PATH="$PIPELINE_CLOSE_FIXTURE/bin:$PATH" \
  bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    web_advisor_provider_clear_job_state() { return 0; }
    state_merge 991004 " .pipeline_system.enabled = true | .pipeline_system.commit_sha = \"$2\" | .pipeline_system.close_comment_posted_at = (now | todate)"
    if ! conclude_run 991004 pipeline-system "commit is live"; then echo refused; exit 1; fi
    state_read 991004 | jq -r "[.run.outcome,.state]|@tsv"
  ' _ "$SCRIPT_DIR" "$PIPELINE_CLOSE_RETRY_SHA")"
assert_eq "stale close-comment marker is replaced before the issue closes" \
  $'pipeline-system\tconcluded' "$PIPELINE_CLOSE_RETRY_OUT"
assert_contains "stale pipeline close comment is refreshed with SHA evidence" \
  "$(grep -A8 'issue comment 991004' "$PIPELINE_GH_LOG")" "Commit: $PIPELINE_CLOSE_RETRY_SHA"

git -C "$PIPELINE_CLOSE_FIXTURE/repo" commit --allow-empty -m 'fix(agent): pipeline issue #991003' >/dev/null
PIPELINE_CLOSE_UNPUBLISHED_SHA="$(git -C "$PIPELINE_CLOSE_FIXTURE/repo" rev-parse HEAD)"
PIPELINE_CLOSE_UNPUBLISHED_OUT="$(AGENT_HOME="$PIPELINE_CLOSE_FIXTURE/home" \
  ZF_REPO_DIR="$PIPELINE_CLOSE_FIXTURE/repo" REPO=test/repo \
  PIPELINE_GH_LOG="$PIPELINE_GH_LOG" PATH="$PIPELINE_CLOSE_FIXTURE/bin:$PATH" \
  bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    web_advisor_provider_clear_job_state() { return 0; }
    state_merge 991003 " .pipeline_system.enabled = true | .pipeline_system.commit_sha = \"$2\""
    if conclude_run 991003 pipeline-system "commit is live"; then echo accepted; else echo rejected; fi
  ' _ "$SCRIPT_DIR" "$PIPELINE_CLOSE_UNPUBLISHED_SHA")"
assert_contains "pipeline-system close waits until cited commit reaches origin/main" \
  "$PIPELINE_CLOSE_UNPUBLISHED_OUT" 'rejected'
assert_not_contains "unpublished pipeline commit never reaches issue close" \
  "$(cat "$PIPELINE_GH_LOG")" 'issue close 991003'
rm -rf "$PIPELINE_CLOSE_FIXTURE"

# Dispatch budgets use the same 24-hour spend ledger as supervisor used to,
# but now block at the stage/model-call boundary. Keep the measured limits
# and ticket attribution independent of any live state.
SPEND_BUDGET_HOME="$(mktemp -d)"
mkdir -p "$SPEND_BUDGET_HOME/spend"
SPEND_DIR="$SPEND_BUDGET_HOME/spend"
ISSUE_CALL_BUDGET_THRESHOLD=10
ISSUE_TOKEN_BUDGET_THRESHOLD=2200000
SPEND_BUDGET_NOW="$(date +%s)"
SPEND_BUDGET_DAY="$(date -u -d "@$SPEND_BUDGET_NOW" +%F)"
for i in $(seq 1 9); do
  printf '%s\timplement\tcodex:test\t991101\t\t100\n' "$SPEND_BUDGET_NOW" >> "$SPEND_DIR/$SPEND_BUDGET_DAY.log"
done
assert_eq "dispatch budget leaves normal ticket under both thresholds" \
  $'clear\t9\t900' "$(issue_spend_budget_status 991101 "$SPEND_BUDGET_NOW")"
printf '%s\treview\tcodex:test\t991101\t\t100\n' "$SPEND_BUDGET_NOW" >> "$SPEND_DIR/$SPEND_BUDGET_DAY.log"
assert_eq "dispatch budget blocks ticket at call threshold" \
  $'over\t10\t1000' "$(issue_spend_budget_status 991101 "$SPEND_BUDGET_NOW")"
printf '%s\timplement\tcodex:test\t991102\t\t2200000\n' "$SPEND_BUDGET_NOW" > "$SPEND_DIR/$SPEND_BUDGET_DAY.log"
assert_eq "dispatch budget blocks ticket at token threshold" \
  $'over\t1\t2200000' "$(issue_spend_budget_status 991102 "$SPEND_BUDGET_NOW")"
printf '%s\ttriage-batch\tcodex:test\tbatch:991103,991104\t\t2200000\n' "$SPEND_BUDGET_NOW" > "$SPEND_DIR/$SPEND_BUDGET_DAY.log"
assert_eq "dispatch budget attributes shared triage call to included tickets" \
  $'over\t1\t2200000' "$(issue_spend_budget_status 991103 "$SPEND_BUDGET_NOW")"
rm -rf "$SPEND_BUDGET_HOME"

# The review and repair model-output capture invokes this guard before dispatch.
# A successful `gh issue comment` prints its URL; routing stdout must not prefix
# the caller's structured model-policy JSON.
SPEND_GUARD_CAPTURE="$(
  (
    issue_spend_budget_status() { printf 'over\t7\t2766815\n'; }
    route_issue_spend_budget() { printf '%s\n' 'https://github.com/test/repo/issues/991104#issuecomment-1'; }
    spend_guard_status=0
    spend_guard_output="$(issue_spend_budget_guard 991104 review 2>/dev/null)" || spend_guard_status=$?
    printf '%s\t%s' "$spend_guard_status" "$spend_guard_output"
  )
)"
assert_eq "#1942: budget route URL stays out of captured review output" \
  $'78\t' "$SPEND_GUARD_CAPTURE"

mkdir -p "$STATE_DIR"
printf '{"recut_children":[991202]}' > "$(state_file 991201)"
assert_eq "recut umbrella with open child is not implement-eligible" 0 \
  "$(recut_parent_has_open_child 991201 '[{"number":991202,"state":"OPEN"}]' && echo 0 || echo $?)"
assert_eq "recut umbrella with closed child reports completed parent" 3 \
  "$(gh() { echo CLOSED; }; recut_parent_has_open_child 991201 '[]' && echo 0 || echo $?)"
printf '{"state":"needs-advisor","recut_children":[]}\n' > "$(state_file 991205)"
gh() { return 64; }
assert_eq "ordinary empty recut list tolerates an unavailable live child read" 3 \
  "$(recut_parent_has_open_child 991205 '[]' && echo 0 || echo $?)"
printf '{"state":"needs-advisor"}\n' > "$(state_file 991206)"
assert_eq "ordinary issue without recut children tolerates an unavailable live child read" 3 \
  "$(recut_parent_has_open_child 991206 '[]' && echo 0 || echo $?)"
printf '{"state":"tracker","tracker_parent":true,"recut_children":[]}\n' > "$(state_file 991204)"
gh() {
  if [ "${1:-}" = api ]; then printf '[]\n'
  elif [ "${1:-} ${2:-}" = "issue view" ]; then printf '{"body":"","comments":[]}\n'
  else return 64; fi
}
assert_eq "empty recut child list is checked against live sub-issues" 1 \
  "$(recut_parent_has_open_child 991204 '[]' && echo 0 || echo $?)"
unset -f gh
printf '{}' > "$(state_file 991203)"
gh() {
  if [ "${1:-}" = api ] && [[ "${2:-}" == */issues/991203/sub_issues?per_page=100 ]]; then
    echo api >> "$STATE_DIR/991203-gh-calls"
    echo '[]'
  elif [ "${1:-} ${2:-}" = "issue view" ]; then
    echo comments >> "$STATE_DIR/991203-gh-calls"
    echo '{"body":"","comments":[{"body":"plain"}]}'
  else
    return 64
  fi
}
recut_parent_children_json 991203 >/dev/null 2>&1 || true
recut_parent_children_json 991203 >/dev/null 2>&1 || true
unset -f gh
assert_eq "root without a split marker has its comments read once, not every tick" 1 \
  "$(grep -c '^comments$' "$STATE_DIR/991203-gh-calls" || true)"
assert_eq "native child list is read once per parent per tick" 1 \
  "$(grep -c '^api$' "$STATE_DIR/991203-gh-calls" || true)"

NATIVE_PARENT_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$NATIVE_PARENT_HOME/model-policy.json"
mkdir -p "$NATIVE_PARENT_HOME/state"
NATIVE_PARENT_LOG="$NATIVE_PARENT_HOME/gh.log"
NATIVE_PARENT_OUTPUT="$(AGENT_HOME="$NATIVE_PARENT_HOME" REPO=test/repo NATIVE_PARENT_LOG="$NATIVE_PARENT_LOG" \
  NATIVE_CHILD_RELEASED_LABEL='[{"name":"released"}]' \
  bash -c '
    set -euo pipefail
    source "$ZF_EXECUTION_MODULE_DIR/lib.sh"
    roadmap_ensure_issue_parent() { :; }
    REPO=test/repo
    is_on_hold() { return 1; }
    ensure_state_labels() { :; }
    issue_label_cache_invalidate() { :; }
    model_policy() { [ "$1" = initial-step ] && { echo work; return 0; }; return 0; }
    gh() {
      if [ "${1:-}" = api ]; then
        printf "api %s\n" "$2" >> "$NATIVE_PARENT_LOG"
        number="${2#repos/test/repo/issues/}"
        number="${number%%/*}"
        child_labels="[]"
        case "$number" in
          991210) child=991211; child_state=open; closed_at=null ;;
          991212) child=991213; child_state=open; closed_at=null ;;
          991214) child=991215; child_state=open; closed_at=null ;;
          991218) child=991219; child_state=open; closed_at=null ;;
          991220) printf "%s\n" "[]"; return 0 ;;
          991216)
            child=991217
            child_state="${NATIVE_CHILD_STATE:-closed}"
            closed_at="\"2026-01-01T00:00:00Z\""
            if [[ "${child_state^^}" == CLOSED ]]; then child_labels="${NATIVE_CHILD_RELEASED_LABEL:-[]}"; fi
            ;;
          *) echo "unexpected parent $number" >&2; return 64 ;;
        esac
        printf "[{\"number\":%s,\"state\":\"%s\",\"closed_at\":%s,\"labels\":%s}]\n" \
          "$child" "$child_state" "$closed_at" "$child_labels"
      elif [ "${1:-} ${2:-}" = "issue view" ]; then
        printf "%s\n" "{\"body\":\"\",\"comments\":[]}"
      elif [ "${1:-} ${2:-}" = "issue edit" ] || [ "${1:-} ${2:-}" = "issue close" ]; then
        printf "%s\n" "$*" >> "$NATIVE_PARENT_LOG"
      elif [ "${1:-} ${2:-}" = "issue list" ]; then
        printf "%s\n" "[{\"number\":991216,\"title\":\"Native parent\",\"state\":\"OPEN\",\"labels\":[{\"name\":\"needs-advisor\"}],\"blockedBy\":{\"nodes\":[]},\"blocking\":{\"nodes\":[]}}]"
      else
        echo "unexpected gh read $*" >&2
        return 64
      fi
    }

    printf "%s\n" "{}" > "$STATE_DIR/991210.json"
    open_status=1
    if recut_parent_has_open_child 991210 "[]" "{}" 0; then open_status=0; else open_status=$?; fi
    native_children="$(recut_parent_children_json 991210 "{}" 0)"
    recut_parent_has_open_child 991210 "[]" "{}" 0 || :
    printf "native-children=%s open-status=%s parent-reads=%s\n" \
      "$native_children" "$open_status" "$(grep -c "api repos/test/repo/issues/991210/" "$NATIVE_PARENT_LOG" || true)"

    printf "%s\n" "{\"attempts\":3,\"state\":\"needs-advisor\"}" > "$STATE_DIR/991212.json"
    state_requeue 991212
    printf "requeue-state=%s attempts=%s marker=%s\n" \
      "$(state_read 991212 | jq -r .state)" "$(state_attempts 991212)" \
      "$(state_read 991212 | jq -r ".native_subissue_parent // false")"

    NATIVE_PARENT_SUBISSUES_CACHE[991220]="[]"
    printf "%s\n" "{\"state\":\"tracker\",\"tracker_parent\":true,\"recut_children\":[]}" > "$STATE_DIR/991220.json"
    state_requeue 991220 "" pipeline-requeue
    printf "tracker-requeue=%s parent=%s\n" \
      "$(state_read 991220 | jq -r .state)" "$(state_read 991220 | jq -r ".tracker_parent // false")"

    printf "%s\n" "{\"attempts\":2,\"state\":\"needs-advisor\",\"pipeline_system\":{\"enabled\":true},\"model_policy\":{\"unit\":\"implement\",\"step\":\"advisor\"}}" \
      > "$STATE_DIR/991214.json"
    pipeline_system_return_to_implement 991214 needs-advisor
    guarded_write gh issue edit 991214 --repo test/repo --remove-label needs-advisor --add-label ready-for-agent
    printf "advisor-state=%s\n" "$(state_read 991214 | jq -r .state)"
    printf "advisor-writes=%s\n" "$(grep -c "issue edit 991214" "$NATIVE_PARENT_LOG" || true)"

    printf "%s\n" "{\"state\":\"needs-advisor\"}" > "$STATE_DIR/991218.json"
    admit_guarded 991218 P2 L3 "classification needs guarded work" "- [ ] preserve tenant isolation"
    printf "guarded-admission-state=%s\n" "$(state_read 991218 | jq -r .state)"
    printf "guarded-admission-writes=%s\n" "$(grep -c "issue edit 991218" "$NATIVE_PARENT_LOG" || true)"

    printf "%s\n" "{\"state\":\"needs-advisor\",\"native_subissue_parent\":true}" > "$STATE_DIR/991216.json"
    sweep_blocking_issue_roots
    printf "sweep-closed=%s marker=%s\n" \
      "$(grep -c "issue close 991216" "$NATIVE_PARENT_LOG" || true)" \
      "$(state_read 991216 | jq -r ".native_subissue_parent // false")"
  ' 2>&1)" || {
  echo "native parent fixture exited non-zero:" >&2
  echo "$NATIVE_PARENT_OUTPUT" >&2
  FAILED=1
}
assert_contains "native children are discovered without recut state" \
  "$NATIVE_PARENT_OUTPUT" 'native-children=[991211] open-status=0 parent-reads=1'
assert_contains "requeue keeps native parent out of ready-for-agent" \
  "$NATIVE_PARENT_OUTPUT" 'requeue-state=needs-advisor attempts=3 marker=true'
assert_contains "childless tracker can requeue when its recorded child list is empty" \
  "$NATIVE_PARENT_OUTPUT" 'tracker-requeue=ready-for-agent parent=false'
assert_contains "advisor return keeps native parent in its current lane" \
  "$NATIVE_PARENT_OUTPUT" 'advisor-state=needs-advisor'
assert_contains "advisor return does not write ready-for-agent" \
  "$NATIVE_PARENT_OUTPUT" 'advisor-writes=0'
assert_contains "advisor guarded admission leaves a native parent in its current lane" \
  "$NATIVE_PARENT_OUTPUT" 'guarded-admission-state=needs-advisor'
assert_contains "advisor guarded admission does not write ready-for-agent" \
  "$NATIVE_PARENT_OUTPUT" 'guarded-admission-writes=0'
assert_contains "tracked native parent closes after its released children are closed" \
  "$NATIVE_PARENT_OUTPUT" 'sweep-closed=1 marker=false'
assert_eq "native parent status and closure use one sub-issue read per tick" 5 \
  "$(grep -c '^api repos/test/repo/issues/' "$NATIVE_PARENT_LOG" | tr -d ' ')"
rm -rf -- "$NATIVE_PARENT_HOME"
HOME="$PIPELINE_TEST_HOME"

HOME="$WT_REAL_HOME"
rm -rf "$WT_TEST_HOME" "$WT_FIXTURE_REPO"
rm -rf -- "$LIB_TEST_AGENT_HOME"
rm -rf "$WT_TEST_HOME" "$WT_FIXTURE_REPO" "$WT_FIXTURE_REMOTE"

# Direct-main commits name their ticket as `issue N`, never `#N` (a merged PR
# mentioning #N seals N). A close comment that cites such a commit is valid;
# the audit used to demand `#N` and flagged every correct close (issue 1988).
close_repo="$(mktemp -d)"
git -C "$close_repo" init -q
git -C "$close_repo" -c user.name=t -c user.email=t@example.invalid commit --allow-empty -qm '[skip ci] fix(agent): issue 1988 clear rolled-back fleet marker'
close_sha="$(git -C "$close_repo" rev-parse HEAD)"
git -C "$close_repo" update-ref refs/remotes/origin/main "$close_sha"
assert_true "a close comment citing an 'issue N' direct-main commit is valid" \
  pipeline_system_close_comment_valid "$close_repo" 1988 "Supervisor: closing with evidence. The fix is on main as commit $close_sha."
assert_false "an 'issue N' commit does not prove a different issue" \
  pipeline_system_close_comment_valid "$close_repo" 198 "Supervisor: closing with evidence. The fix is on main as commit $close_sha."
rm -rf -- "$close_repo"
test_direct_landing_product_and_revert

# A held issue routed to pipeline-system verification moves its local state with
# its label; 2057 kept state on-hold under an awaiting-pipeline-sync label (2026-10-03).
route_home="$(mktemp -d)"
route_repo="$(mktemp -d)"
git -C "$route_repo" init -q
git -C "$route_repo" -c user.name=t -c user.email=t@example.invalid commit --allow-empty -qm base
(
  AGENT_HOME="$route_home"; STATE_DIR="$route_home/state"; REPO_DIR="$route_repo"
  mkdir -p "$STATE_DIR"
  printf '%s\n' '{"state":"on-hold","hold":null}' > "$STATE_DIR/7301.json"
  guarded_write() { :; }
  guarded_issue_comment() { :; }
  conclude_run() { echo "unexpected conclude_run" >&2; return 1; }
  route_pipeline_system_verification 7301 0123456789abcdef0123456789abcdef01234567
  jq -r '.state + " " + .pipeline_system.delivery_state' "$STATE_DIR/7301.json"
) > "$route_home/out" 2>&1
assert_eq "verification routing moves state with the awaiting-pipeline-sync label" \
  "awaiting-pipeline-sync awaiting-pipeline-sync" "$(tail -n 1 "$route_home/out")"
rm -rf -- "$route_home" "$route_repo"

# --- two-strike rule (ruling pipeline-node-execution-model) -----------------
assert_eq "two-strike class: scope/blast-radius failure" scope-plan \
  "$(two_strike_failure_class 'scope conflict: diff outside the declared blast radius')"
assert_eq "two-strike class: oversized/plan failure" scope-plan \
  "$(two_strike_failure_class 'risk_class P3 refuses: ticket oversized for one implement pass')"
assert_eq "two-strike class: decision failure" decision-ambiguity \
  "$(two_strike_failure_class 'model asked for a decision on the product expectation')"
assert_eq "two-strike class: exit 124 is environmental" environmental \
  "$(two_strike_failure_class 'implement gates failed' 124)"
assert_eq "two-strike class: quota text is environmental" environmental \
  "$(two_strike_failure_class 'quota refused: usage limit reached, try again later')"
assert_eq "two-strike class: landing slot is environmental" environmental \
  "$(two_strike_failure_class 'BLOCKED-ON land-lock while waiting for a preflight slot')"
assert_eq "two-strike class: unclassified gate failure" unclassified \
  "$(two_strike_failure_class 'preflight command failed with exit 3')"

two_strike_fixture_state() {
  # <step> <reason-1> <reason-2> <status> [extra-jq]
  jq -cn --arg step "$1" --arg r1 "$2" --arg r2 "$3" --argjson status "$4" --arg extra "${5:-}" '
    def norm($r): ($r | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "") | sub("(?i)(?<p>issue )#[0-9]+"; "\(.p)#<issue>"));
    {attempts: 3, model_policy: {failures: [
      {unit: "implement", step: $step, stage: "implement-gates", reason: $r1, normalized_reason: norm($r1), status: $status, recorded_at: "2026-10-08T00:00:00Z"},
      {unit: "implement", step: $step, stage: "implement-gates", reason: $r2, normalized_reason: norm($r2), status: $status, recorded_at: "2026-10-08T01:00:00Z"}
    ]}} + (if $extra == "" then {} else ($extra | fromjson) end)
  '
}

two_strike_case() {
  # <case-name> <state-json> [own-open-pr:0|1] -- runs
  # enforce_implement_two_strike against a fixture issue with the route
  # functions and the comment writer faked, then prints the routed/not-routed
  # line, the state marker, and whatever the faked route/comment calls
  # captured. The gh fake answers issue_own_open_agent_pr's pr-list probe.
  local name="$1" state_json="$2" own_open_pr="${3:-0}" home log comment
  home="$(mktemp -d)"
  mkdir -p "$home/state"
  printf '%s\n' "$state_json" > "$home/state/4291.json"
  log="$home/routed.log"
  comment="$home/comment.md"
  AGENT_HOME="$home" bash -c '
    lib_dir="$1"; log="$2"; comment="$3"; own_open_pr="$4"
    source "$lib_dir/lib.sh"
    gh() {
      if [[ "${1:-} ${2:-}" == "pr list" ]]; then
        if [ "$own_open_pr" = 1 ]; then echo "[{\"number\":991234}]"; else echo "[]"; fi
        return 0
      fi
      return 1
    }
    route_to_recut() { echo "route_to_recut $1" >> "$log"; return 0; }
    route_to_advisor() { echo "route_to_advisor $1" >> "$log"; return 0; }
    guarded_issue_comment() { printf "%s\n" "$2" >> "$comment"; return 0; }
    if enforce_implement_two_strike 4291; then
      echo "routed"
    else
      echo "not-routed"
    fi
    echo "marker=$(jq -r ".two_strike.route // \"none\"" "$AGENT_HOME/state/4291.json")"
    cat "$log" 2>/dev/null || true
    cat "$comment" 2>/dev/null || true
  ' _ "$SCRIPT_DIR" "$log" "$comment" "$own_open_pr" 2>/dev/null
  rm -rf -- "$home"
}

TWO_STRIKE_OUT="$(two_strike_case scope-pair "$(two_strike_fixture_state work \
  'scope conflict: diff outside the declared blast radius for issue #4291' \
  'scope conflict: diff outside the declared blast radius for issue #4291' 1)")"
assert_contains "two identical scope failures route away (no third full attempt)" "$TWO_STRIKE_OUT" "routed"
assert_contains "two identical scope failures route through needs-recut" "$TWO_STRIKE_OUT" "route_to_recut 4291"
assert_contains "two identical scope failures record the recut route in state" "$TWO_STRIKE_OUT" "marker=recut"

TWO_STRIKE_DECISION_OUT="$(two_strike_case decision-pair "$(two_strike_fixture_state work \
  'model needs a decision on the product expectation' \
  'model needs a decision on the product expectation' 1)")"
assert_contains "two identical decision failures route away" "$TWO_STRIKE_DECISION_OUT" "routed"
assert_contains "two identical decision failures route through the advisor" "$TWO_STRIKE_DECISION_OUT" "route_to_advisor 4291"
assert_contains "two identical decision failures record the advisor route in state" "$TWO_STRIKE_DECISION_OUT" "marker=advisor"

TWO_STRIKE_ENV_OUT="$(two_strike_case environmental-pair "$(two_strike_fixture_state work \
  'implement run timed out after 5400s waiting on CI' \
  'implement run timed out after 5400s waiting on CI' 124)")"
assert_contains "two environmental failures do not route away" "$TWO_STRIKE_ENV_OUT" "not-routed"
assert_contains "two environmental failures leave no route marker" "$TWO_STRIKE_ENV_OUT" $'not-routed\nmarker=none'

TWO_STRIKE_DIFFERENT_OUT="$(two_strike_case different-reasons "$(two_strike_fixture_state work \
  'scope conflict outside the declared blast radius' \
  'local preflight failed for widget tests' 1)")"
assert_contains "two different failures do not route away" "$TWO_STRIKE_DIFFERENT_OUT" "not-routed"

TWO_STRIKE_STEPS_OUT="$(two_strike_case different-steps "$(two_strike_fixture_state work \
  'model needs a decision on the product expectation' \
  'model needs a decision on the product expectation' 1 | jq -c '.model_policy.failures[1].step = "work_retry"')")"
assert_contains "the same failure at two different steps does not route away" "$TWO_STRIKE_STEPS_OUT" "not-routed"

TWO_STRIKE_MARKER_OUT="$(two_strike_case already-routed "$(two_strike_fixture_state work \
  'scope conflict outside the declared blast radius' \
  'scope conflict outside the declared blast radius' 1 \
  '{"two_strike":{"step":"work","normalized_reason":"scope conflict outside the declared blast radius","route":"recut"}}')")"
assert_contains "a pair that already routed never re-routes a re-armed ticket" "$TWO_STRIKE_MARKER_OUT" "not-routed"

TWO_STRIKE_LANE_OUT="$(two_strike_case pipeline-system-lane "$(two_strike_fixture_state work \
  'scope conflict outside the declared blast radius' \
  'scope conflict outside the declared blast radius' 1 \
  '{"pipeline_system":{"enabled":true}}')")"
assert_contains "pipeline-system tickets keep their own same-failure conclude path" "$TWO_STRIKE_LANE_OUT" "not-routed"

# #2796: a work failure on a ticket that already carries its own open agent PR
# stays in the PR lane -- the two-strike gate must not open an advisor/recut
# episode on top of blocking-pr-recovery and the merge sweeper.
TWO_STRIKE_OPEN_PR_OUT="$(two_strike_case own-open-pr "$(two_strike_fixture_state work \
  'model needs a decision on the product expectation' \
  'model needs a decision on the product expectation' 1)" 1)"
assert_contains "a ticket with its own open PR is never routed away by two-strike" "$TWO_STRIKE_OPEN_PR_OUT" "not-routed"

TWO_STRIKE_COMMENT_OUT="$(two_strike_case comment-names-both "$(two_strike_fixture_state work \
  'scope conflict: diff outside the declared blast radius' \
  'scope conflict: diff outside the declared blast radius' 1)")"
assert_contains "the two-strike comment states the rule" "$TWO_STRIKE_COMMENT_OUT" "Two-strike rule"
assert_contains "the two-strike comment names the first failure" "$TWO_STRIKE_COMMENT_OUT" "Failure 1: scope conflict: diff outside the declared blast radius"
assert_contains "the two-strike comment names the second failure" "$TWO_STRIKE_COMMENT_OUT" "Failure 2: scope conflict: diff outside the declared blast radius"

# --- cross-family review (ruling reviewer-different-model-family-2026-11-03) -
# The policy review role is GLM by default. A GLM-authored unit uses the Codex
# work identity; an unavailable different-family reviewer returns defer status 75.
CROSS_REVIEW_MODEL=cross-review-fixture
CROSS_REVIEW_IDENTITY="zcode:$CROSS_REVIEW_MODEL:max"
CROSS_REVIEW_POLICY="$(mktemp)"
jq --arg model "$CROSS_REVIEW_MODEL" '.roles.review = {provider:"zcode",model:$model,effort:"max"}' \
  "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$CROSS_REVIEW_POLICY"
REVIEW_HELPERS_HOME="$(mktemp -d)"
mkdir -p "$REVIEW_HELPERS_HOME/state" "$REVIEW_HELPERS_HOME/bin" "$REVIEW_HELPERS_HOME/home"
cp "$CROSS_REVIEW_POLICY" "$REVIEW_HELPERS_HOME/model-policy.json"
# The fake zcode binary plus its provider config make the cross reviewer
# "available". The Codex probe marker admits the reviewer for the reverse direction.
cat > "$REVIEW_HELPERS_HOME/bin/zcode" <<'EOF'
#!/usr/bin/env bash
printf 'zcode called\n' >&2
echo 'reviewer preamble'
echo '```json'
echo '{"verdict":"NOT_READY","report_md":"cross-provider finding: widget test missing"}'
echo '```'
EOF
chmod +x "$REVIEW_HELPERS_HOME/bin/zcode"
mkdir -p "$REVIEW_HELPERS_HOME/home/.zcode/v2"
jq -n --arg model "$CROSS_REVIEW_MODEL" '{config:{defaultModelSelection:{modelId:$model}}}' \
  > "$REVIEW_HELPERS_HOME/home/.zcode/v2/provider_config.json"
touch "$REVIEW_HELPERS_HOME/codex-probe-passed"
mkdir -p "$REVIEW_HELPERS_HOME/home/.zenoforge"
jq -n --argjson read_at "$(date +%s)" '{freshness:"fresh",read_at:$read_at,max_age_seconds:900,five_h_pct:0,week_pct:1,cap_5h:60,cap_week:100}' \
  > "$REVIEW_HELPERS_HOME/home/.zenoforge/zc-quota.json"
REVIEW_CROSS_OUT="$(HOME="$REVIEW_HELPERS_HOME/home" AGENT_HOME="$REVIEW_HELPERS_HOME" PATH="$REVIEW_HELPERS_HOME/bin:$PATH" bash -c '
  source "$0/lib.sh"
  work="$(model_policy identity work)"
  review="$(model_policy identity review)"
  [ "${review%%:*}" != "${work%%:*}" ] && echo "policy review role is cross-provider"
  echo "codex-implementer-review: $(review_model_for_implementer 4293 "$work")"
  echo "zcode-implementer-review: $(review_model_for_implementer 4293 "$review")"
' "$SCRIPT_DIR" 2>/dev/null)"
assert_contains "a codex implementer is reviewed by the other provider" "$REVIEW_CROSS_OUT" "codex-implementer-review: $CROSS_REVIEW_IDENTITY"
assert_contains "a zcode implementer is reviewed by the codex work role" "$REVIEW_CROSS_OUT" "zcode-implementer-review: $MODEL_POLICY_TEST_WORK_IDENTITY"
assert_contains "the pinned review role is cross-provider" "$REVIEW_CROSS_OUT" "policy review role is cross-provider"

# The zcode runner parses the fenced verdict into the shared envelope.
REVIEW_RUNNER_OUT="$(HOME="$REVIEW_HELPERS_HOME/home" AGENT_HOME="$REVIEW_HELPERS_HOME" PATH="$REVIEW_HELPERS_HOME/bin:$PATH" bash -c '
  source "$0/lib.sh"
  schema="$(mktemp)"; prompt="$(mktemp)"; wt="$(mktemp -d)"
  echo "{\"type\":\"object\",\"properties\":{\"verdict\":{\"type\":\"string\"},\"report_md\":{\"type\":\"string\"}},\"required\":[\"verdict\",\"report_md\"]}" > "$schema"
  echo "Run the the product code review skill." > "$prompt"
  run_model_json "$wt" "$(model_policy identity review)" 1 "$schema" "$prompt" "" review | jq -c "{is_error, verdict: .structured_output.verdict}"
  rm -f "$schema" "$prompt"
' "$SCRIPT_DIR" 2>/dev/null)"
assert_contains "run_model_json dispatches a zcode review and parses the verdict" "$REVIEW_RUNNER_OUT" '"is_error":false'
assert_contains "the zcode review verdict reaches the shared envelope unchanged" "$REVIEW_RUNNER_OUT" '"verdict":"NOT_READY"'
rm -rf -- "$REVIEW_HELPERS_HOME"

# No zcode runtime at all: review waits instead of using the author's family.
REVIEW_FALLBACK_HOME="$(mktemp -d)"
mkdir -p "$REVIEW_FALLBACK_HOME/state"
cp "$CROSS_REVIEW_POLICY" "$REVIEW_FALLBACK_HOME/model-policy.json"
printf '%s\n' '{"attempts":2}' > "$REVIEW_FALLBACK_HOME/state/4294.json"
REVIEW_FALLBACK_OUT="$(AGENT_HOME="$REVIEW_FALLBACK_HOME" bash -c '
  source "$0/lib.sh"
  work="$(model_policy identity work)"
  if review_model_for_implementer 4294 "$work"; then echo "unexpected-review-dispatch"; else echo "review-waits:$?"; fi
' "$SCRIPT_DIR" 2>/dev/null)"
rm -rf -- "$REVIEW_FALLBACK_HOME"
assert_contains "missing cross runtime leaves the review pending" "$REVIEW_FALLBACK_OUT" "review-waits:75"
assert_not_contains "missing cross runtime never dispatches a same-family reviewer" "$REVIEW_FALLBACK_OUT" "unexpected-review-dispatch"

# A zcode quota hold blocks the cross reviewer even with the runtime present.
REVIEW_QUOTA_HOME="$(mktemp -d)"
mkdir -p "$REVIEW_QUOTA_HOME/state" "$REVIEW_QUOTA_HOME/bin" "$REVIEW_QUOTA_HOME/home/.zcode/v2"
cp "$CROSS_REVIEW_POLICY" "$REVIEW_QUOTA_HOME/model-policy.json"
cat > "$REVIEW_QUOTA_HOME/bin/zcode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$REVIEW_QUOTA_HOME/bin/zcode"
jq -n --arg model "$CROSS_REVIEW_MODEL" '{config:{defaultModelSelection:{modelId:$model}}}' \
  > "$REVIEW_QUOTA_HOME/home/.zcode/v2/provider_config.json"
echo $(( $(date +%s) + 1800 )) > "$REVIEW_QUOTA_HOME/zcode-exhausted-until"
printf '%s\n' '{"attempts":1}' > "$REVIEW_QUOTA_HOME/state/4295.json"
REVIEW_QUOTA_OUT="$(HOME="$REVIEW_QUOTA_HOME/home" AGENT_HOME="$REVIEW_QUOTA_HOME" PATH="$REVIEW_QUOTA_HOME/bin:$PATH" bash -c '
  source "$0/lib.sh"
  work="$(model_policy identity work)"
  provider_quota_exhausted zcode && echo "zcode quota hold read"
  if review_model_for_implementer 4295 "$work"; then echo "unexpected-review-dispatch"; else echo "quota-review-waits:$?"; fi
' "$SCRIPT_DIR" 2>/dev/null)"
rm -rf -- "$REVIEW_QUOTA_HOME"
assert_contains "a zcode quota hold is visible through the shared marker lookup" "$REVIEW_QUOTA_OUT" "zcode quota hold read"
assert_contains "a held cross provider waits instead of reusing the author family" "$REVIEW_QUOTA_OUT" "quota-review-waits:75"
assert_not_contains "a quota hold never dispatches a same-family reviewer" "$REVIEW_QUOTA_OUT" "unexpected-review-dispatch"

# A live policy that predates the review role resolves no cross reviewer and
# waits instead of dispatching a same-family reviewer.
REVIEW_OLDPOLICY_HOME="$(mktemp -d)"
mkdir -p "$REVIEW_OLDPOLICY_HOME/state"
jq 'del(.roles.review)' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$REVIEW_OLDPOLICY_HOME/model-policy.json"
printf '%s\n' '{"attempts":1}' > "$REVIEW_OLDPOLICY_HOME/state/4296.json"
REVIEW_OLDPOLICY_OUT="$(AGENT_HOME="$REVIEW_OLDPOLICY_HOME" bash -c '
  source "$0/lib.sh"
  work="$(model_policy identity work)"
  if review_model_for_implementer 4296 "$work"; then echo "unexpected-review-dispatch"; else echo "old-policy-waits:$?"; fi
' "$SCRIPT_DIR" 2>/dev/null)"
rm -rf -- "$REVIEW_OLDPOLICY_HOME"
assert_contains "a policy without the review role waits" "$REVIEW_OLDPOLICY_OUT" "old-policy-waits:75"
assert_not_contains "an unresolvable review role never dispatches the author's family" "$REVIEW_OLDPOLICY_OUT" "unexpected-review-dispatch"

# A reply without a valid JSON object fails closed as an exec failure.
REVIEW_MALFORMED_HOME="$(mktemp -d)"
mkdir -p "$REVIEW_MALFORMED_HOME/bin"
cp "$CROSS_REVIEW_POLICY" "$REVIEW_MALFORMED_HOME/model-policy.json"
cat > "$REVIEW_MALFORMED_HOME/bin/zcode" <<'EOF'
#!/usr/bin/env bash
echo 'I looked at the diff and it seemed mostly fine, no JSON though'
EOF
chmod +x "$REVIEW_MALFORMED_HOME/bin/zcode"
REVIEW_MALFORMED_OUT="$(AGENT_HOME="$REVIEW_MALFORMED_HOME" PATH="$REVIEW_MALFORMED_HOME/bin:$PATH" bash -c '
  source "$0/lib.sh"
  schema="$(mktemp)"; prompt="$(mktemp)"; wt="$(mktemp -d)"
  echo "{\"type\":\"object\",\"properties\":{\"verdict\":{\"type\":\"string\"},\"report_md\":{\"type\":\"string\"}},\"required\":[\"verdict\",\"report_md\"]}" > "$schema"
  echo "Run the the product code review skill." > "$prompt"
  set +e
  out="$(run_model_json "$wt" "$(model_policy identity review)" 1 "$schema" "$prompt" "" review)"
  status=$?
  set -e
  echo "$out" | jq -c "{is_error, subtype}"
  echo "exit=$status"
  rm -f "$schema" "$prompt"
' "$SCRIPT_DIR" 2>/dev/null)"
rm -rf -- "$REVIEW_MALFORMED_HOME"
assert_contains "a reply without a valid JSON object fails closed" "$REVIEW_MALFORMED_OUT" '"is_error":true'
assert_contains "a malformed zcode reply is classified as an exec failure" "$REVIEW_MALFORMED_OUT" '"subtype":"zcode_exec_failure"'
rm -f -- "$CROSS_REVIEW_POLICY"

# Retired hand-queue routing is covered by hold.test.sh using issue-state and
# GitHub fixtures, including comment and label failures and retry idempotency.
HANDOFF_HELPER_OUT="$(bash -c '
  source "$1/lib.sh"
  state_read() { printf "%s\n" "{\"state\":\"on-hold\",\"hold\":{\"created_at\":\"episode\",\"release_condition\":\"fix\"},\"last_failure_reason\":\"review finding\"}"; }
  guarded_issue_comment() { printf "comment:%s\n" "$2"; }
  state_requeue() { printf "transition:%s:%s:%s\n" "$1" "$2" "$3"; }
  supervisor_hold_owner_state() { SUPERVISOR_HOLD_OWNER_STATE=none; }
  git_fetch_hand_bounded() { :; }
  gh() { printf "[]\n"; }
  git() { :; }
  scheduler_requeue_issue 999 "owner gone" "{\"state\":\"OPEN\",\"comments\":[]}"
' _ "$SCRIPT_DIR")"
assert_contains "handoff publishes the previous failure" "$HANDOFF_HELPER_OUT" 'review finding'
assert_contains "handoff requeues through the existing transition" "$HANDOFF_HELPER_OUT" 'transition:999:release-hold:hold-requeue'

# --- rebase_agent_pr_onto_main: a real `git rebase` against a fixture repo ---
# A PR that is CONFLICTING solely because main moved is rebased and pushed; a
# PR with a real content conflict is left alone, unresolved, and its remote
# branch is untouched (lessons/RULES.md is deliberately not special-cased).
REBASE_ROOT="$(mktemp -d)"
REBASE_ORIGIN="$REBASE_ROOT/origin"
REBASE_REPO="$REBASE_ROOT/repo"
mkdir -p "$REBASE_ORIGIN" "$REBASE_REPO/packages/widget"
git init -q --bare "$REBASE_ORIGIN"
git -C "$REBASE_ORIGIN" symbolic-ref HEAD refs/heads/main
git -C "$REBASE_REPO" init -q -b main
git -C "$REBASE_REPO" config user.email test@example.com
git -C "$REBASE_REPO" config user.name Test
printf 'line1\nline2\nline3\n' > "$REBASE_REPO/packages/widget/shared.txt"
echo 'module.exports = {};' > "$REBASE_REPO/packages/widget/other.js"
git -C "$REBASE_REPO" add -A
git -C "$REBASE_REPO" commit -q -m seed
git -C "$REBASE_REPO" remote add origin "$REBASE_ORIGIN"
git -C "$REBASE_REPO" push -q -u origin main
git -C "$REBASE_REPO" checkout -q -b agent/issue-1295
echo 'module.exports = { clean: true };' > "$REBASE_REPO/packages/widget/other.js"
git -C "$REBASE_REPO" commit -q -am "clean-rebase PR: touches a file main never touches again"
git -C "$REBASE_REPO" push -q -u origin agent/issue-1295
REBASE_SHA_1295="$(git -C "$REBASE_REPO" rev-parse agent/issue-1295)"
git -C "$REBASE_REPO" checkout -q main
git -C "$REBASE_REPO" checkout -q -b agent/issue-1296
sed -i 's/line2/line2-pr-edit/' "$REBASE_REPO/packages/widget/shared.txt"
git -C "$REBASE_REPO" commit -q -am "conflicting PR: edits the SAME line main also edits"
git -C "$REBASE_REPO" push -q -u origin agent/issue-1296
REBASE_SHA_1296="$(git -C "$REBASE_REPO" rev-parse agent/issue-1296)"
git -C "$REBASE_REPO" checkout -q main
sed -i 's/line2/line2-main-moved/' "$REBASE_REPO/packages/widget/shared.txt"
git -C "$REBASE_REPO" commit -q -am "main moved"
git -C "$REBASE_REPO" push -q origin main
REBASE_RC_1295=0
REBASE_RC_1296=0
( REPO_DIR="$REBASE_REPO"; ZF_AGENT_GIT_USER_NAME="Test Bot"; ZF_AGENT_GIT_USER_EMAIL="test-bot@example.invalid"
  DRY_RUN=0; PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=empty-list ZF_NIGHT_DIR="$WT_TEST_HOME/night" \
    rebase_agent_pr_onto_main agent/issue-1295 "$REBASE_SHA_1295" ) >/dev/null 2>&1 || REBASE_RC_1295=$?
( REPO_DIR="$REBASE_REPO"; ZF_AGENT_GIT_USER_NAME="Test Bot"; ZF_AGENT_GIT_USER_EMAIL="test-bot@example.invalid"
  DRY_RUN=0; PATH="$SUA_BIN:$PATH" SYSTEMCTL_MODE=empty-list ZF_NIGHT_DIR="$WT_TEST_HOME/night" \
    rebase_agent_pr_onto_main agent/issue-1296 "$REBASE_SHA_1296" ) >/dev/null 2>&1 || REBASE_RC_1296=$?
assert_eq "a CONFLICTING PR that rebases cleanly onto main is rebased and pushed" 0 "$REBASE_RC_1295"
assert_true "...and its remote branch moved onto the new main" \
  test "$(git -C "$REBASE_ORIGIN" rev-parse refs/heads/agent/issue-1295)" != "$REBASE_SHA_1295"
assert_eq "a PR with a real content conflict against main is left alone (rebase aborted)" 1 "$REBASE_RC_1296"
assert_eq "origin's conflicting branch is untouched by the aborted rebase" \
  "$REBASE_SHA_1296" "$(git -C "$REBASE_ORIGIN" rev-parse refs/heads/agent/issue-1296)"
rm -rf "$REBASE_ROOT"

# --- issue_label_snapshot_load: one bulk read per label, failure is explicit --
LABEL_SNAPSHOT_OUT="$(
  REPO=test/repo
  GH_CALL_TIMEOUT_SEC=60
  gh() {
    case "$LABEL_SNAPSHOT_CASE" in
      ok) printf '1295\n1301\nnot-a-number\n' ;;
      fail) echo "api failure" >&2; return 1 ;;
      full) seq 1 1000 ;;
    esac
  }
  for LABEL_SNAPSHOT_CASE in ok fail full; do
    issue_label_cache_invalidate
    ISSUE_LABEL_BULK_QUERY_COUNT=0
    issue_label_snapshot_load on-hold
    issue_label_snapshot_load on-hold
    ids="$(printf '%s' "${ISSUE_LABEL_SNAPSHOT_IDS[on-hold]}" | paste -sd, -)"
    printf '%s state=%s ids=%s queries=%s\n' "$LABEL_SNAPSHOT_CASE" "${ISSUE_LABEL_SNAPSHOT_STATE[on-hold]}" "${ids:0:9}" "$ISSUE_LABEL_BULK_QUERY_COUNT"
  done
)"
assert_contains "a label snapshot lists numeric members and is read once per ttl window" \
  "$LABEL_SNAPSHOT_OUT" 'ok state=complete ids=1295,1301 queries=1'
assert_contains "an unreadable label snapshot is marked unavailable, not empty" \
  "$LABEL_SNAPSHOT_OUT" 'fail state=unavailable ids= queries=1'
assert_contains "a 1000-row label snapshot is marked truncated" \
  "$LABEL_SNAPSHOT_OUT" 'full state=truncated'

# Mandatory-check receipts are exact-head evidence: only a blocked or failed
# receipt for the merged head stops success. No receipt (hand PRs, PRs opened
# before receipts) and deferred receipts leave admission to the exact-head
# merge gate. Replay preserves the original receipt timestamp.
RECEIPT_TEST_HOME="$(mktemp -d)"
mkdir -p "$RECEIPT_TEST_HOME/state"
RECEIPT_MATRIX_OUT="$(AGENT_HOME="$RECEIPT_TEST_HOME" DRY_RUN=0 AGENT_DRY_RUN=0 \
  ZF_REPO_DIR="$MODEL_POLICY_TEST_REPO" REPO=test/repo bash -s -- "$SCRIPT_DIR" <<'RECEIPT_TEST'
set -euo pipefail
SCRIPT_DIR="$1"
source "$SCRIPT_DIR/lib.sh"
HEAD_A=0123456789abcdef0123456789abcdef01234567
HEAD_B=abcdef0123456789abcdef0123456789abcdef01

record_mandatory_check_receipt 900001 passed "$HEAD_A" 'unit tests passed'
if mandatory_check_receipt_ready 900001 "$HEAD_A"; then echo passed=1; else echo passed=0; fi
state_merge 900001 '.run.evidence.mandatory_checks.recorded_at = "2000-01-01T00:00:00Z"'
before="$(jq -c '.run.evidence.mandatory_checks' "$STATE_DIR/900001.json")"
record_mandatory_check_receipt 900001 passed "$HEAD_A" 'unit tests passed'
after="$(jq -c '.run.evidence.mandatory_checks' "$STATE_DIR/900001.json")"
[ "$before" = "$after" ] && echo replay=1 || echo replay=0

record_mandatory_check_receipt 900002 deferred "$HEAD_A" 'integration tests deferred to PR CI'
if mandatory_check_receipt_ready 900002 "$HEAD_A"; then echo deferred=1; else echo deferred=0; fi

record_mandatory_check_receipt 900003 blocked "$HEAD_A" 'local test blocked by environment'
state_merge 900003 ".run.evidence.pr_number = 795 | .run.evidence.pr_head_sha = \"$HEAD_A\" | .run.evidence.ci_outcome = \"pass\" | .run.evidence.ci_head_sha = \"$HEAD_A\""
if mandatory_check_receipt_ready 900003 "$HEAD_A"; then echo blocked=1; else echo blocked=0; fi
if conclude_run 900003 merged ''; then echo blocked_conclude=1; else echo blocked_conclude=0; fi
echo "blocked_outcome=$(jq -r '.run.outcome // "none"' "$STATE_DIR/900003.json")"
if mandatory_check_receipt_ready 900003 "$HEAD_B"; then echo blocked_older_head=1; else echo blocked_older_head=0; fi
record_mandatory_check_receipt 900005 failed "$HEAD_A" 'unit tests failed'
if mandatory_check_receipt_ready 900005 "$HEAD_A"; then echo failed=1; else echo failed=0; fi

state_merge 900004 '{"run":{"evidence":{"pr_head_sha":"'"$HEAD_A"'"}}}'
state_merge 900004 '.run.evidence.pr_number = 796'
if mandatory_check_receipt_ready 900004 "$HEAD_A"; then echo missing=1; else echo missing=0; fi
echo "missing_status=$(jq -r '.run.evidence.mandatory_checks.status' "$STATE_DIR/900004.json")"
RECEIPT_TEST
)"
assert_eq "passed receipt admits exact tested head" 1 "$(sed -n 's/^passed=//p' <<< "$RECEIPT_MATRIX_OUT")"
assert_eq "receipt replay is idempotent" 1 "$(sed -n 's/^replay=//p' <<< "$RECEIPT_MATRIX_OUT")"
assert_eq "deferred receipt leaves admission to the exact-head merge gate" 1 "$(sed -n 's/^deferred=//p' <<< "$RECEIPT_MATRIX_OUT")"
assert_eq "blocked receipt rejects even matching CI" 0 "$(sed -n 's/^blocked=//p' <<< "$RECEIPT_MATRIX_OUT")"
assert_eq "blocked receipt cannot conclude merged success" 0 "$(sed -n 's/^blocked_conclude=//p' <<< "$RECEIPT_MATRIX_OUT")"
assert_eq "blocked conclusion leaves outcome unset" none "$(sed -n 's/^blocked_outcome=//p' <<< "$RECEIPT_MATRIX_OUT")"
assert_eq "blocked receipt for an earlier head does not judge the merged head" 1 "$(sed -n 's/^blocked_older_head=//p' <<< "$RECEIPT_MATRIX_OUT")"
assert_eq "failed receipt rejects success" 0 "$(sed -n 's/^failed=//p' <<< "$RECEIPT_MATRIX_OUT")"
assert_eq "no receipt (hand or pre-receipt PR) does not block success" 1 "$(sed -n 's/^missing=//p' <<< "$RECEIPT_MATRIX_OUT")"
assert_eq "readiness check writes no receipt of its own" null "$(sed -n 's/^missing_status=//p' <<< "$RECEIPT_MATRIX_OUT")"
rm -rf "$RECEIPT_TEST_HOME"

TRIAGE_CONFIG_OVERRIDE_DIR="$(mktemp -d)"
LIB_TEST_TMP_DIRS+=("$TRIAGE_CONFIG_OVERRIDE_DIR")
mkdir -p "$TRIAGE_CONFIG_OVERRIDE_DIR/prompts"
printf '%s\n' '{"type":"object","required":["config_marker"],"properties":{"config_marker":{"type":"boolean"}}}' \
  > "$TRIAGE_CONFIG_OVERRIDE_DIR/prompts/triage.schema.json"
TRIAGE_CONFIG_OVERRIDE_RESULT="$TRIAGE_CONFIG_OVERRIDE_DIR/result.json"
jq -nc '{category:"bug",state:"ready-for-agent",risk_class:"P1",level:"L1",entry_surface:"API",acceptor:"none",brief_md:"fix",notes_md:"",expected_packages:[],expected_paths:[],estimated_changed_lines:0,external_deliverable:{required:false,location:"",reason:""}}' \
  > "$TRIAGE_CONFIG_OVERRIDE_RESULT"
if ZF_CONFIG_ROOT="$TRIAGE_CONFIG_OVERRIDE_DIR" triage_result_matches_schema "$TRIAGE_CONFIG_OVERRIDE_RESULT"; then
  TRIAGE_CONFIG_OVERRIDE_STATUS=accepted
else
  TRIAGE_CONFIG_OVERRIDE_STATUS=rejected
fi
assert_eq "triage schema validation reads target config override" rejected "$TRIAGE_CONFIG_OVERRIDE_STATUS"

lib_case_exit
