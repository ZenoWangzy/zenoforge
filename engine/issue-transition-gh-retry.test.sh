#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export ZF_REPO=fixture/repo ZF_GH_RETRY_MAX_ATTEMPTS=3 ZF_GH_RETRY_BACKOFF_SECONDS=2
source "$SCRIPT_DIR/lib.sh"

export GH_MODE=complexity
export GH_CALL_LOG="$AGENT_HOME/gh-calls.log"
export GH_SLEEP_LOG="$AGENT_HOME/sleeps.log"
export GH_LABELS_OUT="$AGENT_HOME/labels-written.json"
export GH_LABELS_IN="$AGENT_HOME/labels-read.json"
: > "$GH_CALL_LOG"
: > "$GH_SLEEP_LOG"

cat > "$test_env_bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_CALL_LOG"
if [[ "$GH_MODE" == gql-quota ]]; then
  if [[ "$1 ${2:-}" == 'api graphql' && "$*" == *rateLimit* ]]; then
    printf '%s\n' "$GH_RATE_LIMIT_RESET_AT"
    exit 0
  fi
  if [[ "$1 ${2:-}" == 'issue view' ]]; then
    echo 'GraphQL: API rate limit already exceeded for user ID 1.' >&2
    exit 1
  fi
  echo tester
  exit 0
fi
if [[ "$GH_MODE" == rest-quota ]]; then
  if [[ "$1 ${2:-}" == 'api rate_limit' ]]; then
    printf '%s\n' "$GH_RATE_LIMIT_RESET_EPOCH"
    exit 0
  fi
  if [[ "$1" == api ]]; then
    echo 'HTTP 403: API rate limit exceeded for user ID 1.' >&2
    exit 1
  fi
  echo tester
  exit 0
fi
if [[ "$GH_MODE" == unrestricted ]]; then
  echo tester
  exit 0
fi
if [[ "$1" == api && "${2:-}" == repos/fixture/repo/issues/8124 ]]; then
  printf '%s\n' '{"number":8124,"state":"closed","labels":[]}'
  exit 0
fi
if [[ "$GH_MODE" == retry502 ]]; then
  echo 'gh: Bad Gateway (HTTP 502)' >&2
  exit 1
fi
if [[ "$GH_MODE" == complexity ]] || { [[ "$GH_MODE" == rest || "$GH_MODE" == primary || "$GH_MODE" == edit404 ]] && [[ "$1 $2 ${3:-}" == 'issue view 5314' ]]; }; then
  for _ in $(seq 1 300); do echo 'Resource limits for this query exceeded.' >&2; done
  exit 1
fi
if [[ "$GH_MODE" == edit404 ]]; then
  if [[ "$1 $2 ${3:-}" == 'issue view 8124' ]]; then
    echo CLOSED
    exit 0
  fi
  if [[ "$1 $2" == 'issue edit' ]]; then
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1
  fi
  echo "unexpected fake gh call: $*" >&2
  exit 90
fi
if [[ ( "$GH_MODE" == rest || "$GH_MODE" == primary ) && "$1 $2 ${3:-}" == 'issue view 8124' ]]; then
  echo CLOSED
  exit 0
fi
if [[ "$GH_MODE" == primary && "$1 $2" == 'issue edit' ]]; then
  exit 0
fi
if [[ "$GH_MODE" == rest && "$1 $2" == 'issue edit' ]]; then
  if [[ "${GH_EDIT_ERROR:-complexity}" == validation ]]; then
    printf '%s\n' 'GraphQL returned multiple errors' 'Cannot query field labels on type Issue' >&2
  else
    echo 'gh: Resource limits for this query exceeded' >&2
  fi
  exit 1
fi
if [[ "$GH_MODE" == rest && "$1" == api ]]; then
  method=""; path=""; input=""; previous=""
  for arg in "$@"; do
    case "$previous" in
      --method) method="$arg" ;;
      --input) input="$arg" ;;
    esac
    case "$arg" in repos/*/issues/*) path="$arg" ;; esac
    previous="$arg"
  done
  case "$method:$path" in
    GET:repos/fixture/repo/issues/5314/labels)
      cat "$GH_LABELS_IN"
      ;;
    PUT:repos/fixture/repo/issues/5314/labels)
      [[ -r "$input" ]]
      cp -- "$input" "$GH_LABELS_OUT"
      echo '[]'
      ;;
    *) echo "unexpected REST call: $*" >&2; exit 90 ;;
  esac
  exit 0
fi
echo "unexpected fake gh call: $*" >&2
exit 90
GH
chmod +x "$test_env_bin/gh"

sleep() { printf '%s\n' "$1" >> "$GH_SLEEP_LOG"; }

# A deterministic GraphQL complexity refusal is one attempt and one summary
# line even when gh emits the same error once per failed query path.
: > "$GH_CALL_LOG"
if gh issue view 5314 --repo "$REPO" --json labels > "$AGENT_HOME/complex.out" 2> "$AGENT_HOME/complex.err"; then
  echo 'not ok - complexity refusal unexpectedly succeeded' >&2
  exit 1
fi
[[ "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')" == 1 ]]
[[ "$(wc -l < "$AGENT_HOME/complex.err" | tr -d ' ')" == 1 ]]
grep -Fqx 'gh: non-retryable GraphQL error: Resource limits for this query exceeded' "$AGENT_HOME/complex.err"
if gh_failure_is_transient 'gh: Resource limits for this query exceeded'; then
  echo 'not ok - GraphQL complexity refusal classified as transient' >&2
  exit 1
fi
if gh_failure_is_transient "gh: GraphQL: Field 'title' doesn't exist on type 'Issue' (HTTP 200)"; then
  echo 'not ok - deterministic GraphQL validation failure classified as transient' >&2
  exit 1
fi
echo 'ok - GraphQL complexity refusal fails after one attempt with one log line'

# Retryable 502 reads honor the configured three-attempt cap and exponential
# backoff (the sleep shim records delays without waiting in the focused test).
export GH_MODE=retry502
: > "$GH_CALL_LOG"
: > "$GH_SLEEP_LOG"
if gh issue view 5314 --repo "$REPO" --json labels > "$AGENT_HOME/502.out" 2> "$AGENT_HOME/502.err"; then
  echo 'not ok - repeated 502 unexpectedly succeeded' >&2
  exit 1
fi
[[ "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')" == 3 ]]
[[ "$(cat "$GH_SLEEP_LOG")" == $'2\n4' ]]
echo 'ok - HTTP 502 retries stop at the configured three attempts with backoff'

# Leading zeroes are decimal configuration, so 01 must still mean one try.
export ZF_GH_RETRY_MAX_ATTEMPTS=01
: > "$GH_CALL_LOG"
: > "$GH_SLEEP_LOG"
if gh issue view 5314 --repo "$REPO" --json labels > "$AGENT_HOME/one.out" 2> "$AGENT_HOME/one.err"; then
  echo 'not ok - repeated 502 unexpectedly succeeded with one configured attempt' >&2
  exit 1
fi
[[ "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')" == 1 ]] || { echo 'not ok - leading-zero attempt limit was not honored' >&2; exit 1; }
[[ ! -s "$GH_SLEEP_LOG" ]]
echo 'ok - leading-zero retry limit is honored'

# Decimal configuration stays bounded even with leading zeroes or very large
# values; neither may cause a read to be skipped or an arithmetic error.
export ZF_GH_RETRY_MAX_ATTEMPTS=999999999999999999999999999999
export ZF_GH_RETRY_BACKOFF_SECONDS=08
: > "$GH_CALL_LOG"
: > "$GH_SLEEP_LOG"
if gh issue view 5314 --repo "$REPO" --json labels > "$AGENT_HOME/large.out" 2> "$AGENT_HOME/large.err"; then
  echo 'not ok - repeated 502 with oversized retry configuration unexpectedly succeeded' >&2
  exit 1
fi
[[ "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')" == 5 ]]
[[ "$(cat "$GH_SLEEP_LOG")" == $'8\n16\n30\n30' ]]
export ZF_GH_RETRY_MAX_ATTEMPTS=3 ZF_GH_RETRY_BACKOFF_SECONDS=2
echo 'ok - retry settings are normalized and bounded before arithmetic'

# A successful primary edit must not call the REST label API.
export GH_MODE=primary
: > "$GH_CALL_LOG"
roadmap_ensure_issue_parent() { :; }
ensure_state_labels() { :; }
state_merge 5314 '{"state":"needs-triage","recut_children":[8124]}'
OPEN_ISSUE_BLOCKER_GRAPH_JSON='[{"number":8124,"state":"CLOSED"}]' \
  issue_transition 5314 ready-for-agent focused-primary-label-write 2> "$AGENT_HOME/primary.err"
[[ "$(grep -Fc 'issue edit 5314 ' "$GH_CALL_LOG")" == 1 ]]
if grep -Eq '^api .*repos/fixture/repo/issues/5314/labels' "$GH_CALL_LOG"; then
  echo 'not ok - successful primary edit called the REST label fallback' >&2
  exit 1
fi
[[ "$(state_read 5314 | jq -r '.state')" == ready-for-agent ]]
echo 'ok - successful primary edit does not use REST fallback'

# A deterministic GraphQL refusal of the primary `gh issue edit` falls back to
# the REST labels API: one edit attempt, then the complete label set written
# through REST with unrelated labels preserved and the state transition kept.
export ZF_REPO=fixture/repo
export GH_MODE=rest
: > "$GH_CALL_LOG"
: > "$GH_SLEEP_LOG"
printf '%s\n' '[[{"name":"needs-triage"},{"name":"focus"},{"name":"evidence-gate"}]]' > "$GH_LABELS_IN"
state_merge 5314 '{"state":"needs-triage","recut_children":[8124]}'
OPEN_ISSUE_BLOCKER_GRAPH_JSON='[{"number":8124,"state":"CLOSED"}]' \
  issue_transition 5314 ready-for-agent focused-rest-label-write 2> "$AGENT_HOME/transition.err"
jq -e '.labels | index("ready-for-agent") != null and index("focus") != null and index("evidence-gate") != null and index("needs-triage") == null' \
  "$GH_LABELS_OUT" >/dev/null || { echo 'not ok - REST fallback lost a label the transition did not remove' >&2; exit 1; }
grep -Fq 'api --paginate --slurp --method GET repos/fixture/repo/issues/5314/labels' "$GH_CALL_LOG"
grep -Fq 'api --method PUT repos/fixture/repo/issues/5314/labels' "$GH_CALL_LOG"
[[ "$(grep -Fc 'issue edit 5314 ' "$GH_CALL_LOG")" == 1 ]]
[[ "$(state_read 5314 | jq -r '.state')" == ready-for-agent ]]
[[ "$(grep -Fc 'issue view 5314 --repo fixture/repo --json labels' "$GH_CALL_LOG")" == 1 ]]
grep -Fq 'issue view failed for #5314' "$AGENT_HOME/transition.err"
grep -Fq 'falling back to the REST label write' "$AGENT_HOME/transition.err"
echo 'ok - GraphQL-refused label edit retries the transition labels through REST'

# A validation error following an unrelated line must remain recognizable
# after transport logging, so the fallback still runs.
export GH_EDIT_ERROR=validation
: > "$GH_CALL_LOG"
state_merge 5314 '{"state":"needs-triage"}'
issue_transition 5314 needs-recut focused-validation-label-write 2> "$AGENT_HOME/validation.err"
grep -Fq 'api --method PUT repos/fixture/repo/issues/5314/labels' "$GH_CALL_LOG"
[[ "$(state_read 5314 | jq -r '.state')" == needs-recut ]]
unset GH_EDIT_ERROR
echo 'ok - multi-line GraphQL validation error triggers REST fallback'

# A hold learned through REST must prevent every unauthorized transition, even
# when the earlier GraphQL label read failed and the target is not ready.
printf '%s\n' '[[{"name":"needs-triage"},{"name":"on-hold"},{"name":"focus"}]]' > "$GH_LABELS_IN"
: > "$GH_CALL_LOG"
state_merge 5314 '{"state":"needs-triage"}'
if issue_transition 5314 needs-recut focused-held-label-write 2> "$AGENT_HOME/held.err"; then
  echo 'not ok - REST fallback transitioned a held issue' >&2
  exit 1
fi
if grep -Fq 'api --method PUT' "$GH_CALL_LOG"; then
  echo 'not ok - REST fallback wrote labels for a held issue' >&2
  exit 1
fi
[[ "$(state_read 5314 | jq -r '.state')" == needs-triage ]]
grep -Fq 'refusing partial stage transition for held #5314' "$AGENT_HOME/held.err"
echo 'ok - REST fallback preserves the hold guard for non-ready stages'

# An explicit hold release still removes the hold but keeps unrelated labels.
printf '%s\n' '[[{"name":"on-hold"},{"name":"focus"},{"name":"evidence-gate"}]]' > "$GH_LABELS_IN"
state_merge 5314 '{"state":"on-hold","recut_children":[8124]}'
OPEN_ISSUE_BLOCKER_GRAPH_JSON='[{"number":8124,"state":"CLOSED"}]' \
  issue_transition 5314 ready-for-agent hold-requeue 2> "$AGENT_HOME/release.err"
jq -e '.labels | index("ready-for-agent") != null and index("on-hold") == null and index("evidence-gate") != null and index("focus") != null' \
  "$GH_LABELS_OUT" >/dev/null
echo 'ok - REST fallback honors an explicit hold release'

# A hold is allowed to be retained when it is the destination itself.
state_merge 5314 '{"state":"needs-triage"}'
issue_transition 5314 on-hold hold-applied 2> "$AGENT_HOME/retain-hold.err"
jq -e '.labels | index("on-hold") != null and index("evidence-gate") != null' "$GH_LABELS_OUT" >/dev/null
echo 'ok - REST fallback can retain the destination hold'

# Evidence-gate is removed when the transition explicitly requests it.
printf '%s\n' '[[{"name":"needs-triage"},{"name":"focus"},{"name":"evidence-gate"}]]' > "$GH_LABELS_IN"
state_merge 5314 '{"state":"needs-triage"}'
issue_transition 5314 concluded conclude:deployed 2> "$AGENT_HOME/conclude.err"
jq -e '.labels | index("concluded") != null and index("released") != null and index("evidence-gate") == null and index("focus") != null' \
  "$GH_LABELS_OUT" >/dev/null
echo 'ok - REST fallback honors explicit evidence removal'

# Malformed label entries must never be silently discarded from a replacement.
printf '%s\n' '[[{"name":"focus"},{"id":123}]]' > "$GH_LABELS_IN"
: > "$GH_CALL_LOG"
state_merge 5314 '{"state":"needs-triage","recut_children":[8124]}'
if OPEN_ISSUE_BLOCKER_GRAPH_JSON='[{"number":8124,"state":"CLOSED"}]' \
  issue_transition 5314 ready-for-agent focused-invalid-label-response 2> "$AGENT_HOME/invalid.err"; then
  echo 'not ok - malformed REST labels unexpectedly succeeded' >&2
  exit 1
fi
if grep -Fq 'api --method PUT' "$GH_CALL_LOG"; then
  echo 'not ok - malformed REST labels triggered a replacement' >&2
  exit 1
fi
[[ "$(state_read 5314 | jq -r '.state')" == needs-triage ]]
grep -Fq 'invalid REST label response' "$AGENT_HOME/invalid.err"
echo 'ok - malformed REST labels cannot cause a replacement'

# Any other write failure keeps the ordinary path: no REST fallback, the
# transition fails, and the local state rolls back to its pre-write value.
export GH_MODE=edit404
: > "$GH_CALL_LOG"
state_merge 5314 '{"state":"needs-triage","recut_children":[8124]}'
if OPEN_ISSUE_BLOCKER_GRAPH_JSON='[{"number":8124,"state":"CLOSED"}]' \
  issue_transition 5314 ready-for-agent focused-rest-label-write 2> "$AGENT_HOME/edit404.err"; then
  echo 'not ok - HTTP 404 write failure unexpectedly succeeded' >&2
  exit 1
fi
if grep -Eq '^api .*repos/fixture/repo/issues/5314/labels' "$GH_CALL_LOG"; then
  echo 'not ok - non-GraphQL write failure used the REST fallback' >&2
  exit 1
fi
[[ "$(grep -Fc 'issue edit 5314 ' "$GH_CALL_LOG")" == 1 ]]
[[ "$(state_read 5314 | jq -r '.state')" == needs-triage ]]
grep -Fq 'label write failed for #5314' "$AGENT_HOME/edit404.err"
echo 'ok - non-GraphQL write failure never touches the REST fallback'

# Primary GraphQL exhaustion writes one host-visible reset marker. Calls from
# both wrappers stop before reaching gh, and the marker expiry reopens them.
export GH_MODE=gql-quota
export GH_RATE_LIMIT_RESET_AT="$(date -u -d '+45 minutes' '+%Y-%m-%dT%H:%M:%SZ')"
export GH_RATE_LIMIT_RESET_EPOCH="$(date -u -d '+45 minutes' +%s)"
gql_marker="$AGENT_HOME/gh-rate-limit-until.graphql"
rest_marker="$AGENT_HOME/gh-rate-limit-until.rest"
rm -f -- "$gql_marker" "$rest_marker"
: > "$GH_CALL_LOG"
if gh issue view 8124 --repo "$REPO" > /dev/null 2> "$AGENT_HOME/gql-quota.err"; then
  echo 'not ok - GraphQL quota exhaustion unexpectedly succeeded' >&2
  exit 1
else
  quota_rc=$?
fi
[[ "$quota_rc" == 75 ]] || { echo "not ok - GraphQL exhaustion returned rc=$quota_rc, expected 75" >&2; exit 1; }
expected_reset="$(date -u -d "$GH_RATE_LIMIT_RESET_AT" +%s)"
actual_reset="$(cat "$gql_marker")"
[[ "$actual_reset" == "$expected_reset" ]] || {
  echo "not ok - GraphQL marker reset=$actual_reset expected=$expected_reset" >&2
  exit 1
}
calls_after_quota="$(wc -l < "$GH_CALL_LOG" | tr -d ' ')"
[[ "$calls_after_quota" == 2 ]] || { echo "not ok - GraphQL failure made $calls_after_quota CLI calls, expected one failure and one reset read" >&2; exit 1; }
if bash -c 'source "$1/lib.sh"; gh issue view 8124 --repo "$REPO"' _ "$SCRIPT_DIR" > /dev/null 2> "$AGENT_HOME/gql-backoff.err"; then
  echo 'not ok - another shell bypassed the host GraphQL backoff' >&2
  exit 1
else
  quota_rc=$?
fi
[[ "$quota_rc" == 75 ]]
[[ "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')" == "$calls_after_quota" ]]
(
  source "$SCRIPT_DIR/mac-autopilot/scheduler.d/core.sh"
  A="$AGENT_HOME/tick-backoff"
  GH_ETAG_DIR="$A/.gh-etag"
  mkdir -p "$A" "$GH_ETAG_DIR"
  if gh pr list --repo "$REPO" > /dev/null 2> "$AGENT_HOME/scheduler-backoff.err"; then exit 1; else [[ "$?" == 75 ]]; fi
)
[[ "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')" == "$calls_after_quota" ]]
printf '%s\n' "$(( $(date +%s) - 1 ))" > "$gql_marker"
export GH_MODE=unrestricted
gh issue view 8124 --repo "$REPO" > /dev/null
[[ "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')" == "$((calls_after_quota + 1))" ]]
echo 'ok - GraphQL quota marker is shared by both wrappers and expires'

# REST primary exhaustion has its own marker; it blocks REST while leaving
# GraphQL available.
export GH_MODE=rest-quota
rm -f -- "$gql_marker" "$rest_marker"
: > "$GH_CALL_LOG"
if gh api repos/fixture/repo/issues/8124 > /dev/null 2> "$AGENT_HOME/rest-quota.err"; then
  echo 'not ok - REST quota exhaustion unexpectedly succeeded' >&2
  exit 1
else
  quota_rc=$?
fi
[[ "$quota_rc" == 75 ]] || { echo "not ok - REST exhaustion returned rc=$quota_rc, expected 75" >&2; exit 1; }
[[ "$(cat "$rest_marker")" == "$GH_RATE_LIMIT_RESET_EPOCH" ]]
calls_after_quota="$(wc -l < "$GH_CALL_LOG" | tr -d ' ')"
[[ "$calls_after_quota" == 2 ]] || { echo "not ok - REST failure made $calls_after_quota CLI calls, expected one failure and one reset read" >&2; exit 1; }
if gh run list --repo "$REPO" > /dev/null 2> "$AGENT_HOME/rest-backoff.err"; then
  echo 'not ok - REST call escaped the shared REST backoff' >&2
  exit 1
else
  quota_rc=$?
fi
[[ "$quota_rc" == 75 ]]
gh issue list --repo "$REPO" > /dev/null
[[ "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')" == "$((calls_after_quota + 1))" ]]
printf '%s\n' "$(( $(date +%s) - 1 ))" > "$rest_marker"
GH_MODE=unrestricted gh run list --repo "$REPO" > /dev/null
export GH_MODE=unrestricted
echo 'ok - REST quota marker blocks REST without blocking GraphQL and expires'

# Quota lookups must reach gh while both API classes are backed off, but
# ordinary REST and GraphQL calls remain blocked.
printf '%s\n' "$GH_RATE_LIMIT_RESET_EPOCH" > "$gql_marker"
printf '%s\n' "$GH_RATE_LIMIT_RESET_EPOCH" > "$rest_marker"
: > "$GH_CALL_LOG"
gh api rate_limit > /dev/null
gh api graphql -f 'query={rateLimit{remaining}}' > /dev/null
[[ "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')" == 2 ]]
grep -Fqx 'api rate_limit' "$GH_CALL_LOG"
grep -Fqx 'api graphql -f query={rateLimit{remaining}}' "$GH_CALL_LOG"
if gh api repos/x/y > /dev/null 2> "$AGENT_HOME/rest-backoff-lookup.err"; then
  echo 'not ok - ordinary REST call escaped the active backoff' >&2
  exit 1
else
  quota_rc=$?
fi
[[ "$quota_rc" == 75 ]]
if gh pr view 1 > /dev/null 2> "$AGENT_HOME/graphql-backoff-lookup.err"; then
  echo 'not ok - ordinary GraphQL call escaped the active backoff' >&2
  exit 1
else
  quota_rc=$?
fi
[[ "$quota_rc" == 75 ]]
[[ "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')" == 2 ]]
rm -f -- "$gql_marker" "$rest_marker"
echo 'ok - quota lookups reach gh during backoff while ordinary calls stay blocked'

# The scheduler tick file keeps totals while splitting the API classes.
(
  A="$AGENT_HOME/tick-meter"
  GH_ETAG_DIR="$A/.gh-etag"
  mkdir -p "$A" "$GH_ETAG_DIR"
  source "$SCRIPT_DIR/mac-autopilot/scheduler.d/core.sh"
  tick_gh_calls_begin
  gh pr list --repo "$REPO" > /dev/null
  gh issue view 8124 --repo "$REPO" > /dev/null
  gh api graphql -f 'query=query { viewer { login } }' > /dev/null
  gh search issues fixture --repo "$REPO" > /dev/null
  gh api repos/fixture/repo/issues/8124 > /dev/null
  gh run list --repo "$REPO" > /dev/null
  [[ "$(tick_gh_calls_summary)" == 'gh_calls=6 gql=4 rest=2 gh_locked=0' ]] # row 898: the summary carries the tick's under-lock count
)
echo 'ok - scheduler tick metrics split GraphQL and REST calls'
