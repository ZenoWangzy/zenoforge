#!/usr/bin/env bash
# Conclusion and advisor ownership regression cases from the library suite.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-lib-helpers.sh"
# --- conclude_run: refuses an outcome it cannot produce the artifact for --
# docs/agents/issue-pipeline.md "Every run concludes with an account of
# itself" -- maintainer ruling, 2026-09-15: nothing in flight waits for a human
# A park must not be able to wear the costume of a
# conclusion: conclude_run() refuses (prints why, returns 1, writes
# nothing) unless the state already carries the artifact the outcome
# needs. Every call here runs under AGENT_DRY_RUN=1 (no real gh call, no
# real state write from conclude_run's OWN state_merge) with the input
# state pre-seeded by writing the JSON file directly -- the same "seed a
# fixture file, read the dry-run print" shape run-implement.test.sh's
# scenarios already use.
CONCLUDE_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$CONCLUDE_HOME/model-policy.json"
mkdir -p "$CONCLUDE_HOME/state"

CONCLUDE_MERGED_REFUSE_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500001 merged ""
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run refuses merged with no pr_number recorded" \
  "$CONCLUDE_MERGED_REFUSE_OUT" "refusing outcome=merged"
assert_contains "...and returns 1, not a silent success" \
  "$CONCLUDE_MERGED_REFUSE_OUT" "exit=1"
assert_not_contains "...and never applies the concluded label when refusing" \
  "$CONCLUDE_MERGED_REFUSE_OUT" "--add-label concluded"

echo '{"attempts":1,"run":{"evidence":{"pr_number":777,"pr_head_sha":"0123456789abcdef0123456789abcdef01234567","mandatory_checks":{"status":"passed","head_sha":"0123456789abcdef0123456789abcdef01234567"}}}}' > "$CONCLUDE_HOME/state/500002.json"
CONCLUDE_MERGED_OK_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    roadmap_ensure_issue_parent() { :; }
    conclude_run 500002 merged ""
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run admits merged once .run.evidence.pr_number is recorded" \
  "$CONCLUDE_MERGED_OK_OUT" "exit=0"
assert_contains "...records the merged ticket as awaiting release" \
  "$CONCLUDE_MERGED_OK_OUT" "--add-label awaiting-release"
assert_contains "...strips an orphaned in-progress label on merge" \
  "$CONCLUDE_MERGED_OK_OUT" "--remove-label in-progress"
assert_contains "...strips ready-for-agent (the same 'exactly one state label' invariant give_up_on_issue enforces)" \
  "$CONCLUDE_MERGED_OK_OUT" "--remove-label ready-for-agent"
assert_contains "...records deploy_state=pending before a deployment exists" \
  "$CONCLUDE_MERGED_OK_OUT" '"deploy_state": "pending"'
assert_not_contains "...never closes at merge" \
  "$CONCLUDE_MERGED_OK_OUT" "gh issue close 500002"

echo '{"attempts":1,"run":{"evidence":{"pr_number":778,"review_verdict":"READY"}}}' > "$CONCLUDE_HOME/state/500003.json"
CONCLUDE_PROPEN_REFUSE_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500003 pr-open ""
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run refuses pr-open when ci_outcome is still missing (two of three evidence fields is not enough)" \
  "$CONCLUDE_PROPEN_REFUSE_OUT" "exit=1"

echo '{"attempts":1,"run":{"evidence":{"pr_number":779,"review_verdict":"READY","ci_outcome":"pass"}}}' > "$CONCLUDE_HOME/state/500004.json"
CONCLUDE_PROPEN_OK_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    roadmap_ensure_issue_parent() { :; }
    conclude_run 500004 pr-open "a footprint gate blocked auto-merge; needs a human to widen expected_packages or confirm the extra file"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run admits pr-open once all three evidence fields are recorded" \
  "$CONCLUDE_PROPEN_OK_OUT" "exit=0"
assert_contains "pr-open conclusion uses the reporter-only report email" \
  "$CONCLUDE_PROPEN_OK_OUT" "[dry-run] send_email"
assert_contains "...the needs_md reaches the record" \
  "$CONCLUDE_PROPEN_OK_OUT" "confirm the extra file"

echo '{"attempts":2}' > "$CONCLUDE_HOME/state/500005.json"
CONCLUDE_NC_REFUSE_ATTEMPTS_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500005 not-completed "missing a rehearsal environment"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run refuses not-completed below the attempt cap, even with needs_md set" \
  "$CONCLUDE_NC_REFUSE_ATTEMPTS_OUT" "exit=1"

echo '{"attempts":1,"run":{"concluded_at":"2026-09-24T00:00:00Z","implement_started_at":"2026-09-20T00:00:00Z"},"model_policy":{"unit":"implement","step":"conclude","failure":{"reason":"old run","recorded_at":"2026-09-20T00:00:00Z"}}}' > "$CONCLUDE_HOME/state/500011.json"
CONCLUDE_NC_REFUSE_STALE_CONCLUSION_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500011 not-completed "missing a rehearsal environment"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run refuses stale conclude state after prior conclusion even without requeued_at" \
  "$CONCLUDE_NC_REFUSE_STALE_CONCLUSION_OUT" "exit=1"

echo '{"attempts":1,"requeued_at":"2026-09-25T00:00:00Z","run":{"implement_started_at":"2026-09-20T00:00:00Z"},"model_policy":{"unit":"implement","step":"conclude","failure":{"reason":"old run","recorded_at":"2026-09-20T00:00:00Z"}}}' > "$CONCLUDE_HOME/state/500008.json"
CONCLUDE_NC_REFUSE_STALE_POLICY_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500008 not-completed "missing a rehearsal environment"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run refuses stale model-policy exhaustion after requeue" \
  "$CONCLUDE_NC_REFUSE_STALE_POLICY_OUT" "exit=1"
assert_not_contains "...does not add concluded label for stale policy state" \
  "$CONCLUDE_NC_REFUSE_STALE_POLICY_OUT" "--add-label concluded"

echo '{"attempts":0,"requeued_at":"2026-09-25T00:00:00Z","model_policy":{"unit":"implement","step":"conclude","failure":{"reason":"old run","recorded_at":"2026-09-20T00:00:00Z"}}}' > "$CONCLUDE_HOME/state/500010.json"
CONCLUDE_NC_REFUSE_ZERO_ATTEMPTS_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500010 not-completed "missing a rehearsal environment"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run refuses model-policy exhaustion with zero attempts" \
  "$CONCLUDE_NC_REFUSE_ZERO_ATTEMPTS_OUT" "exit=1"

echo '{"attempts":1,"requeued_at":"2026-09-20T00:00:00Z","run":{"implement_started_at":"2026-09-25T00:01:00Z"},"model_policy":{"unit":"implement","step":"conclude","failure":{"reason":"fresh run","recorded_at":"2026-09-25T00:02:00Z"}}}' > "$CONCLUDE_HOME/state/500009.json"
CONCLUDE_NC_ACCEPT_FRESH_POLICY_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500009 not-completed "missing a rehearsal environment"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run admits a fresh policy failure after requeue" \
  "$CONCLUDE_NC_ACCEPT_FRESH_POLICY_OUT" "exit=0"

echo '{"attempts":4}' > "$CONCLUDE_HOME/state/500006.json"
CONCLUDE_NC_REFUSE_NEEDS_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500006 not-completed ""
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run refuses not-completed at the cap but with an empty needs_md -- a bare attempt count is not an account" \
  "$CONCLUDE_NC_REFUSE_NEEDS_OUT" "exit=1"

echo '{"attempts":4,"requeued_at":"2026-09-30T16:49:03Z","run":{"outcome":"not-completed","implement_started_at":"2026-10-04T09:41:21Z","concluded_at":"2026-10-04T09:41:22Z"},"model_policy":{"unit":"implement","step":"conclude","failure":{"reason":"delivery failed","recorded_at":"2026-10-04T09:41:21Z"}}}' > "$CONCLUDE_HOME/state/500013.json"
CONCLUDE_NC_CAP_AFTER_HOLD_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500013 not-completed "Implement dispatch reached its 4-attempt cap."
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run admits a capped issue resumed by hold expiry, which can never start a new implement" \
  "$CONCLUDE_NC_CAP_AFTER_HOLD_OUT" "exit=0"

# State files pass the 128 KiB per-argument limit; --argjson then failed "Argument list too long" (2026-10-10).
jq -n '{attempts:4,model_policy:{unit:"implement",history:[range(0;1500) | {note:("history entry " + tostring + " padding padding padding padding padding padding")}]}}' \
  > "$CONCLUDE_HOME/state/500014.json"
CONCLUDE_NC_LARGE_STATE_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500014 not-completed "Implement dispatch reached its 4-attempt cap."
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run concludes a capped issue whose state is over 128 KiB" \
  "$CONCLUDE_NC_LARGE_STATE_OUT" "exit=0"

echo '{"attempts":4}' > "$CONCLUDE_HOME/state/500007.json"
CONCLUDE_NC_OK_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500007 not-completed "missing capability: fixture rehearsal environment"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run admits not-completed at the cap with a named missing capability" \
  "$CONCLUDE_NC_OK_OUT" "exit=0"
assert_contains "not-completed conclusion clears a stale in-progress label" \
  "$CONCLUDE_NC_OK_OUT" "--remove-label in-progress"
assert_contains "...the issue still gets its round-result comment" \
  "$CONCLUDE_NC_OK_OUT" "[dry-run] gh issue comment 500007"
assert_contains "not-completed conclusion attempts a classified report email" \
  "$CONCLUDE_NC_OK_OUT" "[dry-run] send_email"

# Keep invocation-local multiline text even if issue-comment handling
# replaces the on-disk state before the email is composed.
CONCLUDE_MAIL_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=0 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    guarded_write() { return 0; }
    guarded_issue_comment() { printf "%s\n" "{\"attempts\":4,\"run\":{\"needs_md\":\"replacement\"}}" > "$STATE_DIR/500012.json"; }
    notify_email_reporter() { printf "MAIL-VIA:notify_email_reporter MAIL-ARGS:%s\n" "$*"; }
    printf "%s\n" "{\"attempts\":4,\"last_failure_reason\":\"前置依赖票仍未关闭，当前仓库没有可用实现\"}" > "$STATE_DIR/500012.json"
    conclude_run 500012 not-completed "缺少演练环境
重试条件：环境恢复后再跑"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "not-completed email stays business-readable" \
  "$CONCLUDE_MAIL_OUT" '不用现在操作；处理原因已记录在问题进展中。'
assert_contains "not-completed email carries the recorded failure reason" \
  "$CONCLUDE_MAIL_OUT" '前置依赖票仍未关闭，当前仓库没有可用实现'
assert_not_contains "not-completed email replaces its generic summary with the recorded reason" \
  "$CONCLUDE_MAIL_OUT" '这一轮已经结束。'
assert_not_contains "not-completed email omits invocation-local diagnostics" \
  "$CONCLUDE_MAIL_OUT" '重试条件'
assert_contains "not-completed email uses reporter-only wrapper" \
  "$CONCLUDE_MAIL_OUT" 'notify_email_reporter'

CONCLUDE_MAIL_FALLBACK_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=0 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    guarded_write() { return 0; }
    guarded_issue_comment() { :; }
    notify_email_reporter() { printf "MAIL-ARGS:%s\\n" "$*"; }
    printf "%s\\n" "{\"attempts\":4,\"guard_reason\":\"The prerequisite implementation does not exist yet.\"}" > "$STATE_DIR/500013.json"
    conclude_run 500013 not-completed "attempts exhausted"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "not-completed email falls back when recorded reason fails maintainer-readable gate" \
  "$CONCLUDE_MAIL_FALLBACK_OUT" '这一轮没能改完，先停下了。'
assert_not_contains "not-completed email does not expose an English recorded reason" \
  "$CONCLUDE_MAIL_FALLBACK_OUT" 'The prerequisite implementation does not exist yet.'

ADVISOR_RETRY_REASON_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$ADVISOR_RETRY_REASON_HOME/model-policy.json"
ADVISOR_RETRY_REASON_OUT="$(AGENT_HOME="$ADVISOR_RETRY_REASON_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  printf "%s\\n" "{\"attempts\":4,\"guard_reason\":\"前置依赖票仍未关闭，当前工作无法开始\"}" > "$STATE_DIR/509993.json"
  web_advisor_provider_clear_job_state() { :; }
  status=0; advisor_retry_admission 509993 || status=$?
  echo "exit=$status"
' _ "$SCRIPT_DIR" 2>&1)"
assert_contains "retry-exhaustion issue comment carries the current guard reason" \
  "$ADVISOR_RETRY_REASON_OUT" '前置依赖票仍未关闭，当前工作无法开始'
rm -rf "$ADVISOR_RETRY_REASON_HOME"

# New not-completed conclusions must persist a class and an executable route
# from their durable state evidence, before the next scheduler tick sees them.
cat > "$CONCLUDE_HOME/state/500020.json" <<'EOF'
{"attempts":4,"run":{"implement_started_at":"2026-09-27T09:00:00Z"},"model_policy":{"unit":"implement","retry_note":{"stage":"implement","status":1,"attempt_refunded":true,"reason":"CI runner capacity precondition failed","recorded_at":"2026-09-27T09:01:00Z"}}}
EOF
cat > "$CONCLUDE_HOME/state/500021.json" <<'EOF'
{"attempts":4,"run":{"implement_started_at":"2026-09-27T09:00:00Z"},"model_policy":{"unit":"implement","failure":{"stage":"role-identity","status":64,"reason":"model identity does not match the work role","recorded_at":"2026-09-27T09:01:00Z"}}}
EOF
cat > "$CONCLUDE_HOME/state/500022.json" <<'EOF'
{"attempts":4,"risk_class":"P2","level":"L3","run":{"implement_started_at":"2026-09-27T09:00:00Z"},"model_policy":{"unit":"implement","failure":{"stage":"package-gate","status":1,"reason":"package test failed","recorded_at":"2026-09-27T09:01:00Z"}}}
EOF
cat > "$CONCLUDE_HOME/state/500024.json" <<'EOF'
{"attempts":4,"risk_class":"P1","level":"L1","run":{"implement_started_at":"2026-09-27T09:00:00Z"},"model_policy":{"unit":"implement","failure":{"stage":"package-gate","status":1,"reason":"package test failed","recorded_at":"2026-09-27T09:01:00Z"}}}
EOF
cat > "$CONCLUDE_HOME/state/500025.json" <<'EOF'
{"attempts":1,"pipeline_system":{"enabled":true},"run":{"implement_started_at":"2026-09-27T09:00:00Z"},"model_policy":{"unit":"implement","step":"conclude","failure":{"stage":"pipeline-system-delivery","status":1,"signature":"pipeline-system-delivery-failed","reason":"pipeline-system delivery returned an invalid commit SHA","evidence":"delivery output: {\"commitSha\":\"not-a-sha\"}","recorded_at":"2026-09-27T09:01:00Z"}}}
EOF
CONCLUDE_CLASSIFICATION_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=0 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    is_on_hold() { return 1; }
    guarded_write() { :; }
    guarded_issue_comment() { :; }
    notify_email() { :; }
    notify_email_reporter() { :; }
    web_advisor_provider_clear_job_state() { :; }
    conclude_run 500020 not-completed "capacity failure" || exit 1
    conclude_run 500021 not-completed "model role mismatch" || exit 1
    conclude_run 500022 not-completed "package test failure" || exit 1
    conclude_run 500024 not-completed "package test failure" || exit 1
    conclude_run 500025 not-completed "pipeline-system delivery returned an invalid commit SHA" || exit 1
    for issue in 500020 500021 500022 500024; do
      jq -r ".run.conclusion | [.class,.route] | @tsv" "$STATE_DIR/$issue.json"
    done
    jq -r ".run.conclusion | [.class,.route,.owner,.signature] | @tsv" "$STATE_DIR/500025.json"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_eq "conclude_run classifies infra, pipeline defect, and ticket from fake state" \
  $'infrastructure\trequeue\npipeline-defect\trequeue\nticket\trecut\nticket\trequeue\npipeline-defect\trequeue\tsupervisor-inbox\tpipeline-system-delivery-failed' \
  "$CONCLUDE_CLASSIFICATION_OUT"

CONCLUDE_ENV_FAULT_EPOCH="$(date +%s)"
CONCLUDE_ENV_FAULT_STARTED="$(date -u -d "@$((CONCLUDE_ENV_FAULT_EPOCH - 30))" +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$CONCLUDE_HOME/env-faults"
cat > "$CONCLUDE_HOME/state/500023.json" <<EOF
{"attempts":4,"run":{"implement_started_at":"$CONCLUDE_ENV_FAULT_STARTED"}}
EOF
printf '%s\timplement@packages/example\t500023\tenv:test-gate:docker\tDocker precondition is missing\n' \
  "$CONCLUDE_ENV_FAULT_EPOCH" > "$CONCLUDE_HOME/env-faults/env_test_gate_docker.log"
AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=0 REPO="test/repo" bash -c '
  source "$0/lib.sh"
  is_on_hold() { return 1; }
  guarded_write() { :; }
  guarded_issue_comment() { :; }
  notify_email_reporter() { :; }
  web_advisor_provider_clear_job_state() { :; }
  conclude_run 500023 not-completed "Docker precondition is missing" || exit 1
' "$SCRIPT_DIR" >/dev/null 2>&1
assert_eq "env-fault ledger classifies its issue as infrastructure" infrastructure \
  "$(jq -r '.run.conclusion.class' "$CONCLUDE_HOME/state/500023.json")"
assert_eq "env-fault ledger preserves the matching quarantine scope" implement@packages/example \
  "$(jq -r '.run.conclusion.scope' "$CONCLUDE_HOME/state/500023.json")"

MERGE_AGENT_PR_BODY="$(awk '
  /^merge_agent_pr\(\) \{/ { in_function=1 }
  in_function { print }
  in_function && /^}$/ { exit }
' "$SCRIPT_DIR/lib.sh")"
assert_not_contains "#1597: merge_agent_pr has no control-surface exception; guarded risk-class hits use one admission path" \
  "$MERGE_AGENT_PR_BODY" 'select(.kind == "control-surface")'

# #1377: terminal guard lives before every conclusion, not after a caller
# attempts a refund. Seed cap-before-refusal to cover the dangerous window.
echo '{"attempts":4}' > "$CONCLUDE_HOME/state/500010.json"
CONCLUDE_HOLD_REFUSE_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    printf "%s\n" "$(( $(date +%s) + 600 ))" > "$CODEX_EXHAUSTED_MARKER_FILE"
    conclude_run 500010 not-completed "missing capability: provider quota is refusing all calls" codex
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
rm -f "$CONCLUDE_HOME/codex-exhausted-until"
assert_contains "#1377: conclude_run refuses a cap-reached ticket while its provider hold is open" \
  "$CONCLUDE_HOLD_REFUSE_OUT" "provider quota hold is open"
assert_contains "#1377: the hold refusal returns non-zero before any conclusion" \
  "$CONCLUDE_HOLD_REFUSE_OUT" "exit=1"
assert_not_contains "#1377: the hold refusal never applies the concluded label" \
  "$CONCLUDE_HOLD_REFUSE_OUT" "--add-label concluded"

GIVEUP_HOLD_REFUSE_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    printf "%s\n" "$(( $(date +%s) + 600 ))" > "$CODEX_EXHAUSTED_MARKER_FILE"
    give_up_on_issue 500010 "provider quota refusal" codex
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
rm -f "$CONCLUDE_HOME/codex-exhausted-until"
assert_contains "#1377: legacy per-ticket give_up_on_issue is suppressed during the same hold" \
  "$GIVEUP_HOLD_REFUSE_OUT" "provider quota hold is open"
assert_not_contains "#1377: suppressed give_up_on_issue sends no per-ticket email" \
  "$GIVEUP_HOLD_REFUSE_OUT" "遇到点麻烦，已经转给顾问了"

GIVEUP_NONQUOTA_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    roadmap_ensure_issue_parent() { :; }
    gh() {
      if [ "$1 $2" = "issue view" ]; then
        echo '\''{"number":500011,"labels":[]}'\''
      fi
    }
    printf "%s\n" "$(( $(date +%s) + 600 ))" > "$CODEX_EXHAUSTED_MARKER_FILE"
    echo "{\"attempts\":2}" > "$STATE_DIR/500011.json"
    notify_email() { printf "PER-TICKET:%s\n" "$*"; }
give_up_on_issue 500011 "前置依赖票 #500012 仍未关闭" "" "{\"labels\":[]}"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
rm -f "$CONCLUDE_HOME/codex-exhausted-until"
assert_contains "#1377: an unrelated real failure still reaches its per-ticket give-up path during a provider hold" \
  "$GIVEUP_NONQUOTA_OUT" "[dry-run] gh issue comment 500011"
assert_contains "give_up_on_issue email carries the readable failure reason" \
  "$GIVEUP_NONQUOTA_OUT" "PER-TICKET:500011 [example] #500011 已转给顾问了 前置依赖票 #500012 仍未关闭"
assert_contains "#1377: the non-provider give-up is not refused by another provider's hold" \
  "$GIVEUP_NONQUOTA_OUT" "exit=0"

CONCLUDE_UNKNOWN_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500008 some-made-up-outcome "x"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run fails closed on an unrecognized outcome" \
  "$CONCLUDE_UNKNOWN_OUT" "exit=1"

# --- conclude_run: deploy-time close after real-user-path proof ------------
# Merge is implementation completion, not production completion. It removes
# ready-for-agent and records the pending deploy, so neither label selection
# nor the independent merged-PR gate can re-implement it. The actual GitHub
# close waits for URL, visible DOM, and same-run network evidence.
echo '{"attempts":1,"acceptor":"none","run":{"evidence":{"pr_number":790,"pr_head_sha":"0123456789abcdef0123456789abcdef01234567","mandatory_checks":{"status":"passed","head_sha":"0123456789abcdef0123456789abcdef01234567"}}}}' > "$CONCLUDE_HOME/state/500009.json"
CONCLUDE_NONE_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    roadmap_ensure_issue_parent() { :; }
    queue_maintainer_outcome() { printf "queued:%s:%s\n" "$1" "$2"; }
    conclude_run 500009 merged ""
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "acceptor=none, merged: admits" "$CONCLUDE_NONE_OUT" "exit=0"
assert_contains "...applies awaiting-release" "$CONCLUDE_NONE_OUT" "--add-label awaiting-release"
assert_not_contains "...does not close before production proof" "$CONCLUDE_NONE_OUT" "gh issue close 500009"
assert_not_contains "...does not announce a production result at merge" "$CONCLUDE_NONE_OUT" "send_email"
assert_not_contains "...does not queue a production result at merge" "$CONCLUDE_NONE_OUT" "queued:"

echo '{"attempts":1,"run":{"outcome":"merged","evidence":{"pr_number":791}}}' > "$CONCLUDE_HOME/state/500014.json"
RECORD_DEPLOY_LEGACY_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    record_deploy_evidence 500014 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "Feature surface: authenticated /chat/ photo attachment send\nURL: https://example.example/chat; Visible DOM: the product; Same-run network: GET /api/me -> 200"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "legacy merged record migrates to deploy_state through production evidence" \
  "$RECORD_DEPLOY_LEGACY_OUT" "exit=0"
assert_contains "...records deployed state for the legacy merge too" \
  "$RECORD_DEPLOY_LEGACY_OUT" '"deploy_state": "deployed"'
LIVE_SHA_RECORD="$(cat "$CONCLUDE_HOME/state/live-sha.json" 2>/dev/null || true)"
assert_contains "post-deploy success writes the live SHA record" "$LIVE_SHA_RECORD" '"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
assert_contains "live SHA record carries its write time and source" "$LIVE_SHA_RECORD" '"source":"post-deploy-success"'

echo '{"attempts":1,"brief_md":"#1839: send a photo attachment through /chat/","run":{"outcome":"merged","evidence":{"pr_number":793}}}' > "$CONCLUDE_HOME/state/500020.json"
PHOTO_GENERIC_REPLAY_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    if record_deploy_evidence 500020 abc1234 "URL: https://example.example/chat/ -> /login -> /chat/\nVisible DOM: the product; 登录工作空间; 安全登录.\nSame-run network: GET /chat/api/v1/auths/ -> 200 (finished)."; then echo exit=0; else echo exit=1; fi
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "#1839 replay rejects login and page-load evidence without a photo send" \
  "$PHOTO_GENERIC_REPLAY_OUT" "feature surface is unnamed"
assert_contains "#1839 replay cannot record a deployed state" "$PHOTO_GENERIC_REPLAY_OUT" "exit=1"
assert_not_contains "#1839 replay does not migrate deploy state" "$PHOTO_GENERIC_REPLAY_OUT" '"deploy_state": "deployed"'

echo '{"attempts":1,"brief_md":"#1839: photo attachment","acceptor":"reporter","deploy_state":"deployed","deployed_sha":"abc1234","run":{"outcome":"merged","evidence":{"pr_number":794,"real_user_path":"URL: https://example.example/chat/ -> /login -> /chat/\\nVisible DOM: the product; 登录工作空间; 安全登录.\\nSame-run network: GET /chat/api/v1/auths/ -> 200 (finished)."}}}' > "$CONCLUDE_HOME/state/500021.json"
PHOTO_GENERIC_CLOSE_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500021 deployed "Production evidence recorded."
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "#1839 replay also fails the independent deployed-close gate" "$PHOTO_GENERIC_CLOSE_OUT" "feature surface is unnamed"
assert_not_contains "#1839 replay never closes the ticket" "$PHOTO_GENERIC_CLOSE_OUT" "gh issue close 500021"

echo '{"title":"Admin notification settings","brief_md":"Add admin notification settings panel"}' > "$CONCLUDE_HOME/state/500022.json"
FEATURE_MATCH_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    release_feature_evidence_valid 500022 "Feature surface: admin notification settings panel"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "named non-photo feature surface matches the ticket brief" "$FEATURE_MATCH_OUT" "exit=0"
echo '{"title":"管理员通知设置","brief_md":"修复管理员通知设置面板"}' > "$CONCLUDE_HOME/state/500023.json"
FEATURE_MATCH_ZH_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    release_feature_evidence_valid 500023 "Feature surface: 管理员通知设置面板"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "Chinese ticket brief matches its named feature surface" "$FEATURE_MATCH_ZH_OUT" "exit=0"
FEATURE_MISMATCH_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    if release_feature_evidence_valid 500022 "Feature surface: photo attachment send through /chat/"; then echo exit=0; else echo exit=1; fi
  ' "$SCRIPT_DIR" 2>&1
)"
# 2026-09-24 ruling: what the automated acceptance cannot exercise closes at
# deploy and the reporter reopens. Refusing reran the production E2E every
# tick for issue 1211 (8 runs in 50 minutes).
assert_contains "feature surface the acceptance does not exercise is named as uncovered" \
  "$FEATURE_MISMATCH_OUT" "not exercised by the automated acceptance"
assert_contains "uncovered non-photo surface closes at deploy instead of looping" "$FEATURE_MISMATCH_OUT" "exit=0"

echo '{"attempts":1,"acceptor":"reporter","brief_md":"## Acceptance criteria\\n- [ ] 能查到结果","run":{"evidence":{"pr_number":792,"pr_head_sha":"0123456789abcdef0123456789abcdef01234567","mandatory_checks":{"status":"passed","head_sha":"0123456789abcdef0123456789abcdef01234567"}}}}' > "$CONCLUDE_HOME/state/500011.json"
CONCLUDE_REPORTER_MERGED_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    roadmap_ensure_issue_parent() { :; }
    conclude_run 500011 merged ""
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_not_contains "acceptor=reporter, merged: does not close" "$CONCLUDE_REPORTER_MERGED_OUT" "gh issue close"
assert_not_contains "...does not send the old closing notification before deploy" "$CONCLUDE_REPORTER_MERGED_OUT" "已经改完关闭了"

echo '{"attempts":1,"acceptor":"reporter","deploy_state":"deployed","deployed_sha":"abc1234","run":{"outcome":"merged","evidence":{"pr_number":792,"real_user_path":"URL: https://example.example/chat\\nVisible DOM: the product"}}}' > "$CONCLUDE_HOME/state/500012.json"
CONCLUDE_DEPLOY_REFUSE_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500012 deployed "Production evidence recorded."
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "deployed refuses missing same-run network evidence" "$CONCLUDE_DEPLOY_REFUSE_OUT" "exit=1"
assert_not_contains "...never closes on partial production evidence" "$CONCLUDE_DEPLOY_REFUSE_OUT" "gh issue close"

echo '{"attempts":1,"acceptor":"reporter","deploy_state":"deployed","deployed_sha":"abc1234","run":{"outcome":"merged","evidence":{"pr_number":792,"pr_head_sha":"0123456789abcdef0123456789abcdef01234567","mandatory_checks":{"status":"passed","head_sha":"0123456789abcdef0123456789abcdef01234567"},"real_user_path":"Feature surface: authenticated /chat/ photo attachment send\\nURL: https://example.example/chat\\nVisible DOM: the product\\nSame-run network: GET /api/me -> 200"}}}' > "$CONCLUDE_HOME/state/500013.json"
CONCLUDE_DEPLOY_OK_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    queue_maintainer_outcome() { printf "queued:%s:%s\n" "$1" "$2"; }
    conclude_run 500013 deployed "Production evidence recorded."
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
conclude_split_close() { # gh issue list body, then its exit code
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" SPLIT_LIST="$1" SPLIT_RC="$2" bash -c '
    source "$0/lib.sh"
    queue_maintainer_outcome() { :; }
    guarded_issue_comment() { printf "%s\n" "$2"; }
    gh() { [ "$1 $2" = "issue list" ] && { printf "%s" "$SPLIT_LIST"; return "$SPLIT_RC"; }; }
    conclude_run 500013 deployed "Production evidence recorded."
  ' "$SCRIPT_DIR" 2>&1
}
CONCLUDE_DEPLOY_SPLIT_OUT="$(conclude_split_close '[{"number":9001,"title":"x（续作自 #500013）"},{"number":9002,"title":"y（续作自 #5000130）"}]' 0)"
assert_contains "a split parent's close comment names its open follow-up" "$CONCLUDE_DEPLOY_SPLIT_OUT" "剩余范围在 #9001 继续"
assert_not_contains "...and no ticket whose title only looks like one" "$CONCLUDE_DEPLOY_SPLIT_OUT" "#9002"
CONCLUDE_DEPLOY_NOSPLIT_OUT="$(conclude_split_close '[]' 0)"
assert_contains "a ticket with no follow-up still closes" "$CONCLUDE_DEPLOY_NOSPLIT_OUT" "这张票已经关闭"
assert_not_contains "...and says nothing about one" "$CONCLUDE_DEPLOY_NOSPLIT_OUT" "剩余范围"
CONCLUDE_DEPLOY_SEARCHFAIL_OUT="$(conclude_split_close '' 1)"
assert_contains "a failed search does not hold the deployed close" "$CONCLUDE_DEPLOY_SEARCHFAIL_OUT" "gh issue close 500013"
assert_contains "deployed closes after URL, DOM, and same-run network evidence" \
  "$CONCLUDE_DEPLOY_OK_OUT" "gh issue close 500013"
assert_contains "deployed conclusion clears a stale in-progress label" \
  "$CONCLUDE_DEPLOY_OK_OUT" "--remove-label in-progress"
assert_contains "deploy close clears on-hold so a later reopen can re-enter triage" \
  "$CONCLUDE_DEPLOY_OK_OUT" "--remove-label on-hold"
assert_contains "...keeps deployed status visible beside concluded" \
  "$CONCLUDE_DEPLOY_OK_OUT" "--add-label released"
assert_contains "...queues the production result only after proof" \
  "$CONCLUDE_DEPLOY_OK_OUT" "queued:500013:abc1234"
assert_not_contains "...does not send an immediate per-ticket email" \
  "$CONCLUDE_DEPLOY_OK_OUT" "send_email"
assert_contains "...stores deploy_state=deployed in final state" \
  "$CONCLUDE_DEPLOY_OK_OUT" '"deploy_state": "deployed"'
assert_contains "...keeps legacy release selector from dispatching it again" \
  "$CONCLUDE_DEPLOY_OK_OUT" '"released": true'

# A failed outbox write leaves deployed proof marked for the scheduler's next
# tick; a successful retry queues it and clears only that marker.
OUTCOME_RECOVERY_HOME="$CONCLUDE_HOME/outcome-recovery"
mkdir -p "$OUTCOME_RECOVERY_HOME/state"
echo '{"deployed_sha":"abc1234","maintainer_outcome_pending":true}' > "$OUTCOME_RECOVERY_HOME/state/500099.json"
OUTCOME_RECOVERY_FAIL_OUT="$(
  AGENT_HOME="$OUTCOME_RECOVERY_HOME" DRY_RUN=0 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    queue_maintainer_outcome() { return 1; }
    if reconcile_maintainer_outcomes; then echo exit=0; else echo exit=1; fi
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "failed outcome queue write stays retryable" "$OUTCOME_RECOVERY_FAIL_OUT" "exit=1"
assert_eq "failed queue write preserves the recovery marker" "true" \
  "$(jq -r '.maintainer_outcome_pending' "$OUTCOME_RECOVERY_HOME/state/500099.json")"
OUTCOME_RECOVERY_OK_OUT="$(
  AGENT_HOME="$OUTCOME_RECOVERY_HOME" DRY_RUN=0 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    queue_maintainer_outcome() { printf "queued:%s:%s\\n" "$1" "$2"; }
    if reconcile_maintainer_outcomes; then echo exit=0; else echo exit=1; fi
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "retry queues the deployed issue and clears marker" "$OUTCOME_RECOVERY_OK_OUT" "queued:500099:abc1234"
assert_eq "successful queue retry clears only the recovery marker" "false" \
  "$(jq -r 'has("maintainer_outcome_pending")' "$OUTCOME_RECOVERY_HOME/state/500099.json")"

echo '{"attempts":1,"acceptor":"reporter","run":{"evidence":{"pr_number":794,"review_verdict":"READY","ci_outcome":"pass"}}}' > "$CONCLUDE_HOME/state/500013.json"
CONCLUDE_REPORTER_PROPEN_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500013 pr-open "needs a human to widen expected_packages"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_not_contains "acceptor=reporter but outcome=pr-open (not done): does NOT close -- only merged closes" \
  "$CONCLUDE_REPORTER_PROPEN_OUT" "gh issue close"
assert_contains "...still gets the issue comment, not an email" \
  "$CONCLUDE_REPORTER_PROPEN_OUT" "gh issue comment 500013"
assert_contains "pr-open conclusion clears a stale in-progress label" \
  "$CONCLUDE_REPORTER_PROPEN_OUT" "--remove-label in-progress"
assert_not_contains "...the generic round-result mail is suppressed" \
  "$CONCLUDE_REPORTER_PROPEN_OUT" "跑完了一轮"

# --- conclude_run: outcome=duplicate (2026-09-16, run-advisor-batch.sh) ----
# A ticket the batch advisor rules a duplicate of a surviving ticket is an
# ORDINARY conclusion through this same terminal -- not a new terminal, not
# a park. Same evidence-required shape as `merged`/pr-open above
# (.run.evidence.duplicate_of, checked here, written by the caller before
# calling this), but closes UNCONDITIONALLY -- unlike `merged`, which only
# closes for acceptor in {none, reporter, maintainer} -- because the
# validation a `merged` outcome's acceptor logic exists for happens on the
# SURVIVING ticket, not this one; no acceptor field is set on 500014/500016
# below at all, and it still closes.
echo '{"attempts":0}' > "$CONCLUDE_HOME/state/500014.json"
CONCLUDE_DUP_REFUSE_NO_SURVIVOR_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500014 duplicate "reasoning here"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run refuses duplicate with no .run.evidence.duplicate_of recorded" \
  "$CONCLUDE_DUP_REFUSE_NO_SURVIVOR_OUT" "refusing outcome=duplicate"
assert_contains "...and returns 1" "$CONCLUDE_DUP_REFUSE_NO_SURVIVOR_OUT" "exit=1"

echo '{"attempts":0,"run":{"evidence":{"duplicate_of":1200}}}' > "$CONCLUDE_HOME/state/500015.json"
CONCLUDE_DUP_REFUSE_NO_NEEDS_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500015 duplicate ""
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run refuses duplicate with duplicate_of set but an empty needs_md" \
  "$CONCLUDE_DUP_REFUSE_NO_NEEDS_OUT" "exit=1"

echo '{"attempts":0,"run":{"evidence":{"duplicate_of":1200}}}' > "$CONCLUDE_HOME/state/500016.json"
CONCLUDE_DUP_OK_OUT="$(
  AGENT_HOME="$CONCLUDE_HOME" AGENT_DRY_RUN=1 REPO="test/repo" bash -c '
    source "$0/lib.sh"
    conclude_run 500016 duplicate "重复票，工作由 #1200 承担。"
    echo "exit=$?"
  ' "$SCRIPT_DIR" 2>&1
)"
assert_contains "conclude_run admits duplicate once duplicate_of and needs_md are both set" \
  "$CONCLUDE_DUP_OK_OUT" "exit=0"
assert_contains "...applies the concluded label" "$CONCLUDE_DUP_OK_OUT" "--add-label concluded"
assert_contains "...closes the issue -- no acceptor was set, and it still closes (unconditional, unlike merged)" \
  "$CONCLUDE_DUP_OK_OUT" "gh issue close 500016"
assert_contains "...the closing comment names the surviving ticket" "$CONCLUDE_DUP_OK_OUT" "#1200"
assert_contains "duplicate conclusion clears a stale in-progress label" \
  "$CONCLUDE_DUP_OK_OUT" "--remove-label in-progress"
assert_contains "duplicate conclusion keeps the duplicate label as close evidence" \
  "$CONCLUDE_DUP_OK_OUT" "--add-label duplicate"
assert_not_contains "duplicate conclusion does not strip its own duplicate label" \
  "$CONCLUDE_DUP_OK_OUT" "--remove-label duplicate"
assert_not_contains "...no email -- a duplicate closure is not a maintainer question and not a merge report" \
  "$CONCLUDE_DUP_OK_OUT" "send_email"

# --- conclusion/recut paths retire async advisor ownership ---------------
# Live state writes use no-op GitHub wrappers here. The clear helper below
# simulates a late async poll write; each terminal state transition must clear
# those fields again.
CLEAR_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$CLEAR_HOME/model-policy.json"
mkdir -p "$CLEAR_HOME/state"
for n in 510001 510002 510003 510004 510005 510006 510007; do
  jq -n --arg j "job-$n" \
    '{attempts:1,web_advisor_provider_job_id:$j,web_advisor_provider_job_started_at:1,web_advisor_provider_job_episode_seq:2}' \
    > "$CLEAR_HOME/state/$n.json"
done
jq -n --arg j job-510001 \
  '{attempts:1,web_advisor_provider_job_id:$j,web_advisor_provider_job_started_at:1,web_advisor_provider_job_episode_seq:2,run:{evidence:{pr_number:"1",pr_head_sha:"0123456789abcdef0123456789abcdef01234567",mandatory_checks:{status:"passed",head_sha:"0123456789abcdef0123456789abcdef01234567"}}}}' \
  > "$CLEAR_HOME/state/510001.json"
jq -n --arg j job-510002 \
  '{attempts:1,acceptor:"none",deploy_state:"deployed",deployed_sha:"sha",web_advisor_provider_job_id:$j,web_advisor_provider_job_started_at:1,web_advisor_provider_job_episode_seq:2,run:{outcome:"merged",evidence:{pr_number:"2",pr_head_sha:"0123456789abcdef0123456789abcdef01234567",mandatory_checks:{status:"passed",head_sha:"0123456789abcdef0123456789abcdef01234567"},real_user_path:"Feature surface: authenticated /chat/ photo attachment send URL: x Visible DOM: y Same-run network: z"}}}' \
  > "$CLEAR_HOME/state/510002.json"
jq -n --arg j job-510003 \
  '{attempts:1,web_advisor_provider_job_id:$j,web_advisor_provider_job_started_at:1,web_advisor_provider_job_episode_seq:2,run:{evidence:{pr_number:"3",review_verdict:"READY",ci_outcome:"pass"}}}' \
  > "$CLEAR_HOME/state/510003.json"
jq -n --arg j job-510004 \
  '{attempts:1,web_advisor_provider_job_id:$j,web_advisor_provider_job_started_at:1,web_advisor_provider_job_episode_seq:2,run:{evidence:{duplicate_of:1}}}' \
  > "$CLEAR_HOME/state/510004.json"
jq -n \
  '{attempts:1,run:{evidence:{pr_head_sha:"0123456789abcdef0123456789abcdef01234567",mandatory_checks:{status:"passed",head_sha:"0123456789abcdef0123456789abcdef01234567"}}}}' \
  > "$CLEAR_HOME/state/510005.json"
CLEAR_OUT="$(
  AGENT_HOME="$CLEAR_HOME" AGENT_DRY_RUN=0 REPO="test/repo" ZF_REPO="test/repo" bash -c '
    source "$0/lib.sh"
    roadmap_ensure_issue_parent() { :; }
  gh() {
    if [ "$1 ${2:-}" = "api repos/test/repo/pulls/795" ]; then
      printf "%s\n" '\''{"number":795,"merged":true,"base":{"ref":"main"},"merge_commit_sha":"main-sha","merged_at":"2026-11-04T19:54:15Z"}'\''
    elif [ "$1 ${2:-}" = "issue view" ]; then
      printf "%s\n" '\''{"state":"OPEN","labels":[],"comments":[]}'\''
    elif [ "$1" = api ] && [[ " $* " == *"/comments?"* ]]; then
      printf "%s\n" "[[]]"
    else
      return 0
      fi
    }
    guarded_write() { :; }
    guarded_issue_comment() { :; }
    notify_email() { :; }
    notify_email_everyone() { :; }
    label_transition_events() { :; }
    # Simulate an async poll racing after the early clear. Terminal writes
    # must remove the marker again in their final state transition.
    web_advisor_provider_clear_job_state() {
      state_merge "$1" ".web_advisor_provider_job_id = \"late-job\" | .web_advisor_provider_job_started_at = 1 | .web_advisor_provider_job_episode_seq = 9"
    }
    conclude_run 510001 merged "" || exit 1
    conclude_run 510002 deployed "proof" || exit 1
    conclude_run 510003 pr-open "blocked" || exit 1
    conclude_run 510004 duplicate "duplicate" || exit 1
    conclude_merged_run 510005 795 || exit 1
    route_to_recut 510006 || exit 1
    route_to_advisor 510007 || exit 1
    for n in 510001 510002 510003 510004 510005 510006 510007; do
      if jq -e ".web_advisor_provider_job_id? != null or .web_advisor_provider_job_started_at? != null or .web_advisor_provider_job_episode_seq? != null" "$STATE_DIR/$n.json" >/dev/null; then
        echo "$n=present"
      else
        echo "$n=clear"
      fi
    done
  ' "$SCRIPT_DIR"
)"
rm -rf "$CLEAR_HOME"
for n in 510001 510002 510003 510004 510005 510006 510007; do
  assert_contains "path $n clears web-advisor-provider job ownership" "$CLEAR_OUT" "$n=clear"
done
rm -rf "$CONCLUDE_HOME"


lib_case_exit
