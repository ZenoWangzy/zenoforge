#!/usr/bin/env bash
# Regression coverage for #1565. These bodies are the actual PR #1557 and
# #1559 bodies that prematurely closed #1443 and #1449. The fake gh seam
# supplies their labels as they stood when the closing keyword mattered.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/closing-keyword-gate.sh"

FAILED=0
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
    echo "not ok - $desc (expected not to find [$needle])"
    FAILED=1
  fi
}

CI_WORKFLOW="$SCRIPT_DIR/../.github/workflows/ci.yml"
CI_TEXT="$(<"$CI_WORKFLOW")"
assert_contains "all-PR CI gate invokes the closing-keyword checker" "$CI_TEXT" \
  'bash "$PIPELINE_ENGINE_DIR/closing-keyword-gate.sh" --body-file "$body_file"'
assert_contains "all-PR CI gate can read issue evidence" "$CI_TEXT" 'issues: read'
assert_contains "all-PR CI backfills the checker for older branches" "$CI_TEXT" \
  'for f in scripts/repo-path-ownership.mjs "$PIPELINE_ENGINE_DIR/closing-keyword-gate.sh" scripts/ci/install-dagger.sh scripts/ci/dagger-pin.json; do'
assert_contains "all-PR CI reads branch commit messages" "$CI_TEXT" \
  'git log --format=%B "${base_sha}..HEAD" > "$commit_messages_file"'
assert_contains "all-PR CI passes commit messages to the checker" "$CI_TEXT" \
  '--commits-file "$commit_messages_file"'
BACKFILL_LINE="$(grep -nF 'for f in scripts/repo-path-ownership.mjs "$PIPELINE_ENGINE_DIR/closing-keyword-gate.sh" scripts/ci/install-dagger.sh scripts/ci/dagger-pin.json; do' "$CI_WORKFLOW" | cut -d: -f1)"
GATE_LINE="$(grep -nF 'bash "$PIPELINE_ENGINE_DIR/closing-keyword-gate.sh" --body-file "$body_file"' "$CI_WORKFLOW" | cut -d: -f1)"
if [ "$BACKFILL_LINE" -lt "$GATE_LINE" ]; then
  echo "ok - all-PR CI backfills the checker before invoking it"
else
  echo "not ok - all-PR CI invokes the checker before its backfill"
  FAILED=1
fi

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/issues"

write_issue() {
  local number="$1" json="$2"
  printf '%s\n' "$json" > "$TEST_ROOT/issues/$number.json"
}

write_issue 1443 '{"labels":[{"name":"on-hold"},{"name":"evidence-gate"}],"comments":[]}'
write_issue 1449 '{"labels":[{"name":"evidence-gate"}],"comments":[]}'
write_issue 2001 '{"labels":[{"name":"evidence-gate"}],"comments":[{"body":"## Real-user-path acceptance: PASS\n\nURL: https://example.example/chat/\nDOM: composer is visible and interactive\nNetwork: same-run GET /chat/api/v1/auths/ -> 200 application/json"}]}'
write_issue 4001 '{"title":"complete change","labels":[],"comments":[]}'
write_issue 3001 '{"title":"hold residue","labels":[{"name":"on-hold"}],"comments":[]}'
write_issue 3002 '{"title":"evidence residue","labels":[{"name":"evidence-gate"}],"comments":[]}'
write_issue 3003 '{"title":"accepted residue","labels":[{"name":"evidence-gate"}],"comments":[{"body":"## Real-user-path acceptance: PASS\n\nURL: https://example.example/chat/\nDOM: composer is visible\nNetwork: same-run GET /chat/api/v1/auths/ -> 200"}]}'

printf '%s\n' '[{"number":3001},{"number":1443}]' > "$TEST_ROOT/issues/closed-on-hold.json"
printf '%s\n' '[{"number":3002},{"number":3003}]' > "$TEST_ROOT/issues/closed-evidence-gate.json"

cat > "$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "issue view")
    number="${3:-}"
    if [ "$number" = "9999" ]; then
      echo "simulated gh read failure" >&2
      exit 1
    fi
    cat "$FAKE_GH_FIXTURES/$number.json"
    ;;
  "issue list")
    label=""
    previous=""
    for arg in "$@"; do
      if [ "$previous" = "--label" ]; then
        label="$arg"
      fi
      previous="$arg"
    done
    case "$label" in
      on-hold) cat "$FAKE_GH_FIXTURES/closed-on-hold.json" ;;
      evidence-gate) cat "$FAKE_GH_FIXTURES/closed-evidence-gate.json" ;;
      *) echo "unexpected label: $label" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/gh"

export PATH="$TEST_ROOT/bin:$PATH"
export FAKE_GH_FIXTURES="$TEST_ROOT/issues"
export GITHUB_REPOSITORY="test/repo"

run_gate() {
  set +e
  RUN_OUTPUT="$(bash "$GATE" "$@" 2>&1)"
  RUN_STATUS=$?
  set -e
}

PR_1557_BODY="$TEST_ROOT/pr-1557.md"
printf '%s\n' \
  'Fixes #1443' \
  '' \
  '- Restore composer focus after an image enters the existing attachment path.' \
  '- Give the native submit button an accessible name.' \
  '- Preserve zero-text attachment submission; no Example or status-chain changes.' \
  '' \
  'Validation:' \
  '- pnpm --filter @agent-runtime/example-service exec vitest run src/routes/agent-ui-proxy.test.ts (76 passed)' \
  '- pnpm --filter @agent-runtime/example-service typecheck' \
  '- fixed-SHA review: READY' > "$PR_1557_BODY"

run_gate --body-file "$PR_1557_BODY"
assert_eq "actual PR #1557 body refuses #1443" "1" "$RUN_STATUS"
assert_contains "#1443 names the on-hold condition" "$RUN_OUTPUT" \
  '#1443 closing keyword refused: issue is labelled on-hold'
assert_contains "#1443 names its missing acceptance evidence" "$RUN_OUTPUT" \
  '#1443 closing keyword refused: issue is labelled evidence-gate but lacks recorded passing real-user-path acceptance evidence'

PR_1559_BODY="$TEST_ROOT/pr-1559.md"
printf '%s\n' \
  '## UX-07 login path only' \
  '' \
  'Fixes #1449 login cold-start half; does not change Admin↔Chat handoff or composer behavior.' \
  '' \
  '- Remove duplicate Nginx body rewrite config from local/dev reference; production counterpart: example-org/example-infra#95.' \
  '- Add isolated `LOGIN_ONLY` production probe. It rejects a shared browser, uses a temporary profile, and passes the requested proxy to the browser.' \
  '- Define static baseline: cold network-fetched `/chat/` JS/CSS must finish successfully, each within 6s and final response within 6s after URL change.' \
  '- Guard against duplicate Nginx rewriter regression.' \
  '' \
  '## Evidence' \
  '' \
  '- Production red before deploy, isolated profile: URL 4548ms; composer 12460ms; JS/CSS tail 6123ms; 12s gate failed.' \
  '- `agent-ui-proxy.test.ts`: 75/75 pass.' \
  '- Nginx contract, shell syntax, Node syntax, credential scan, branch preflight pass.' \
  '- Fixed-SHA review and targeted re-review: READY.' \
  '' \
  'Deployment and post-deploy production measurement follow merged app + infra changes.' > "$PR_1559_BODY"

run_gate --body-file "$PR_1559_BODY"
assert_eq "actual PR #1559 body refuses #1449" "1" "$RUN_STATUS"
assert_contains "#1449 names its missing acceptance evidence" "$RUN_OUTPUT" \
  '#1449 closing keyword refused: issue is labelled evidence-gate but lacks recorded passing real-user-path acceptance evidence'
assert_contains "#1449 names its self-declared incompleteness" "$RUN_OUTPUT" \
  '#1449 closing keyword refused: PR body declares incomplete work'

PASSING_BODY="$TEST_ROOT/passing.md"
printf '%s\n' 'Closes #2001' > "$PASSING_BODY"
run_gate --body-file "$PASSING_BODY"
assert_eq "recorded three-part acceptance evidence permits a legitimate close" "0" "$RUN_STATUS"
assert_contains "legitimate close reports pass" "$RUN_OUTPUT" "closing keyword evidence gate passed"

CHECK_ONLY_BODY="$TEST_ROOT/check-only.md"
COMMIT_MESSAGES="$TEST_ROOT/check-only-commits.md"
printf '%s\n' \
  'This is the only command reported here: restart-when-idle --check-only exited0' > "$CHECK_ONLY_BODY"
printf '%s\n' 'Fixes #4001' > "$COMMIT_MESSAGES"
run_gate --body-file "$CHECK_ONLY_BODY" --commits-file "$COMMIT_MESSAGES"
assert_eq "check-only evidence in body does not block commit closing keyword" "0" "$RUN_STATUS"
assert_contains "body plus commit closing reference reports pass" "$RUN_OUTPUT" "closing keyword evidence gate passed"

ONLY_HALF_BODY="$TEST_ROOT/only-half.md"
printf '%s\n' 'Fixes #4001' 'Only half fixed; follow-up work remains.' > "$ONLY_HALF_BODY"
run_gate --body-file "$ONLY_HALF_BODY"
assert_eq "only half fixed still refuses closing keyword" "1" "$RUN_STATUS"
assert_contains "only half fixed names incomplete work" "$RUN_OUTPUT" \
  '#4001 closing keyword refused: PR body declares incomplete work'

INCOMPLETE_BODY="$TEST_ROOT/incomplete.md"
printf '%s\n' 'Fixes #4001' 'This change remains incomplete.' > "$INCOMPLETE_BODY"
run_gate --body-file "$INCOMPLETE_BODY"
assert_eq "incomplete work still refuses closing keyword" "1" "$RUN_STATUS"

SCOPE_STATEMENT_BODY="$TEST_ROOT/scope-statement.md"
printf '%s\n' 'Fixes #4001' \
  '已记录费用降低费用后净利，不改变毛利；仅提示实际缺记录的科目。' \
  'This covers partial-period expenses and does not change gross profit.' > "$SCOPE_STATEMENT_BODY"
run_gate --body-file "$SCOPE_STATEMENT_BODY"
assert_eq "recorded expense and unchanged gross profit scope does not refuse closing keyword" "0" "$RUN_STATUS"
assert_contains "scope statement reports a passing close" "$RUN_OUTPUT" \
  "closing keyword evidence gate passed"

EXPLICIT_INCOMPLETE_BODY="$TEST_ROOT/explicit-incomplete.md"
printf '%s\n' 'Fixes #4001' \
  'This PR does not implement the requested expense detail yet.' \
  '本次仅实现部分费用明细，剩余部分尚未完成。' > "$EXPLICIT_INCOMPLETE_BODY"
run_gate --body-file "$EXPLICIT_INCOMPLETE_BODY"
assert_eq "explicitly unimplemented requested work still refuses closing keyword" "1" "$RUN_STATUS"
assert_contains "explicitly incomplete work explains refusal" "$RUN_OUTPUT" \
  '#4001 closing keyword refused: PR body declares incomplete work'

PARTIAL_WORK_BODY="$TEST_ROOT/partial-work.md"
printf '%s\n' 'Fixes #4001' 'The implementation remains partial.' > "$PARTIAL_WORK_BODY"
run_gate --body-file "$PARTIAL_WORK_BODY"
assert_eq "explicitly partial implementation still refuses closing keyword" "1" "$RUN_STATUS"

FOLLOW_ON_BODY="$TEST_ROOT/follow-on.md"
printf '%s\n' 'Fixes #4001' \
  'Deployment and post-deploy production measurement follow merged app + infra changes.' > "$FOLLOW_ON_BODY"
run_gate --body-file "$FOLLOW_ON_BODY"
assert_eq "real follow-on dependency still refuses closing keyword" "1" "$RUN_STATUS"

REFS_BODY="$TEST_ROOT/refs.md"
printf '%s\n' 'Refs #4001' > "$REFS_BODY"
run_gate --body-file "$REFS_BODY"
assert_eq "Refs reference alone does not close issue" "0" "$RUN_STATUS"

QUALIFIED_REPO_BODY="$TEST_ROOT/qualified-repo.md"
printf '%s\n' 'Fixes test/repo#1449' > "$QUALIFIED_REPO_BODY"
run_gate --body-file "$QUALIFIED_REPO_BODY"
assert_eq "qualified repo closing reference refuses #1449" "1" "$RUN_STATUS"
assert_contains "qualified repo reference names #1449 missing acceptance evidence" "$RUN_OUTPUT" \
  '#1449 closing keyword refused: issue is labelled evidence-gate but lacks recorded passing real-user-path acceptance evidence'

QUALIFIED_URL_BODY="$TEST_ROOT/qualified-url.md"
printf '%s\n' 'Resolves https://github.com/test/repo/issues/1449' > "$QUALIFIED_URL_BODY"
run_gate --body-file "$QUALIFIED_URL_BODY"
assert_eq "qualified URL closing reference refuses #1449" "1" "$RUN_STATUS"
assert_contains "qualified URL reference names #1449 missing acceptance evidence" "$RUN_OUTPUT" \
  '#1449 closing keyword refused: issue is labelled evidence-gate but lacks recorded passing real-user-path acceptance evidence'

COMMIT_CLOSING_BODY="$TEST_ROOT/commit-closing-body.md"
COMMIT_MESSAGES="$TEST_ROOT/commit-messages.md"
printf '%s\n' 'No closing reference in this PR body.' > "$COMMIT_CLOSING_BODY"
printf '%s\n' 'Fixes #1449' > "$COMMIT_MESSAGES"
run_gate --body-file "$COMMIT_CLOSING_BODY" --commits-file "$COMMIT_MESSAGES"
assert_eq "branch commit closing keyword refuses #1449" "1" "$RUN_STATUS"
assert_contains "branch commit names #1449 missing acceptance evidence" "$RUN_OUTPUT" \
  '#1449 closing keyword refused: issue is labelled evidence-gate but lacks recorded passing real-user-path acceptance evidence'

READ_FAILURE_BODY="$TEST_ROOT/read-failure.md"
printf '%s\n' 'Resolves #9999' > "$READ_FAILURE_BODY"
run_gate --body-file "$READ_FAILURE_BODY"
assert_eq "unreadable issue fails closed" "1" "$RUN_STATUS"
assert_contains "unreadable issue explains refusal" "$RUN_OUTPUT" \
  '#9999 closing keyword refused: cannot read labels and acceptance evidence'

run_gate --sweep-closed
assert_eq "closed residue sweep is report-only" "0" "$RUN_STATUS"
assert_contains "sweep reports on-hold residue" "$RUN_OUTPUT" "#3001 hold residue"
assert_contains "sweep reports evidence-gate residue" "$RUN_OUTPUT" "#3002 evidence residue"
assert_not_contains "sweep omits accepted issue" "$RUN_OUTPUT" "#3003 accepted residue"
assert_not_contains "sweep excludes separately handled #1443" "$RUN_OUTPUT" "#1443"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi

echo "ALL PASS"
