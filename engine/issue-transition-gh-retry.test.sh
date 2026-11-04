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
: > "$GH_CALL_LOG"
: > "$GH_SLEEP_LOG"

cat > "$test_env_bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_CALL_LOG"
if [[ "$GH_MODE" == retry502 ]]; then
  echo 'gh: Bad Gateway (HTTP 502)' >&2
  exit 1
fi
if [[ "$GH_MODE" == complexity ]] || { [[ "$GH_MODE" == rest && "$1 $2 ${3:-}" == 'issue view 5314' ]]; }; then
  for _ in $(seq 1 300); do echo 'Resource limits for this query exceeded.' >&2; done
  exit 1
fi
if [[ "$GH_MODE" == rest && "$1 $2 ${3:-}" == 'issue view 8124' ]]; then
  echo CLOSED
  exit 0
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
      echo '[[{"name":"needs-triage"},{"name":"focus"}]]'
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

# The read-side GraphQL failure must not block a transition label write: the
# guarded transition writes its complete label set through the REST labels API.
export ZF_REPO=fixture/repo
export GH_MODE=rest
: > "$GH_CALL_LOG"
: > "$GH_SLEEP_LOG"
roadmap_ensure_issue_parent() { :; }
ensure_state_labels() { :; }
state_merge 5314 '{"state":"needs-triage","recut_children":[8124]}'
OPEN_ISSUE_BLOCKER_GRAPH_JSON='[{"number":8124,"state":"CLOSED"}]' \
  issue_transition 5314 ready-for-agent focused-rest-label-write 2> "$AGENT_HOME/transition.err"
jq -e '.labels | index("ready-for-agent") != null and index("focus") != null and index("needs-triage") == null' \
  "$GH_LABELS_OUT" >/dev/null
grep -Fq 'api --paginate --slurp --method GET repos/fixture/repo/issues/5314/labels' "$GH_CALL_LOG"
grep -Fq 'api --method PUT repos/fixture/repo/issues/5314/labels' "$GH_CALL_LOG"
if grep -Fq 'issue edit 5314' "$GH_CALL_LOG"; then
  echo 'not ok - transition used the GraphQL issue-edit write' >&2
  exit 1
fi
[[ "$(state_read 5314 | jq -r '.state')" == ready-for-agent ]]
[[ "$(grep -Fc 'issue view 5314 --repo fixture/repo --json labels' "$GH_CALL_LOG")" == 1 ]]
grep -Fq 'issue view failed for #5314' "$AGENT_HOME/transition.err"
echo 'ok - REST label replacement succeeds when the GraphQL label guard degrades'
