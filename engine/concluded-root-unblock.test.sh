#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# This suite checks issue recovery, not roadmap placement.
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$AGENT_HOME/model-policy.json"
source "$SCRIPT_DIR/lib.sh"
TEST_HOME="$AGENT_HOME"
trap 'rm -rf -- "$TEST_HOME"' EXIT

FAILED=0
assert_contains() {
  local desc="$1" value="$2" expected="$3"
  if [[ "$value" == *"$expected"* ]]; then echo "ok - $desc"
  else echo "not ok - $desc (missing [$expected])"; FAILED=1; fi
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "ok - $desc"
  else echo "not ok - $desc (expected [$expected], got [$actual])"; FAILED=1; fi
}
infra_requeue_comment_count() {
  grep -cF '<!-- vecta-conclusion-requeue issue=500050 episode=' "$ROOT_WRITE_LOG" || true
}
assert_not_contains() {
  local desc="$1" value="$2" unexpected="$3"
  if [[ "$value" != *"$unexpected"* ]]; then echo "ok - $desc"
  else echo "not ok - $desc (unexpected [$unexpected])"; FAILED=1; fi
}

mkdir -p "$STATE_DIR"
cat > "$TEST_HOME/blocking-root.json" <<'EOF'
{"number":500004,"state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[{"number":500014,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500004.json" <<'EOF'
{"state":"concluded","attempts":4,"risk_class":"P2","level":"L3","review_verdict":"NOT_READY","run":{"outcome":"not-completed","concluded_at":"2026-09-27T09:00:00Z","needs_md":"Code review verdict stayed NOT_READY after one repair pass"}}
EOF

export ROOT_WRITE_LOG="$TEST_HOME/writes.log"
: > "$ROOT_WRITE_LOG"
guarded_write() {
  printf '%s\n' "$*" >> "$ROOT_WRITE_LOG"
  local previous="" arg
  for arg in "$@"; do
    if [ "$previous" = "--body-file" ]; then
      cat "$arg" >> "$ROOT_WRITE_LOG"
      printf '\n' >> "$ROOT_WRITE_LOG"
      break
    fi
    previous="$arg"
  done
  if [ "${1:-}" = gh ] && [ "${2:-}" = issue ] && [ "${3:-}" = create ]; then
    printf '%s\n' "https://github.com/test/repo/issues/500030"
  fi
}
gh() {
  printf '%s\n' "$*" >> "$TEST_HOME/gh-calls.log"
  # Native sub-issue reads (issue 2046): these fixtures have none.
  if [ "${1:-}" = api ] && [[ "${2:-}" == */sub_issues\?per_page=100 ]]; then
    # The #2511/#2520 shape (2026-10-08 07:37-07:38Z): a transient gh api
    # failure whose stderr the old call site discarded.
    if [ -n "${SUBISSUES_API_FAIL:-}" ]; then
      echo 'gh: HTTP 403: secondary rate limit exceeded (fake)' >&2
      return 1
    fi
    if [ -n "${NATIVE_DUPLICATE_PARENT:-}" ] && [[ "$2" == */issues/$NATIVE_DUPLICATE_PARENT/* ]]; then
      printf '[{"number":500058,"state":"closed","closed_at":"2026-10-04T09:23:51Z","labels":[{"name":"duplicate"}]}]\n'
      return 0
    fi
    printf '[]\n'
    return 0
  fi
  if [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
    if [[ " $* " == *" --json number,title,state,labels,author,blockedBy,blocking "* ]]; then
      printf '%s\n' "${BLOCKER_GRAPH_JSON:-[]}"
    else
      printf '%s\n' "${PREREQUISITE_ISSUES_JSON:-[]}"
    fi
  elif [ "${1:-}" = issue ] && [ "${2:-}" = view ]; then
    if [[ " $* " == *" --json state "* ]]; then
      if [[ " ${CLOSED_CHILD_IDS:-} " == *" $3 "* ]]; then echo CLOSED; else echo OPEN; fi
      return 0
    fi
    if [[ " $* " == *" --json state,labels "* ]]; then
      if [ "$3" = 500053 ] || [ "$3" = 500054 ]; then
        printf '{"state":"OPEN","labels":[{"name":"concluded"},{"name":"pipeline-system"}]}\n'
      else
        printf '{"state":"OPEN","labels":[{"name":"concluded"}]}\n'
      fi
      return 0
    fi
    if [[ " $* " == *" --json closedAt,labels "* ]]; then
      jq -cn --arg n "$3" --argjson meta "${CLOSED_CHILD_META:-null}" \
        '($meta // {})[$n] // {closedAt:"2026-01-01T00:00:00Z",labels:[]}'
      return 0
    fi
    if [[ " $* " == *" --json number,labels "* ]]; then
      if [ "$3" = 500051 ] || [ "$3" = 500052 ] || [ "$3" = 500053 ] || [ "$3" = 500054 ]; then
        printf '{"number":%s,"labels":[{"name":"concluded"},{"name":"pipeline-system"}]}\n' "$3"
        return 0
      fi
      printf '{"number":%s,"labels":[{"name":"concluded"}]}\n' "${3:-0}"
    elif [ -n "${ISSUE_COMMENTS_JSON:-}" ]; then
      printf '%s\n' "$ISSUE_COMMENTS_JSON"
    else
      printf '%s\n' '{"comments":[]}'
    fi
  else
    return 64
  fi
}
guarded_issue_comment() { printf 'comment:%s\n%s\n' "$1" "$2" >> "$ROOT_WRITE_LOG"; }
notify_reporter_question() { printf 'thread-500005\n'; }
author_is_maintainer() { [ "$1" = maintainer ]; }
if declare -F reconcile_blocking_issue_root >/dev/null; then
  reconcile_blocking_issue_root "$(cat "$TEST_HOME/blocking-root.json")" '[]'
else
  echo "not ok - reconcile_blocking_issue_root exists"
  FAILED=1
fi
assert_contains "review loop exits concluded and enters recut queue" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label needs-recut"
assert_eq "one automatic exit is recorded" 1 \
  "$(jq -r '.concluded_blocker_recovery.auto_exits // 0' "$STATE_DIR/500004.json")"
assert_eq "first recovery resets exhausted attempt budget" 0 \
  "$(jq -r '.attempts' "$STATE_DIR/500004.json")"
assert_eq "first recovery records prior attempt count" 4 \
  "$(jq -r '.concluded_blocker_recovery.attempts_reset.from' "$STATE_DIR/500004.json")"
assert_eq "recorded action is needs-recut" needs-recut \
  "$(jq -r '.concluded_blocker_recovery.last_action // empty' "$STATE_DIR/500004.json")"

# A production-access recut refusal is held by the hot-fix supervisor. Holds
# owned outside conclusion recovery are skipped, so this root cannot requeue.
cat > "$TEST_HOME/production-access-held-root.json" <<'EOF'
{"number":500054,"state":"OPEN","labels":[{"name":"concluded"},{"name":"on-hold"},{"name":"hotfix"}],"blocking":{"nodes":[{"number":500064,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500054.json" <<'EOF'
{"state":"on-hold","attempts":4,"recut_refused_at":"2026-10-04T00:00:00Z","recut_refused_reason":"需要访问生产主机","recut_needs_production_access":true,"hold":{"holder":"hot-fix supervisor","kind":"hotfix-lane","release_condition":"需要访问生产主机"},"run":{"outcome":"not-completed","concluded_at":"2026-10-04T00:00:00Z","needs_md":"Implement dispatch reached its 4-attempt cap"}}
EOF
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/production-access-held-root.json")" '[]'
assert_eq "production-access refusal hold prevents blocker-root requeue" "" \
  "$(cat "$ROOT_WRITE_LOG")"
assert_eq "production-access refusal hold records no recovery action" false \
  "$(jq 'has("concluded_blocker_recovery")' "$STATE_DIR/500054.json")"

cat > "$TEST_HOME/retry-advisor-route.json" <<'EOF'
{"number":500010,"state":"OPEN","labels":[{"name":"concluded"}],"author":{"login":"maintainer"},"blocking":{"nodes":[{"number":500020,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500010.json" <<'EOF'
{"state":"concluded","attempts":4,"concluded_blocker_recovery":{"auto_exits":1,"last_episode":"2026-09-23T19:28:53Z","last_action":"needs-advisor"},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T10:56:18Z","needs_md":"No further advisor episode was admitted after 4 attempts"}}
EOF
: > "$ROOT_WRITE_LOG"
ROUTE_TO_ADVISOR_CALLS=0
ROUTE_TO_ADVISOR_FORCE=""
# The pipeline-system risk-class case runs the real router: a stub here hid that the census
# undid the advisor route every tick (1819, 2026-10-04).
REAL_ROUTE_TO_ADVISOR="$(declare -f route_to_advisor)"
route_to_advisor() {
  local n="$1" remove_label="${2:-ready-for-agent}"
  ROUTE_TO_ADVISOR_CALLS=$((ROUTE_TO_ADVISOR_CALLS + 1))
  ROUTE_TO_ADVISOR_FORCE="${3:-false}"
  state_merge "$n" '.state = "needs-advisor"' || return 1
  guarded_write gh issue edit "$n" --repo "$REPO" --remove-label "$remove_label" --add-label needs-advisor
}
STUB_ROUTE_TO_ADVISOR="$(declare -f route_to_advisor)"
QUESTION_SEND_LOG="$TEST_HOME/question-sends.log"
: > "$QUESTION_SEND_LOG"
notify_reporter_question() {
  printf '%s\n' "$1" >> "$QUESTION_SEND_LOG"
  return 1
}
reconcile_blocking_issue_root "$(cat "$TEST_HOME/retry-advisor-route.json")" '[]'
assert_contains "failed advisor admission removes concluded label" \
  "$(cat "$ROOT_WRITE_LOG")" "--remove-label concluded"
assert_contains "undeliverable maintainer question routes to advisor" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label needs-advisor"
assert_not_contains "undeliverable maintainer question never adds needs-info" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label needs-info"
assert_eq "undeliverable question opens one advisor route" 1 "$ROUTE_TO_ADVISOR_CALLS"
assert_eq "undeliverable question forces advisor batch route" true "$ROUTE_TO_ADVISOR_FORCE"
assert_eq "retry of unlanded advisor route keeps the one-exit cap" 1 \
  "$(jq -r '.concluded_blocker_recovery.auto_exits' "$STATE_DIR/500010.json")"
assert_eq "undeliverable question records advisor route" needs-advisor \
  "$(jq -r '.concluded_blocker_recovery.last_action' "$STATE_DIR/500010.json")"
assert_eq "undelivered question records its conclusion episode" 2026-09-27T10:56:18Z \
  "$(jq -r '.concluded_blocker_recovery.question_delivery_failed_episode' "$STATE_DIR/500010.json")"
ADVISOR_ROOT_AFTER_FAILURE="$(jq '.labels = [{"name":"needs-advisor"}]' "$TEST_HOME/retry-advisor-route.json")"
reconcile_blocking_issue_root "$ADVISOR_ROOT_AFTER_FAILURE" '[]'
assert_eq "same-episode rejection is not sent again after advisor handoff" 1 \
  "$(grep -c '^500010$' "$QUESTION_SEND_LOG" || true)"
assert_eq "same-episode rejection does not reopen needs-info" 0 \
  "$(grep -c -- '--add-label needs-info' "$ROOT_WRITE_LOG" || true)"

cat > "$TEST_HOME/restore-needs-info-route.json" <<'EOF'
{"number":500012,"state":"OPEN","labels":[{"name":"needs-advisor"}],"author":{"login":"maintainer"},"blocking":{"nodes":[{"number":500022,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500012.json" <<'EOF'
{"state":"needs-advisor","attempts":2,"concluded_blocker_recovery":{"auto_exits":1,"last_episode":"2026-09-27T09:00:35Z","last_action":"needs-advisor","question_delivery_failed_episode":"2026-09-27T09:00:35Z"},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T09:00:35Z","needs_md":"Product decision required for P2/L4 path"}}
EOF
: > "$ROOT_WRITE_LOG"
: > "$QUESTION_SEND_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/restore-needs-info-route.json")" '[]'
assert_not_contains "undelivered follow-up stays out of needs-info" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label needs-info"
assert_not_contains "ticket already in advisor queue is not routed a second time" \
  "$(cat "$ROOT_WRITE_LOG")" "gh issue edit"
assert_eq "advisor correction keeps the one-exit cap" 1 \
  "$(jq -r '.concluded_blocker_recovery.auto_exits' "$STATE_DIR/500012.json")"
assert_eq "undelivered advisor follow-up remains needs-advisor" needs-advisor \
  "$(jq -r '.state' "$STATE_DIR/500012.json")"
assert_eq "advisor correction marker stays needs-advisor" needs-advisor \
  "$(jq -r '.concluded_blocker_recovery.last_action' "$STATE_DIR/500012.json")"
assert_eq "same-episode follow-up rejection is not retried" 0 \
  "$(grep -c '^500012$' "$QUESTION_SEND_LOG" || true)"

notify_reporter_question() { printf 'thread-500005\n'; }

cat > "$TEST_HOME/reclassify-recut-root.json" <<'EOF'
{"number":500011,"state":"OPEN","labels":[{"name":"needs-recut"}],"author":{"login":"maintainer"},"blocking":{"nodes":[{"number":500021,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500011.json" <<'EOF'
{"state":"needs-recut","attempts":3,"review_verdict":"NOT_READY","concluded_blocker_recovery":{"auto_exits":1,"last_episode":"2026-09-27T09:00:40Z","last_action":"needs-recut"},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T09:00:40Z","needs_md":"Configured model escalation exhausted: Code review verdict stayed INPUT_INCOMPLETE after one repair pass"},"model_policy":{"failure":{"reason":"Code review verdict stayed INPUT_INCOMPLETE after one repair pass"}}}
EOF
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/reclassify-recut-root.json")" '[]'
assert_contains "INPUT_INCOMPLETE underscore corrects prior needs-recut route to needs-info" \
  "$(cat "$ROOT_WRITE_LOG")" "--remove-label needs-recut"
assert_contains "INPUT_INCOMPLETE correction adds needs-info" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label needs-info"
assert_eq "classification correction keeps auto-exit count at one" 1 \
  "$(jq -r '.concluded_blocker_recovery.auto_exits' "$STATE_DIR/500011.json")"
assert_eq "corrected action is needs-info" needs-info \
  "$(jq -r '.concluded_blocker_recovery.last_action' "$STATE_DIR/500011.json")"

cat > "$TEST_HOME/infra-root.json" <<'EOF'
{"number":500005,"state":"OPEN","labels":[{"name":"concluded"}],"author":{"login":"reporter"},"blocking":{"nodes":[{"number":500015,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500005.json" <<'EOF'
{"state":"concluded","attempts":4,"run":{"outcome":"not-completed","concluded_at":"2026-09-27T09:01:00Z","needs_md":"Previous model unit ended without recording a result; treating it as stalled"},"model_policy":{"failures":[{"reason":"Previous model unit ended without recording a result; treating it as stalled","recorded_at":"2026-09-27T08:59:00Z"}]}}
EOF
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/infra-root.json")" '[]'
assert_contains "missing systemd result is held as a pipeline defect" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label on-hold"
assert_eq "silent resume gets pipeline-defect class" pipeline-defect \
  "$(jq -r '.run.conclusion.class' "$STATE_DIR/500005.json")"
assert_eq "silent resume gets deterministic requeue route" requeue \
  "$(jq -r '.run.conclusion.route' "$STATE_DIR/500005.json")"
assert_eq "pipeline defect is owned by the supervisor inbox" supervisor-inbox \
  "$(jq -r '.run.conclusion.owner' "$STATE_DIR/500005.json")"
assert_eq "pipeline defect emits one inbox signature" 1 \
  "$(grep -c 'conclusion-pipeline-defect signature=unit-result-not-recorded' "$AGENT_HOME/supervisor-inbox")"
assert_eq "pipeline defect does not consume ticket attempts" 4 \
  "$(jq -r '.attempts' "$STATE_DIR/500005.json")"

cat > "$TEST_HOME/pipeline-delivery-root.json" <<'EOF'
{"number":500051,"state":"OPEN","labels":[{"name":"concluded"},{"name":"pipeline-system"}],"author":{"login":"reporter"},"blocking":{"nodes":[]}}
EOF
cat > "$STATE_DIR/500051.json" <<'EOF'
{"state":"concluded","attempts":1,"pipeline_system":{"enabled":true},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T09:02:00Z","needs_md":"pipeline-system delivery failed","conclusion":{"class":"pipeline-defect","route":"requeue","owner":"supervisor-inbox","signature":"pipeline-system-delivery-failed","reason":"pipeline-system delivery failed"}}}
EOF
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/pipeline-delivery-root.json")" '[]'
assert_contains "pipeline-system delivery defect takes existing hold path" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label on-hold"
assert_eq "pipeline-system delivery defect ends on hold" on-hold \
  "$(jq -r '.state' "$STATE_DIR/500051.json")"
assert_eq "pipeline-system delivery defect keeps supervisor ownership" supervisor-inbox \
  "$(jq -r '.run.conclusion.owner' "$STATE_DIR/500051.json")"
assert_eq "pipeline-system delivery defect preserves its signature" pipeline-system-delivery-failed \
  "$(jq -r '.run.conclusion.signature' "$STATE_DIR/500051.json")"
assert_eq "pipeline-system delivery defect emits one inbox line" 1 \
  "$(grep -c 'conclusion-pipeline-defect signature=pipeline-system-delivery-failed' "$AGENT_HOME/supervisor-inbox")"
assert_eq "pipeline-system delivery defect does not consume ticket attempts" 1 \
  "$(jq -r '.attempts' "$STATE_DIR/500051.json")"

cat > "$TEST_HOME/pipeline-delivery-ticket-guard.json" <<'EOF'
{"number":500052,"state":"OPEN","labels":[{"name":"concluded"},{"name":"pipeline-system"}],"author":{"login":"reporter"},"blocking":{"nodes":[]}}
EOF
cat > "$STATE_DIR/500052.json" <<'EOF'
{"state":"concluded","attempts":1,"pipeline_system":{"enabled":true},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T09:03:00Z","needs_md":"product decision required","conclusion":{"class":"ticket","route":"needs-info","owner":"reporter","signature":"pipeline-system-delivery-failed","reason":"product decision required"}}}
EOF
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/pipeline-delivery-ticket-guard.json")" '[]'
assert_eq "pipeline-system delivery signature survives ticket override guard" pipeline-system-delivery-failed \
  "$(jq -r '.run.conclusion.signature' "$STATE_DIR/500052.json")"
assert_not_contains "pipeline-system delivery signature does not become forced requeue" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label ready-for-agent"

cat > "$TEST_HOME/pipeline-risk-class-root.json" <<'EOF'
{"number":500053,"state":"OPEN","labels":[{"name":"concluded"},{"name":"pipeline-system"}],"author":{"login":"reporter"},"blocking":{"nodes":[]}}
EOF
cat > "$STATE_DIR/500053.json" <<'EOF'
{"state":"concluded","attempts":4,"pipeline_system":{"enabled":true},"model_policy":{"unit":"implement","step":"conclude","failure":{"unit":"implement","step":"work_retry","transition":"conclude","stage":"risk-class","status":1,"reason":"Implementation touched a P2/L4 path for issue #500053","early_stop":{"reason":"same-failure","stage":"risk-class","decision":"conclude","advisor_seen":false}}},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T09:04:00Z","needs_md":"Stopped after repeated risk-class refusal","conclusion":{"class":"ticket","route":"requeue","owner":"issue-pipeline","signature":"pipeline-system-requeue","reason":"Implementation touched a P2/L4 path for issue #500053"}}}
EOF
: > "$ROOT_WRITE_LOG"
eval "$REAL_ROUTE_TO_ADVISOR"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/pipeline-risk-class-root.json")" '[]'
eval "$STUB_ROUTE_TO_ADVISOR"
assert_eq "pipeline-system risk-class refusal is held, not sent to an advisor lane it cannot use" on-hold \
  "$(jq -r '.state' "$STATE_DIR/500053.json")"
assert_eq "risk-class hold is owned by the supervisor" pipeline-system-risk-class \
  "$(jq -r '.hold.kind' "$STATE_DIR/500053.json")"
assert_eq "risk-class hold leaves the model-policy ladder off the advisor step the census resets" conclude \
  "$(jq -r '.model_policy.step' "$STATE_DIR/500053.json")"
assert_eq "risk-class refusal stage remains recorded" risk-class \
  "$(jq -r '.model_policy.failure.stage' "$STATE_DIR/500053.json")"
assert_eq "risk-class refusal reason remains intact" \
  "Implementation touched a P2/L4 path for issue #500053" \
  "$(jq -r '.model_policy.failure.reason' "$STATE_DIR/500053.json")"
assert_eq "risk-class escalation keeps its refusal signature" risk-class-refusal \
  "$(jq -r '.run.conclusion.signature' "$STATE_DIR/500053.json")"
assert_eq "risk-class escalation records supervisor ownership" supervisor \
  "$(jq -r '.run.conclusion.owner' "$STATE_DIR/500053.json")"
assert_contains "risk-class refusal is labeled on-hold" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label on-hold"
assert_not_contains "risk-class refusal is not labeled for the advisor" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label needs-advisor"
assert_not_contains "risk-class refusal is not plainly requeued" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label ready-for-agent"
assert_contains "risk-class hold wakes the supervisor" \
  "$(cat "$AGENT_HOME/supervisor-inbox")" "pipeline-system issue 500053 held for supervisor"

cat > "$TEST_HOME/pipeline-ordinary-conclusion.json" <<'EOF'
{"number":500054,"state":"OPEN","labels":[{"name":"concluded"},{"name":"pipeline-system"}],"author":{"login":"reporter"},"blocking":{"nodes":[]}}
EOF
cat > "$STATE_DIR/500054.json" <<'EOF'
{"state":"concluded","attempts":1,"pipeline_system":{"enabled":true},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T09:05:00Z","needs_md":"Ordinary implementation failure","conclusion":{"class":"ticket","route":"needs-info","owner":"reporter","signature":"ticket-code-or-scope-failure","reason":"Ordinary implementation failure"}}}
EOF
# This fixture owns unit state; CI runners may have systemctl without a user bus.
stage_unit_active() { return 1; }
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/pipeline-ordinary-conclusion.json")" '[]'
assert_eq "non-risk pipeline-system conclusion still uses plain requeue" pipeline-system-requeue \
  "$(jq -r '.run.conclusion.signature' "$STATE_DIR/500054.json")"
assert_eq "non-risk pipeline-system conclusion returns to ready-for-agent" ready-for-agent \
  "$(jq -r '.state' "$STATE_DIR/500054.json")"

cat > "$TEST_HOME/infra-wait.json" <<'EOF'
{"number":500050,"state":"OPEN","labels":[{"name":"concluded"}],"author":{"login":"reporter"},"blocking":{"nodes":[]}}
EOF
INFRA_FAULT_NOW="$(date +%s)"
INFRA_FAULT_STARTED="$(date -u -d "@$((INFRA_FAULT_NOW - 30))" +%Y-%m-%dT%H:%M:%SZ)"
cat > "$STATE_DIR/500050.json" <<EOF
{"state":"concluded","attempts":3,"run":{"outcome":"not-completed","implement_started_at":"$INFRA_FAULT_STARTED","concluded_at":"$INFRA_FAULT_STARTED","needs_md":"Docker precondition is missing"}}
EOF
mkdir -p "$ENV_FAULT_DIR"
printf '%s\timplement@packages/example\t500050\tenv:test-gate:docker\tDocker precondition is missing\n' \
  "$INFRA_FAULT_NOW" > "$ENV_FAULT_DIR/env_test_gate_docker.log"
INFRA_GATE_BLOCKED=1
stage_dispatch_allowed() { return 0; }
quarantine_decision() { [ "$INFRA_GATE_BLOCKED" = 1 ] && echo open || echo clear; }
quarantine_mark_canary() { :; }
: > "$ROOT_WRITE_LOG"
BLOCKER_GRAPH_JSON="$(jq -n '[{number:500050,state:"OPEN",labels:[{name:"concluded"}],author:{login:"reporter"},blocking:{nodes:[]}}]')"
sweep_blocking_issue_roots
assert_eq "recorded environment fault keeps its infrastructure class while blocked" infrastructure \
  "$(jq -r '.run.conclusion.class' "$STATE_DIR/500050.json")"
assert_eq "infrastructure owner retains matching quarantine scope" implement@packages/example \
  "$(jq -r '.run.conclusion.scope' "$STATE_DIR/500050.json")"
assert_eq "infrastructure waits in owned on-hold state" on-hold \
  "$(jq -r '.state' "$STATE_DIR/500050.json")"
assert_eq "infrastructure wait does not post requeue comment early" 0 \
  "$(infra_requeue_comment_count)"
assert_eq "infrastructure wait preserves remaining attempts" 3 \
  "$(jq -r '.attempts' "$STATE_DIR/500050.json")"

cat > "$TEST_HOME/infra-wait-retry.json" <<'EOF'
{"number":500050,"state":"OPEN","labels":[{"name":"on-hold"}],"author":{"login":"reporter"},"blocking":{"nodes":[]}}
EOF
INFRA_GATE_BLOCKED=0
BLOCKER_GRAPH_JSON="$(jq -n '[{number:500050,state:"OPEN",labels:[{name:"on-hold"}],author:{login:"reporter"},blocking:{nodes:[]}}]')"
sweep_blocking_issue_roots
assert_eq "cleared infrastructure precondition requeues the ticket" ready-for-agent \
  "$(jq -r '.state' "$STATE_DIR/500050.json")"
assert_eq "requeue resets the charged attempt budget" 0 \
  "$(jq -r '.attempts' "$STATE_DIR/500050.json")"
assert_eq "requeue comment is posted once after the precondition clears" 1 \
  "$(infra_requeue_comment_count)"
assert_contains "requeue comment names the recorded infrastructure reason" \
  "$(cat "$ROOT_WRITE_LOG")" "Docker precondition is missing"
assert_eq "successful requeue changes owner to implement queue" implement \
  "$(jq -r '.run.conclusion.owner' "$STATE_DIR/500050.json")"
assert_contains "conclusion hold is released in the requeue write" \
  "$(grep -F -- '--add-label ready-for-agent' "$ROOT_WRITE_LOG")" "--remove-label on-hold"
assert_eq "released conclusion hold clears its record" null "$(jq -c '.hold' "$STATE_DIR/500050.json")"
INFRA_REQUEUE_EPISODE="$(jq -r '.run.concluded_at' "$STATE_DIR/500050.json")"
INFRA_REQUEUE_MARKER="<!-- vecta-conclusion-requeue issue=500050 episode=$INFRA_REQUEUE_EPISODE -->"
ISSUE_COMMENTS_JSON="$(jq -cn --arg marker "$INFRA_REQUEUE_MARKER" '{comments:[{body:$marker}]}')"
conclusion_requeue_comment_once 500050
assert_eq "replayed requeue receipt does not duplicate the infrastructure comment" 1 \
  "$(infra_requeue_comment_count)"
ISSUE_COMMENTS_JSON='{"comments":"malformed"}'
if conclusion_requeue_comment_once 500050; then
  echo "not ok - malformed comment read is not treated as a missing marker"
  FAILED=1
else
  echo "ok - malformed comment read fails closed before duplicate comment"
fi
assert_eq "malformed comment read does not write a second comment" 1 \
  "$(infra_requeue_comment_count)"

# A hold the conclusion path does not own is left to its holder, even with a requeue
# conclusion: requeueing it was suppressed by the hold guard and repeated every tick.
cat > "$STATE_DIR/500070.json" <<'EOF'
{"state":"on-hold","attempts":2,"hold":{"kind":"manual","holder":"supervisor","release_condition":"fixture","expires_at":"2099-01-01T00:00:00Z"},"run":{"outcome":"not-completed","conclusion":{"class":"ticket","route":"requeue","owner":"implement"}},"model_policy":{"unit":"implement","step":"work","history":[]}}
EOF
cp "$STATE_DIR/500070.json" "$TEST_HOME/500070-before.json"
: > "$ROOT_WRITE_LOG"
BLOCKER_GRAPH_JSON="$(jq -n '[{number:500070,state:"OPEN",labels:[{name:"on-hold"}],author:{login:"reporter"},blocking:{nodes:[]}}]')"
sweep_blocking_issue_roots
assert_eq "manual hold with a requeue conclusion gets no writes" "" "$(cat "$ROOT_WRITE_LOG")"
assert_eq "manual hold with a requeue conclusion keeps its state" \
  "$(jq -S -c '{state,attempts,hold,model_policy}' "$TEST_HOME/500070-before.json")" \
  "$(jq -S -c '{state,attempts,hold,model_policy}' "$STATE_DIR/500070.json")"

# A root with open dependents is classified from the labels the sweep just read, not a re-read.
cat > "$STATE_DIR/500071.json" <<'EOF'
{"state":"ready-for-agent","attempts":0}
EOF
: > "$TEST_HOME/gh-calls.log"
BLOCKER_GRAPH_JSON="$(jq -n '[{number:500071,state:"OPEN",labels:[{name:"ready-for-agent"}],author:{login:"reporter"},blocking:{nodes:[{number:500072,state:"OPEN"}]}},{number:500072,state:"OPEN",labels:[{name:"ready-for-agent"}],author:{login:"reporter"},blocking:{nodes:[]}}]')"
sweep_blocking_issue_roots
assert_eq "dependent root is not re-read for its lane labels" 0 \
  "$(grep -c 'issue view 500071 .*--json number,labels' "$TEST_HOME/gh-calls.log" || true)"
unset -f stage_unit_active stage_dispatch_allowed quarantine_decision quarantine_mark_canary

cat > "$TEST_HOME/legacy-merged.json" <<'EOF'
{"number":500060,"state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[]}}
EOF
cat > "$STATE_DIR/500060.json" <<'EOF'
{"state":"concluded","run":{"outcome":"merged","concluded_at":"2026-09-27T09:00:00Z","evidence":{"pr_number":"600"}}}
EOF
reconcile_blocking_issue_root "$(cat "$TEST_HOME/legacy-merged.json")" '[]'
assert_eq "legacy merged conclusion returns to release owner" awaiting-release \
  "$(jq -r '.state' "$STATE_DIR/500060.json")"
assert_eq "legacy merged route is explicit" awaiting-release \
  "$(jq -r '.run.conclusion.route' "$STATE_DIR/500060.json")"

cat > "$TEST_HOME/legacy-no-outcome.json" <<'EOF'
{"number":500061,"state":"OPEN","labels":[{"name":"concluded"}],"author":{"login":"reporter"},"blocking":{"nodes":[]}}
EOF
cat > "$STATE_DIR/500061.json" <<'EOF'
{"state":"concluded","run":{"concluded_at":"2026-09-27T09:00:00Z"}}
EOF
reconcile_blocking_issue_root "$(cat "$TEST_HOME/legacy-no-outcome.json")" '[]'
assert_eq "legacy missing outcome is recorded as inferred incomplete" true \
  "$(jq -r '.run.outcome_inferred' "$STATE_DIR/500061.json")"
assert_eq "legacy missing outcome asks reporter for information" needs-info \
  "$(jq -r '.state' "$STATE_DIR/500061.json")"
assert_eq "legacy missing outcome has deterministic ticket route" needs-info \
  "$(jq -r '.run.conclusion.route' "$STATE_DIR/500061.json")"

cat > "$TEST_HOME/not-planned.json" <<'EOF'
{"number":500062,"state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[]}}
EOF
cat > "$STATE_DIR/500062.json" <<'EOF'
{"state":"concluded","run":{"outcome":"not-completed","disposition":"not-planned","concluded_at":"2026-09-27T09:00:00Z","needs_md":"The requested behavior is explicitly out of scope."}}
EOF
reconcile_blocking_issue_root "$(cat "$TEST_HOME/not-planned.json")" '[]'
assert_eq "explicit not-planned decision closes with reason" wontfix \
  "$(jq -r '.state' "$STATE_DIR/500062.json")"
assert_eq "not-planned route is persisted" close-not-planned \
  "$(jq -r '.run.conclusion.route' "$STATE_DIR/500062.json")"
assert_contains "not-planned issue is closed in GitHub" \
  "$(cat "$ROOT_WRITE_LOG")" "issue close 500062"

cat > "$TEST_HOME/newest-failure-root.json" <<'EOF'
{"number":500009,"state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[{"number":500019,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500009.json" <<'EOF'
{"state":"concluded","risk_class":"P2","level":"L3","run":{"outcome":"not-completed","concluded_at":"2026-09-27T09:01:30Z","needs_md":"Implement dispatch reached its 4-attempt cap"},"model_policy":{"failures":[{"reason":"Previous model unit ended without recording a result","recorded_at":"2026-09-27T08:00:00Z"},{"reason":"Package test failed after repair","recorded_at":"2026-09-27T08:59:00Z"}]}}
EOF
reconcile_blocking_issue_root "$(cat "$TEST_HOME/newest-failure-root.json")" '[]'
assert_contains "latest real code failure is not refunded because older record was infrastructure" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label needs-recut"
assert_eq "latest real code failure routes to recut" needs-recut \
  "$(jq -r '.concluded_blocker_recovery.last_action' "$STATE_DIR/500009.json")"

cat > "$TEST_HOME/missing-prerequisite-root.json" <<'EOF'
{"number":500013,"title":"Learning events root","state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[{"number":500023,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500013.json" <<'EOF'
{"state":"concluded","attempts":4,"recut_refused_at":"2026-09-27T11:08:46Z","recut_refused_reason":"未找到学习事件与来源组的持久化实现","concluded_blocker_recovery":{"auto_exits":1,"last_episode":"2026-09-25T18:05:47Z","last_action":"needs-recut"},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T11:12:00Z","needs_md":"Implement dispatch reached its 4-attempt cap"}}
EOF
: > "$ROOT_WRITE_LOG"
PREREQUISITE_ISSUES_JSON='[]'
reconcile_blocking_issue_root "$(cat "$TEST_HOME/missing-prerequisite-root.json")" '[]'
assert_contains "missing prerequisite creates a child issue" \
  "$(cat "$ROOT_WRITE_LOG")" "concluded-root-prerequisite-500013"
assert_contains "parent records prerequisite as a blocking edge" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-blocked-by 500030"
assert_contains "parent returns to ready queue behind prerequisite" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label ready-for-agent"
assert_eq "new conclusion episode resets attempt budget" 0 \
  "$(jq -r '.attempts' "$STATE_DIR/500013.json")"
assert_eq "attempt reset keeps prior count for audit" 4 \
  "$(jq -r '.concluded_blocker_recovery.attempts_reset.from' "$STATE_DIR/500013.json")"
assert_eq "attempt reset records missing prerequisite reason" missing-prerequisite \
  "$(jq -r '.concluded_blocker_recovery.attempts_reset.reason_class' "$STATE_DIR/500013.json")"
assert_eq "created prerequisite id is persisted" 500030 \
  "$(jq -r '.concluded_blocker_recovery.prerequisite_issue' "$STATE_DIR/500013.json")"
assert_eq "new conclusion episode gets one fresh recovery exit" 2 \
  "$(jq -r '.concluded_blocker_recovery.auto_exits' "$STATE_DIR/500013.json")"

cat > "$TEST_HOME/duplicate-prerequisite-root.json" <<'EOF'
{"number":500070,"title":"Learning events root","state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[{"number":500080,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500070.json" <<'EOF'
{"state":"concluded","attempts":4,"recut_refused_at":"2026-09-27T11:08:46Z","recut_refused_reason":"未找到学习事件与来源组的持久化实现","concluded_blocker_recovery":{"auto_exits":1,"last_episode":"2026-09-25T18:05:47Z","last_action":"needs-recut"},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T11:12:01Z","needs_md":"Implement dispatch reached its 4-attempt cap"}}
EOF
PREREQUISITE_ISSUES_JSON='[{"number":500031,"title":"前置能力 [concluded-root-prerequisite-500070]: Learning events root","state":"CLOSED","stateReason":"COMPLETED","labels":[{"name":"duplicate"},{"name":"concluded"}]}]'
notify_reporter_question() { printf 'thread-500070\n'; }
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/duplicate-prerequisite-root.json")" '[]'
assert_contains "duplicate prerequisite routes parent to needs-info" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label needs-info"
assert_not_contains "duplicate prerequisite does not requeue parent" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label ready-for-agent"
assert_not_contains "duplicate prerequisite does not create another prerequisite" \
  "$(cat "$ROOT_WRITE_LOG")" "issue create"
assert_eq "duplicate prerequisite records unresolved-recut" unresolved-recut \
  "$(jq -r '.concluded_blocker_recovery.attempts_reset.reason_class' "$STATE_DIR/500070.json")"
assert_eq "duplicate prerequisite asks reporter for information" thread-500070 \
  "$(jq -r '.needs_info_thread_id' "$STATE_DIR/500070.json")"
assert_contains "prerequisite lookup requests closure evidence" \
  "$(cat "$TEST_HOME/gh-calls.log")" "--json number,title,body,state,labels,stateReason"

cat > "$TEST_HOME/not-planned-prerequisite-root.json" <<'EOF'
{"number":500073,"title":"Learning events root","state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[{"number":500083,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500073.json" <<'EOF'
{"state":"concluded","attempts":4,"recut_refused_at":"2026-09-27T11:08:46Z","recut_refused_reason":"未找到学习事件与来源组的持久化实现","concluded_blocker_recovery":{"auto_exits":1,"last_episode":"2026-09-25T18:05:47Z","last_action":"needs-recut"},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T11:12:02Z","needs_md":"Implement dispatch reached its 4-attempt cap"}}
EOF
PREREQUISITE_ISSUES_JSON='[{"number":500034,"title":"前置能力 [concluded-root-prerequisite-500073]: Learning events root","state":"CLOSED","stateReason":"NOT_PLANNED","labels":[]}]'
notify_reporter_question() { printf 'thread-500073\n'; }
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/not-planned-prerequisite-root.json")" '[]'
assert_contains "not-planned prerequisite routes parent to needs-info" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label needs-info"
assert_not_contains "not-planned prerequisite does not requeue parent" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label ready-for-agent"

cat > "$TEST_HOME/completed-prerequisite-root.json" <<'EOF'
{"number":500071,"title":"Learning events root","state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[{"number":500081,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500071.json" <<'EOF'
{"state":"concluded","attempts":4,"recut_refused_at":"2026-09-27T11:08:46Z","recut_refused_reason":"未找到学习事件与来源组的持久化实现","concluded_blocker_recovery":{"auto_exits":1,"last_episode":"2026-09-25T18:05:47Z","last_action":"needs-recut"},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T11:12:03Z","needs_md":"Implement dispatch reached its 4-attempt cap"}}
EOF
PREREQUISITE_ISSUES_JSON='[{"number":500032,"title":"前置能力 [concluded-root-prerequisite-500071]: Learning events root","state":"CLOSED","stateReason":"COMPLETED","labels":[]}]'
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/completed-prerequisite-root.json")" '[]'
assert_contains "completed prerequisite without disqualifying labels requeues parent" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label ready-for-agent"
assert_eq "completed prerequisite records requeue action" ready-for-agent \
  "$(jq -r '.concluded_blocker_recovery.last_action' "$STATE_DIR/500071.json")"
assert_eq "completed prerequisite id is persisted for loop detection" 500032 \
  "$(jq -r '.concluded_blocker_recovery.prerequisite_issue' "$STATE_DIR/500071.json")"

cat > "$TEST_HOME/repeated-prerequisite-root.json" <<'EOF'
{"number":500072,"title":"Learning events root","state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[{"number":500082,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500072.json" <<'EOF'
{"state":"concluded","attempts":4,"recut_refused_at":"2026-09-27T11:08:46Z","recut_refused_reason":"未找到学习事件与来源组的持久化实现","concluded_blocker_recovery":{"auto_exits":1,"last_episode":"2026-09-25T18:05:47Z","last_action":"ready-for-agent","prerequisite_issue":500033,"attempts_reset":{"reason_class":"missing-prerequisite","action":"ready-for-agent","reason":"未找到学习事件与来源组的持久化实现","to":0}},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T11:12:04Z","needs_md":"Implement dispatch reached its 4-attempt cap"}}
EOF
PREREQUISITE_ISSUES_JSON='[{"number":500033,"title":"前置能力 [concluded-root-prerequisite-500072]: Learning events root","state":"CLOSED","stateReason":"COMPLETED","labels":[]}]'
notify_reporter_question() { printf 'thread-500072\n'; }
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/repeated-prerequisite-root.json")" '[]'
assert_contains "same prerequisite requeue routes repeated refusal to needs-info" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label needs-info"
assert_not_contains "same prerequisite does not trigger second requeue" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label ready-for-agent"
assert_not_contains "same prerequisite does not create another prerequisite" \
  "$(cat "$ROOT_WRITE_LOG")" "issue create"
assert_eq "repeated prerequisite refusal records unresolved-recut" unresolved-recut \
  "$(jq -r '.concluded_blocker_recovery.attempts_reset.reason_class' "$STATE_DIR/500072.json")"

cat > "$TEST_HOME/legacy-refusal-root.json" <<'EOF'
{"number":500015,"title":"Agent finalizer root","state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[{"number":500025,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500015.json" <<'EOF'
{"state":"concluded","attempts":4,"recut_refused_at":"2026-09-27T11:03:19Z","concluded_blocker_recovery":{"auto_exits":1,"last_episode":"2026-09-26T22:12:44Z","last_action":"needs-recut"},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T11:13:49Z","needs_md":"Implement dispatch reached its 4-attempt cap"}}
EOF
: > "$ROOT_WRITE_LOG"
LEGACY_REASON_FILE="$TEST_HOME/legacy-refusal-reason.txt"
printf '目标 Agent 0.21.2 原生 finalizer 不存在于当前源码。' > "$LEGACY_REASON_FILE"
head -c 140000 /dev/zero | tr '\000' x >> "$LEGACY_REASON_FILE"
ISSUE_COMMENTS_JSON="$(jq -cn --rawfile reason "$LEGACY_REASON_FILE" \
  '{comments:[{body:("流水线尝试把这张票拆成可独立交付的小票，但没能做到：" + $reason + "\n\n合并条件")}]}')"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/legacy-refusal-root.json")" '[]'
LEGACY_REASON_BYTES="$(wc -c < "$LEGACY_REASON_FILE" | tr -d ' ')"
STORED_LEGACY_REASON_BYTES="$(jq -r '.recut_refused_reason' "$STATE_DIR/500015.json" | wc -c | tr -d ' ')"
assert_eq "legacy refusal reason beyond MAX_ARG_STRLEN backfills" \
  "$((LEGACY_REASON_BYTES + 1))" "$STORED_LEGACY_REASON_BYTES"
assert_contains "legacy refusal reason retains source text" \
  "$(jq -r '.recut_refused_reason' "$STATE_DIR/500015.json")" \
  "目标 Agent 0.21.2 原生 finalizer 不存在于当前源码。"
assert_contains "large prerequisite issue uses body-file" "$(cat "$ROOT_WRITE_LOG")" "--body-file"
assert_eq "legacy missing prerequisite is classified from its comment" missing-prerequisite \
  "$(jq -r '.concluded_blocker_recovery.attempts_reset.reason_class' "$STATE_DIR/500015.json")"

cat > "$TEST_HOME/permission-decision-root.json" <<'EOF'
{"number":500014,"title":"Run projection root","state":"OPEN","labels":[{"name":"concluded"}],"author":{"login":"reporter"},"blocking":{"nodes":[{"number":500024,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500014.json" <<'EOF'
{"state":"concluded","attempts":4,"recut_refused_at":"2026-09-27T11:11:25Z","recut_refused_reason":"不是无论如何都太大；应调整权限阶段","concluded_blocker_recovery":{"auto_exits":1,"last_episode":"2026-09-25T06:13:30Z","last_action":"needs-recut"},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T11:24:01Z","needs_md":"Implement dispatch reached its 4-attempt cap"}}
EOF
: > "$ROOT_WRITE_LOG"
notify_reporter_question() { printf 'thread-500014\n'; }
reconcile_blocking_issue_root "$(cat "$TEST_HOME/permission-decision-root.json")" '[]'
assert_contains "permission-stage gap asks reporter for decision" \
  "$(cat "$ROOT_WRITE_LOG")" "应调整权限阶段"
assert_contains "permission-stage gap routes to needs-info" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label needs-info"
assert_not_contains "product decision does not create prerequisite issue" \
  "$(cat "$ROOT_WRITE_LOG")" "issue create"
assert_eq "product-decision recovery resets exhausted attempts" 0 \
  "$(jq -r '.attempts' "$STATE_DIR/500014.json")"
assert_eq "permission gap is recorded as product-decision" product-decision \
  "$(jq -r '.concluded_blocker_recovery.attempts_reset.reason_class' "$STATE_DIR/500014.json")"

cat > "$TEST_HOME/info-root.json" <<'EOF'
{"number":500006,"state":"OPEN","labels":[{"name":"concluded"}],"author":{"login":"reporter"},"blocking":{"nodes":[{"number":500016,"state":"OPEN"}]}}
EOF
notify_reporter_question() { printf 'thread-500005\n'; }
cat > "$STATE_DIR/500006.json" <<'EOF'
{"state":"concluded","attempts":1,"review_verdict":"INPUT_INCOMPLETE","run":{"outcome":"not-completed","concluded_at":"2026-09-27T09:02:00Z","needs_md":"Code review verdict stayed INPUT_INCOMPLETE after one repair pass"}}
EOF
reconcile_blocking_issue_root "$(cat "$TEST_HOME/info-root.json")" '[]'
assert_contains "missing product input routes to needs-info" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label needs-info"
assert_eq "reporter reply thread is persisted" thread-500005 \
  "$(jq -r '.needs_info_thread_id' "$STATE_DIR/500006.json")"
assert_eq "info route is recorded as the single automatic exit" needs-info \
  "$(jq -r '.concluded_blocker_recovery.last_action' "$STATE_DIR/500006.json")"

cat > "$TEST_HOME/repeat-root.json" <<'EOF'
{"number":500007,"state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[{"number":500017,"state":"OPEN"}]}}
EOF
cat > "$STATE_DIR/500007.json" <<'EOF'
{"state":"concluded","attempts":4,"risk_class":"P2","level":"L3","concluded_blocker_recovery":{"auto_exits":1},"run":{"outcome":"not-completed","concluded_at":"2026-09-27T09:03:00Z","needs_md":"cap reached"}}
EOF
reconcile_blocking_issue_root "$(cat "$TEST_HOME/repeat-root.json")" '[]'
reconcile_blocking_issue_root "$(cat "$TEST_HOME/repeat-root.json")" '[]'
assert_eq "repeat conclusion escalates to supervisor inbox once" 1 \
  "$(grep -c 'concluded-blocker-recovery issue=#500007' "$AGENT_HOME/supervisor-inbox")"

cat > "$TEST_HOME/umbrella-root.json" <<'EOF'
{"number":500008,"state":"OPEN","labels":[{"name":"enhancement"}],"blocking":{"nodes":[{"number":500018,"state":"OPEN"}]}}
EOF
cat > "$TEST_HOME/open-issues.json" <<'EOF'
[
  {"number":500008,"state":"OPEN","blockedBy":{"nodes":[]}},
  {"number":500018,"state":"OPEN","blockedBy":{"nodes":[{"number":500008,"state":"OPEN"}]}},
  {"number":500019,"state":"OPEN","blockedBy":{"nodes":[]}}
]
EOF
cat > "$STATE_DIR/500008.json" <<'EOF'
{"state":"needs-recut","recut_children":[500019]}
EOF
reconcile_blocking_issue_root "$(cat "$TEST_HOME/umbrella-root.json")" "$(cat "$TEST_HOME/open-issues.json")"
assert_contains "recut umbrella moves dependent to live child" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-blocked-by 500019 --remove-blocked-by 500008"
assert_eq "recut umbrella stays unlabeled" 'enhancement' \
  "$(jq -r '[.labels[].name] | join(",")' "$TEST_HOME/umbrella-root.json")"

# Recut evidence takes precedence over a parent's active/on-hold labels when
# resolving dependencies; a parent closes only after every child is released.
cat > "$TEST_HOME/held-umbrella.json" <<'EOF'
{"number":500023,"state":"OPEN","labels":[{"name":"on-hold"},{"name":"needs-triage"}],"blocking":{"nodes":[{"number":500026,"state":"OPEN"}]}}
EOF
cat > "$TEST_HOME/held-graph.json" <<'EOF'
[
  {"number":500023,"state":"OPEN","blockedBy":{"nodes":[]}},
  {"number":500026,"state":"OPEN","blockedBy":{"nodes":[{"number":500023,"state":"OPEN"}]}},
  {"number":500027,"state":"OPEN","blockedBy":{"nodes":[]}}
]
EOF
cat > "$STATE_DIR/500023.json" <<'EOF'
{"recut_children":[500027]}
EOF
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/held-umbrella.json")" "$(cat "$TEST_HOME/held-graph.json")"
assert_contains "on-hold recut parent still transfers dependency to child" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-blocked-by 500027 --remove-blocked-by 500023"
assert_not_contains "recut parent resolution does not clear human on-hold" \
  "$(cat "$ROOT_WRITE_LOG")" "issue edit 500023"

cat > "$TEST_HOME/completed-umbrella.json" <<'EOF'
{"number":500028,"state":"OPEN","labels":[],"blocking":{"nodes":[]}}
EOF
cat > "$STATE_DIR/500028.json" <<'EOF'
{"recut_children":[500029,500030]}
EOF
CLOSED_CHILD_IDS='500029 500030'
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/completed-umbrella.json")" '[]' 2>>"$ROOT_WRITE_LOG"
assert_not_contains "closed but unreleased recut children keep umbrella parent open" \
  "$(cat "$ROOT_WRITE_LOG")" "gh issue close 500028"
assert_contains "unreleased recut parent reports child IDs" \
  "$(cat "$ROOT_WRITE_LOG")" "reason=children-not-released children=#500029, #500030"
unset CLOSED_CHILD_IDS

# A parent requeued after its children closed has its own remaining work
# (issue 1397 was reclosed five minutes after a supervisor requeue).
cat > "$STATE_DIR/500040.json" <<'EOF'
{"recut_children":[500041],"requeued_at":"2026-09-28T14:34:06Z"}
EOF
CLOSED_CHILD_IDS='500041'
CLOSED_CHILD_META='{"500041":{"closedAt":"2026-09-24T18:46:27Z","labels":[{"name":"released"}]}}'
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root '{"number":500040,"state":"OPEN","labels":[],"blocking":{"nodes":[]}}' '[]'
assert_not_contains "parent requeued after its children closed is not auto-closed" \
  "$(cat "$ROOT_WRITE_LOG")" "gh issue close 500040"
assert_eq "requeued parent drops its recut children so it implements as a normal ticket" false \
  "$(jq -r 'has("recut_children")' "$STATE_DIR/500040.json")"

# A pure umbrella whose children all shipped is released too, so the
# outcomes audit does not flag its close.
cat > "$STATE_DIR/500042.json" <<'EOF'
{"recut_children":[500043,500044]}
EOF
CLOSED_CHILD_IDS='500043 500044'
CLOSED_CHILD_META='{"500043":{"closedAt":"2026-09-24T18:46:27Z","labels":[{"name":"released"}]},"500044":{"closedAt":"2026-09-25T01:00:00Z","labels":[{"name":"released"}]}}'
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root '{"number":500042,"state":"OPEN","labels":[],"blocking":{"nodes":[]}}' '[]'
assert_contains "umbrella of released children is labelled released" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label released"
assert_contains "umbrella of released children still closes" \
  "$(cat "$ROOT_WRITE_LOG")" "gh issue close 500042 --repo $REPO"
unset CLOSED_CHILD_IDS CLOSED_CHILD_META

# A mixed release set keeps the umbrella open until every child is released.
cat > "$STATE_DIR/500045.json" <<'EOF'
{"recut_children":[500046,500047]}
EOF
CLOSED_CHILD_IDS='500046 500047'
CLOSED_CHILD_META='{"500046":{"closedAt":"2026-09-24T18:46:27Z","labels":[{"name":"released"}]},"500047":{"closedAt":"2026-09-25T01:00:00Z","labels":[]}}'
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root '{"number":500045,"state":"OPEN","labels":[],"blocking":{"nodes":[]}}' '[]' 2>>"$ROOT_WRITE_LOG"
assert_not_contains "mixed-release children do not label the umbrella released" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-label released"
assert_not_contains "mixed-release umbrella stays open" \
  "$(cat "$ROOT_WRITE_LOG")" "gh issue close 500045"
assert_contains "mixed-release umbrella reports pending release" \
  "$(cat "$ROOT_WRITE_LOG")" "reason=children-not-released children=#500046, #500047"
unset CLOSED_CHILD_IDS CLOSED_CHILD_META

# A child closed as a duplicate delivered nothing; on 2026-10-04 child 2425 was closed as a duplicate
# whose work "由 #1141 承担", and the auto-close then closed 1141 as completed with its work undone.
cat > "$STATE_DIR/500048.json" <<'EOF'
{"recut_children":[500049,500050]}
EOF
CLOSED_CHILD_IDS='500049 500050'
CLOSED_CHILD_META='{"500049":{"closedAt":"2026-10-04T09:23:51Z","labels":[{"name":"duplicate"},{"name":"concluded"}]},"500050":{"closedAt":"2026-10-04T09:00:00Z","labels":[{"name":"released"}]}}'
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root '{"number":500048,"state":"OPEN","labels":[],"blocking":{"nodes":[]}}' '[]'
assert_not_contains "parent of a child closed as duplicate is not auto-closed" \
  "$(cat "$ROOT_WRITE_LOG")" "gh issue close 500048"
assert_eq "parent of a duplicate child drops its recut children and implements its own work" false \
  "$(jq -r 'has("recut_children")' "$STATE_DIR/500048.json")"
unset CLOSED_CHILD_IDS CLOSED_CHILD_META

# The same through a native sub-issue: the parent is dispatched as a normal ticket, not skipped every tick.
printf '{}\n' > "$STATE_DIR/500057.json"
NATIVE_DUPLICATE_PARENT=500057
native_duplicate_status=0
recut_parent_has_open_child 500057 '[]' || native_duplicate_status=$?
assert_eq "parent whose native sub-issue closed as duplicate is not a closed recut parent" 1 "$native_duplicate_status"
unset NATIVE_DUPLICATE_PARENT

# Comment-only recut parents are recognized for blocker transfer during the
# migration from local recut_children state.
cat > "$TEST_HOME/comment-umbrella.json" <<'EOF'
{"number":500031,"state":"OPEN","labels":[{"name":"on-hold"}],"blocking":{"nodes":[{"number":500032,"state":"OPEN"}]}}
EOF
ISSUE_COMMENTS_JSON='{"body":"","comments":[{"body":"这张票范围太大，流水线拆成了 1 张更小的子票。\n- #500033 Child"}]}'
cat > "$TEST_HOME/comment-graph.json" <<'EOF'
[
  {"number":500031,"state":"OPEN","blockedBy":{"nodes":[]}},
  {"number":500032,"state":"OPEN","blockedBy":{"nodes":[{"number":500031,"state":"OPEN"}]}},
  {"number":500033,"state":"OPEN","blockedBy":{"nodes":[]}}
]
EOF
: > "$ROOT_WRITE_LOG"
reconcile_blocking_issue_root "$(cat "$TEST_HOME/comment-umbrella.json")" "$(cat "$TEST_HOME/comment-graph.json")"
assert_contains "comment-marked recut parent transfers blocker without local state" \
  "$(cat "$ROOT_WRITE_LOG")" "--add-blocked-by 500033 --remove-blocked-by 500031"
unset ISSUE_COMMENTS_JSON

cat > "$TEST_HOME/blocker-graph.json" <<'EOF'
[
  {"number":500030,"title":"Root","labels":[{"name":"concluded"}],"blockedBy":{"nodes":[]}},
  {"number":500031,"labels":[{"name":"ready-for-agent"}],"blockedBy":{"nodes":[{"number":500030,"state":"OPEN"}]}},
  {"number":500032,"labels":[{"name":"ready-for-agent"}],"blockedBy":{"nodes":[{"number":500031,"state":"OPEN"}]}},
  {"number":500033,"labels":[{"name":"ready-for-agent"}],"blockedBy":{"nodes":[{"number":500030,"state":"OPEN"}]}},
  {"number":500040,"title":"Other root","labels":[{"name":"concluded"}],"blockedBy":{"nodes":[]}},
  {"number":500041,"labels":[{"name":"ready-for-agent"}],"blockedBy":{"nodes":[{"number":500040,"state":"OPEN"}]}}
]
EOF
assert_eq "summary collapses dependency chains to roots and counts held tickets" \
  '#500030 Root:3,#500040 Other root:1' \
  "$(issue_blocker_root_summary "$(cat "$TEST_HOME/blocker-graph.json")" ready-for-agent)"


# Replay supervisor evidence: 22 silent resumes, 6 refunded infrastructure
# attempts, 25 ticket failures, 6 merged outcomes, and one missing outcome.
REPLAY_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REPLAY_ISSUES_NDJSON="$TEST_HOME/replay-issues.ndjson"
: > "$REPLAY_ISSUES_NDJSON"
stage_unit_active() { return 1; }
stage_dispatch_allowed() { return 0; }
unset ISSUE_COMMENTS_JSON || true
for offset in $(seq 0 59); do
  issue=$((510000 + offset))
  started="$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)"
  if [ "$offset" -lt 22 ]; then
    state="$(jq -cn --arg started "$started" --arg now "$REPLAY_NOW" \
      '{state:"concluded",attempts:4,run:{outcome:"not-completed",implement_started_at:$started,concluded_at:$now,needs_md:"Previous model unit ended without recording a result"},model_policy:{failure:{stage:"implement",reason:"Previous model unit ended without recording a result",recorded_at:$now}}}')"
  elif [ "$offset" -lt 28 ]; then
    state="$(jq -cn --arg started "$started" --arg now "$REPLAY_NOW" \
      '{state:"concluded",attempts:4,run:{outcome:"not-completed",implement_started_at:$started,concluded_at:$now,needs_md:"CI runner capacity gate failed"},model_policy:{unit:"implement",retry_note:{stage:"implement",status:1,attempt_refunded:true,reason:"CI runner capacity gate failed",recorded_at:$now}}}')"
  elif [ "$offset" -lt 53 ]; then
    risk="P2"
    level="L3"
    if [ "$offset" -ge 48 ]; then risk="P1"; level="L1"; fi
    state="$(jq -cn --arg started "$started" --arg now "$REPLAY_NOW" --arg risk "$risk" --arg level "$level" \
      '{state:"concluded",attempts:4,risk_class:$risk,level:$level,run:{outcome:"not-completed",implement_started_at:$started,concluded_at:$now,needs_md:"Package test failed"},model_policy:{failure:{stage:"package-gate",status:1,reason:"Package test failed",recorded_at:$now}}}')"
  elif [ "$offset" -lt 59 ]; then
    state="$(jq -cn --arg now "$REPLAY_NOW" \
      '{state:"concluded",run:{outcome:"merged",concluded_at:$now,evidence:{pr_number:"600"}}}')"
  else
    state="$(jq -cn --arg now "$REPLAY_NOW" '{state:"concluded",run:{concluded_at:$now}}')"
  fi
  printf '%s\n' "$state" > "$STATE_DIR/$issue.json"
  issue_json="$(jq -cn --argjson number "$issue" '{number:$number,state:"OPEN",labels:[{name:"concluded"}],author:{login:"reporter"},blocking:{nodes:[]}}')"
  reconcile_blocking_issue_root "$issue_json" '[]'
  stage="$(jq -r '.state' "$STATE_DIR/$issue.json")"
  jq -cn --argjson number "$issue" --arg stage "$stage" --arg updated "$REPLAY_NOW" \
    '{number:$number,state:"OPEN",createdAt:$updated,updatedAt:$updated,labels:[{name:$stage}]}' \
    >> "$REPLAY_ISSUES_NDJSON"
done
unset -f stage_unit_active stage_dispatch_allowed
jq -s . "$REPLAY_ISSUES_NDJSON" > "$TEST_HOME/replay-open-issues.json"
printf 'triage OK fixture\nadvisor OK fixture\nimplement OK fixture\ndeploy OK fixture\nacceptance OK fixture\n' \
  > "$TEST_HOME/replay-health"
REPLAY_NOW_EPOCH="$(date -u +%s)"
AGENT_HOME="$TEST_HOME" bash "$SCRIPT_DIR/ticket-progress.sh" \
  "$TEST_HOME/replay-open-issues.json" "$TEST_HOME/replay-health" "$REPLAY_NOW_EPOCH" >/dev/null
assert_eq "60-ticket replay classifies and routes every prior conclusion" 60 \
  "$(for issue in $(seq 510000 510059); do jq -e '
    (.run.conclusion.class == "infrastructure" and .run.conclusion.route == "requeue") or
    (.run.conclusion.class == "pipeline-defect" and .run.conclusion.route == "requeue") or
    (.run.conclusion.class == "completed" and .run.conclusion.route == "awaiting-release") or
    (.run.conclusion.class == "ticket" and .run.conclusion.route == "requeue") or
    (.run.conclusion.class == "ticket" and (.run.conclusion.route == "recut" or .run.conclusion.route == "needs-info" or .run.conclusion.route == "close-not-planned"))
  ' "$STATE_DIR/$issue.json" >/dev/null && echo "$issue"; done | wc -l | tr -d ' ')"
assert_eq "60-ticket replay leaves no concluded state records" 0 \
  "$(for issue in $(seq 510000 510059); do jq -r 'select(.state == "concluded") | .state' "$STATE_DIR/$issue.json"; done | wc -l | tr -d ' ')"
assert_eq "60-ticket replay tracks active and held owner lanes" 38 \
  "$(jq -r '.tickets | length' "$STATE_DIR/ticket-stage-status.json")"
assert_eq "60-ticket replay clears no-lane-consumer count" 0 \
  "$(jq -r '[.tickets[] | select(.reason | contains("no-lane-consumer"))] | length' "$STATE_DIR/ticket-stage-status.json")"
printf '60-ticket replay: no-lane-consumer 60 -> 0\n'


# 2026-10-03, issue 1943: an undeliverable question routed a spent ticket to
# the advisor before its attempts were reset. The admission gate saw 4/4,
# conclude_run refused, and the failure aborted every later root for 15h.
cat > "$TEST_HOME/spent-advisor-route.json" <<'EOF'
{"number":500060,"state":"OPEN","labels":[{"name":"concluded"}],"author":{"login":"maintainer"},"blocking":{"nodes":[]}}
EOF
cat > "$STATE_DIR/500060.json" <<'EOF'
{"state":"concluded","attempts":4,"recut_refused_at":"2026-10-01T10:31:04Z","concluded_blocker_recovery":{"auto_exits":1,"last_episode":"2026-10-01T10:22:14Z","last_action":"needs-recut","question_delivery_failed_episode":"2026-10-01T11:02:00Z"},"model_policy":{"unit":"implement","step":"work"},"requeued_at":"2026-09-29T00:57:53Z","run":{"outcome":"not-completed","concluded_at":"2026-10-01T11:02:00Z","previous_concluded_at":"2026-10-01T10:22:14Z","implement_started_at":"2026-10-01T10:59:43Z","needs_md":"流水线尝试把这张票拆成可独立交付的小票，但没能做到"}}
EOF
: > "$ROOT_WRITE_LOG"
ADMISSION_RESULT=unset
route_to_advisor() {
  advisor_retry_admission "$1" && ADMISSION_RESULT=admitted || { ADMISSION_RESULT="refused:$?"; return 1; }
  state_merge "$1" '.state = "needs-advisor"' || return 1
  guarded_write gh issue edit "$1" --repo "$REPO" --remove-label concluded --add-label needs-advisor
}
notify_reporter_question() { return 1; }
spent_rc=0
reconcile_blocking_issue_root "$(cat "$TEST_HOME/spent-advisor-route.json")" '[]' 2>/dev/null || spent_rc=$?
assert_eq "spent ticket with an undeliverable question reaches the advisor" 0 "$spent_rc"
assert_eq "advisor admission sees the new episode budget" admitted "$ADMISSION_RESULT"

real_reconcile="$(declare -f reconcile_blocking_issue_root)"
SWEPT=""
reconcile_blocking_issue_root() {
  local n; n="$(jq -r '.number' <<< "$1")"
  SWEPT+="$n "
  [ "$n" != 500061 ]
}
BLOCKER_GRAPH_JSON='[{"number":500061,"state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[]}},{"number":500062,"state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[]}}]'
: > "$AGENT_HOME/supervisor-inbox"
sweep_rc=0
sweep_blocking_issue_roots 2>/dev/null || sweep_rc=$?
eval "$real_reconcile"
assert_contains "a failing root does not stop the sweep" "$SWEPT" "500062"
assert_eq "the sweep still reports the failure" 1 "$sweep_rc"
assert_contains "a failing root rings the supervisor" "$(cat "$AGENT_HOME/supervisor-inbox")" "blocker-root-failed issue=#500061"

# 2026-10-08 07:37:31Z/#2511 and 07:38:18Z/#2520: a ready-for-agent root with
# open dependents and no recut_children aborted its reconcile on a transient
# gh api sub_issues failure with no output anywhere -- gh's stderr was
# discarded at the call site and the inbox line named no reason. The same
# shape must still fail closed (the root waits for the next tick), but the
# inbox line must now say why, including gh's own error.
cat > "$STATE_DIR/500090.json" <<'EOF'
{"state":"ready-for-agent","attempts":0,"recut_comment_scanned":true}
EOF
rm -f "$AGENT_HOME/blocker-root-sweep.cursor"
: > "$AGENT_HOME/supervisor-inbox"
BLOCKER_GRAPH_JSON="$(jq -n '[{number:500090,state:"OPEN",labels:[{name:"ready-for-agent"},{name:"enhancement"}],author:{login:"reporter"},blocking:{nodes:[{number:500091,state:"OPEN"}]}}]')"
SUBISSUES_API_FAIL=1
transient_rc=0
sweep_blocking_issue_roots 2>/dev/null || transient_rc=$?
unset SUBISSUES_API_FAIL
assert_eq "transient sub-issue read still fails its root closed" 1 "$transient_rc"
assert_contains "inbox line names the failing call and issue" \
  "$(cat "$AGENT_HOME/supervisor-inbox")" "blocker-root-failed issue=#500090 reason=gh api sub_issues failed for #500090"
assert_contains "inbox line carries gh's own stderr as the reason" \
  "$(cat "$AGENT_HOME/supervisor-inbox")" "secondary rate limit exceeded (fake)"
assert_contains "the sweep still continues past the failed root" \
  "$(cat "$AGENT_HOME/supervisor-inbox")" "the sweep continued with the remaining roots"
assert_eq "root stays untouched for the next tick" ready-for-agent \
  "$(jq -r '.state' "$STATE_DIR/500090.json")"
unset BLOCKER_ROOT_FAIL_REASON

# 2026-10-04: the sweep took 300-530s per tick and starved implement for 8 hours. It stops at its budget
# and resumes after the last root it reconciled, so the next ticks visit the rest.
real_reconcile="$(declare -f reconcile_blocking_issue_root)"
reconcile_blocking_issue_root() {
  SWEPT+="$(jq -r '.number' <<< "$1") "
  SECONDS=$((SECONDS + 100))
}
BLOCKER_GRAPH_JSON='[{"number":500083,"state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[]}},{"number":500081,"state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[]}},{"number":500082,"state":"OPEN","labels":[{"name":"concluded"}],"blocking":{"nodes":[]}}]'
rm -f "$AGENT_HOME/blocker-root-sweep.cursor"
SWEPT=""; BLOCKER_ROOT_SWEEP_BUDGET_SECONDS=150 sweep_blocking_issue_roots 2>/dev/null || true
assert_eq "a sweep stops at its budget" "500081 500082 " "$SWEPT"
assert_eq "the stopped sweep records where it got to" 500082 "$(cat "$AGENT_HOME/blocker-root-sweep.cursor")"
SWEPT=""; BLOCKER_ROOT_SWEEP_BUDGET_SECONDS=150 sweep_blocking_issue_roots 2>/dev/null || true
assert_eq "the next sweep resumes after the cursor and wraps" "500083 500081 " "$SWEPT"
SWEPT=""; BLOCKER_ROOT_SWEEP_BUDGET_SECONDS=1000 sweep_blocking_issue_roots 2>/dev/null || true
assert_eq "a sweep with budget left visits every root once" "500082 500083 500081 " "$SWEPT"
assert_eq "a completed sweep clears its cursor" no "$([ -e "$AGENT_HOME/blocker-root-sweep.cursor" ] && echo yes || echo no)"
eval "$real_reconcile"

# The tick-wide GH deadline can expire before the sweep's own time budget.
# Stop before reconciling the next root; leave its predecessor as cursor so it
# is first on the next tick, then wrap through roots already visited this tick.
deadline_real_reconcile="$(declare -f reconcile_blocking_issue_root)"
deadline_real_helper="$(declare -f gh_tick_attempt_timeout_sec)"
DEADLINE_ACTIVE=1
DEADLINE_CALLS=0
DEADLINE_SWEPT=""
gh_tick_attempt_timeout_sec() {
  DEADLINE_CALLS=$((DEADLINE_CALLS + 1))
  if [ "$DEADLINE_ACTIVE" = 1 ] && [ "$DEADLINE_CALLS" -eq 3 ]; then return 1; fi
  printf '1\n'
}
reconcile_blocking_issue_root() {
  local n; n="$(jq -r '.number' <<< "$1")"
  DEADLINE_SWEPT+="$n "
}
BLOCKER_GRAPH_JSON="$(jq -nc '[range(500081;500086) | {number:.,state:"OPEN",labels:[{name:"concluded"}],blocking:{nodes:[]}}]')"
rm -f "$AGENT_HOME/blocker-root-sweep.cursor"
: > "$AGENT_HOME/supervisor-inbox"
deadline_stderr="$TEST_HOME/blocker-root-deadline.stderr"
sweep_blocking_issue_roots 2> "$deadline_stderr"
assert_eq "tick deadline stops after roots 1 and 2" "500081 500082 " "$DEADLINE_SWEPT"
assert_eq "deadline stop writes no inbox lines" 0 "$(wc -l < "$AGENT_HOME/supervisor-inbox" | tr -d ' ')"
assert_eq "deadline stop writes one stderr line" 1 "$(wc -l < "$deadline_stderr" | tr -d ' ')"
assert_eq "deadline stop names next root and progress" \
  "blocker-root sweep: tick gh deadline exhausted after 2/5 roots; resuming at #500083 next tick" \
  "$(cat "$deadline_stderr")"
assert_eq "cursor predecessor makes root 3 next" 500082 "$(cat "$AGENT_HOME/blocker-root-sweep.cursor")"
DEADLINE_ACTIVE=0
DEADLINE_CALLS=0
DEADLINE_SWEPT=""
sweep_blocking_issue_roots 2> "$deadline_stderr"
assert_eq "next tick resumes at roots 3-5 then wraps to roots 1-2" \
  "500083 500084 500085 500081 500082 " "$DEADLINE_SWEPT"
eval "$deadline_real_reconcile"
eval "$deadline_real_helper"

exit "$FAILED"
