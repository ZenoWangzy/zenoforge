#!/usr/bin/env bash
# Focused recovery tests for supervise-pipeline.sh. No network or production.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR_SRC="$SCRIPT_DIR/supervise-pipeline.sh"
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

assert_dir() {
  local desc="$1" dir="$2"
  if [ -d "$dir" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (missing [$dir])"
    FAILED=1
  fi
}

TEST_ROOT="$(mktemp -d)"
FAKE_BIN="$TEST_ROOT/bin"
LIBRARY_DIR="$TEST_ROOT/library"
ORIGIN="$TEST_ROOT/origin.git"
PRIMARY="$TEST_ROOT/primary"
DIRTY_WORKTREE="$TEST_ROOT/dirty-worktree"
UNIQUE_WORKTREE="$TEST_ROOT/unique-worktree"
CLEAN_WORKTREE="$TEST_ROOT/clean-worktree"
PID_FILE="$TEST_ROOT/live.pid"
FAKE_DISPATCH_ARGS_FILE="$TEST_ROOT/dispatch-args"
FAKE_POSTSUBMIT_LOG="$TEST_ROOT/postsubmit-queries.log"
export FAKE_POSTSUBMIT_LOG
trap 'if [ -s "$PID_FILE" ]; then kill "$(cat "$PID_FILE")" 2>/dev/null || true; fi; rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$FAKE_BIN" "$LIBRARY_DIR"
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = variable ] && [ "${2:-}" = get ]; then
  echo observe
elif [ "${1:-}" = api ] && [[ "${2:-}" == repos/*/commits/main ]]; then
  jq -cn --arg sha "${FAKE_MAIN_SHA:-}" \
    '{sha:$sha,commit:{committer:{date:"2026-10-21T00:00:00Z"}}}'
elif [ "${1:-}" = api ] && [[ "${2:-}" == *"/actions/runs/801/jobs?per_page=100"* ]]; then
  printf '%s\n' '{"jobs":[{"id":1801,"name":"Postsubmit validate","status":"completed","conclusion":"success"}]}'
elif [ "${1:-}" = api ] && [[ "${2:-}" == *"/actions/runs?head_sha="* ]]; then
  postsubmit_url="${2:-}"
  postsubmit_url="${postsubmit_url%%&created=*}"
  printf '%s\n' "$postsubmit_url" >> "${FAKE_POSTSUBMIT_LOG:?}"
  postsubmit_sha="${postsubmit_url#*head_sha=}"
  postsubmit_sha="${postsubmit_sha%%&*}"
  if [ "$postsubmit_sha" = "${FAKE_MAIN_SHA:-}" ]; then
    jq -cn --arg sha "$postsubmit_sha" \
      '{workflow_runs:[{id:801,head_sha:$sha,head_branch:"main",event:"push",path:".github/workflows/ci.yml",status:"completed",conclusion:"success"}]}'
  else
    printf '%s\n' '{"workflow_runs":[]}'
  fi
elif [ "${1:-}" = run ] && [ "${2:-}" = list ]; then
  if [[ " $* " == *" --workflow ci.yml "* && " $* " == *" --branch main "* ]]; then
    # GitHub's branch-filtered listing was stale for this workflow (newest 2026-09-21).
    printf '[]\n'
  elif [[ " $* " == *" --workflow ci.yml "* ]]; then
    # The unfiltered history is stale too; it cannot prove the current source SHA.
    printf '%s\n' '[{"headSha":"ffffffffffffffffffffffffffffffffffffffff","headBranch":"main","status":"completed","conclusion":"failure"}]'
  fi
elif [ "${1:-}" = run ] && [ "${2:-}" = view ]; then
  if [ "${FAKE_BUILD_CAPACITY:-0}" = 1 ] && [[ " $* " == *" --json status,conclusion "* ]]; then
    printf '%s\n' '{"status":"completed","conclusion":"failure"}'
  elif [[ " $* " == *" --json jobs "* ]]; then
    # gh applies the supplied --jq program before printing.
    if [ "${FAKE_BUILD_NEXUS_AUTH:-0}" = 1 ]; then
      printf '%s\n' 'Ensure production Nexus is running'
    elif [ "${FAKE_BUILD_CAPACITY:-0}" = 1 ]; then
      printf '%s\n' 'Preflight production build runner'
    else
      printf '%s\n' 'Download selected the product source'
    fi
  elif [[ " $* " == *" --log-failed "* ]]; then
    if [ "${FAKE_BUILD_NEXUS_AUTH:-0}" = 1 ]; then
      printf '%s\n' $'build\tEnsure production Nexus is running\t2026-10-08T12:01:29Z curl: (22) The requested URL returned error: 401'
      printf '%s\n' $'build\tEnsure production Nexus is running\t2026-10-08T12:01:29Z ##[error]Process completed with exit code 22.'
    elif [ "${FAKE_BUILD_CAPACITY:-0}" = 1 ]; then
      printf '%s\n' 'at least 60GiB free disk is required'
    else
      printf '%s\n' 'source_sha must be the current the product main HEAD'
    fi
    printf '%s\n' 'Error: Process completed with exit code 1'
  fi
elif [ "${1:-}" = workflow ] && [ "${2:-}" = run ]; then
  printf '%q ' "$@" >> "${FAKE_GH_LOG:?}"
  printf '\n' >> "${FAKE_GH_LOG:?}"
fi
EOF
chmod +x "$FAKE_BIN/gh"
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --user ] && [ "${2:-}" = list-units ]; then
  exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/systemctl"
cat > "$FAKE_BIN/ssh" <<'SSHEOF'
#!/usr/bin/env bash
# cihost root df, as the build-capacity probe reads it.
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fake 1000000000 1 %s 1%% /\n' "${FAKE_CIHOST_AVAIL_KB:-125829120}"
SSHEOF
chmod +x "$FAKE_BIN/ssh"

git init -q --bare "$ORIGIN"
git init -q -b main "$PRIMARY"
git -C "$PRIMARY" config user.name test
git -C "$PRIMARY" config user.email test@example.invalid
printf '%s\n' seed > "$PRIMARY/seed.txt"
git -C "$PRIMARY" add seed.txt
git -C "$PRIMARY" commit -qm seed
git -C "$PRIMARY" remote add origin "$ORIGIN"
git -C "$PRIMARY" push -qu origin main
git -C "$PRIMARY" fetch -q origin
git -C "$PRIMARY" worktree add -q -b manual-dirty "$DIRTY_WORKTREE" main
git -C "$PRIMARY" worktree add -q -b manual-unique "$UNIQUE_WORKTREE" main
git -C "$PRIMARY" worktree add -q -b manual-clean "$CLEAN_WORKTREE" main

copy_agent_library "$LIBRARY_DIR"
sed '/^main "\$@"/d' "$SUPERVISOR_SRC" > "$LIBRARY_DIR/supervise-pipeline.sh"
# ensure-ci-runner-disk.sh sits beside engine, outside the helper's
# closure; lib.sh loads it through its optional [[ -r ]] guard.
cp "$SCRIPT_DIR/ci-runner-disk-floor.sh" "$LIBRARY_DIR/ci-runner-disk-floor.sh"
cat > "$LIBRARY_DIR/dispatch-codex.sh" <<'EOF'
#!/usr/bin/env bash
printf '<%s>\n' "$@" > "${FAKE_DISPATCH_ARGS_FILE:?}"
EOF
chmod +x "$LIBRARY_DIR/dispatch-codex.sh"

export PATH="$FAKE_BIN:$PATH"
export AGENT_HOME="$TEST_ROOT/agent-home"
export ZF_REPO_DIR="$PRIMARY"
export REPO="test/repo"
export FAKE_DISPATCH_ARGS_FILE
mkdir -p "$AGENT_HOME/state" "$AGENT_HOME/spend" "$AGENT_HOME/night"
: > "$AGENT_HOME/night/agents.txt"
# shellcheck source=/dev/null
source "$LIBRARY_DIR/supervise-pipeline.sh"

RECOVERY_FUNCTIONS=1
for fn in hand_dispatch_agent_is_stalled cleanup_hand_dispatch_worktree relaunch_hand_dispatch classify_build_failure; do
  if ! declare -F "$fn" >/dev/null; then
    echo "not ok - supervisor exposes $fn"
    FAILED=1
    RECOVERY_FUNCTIONS=0
  fi
done

# A current log plus a verified PID/start identity is live work, not a stall.
if [ "$RECOVERY_FUNCTIONS" -eq 1 ]; then
  # shellcheck disable=SC2016
  setsid --fork bash -c 'printf "%s\n" "$$" > "$1"; exec -a "codex exec --cd $2 -" sleep 60' _ "$PID_FILE" "$DIRTY_WORKTREE"
  for _ in $(seq 1 50); do [ -s "$PID_FILE" ] && break; sleep 0.02; done
  LIVE_PID="$(cat "$PID_FILE")"
  LIVE_TICKS="$(awk '{print $22}' "/proc/$LIVE_PID/stat")"
  LIVE_LOG="$TEST_ROOT/live.log"
  touch "$LIVE_LOG"
  assert_eq "live agent never classified stalled" "false" \
    "$(if hand_dispatch_agent_is_stalled "$LIVE_PID" "$LIVE_TICKS" "$DIRTY_WORKTREE" "$LIVE_LOG"; then echo true; else echo false; fi)"

  clean_head="$(git -C "$CLEAN_WORKTREE" rev-parse HEAD)"
  cleanup_hand_dispatch_worktree "$CLEAN_WORKTREE" manual-clean
  assert_eq "clean dead hand-dispatch worktree is removed" "false" "$(test -d "$CLEAN_WORKTREE" && echo true || echo false)"
  assert_eq "clean hand-dispatch branch is removed" "false" "$(git -C "$PRIMARY" show-ref --verify --quiet refs/heads/manual-clean && echo true || echo false)"
  grep -Fq $'removed-worktree\tclean-worktree\t'"$clean_head" "$AGENT_HOME/night/worktree-cleanup-manifest.txt" \
    && echo "ok - clean hand-dispatch cleanup records name and head" \
    || { echo "not ok - clean hand-dispatch cleanup omitted manifest record"; FAILED=1; }

  # Both shapes are actual output. Cleanup must leave their worktrees intact.
  printf '%s\n' partial > "$DIRTY_WORKTREE/partial.txt"
  cleanup_hand_dispatch_worktree "$DIRTY_WORKTREE" manual-dirty || true
  assert_dir "worktree with uncommitted material or unique commits is never cleaned (uncommitted)" "$DIRTY_WORKTREE"

  printf '%s\n' committed > "$UNIQUE_WORKTREE/committed.txt"
  git -C "$UNIQUE_WORKTREE" add committed.txt
  git -C "$UNIQUE_WORKTREE" commit -qm unique
  cleanup_hand_dispatch_worktree "$UNIQUE_WORKTREE" manual-unique || true
  assert_dir "worktree with uncommitted material or unique commits is never cleaned (unique commits)" "$UNIQUE_WORKTREE"

  assert_eq "build failure: missing container runtime is environment" \
    "environment:runner-container-runtime" \
    "$(classify_build_failure failure 'Set up job' 'Error: no container runtime available' abc abc)"
  assert_eq "build failure: exact production disk gate is a capacity environment fault" \
    "environment:build-capacity" \
    "$(classify_build_failure failure 'Preflight production build runner' 'at least 60GiB free disk is required' abc abc)"
  assert_eq "build failure: proxy timeout is environment" \
    "environment:proxy-timeout" \
    "$(classify_build_failure failure 'Build and push production images' 'proxy request timed out' abc abc)"
  assert_eq "build failure: live-main source mismatch is superseded environment" \
    "environment:source-sha-superseded" \
    "$(classify_build_failure failure 'Download selected the product source' 'source_sha must be the current the product main HEAD' old live)"
  assert_eq "build failure: Postsubmit evidence alone is not guessed as product" \
    "unknown" \
    "$(classify_build_failure failure 'Require exact-SHA the product Postsubmit evidence' 'verification failed' abc abc)"
  FAKE_BUILD_NEXUS_AUTH=1 build_failure_evidence 99
  assert_contains "Nexus auth evidence survives the prefixed runner epilogue" "$BUILD_FAILURE_LINE" \
    'curl: (22) The requested URL returned error: 401'
  for nexus_step in 'Ensure production Nexus is running' 'Provision production Nexus repositories'; do
    assert_eq "Nexus 401 is an environment fault at $nexus_step" 'environment:nexus-auth' \
      "$(classify_build_failure failure "$nexus_step" "$BUILD_FAILURE_LINE" abc abc)"
  done
  assert_eq "Nexus repository provisioning 401 uses the same environment route" 'environment:nexus-auth' \
    "$(classify_build_failure failure 'Provision production Nexus repositories' 'Error: GET /repositories/zf-npm-proxy -> 401: Unauthorized' abc abc)"
  assert_eq "Nexus 401 persists only a credential-free label" 'http-401' \
    "$(safe_build_failure_line "$BUILD_FAILURE_LINE")"
  assert_eq "401 in the product build step still requires product repair" 'product' \
    "$(classify_build_failure failure 'Build and push production images' "$BUILD_FAILURE_LINE" abc abc)"
  assert_eq "other Nexus errors are not guessed as authentication failures" 'unknown' \
    "$(classify_build_failure failure 'Ensure production Nexus is running' 'curl: (22) The requested URL returned error: 500' abc abc)"
  build_failure_evidence 99
  assert_eq "failed build evidence keeps failed step" "Download selected the product source" "$BUILD_FAILURE_STEP"
  assert_eq "failed build evidence skips generic runner epilogue" \
    "source_sha must be the current the product main HEAD" "$BUILD_FAILURE_LINE"
  assert_eq "failed build evidence never persists arbitrary output" \
    "failed-step-output-redacted" "$(safe_build_failure_line arbitrary-failed-step-output)"
  assert_eq "build capacity evidence is persisted as a safe fixed label" \
    "production-build-disk-capacity-gate" \
    "$(safe_build_failure_line 'at least 60GiB free disk is required')"
  assert_eq "build failure: cancelled stale source is superseded" \
    "environment:superseded" \
    "$(classify_build_failure cancelled '' '' old live)"
  assert_eq "build failure: build step defect is product" \
    "product" \
    "$(classify_build_failure failure 'Build and push production images' 'npm ERR! build failed' abc abc)"

  # One build's result fans out to every issue in its range; an environment fault counts once per
  # build, and a superseded build is no fault at all (2026-10-05: 28 hits from one build).
  BUILD_FAULT_LOG="$TEST_ROOT/build-env-faults.log"
  for build_kind in environment:superseded environment:proxy-timeout environment:nexus-auth; do
    : > "$BUILD_FAULT_LOG"
    (
      git() { case "$*" in *merge-base*) return 1 ;; *) echo base ;; esac; }
      issue_numbers_in_range() { printf '%s\n' 11 12 13; }
      issue_has_live_unit() { return 1; }
      state_merge() { :; }
      record_env_fault() { printf '%s\n' "$1" >> "$BUILD_FAULT_LOG"; }
      record_build_result_on_issues 0123456789abcdef0123456789abcdef01234567 "$build_kind" 991 cancelled 'Build and push production images' 'line'
    )
    case "$build_kind" in
      environment:superseded) assert_eq "a superseded build records no environment fault" 0 "$(grep -c . "$BUILD_FAULT_LOG" || true)" ;;
      *) assert_eq "an environment build fault counts once per build, not per issue" 1 "$(grep -c . "$BUILD_FAULT_LOG" || true)" ;;
    esac
    if [ "$build_kind" = environment:nexus-auth ]; then
      assert_eq "Nexus auth enters the release environment ledger" 'env:production-image-build:nexus-auth' \
        "$(cat "$BUILD_FAULT_LOG")"
    fi
  done

  # Continuous release always dispatches current main after its own green
  # Postsubmit; it records the request before the side effect and never pins
  # an older source from a previous pass.
  LIVE_SHA=0123456789abcdef0123456789abcdef01234567
  OLD_SHA=abcdef0123456789abcdef0123456789abcdef0123
  export FAKE_MAIN_SHA="$LIVE_SHA" FAKE_GH_LOG="$TEST_ROOT/gh.log"
  : > "$FAKE_GH_LOG"
  # shellcheck disable=SC2034 # sourced recovery functions read both globals
  MODE=act
  # shellcheck disable=SC2034 # sourced recovery functions read both globals
  DRY_RUN=0

  RECOVERY_BRIEF="$TEST_ROOT/recovery-brief.md"
  RECOVERY_RECORD="$TEST_ROOT/recovery-record.json"
  printf '%s\n' 'Recover one safe unit.' > "$RECOVERY_BRIEF"
  printf '%s\n' '{"status":"running"}' > "$RECOVERY_RECORD"
  : > "$FAKE_DISPATCH_ARGS_FILE"
  if relaunch_hand_dispatch "$RECOVERY_RECORD" delivery-record production other-model xhigh delivery \
    "$DIRTY_WORKTREE" manual-dirty "$RECOVERY_BRIEF"; then
    RECOVERY_STATUS=0
  else
    RECOVERY_STATUS=1
  fi
  assert_eq "unapproved delivery identity is refused" "1" "$RECOVERY_STATUS"
  assert_eq "unapproved delivery identity never invokes dispatcher" "" "$(cat "$FAKE_DISPATCH_ARGS_FILE")"
  assert_eq "unapproved delivery record stays unrecovered" "running" "$(jq -r '.status' "$RECOVERY_RECORD")"

  printf '%s\n' '{"status":"running"}' > "$RECOVERY_RECORD"
  if relaunch_hand_dispatch "$RECOVERY_RECORD" legacy-work-record work other-model max investigation \
    "$DIRTY_WORKTREE" manual-dirty "$RECOVERY_BRIEF"; then
    LEGACY_WORK_STATUS=0
  else
    LEGACY_WORK_STATUS=1
  fi
  assert_eq "unapproved work identity is refused by the current work role" "1" "$LEGACY_WORK_STATUS"

  for current_contract in \
    'work work investigation' \
    'hard work delivery' \
    'production production delivery'; do
    read -r CURRENT_KIND CURRENT_POLICY_ROLE CURRENT_ACCESS <<< "$current_contract"
    CURRENT_IDENTITY="$(model_policy identity "$CURRENT_POLICY_ROLE")"
    CURRENT_MODEL_EFFORT="${CURRENT_IDENTITY#*:}"
    IFS=: read -r CURRENT_MODEL CURRENT_EFFORT <<< "$CURRENT_MODEL_EFFORT"
    printf '%s\n' '{"status":"running"}' > "$RECOVERY_RECORD"
    : > "$FAKE_DISPATCH_ARGS_FILE"
    if relaunch_hand_dispatch "$RECOVERY_RECORD" current-record "$CURRENT_KIND" "$CURRENT_MODEL" "$CURRENT_EFFORT" "$CURRENT_ACCESS" \
      "$DIRTY_WORKTREE" manual-dirty "$RECOVERY_BRIEF"; then
      CURRENT_STATUS=0
    else
      CURRENT_STATUS=1
    fi
    assert_eq "$CURRENT_KIND current model/access contract replays" "0" "$CURRENT_STATUS"
    assert_eq "$CURRENT_KIND replay marks record recovered" "recovered" "$(jq -r '.status' "$RECOVERY_RECORD")"
  done

  CURRENT_WORK_IDENTITY="$(model_policy identity work)"
  CURRENT_WORK_MODEL_EFFORT="${CURRENT_WORK_IDENTITY#*:}"
  IFS=: read -r CURRENT_WORK_MODEL CURRENT_WORK_EFFORT <<< "$CURRENT_WORK_MODEL_EFFORT"

  : > "$FAKE_DISPATCH_ARGS_FILE"
  if relaunch_hand_dispatch "$RECOVERY_RECORD" invalid-access work "$CURRENT_WORK_MODEL" "$CURRENT_WORK_EFFORT" unbounded \
    "$DIRTY_WORKTREE" manual-dirty "$RECOVERY_BRIEF"; then
    INVALID_ACCESS_STATUS=0
  else
    INVALID_ACCESS_STATUS=1
  fi
  assert_eq "unknown persisted access is refused" "1" "$INVALID_ACCESS_STATUS"
  assert_eq "unknown persisted access never invokes dispatcher" "" "$(cat "$FAKE_DISPATCH_ARGS_FILE")"

  LEGACY_LOG="$TEST_ROOT/legacy.log"
  LEGACY_RECORD="$HAND_DISPATCH_DIR/legacy-record.json"
  touch "$LEGACY_LOG"
  mkdir -p "$HAND_DISPATCH_DIR"
  jq -n --arg worktree "$DIRTY_WORKTREE" --arg brief "$RECOVERY_BRIEF" --arg log_file "$LEGACY_LOG" \
    '{id: "legacy-record", status: "running", pid: 99999999, pid_start_ticks: "1", kind: "production", model: "retired-identity", effort: "xhigh", worktree: $worktree, branch: "manual-dirty", brief_file: $brief, log_file: $log_file}' \
    > "$LEGACY_RECORD"
  : > "$FAKE_DISPATCH_ARGS_FILE"
  check_hand_dispatches
  assert_eq "retired model record is not replayed" "" "$(cat "$FAKE_DISPATCH_ARGS_FILE")"
  assert_eq "retired model record stays unrecovered" "running" "$(jq -r '.status' "$LEGACY_RECORD")"

  CURRENT_LOG="$TEST_ROOT/current.log"
  CURRENT_RECORD="$HAND_DISPATCH_DIR/current-record.json"
  touch "$CURRENT_LOG"
  jq -n --arg worktree "$DIRTY_WORKTREE" --arg brief "$RECOVERY_BRIEF" --arg log_file "$CURRENT_LOG" \
    --arg model "$CURRENT_WORK_MODEL" --arg effort "$CURRENT_WORK_EFFORT" \
    '{id: "current-record", status: "running", pid: 99999999, pid_start_ticks: "1", kind: "work", model: $model, effort: $effort, access: "delivery", worktree: $worktree, branch: "manual-dirty", brief_file: $brief, log_file: $log_file}' \
    > "$CURRENT_RECORD"
  : > "$FAKE_DISPATCH_ARGS_FILE"
  check_hand_dispatches
  assert_contains "current record replays its delivery access" "$(cat "$FAKE_DISPATCH_ARGS_FILE")" "<delivery>"
  assert_eq "current work record recovery succeeds" "recovered" "$(jq -r '.status' "$CURRENT_RECORD")"

  release_record_write "$OLD_SHA" dispatching "" "" "" "" "" "$OLD_SHA"
  : > "$FAKE_POSTSUBMIT_LOG"
  check_release_reconciliation
  check_release_reconciliation
  assert_eq "continuous release queries exact live SHA despite stale CI history" \
    "repos/example-maintainer/example-repo/actions/runs?head_sha=$LIVE_SHA&per_page=100&page=1" \
    "$(cat "$FAKE_POSTSUBMIT_LOG")"
  assert_eq "continuous release dispatches exactly live main SHA" "1" \
    "$(grep -cF -- "source_sha=$LIVE_SHA" "$FAKE_GH_LOG" || true)"
  assert_eq "continuous release never re-dispatches an older pinned SHA" "0" \
    "$(grep -cF -- "source_sha=$OLD_SHA" "$FAKE_GH_LOG" || true)"
  assert_eq "continuous release records dispatch before async build discovery" "dispatching" \
    "$(jq -r '.status' "$RELEASE_RECOVERY_DIR/$LIVE_SHA.json")"
  assert_eq "continuous release records the exact validation run beside the source SHA" "801" \
    "$(jq -r '.validation.run_id' "$RELEASE_RECOVERY_DIR/$LIVE_SHA.json")"

  CAPACITY_SHA=abcdefabcdefabcdefabcdefabcdefabcdefabcd
  NEW_SHA=0123012301230123012301230123012301230123
  export FAKE_MAIN_SHA="$CAPACITY_SHA" FAKE_BUILD_CAPACITY=1
  export FAKE_CIHOST_AVAIL_KB=83886080
  : > "$FAKE_GH_LOG"
  release_record_write "$CAPACITY_SHA" running 991 "" "" "" "" "$CAPACITY_SHA"
  jq '.dispatched_at = "2000-01-01T00:00:00Z"' "$RELEASE_RECOVERY_DIR/$CAPACITY_SHA.json" \
    > "$RELEASE_RECOVERY_DIR/$CAPACITY_SHA.json.tmp"
  mv "$RELEASE_RECOVERY_DIR/$CAPACITY_SHA.json.tmp" "$RELEASE_RECOVERY_DIR/$CAPACITY_SHA.json"
  check_release_reconciliation
  assert_eq "supervisor classifies build disk-gate failure as a capacity wait" "capacity-wait" \
    "$(jq -r '.status' "$RELEASE_RECOVERY_DIR/$CAPACITY_SHA.json")"
  assert_eq "supervisor records capacity in shared environment taxonomy once" "1" \
    "$(wc -l < "$ENV_FAULT_DIR/env:build-capacity.log")"
  assert_eq "supervisor opens release capacity quarantine" "yes" \
    "$([ -f "$(quarantine_file release)" ] && echo yes || echo no)"

  export FAKE_MAIN_SHA="$NEW_SHA"
  check_release_reconciliation
  assert_eq "supervisor does not dispatch a new main SHA while release capacity is quarantined" "0" \
    "$(grep -cF 'workflow run build-cihost-images.yml' "$FAKE_GH_LOG" || true)"
  check_release_reconciliation
  assert_eq "repeated capacity-wait checks do not duplicate the shared fault" "1" \
    "$(wc -l < "$ENV_FAULT_DIR/env:build-capacity.log")"

  export FAKE_CIHOST_AVAIL_KB=125829120
  reconcile_quarantines 1800000023
  assert_eq "cihost capacity recovery lifts supervisor release quarantine" "no" \
    "$([ -f "$(quarantine_file release)" ] && echo yes || echo no)"
  export FAKE_MAIN_SHA="$CAPACITY_SHA"
  check_release_reconciliation
  assert_eq "same main SHA resumes build automatically after capacity recovery" "1" \
    "$(grep -cF -- "source_sha=$CAPACITY_SHA" "$FAKE_GH_LOG" || true)"
  assert_eq "resumed dispatch keeps prior capacity failure evidence" "991" \
    "$(jq -r '.capacity_failure.run_id' "$RELEASE_RECOVERY_DIR/$CAPACITY_SHA.json")"
  assert_eq "resumed dispatch refreshes discovery window" "false" \
    "$(jq -r '.dispatched_at == "2000-01-01T00:00:00Z"' "$RELEASE_RECOVERY_DIR/$CAPACITY_SHA.json")"
  check_release_reconciliation
  assert_eq "automatic capacity recovery dispatches the SHA only once" "1" \
    "$(grep -cF -- "source_sha=$CAPACITY_SHA" "$FAKE_GH_LOG" || true)"
  unset FAKE_BUILD_CAPACITY
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "ALL PASS"
