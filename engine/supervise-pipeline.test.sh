#!/usr/bin/env bash
# Regression tests for supervise-pipeline.sh. Plain bash assertions, no
# framework -- same shape as detect-label-churn.test.sh: fake `gh`/
# `journalctl`/`rg` binaries shadowing the real binaries on PATH, driven by
# env vars per scenario, and a fresh AGENT_HOME per run so state/spend
# fixtures never touch the real pipeline's files.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR_SRC="$SCRIPT_DIR/supervise-pipeline.sh"
FAKE_REAL_GIT_BIN="$(type -P git)"
CHECK_HAND_DISPATCHES_FN="$(sed -n '/^check_hand_dispatches() {/,/^}/p' "$SUPERVISOR_SRC")"

FAILED=0
TMP_DIRS=()
cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

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
    echo "not ok - $desc (expected NOT to find [$needle])"
    FAILED=1
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected [$expected], got [$actual])"
    FAILED=1
  fi
}

assert_ne() {
  local desc="$1" unexpected="$2" actual="$3"
  if [ "$unexpected" != "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (did not expect [$unexpected])"
    FAILED=1
  fi
}

# Empty PR metadata must use check_stalled_prs' existing "age zero" fallback.
source "$SCRIPT_DIR/lib.sh"
DEPLOYMENT_BUILD_RESULT_FN="$(sed -n '/^record_build_result_on_issues() {/,/^}/p' "$SUPERVISOR_SRC")"
DEPLOYMENT_BUILD_FIXTURE="$(mktemp -d)"
TMP_DIRS+=("$DEPLOYMENT_BUILD_FIXTURE")
command git init -q -b main "$DEPLOYMENT_BUILD_FIXTURE/repo"
command git -C "$DEPLOYMENT_BUILD_FIXTURE/repo" -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet --allow-empty -m deployed
DEPLOYMENT_BUILD_BASE="$(command git -C "$DEPLOYMENT_BUILD_FIXTURE/repo" rev-parse HEAD)"
command git -C "$DEPLOYMENT_BUILD_FIXTURE/repo" -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet --allow-empty -m candidate
DEPLOYMENT_BUILD_HEAD="$(command git -C "$DEPLOYMENT_BUILD_FIXTURE/repo" rev-parse HEAD)"
mkdir -p "$DEPLOYMENT_BUILD_FIXTURE/bin"
cat > "$DEPLOYMENT_BUILD_FIXTURE/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$2" in
  repos/*/deployments\?environment=production\&per_page=1)
    jq -cn --arg sha "$FAKE_DEPLOYMENT_SHA" '[{id:1,sha:$sha,payload:{sha:$sha,images:{"example-admin":"sha256:test"},image_shas:{"example-admin":$sha}}}]' ;;
  repos/*/deployments/1/statuses) echo '[{"state":"success","created_at":"2026-10-24T00:00:00Z"}]' ;;
  *) echo "unexpected fake deployment API call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$DEPLOYMENT_BUILD_FIXTURE/bin/gh"
DEPLOYMENT_BUILD_RANGE="$DEPLOYMENT_BUILD_FIXTURE/range"
(
  export REPO=test/repo REPO_DIR="$DEPLOYMENT_BUILD_FIXTURE/repo"
  export FAKE_DEPLOYMENT_SHA="$DEPLOYMENT_BUILD_BASE" PATH="$DEPLOYMENT_BUILD_FIXTURE/bin:$PATH"
  eval "$DEPLOYMENT_BUILD_RESULT_FN"
  issue_numbers_in_range() { printf '%s\n' "$1" > "$DEPLOYMENT_BUILD_RANGE"; echo 2001; }
  issue_has_live_unit() { return 1; }
  state_merge() { return 0; }
  record_env_fault() { return 0; }
  finding() { return 0; }
  route_to_advisor() { return 0; }
  record_build_result_on_issues "$DEPLOYMENT_BUILD_HEAD" environment:build-capacity 55 failure build 'fixture'
)
assert_eq 'build issue attribution uses the newest successful Deployment baseline' \
  "$DEPLOYMENT_BUILD_BASE..$DEPLOYMENT_BUILD_HEAD" "$(cat "$DEPLOYMENT_BUILD_RANGE")"
EMPTY_EPOCH_NOW="$(date +%s)"
EMPTY_EPOCH_TZ_MIN=$(( (1440 - (EMPTY_EPOCH_NOW / 60) % 1440 + 1) % 1440 ))
export TZ="PIN-$((EMPTY_EPOCH_TZ_MIN / 60)):$((EMPTY_EPOCH_TZ_MIN % 60))"
CHECK_STALLED_PRS_FN="$(sed -n '/^check_stalled_prs() {/,/^}/p' "$SUPERVISOR_SRC")"
EMPTY_UPDATED_PR_FINDINGS="$(
  eval "$CHECK_STALLED_PRS_FN"
  REPO=test/repo
  STALLED_PR_GRACE_SECONDS=1
  gh() { printf '%s\n' '{"number":2043,"headRefName":"agent/issue-2043","isDraft":false,"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","updatedAt":""}'; }
  finding() { printf '%s\n' "$*"; }
  check_stalled_prs
)"
assert_eq "empty PR updatedAt takes now fallback, not midnight-age finding" '' "$EMPTY_UPDATED_PR_FINDINGS"

# Postsubmit build admission must query the exact source SHA. The workflow
# list can be stale even when the per-SHA Actions endpoint has the green run.
POSTSUBMIT_GREEN_FN="$(sed -n '/^postsubmit_green_for_sha() {/,/^}/p' "$SUPERVISOR_SRC")"
eval "$POSTSUBMIT_GREEN_FN"
POSTSUBMIT_MAIN_HEAD_FN="$(sed -n '/^main_head_sha() {/,/^}/p' "$SUPERVISOR_SRC")"
eval "$POSTSUBMIT_MAIN_HEAD_FN"
REPO="example-maintainer/example-repo"
POSTSUBMIT_CALL_LOG="$(mktemp)"
POSTSUBMIT_API_ARG_LOG="$(mktemp)"
TMP_DIRS+=("$POSTSUBMIT_CALL_LOG" "$POSTSUBMIT_API_ARG_LOG")
POSTSUBMIT_API_ERROR=0
POSTSUBMIT_API_JSON='{}'
POSTSUBMIT_API_JSON_FRESH='{}'
POSTSUBMIT_JOB_API_ERROR=0
POSTSUBMIT_JOB_JSON_BY_RUN=''
POSTSUBMIT_JOB_JSON='{}'
POSTSUBMIT_JOB_JSON_FRESH='{}'
POSTSUBMIT_COMMIT_JSON='{}'
POSTSUBMIT_COMMIT_JSON_FRESH='{}'
POSTSUBMIT_ENFORCE_FRESHNESS=0
POSTSUBMIT_HISTORY_JSON='[]'
gh() {
  if [ "${1:-}" = api ]; then
    local endpoint='' arg api_args="$*" normalized_endpoint
    for arg in "$@"; do
      case "$arg" in repos/*) endpoint="$arg" ;; esac
    done
    normalized_endpoint="${endpoint%%&created=*}"
    printf 'api %s\n' "$normalized_endpoint" >> "$POSTSUBMIT_CALL_LOG"
    printf 'api %s\n' "$api_args" >> "$POSTSUBMIT_API_ARG_LOG"
    case "$endpoint" in
      "repos/$REPO/commits/main")
        if [ "$POSTSUBMIT_ENFORCE_FRESHNESS" = 1 ] \
          && [[ "$api_args" == *"Cache-Control: no-cache"* && "$api_args" == *"Pragma: no-cache"* ]]; then
          printf '%s\n' "$POSTSUBMIT_COMMIT_JSON_FRESH"
        else
          printf '%s\n' "$POSTSUBMIT_COMMIT_JSON"
        fi
        ;;
      "repos/$REPO/commits/"*)
        printf '%s\n' "$POSTSUBMIT_COMMIT_JSON"
        ;;
      "repos/$REPO/actions/runs?head_sha="*)
        [ "$POSTSUBMIT_API_ERROR" = 0 ] || return 1
        if [ "$POSTSUBMIT_ENFORCE_FRESHNESS" = 1 ]; then
          if [[ "$api_args" == *"Cache-Control: no-cache"* \
            && "$api_args" == *"Pragma: no-cache"* \
            && "$endpoint" == *"&page=1&created=%3E%3D"* ]]; then
            printf '%s\n' "$POSTSUBMIT_API_JSON_FRESH"
          else
            printf '%s\n' '{"workflow_runs":[]}'
          fi
          return 0
        fi
        if [ -n "${POSTSUBMIT_API_JSON_SECOND:-}" ] \
          && [ "$(grep -cF "api repos/$REPO/actions/runs?head_sha=" "$POSTSUBMIT_CALL_LOG" || true)" -ge 2 ]; then
          printf '%s\n' "$POSTSUBMIT_API_JSON_SECOND"
        else
          printf '%s\n' "$POSTSUBMIT_API_JSON"
        fi
        ;;
      "repos/$REPO/actions/runs/"*/jobs\?per_page=100*)
        [ "$POSTSUBMIT_JOB_API_ERROR" = 0 ] || return 1
        if [ "$POSTSUBMIT_ENFORCE_FRESHNESS" = 1 ]; then
          if [[ "$api_args" == *"Cache-Control: no-cache"* \
            && "$api_args" == *"Pragma: no-cache"* \
            && "$endpoint" == *"&page=1" ]]; then
            printf '%s\n' "$POSTSUBMIT_JOB_JSON_FRESH"
          else
            printf '%s\n' '{"jobs":[{"id":0,"name":"Postsubmit validate","status":"in_progress","conclusion":null}]}'
          fi
          return 0
        fi
        if [ -n "${POSTSUBMIT_JOB_JSON_BY_RUN:-}" ]; then
          local run_id mapped_job_json
          run_id="${endpoint#repos/$REPO/actions/runs/}"
          run_id="${run_id%%/*}"
          mapped_job_json="$(jq -c --arg run_id "$run_id" '.[$run_id] // empty' <<< "$POSTSUBMIT_JOB_JSON_BY_RUN")"
          if [ -n "$mapped_job_json" ]; then
            printf '%s\n' "$mapped_job_json"
            return 0
          fi
        fi
        printf '%s\n' "$POSTSUBMIT_JOB_JSON"
        ;;
      *) return 2 ;;
    esac
    return 0
  fi
  if [ "${1:-}" = run ] && [ "${2:-}" = list ]; then
    printf 'list\n' >> "$POSTSUBMIT_CALL_LOG"
    printf '%s\n' "$POSTSUBMIT_HISTORY_JSON"
    return 0
  fi
  return 2
}
POSTSUBMIT_SHA="$(printf 'a%.0s' {1..40})"
POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_SHA" \
  '{workflow_runs:[{id:101,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:00:00Z"}]}')"
POSTSUBMIT_JOB_JSON='{"jobs":[{"id":501,"name":"Postsubmit validate","status":"completed","conclusion":"success"}]}'
for POSTSUBMIT_HISTORY_JSON in \
  '[]' \
  '[{"headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","headBranch":"main","status":"completed","conclusion":"failure"}]'; do
  if postsubmit_green_for_sha "$POSTSUBMIT_SHA"; then POSTSUBMIT_GREEN=true; else POSTSUBMIT_GREEN=false; fi
  assert_eq "exact-SHA green survives stale workflow list $POSTSUBMIT_HISTORY_JSON" true "$POSTSUBMIT_GREEN"
done
assert_eq "Postsubmit lookups pin exact full source SHA and skip stale list" \
  "api repos/$REPO/actions/runs?head_sha=$POSTSUBMIT_SHA&per_page=100&page=1
api repos/$REPO/actions/runs/101/jobs?per_page=100&page=1
api repos/$REPO/actions/runs?head_sha=$POSTSUBMIT_SHA&per_page=100&page=1
api repos/$REPO/actions/runs/101/jobs?per_page=100&page=1" \
  "$(cat "$POSTSUBMIT_CALL_LOG")"

# A cache proxy returns an empty run snapshot and an in-progress job snapshot
# unless each mutable GitHub read requests freshness. The cache-key parameters
# preserve the API's first-page semantics while exposing the current run.
POSTSUBMIT_COMMIT_JSON="$(jq -cn --arg sha "$(printf 'a%.0s' {1..40})" \
  '{sha:$sha,commit:{committer:{date:"2026-10-19T00:00:00Z"}}}')"
POSTSUBMIT_COMMIT_JSON_FRESH="$(jq -cn --arg sha "$(printf 'b%.0s' {1..40})" \
  '{sha:$sha,commit:{committer:{date:"2026-10-20T00:00:00Z"}}}')"
POSTSUBMIT_ENFORCE_FRESHNESS=1
assert_eq "main tip lookup bypasses a cached older commit" \
  "$(printf 'b%.0s' {1..40})" "$(main_head_sha)"
assert_contains "main tip lookup sends freshness headers" \
  "$(cat "$POSTSUBMIT_API_ARG_LOG")" "Cache-Control: no-cache"
assert_contains "main tip lookup sends both freshness headers" \
  "$(cat "$POSTSUBMIT_API_ARG_LOG")" "Pragma: no-cache"

POSTSUBMIT_API_JSON='{"workflow_runs":[]}'
POSTSUBMIT_API_JSON_FRESH="$(jq -cn --arg sha "$POSTSUBMIT_SHA" \
  '{workflow_runs:[{id:106,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:00:00Z"}]}')"
POSTSUBMIT_JOB_JSON_FRESH='{"jobs":[{"id":506,"name":"Postsubmit validate","status":"completed","conclusion":"success"}]}'
POSTSUBMIT_JOB_JSON='{"jobs":[{"id":0,"name":"Postsubmit validate","status":"in_progress","conclusion":null}]}'
: > "$POSTSUBMIT_CALL_LOG"
: > "$POSTSUBMIT_API_ARG_LOG"
if postsubmit_green_for_sha "$POSTSUBMIT_SHA"; then POSTSUBMIT_GREEN=true; else POSTSUBMIT_GREEN=false; fi
assert_eq "fresh exact-SHA run and job reads escape stale cached snapshots" true "$POSTSUBMIT_GREEN"
assert_contains "exact-SHA run request carries freshness headers and moving first-page key" \
  "$(cat "$POSTSUBMIT_API_ARG_LOG")" \
  "repos/$REPO/actions/runs?head_sha=$POSTSUBMIT_SHA&per_page=100&page=1&created=%3E%3D"
assert_contains "exact-SHA run request also sends both freshness headers" \
  "$(cat "$POSTSUBMIT_API_ARG_LOG")" \
  "-H Cache-Control: no-cache -H Pragma: no-cache"
assert_contains "exact-SHA job request carries freshness headers and explicit first page" \
  "$(cat "$POSTSUBMIT_API_ARG_LOG")" \
  "repos/$REPO/actions/runs/106/jobs?per_page=100&page=1 -H Cache-Control: no-cache -H Pragma: no-cache"
POSTSUBMIT_ENFORCE_FRESHNESS=0

POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_SHA" \
  '{workflow_runs:[{id:102,head_sha:$sha,head_branch:"main",event:"push",path:".github/workflows/ci.yml",status:"in_progress",conclusion:null}]}')"
if postsubmit_green_for_sha "$POSTSUBMIT_SHA"; then POSTSUBMIT_GREEN=true; else POSTSUBMIT_GREEN=false; fi
assert_eq "pending exact-SHA Postsubmit blocks build admission" false "$POSTSUBMIT_GREEN"
POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_SHA" \
  '{workflow_runs:[{id:103,head_sha:$sha,head_branch:"main",event:"push",path:".github/workflows/ci.yml",status:"completed",conclusion:"failure"}]}')"
if postsubmit_green_for_sha "$POSTSUBMIT_SHA"; then POSTSUBMIT_GREEN=true; else POSTSUBMIT_GREEN=false; fi
assert_eq "failed exact-SHA Postsubmit blocks build admission" false "$POSTSUBMIT_GREEN"
POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_SHA" \
  '{workflow_runs:[{id:104,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success"}]}')"
POSTSUBMIT_JOB_JSON='{"jobs":[{"id":504,"name":"Postsubmit validate","status":"completed","conclusion":"skipped"}]}'
if postsubmit_green_for_sha "$POSTSUBMIT_SHA"; then POSTSUBMIT_GREEN=true; else POSTSUBMIT_GREEN=false; fi
assert_eq "successful workflow with skipped Postsubmit job blocks build admission" false "$POSTSUBMIT_GREEN"

# Only the newest exact-SHA run can authorize a build. Older success must not
# survive a newer failed, active, or skipped validation attempt.
POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_SHA" '{workflow_runs:[
  {id:776,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:00:00Z"},
  {id:777,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"failure",created_at:"2026-10-20T00:01:00Z"}
]}')"
if postsubmit_green_for_sha "$POSTSUBMIT_SHA"; then POSTSUBMIT_GREEN=true; else POSTSUBMIT_GREEN=false; fi
assert_eq "newer failed exact-SHA run supersedes an older green run" false "$POSTSUBMIT_GREEN"
POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_SHA" '{workflow_runs:[
  {id:776,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:00:00Z"},
  {id:777,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"in_progress",conclusion:null,created_at:"2026-10-20T00:01:00Z"}
]}')"
if postsubmit_green_for_sha "$POSTSUBMIT_SHA"; then POSTSUBMIT_GREEN=true; else POSTSUBMIT_GREEN=false; fi
assert_eq "newer active exact-SHA run supersedes an older green run" false "$POSTSUBMIT_GREEN"
POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_SHA" '{workflow_runs:[
  {id:776,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:00:00Z"},
  {id:777,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:01:00Z"}
]}')"
POSTSUBMIT_JOB_JSON_BY_RUN='{"776":{"jobs":[{"id":776,"name":"Postsubmit validate","status":"completed","conclusion":"success"}]},"777":{"jobs":[{"id":777,"name":"Postsubmit validate","status":"completed","conclusion":"skipped"}]}}'
if postsubmit_green_for_sha "$POSTSUBMIT_SHA"; then POSTSUBMIT_GREEN=true; else POSTSUBMIT_GREEN=false; fi
assert_eq "newer skipped exact-SHA job supersedes an older green run" false "$POSTSUBMIT_GREEN"
POSTSUBMIT_JOB_JSON_BY_RUN=''
POSTSUBMIT_JOB_API_ERROR=1
if postsubmit_green_for_sha "$POSTSUBMIT_SHA"; then POSTSUBMIT_GREEN=true; else POSTSUBMIT_GREEN=false; fi
assert_eq "unreadable Postsubmit job API blocks build admission" false "$POSTSUBMIT_GREEN"
POSTSUBMIT_JOB_API_ERROR=0
POSTSUBMIT_API_ERROR=1
if postsubmit_green_for_sha "$POSTSUBMIT_SHA"; then POSTSUBMIT_GREEN=true; else POSTSUBMIT_GREEN=false; fi
assert_eq "Actions API error blocks build admission" false "$POSTSUBMIT_GREEN"
POSTSUBMIT_API_ERROR=0

# A pipeline-only [skip ci] HEAD has no own push run. A green ancestor cannot
# stand in for exact source-SHA evidence for this build helper.
POSTSUBMIT_SKIP_CI_SHA="$(printf 'c%.0s' {1..40})"
POSTSUBMIT_ANCESTOR_SHA="$(printf 'b%.0s' {1..40})"
POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_ANCESTOR_SHA" \
  '{workflow_runs:[{id:105,head_sha:$sha,head_branch:"main",event:"push",path:".github/workflows/ci.yml",status:"completed",conclusion:"success"}]}')"
if postsubmit_green_for_sha "$POSTSUBMIT_SKIP_CI_SHA"; then POSTSUBMIT_GREEN=true; else POSTSUBMIT_GREEN=false; fi
assert_eq "[skip ci] source SHA cannot borrow green ancestor evidence" false "$POSTSUBMIT_GREEN"
assert_eq "[skip ci] lookup still queries exact current source SHA" \
  "api repos/$REPO/actions/runs?head_sha=$POSTSUBMIT_SKIP_CI_SHA&per_page=100&page=1" \
  "$(tail -n 1 "$POSTSUBMIT_CALL_LOG")"

# The admission caller must stop before recording or dispatching when its
# exact-SHA lookup is pending, failed, or unavailable.
CHECK_RELEASE_RECONCILIATION_FN="$(sed -n '/^check_release_reconciliation() {/,/^}/p' "$SUPERVISOR_SRC")"
POSTSUBMIT_SKIPPED_DISPATCH_FN="$(sed -n '/^postsubmit_dispatch_was_skipped_for_run() {/,/^}/p' "$SUPERVISOR_SRC")"
POSTSUBMIT_RECOVERY_FN="$(awk '
  /^(release_record_file|release_record_write|release_record_field|release_record_validation_write|dispatch_postsubmit_for_sha|postsubmit_dispatch_was_skipped_for_run|check_release_reconciliation)\(\) \{/ { inside=1 }
  inside { print }
  inside && /^}/ { inside=0 }
' "$SUPERVISOR_SRC")"
POSTSUBMIT_ADMISSION_LOG="$(mktemp)"
TMP_DIRS+=("$POSTSUBMIT_ADMISSION_LOG")
assert_no_postsubmit_build_dispatch() {
  local desc="$1"
  : > "$POSTSUBMIT_ADMISSION_LOG"
  (
    eval "$POSTSUBMIT_SKIPPED_DISPATCH_FN"
    eval "$CHECK_RELEASE_RECONCILIATION_FN"
    main_head_sha() { printf '%s\n' "$POSTSUBMIT_SHA"; }
    reconcile_build_record() { return 0; }
    release_record_field() { return 0; }
    finding() { :; }
    stage_dispatch_allowed() { return 0; }
    release_record_write() { printf 'record\n' >> "$POSTSUBMIT_ADMISSION_LOG"; }
    guarded_write() { printf 'dispatch\n' >> "$POSTSUBMIT_ADMISSION_LOG"; return 0; }
    RELEASE_RECOVERY_DIR="$POSTSUBMIT_ADMISSION_LOG/missing"
    MODE=act DRY_RUN=0 check_release_reconciliation
  )
  assert_eq "$desc" '' "$(cat "$POSTSUBMIT_ADMISSION_LOG")"
}
for POSTSUBMIT_API_CASE in pending failure; do
  POSTSUBMIT_API_ERROR=0
  POSTSUBMIT_API_STATUS=in_progress
  POSTSUBMIT_API_CONCLUSION=null
  if [ "$POSTSUBMIT_API_CASE" = failure ]; then
    POSTSUBMIT_API_STATUS=completed
    POSTSUBMIT_API_CONCLUSION=failure
  fi
  POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_SHA" --arg status "$POSTSUBMIT_API_STATUS" --arg conclusion "$POSTSUBMIT_API_CONCLUSION" \
    '{workflow_runs:[{head_sha:$sha,head_branch:"main",event:"push",path:".github/workflows/ci.yml",status:$status,conclusion:(if $conclusion == "null" then null else $conclusion end)}]}')"
  assert_no_postsubmit_build_dispatch "$POSTSUBMIT_API_CASE exact-SHA Postsubmit blocks build dispatch"
done
POSTSUBMIT_API_ERROR=1
POSTSUBMIT_API_JSON='{}'
assert_no_postsubmit_build_dispatch "Actions API error blocks build dispatch"
POSTSUBMIT_API_ERROR=0

POSTSUBMIT_CASE_DIR="$(mktemp -d)"
TMP_DIRS+=("$POSTSUBMIT_CASE_DIR")
POSTSUBMIT_CASE_SHA="$(printf 'd%.0s' {1..40})"
POSTSUBMIT_CHANGED_SHA="$(printf 'e%.0s' {1..40})"
POSTSUBMIT_WRITE_LOG="$POSTSUBMIT_CASE_DIR/writes.log"
POSTSUBMIT_FINDING_LOG="$POSTSUBMIT_CASE_DIR/findings.log"
POSTSUBMIT_HEAD_SEQUENCE="$POSTSUBMIT_CASE_DIR/head-sequence"
POSTSUBMIT_HEAD_INDEX="$POSTSUBMIT_CASE_DIR/head-index"
POSTSUBMIT_API_ERROR=0
POSTSUBMIT_JOB_API_ERROR=0
POSTSUBMIT_API_JSON='{"workflow_runs":[]}'
POSTSUBMIT_COMMIT_JSON="$(jq -cn --arg sha "$POSTSUBMIT_CASE_SHA" \
  '{sha:$sha,commit:{message:"[skip ci] fixture",committer:{date:"2026-10-20T00:00:00Z"}}}')"
POSTSUBMIT_JOB_JSON='{"jobs":[{"id":901,"name":"Postsubmit validate","status":"completed","conclusion":"success"}]}'
postsubmit_check_once() (
  eval "$POSTSUBMIT_RECOVERY_FN"
  eval "$POSTSUBMIT_GREEN_FN"
  main_head_sha() {
    if [ -s "$POSTSUBMIT_HEAD_SEQUENCE" ]; then
      local index value
      index="$(cat "$POSTSUBMIT_HEAD_INDEX" 2>/dev/null || echo 0)"
      index=$((index + 1))
      printf '%s\n' "$index" > "$POSTSUBMIT_HEAD_INDEX"
      value="$(sed -n "${index}p" "$POSTSUBMIT_HEAD_SEQUENCE")"
      printf '%s\n' "${value:-$POSTSUBMIT_CASE_SHA}"
    else
      printf '%s\n' "$POSTSUBMIT_CASE_SHA"
    fi
  }
  reconcile_build_record() { return 0; }
  finding() { printf '%s\n' "$*" >> "$POSTSUBMIT_FINDING_LOG"; }
  stage_dispatch_allowed() { return 0; }
  guarded_write() {
    printf '%s\n' "$*" >> "$POSTSUBMIT_WRITE_LOG"
    if [ "${POSTSUBMIT_FAIL_DISPATCH:-0}" = 1 ] && [[ "$*" == *"workflow run ci.yml"* ]]; then
      return 1
    fi
    return 0
  }
  REPO=example-maintainer/example-repo
  RELEASE_RECOVERY_DIR="$POSTSUBMIT_CASE_DIR/recovery"
  MODE=act DRY_RUN=0 check_release_reconciliation
)
: > "$POSTSUBMIT_WRITE_LOG"
: > "$POSTSUBMIT_FINDING_LOG"
: > "$POSTSUBMIT_HEAD_INDEX"
postsubmit_check_once
assert_eq "missing current [skip ci] tip dispatches one exact-SHA Postsubmit" 1 \
  "$(grep -cF "workflow run ci.yml -R example-maintainer/example-repo --ref main -f source_sha=$POSTSUBMIT_CASE_SHA" "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "Postsubmit dispatch does not dispatch an image build" 0 \
  "$(grep -cF 'workflow run build-cihost-images.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "automatic Postsubmit request persists its source SHA and state" \
  "$POSTSUBMIT_CASE_SHA requested" \
  "$(jq -r '[.source_sha,.status] | join(" ")' "$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_CASE_SHA.json")"
postsubmit_check_once
assert_eq "restart and delayed run-list visibility do not duplicate Postsubmit dispatch" 1 \
  "$(grep -cF 'workflow run ci.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "repeated missing evidence remains blocked from image build" 0 \
  "$(grep -cF 'workflow run build-cihost-images.yml' "$POSTSUBMIT_WRITE_LOG" || true)"

# A workflow_dispatch submitted for the previous tip can arrive after main has
# advanced. GitHub binds the run's head SHA to the selected ref, so this run is
# visible under the successor SHA even though its Postsubmit job was skipped
# because source_sha still names the previous tip. The successor needs its own
# durable dispatch request and must stay blocked until that request validates.
rm -rf "$POSTSUBMIT_CASE_DIR/recovery"
mkdir -p "$POSTSUBMIT_CASE_DIR/recovery/postsubmit"
POSTSUBMIT_PREDECESSOR_SHA="$(printf 'f%.0s' {1..40})"
jq -n --arg sha "$POSTSUBMIT_PREDECESSOR_SHA" \
  '{source_sha:$sha,status:"requested",dispatch_attempts:1,run_id:"",conclusion:"",dispatched_at:"2026-10-20T00:00:00Z",updated_at:"2026-10-20T00:00:00Z"}' \
  > "$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_PREDECESSOR_SHA.json"
POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_CASE_SHA" \
  '{workflow_runs:[{id:990,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:01:00Z"}]}')"
POSTSUBMIT_JOB_JSON='{"jobs":[{"id":990,"name":"Postsubmit validate","status":"completed","conclusion":"skipped"}]}'
: > "$POSTSUBMIT_WRITE_LOG"
: > "$POSTSUBMIT_FINDING_LOG"
: > "$POSTSUBMIT_HEAD_INDEX"
postsubmit_check_once
assert_eq "a skipped stale dispatch does not stand in for its successor tip" 1 \
  "$(grep -cF "workflow run ci.yml -R example-maintainer/example-repo --ref main -f source_sha=$POSTSUBMIT_CASE_SHA" "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "successor dispatch persists its own source SHA" \
  "$POSTSUBMIT_CASE_SHA requested" \
  "$(jq -r '[.source_sha,.status] | join(" ")' "$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_CASE_SHA.json")"
assert_eq "a stale skipped dispatch cannot release the image build" 0 \
  "$(grep -cF 'workflow run build-cihost-images.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
postsubmit_check_once
assert_eq "stale skipped dispatch recovery remains persistently deduplicated" 1 \
  "$(grep -cF 'workflow run ci.yml' "$POSTSUBMIT_WRITE_LOG" || true)"

POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_CASE_SHA" \
  '{workflow_runs:[{id:991,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:02:00Z"}]}')"
POSTSUBMIT_JOB_JSON='{"jobs":[{"id":991,"name":"Postsubmit validate","status":"completed","conclusion":"success"}]}'
: > "$POSTSUBMIT_WRITE_LOG"
: > "$POSTSUBMIT_HEAD_INDEX"
postsubmit_check_once
assert_eq "successor build waits for its own successful Postsubmit run" 1 \
  "$(grep -cF 'workflow run build-cihost-images.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "successor build record binds its own validation run" \
  "$POSTSUBMIT_CASE_SHA 991 success" \
  "$(jq -r '[.source_sha,.validation.run_id,.validation.conclusion] | join(" ")' \
    "$POSTSUBMIT_CASE_DIR/recovery/$POSTSUBMIT_CASE_SHA.json")"

# A failed workflow_dispatch and a process that died after the durable claim
# are recoverable only after the claim is stale and an exact-SHA Actions lookup
# confirms that no matching run exists. Retries are capped per source SHA.
POSTSUBMIT_API_JSON='{"workflow_runs":[]}'
POSTSUBMIT_API_ERROR=0
rm -rf "$POSTSUBMIT_CASE_DIR/recovery"
: > "$POSTSUBMIT_WRITE_LOG"
POSTSUBMIT_FAIL_DISPATCH=1 postsubmit_check_once
assert_eq "failed Postsubmit dispatch is recorded" dispatch-failed \
  "$(jq -r '.status' "$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_CASE_SHA.json")"
assert_eq "failed Postsubmit dispatch consumes one bounded attempt" 1 \
  "$(jq -r '.dispatch_attempts' "$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_CASE_SHA.json")"
postsubmit_check_once
assert_eq "fresh failed request is not dispatched again before its retry delay" 1 \
  "$(grep -cF 'workflow run ci.yml' "$POSTSUBMIT_WRITE_LOG" || true)"

age_postsubmit_request_record() {
  local record="$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_CASE_SHA.json"
  jq '.updated_at = "2020-01-01T00:00:00Z"' "$record" > "$record.tmp"
  mv "$record.tmp" "$record"
}
age_postsubmit_request_record
POSTSUBMIT_API_ERROR=1 postsubmit_check_once
assert_eq "unreadable exact-SHA API does not retry a failed dispatch" 1 \
  "$(grep -cF 'workflow run ci.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
POSTSUBMIT_FAIL_DISPATCH=1 postsubmit_check_once
assert_eq "confirmed missing run permits a failed-request retry" 2 \
  "$(grep -cF 'workflow run ci.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "retry increments the durable attempt count" 2 \
  "$(jq -r '.dispatch_attempts' "$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_CASE_SHA.json")"
age_postsubmit_request_record
POSTSUBMIT_FAIL_DISPATCH=1 postsubmit_check_once
assert_eq "request can recover only up to the configured attempt cap" 3 \
  "$(grep -cF 'workflow run ci.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "attempt cap is persisted" 3 \
  "$(jq -r '.dispatch_attempts' "$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_CASE_SHA.json")"
age_postsubmit_request_record
postsubmit_check_once
assert_eq "exhausted Postsubmit request never dispatches a fourth time" 3 \
  "$(grep -cF 'workflow run ci.yml' "$POSTSUBMIT_WRITE_LOG" || true)"

# If a prior request was accepted but its response was lost, the run may appear
# between the supervisor's first lookup and the retry guard's final lookup.
rm -rf "$POSTSUBMIT_CASE_DIR/recovery"
mkdir -p "$POSTSUBMIT_CASE_DIR/recovery/postsubmit"
jq -n --arg sha "$POSTSUBMIT_CASE_SHA" \
  '{source_sha:$sha,status:"dispatch-failed",dispatch_attempts:1,run_id:"",conclusion:"",dispatched_at:"2020-01-01T00:00:00Z",updated_at:"2020-01-01T00:00:00Z"}' \
  > "$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_CASE_SHA.json"
POSTSUBMIT_API_JSON_SECOND="$(jq -cn --arg sha "$POSTSUBMIT_CASE_SHA" \
  '{workflow_runs:[{id:889,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"in_progress",conclusion:null,created_at:"2026-10-20T00:00:00Z"}]}')"
: > "$POSTSUBMIT_CALL_LOG"
: > "$POSTSUBMIT_WRITE_LOG"
postsubmit_check_once
assert_eq "retry guard rechecks exact-SHA runs before redispatch" 2 \
  "$(grep -cF "api repos/$REPO/actions/runs?head_sha=$POSTSUBMIT_CASE_SHA&per_page=100" "$POSTSUBMIT_CALL_LOG" || true)"
assert_eq "a newly visible exact-SHA run blocks a duplicate retry" 0 \
  "$(grep -cF 'workflow run ci.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
assert_contains "a newly visible exact-SHA run is reported" \
  "$(cat "$POSTSUBMIT_FINDING_LOG")" "found exact-SHA run 889"
unset POSTSUBMIT_API_JSON_SECOND

# Recreate a supervisor restart after the pre-dispatch marker was persisted.
# A stale marker can recover once, while a fresh marker remains deduplicated.
rm -rf "$POSTSUBMIT_CASE_DIR/recovery"
mkdir -p "$POSTSUBMIT_CASE_DIR/recovery/postsubmit"
jq -n --arg sha "$POSTSUBMIT_CASE_SHA" \
  '{source_sha:$sha,status:"dispatching",dispatch_attempts:1,run_id:"",conclusion:"",dispatched_at:"2020-01-01T00:00:00Z",updated_at:"2020-01-01T00:00:00Z"}' \
  > "$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_CASE_SHA.json"
: > "$POSTSUBMIT_WRITE_LOG"
postsubmit_check_once
assert_eq "stale interrupted claim recovers after exact-SHA absence is confirmed" 1 \
  "$(grep -cF 'workflow run ci.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "recovered interrupted claim records its next attempt" 2 \
  "$(jq -r '.dispatch_attempts' "$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_CASE_SHA.json")"
postsubmit_check_once
assert_eq "recovered request remains deduplicated after restart" 1 \
  "$(grep -cF 'workflow run ci.yml' "$POSTSUBMIT_WRITE_LOG" || true)"

rm -rf "$POSTSUBMIT_CASE_DIR/recovery"
: > "$POSTSUBMIT_WRITE_LOG"
: > "$POSTSUBMIT_HEAD_INDEX"
printf '%s\n%s\n' "$POSTSUBMIT_CASE_SHA" "$POSTSUBMIT_CHANGED_SHA" > "$POSTSUBMIT_HEAD_SEQUENCE"
postsubmit_check_once
assert_eq "tip change between lookup and dispatch prevents stale Postsubmit request" 0 \
  "$(grep -cF 'workflow run ci.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "tip change prevents stale image build" 0 \
  "$(grep -cF 'workflow run build-cihost-images.yml' "$POSTSUBMIT_WRITE_LOG" || true)"

rm -f "$POSTSUBMIT_HEAD_SEQUENCE" "$POSTSUBMIT_HEAD_INDEX"
POSTSUBMIT_COMMIT_JSON="$(jq -cn --arg sha "$POSTSUBMIT_CASE_SHA" \
  '{sha:$sha,commit:{message:"product source without skip marker",committer:{date:"2026-10-20T00:00:00Z"}}}')"
: > "$POSTSUBMIT_WRITE_LOG"
postsubmit_check_once
assert_eq "automatic recovery does not dispatch for a non-skip main commit" 0 \
  "$(grep -cF 'workflow run ci.yml' "$POSTSUBMIT_WRITE_LOG" || true)"

POSTSUBMIT_COMMIT_JSON="$(jq -cn --arg sha "$POSTSUBMIT_CASE_SHA" \
  '{sha:$sha,commit:{message:"[skip ci] fixture",committer:{date:"2026-10-20T00:00:00Z"}}}')"
POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_CASE_SHA" \
  '{workflow_runs:[{id:777,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:00:00Z"}]}')"
: > "$POSTSUBMIT_WRITE_LOG"
: > "$POSTSUBMIT_HEAD_INDEX"
postsubmit_check_once
assert_eq "successful exact-tip validation precedes image build dispatch" \
  1 "$(grep -cF 'workflow run build-cihost-images.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "build record binds source SHA to its exact validation run" \
  "$POSTSUBMIT_CASE_SHA 777 success" \
  "$(jq -r '[.source_sha,.validation.run_id,.validation.conclusion] | join(" ")' \
    "$POSTSUBMIT_CASE_DIR/recovery/$POSTSUBMIT_CASE_SHA.json")"

# A later failed retry supersedes an earlier green run for the same exact
# source SHA, matching HEALTH's latest-run verdict and blocking build admission.
rm -rf "$POSTSUBMIT_CASE_DIR/recovery"
POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_CASE_SHA" '{workflow_runs:[
  {id:776,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:00:00Z"},
  {id:777,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"failure",created_at:"2026-10-20T00:01:00Z"}
]}')"
: > "$POSTSUBMIT_WRITE_LOG"
: > "$POSTSUBMIT_FINDING_LOG"
: > "$POSTSUBMIT_HEAD_INDEX"
postsubmit_check_once
assert_eq "a later failed exact-SHA retry blocks image build dispatch" 0 \
  "$(grep -cF 'workflow run build-cihost-images.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "failed latest run does not write validation evidence" 0 \
  "$(test -e "$POSTSUBMIT_CASE_DIR/recovery/$POSTSUBMIT_CASE_SHA.json" && echo 1 || echo 0)"
assert_contains "failed latest run remains blocked pending its own successful evidence" \
  "$(cat "$POSTSUBMIT_FINDING_LOG")" \
  "exact-SHA Postsubmit has no completed successful validate job for live main $POSTSUBMIT_CASE_SHA"

POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_CASE_SHA" '{workflow_runs:[
  {id:776,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:00:00Z"},
  {id:777,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"in_progress",conclusion:null,created_at:"2026-10-20T00:01:00Z"}
]}')"
rm -rf "$POSTSUBMIT_CASE_DIR/recovery"
: > "$POSTSUBMIT_WRITE_LOG"
: > "$POSTSUBMIT_FINDING_LOG"
postsubmit_check_once
assert_eq "a newer active exact-SHA retry blocks image build dispatch" 0 \
  "$(grep -cF 'workflow run build-cihost-images.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "active latest run does not write validation evidence" 0 \
  "$(test -e "$POSTSUBMIT_CASE_DIR/recovery/$POSTSUBMIT_CASE_SHA.json" && echo 1 || echo 0)"

POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_CASE_SHA" '{workflow_runs:[
  {id:776,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:00:00Z"},
  {id:777,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:01:00Z"}
]}')"
POSTSUBMIT_JOB_JSON_BY_RUN='{"776":{"jobs":[{"id":776,"name":"Postsubmit validate","status":"completed","conclusion":"success"}]},"777":{"jobs":[{"id":777,"name":"Postsubmit validate","status":"completed","conclusion":"skipped"}]}}'
rm -rf "$POSTSUBMIT_CASE_DIR/recovery"
: > "$POSTSUBMIT_WRITE_LOG"
: > "$POSTSUBMIT_FINDING_LOG"
postsubmit_check_once
assert_eq "a newer skipped exact-SHA job blocks image build dispatch" 0 \
  "$(grep -cF 'workflow run build-cihost-images.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "a newer skipped exact-SHA job requests a fresh validation" 1 \
  "$(grep -cF "workflow run ci.yml -R example-maintainer/example-repo --ref main -f source_sha=$POSTSUBMIT_CASE_SHA" "$POSTSUBMIT_WRITE_LOG" || true)"
assert_eq "skipped latest run does not write validation evidence" 0 \
  "$(test -e "$POSTSUBMIT_CASE_DIR/recovery/$POSTSUBMIT_CASE_SHA.json" && echo 1 || echo 0)"
POSTSUBMIT_JOB_JSON_BY_RUN=''

POSTSUBMIT_API_JSON="$(jq -cn --arg sha "$POSTSUBMIT_CASE_SHA" \
  '{workflow_runs:[{id:777,head_sha:$sha,head_branch:"main",event:"workflow_dispatch",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",created_at:"2026-10-20T00:00:00Z"}]}')"

# A successful run is still not build authority if main advances after the
# evidence lookup and before the image-build workflow write.
rm -rf "$POSTSUBMIT_CASE_DIR/recovery"
: > "$POSTSUBMIT_WRITE_LOG"
: > "$POSTSUBMIT_FINDING_LOG"
: > "$POSTSUBMIT_HEAD_INDEX"
printf '%s\n%s\n' "$POSTSUBMIT_CASE_SHA" "$POSTSUBMIT_CHANGED_SHA" > "$POSTSUBMIT_HEAD_SEQUENCE"
postsubmit_check_once
assert_eq "tip change after green validation blocks stale image build" 0 \
  "$(grep -cF 'workflow run build-cihost-images.yml' "$POSTSUBMIT_WRITE_LOG" || true)"
assert_contains "tip change after green validation is reported" \
  "$(cat "$POSTSUBMIT_FINDING_LOG")" \
  "main tip changed from $POSTSUBMIT_CASE_SHA to $POSTSUBMIT_CHANGED_SHA before build dispatch"
assert_eq "changed-tip record keeps the verified source and run evidence" \
  "$POSTSUBMIT_CASE_SHA 777 success" \
  "$(jq -r '[.source_sha,.validation.run_id,.validation.conclusion] | join(" ")' \
    "$POSTSUBMIT_CASE_DIR/recovery/$POSTSUBMIT_CASE_SHA.json")"

# Both recovery entry points use one per-SHA atomic claim while Actions can
# still be returning an empty run list. Exercise competing claimants, then
# alternate the real supervisor and direct-main dispatch functions in each
# order against the same recovery directory.
POSTSUBMIT_DIRECT_REVALIDATE_FN="$(sed -n '/^revalidate_missing_postsubmit() {/,/^}/p' "$SCRIPT_DIR/land-direct-main.sh")"
POSTSUBMIT_DIRECT_LOG="$POSTSUBMIT_CASE_DIR/direct-main.log"
POSTSUBMIT_CLAIM_ONE="$POSTSUBMIT_CASE_DIR/claim-one"
POSTSUBMIT_CLAIM_TWO="$POSTSUBMIT_CASE_DIR/claim-two"
RELEASE_RECOVERY_DIR="$POSTSUBMIT_CASE_DIR/recovery"
POSTSUBMIT_COMMIT_JSON="$(jq -cn --arg sha "$POSTSUBMIT_CASE_SHA" \
  '{sha:$sha,commit:{message:"[skip ci] fixture",committer:{date:"2026-10-20T00:00:00Z"}}}')"
POSTSUBMIT_API_JSON='{"workflow_runs":[]}'
POSTSUBMIT_API_ERROR=0
POSTSUBMIT_JOB_API_ERROR=0
POSTSUBMIT_HISTORY_JSON='[]'
run_direct_main_revalidation() (
  eval "$POSTSUBMIT_DIRECT_REVALIDATE_FN"
  git() {
    if [[ "${1:-}" == rev-parse && "${2:-}" == origin/main ]]; then
      printf '%s\n' "$POSTSUBMIT_CASE_SHA"
    else
      "$FAKE_REAL_GIT_BIN" "$@"
    fi
  }
  postsubmit_run_contains_sha() { return 1; }
  timeout() {
    while (($#)) && [[ "$1" != gh ]]; do shift; done
    "$@"
  }
  gh() {
    [[ "${1:-} ${2:-} ${3:-}" == 'workflow run ci.yml' ]] || return 2
    printf '%s\n' "$*" >> "$POSTSUBMIT_DIRECT_LOG"
  }
  revalidate_missing_postsubmit ""
)

rm -rf "$POSTSUBMIT_CASE_DIR/recovery"
: > "$POSTSUBMIT_WRITE_LOG"
: > "$POSTSUBMIT_FINDING_LOG"
: > "$POSTSUBMIT_DIRECT_LOG"
postsubmit_check_once
run_direct_main_revalidation
assert_eq "supervisor then direct-main share one claim while Actions run visibility is delayed" 1 \
  "$(cat "$POSTSUBMIT_WRITE_LOG" "$POSTSUBMIT_DIRECT_LOG" | grep -cF 'workflow run ci.yml' || true)"
assert_eq "supervisor-owned shared claim remains requested" requested \
  "$(jq -r '.status' "$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_CASE_SHA.json")"

rm -rf "$POSTSUBMIT_CASE_DIR/recovery"
: > "$POSTSUBMIT_WRITE_LOG"
: > "$POSTSUBMIT_FINDING_LOG"
: > "$POSTSUBMIT_DIRECT_LOG"
run_direct_main_revalidation
postsubmit_check_once
assert_eq "direct-main then supervisor share one claim while Actions run visibility is delayed" 1 \
  "$(cat "$POSTSUBMIT_WRITE_LOG" "$POSTSUBMIT_DIRECT_LOG" | grep -cF 'workflow run ci.yml' || true)"
assert_eq "direct-main-owned shared claim remains requested" requested \
  "$(jq -r '.status' "$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_CASE_SHA.json")"

rm -rf "$POSTSUBMIT_CASE_DIR/recovery"
mkdir -p "$POSTSUBMIT_CASE_DIR/recovery"
: > "$POSTSUBMIT_CLAIM_ONE"
: > "$POSTSUBMIT_CLAIM_TWO"
(
  if postsubmit_request_dispatch_claim "$POSTSUBMIT_CASE_SHA" 600 3; then echo claimed; else echo "held:$?"; fi
) > "$POSTSUBMIT_CLAIM_ONE" &
POSTSUBMIT_CLAIM_PID_ONE=$!
(
  if postsubmit_request_dispatch_claim "$POSTSUBMIT_CASE_SHA" 600 3; then echo claimed; else echo "held:$?"; fi
) > "$POSTSUBMIT_CLAIM_TWO" &
POSTSUBMIT_CLAIM_PID_TWO=$!
wait "$POSTSUBMIT_CLAIM_PID_ONE"
wait "$POSTSUBMIT_CLAIM_PID_TWO"
assert_eq "two concurrent Postsubmit claimants produce one winner" 1 \
  "$(grep -hxc 'claimed' "$POSTSUBMIT_CLAIM_ONE" "$POSTSUBMIT_CLAIM_TWO" | awk '{sum += $1} END {print sum + 0}')"
assert_eq "the losing Postsubmit claimant observes the existing claim" 1 \
  "$(grep -hxc 'held:1' "$POSTSUBMIT_CLAIM_ONE" "$POSTSUBMIT_CLAIM_TWO" | awk '{sum += $1} END {print sum + 0}')"
assert_eq "concurrent Postsubmit claim records one attempt" 1 \
  "$(jq -r '.dispatch_attempts' "$POSTSUBMIT_CASE_DIR/recovery/postsubmit/$POSTSUBMIT_CASE_SHA.json")"
unset POSTSUBMIT_DIRECT_LOG

# --- fake gh, shadowing the real binary on PATH -----------------------------
# `variable get AGENT_SUPERVISOR` -> $FAKE_MODE. `issue list --label X` ->
# $FAKE_ISSUES_<X> (space/newline-separated issue numbers; population is
# derived by counting them, same as the real `length` vs `.[].number`
# split). `pr list` -> $FAKE_PRS_JSON verbatim. `api .../comments` ->
# $FAKE_COMMENTS_<N>. `issue comment N ...` -> echoes the body to stdout
# prefixed so a test can assert on it (this only runs under AGENT_DRY_RUN=0
# / MODE=act; guarded_write's own dry-run branch intercepts everything
# else and never reaches this binary).
FAKE_BIN="$(mktemp -d)"
TMP_DIRS+=("$FAKE_BIN")
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
label_of() {
  local prev=""
  for a in "$@"; do
    [ "$prev" = "--label" ] && { echo "$a"; return; }
    prev="$a"
  done
}
if [ "$1" = "variable" ] && [ "$2" = "get" ]; then
  echo "${FAKE_MODE:-observe}"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  label="$(label_of "$@")"
  safe="$(echo "$label" | tr '-' '_')"
  var="FAKE_ISSUES_$safe"
  nums="${!var:-}"
  if [ "$label" = "on-hold" ] && [ -n "${FAKE_ONHOLD_ISSUES:-}" ]; then
    nums="$FAKE_ONHOLD_ISSUES"
  fi
  if [[ "$*" == *"-q length"* ]]; then
    cnt="$(printf '%s\n' "$nums" | grep -c . || true)"
    echo "${cnt:-0}"
  else
    printf '%s\n' "$nums" | grep . || true
  fi
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  n="$3"
  if [[ "$*" == *"--json state,labels"* ]]; then
    case " ${FAKE_CLOSED_ISSUES:-} " in
      *" $n "*) echo '{"state":"CLOSED","labels":[]}' ;;
      *)
        case " ${FAKE_CONCLUDED_ISSUES:-} " in
          *" $n "*) echo '{"state":"OPEN","labels":[{"name":"concluded"}]}' ;;
          *) echo '{"state":"OPEN","labels":[]}' ;;
        esac
        ;;
    esac
    exit 0
  fi
  if [[ "$*" == *"--json number,labels"* ]]; then
    printf '{"number":%s,"labels":[]}' "$n"
    exit 0
  fi
  if [[ "$*" == *"--json state"* ]]; then
    case " ${FAKE_CLOSED_ISSUES:-} " in
      *" $n "*) echo "CLOSED" ;;
      *) echo "OPEN" ;;
    esac
    exit 0
  fi
  # Point reads still expose the stored label list; bulk reads above use the
  # same FAKE_ONHOLD_ISSUES fixture.
  case " ${FAKE_ONHOLD_ISSUES:-} " in
    *" $n "*) echo "on-hold" ;;
  esac
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
  n="$3"
  # body is whatever followed --body; just dump the whole invocation so
  # tests can grep for a marker inside it.
  echo "FAKE_GH_ISSUE_COMMENT #$n: $*"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "edit" ]; then
  n="$3"
  echo "FAKE_GH_ISSUE_EDIT #$n: $*"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  printf '%s\n' "${FAKE_PRS_JSON:-}"
  exit 0
fi
if [ "$1" = "api" ]; then
  path="$2"
  n="$(echo "$path" | grep -oE '/issues/[0-9]+/' | grep -oE '[0-9]+')"
  var="FAKE_COMMENTS_$n"
  printf '%s\n' "${!var:-}"
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/gh"

cat > "$FAKE_BIN/journalctl" <<'EOF'
#!/usr/bin/env bash
set -u
stage=""
for a in "$@"; do
  case "$a" in
    zenoforge-agent.service) stage="agent" ;;
    zenoforge-supervisor.service) stage="supervisor" ;;
    zf-*-\**) stage="$(echo "$a" | sed -E 's/^zf-(.*)-\*$/\1/')" ;;
  esac
done
var="FAKE_JOURNAL_$stage"
printf '%s\n' "${!var:-}"
exit 0
EOF
chmod +x "$FAKE_BIN/journalctl"

cat > "$FAKE_BIN/rg" <<'EOF'
#!/usr/bin/env bash
exec grep "$@"
EOF
chmod +x "$FAKE_BIN/rg"

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "$1" = "--user" ] && [ "$2" = "list-units" ]; then
  for a in "$@"; do
    if [ "$a" = 'zf-triage-*' ] && [ "${FAKE_TRIAGE_ACTIVE:-0}" = 1 ]; then
      echo 'zf-triage-batch.service loaded active running fake'
    fi
    case "$a" in
      zf-*.service)
        n="$(echo "$a" | sed -E 's/^zf-\*-([0-9]+)\.service$/\1/')"
        # FAKE_SYSTEMCTL_FAIL_<n>: issue_has_live_unit()'s own fail-closed
        # regression test -- a genuine "could not reach the manager" query
        # failure, not the ordinary zero-match success.
        failvar="FAKE_SYSTEMCTL_FAIL_$n"
        if [ -n "${!failvar:-}" ]; then
          echo "Failed to connect to user scope bus via local transport: No such file or directory" >&2
          exit 1
        fi
        var="FAKE_LIVE_UNIT_$n"
        [ -n "${!var:-}" ] && echo "$a loaded active running fake"
        ;;
    esac
  done
  exit 0
fi
if [ "$1" = "--user" ] && [ "$2" = "show" ] && [ "${5:-}" = "Result" ]; then
  case "${FAKE_SYSTEMD_OWNER_STATE:-unknown}" in
    inactive|active) echo success; exit 0 ;;
    *) echo 'Failed to connect to user scope bus' >&2; exit 1 ;;
  esac
fi
if [ "$1" = "--user" ] && [ "$2" = "show" ]; then
  echo "ActiveState=inactive"
  echo "ActiveEnterTimestamp="
  echo "LastTriggerUSec="
  exit 0
fi
if [ "$1" = "--user" ] && [ "$2" = "is-active" ] && [ "${4:-}" = "${FAKE_OWNER_UNIT_NAME:-}" ] && [ -n "${FAKE_OWNER_UNIT_NAME:-}" ]; then
  case "${FAKE_SYSTEMD_OWNER_STATE:-unknown}" in
    active) exit 0 ;;
    inactive) exit 3 ;;
    *) echo 'Failed to connect to user scope bus' >&2; exit 1 ;;
  esac
fi
exit 0
EOF
chmod +x "$FAKE_BIN/systemctl"

export PATH="$FAKE_BIN:$PATH"
export REPO="test/repo"
export ZF_AGENT_RECIPIENTS_FILE="/nonexistent/recipients.json"

run_once() {
  local agent_home
  agent_home="$(mktemp -d)"
  TMP_DIRS+=("$agent_home")
  export AGENT_HOME="$agent_home"
  mkdir -p "$agent_home/state" "$agent_home/spend"
  if [ -n "${STATE_FIXTURE_N:-}" ]; then
    echo "${STATE_FIXTURE_JSON:-{\}}" > "$agent_home/state/$STATE_FIXTURE_N.json"
  fi
  if [ -n "${SPEND_FIXTURE:-}" ]; then
    spend_file="$agent_home/spend/$(date -u +%Y-%m-%d).log"
    printf '%s\n' "$SPEND_FIXTURE" > "$spend_file"
    [ "${SPEND_FILE_UNREADABLE:-0}" = "1" ] && chmod 000 "$spend_file"
  fi
  set +e
  RUN_OUTPUT="$(bash "$SUPERVISOR_SRC" 2>&1)"
  RUN_STATUS=$?
  set -e
}

# --- scenario 1: AGENT_SUPERVISOR=off -> exits immediately, no checks -----
export FAKE_MODE="off"
run_once
assert_contains "off mode logs its own value" "$RUN_OUTPUT" "AGENT_SUPERVISOR=off"
assert_not_contains "off mode never reaches the findings summary" "$RUN_OUTPUT" "findings="
unset FAKE_MODE

# --- scenario 2: INV-1(a) advisor_ruled_at regression, observe mode -------
# A needs-advisor issue whose state already carries advisor_ruled_at --
# issue-pipeline.sh's own dispatch guard would skip it forever. Observe
# mode must report it and must NOT call state_merge or post a comment.
export FAKE_MODE="observe"
export FAKE_ISSUES_needs_advisor="1245"
export FAKE_ISSUES_ready_for_agent=""
export FAKE_ISSUES_needs_triage=""
export FAKE_ISSUES_needs_recut=""
export STATE_FIXTURE_N="1245"
export STATE_FIXTURE_JSON='{"attempts":1,"advisor_ruled_at":"2026-09-15T16:17:47Z"}'
run_once
assert_contains "observe: stale advisor_ruled_at on needs-advisor issue is flagged" \
  "$RUN_OUTPUT" "FINDING [inv1a] #1245"
assert_not_contains "observe mode never posts the heal comment" \
  "$RUN_OUTPUT" "FAKE_GH_ISSUE_COMMENT #1245"
unset STATE_FIXTURE_N STATE_FIXTURE_JSON

# --- scenario 3: same regression, act mode -> heals (state cleared, ------
# comment posted with the heal marker), and does not touch an issue with a
# live unit right now.
# 2026-09-19: STATE_FIXTURE_JSON now also seeds advisor_episode_seq (a
# ticket that already went through one episode before this regression, the
# realistic case, not a ticket that has never once been ruled on) and a
# leftover pending_advisor_verdict (belt-and-braces: proves the clear
# happens even though this specific trigger condition -- advisor_ruled_at
# present -- should never co-occur with a live pending verdict by
# construction elsewhere in this codebase; see this fix's own comment in
# supervise-pipeline.sh). Regression coverage for the bug this fix closes:
# this healer's own state_merge filter used to be a stale hand-copy of
# route_to_advisor()'s (lib.sh) filter from BEFORE that filter grew the
# episode-sequence guard (advisor-core.sh, 2026-09-19) -- a heal used to
# silently leave advisor_episode_seq unbumped, making the "new" episode
# indistinguishable from the one just healed away to advisor_persist_
# pending()/advisor_resume_check()'s own episode-seq comparison.
export FAKE_MODE="act"
export STATE_FIXTURE_N="1245"
export STATE_FIXTURE_JSON='{"attempts":1,"advisor_ruled_at":"2026-09-15T16:17:47Z","advisor_episode_seq":3,"pending_advisor_verdict":{"result":{},"input":{},"computed_at":"2026-09-01T00:00:00Z","episode_seq":3,"effects":{}}}'
run_once
assert_contains "act: heals by posting a comment with the heal marker" \
  "$RUN_OUTPUT" "zenoforge-supervisor-heal-advisor-ruled-at"
STATE_AFTER="$(cat "$AGENT_HOME/state/1245.json")"
assert_not_contains "act: state_merge actually cleared advisor_ruled_at on disk" \
  "$STATE_AFTER" "advisor_ruled_at"
assert_eq "act: THE FIX -- also clears a leftover pending_advisor_verdict (route_to_advisor()'s own filter does; this healer must match it byte for byte)" \
  "false" "$(jq 'has("pending_advisor_verdict")' <<< "$STATE_AFTER")"
assert_eq "act: THE FIX -- also bumps advisor_episode_seq (3 -> 4), so a stale in-flight reasoning pass from the healed-away episode can never be mistaken for belonging to the fresh one" \
  "4" "$(jq '.advisor_episode_seq' <<< "$STATE_AFTER")"
unset STATE_FIXTURE_N STATE_FIXTURE_JSON

# --- scenario 4: act mode, but a live unit is running for that issue ------
# right now -- must never fight another leg already working the ticket.
export FAKE_LIVE_UNIT_1245="1"
export STATE_FIXTURE_N="1245"
export STATE_FIXTURE_JSON='{"attempts":1,"advisor_ruled_at":"2026-09-15T16:17:47Z"}'
run_once
assert_not_contains "act: never heals an issue with a live zf-*-N unit right now" \
  "$RUN_OUTPUT" "FAKE_GH_ISSUE_COMMENT #1245"
STATE_AFTER="$(cat "$AGENT_HOME/state/1245.json")"
assert_contains "act: state is untouched while a live unit owns the ticket" \
  "$STATE_AFTER" "advisor_ruled_at"
unset FAKE_LIVE_UNIT_1245 STATE_FIXTURE_N STATE_FIXTURE_JSON FAKE_ISSUES_needs_advisor

# --- scenario 5: INV-1(b) dispatch stall -- population over the floor, ----
# no dispatch activity in the window -> flags. This also regression-covers
# the pipefail/SIGPIPE fix: the fake journalctl output below has multiple
# lines, exactly the shape that made a live `journalctl | grep -q` pipe
# report "no match" even when one existed (grep -q exits after the first
# match and SIGPIPEs a still-writing producer; under `set -o pipefail`
# that reads as the whole pipeline failing). If this regresses back to a
# live pipe, this scenario's "has activity -> not flagged" half (scenario
# 6) is what would catch it.
export FAKE_ISSUES_needs_recut="$(printf '1\n2\n3\n4\n5\n6')"
export FAKE_JOURNAL_recut=""
run_once
assert_contains "inv1b: backlog with zero dispatch activity in the window is flagged" \
  "$RUN_OUTPUT" "needs-recut has 6 open ticket(s) and no zf-recut-* unit"
unset FAKE_JOURNAL_recut

# --- scenario 6: same backlog, but journalctl shows recent activity -------
export FAKE_JOURNAL_recut="Sep 16 00:00:16 host systemd[1]: Started zf-recut-1.service.
Sep 16 00:05:16 host systemd[1]: Started zf-recut-2.service.
Sep 16 00:10:16 host systemd[1]: Started zf-recut-3.service."
run_once
assert_not_contains "inv1b: backlog with recent dispatch activity is NOT flagged" \
  "$RUN_OUTPUT" "needs-recut has"
unset FAKE_JOURNAL_recut FAKE_ISSUES_needs_recut

# --- repeated identical implement skips are one stall ---------------------
# Four decision rows cross the three-tick threshold. The finding must appear
# once for this episode, then the supervisor's own prior finding suppresses
# every later tick until a non-matching decision starts a new episode.
export FAKE_JOURNAL_agent="issue-pipeline: implement-decision tick=20260922T160000Z issue=#91010 outcome=skipped gate=merged-agent-pr object=PR #9001 reason=already merged
issue-pipeline: implement-decision tick=20260922T160500Z issue=#91010 outcome=skipped gate=merged-agent-pr object=PR #9001 reason=already merged
issue-pipeline: implement-decision tick=20260922T161000Z issue=#91010 outcome=skipped gate=merged-agent-pr object=PR #9001 reason=already merged
issue-pipeline: implement-decision tick=20260922T161500Z issue=#91010 outcome=skipped gate=merged-agent-pr object=PR #9001 reason=already merged"
export FAKE_JOURNAL_supervisor=""
run_once
STALL_MARKER="FINDING [inv10] implement-skip-stall issue=#91010 gate=merged-agent-pr start=20260922T160000Z"
assert_eq "inv10: same issue and gate repeating produces exactly one finding" \
  "1" "$(grep -cF "$STALL_MARKER" <<< "$RUN_OUTPUT" || true)"

export FAKE_JOURNAL_supervisor="supervise-pipeline: $STALL_MARKER"
run_once
assert_eq "inv10: an existing stall finding suppresses every later tick" \
  "0" "$(grep -cF "$STALL_MARKER" <<< "$RUN_OUTPUT" || true)"
unset FAKE_JOURNAL_agent FAKE_JOURNAL_supervisor

# Normal waits never become inv10 stalls after repeated identical skips.
for normal_gate in open-blocker capacity package-scope-cap active-implement dispatch-resources model-policy-transition; do
  export FAKE_JOURNAL_agent="issue-pipeline: implement-decision tick=20260922T180000Z issue=#91012 outcome=skipped gate=$normal_gate
issue-pipeline: implement-decision tick=20260922T180500Z issue=#91012 outcome=skipped gate=$normal_gate
issue-pipeline: implement-decision tick=20260922T181000Z issue=#91012 outcome=skipped gate=$normal_gate"
  export FAKE_JOURNAL_supervisor=""
  run_once
  assert_eq "inv10 ignores normal wait gate $normal_gate" "0" \
    "$(grep -cF "FINDING [inv10] implement-skip-stall issue=#91012 gate=$normal_gate" <<< "$RUN_OUTPUT" || true)"
done
unset FAKE_JOURNAL_agent FAKE_JOURNAL_supervisor

# --- repeated advisor lease bails are one report-only stall episode -------
export FAKE_JOURNAL_advisor="issue-pipeline: advisor-lease-decision tick=20260922T170000Z issue=#91011 outcome=busy
issue-pipeline: advisor-lease-decision tick=20260922T170500Z issue=#91011 outcome=busy
issue-pipeline: advisor-lease-decision tick=20260922T171000Z issue=#91011 outcome=busy"
export FAKE_JOURNAL_supervisor=""
run_once
LEASE_STALL_MARKER="FINDING [inv10b] advisor-lease-bail-stall issue=#91011 start=20260922T170000Z"
assert_eq "inv10b: consecutive lease bails produce exactly one finding" \
  "1" "$(grep -cF "$LEASE_STALL_MARKER" <<< "$RUN_OUTPUT" || true)"

export FAKE_JOURNAL_supervisor="supervise-pipeline: $LEASE_STALL_MARKER"
run_once
assert_eq "inv10b: an existing lease-bail finding suppresses repeats in one episode" \
  "0" "$(grep -cF "$LEASE_STALL_MARKER" <<< "$RUN_OUTPUT" || true)"

export FAKE_JOURNAL_advisor="issue-pipeline: advisor-lease-decision tick=20260922T170000Z issue=#91011 outcome=busy
issue-pipeline: advisor-lease-decision tick=20260922T170500Z issue=#91011 outcome=busy
issue-pipeline: advisor-lease-decision tick=20260922T171000Z issue=#91011 outcome=busy
issue-pipeline: advisor-lease-decision tick=20260922T171500Z issue=#91011 outcome=clear
issue-pipeline: advisor-lease-decision tick=20260922T172000Z issue=#91011 outcome=busy
issue-pipeline: advisor-lease-decision tick=20260922T172500Z issue=#91011 outcome=busy
issue-pipeline: advisor-lease-decision tick=20260922T173000Z issue=#91011 outcome=busy"
run_once
NEXT_LEASE_STALL_MARKER="FINDING [inv10b] advisor-lease-bail-stall issue=#91011 start=20260922T172000Z"
assert_eq "inv10b: a clear decision starts one new stall episode" \
  "1" "$(grep -cF "$NEXT_LEASE_STALL_MARKER" <<< "$RUN_OUTPUT" || true)"
unset FAKE_JOURNAL_advisor FAKE_JOURNAL_supervisor

# INV-7 has an evidence-based 10-call floor and stays report-only. The two
# 2026-09-23 six-call windows (5/1 and 4/2) must not become maintainer mail;
# meaningful concentration remains visible as a finding.
export FAKE_MODE=act
unset VELOCITY_FLOOR_CALLS VELOCITY_CONCENTRATION_RATIO
export AGENT_DRY_RUN=1
rows=""
for issue in 1625 1625 1625 1625 1625 1420; do
  rows+="${rows:+$'\n'}$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$(date -u +%s)" advisor "$MODEL_POLICY_TEST_ADVISOR_IDENTITY" "$issue" '' '')"
done
export SPEND_FIXTURE="$rows"
run_once
assert_not_contains "inv7: six calls across two tickets stay below the measured floor" \
  "$RUN_OUTPUT" "FINDING [inv7]"
assert_not_contains "inv7: six-call concentration sends no maintainer email" \
  "$RUN_OUTPUT" "最近一小时的模型调用高度集中"

rows=""
for issue in 1625 1625 1625 1625 1625 1625 1625 1625 1420 1425; do
  rows+="${rows:+$'\n'}$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$(date -u +%s)" advisor "$MODEL_POLICY_TEST_ADVISOR_IDENTITY" "$issue" '' '')"
done
export SPEND_FIXTURE="$rows"
run_once
assert_contains "inv7: ten concentrated calls remain visible as a finding" \
  "$RUN_OUTPUT" "FINDING [inv7] 10 model calls in the last 60min"
assert_not_contains "inv7: report-only concentration never sends maintainer mail" \
  "$RUN_OUTPUT" "最近一小时的模型调用高度集中"
unset AGENT_DRY_RUN SPEND_FIXTURE VELOCITY_FLOOR_CALLS VELOCITY_CONCENTRATION_RATIO

# --- 2026-09-16 fix: heal_advisor_ruled_at_regression() must not post the
# --- "healed it" comment when its own state_merge clear failed -----------
# Same class as route_to_advisor()/route_to_recut() (lib.sh, this same
# fix): a bare state_merge call here, followed unconditionally by
# guarded_write gh issue comment, would post a comment claiming the field
# was cleared even when it was not -- worse than lib.sh's own version of
# this bug, since issue_comment_has_marker() then makes this function
# believe on every future run that it already healed the ticket and never
# try again. Static, not behavioral: reaching the failure from outside
# would need a state file that is malformed by the time this function's
# own state_merge runs, but check_advisor_ruled_at_regression()'s `has=...
# || echo false` upstream already treats a malformed file as "not
# regressed" and never calls this function at all -- lib.test.sh's own
# route_to_advisor/route_to_recut/give_up_on_issue tests already prove the
# underlying guard shape behaves correctly on a real state_merge failure.
assert_eq "heal_advisor_ruled_at_regression: state_merge's clear is checked before posting the healed-it comment" \
  "1" "$(awk '/^heal_advisor_ruled_at_regression\(\) \{/,/^\}/' "$SUPERVISOR_SRC" | grep -cF "state_merge \"\$n\" 'del(.advisor_ruled_at, .pending_advisor_verdict) | .advisor_episode_seq = ((.advisor_episode_seq // 0) + 1)' || {")"

# --- scenario 8: 2026-09-16 fix (instance 5) -- an on-hold ticket must -----
# never be mutated by a supervisor action, only by scheduling. Same
# regression fixture as scenario 3 (a genuine advisor_ruled_at regression,
# act mode) but the ticket is on-hold: must be left alone, exactly like the
# existing live-unit deferral in scenario 4.
export FAKE_MODE="act"
export FAKE_ISSUES_needs_advisor="1245"
export FAKE_ONHOLD_ISSUES="1245"
export STATE_FIXTURE_N="1245"
export STATE_FIXTURE_JSON='{"attempts":1,"advisor_ruled_at":"2026-09-15T16:17:47Z"}'
run_once
assert_not_contains "act: never heals an on-hold issue, even with a genuine regression" \
  "$RUN_OUTPUT" "FAKE_GH_ISSUE_COMMENT #1245"
STATE_AFTER="$(cat "$AGENT_HOME/state/1245.json")"
assert_contains "act: state is untouched while the issue is on-hold" \
  "$STATE_AFTER" "advisor_ruled_at"
unset FAKE_ONHOLD_ISSUES STATE_FIXTURE_N STATE_FIXTURE_JSON

# --- scenario 9: 2026-09-16 fix (instance 4) -- issue_has_live_unit() must -
# fail closed (treat as LIVE) when systemctl itself cannot be queried, not
# treat an unreadable answer as "confirmed idle". Same regression fixture
# as scenario 3, but systemctl's own query for #1245 fails outright (a
# session-bus outage, not "no unit found") -- must be left alone exactly
# like the confirmed-live-unit case in scenario 4.
export FAKE_MODE="act"
export FAKE_ISSUES_needs_advisor="1245"
export FAKE_SYSTEMCTL_FAIL_1245="1"
export STATE_FIXTURE_N="1245"
export STATE_FIXTURE_JSON='{"attempts":1,"advisor_ruled_at":"2026-09-15T16:17:47Z"}'
run_once
assert_not_contains "act: never heals an issue when systemctl itself could not be queried" \
  "$RUN_OUTPUT" "FAKE_GH_ISSUE_COMMENT #1245"
STATE_AFTER="$(cat "$AGENT_HOME/state/1245.json")"
assert_contains "act: state is untouched when the live-unit query itself failed" \
  "$STATE_AFTER" "advisor_ruled_at"
unset FAKE_SYSTEMCTL_FAIL_1245 STATE_FIXTURE_N STATE_FIXTURE_JSON

# The supervisor retains one ledger reader for report-only spend velocity.
READER_HOME="$(mktemp -d)"
TMP_DIRS+=("$READER_HOME")
SUPERVISOR_LIBRARY_DIR="$(mktemp -d)"
TMP_DIRS+=("$SUPERVISOR_LIBRARY_DIR")
copy_agent_library "$SUPERVISOR_LIBRARY_DIR"
sed '/^[[:space:]]*main "\$@"/d' "$SUPERVISOR_SRC" > "$SUPERVISOR_LIBRARY_DIR/supervise-pipeline.sh"

# The hand-dispatch stop path must end the leader's whole session while sparing
# same-name work in another session. A non-leader PID must only stop itself.
DISPATCH_SESSION_HOME="$(mktemp -d)"
TMP_DIRS+=("$DISPATCH_SESSION_HOME")
SUPERVISOR_SESSION_OUT="$(bash -s -- "$SCRIPT_DIR/night/hand-agent-watchdog.sh" \
  "$CHECK_HAND_DISPATCHES_FN" "$DISPATCH_SESSION_HOME" <<'SESSION_TEST'
set -euo pipefail
source "$1"
eval "$2"
root="$3"
HAND_AGENT_STOP_GRACE_SECONDS=1
AGENT_HOME="$root/agent-home"
ZF_AGENT_NAME=issue-2763-session-test
tracked_pids=()
cleanup() {
  local pid
  for pid in "${tracked_pids[@]:-}"; do kill -KILL "$pid" 2>/dev/null || true; done
  for pid in "${tracked_pids[@]:-}"; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

proc_state() {
  local pid="$1" stat_line rest state
  IFS= read -r stat_line < "/proc/$pid/stat" 2>/dev/null || return 1
  rest="${stat_line##*) }"
  read -r state _ <<< "$rest"
  printf '%s\n' "$state"
}
pid_alive() {
  local state
  kill -0 "$1" 2>/dev/null || return 1
  state="$(proc_state "$1")" || return 1
  [ "$state" != Z ]
}
proc_session() {
  local pid="$1" stat_line rest state ppid pgrp sid
  IFS= read -r stat_line < "/proc/$pid/stat" 2>/dev/null || return 1
  rest="${stat_line##*) }"
  read -r state ppid pgrp sid _ <<< "$rest"
  printf '%s\n' "$sid"
}
wait_file() {
  local file="$1" i
  for i in {1..3000}; do [ -s "$file" ] && return 0; sleep 0.01; done
  return 1
}
wait_dead() {
  local pid="$1" i
  for i in {1..600}; do pid_alive "$pid" || return 0; sleep 0.05; done
  return 1
}
spawn_agent_session() {
  local file="$1"
  setsid env "ZF_AGENT_NAME=$ZF_AGENT_NAME" bash -c '
    trap "exit 0" TERM
    bash -c "trap \"\" TERM; exec sleep 120" &
    printf "%s %s\n" "$$" "$!" > "$1"
    wait
  ' _ "$file" >/dev/null 2>&1 &
  tracked_pids+=("$!")
  wait_file "$file"
  read -r agent_pid descendant_pid < "$file"
  tracked_pids+=("$agent_pid" "$descendant_pid")
  [ "$(proc_session "$agent_pid")" = "$agent_pid" ]
}
spawn_peer() {
  local file="$root/peer.pid"
  setsid env "ZF_AGENT_NAME=$ZF_AGENT_NAME" bash -c '
    printf "%s\n" "$$" > "$1"
    exec sleep 120
  ' _ "$file" >/dev/null 2>&1 &
  tracked_pids+=("$!")
  wait_file "$file"
  peer_pid="$(cat "$file")"
  tracked_pids+=("$peer_pid")
  peer_name="$(tr "\0" "\n" < "/proc/$peer_pid/environ" | sed -n "s/^ZF_AGENT_NAME=//p")"
  [ "$(proc_session "$peer_pid")" = "$peer_pid" ]
}
spawn_peer
spawn_agent_session "$root/dispatch-session.pid"
HAND_DISPATCH_DIR="$root/dispatch"
HAND_DISPATCH_STALL_SECONDS=60
mkdir -p "$HAND_DISPATCH_DIR"
hand_dispatch_pid_state() { echo live; }
hand_dispatch_agent_is_stalled() { return 0; }
checkpoint_hand_dispatch_worktree() { return 0; }
hand_dispatch_set_status() { return 0; }
finding() { :; }
jq -n --arg pid "$agent_pid" \
  '{id:"fixture",status:"running",pid:$pid,pid_start_ticks:"1",kind:"review",model:"gpt-6-luna",effort:"max",access:"investigation",worktree:"/tmp/fixture",branch:"agent/fixture",brief_file:"/tmp/brief.md",log_file:"/tmp/log.md"}' \
  > "$HAND_DISPATCH_DIR/fixture.json"
MODE=act
check_hand_dispatches
if wait_dead "$descendant_pid"; then echo DISPATCH_DESCENDANT=dead; else echo DISPATCH_DESCENDANT=alive; fi
if pid_alive "$peer_pid"; then echo PEER_ALIVE_AFTER_DISPATCH=yes; else echo PEER_ALIVE_AFTER_DISPATCH=no; fi
echo PEER_AGENT_NAME="$peer_name"

# A PID inside a session it does not lead gets PID-only TERM. Keep its leader
# and sibling alive to pin that session boundary.
setsid env "ZF_AGENT_NAME=$ZF_AGENT_NAME" bash -c '
  sleep 120 & first=$!
  sleep 120 & second=$!
  printf "%s %s %s\n" "$$" "$first" "$second" > "$1"
  wait
' _ "$root/nonleader-session.pid" >/dev/null 2>&1 &
tracked_pids+=("$!")
wait_file "$root/nonleader-session.pid"
read -r session_leader nonleader_pid session_sibling < "$root/nonleader-session.pid"
tracked_pids+=("$session_leader" "$nonleader_pid" "$session_sibling")
if [ "$(proc_session "$nonleader_pid")" = "$session_leader" ]; then echo NONLEADER_SESSION=confirmed; else echo NONLEADER_SESSION=wrong; fi
nonleader_stop_rc=0
hand_agent_stop_session "$nonleader_pid" || nonleader_stop_rc=$?
if wait_dead "$nonleader_pid"; then echo NONLEADER_PID=dead; else echo NONLEADER_PID=alive; fi
if pid_alive "$session_leader"; then echo NONLEADER_SESSION_LEADER=alive; else echo NONLEADER_SESSION_LEADER=dead; fi
if pid_alive "$session_sibling"; then echo NONLEADER_SESSION_SIBLING=alive; else echo NONLEADER_SESSION_SIBLING=dead; fi
echo NONLEADER_STOP_RC="$nonleader_stop_rc"
SESSION_TEST
)"
assert_eq "stalled hand dispatch stop ends leader descendants" dead "$(sed -n 's/^DISPATCH_DESCENDANT=//p' <<< "$SUPERVISOR_SESSION_OUT")"
assert_eq "same-name session survives hand-dispatch stop" yes "$(sed -n 's/^PEER_ALIVE_AFTER_DISPATCH=//p' <<< "$SUPERVISOR_SESSION_OUT")"
assert_eq "peer keeps matching ZF_AGENT_NAME" issue-2763-session-test "$(sed -n 's/^PEER_AGENT_NAME=//p' <<< "$SUPERVISOR_SESSION_OUT")"
assert_eq "non-leader fixture shares leader session" confirmed "$(sed -n 's/^NONLEADER_SESSION=//p' <<< "$SUPERVISOR_SESSION_OUT")"
assert_eq "non-leader runner alone gets stopped" dead "$(sed -n 's/^NONLEADER_PID=//p' <<< "$SUPERVISOR_SESSION_OUT")"
assert_eq "non-leader session leader survives" alive "$(sed -n 's/^NONLEADER_SESSION_LEADER=//p' <<< "$SUPERVISOR_SESSION_OUT")"
assert_eq "non-leader session sibling survives" alive "$(sed -n 's/^NONLEADER_SESSION_SIBLING=//p' <<< "$SUPERVISOR_SESSION_OUT")"
assert_eq "non-leader stop helper succeeds" 0 "$(sed -n 's/^NONLEADER_STOP_RC=//p' <<< "$SUPERVISOR_SESSION_OUT")"


READER_FIXTURE="$(printf '%s\n%s' \
  "$(date -u +%s)	advisor	$MODEL_POLICY_TEST_ADVISOR_IDENTITY	91010	" \
  "$(date -u +%s)	implement	$MODEL_POLICY_TEST_WORK_IDENTITY	91010		714051")"
READER_ROWS="$({
  set +e
  bash -c '
    export AGENT_HOME="$2"
    mkdir -p "$AGENT_HOME/spend" "$AGENT_HOME/state"
    source "$1/supervise-pipeline.sh"
    printf "%s\n" "$3" > "$(spend_file_for_day "$(date +%s)")"
    echo legacy:
    spend_rows_since 0
  ' _ "$SUPERVISOR_LIBRARY_DIR" "$READER_HOME" "$READER_FIXTURE"
  true
})"
assert_eq "spend ledger reader returns legacy and new rows intact" \
  "legacy:
$READER_FIXTURE" "$READER_ROWS"

echo
# --- 2026-09-16: `echo "$big" | grep -q` reports "not found" on a match ------
# Measured live, not reasoned about: the dispatch-stall check captured 116KB
# of journal text and asked `echo "$activity" | grep -q "Started zf-
# implement-"`. `grep -q` exits at its first match, SIGPIPEs the still-writing
# `echo`, and `set -o pipefail` then reports the whole pipeline as failed --
# so the check concluded "no implement unit started in the last 60min" while
# zf-implement-1320 had started 40 minutes earlier and was still running.
# The earlier fix for this exact class captured the producer into a variable
# first, which removed the JOURNALCTL pipe but left the ECHO pipe, and the
# echo is just as capable of being killed. A here-string has no pipe and no
# second process to kill. Guard both halves: the pattern is gone from every
# non-test script, and the replacement actually answers correctly on a
# payload far larger than a pipe buffer. The match sits at the TOP of the
# fixture on purpose: that is the only arrangement that makes `grep -q` exit
# while the producer still has data to write, which is what triggers this.
BIG_HAYSTACK="Started zf-implement-1320.service
$(printf 'filler line %s\n' $(seq 1 12000))"
if grep -q "Started zf-implement-" <<< "$BIG_HAYSTACK"; then
  HERESTRING_RESULT=found
else
  HERESTRING_RESULT=missed
fi
assert_eq "a 100KB+ haystack still answers 'found' (no SIGPIPE through a here-string)" \
  "found" "$HERESTRING_RESULT"

assert_eq "no production agent script pipes a captured variable into grep -q" \
  "0" "$(grep -rln '" | grep -q' "$SUPERVISOR_LIBRARY_DIR"/*.sh 2>/dev/null | grep -vc '\.test\.sh$' || true)"

# --- 2026-09-16: `local` reading a name it declares in the same statement ---
# `cooldown_ready()` was written as
#   local name="$1" secs="$2" f="$SUPERVISOR_COOLDOWN_DIR/$name" last
# and under `set -u` that aborts with `name: unbound variable` even when the
# caller DID pass both arguments -- verified directly, not reasoned about.
# It stayed latent while nothing called it, then fired the moment INV-7
# started alerting and killed every supervisor run at its last invariant,
# after the earlier findings had already printed. Both halves are guarded:
# the function answers correctly under `set -euo pipefail`, and no
# production agent script declares and reads the same name in one `local`
# -- that second half is deliberately NOT a grep over source text: every
# regex tried here matched this file's own explanatory comment and a
# two-statement line that is perfectly correct, and a guard that cries wolf
# gets weakened later. A one-off scan of the tree found exactly this one
# occurrence; the behavioural check below is what actually holds.
COOLDOWN_PROBE="$(bash -c '
  set -euo pipefail
  AGENT_HOME="$1"
  MODE=observe
  source "$2/supervise-pipeline.sh" >/dev/null 2>&1 || true
  if cooldown_ready "probe-never-marked" 60; then echo ready; else echo blocked; fi
' _ "$(mktemp -d)" "$SUPERVISOR_LIBRARY_DIR" 2>&1 | tail -1)"
assert_eq "cooldown_ready answers under set -u instead of aborting on its own local" \
  "ready" "$COOLDOWN_PROBE"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
