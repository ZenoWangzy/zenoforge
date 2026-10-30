#!/usr/bin/env bash
# Focused regression for main_merge_clear() against a proxy-cached response.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

assert_true() {
  local desc="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$desc"
  else
    printf 'not ok - %s\n' "$desc" >&2
    return 1
  fi
}

assert_false() {
  local desc="$1"
  shift
  if ! "$@"; then
    printf 'ok - %s\n' "$desc"
  else
    printf 'not ok - %s\n' "$desc" >&2
    return 1
  fi
}

TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-u" && "${2:-}" == "-d" && "${3:-}" == "10 years ago" ]]; then
  count=0
  if [[ -s "$CACHE_DATE_COUNTER" ]]; then
    count="$(cat "$CACHE_DATE_COUNTER")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$CACHE_DATE_COUNTER"
  printf '2016-10-02T00:00:%02dZ\n' "$count"
  exit 0
fi
if [[ "${1:-}" == "-u" && "${2:-}" == "-d" ]]; then
  echo 'main_merge_clear must use the supported ten-year created window' >&2
  exit 9
fi
exec /bin/date "$@"
EOF
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"/actions/runs/990401/jobs?"* ]]; then
  printf '%s\n' '{"total_count":1,"jobs":[{"name":"Postsubmit validate","conclusion":"failure"}]}'
  exit 0
elif [[ "$*" == *"/commits?sha=main"* ]]; then
  printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  exit 0
elif [[ "${1:-} ${2:-}" == 'run view' ]]; then
  case "${MAIN_FIXTURE_RUN_JOBS:-capacity}" in
    capacity) jobs='[{"databaseId":990411,"conclusion":"failure","steps":[{"name":"Checkout","conclusion":"success"},{"name":"Ensure CI runner has capacity before dependency install","conclusion":"failure"},{"name":"Run touched package gates in Dagger","conclusion":"skipped"},{"name":"Run touched Postsubmit integration gates in Dagger","conclusion":"skipped"},{"name":"Run changed integration tests in Dagger","conclusion":"skipped"},{"name":"Test Example Agent hook consumer","conclusion":"skipped"}]}]' ;;
    source) jobs='[{"databaseId":990411,"conclusion":"failure","steps":[{"name":"Ensure CI runner has capacity before dependency install","conclusion":"skipped"},{"name":"Run touched package gates in Dagger","conclusion":"failure"}]}]' ;;
    capacity-source-ran) jobs='[{"databaseId":990411,"conclusion":"failure","steps":[{"name":"Ensure CI runner has capacity before dependency install","conclusion":"failure"},{"name":"Run touched package gates in Dagger","conclusion":"success"}]}]' ;;
    *) jobs='[]' ;;
  esac
  jq -cn --arg head "${MAIN_FIXTURE_HEAD_SHA:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" --argjson jobs "$jobs" '{headSha:$head,status:"completed",conclusion:"failure",jobs:$jobs}'
  exit 0
elif [[ "${1:-} ${2:-}" == 'pr view' ]]; then
  printf '%s\n' '{"baseRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","isDraft":false}'
  exit 0
elif [[ "${1:-} ${2:-}" == 'pr checks' ]]; then
  case "${MAIN_FIXTURE_CHECKS:-pass}" in
    pass) printf '%s\n' '[{"name":"Required CI gates","bucket":"pass"},{"name":"Required contract gates","bucket":"pass"},{"name":"Enforce branch delivery policy","bucket":"pass"},{"name":"Touched packages PR gate","bucket":"pass"}]' ;;
    capacity-failure|source-failure) printf '%s\n' '[{"name":"Required CI gates","bucket":"fail","link":"https://github.com/example-maintainer/example-repo/actions/runs/990410/job/990412"},{"name":"Required contract gates","bucket":"pass"},{"name":"Enforce branch delivery policy","bucket":"pass"},{"name":"NUL bytes & lone negative assertions","bucket":"pass"},{"name":"Example pack PR gate","bucket":"pass"},{"name":"Repo-path regression PR gate","bucket":"pass"},{"name":"Touched packages PR gate","bucket":"fail","link":"https://github.com/example-maintainer/example-repo/actions/runs/990410/job/990411"}]' ;;
    pending) printf '%s\n' '[{"name":"Required CI gates","bucket":"pass"},{"name":"Required contract gates","bucket":"pass"},{"name":"Enforce branch delivery policy","bucket":"pass"},{"name":"Touched packages PR gate","bucket":"pending"}]' ;;
    *) exit 3 ;;
  esac
  exit 0
fi
url=""
for arg in "$@"; do
  if [[ "$arg" == repos/*/actions/workflows/ci.yml/runs* ]]; then
    url="$arg"
  fi
done
expected_endpoint='repos/example-maintainer/example-repo/actions/workflows/ci.yml/runs?branch=main&status=completed&per_page=50&page=1'
if [[ "$url" != *"$expected_endpoint"* ]]; then
  echo 'unexpected gh api endpoint' >&2
  exit 2
fi
args=" $* "
if [[ "$args" == *'-H Cache-Control: no-cache'* && "$args" == *'-H Pragma: no-cache'* \
  && "$url" =~ \&created=%3E%3D[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  cache_key="${url##*&created=}"
  if [[ -f "$CACHE_KEY_LOG" ]] && grep -Fxq -- "$cache_key" "$CACHE_KEY_LOG"; then
    echo 'workflow-run query key repeated' >&2
    exit 4
  fi
  printf '%s\n' "$cache_key" >> "$CACHE_KEY_LOG"
  case "${MAIN_RELEASE_FIXTURE:-success}" in
    success|failure)
      jq -cn --arg conclusion "${MAIN_RELEASE_FIXTURE:-success}" \
        '{workflow_runs:[{event:"push",id:990401,status:"completed",conclusion:$conclusion,created_at:"2026-10-10T00:00:00Z"}]}' ;;
    manual-success|manual-failure)
      jq -cn --arg conclusion "${MAIN_RELEASE_FIXTURE#manual-}" \
        '{workflow_runs:[{id:990401,event:"push",status:"completed",conclusion:"success",created_at:"2026-10-10T00:00:00Z"},
          {id:990406,event:"workflow_dispatch",status:"completed",conclusion:$conclusion,created_at:"2026-10-12T00:00:00Z"},
          {id:990407,event:"pull_request",status:"completed",conclusion:"success",created_at:"2026-10-12T01:00:00Z"}]}' ;;
    in_progress)
      printf '%s\n' '{"workflow_runs":[{"id":990402,"event":"push","status":"in_progress","conclusion":null}]}' ;;
    pending-failure|pending-success|cancelled-failure|cancelled-success)
      jq -cn --arg conclusion "${MAIN_RELEASE_FIXTURE##*-}" \
        '{workflow_runs:[
          {event:"push",id:990404,status:"queued",conclusion:null,created_at:"2026-10-12T03:00:00Z"},
          {event:"push",id:990403,status:"in_progress",conclusion:null,created_at:"2026-10-12T02:00:00Z"},
          {event:"push",id:990402,status:"completed",conclusion:"cancelled",created_at:"2026-10-12T01:00:00Z"},
          {event:"push",id:990401,status:"completed",conclusion:$conclusion,created_at:"2026-10-10T00:00:00Z"}]}' ;;
    cancelled-only)
      printf '%s\n' '{"workflow_runs":[{"event":"push","status":"completed","conclusion":"cancelled"}]}' ;;
    empty)
      printf '%s\n' '{"workflow_runs":[]}' ;;
    invalid)
      printf '%s\n' '{"workflow_runs":{}}' ;;
    error) echo 'simulated GitHub API error' >&2; exit 1 ;;
    *) exit 3 ;;
  esac
else
  # A stable URL without a moving created bound can replay an old failure.
  printf '{"workflow_runs":[{"event":"push","status":"completed","conclusion":"failure"}]}\n'
fi
EOF
chmod +x "$TEST_DIR/bin/gh"
chmod +x "$TEST_DIR/bin/date"

ORIGINAL_PATH="$PATH"
PATH="$TEST_DIR/bin:$PATH"
REPO=example-maintainer/example-repo
export PATH REPO
CACHE_DATE_COUNTER="$TEST_DIR/date-count"
CACHE_KEY_LOG="$TEST_DIR/cache-keys"
export CACHE_DATE_COUNTER CACHE_KEY_LOG
DEPLOY_HOST=fixture
DEPLOY_DIR="$TEST_DIR/deploy"
CARRIED_REGISTRY_FILE="$TEST_DIR/registry.tsv"
printf 'c1\t/app/agent.js\t990405\t/srv/app/backups/h990405/agent.js\n' > "$CARRIED_REGISTRY_FILE"
ssh() { cat "$CARRIED_REGISTRY_FILE"; }

assert_true 'main gate requests a moving fresh key and accepts current success' main_merge_clear
assert_true 'reads in different seconds use different URL cache keys' main_merge_clear
main_merge_clear_quiet() { main_merge_clear 2>/dev/null; }
MAIN_RELEASE_FIXTURE=in_progress
export MAIN_RELEASE_FIXTURE
assert_true 'an in-progress tip does not close the optimistic gate' main_merge_clear
MAIN_RELEASE_FIXTURE=failure
assert_false 'fresh completed failure remains blocked' main_merge_clear_quiet
MAIN_RELEASE_FIXTURE=error
assert_false 'GitHub API error remains fail-closed' main_merge_clear_quiet

MAIN_RELEASE_FIXTURE=failure
MAIN_FIXTURE_CHECKS=capacity-failure
MAIN_FIXTURE_RUN_JOBS=capacity
export MAIN_RELEASE_FIXTURE MAIN_FIXTURE_CHECKS MAIN_FIXTURE_RUN_JOBS
assert_false 'fresh completed main failure is available to the fix-forward assessor' main_merge_clear_quiet
assert_true 'the recognized shared capacity check remains failed' test \
  "$(pr_checks_outcome "$(gh pr checks 990405 --repo "$REPO" --json name,bucket,link)")" = fail
MAIN_FIXTURE_HEAD_SHA=cccccccccccccccccccccccccccccccccccccccc
export MAIN_FIXTURE_HEAD_SHA
assert_false 'a linked Touched gate from another PR head cannot use the carried exception' \
  main_fix_forward_prepare_for_pr 990405
unset MAIN_FIXTURE_HEAD_SHA

printf 'c1\t/app/agent.js\t990406\t/srv/app/backups/h990406/agent.js\n' > "$CARRIED_REGISTRY_FILE"
assert_false 'unregistered PR cannot use carried exception' main_fix_forward_prepare_for_pr 990405
printf 'malformed registry row\n' > "$CARRIED_REGISTRY_FILE"
assert_false 'malformed carried registry remains unknown and refuses exception' main_fix_forward_prepare_for_pr 990405

printf 'c1\t/app/agent.js\t990405\t/srv/app/backups/h990405/agent.js\n' > "$CARRIED_REGISTRY_FILE"
MAIN_FIXTURE_RUN_JOBS=source
assert_false 'source-test failure does not use shared-capacity exception' main_fix_forward_prepare_for_pr 990405
MAIN_FIXTURE_RUN_JOBS=capacity-source-ran
assert_false 'capacity failure does not excuse source validation that ran' main_fix_forward_prepare_for_pr 990405
MAIN_FIXTURE_CHECKS=pending
MAIN_FIXTURE_RUN_JOBS=capacity
assert_false 'pending PR check does not use carried exception' main_fix_forward_prepare_for_pr 990405
MAIN_FIXTURE_CHECKS=pass
unset DEPLOY_HOST DEPLOY_DIR MAIN_FIXTURE_CHECKS MAIN_FIXTURE_RUN_JOBS

for scenario in pending-failure cancelled-failure; do
  MAIN_RELEASE_FIXTURE="$scenario"
  assert_false "$scenario keeps main red" main_merge_clear_quiet
  assert_true "$scenario selects the completed failure" test "$(jq -r '.id' <<< "$MAIN_RELEASE_RUN_JSON")" = 990401
  assert_true "$scenario admits covered current-base fix-forward" main_fix_forward_prepare_for_pr 990405
done
for scenario in pending-success cancelled-success; do
  MAIN_RELEASE_FIXTURE="$scenario"
  assert_true "$scenario keeps completed success ready" main_merge_clear
  assert_false "$scenario never admits fix-forward" main_fix_forward_prepare_for_pr 990405
done
MAIN_RELEASE_FIXTURE=cancelled-only
assert_true 'cancelled-only history has no completed red verdict' main_merge_clear
assert_false 'no usable verdict refuses fix-forward' main_fix_forward_prepare_for_pr 990405

MAIN_RELEASE_FIXTURE=empty
assert_true 'no completed main verdict leaves the optimistic merge gate open' main_merge_clear
MAIN_RELEASE_FIXTURE=invalid
assert_false 'an invalid Actions response fails the merge gate closed' main_merge_clear_quiet


MAIN_RELEASE_FIXTURE=manual-success
assert_true 'completed main dispatch supplies a green merge verdict' main_merge_clear
MAIN_RELEASE_FIXTURE=manual-failure
assert_false 'newer failed main dispatch cannot inherit old green push' main_merge_clear_quiet
assert_true 'PR event cannot override main verdict' test "$(jq -r '.id' <<< "$MAIN_RELEASE_RUN_JSON")" = 990406

PATH="$ORIGINAL_PATH"
unset MAIN_RELEASE_FIXTURE ORIGINAL_PATH CACHE_DATE_COUNTER CACHE_KEY_LOG
