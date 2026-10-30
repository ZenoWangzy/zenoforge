#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
export ZF_REPO=test/repo ZF_GH_REPO=test/repo AGENT_DRY_RUN=0
export ZF_ROADMAP_TREE_CACHE_FILE="$AGENT_HOME/roadmap-tree.json"
jq '.switches["roadmap-order"] = true | .roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$AGENT_HOME/model-policy.json"
cat > "$ZF_ROADMAP_TREE_CACHE_FILE" <<'JSON'
{"roots":[{"number":900,"title":"the product Roadmap","state":"OPEN","labels":["roadmap"],"children":[{"number":901,"title":"Platform","state":"OPEN","labels":["roadmap-theme"],"children":[{"number":902,"title":"待归类","state":"OPEN","labels":["roadmap-epic"],"children":[]}]},{"number":910,"title":"开发流水线与运行稳定","state":"OPEN","milestone":"开发流水线与运行稳定","labels":["roadmap-theme"],"children":[{"number":912,"title":"Automated dispatch rule validation","state":"OPEN","labels":["roadmap-epic"],"children":[]},{"number":914,"title":"待归类","state":"OPEN","labels":["roadmap-epic"],"children":[]}]}]}]}
JSON
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

# The shipped policy lists no known flakes; the signature state file carries the two this suite exercises.
mkdir -p "$STATE_DIR"
jq -n '{version:1,occurrences:[],signatures:[
  {issue:3176,signature:"57P01 terminating connection due to administrator command",requires_passed_tests:true},
  {issue:3171,test:"order-correction",bound_ms:2000}]}' > "$STATE_DIR/ci-flake-signatures.json"

tmp="$test_env_root/ci-flake"
mkdir -p "$tmp/bin" "$tmp/logs"
export FAKE_CI_FLAKE="$tmp"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
args=" $* "
case "${1:-}:${2:-}" in
  run:view)
    run="${3:-}"
    if [[ "$args" == *" --json jobs "* ]]; then
      cat "$FAKE_CI_FLAKE/jobs-$run.json"
    elif [[ "$args" == *" --json attempt "* ]]; then
      cat "$FAKE_CI_FLAKE/attempt-$run"
    elif [[ "$args" == *" --job "* && "$args" == *" --log-failed "* ]]; then
      job=""
      previous=""
      for arg in "$@"; do
        [ "$previous" != --job ] || job="$arg"
        previous="$arg"
      done
      cat "$FAKE_CI_FLAKE/logs/$run-$job.log"
    else
      exit 2
    fi
    ;;
  run:rerun)
    printf '%s\n' "$*" >> "$FAKE_CI_FLAKE/mutations"
    ;;
  issue:edit)
    printf '%s\n' "$*" >> "$FAKE_CI_FLAKE/issue-edits"
    issue="${3:-}"
    previous=""
    for arg in "$@"; do
      if [[ "$previous" == --add-label ]]; then
        jq --argjson n "$issue" --arg name "$arg" \
          'map(if .number == $n then .labels |= (map(select(.name != $name)) + [{name:$name}]) else . end)' \
          "$FAKE_CI_FLAKE/issues.json" > "$FAKE_CI_FLAKE/issues.next"
        mv "$FAKE_CI_FLAKE/issues.next" "$FAKE_CI_FLAKE/issues.json"
      fi
      previous="$arg"
    done
    ;;
  issue:view)
    issue="${3:-}"
    # Created issues come back with their title, body and labels, as GitHub returns them; roadmap placement reads the labels.
    jq -c --argjson n "$issue" --arg state "$(jq -r --arg n "$issue" '.[$n] // "OPEN"' "$FAKE_CI_FLAKE/issue-states.json")" \
      '(map(select(.number == $n))[0] // {}) + {state:$state}' "$FAKE_CI_FLAKE/issues.json"
    ;;
  issue:list)
    cat "$FAKE_CI_FLAKE/issues.json"
    ;;
  issue:create)
    title="" body="" label_one="" label_two="" previous=""
    for arg in "$@"; do
      case "$previous" in
        --title) title="$arg" ;;
        --body) body="$arg" ;;
        --label) if [[ -z "$label_one" ]]; then label_one="$arg"; else label_two="$arg"; fi ;;
      esac
      previous="$arg"
    done
    issue="$(cat "$FAKE_CI_FLAKE/next-issue")"
    printf '%s\n' "$((issue + 1))" > "$FAKE_CI_FLAKE/next-issue"
    jq --argjson n "$issue" --arg title "$title" --arg body "$body" --arg label1 "$label_one" --arg label2 "$label_two" \
      '. + [{number:$n,title:$title,body:$body,labels:([$label1,$label2] | map(select(length > 0)) | map({name:.}))}]' \
      "$FAKE_CI_FLAKE/issues.json" > "$FAKE_CI_FLAKE/issues.next"
    mv "$FAKE_CI_FLAKE/issues.next" "$FAKE_CI_FLAKE/issues.json"
    printf 'https://github.com/test/repo/issues/%s\n' "$issue"
    ;;
  api:*)
    if [[ "$args" == *" --jq "* ]]; then
      issue="${2##*/}"
      printf '%s\n' "$((100000 + issue))"
    elif [[ "$args" == *" --method POST "* && "$args" == *"/sub_issues "* ]]; then
      printf '%s\n' "$*" >> "$FAKE_CI_FLAKE/roadmap-links"
    else
      exit 2
    fi
    ;;
  issue:comment)
    printf '%s\n' "$*" >> "$FAKE_CI_FLAKE/comments"
    ;;
  *) exit 2 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
printf '{}\n' > "$tmp/issue-states.json"
printf '[]\n' > "$tmp/issues.json"
printf '9001\n' > "$tmp/next-issue"
: > "$tmp/mutations"
: > "$tmp/comments"

assert_eq() {
  [[ "$2" == "$3" ]] || { echo "not ok - $1 (expected $2, got $3)" >&2; exit 1; }
  echo "ok - $1"
}
assert_contains() {
  [[ "$2" == *"$3"* ]] || { echo "not ok - $1 (missing $3)" >&2; exit 1; }
  echo "ok - $1"
}
run_flake() {
  local run="$1" job_json="$2" log="$3" attempt="${4:-1}" issue="${5:-3127}" status=0
  printf '%s\n' "$job_json" > "$tmp/jobs-$run.json"
  printf '%s\n' "$attempt" > "$tmp/attempt-$run"
  while IFS=$'\t' read -r job name; do
    [[ -n "$job" ]] || continue
    printf '%s\n' "$log" > "$tmp/logs/$run-$job.log"
  done < <(jq -r '.[] | select(.conclusion=="failure") | [.databaseId,.name] | @tsv' <<< "$job_json")
  ci_run_is_retryable_infra_failure "$run" "$issue" "$issue" 1 || status=$?
  return "$status"
}

# Recorded #3127/#3179 evidence: all test counts passed, then Vitest reported
# one unhandled PostgreSQL 57P01 error and failed the job.
known_log=$'Test Files 38 passed (38)\nTests 417 passed (417)\n1 unhandled error\n57P01 terminating connection due to administrator command'
one_failed='[{"databaseId":11,"name":"Example pack PR gate","conclusion":"failure","steps":[{"name":"Run tests","conclusion":"failure"}]}]'
if run_flake 38029158406 "$one_failed" "$known_log" 1 3127; then status=0; else status=$?; fi
assert_eq 'open known 57P01 signature is retryable' 0 "$status"
assert_contains 'known signature reruns failed jobs once' "$(cat "$tmp/mutations")" 'run rerun 38029158406 --repo test/repo --failed'
assert_contains 'known occurrence is recorded with PR and run' "$(cat "$tmp/comments")" 'run=38029158406 pr=3127'
assert_contains 'known occurrence is posted to matching issue' "$(cat "$tmp/comments")" 'issue comment 3176'

# Same output shape with an unseen error files one issue and stays blocking.
new_log=$'Test Files 6 passed (6)\nTests 22 passed (22)\n1 unhandled error\nError: ECONNRESET from test worker'
if run_flake 38029158407 "$one_failed" "$new_log" 1 3128; then status=0; else status=$?; fi
assert_eq 'new all-passed signature remains a check failure' 1 "$status"
assert_eq 'new signature files exactly one issue' 1 "$(jq 'length' "$tmp/issues.json")"
jq -e '([.[0].labels[].name] | sort) == ["needs-triage","pipeline-system"] and (.[0].body | contains("38029158407") and contains("PR #3128"))' \
  "$tmp/issues.json" >/dev/null
assert_contains 'new issue is linked to the fallback roadmap epic' "$(cat "$tmp/roadmap-links")" \
  'api repos/test/repo/issues/914/sub_issues --method POST -F sub_issue_id=109001 -F replace_parent=true'
if run_flake 38029158408 "$one_failed" "$new_log" 1 3129; then status=0; else status=$?; fi
assert_eq 'second occurrence uses new open signature instead of filing another issue' 0 "$status"
assert_eq 'one issue remains for repeated signature' 1 "$(jq 'length' "$tmp/issues.json")"
assert_eq 'repeated occurrence does not route a duplicate issue' 1 "$(wc -l < "$tmp/roadmap-links")"

# Existing known test-name signature can retry its one failed test.
test_log=$'Tests 2 passed, 1 failed (3)\nFAIL tests/order-correction.test.ts > order-correction\norder-correction exceeded 2000 ms'
if run_flake 38029158409 "$one_failed" "$test_log" 1 3130; then status=0; else status=$?; fi
assert_eq 'open known test-name signature retries' 0 "$status"
assert_contains 'known test occurrence is posted to issue 3171' "$(cat "$tmp/comments")" 'issue comment 3171'

# Known signature does not excuse a genuine test failure or a closed issue.
real_log=$'Test Files 1 failed (1)\nTests 0 passed, 1 failed (1)\nFAIL tests/orders.test.ts > rejects invalid order\n57P01 terminating connection due to administrator command'
before="$(wc -l < "$tmp/mutations")"
if run_flake 38029158410 "$one_failed" "$real_log" 1 3131; then status=0; else status=$?; fi
assert_eq 'real failed test is never retried under matching error text' 1 "$status"
assert_eq 'real failure adds no rerun' "$before" "$(wc -l < "$tmp/mutations")"
ansi_unrelated_log=$'\e[31m FAIL tests/orders.test.ts > rejects invalid order\e[0m\norder-correction exceeded 2000 ms'
before="$(wc -l < "$tmp/mutations")"
if run_flake 38029158413 "$one_failed" "$ansi_unrelated_log" 1 3134; then status=0; else status=$?; fi
assert_eq 'ANSI-colored unrelated failure cannot match a known test name elsewhere' 1 "$status"
assert_eq 'ANSI-colored real failure adds no rerun' "$before" "$(wc -l < "$tmp/mutations")"
jq '. + {"3176":"CLOSED"}' "$tmp/issue-states.json" > "$tmp/closed.json"
mv "$tmp/closed.json" "$tmp/issue-states.json"
before="$(wc -l < "$tmp/mutations")"
if run_flake 38029158411 "$one_failed" "$known_log" 1 3132; then status=0; else status=$?; fi
assert_eq 'closed flake issue stops tolerance' 1 "$status"
assert_eq 'closed signature adds no rerun' "$before" "$(wc -l < "$tmp/mutations")"

# A known flake cannot mask a second failed job in the same run.
jq '. + {"3176":"OPEN"}' "$tmp/issue-states.json" > "$tmp/open.json"
mv "$tmp/open.json" "$tmp/issue-states.json"
two_failed='[{"databaseId":11,"name":"Known flake","conclusion":"failure","steps":[{"name":"Run tests","conclusion":"failure"}]},{"databaseId":12,"name":"Real failure","conclusion":"failure","steps":[{"name":"Run tests","conclusion":"failure"}]}]'
printf '%s\n' "$two_failed" > "$tmp/jobs-38029158412.json"
printf '1\n' > "$tmp/attempt-38029158412"
printf '%s\n' "$known_log" > "$tmp/logs/38029158412-11.log"
printf '%s\n' "$real_log" > "$tmp/logs/38029158412-12.log"
before="$(wc -l < "$tmp/mutations")"
if ci_run_is_retryable_infra_failure 38029158412 3133 3133 1; then status=0; else status=$?; fi
assert_eq 'mixed known and real failed jobs remain blocking' 1 "$status"
assert_eq 'mixed failures rerun no jobs' "$before" "$(wc -l < "$tmp/mutations")"

echo 'ci-flake-classification.test.sh: PASS'
