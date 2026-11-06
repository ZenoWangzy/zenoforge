#!/usr/bin/env bash
# Regression tests for run-advisor-batch.sh, the batch advisor sweep built
# 2026-09-16 alongside run-advisor.sh (one ticket per dispatch) -- see that
# script's own header for how the two coexist. Plain bash assertions, no
# framework -- same shape as run-advisor.test.sh: fake gh/codex/
# gitnexus on PATH, run the real script as a subprocess against a
# throwaway git fixture and a throwaway copy of engine/ (stub prompts
# keep wrapper scenarios independent of full prompt context; focused prompt
# assertions below read the real advisor-batch.md).
#
# node is NOT faked: advisor_footprint_risky() (lib.sh) calls the real
# risk-class.mjs -- same discipline run-advisor.test.sh already applies,
# not re-derived here. Every fixture ticket below declares an empty
# expected_packages, so that check is a fast no-op (count=0 short-circuits)
# for every scenario in this file; risk-class.mjs's own pattern coverage is
# exercised by run-advisor.test.sh, once, not re-proven here.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENGINE_DIR="$OPS_DIR"

TEST_JQ_HOME="$HOME"
TEST_JQ_BIN="$(command -v jq)"
TEST_DATE_BIN="$(command -v date)"
export TEST_JQ_HOME TEST_JQ_BIN TEST_DATE_BIN

SCRIPT_DIR="$ENGINE_DIR"
PRODUCT_REPO="$(cd -- "$OPS_DIR/.." && pwd -P)"
# The suite later points ZF_CONFIG_ROOT at an empty directory, so the library under test resolves the Engine's own
# default. Fixtures must come from that same file: a checkout's .zenoforge copy (an engine placed at <repo>/engine)
# can forbid or allow different models and make the persistent-policy migration reject the fixtures.
MODEL_POLICY_DEFAULT_FILE="$ENGINE_DIR/model-policy.default.json"
ADVISOR_BATCH_PROMPT_FILE="$(export ZF_REPO_DIR="$PRODUCT_REPO"; source "$ENGINE_DIR/config.sh"; zf_config_file prompts/advisor-batch.md)"
OVERSIZE_ONLY=0
if [ "${1:-}" = "--oversize-only" ]; then OVERSIZE_ONLY=1; fi
QUARANTINE_ONLY=0
if [ "${1:-}" = "--quarantine-only" ]; then QUARANTINE_ONLY=1; OVERSIZE_ONLY=1; fi
QUOTA_PATH_429_ONLY=0
if [ "${1:-}" = "--quota-path-429-only" ]; then QUOTA_PATH_429_ONLY=1; fi
BUSY_POLL_ONLY=0
if [ "${1:-}" = "--busy-poll-only" ]; then BUSY_POLL_ONLY=1; fi
JSON_NORMALIZATION_ONLY=0
if [ "${1:-}" = "--json-normalization-only" ]; then JSON_NORMALIZATION_ONLY=1; fi
RESERVATION_ONLY=0
if [ "${1:-}" = "--reservation-only" ]; then RESERVATION_ONLY=1; fi
LOOP_BREAKER_ONLY=0
if [ "${1:-}" = "--loop-breaker-only" ]; then LOOP_BREAKER_ONLY=1; fi
TAB_FAULT_ONLY=0
if [ "${1:-}" = "--tab-fault-only" ]; then TAB_FAULT_ONLY=1; fi
TRIM_ONLY=0
if [ "${1:-}" = "--trim-only" ]; then TRIM_ONLY=1; fi

FAILED=0
TMP_DIRS=()
TEST_HOME="$(mktemp -d)"
TMP_DIRS+=("$TEST_HOME")
export HOME="$TEST_HOME"
cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  # 2026-09-19: run-advisor-batch.sh no longer checks out a single fixed
  # $HOME/wt/advisor-batch directory -- each scenario below that reaches
  # the worktree step now gets its own $HOME/wt/advisor-run-<id> (real
  # $HOME, same as before this fix; none of these scenarios override it).
  # Every scenario that completes (all of them do, see each one's own
  # `exits 0` assertion) already removes its own directory via this
  # script's normal KEEP_WORKTREE=0-on-success path -- this glob is only
  # the same belt-and-suspenders backstop the old single-name `rm -rf`
  # was, now matched to the new naming pattern so a failed/aborted test
  # run doesn't leave a stray checkout under the real $HOME.
  rm -rf "$HOME"/wt/advisor-run-*
}
trap cleanup EXIT

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
    echo "not ok - $desc (expected NOT to find [$needle])"
    FAILED=1
  fi
}

# assert_true/assert_false (2026-09-19, the advisor execution locking
# scenario below): same shape as lib.test.sh's own helpers of the same
# name -- this file never needed them before now.
assert_true() {
  local desc="$1"; shift
  if "$@"; then
    echo "ok - $desc"
  else
    echo "not ok - $desc"
    FAILED=1
  fi
}

assert_false() {
  local desc="$1"; shift
  if ! "$@"; then
    echo "ok - $desc"
  else
    echo "not ok - $desc"
    FAILED=1
  fi
}

# Lock the constraints in the prompt that the web advisor actually receives.
FAKE_SCRIPT_ROOT="$(mktemp -d)"
FAKE_SCRIPT_DIR="$FAKE_SCRIPT_ROOT/engine"
TMP_DIRS+=("$FAKE_SCRIPT_ROOT")
mkdir -p "$FAKE_SCRIPT_ROOT/scripts"
copy_agent_library "$FAKE_SCRIPT_DIR" run-advisor-batch.sh
cp "$OPS_DIR/run-advisor-batch.sh" "$FAKE_SCRIPT_DIR/run-advisor-batch.sh"
jq 'del(.roles.advisor.disabled) | .switches["roadmap-order"] = false' "$MODEL_POLICY_DEFAULT_FILE" \
  > "$FAKE_SCRIPT_DIR/model-policy.default.json"
echo "stub advisor prompt" > "$FAKE_SCRIPT_DIR/prompts/advisor.md"
echo "stub advisor-batch prompt" > "$FAKE_SCRIPT_DIR/prompts/advisor-batch.md"
chmod +x "$FAKE_SCRIPT_DIR/run-advisor-batch.sh"
BATCH_SRC="$FAKE_SCRIPT_DIR/run-advisor-batch.sh"

# Batch now uses the shared async web-advisor-provider transport. Stub that transport at
# the lib seam: first invocation creates a completed local job, second poll
# consumes its fixture response. No real browser/CDP/model call in this suite.
cat >> "$FAKE_SCRIPT_DIR/lib.sh" <<'EOF'
web_advisor_provider_usable() { return 0; }
web_advisor_provider_ndjson_request_bytes() {
  local prompt_file="$1"
  {
    printf '%s\n\n' "You are answering as this pipeline's automated advisor. Reply with exactly one valid JSON object matching the batch prompt's advisor_batch_result envelope. Include the exact requested_issues manifest and one complete ruling for every issue. Do not use Markdown fences, NDJSON, or prose."
    cat "$prompt_file"
  } | LC_ALL=C wc -c | tr -d '[:space:]'
}
web_advisor_provider_dispatch_ndjson_async() {
  local job_id="$1" prompt_file="$2"
  local job_dir="$WEB_ADVISOR_PROVIDER_JOB_DIR/$job_id"
  [ -n "${FAKE_FD_CAPTURE:-}" ] && ls -la /proc/self/fd > "$FAKE_FD_CAPTURE" 2>&1
  mkdir -p "$job_dir"
  cp "$prompt_file" "${FAKE_WEB_ADVISOR_PROVIDER_PROMPT_LOG:-/dev/null}"
  cp "$prompt_file" "$job_dir/question.txt"
  printf '%s' "${FAKE_BATCH_NDJSON:-}" > "$job_dir/answer.out"
  printf '%s\n' "${FAKE_BATCH_ANSWER_ERR:-本次实际使用：fake-web / max}" > "$job_dir/answer.err"
  if [ "${FAKE_BATCH_STILL_RUNNING:-0}" != "1" ]; then
    printf '0\n' > "$job_dir/done"
  fi
  printf 'dispatch:%s topic:%s\n' "$job_id" "${WEB_ADVISOR_PROVIDER_TOPIC:-}" >> "${FAKE_WEB_ADVISOR_PROVIDER_LOG:-/dev/null}"
}
web_advisor_provider_dispatch_question_async() {
  local FAKE_BATCH_NDJSON="${FAKE_REASK_ANSWER:-$FAKE_BATCH_NDJSON}"
  web_advisor_provider_dispatch_ndjson_async "$1" "$2"
}
web_advisor_provider_model_fallback_signature_from_log() { return 0; }
web_advisor_provider_poll_ndjson() {
  local job_dir="$WEB_ADVISOR_PROVIDER_JOB_DIR/$1"
  [ "${FAKE_BATCH_POLL_STATUS:-0}" = "0" ] || return "$FAKE_BATCH_POLL_STATUS"
  [ -f "$job_dir/done" ] || return 2
  cat "$job_dir/answer.out"
}
web_advisor_provider_model_used() {
  sed -n 's/^本次实际使用：//p' "$1" 2>/dev/null | tail -n 1
}
web_advisor_provider_model_fallback() {
  sed -n 's/^MODEL_FALLBACK: //p' "$1" 2>/dev/null | tail -n 1
}
web_advisor_provider_normalize_batch_json() {
  node -e '
    let text = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => { text += chunk; });
    process.stdin.on("end", () => {
      text = text.replace(/:chatgpt-content-reference\{index="\d+"\}/g, "");
      text = text.replaceAll("service_tier=\"fast\"", "service_tier=\\\"fast\\\"");
      process.stdout.write(text);
    });
  '
}
web_advisor_provider_forget_job() {
  rm -rf -- "$WEB_ADVISOR_PROVIDER_JOB_DIR/$1"
}
web_advisor_provider_fault_signature() {
  local normalized="${1,,}"
  case "$normalized" in
    *'advisor_tab_unresponsive'*|*'tab-unresponsive'*|*'tab unresponsive'*)
      printf 'env:web-advisor-provider:tab-unresponsive\n' ;;
    *) printf 'env:web-advisor-provider:failure\n' ;;
  esac
}
record_web_advisor_provider_fault() {
  local issue="$1" detail="$2" now="${3:-$(date +%s)}" signature
  signature="$(web_advisor_provider_fault_signature "$detail")"
  record_env_fault "$signature" advisor "$issue" "$detail" "" "$now" 0
}
run_web_advisor_provider_ndjson() {
  local prompt_file="$1"
  cp "$prompt_file" "${FAKE_WEB_ADVISOR_PROVIDER_PROMPT_LOG:-/dev/null}"
  printf '%s' "${FAKE_BATCH_NDJSON:-}"
}
notify_maintainer() {
  printf 'subject=%s\nbody=%s\n' "$1" "$2" >> "${FAKE_NOTIFY_LOG:-/dev/null}"
}
send_email() {
  local subject="$1" body="$2" issue="$3"; shift 3
  printf 'subject=%s\nissue=%s\nargs=%s\nbody=\n%s\n' \
    "$subject" "$issue" "$*" "$body" >> "$AGENT_HOME/emails.log"
  if [ "${1:-}" = "--maintainer-kind" ] && [ "${2:-}" = "decision" ]; then
    local rejection
    rejection="$(maintainer_mail_rejection_reason decision "$subject" "$body")"
    [ -z "$rejection" ] || return 0
  fi
  [ "${FAKE_EMAIL_SEND_FAIL_ISSUE:-}" != "$issue" ] || return 0
  [ "${DRY_RUN:-0}" != "1" ] || return 0
  echo "fixture-thread-$issue"
}
EOF

# --- fake gh/codex/gitnexus, shadowing the real binaries on PATH ----------
FAKE_BIN="$(mktemp -d)"
TMP_DIRS+=("$FAKE_BIN")
cat > "$FAKE_BIN/jq" <<'EOF'
#!/usr/bin/env bash
HOME="$TEST_JQ_HOME" \
LD_LIBRARY_PATH="$TEST_JQ_HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  exec "$TEST_JQ_BIN" "$@"
EOF
chmod +x "$FAKE_BIN/jq"
cat > "$FAKE_BIN/date" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "+%s%N" && "$#" -eq 1 && -n "${FAKE_DATE_NS:-}" ]]; then
  printf '%s\n' "$FAKE_DATE_NS"
else
  exec "$TEST_DATE_BIN" "$@"
fi
EOF
chmod +x "$FAKE_BIN/date"

# Fake gh: dispatches on the exact --json field list `issue view` was asked
# for, since this script asks for three different shapes of the same verb
# (the full ticket fetch, is_on_hold()'s bare `labels`, and the duplicate_of
# existence check's bare `number`) -- never touches real GitHub.
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
sub="$1 ${2:-}"
case "$sub" in
  "issue view")
    n="$3"
    json_fields="" prev=""
    for a in "$@"; do
      [ "$prev" = "--json" ] && json_fields="$a"
      prev="$a"
    done
    if [ "$json_fields" = "number,title,body,author,comments,createdAt,labels,state" ] \
      && [ -n "${FAKE_GH_VIEW_LOG:-}" ]; then
      echo "$n" >> "$FAKE_GH_VIEW_LOG"
    fi
    if [ "$json_fields" = "number,title,body,author,comments,createdAt,labels,state" ] \
      && [ -n "${FAKE_GH_VIEW_COUNTS:-}" ]; then
      view_count="$(awk -v issue="$n" '$1 == issue {print $2}' "$FAKE_GH_VIEW_COUNTS")"
      view_count=$(( ${view_count:-0} + 1 ))
      awk -v issue="$n" '$1 != issue' "$FAKE_GH_VIEW_COUNTS" > "$FAKE_GH_VIEW_COUNTS.tmp"
      printf '%s %s\n' "$n" "$view_count" >> "$FAKE_GH_VIEW_COUNTS.tmp"
      mv "$FAKE_GH_VIEW_COUNTS.tmp" "$FAKE_GH_VIEW_COUNTS"
      if [ "$n" = "${FAKE_GH_VIEW_FAIL_ISSUE:-}" ] \
        && [ "$view_count" -ge "${FAKE_GH_VIEW_FAIL_FROM_CALL:-0}" ] \
        && [ "$view_count" -le "${FAKE_GH_VIEW_FAIL_UNTIL_CALL:-0}" ]; then
        echo "${FAKE_GH_VIEW_FAIL_TEXT:-Post \"https://api.github.com/graphql\": net/http: TLS handshake timeout}" >&2
        exit 1
      fi
    fi
    case "$json_fields" in
      number,labels)
        if [ "$n" = "${FAKE_PIPELINE_SYSTEM_ISSUE:-}" ]; then
          echo "{\"number\":$n,\"labels\":[{\"name\":\"needs-advisor\"},{\"name\":\"pipeline-system\"}]}"
        else
          echo "{\"number\":$n,\"labels\":[{\"name\":\"needs-advisor\"}]}"
        fi
        ;;
      number,title,body,author,comments,createdAt,labels,state)
        # FAKE_COMMENTS_ISSUE/FAKE_COMMENTS_JSON: lets exactly one test
        # scenario (the trim test) seed a ticket with real .comments
        # content, without touching every other scenario's default [].
        if [ "$n" = "${FAKE_COMMENTS_ISSUE:-}" ]; then
          comments_json="$FAKE_COMMENTS_JSON"
        else
          comments_json="[]"
        fi
        body_json='null'
        if [ -n "${FAKE_BODY_CONTENT_FILE_ALL:-}" ]; then
          body_json="$(jq -Rs . < "$FAKE_BODY_CONTENT_FILE_ALL")"
        elif [ "$n" = "${FAKE_BODY_ISSUE:-}" ]; then
          if [ -n "${FAKE_BODY_CONTENT_FILE:-}" ]; then
            body_json="$(jq -Rs . < "$FAKE_BODY_CONTENT_FILE")"
          else
            body_json="$(printf '%s' "${FAKE_BODY_CONTENT:-}" | jq -Rs .)"
          fi
        elif [ "$n" = "${FAKE_BODY_ISSUE_2:-}" ]; then
          if [ -n "${FAKE_BODY_CONTENT_FILE_2:-}" ]; then
            body_json="$(jq -Rs . < "$FAKE_BODY_CONTENT_FILE_2")"
          else
            body_json="$(printf '%s' "${FAKE_BODY_CONTENT_2:-}" | jq -Rs .)"
          fi
        fi
        issue_state=OPEN
        case " ${FAKE_CLOSED_ISSUES:-} " in *" $n "*) issue_state=CLOSED ;; esac
        if [ "$n" = "${FAKE_PIPELINE_SYSTEM_ISSUE:-}" ]; then
          labels_json='[{"name":"needs-advisor"},{"name":"pipeline-system"}]'
        else
          labels_json='[{"name":"needs-advisor"}]'
        fi
        echo "{\"number\":$n,\"title\":\"batch test issue #$n\",\"body\":$body_json,\"author\":{\"login\":\"testuser\"},\"comments\":$comments_json,\"createdAt\":\"2026-01-01T00:00:00Z\",\"labels\":$labels_json,\"state\":\"$issue_state\"}"
        ;;
      state)
        case " ${FAKE_CLOSED_ISSUES:-} " in *" $n "*) echo CLOSED ;; *) echo OPEN ;; esac
        ;;
      author) echo '{"author":{"login":"testuser"}}' ;;
      labels)
        case " ${FAKE_ONHOLD_ISSUES:-} " in
          *" $n "*) echo "on-hold" ;;
        esac
        ;;
      state,labels)
        issue_state=OPEN
        case " ${FAKE_CLOSED_ISSUES:-} " in *" $n "*) issue_state=CLOSED ;; esac
        echo "{\"state\":\"$issue_state\",\"labels\":[{\"name\":\"needs-advisor\"}]}"
        ;;
      number,state)
        # duplicate_of validation (apply_one_ruling's `duplicate` verdict,
        # run-advisor-batch.sh): FAKE_REAL_ISSUES names issues that exist
        # at all; FAKE_CLOSED_ISSUES (a subset of those) names ones that
        # exist but are CLOSED -- the 2026-09-16 fix's own regression
        # target (prompts/advisor-batch.md requires an OPEN survivor).
        # Everything in FAKE_REAL_ISSUES not also in FAKE_CLOSED_ISSUES is
        # OPEN.
        case " ${FAKE_REAL_ISSUES:-} " in
          *" $n "*)
            case " ${FAKE_CLOSED_ISSUES:-} " in
              *" $n "*) echo "{\"number\":$n,\"state\":\"CLOSED\"}" ;;
              *) echo "{\"number\":$n,\"state\":\"OPEN\"}" ;;
            esac
            ;;
          *) exit 1 ;;
        esac
        ;;
    esac
    exit 0 ;;
  "issue list")
    label=""; prev=""
    for arg in "$@"; do
      [ "$prev" = "--label" ] && label="$arg"
      prev="$arg"
    done
    if [ "$label" = "on-hold" ]; then
      for n in ${FAKE_ONHOLD_ISSUES:-}; do echo "$n"; done
    else
      # The queue read asks for the full view fields, so each listed ticket
      # carries the same JSON the `issue view` fake below returns.
      queue_json="[]"
      for n in ${FAKE_ISSUE_LIST:-}; do
        queue_json="$(jq -c --argjson n "$n" '. + [{number:$n,title:"batch test issue #\($n)",body:null,author:{login:"testuser"},comments:[],createdAt:"2026-01-01T00:00:00Z",labels:[{name:"needs-advisor"}],state:"OPEN"}]' <<< "$queue_json")"
      done
      echo "$queue_json"
    fi
    exit 0 ;;
  "api "*)
    case "${2:-}" in
      */sub_issues\?per_page=100) printf '%s\n' "${FAKE_NATIVE_SUB_ISSUES_JSON:-[]}" ;;
    esac
    exit 0 ;;
  "issue edit"|"issue comment"|"issue close")
    n="$3"
    if [ "$n" = "${FAKE_GH_APPLY_FAIL_ISSUE:-}" ] \
      && [ "$sub" = "${FAKE_GH_APPLY_FAIL_SUBCOMMAND:-}" ] \
      && { [ -z "${FAKE_GH_APPLY_FAIL_MATCH:-}" ] || [[ " $* " == *"${FAKE_GH_APPLY_FAIL_MATCH}"* ]]; }; then
      echo "${FAKE_GH_APPLY_FAIL_TEXT:-simulated gh write failure}" >&2
      exit 1
    fi
    echo "gh $*" >> "$FAKE_GH_LOG"
    if [ "$sub" = "issue comment" ] && [ "${FAKE_GH_CAPTURE_BODY:-0}" = "1" ]; then
      body_file="" prev=""
      for arg in "$@"; do
        [ "$prev" = "--body-file" ] && body_file="$arg"
        prev="$arg"
      done
      if [ -n "$body_file" ] && [ -f "$body_file" ]; then
        printf 'comment-body:\n' >> "$FAKE_GH_LOG"
        cat "$body_file" >> "$FAKE_GH_LOG"
        printf '\n' >> "$FAKE_GH_LOG"
      fi
    fi
    exit 0 ;;
  "label create"|"label list") exit 0 ;;
  "variable get")
    case "${3:-}" in
      AGENT_PHASE) echo "${FAKE_AGENT_PHASE:-2}" ;;
      *) exit 1 ;;
    esac ;;
  *) : ;;
esac
exit 0
EOF

# Fake codex: writes $FAKE_BATCH_NDJSON to --output-last-message, logs which
# model it was asked for, exits $FAKE_CODEX_STATUS (default 0).
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -u
# FAKE_FD_CAPTURE (2026-09-20, the run_with_fd_closed() regression below):
# a real fd inheritance check, not a proxy -- if a per-ticket claim fd
# survives exec into this fake binary, its underlying file (the lock path, a
# symlink target under /proc/self/fd) is right here to grep for.
[ -n "${FAKE_FD_CAPTURE:-}" ] && ls -la /proc/self/fd > "$FAKE_FD_CAPTURE" 2>&1
out="" model="" prev=""
for a in "$@"; do
  case "$prev" in
    --output-last-message) out="$a" ;;
    -m) model="$a" ;;
  esac
  prev="$a"
done
cat > "${FAKE_CODEX_PROMPT_LOG:-/dev/null}"
echo "$model" >> "${FAKE_CODEX_LOG:-/dev/null}"
if [ "${FAKE_CODEX_STATUS:-0}" != "0" ]; then
  echo "Error: simulated codex failure" >&2
  exit "${FAKE_CODEX_STATUS}"
fi
printf '%s' "${FAKE_BATCH_NDJSON:-}" > "$out"
echo "tokens used" >&2
echo "${FAKE_BATCH_TOKENS:-222,333}" >&2
exit 0
EOF

cat > "$FAKE_BIN/gitnexus" <<'EOF'
#!/usr/bin/env bash
echo "up-to-date"
exit 0
EOF

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"is-active"*) exit 3 ;;
  *) exit 0 ;;
esac
EOF

chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/codex" "$FAKE_BIN/gitnexus" "$FAKE_BIN/systemctl"
export PATH="$FAKE_BIN:$PATH"
# lib.sh computes REPO from ZF_REPO (never inherits a bare REPO env var
# -- see its own `REPO="${ZF_REPO:-...}"` line), so ZF_REPO is the
# one that actually takes effect once lib.sh is sourced.
export ZF_REPO="test/repo"
export ZF_GCLOUD_BIN="/nonexistent/gcloud"
export WEB_ADVISOR_PROVIDER_TOPIC="pipeline-advisor"
export ZF_CONFIG_ROOT="$FAKE_SCRIPT_ROOT/config"
mkdir -p "$ZF_CONFIG_ROOT"
printf '{"advisor":{"provider":"web-advisor-provider"}}\n' > "$ZF_CONFIG_ROOT/night.json"

# --- one shared git fixture -------------------------------------------------
FIXTURE_ORIGIN="$(mktemp -d)"
FIXTURE_REPO="$(mktemp -d)"
TMP_DIRS+=("$FIXTURE_ORIGIN" "$FIXTURE_REPO")
git init -q --bare "$FIXTURE_ORIGIN"
git -C "$FIXTURE_ORIGIN" symbolic-ref HEAD refs/heads/main
git -C "$FIXTURE_REPO" init -q -b main
git -C "$FIXTURE_REPO" config user.email test@example.com
git -C "$FIXTURE_REPO" config user.name "Test"
mkdir -p "$FIXTURE_REPO/engine" "$FIXTURE_REPO/.zenoforge"
cat > "$FIXTURE_REPO/.zenoforge/advisor.json" <<'JSON'
{"commentDisclaimer":"> *This was generated by AI during triage.* This comment is posted by the automated the product agent pipeline under the maintainer's GitHub account — it is not the maintainer writing personally. <!-- vecta-agent-comment -->"}
JSON
jq 'del(.roles.advisor.disabled)' "$MODEL_POLICY_DEFAULT_FILE" \
  > "$FIXTURE_REPO/.zenoforge/model-policy.default.json"
echo seed > "$FIXTURE_REPO/seed.txt"
git -C "$FIXTURE_REPO" add -A
git -C "$FIXTURE_REPO" commit -q -m seed
git -C "$FIXTURE_REPO" remote add origin "$FIXTURE_ORIGIN"
git -C "$FIXTURE_REPO" push -q -u origin main

export ZF_REPO_DIR="$FIXTURE_REPO"

OWNER_WORKTREE_ROOT="$(mktemp -d)"
TMP_DIRS+=("$OWNER_WORKTREE_ROOT")
OWNER_WORKTREE="$OWNER_WORKTREE_ROOT/checkout"
git -C "$FIXTURE_REPO" worktree add -q -b node-auto-owner/fixture "$OWNER_WORKTREE" origin/main

state_field() {
  # state_field <agent_home> <n> <jq filter>
  jq -r "$3" "$1/state/$2.json" 2>/dev/null
}

# Real tick behavior: first run dispatches one detached web job, later run
# polls and applies it. Keep every pre-existing scenario concise while
# exercising both halves of that contract.
run_batch_complete() {
  local first second status
  set +e
  first="$(bash "$BATCH_SRC" "$@" 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 0 ] || ! jq -e '.job.job_id? // empty | length > 0' "$AGENT_HOME/advisor-batch.json" >/dev/null 2>&1; then
    printf '%s\n' "$first"
    return "$status"
  fi
  set +e
  second="$(bash "$BATCH_SRC" "$@" 2>&1)"
  status=$?
  set -e
  printf '%s\n%s\n' "$first" "$second"
  if [ "$status" -eq 0 ] && [ -n "${FAKE_REASK_ANSWER:-}" ] && jq -e '.job.plan_reask_attempted == true' "$AGENT_HOME/advisor-batch.json" >/dev/null 2>&1; then
    bash "$BATCH_SRC" "$@" 2>&1 || return $?
  fi
  return "$status"
}

# --- A: happy path -- a mixed batch through the Codex branch ---------------
NDJSON_HAPPY='{"kind":"cross_ticket_findings","ordering":[]}
{"kind":"ruling","issue":2001,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"misclassified","risk_class":"P1","level":"L0","reasoning_md":"triage over-classified this; read-only admin-console tweak.","decision_md":"","recut_md":"","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}
{"kind":"ruling","issue":2002,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"advised","risk_class":"","level":"","reasoning_md":"stored classification is already admissible.","decision_md":"reuse the existing snapshot-store precedent.","recut_md":"","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}
{"kind":"ruling","issue":2003,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"recut","risk_class":"","level":"","reasoning_md":"","decision_md":"","recut_md":"split the write path from the read path.","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}
{"kind":"ruling","issue":2004,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"maintainer","risk_class":"","level":"","reasoning_md":"","decision_md":"","recut_md":"","founder_subject":"海棠商店配送时效需要确认","founder_question_md":"问题：是否应保留次日送达？\n客户/公司：海棠商店\n用户动作：下单时选择次日送达。\n结果：当前仓库排期无法保证次日发货。\nA）承诺次日送达；影响：需要承担加急配送成本。\nB）改为普通配送；影响：预计晚一天到货。\n建议：B\n请回复“B”","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}
{"kind":"ruling","issue":2005,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"maintainer","risk_class":"","level":"","reasoning_md":"","decision_md":"","recut_md":"","founder_subject":"是否按时向欠款客户发出提醒","founder_question_md":"问题：是否应今天提醒客户逾期款项？\n客户/公司：青禾贸易\n用户动作：客户的两笔货款已超过约定付款日。\n结果：目前尚未收到款项。\nA）今天发出付款提醒；影响：可能尽快收回货款，也会提醒客户已逾期。\nB）再等一周；影响：维持现有关系，但回款会更晚。\n建议：A\n请回复“A”","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}
{"kind":"ruling","issue":2006,"verdict":"duplicate","risk_class":"","level":"","reasoning_md":"完全重复 #2001 的范围。","decision_md":"","recut_md":"","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":2001}
{"kind":"ruling","issue":2007,"verdict":"something_not_in_the_enum","risk_class":"","level":"","reasoning_md":"","decision_md":"","recut_md":"","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}'

seed_ticket() {
  # seed_ticket <agent_home> <n> [risk] [level] [expected_packages_json]
  # expected_packages defaults to a fabricated, real-repo-safe package (same
  # convention run-advisor.test.sh's own run_once() uses): NOT empty.
  # advisor_footprint_risky() (lib.sh) treats a truly EMPTY declaration as
  # itself risky/unknown, fail-closed, same idiom as every other "can't
  # tell -> treat as unsafe" gate in this pipeline (has_open_blocker(),
  # triage_classification_status(), ...) -- see the dedicated test below
  # that asserts this deliberately, rather than letting every OTHER
  # scenario in this file silently depend on packages/react-example never
  # matching a real risk-class.mjs pattern while ALSO tripping the
  # zero-length short-circuit by accident.
  jq -n --arg r "${3:-P1}" --arg l "${4:-L1}" --argjson exp "${5:-[\"packages/react-example\"]}" \
    '{attempts: 0, risk_class: $r, level: $l, state: "needs-advisor", expected_packages: $exp, category: "bug"}' \
    > "$1/state/$2.json"
}
run_truncated_record_regression() {
  local TRUNC_HOME TRUNC_OUTPUT TRUNC_STATUS TRUNC_GH_LOG TRUNC_RAW
  TRUNC_HOME="$(mktemp -d)"
  TMP_DIRS+=("$TRUNC_HOME")
  mkdir -p "$TRUNC_HOME/state"
  : > "$TRUNC_HOME/codex-probe-passed"
  seed_ticket "$TRUNC_HOME" 1158
  NDJSON_TRUNCATED="$(cat "$OPS_DIR/fixtures/advisor-batch-broken-from-journal.ndjson")"
  export AGENT_HOME="$TRUNC_HOME"
  export FAKE_GH_LOG="$TRUNC_HOME/gh.log"; : > "$FAKE_GH_LOG"
  export FAKE_CODEX_LOG="$TRUNC_HOME/codex.log"; : > "$FAKE_CODEX_LOG"
  export FAKE_BATCH_NDJSON="$NDJSON_TRUNCATED"
  export FAKE_REAL_ISSUES=""
  # A generated job id containing "429" must not turn a parser failure into
  # a provider quota refusal and refund its ticket attempt.
  export FAKE_DATE_NS=1790431429000000000
  set +e
  TRUNC_OUTPUT="$(run_batch_complete 1158)"
  TRUNC_STATUS=$?
  set -e
  unset FAKE_DATE_NS
  TRUNC_GH_LOG="$(cat "$FAKE_GH_LOG" 2>/dev/null || true)"
  assert_eq "truncated batch: still exits 0" "0" "$TRUNC_STATUS"
  assert_contains "...the malformed ruling is identified as an advisor failure" "$TRUNC_OUTPUT" "#1158 -- unparseable ruling recorded as a per-ticket advisor failure"
  assert_not_contains "...the malformed ruling is never applied" "$TRUNC_GH_LOG" "issue edit 1158"
  assert_eq "...the issue stays in needs-advisor" "needs-advisor" "$(state_field "$TRUNC_HOME" 1158 '.state')"
  assert_eq "...one failed attempt is recorded" "1" "$(state_field "$TRUNC_HOME" 1158 '.attempts')"
  assert_eq "...failure backoff is scoped to advisor-batch" "advisor-batch" "$(state_field "$TRUNC_HOME" 1158 '.model_failure_backoff.caller')"
  assert_eq "...the failure raw file is retained" "1" "$(find "$TRUNC_HOME/logs" -name 'advisor-batch-*-issue-1158-record-*.raw' -type f | wc -l)"
  TRUNC_RAW="$(cat "$TRUNC_HOME"/logs/advisor-batch-*-issue-1158-record-*.raw)"
  assert_contains "...retained raw includes the journal fragment" "$TRUNC_RAW" 'docs/ux-p0-real-user-path-acceptance-20260921'
  assert_contains "...retained raw includes the pasted markdown chip" "$TRUNC_RAW" '粘贴的 markdown (1)。md +1'
}

run_oversize_regression() {
  local OVERSIZE_HOME LONG_EVIDENCE_MIDDLE OVERSIZE_BODY_FILE LONG_COMMENT_MIDDLE
  local OVERSIZE_OUTPUT OVERSIZE_STATUS OVERSIZE_GH_LOG OVERSIZE_PROMPT
  OVERSIZE_HOME="$(mktemp -d)"
  TMP_DIRS+=("$OVERSIZE_HOME")
  mkdir -p "$OVERSIZE_HOME/state" "$OVERSIZE_HOME/locks"
  : > "$OVERSIZE_HOME/codex-probe-passed"
  for n in 2601 2602 2603; do seed_ticket "$OVERSIZE_HOME" "$n"; done
  LONG_EVIDENCE_MIDDLE="$(head -c 6000 /dev/zero | tr '\0' e)"
  jq --arg evidence "failure-log-start:$LONG_EVIDENCE_MIDDLE:failure-log-end" \
    '.model_policy = {step:"advisor", failure:{unit:"implement",step:"implement",
      transition:"failed",role:"implement",identity:"test-role",stage:"test",
      status:1,reason:"fixture failure",evidence:$evidence,recorded_at:"2026-01-01T00:00:00Z"},
      failures:[{unit:"implement",step:"implement",transition:"failed",role:"implement",
        identity:"test-role",stage:"test",status:1,reason:"fixture failure",
        evidence:$evidence,recorded_at:"2026-01-01T00:00:00Z"}]}' \
    "$OVERSIZE_HOME/state/2601.json" > "$OVERSIZE_HOME/state/2601.json.tmp" \
    && mv "$OVERSIZE_HOME/state/2601.json.tmp" "$OVERSIZE_HOME/state/2601.json"
  OVERSIZE_BODY_FILE="$OVERSIZE_HOME/oversized-body.txt"
  { printf 'Body head. Acceptance criteria: preserve the requested behavior. Question: which route is right?\n'; head -c 70000 /dev/zero | tr '\0' b; } > "$OVERSIZE_BODY_FILE"
  LONG_COMMENT_MIDDLE="$(head -c 6000 /dev/zero | tr '\0' c)"
  export AGENT_HOME="$OVERSIZE_HOME"
  export FAKE_GH_LOG="$OVERSIZE_HOME/gh.log"; : > "$FAKE_GH_LOG"
  export FAKE_GH_CAPTURE_BODY=1
  export FAKE_WEB_ADVISOR_PROVIDER_LOG="$OVERSIZE_HOME/web-advisor-provider.log"
  export FAKE_WEB_ADVISOR_PROVIDER_PROMPT_LOG="$OVERSIZE_HOME/prompt.txt"
  export FAKE_BODY_ISSUE=2601
  export FAKE_BODY_CONTENT='Body head stays. Acceptance criteria: preserve the full behavior. Question: should this stay in the advisor batch?'
  export FAKE_BODY_ISSUE_2=2602
  export FAKE_BODY_CONTENT_FILE_2="$OVERSIZE_BODY_FILE"
  export FAKE_COMMENTS_ISSUE=2601
  export FAKE_COMMENTS_JSON="$(jq -nc --arg body "comment-log-start:$LONG_COMMENT_MIDDLE:comment-log-end" \
    '[{author:{login:"testuser"},createdAt:"2026-01-02T00:00:00Z",body:$body}]')"
  export FAKE_BATCH_NDJSON='{"kind":"advisor_batch_result","requested_issues":[2601,2602,2603],"cross_ticket_findings":{"ordering":[]},"rulings":[{"kind":"ruling","issue":2601,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"misclassified","risk_class":"P1","level":"L0","reasoning_md":"body preserved.","decision_md":"","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null},{"kind":"ruling","issue":2602,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"misclassified","risk_class":"P1","level":"L0","reasoning_md":"large issue body retained.","decision_md":"","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null},{"kind":"ruling","issue":2603,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"misclassified","risk_class":"P1","level":"L0","reasoning_md":"batch continued.","decision_md":"","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}]}'
  export FAKE_REAL_ISSUES=""
  set +e
  OVERSIZE_OUTPUT="$(run_batch_complete 2601 2602 2603)"
  OVERSIZE_STATUS=$?
  set -e
  OVERSIZE_GH_LOG="$(cat "$FAKE_GH_LOG" 2>/dev/null || true)"
  OVERSIZE_PROMPT="$(cat "$FAKE_WEB_ADVISOR_PROVIDER_PROMPT_LOG" 2>/dev/null || true)"
  assert_eq "oversized ticket isolation keeps the batch exit green" "0" "$OVERSIZE_STATUS"
  assert_contains "trimmed failure log retains its head" "$OVERSIZE_PROMPT" "failure-log-start"
  assert_contains "trimmed failure log names omitted text" "$OVERSIZE_PROMPT" "truncated by advisor batch"
  assert_not_contains "trimmed failure log omits its oversized middle" "$OVERSIZE_PROMPT" "$LONG_EVIDENCE_MIDDLE"
  assert_contains "trimmed comment retains its head and tail" "$OVERSIZE_PROMPT" "comment-log-start"
  assert_contains "trimmed comment retains its tail" "$OVERSIZE_PROMPT" "comment-log-end"
  assert_contains "trimmed comment omits its oversized middle" "$OVERSIZE_PROMPT" "truncated by advisor batch"
  assert_true "issue and comment authors remain available" \
    test "$(grep -oE '"login":[[:space:]]*"testuser"' <<< "$OVERSIZE_PROMPT" | wc -l | tr -d '[:space:]')" -ge 2
  assert_contains "comment time remains available" "$OVERSIZE_PROMPT" "2026-01-02T00:00:00Z"
  assert_contains "ticket title remains intact" "$OVERSIZE_PROMPT" "batch test issue #2601"
  assert_contains "ticket body head remains intact" "$OVERSIZE_PROMPT" "Body head stays."
  assert_contains "compact issue body keeps acceptance and question" "$OVERSIZE_PROMPT" "Acceptance criteria: preserve the full behavior. Question: should this stay in the advisor batch?"
  assert_contains "oversized issue body remains in the one request" "$OVERSIZE_PROMPT" "Body head. Acceptance criteria: preserve the requested behavior. Question: which route is right?"
  assert_contains "batch reports all three usable rulings" "$OVERSIZE_OUTPUT" "3 usable ruling(s)"
  assert_contains "first member #2601 receives its ruling" "$(grep -F 'gh issue edit 2601 ' <<< "$OVERSIZE_GH_LOG" || true)" "--add-label ready-for-agent"
  assert_contains "large member #2602 receives its ruling" "$(grep -F 'gh issue edit 2602 ' <<< "$OVERSIZE_GH_LOG" || true)" "--add-label ready-for-agent"
  assert_contains "other member #2603 still receives its ruling" "$(grep -F 'gh issue edit 2603 ' <<< "$OVERSIZE_GH_LOG" || true)" "--add-label ready-for-agent"
  assert_not_contains "large ticket is not routed to recut by an input threshold" "$(grep -F 'gh issue edit 2602 ' <<< "$OVERSIZE_GH_LOG" || true)" "--add-label needs-recut"
  unset FAKE_GH_CAPTURE_BODY FAKE_BODY_ISSUE FAKE_BODY_CONTENT FAKE_BODY_CONTENT_FILE
  unset FAKE_BODY_ISSUE_2 FAKE_BODY_CONTENT_2 FAKE_BODY_CONTENT_FILE_2
  unset FAKE_COMMENTS_ISSUE FAKE_COMMENTS_JSON
}

run_manifest_mismatch_regression() {
  local manifest_home output status gh_log
  manifest_home="$(mktemp -d)"
  TMP_DIRS+=("$manifest_home")
  mkdir -p "$manifest_home/state"
  seed_ticket "$manifest_home" 2604
  export AGENT_HOME="$manifest_home"
  export FAKE_GH_LOG="$manifest_home/gh.log"; : > "$FAKE_GH_LOG"
  export FAKE_WEB_ADVISOR_PROVIDER_LOG="$manifest_home/web-advisor-provider.log"
  export FAKE_BATCH_NDJSON='{"kind":"advisor_batch_result","requested_issues":[9999],"cross_ticket_findings":{"ordering":[]},"rulings":[{"kind":"ruling","issue":2604,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"misclassified","risk_class":"P1","level":"L0","reasoning_md":"must not apply against a different manifest.","decision_md":"","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}]}'
  export FAKE_REAL_ISSUES=""
  set +e
  output="$(run_batch_complete 2604)"
  status=$?
  set -e
  gh_log="$(cat "$FAKE_GH_LOG" 2>/dev/null || true)"
  assert_eq "manifest mismatch leaves the batch poll successful" "0" "$status"
  assert_contains "manifest mismatch is logged" "$output" "manifest differs from the frozen request"
  assert_contains "manifest mismatch fails closed" "$output" "refusing rulings from a JSON reply whose manifest does not match"
  assert_not_contains "mismatched manifest ruling is never applied" "$gh_log" "issue edit 2604"
  assert_eq "mismatched manifest issue remains in needs-advisor" "needs-advisor" "$(state_field "$manifest_home" 2604 '.state')"
}

run_manifest_superset_regression() {
  local superset_home output status gh_log
  superset_home="$(mktemp -d)"
  TMP_DIRS+=("$superset_home")
  mkdir -p "$superset_home/state"
  seed_ticket "$superset_home" 2606 P1 L1
  export AGENT_HOME="$superset_home"
  export FAKE_GH_LOG="$superset_home/gh.log"; : > "$FAKE_GH_LOG"
  export FAKE_WEB_ADVISOR_PROVIDER_LOG="$superset_home/web-advisor-provider.log"
  export FAKE_BATCH_NDJSON='{"kind":"advisor_batch_result","requested_issues":[2606,7777],"cross_ticket_findings":{"ordering":[]},"rulings":[{"kind":"ruling","issue":2606,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"advised","risk_class":"","level":"","reasoning_md":"frozen member ruling.","decision_md":"Apply the frozen member ruling.","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null},{"kind":"ruling","issue":7777,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"advised","risk_class":"","level":"","reasoning_md":"context ticket.","decision_md":"Must not apply.","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}]}'
  export FAKE_REAL_ISSUES=""
  set +e
  output="$(run_batch_complete 2606)"
  status=$?
  set -e
  gh_log="$(cat "$FAKE_GH_LOG" 2>/dev/null || true)"
  assert_eq "superset manifest leaves the batch poll successful" "0" "$status"
  assert_contains "superset manifest is logged" "$output" "adds tickets outside the frozen request"
  assert_eq "frozen member ruling applies from a superset reply" "Apply the frozen member ruling." "$(state_field "$superset_home" 2606 '.advisor_decision')"
  assert_contains "extra ticket ruling is ignored" "$output" "#7777 -- ruled but was not part of this batch's requested tickets"
  assert_not_contains "extra ticket is never edited" "$gh_log" "issue edit 7777"
}

run_ordering_shape_regression() {
  local ordering_home output status gh_log
  ordering_home="$(mktemp -d)"
  TMP_DIRS+=("$ordering_home")
  mkdir -p "$ordering_home/state"
  seed_ticket "$ordering_home" 2607 P1 L1
  export AGENT_HOME="$ordering_home"
  export FAKE_GH_LOG="$ordering_home/gh.log"; : > "$FAKE_GH_LOG"
  export FAKE_WEB_ADVISOR_PROVIDER_LOG="$ordering_home/web-advisor-provider.log"
  export FAKE_BATCH_NDJSON='{"kind":"advisor_batch_result","requested_issues":[2607],"cross_ticket_findings":{"ordering":["2607 after 2398",{"before":2398,"after":2607,"reasoning_md":"shared receipt path."}]},"rulings":[{"kind":"ruling","issue":2607,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"advised","risk_class":"","level":"","reasoning_md":"ordering shape.","decision_md":"Apply despite a string ordering entry.","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}]}'
  export FAKE_REAL_ISSUES=""
  set +e
  output="$(run_batch_complete 2607)"
  status=$?
  set -e
  gh_log="$(cat "$FAKE_GH_LOG" 2>/dev/null || true)"
  assert_eq "string ordering entry leaves the batch poll successful" "0" "$status"
  assert_eq "ruling still applies beside a string ordering entry" "Apply despite a string ordering entry." "$(state_field "$ordering_home" 2607 '.advisor_decision')"
  assert_contains "object ordering entry is still posted" "$gh_log" "issue comment 2607"
  assert_contains "batch reaches its done summary" "$output" "1 ordering note(s) posted"
}

run_json_normalization_regression() {
  local normalize_home output status gh_log
  normalize_home="$(mktemp -d)"
  TMP_DIRS+=("$normalize_home")
  mkdir -p "$normalize_home/state"
  seed_ticket "$normalize_home" 2605 P1 L1
  export AGENT_HOME="$normalize_home"
  export FAKE_GH_LOG="$normalize_home/gh.log"; : > "$FAKE_GH_LOG"
  export FAKE_GH_CAPTURE_BODY=1
  export FAKE_WEB_ADVISOR_PROVIDER_LOG="$normalize_home/web-advisor-provider.log"
  export FAKE_BATCH_NDJSON='{"kind":"advisor_batch_result","requested_issues":[2605],"cross_ticket_findings":{"ordering":[]},"rulings":[{"kind":"ruling","issue":2605,"verdict":"advised","risk_class":"","level":"","reasoning_md":"citation :chatgpt-content-reference{index="0"} should be removed","decision_md":"Preserve service_tier="fast" literally.","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}]}'
  export FAKE_REAL_ISSUES=""
  set +e
  # The original malformed response above is untouched; the corrective reply is a separate model answer.
  export FAKE_REASK_ANSWER='{"kind":"advisor_batch_result","requested_issues":[2605],"cross_ticket_findings":{"ordering":[]},"rulings":[{"kind":"ruling","issue":2605,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"advised","risk_class":"","level":"","reasoning_md":"citation :chatgpt-content-reference{index="0"} should be removed","decision_md":"Preserve service_tier=\"fast\" literally.","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}]}'
  output="$(run_batch_complete 2605)"
  unset FAKE_REASK_ANSWER
  status=$?
  set -e
  gh_log="$(cat "$FAKE_GH_LOG" 2>/dev/null || true)"
  assert_eq "ChatGPT JSON artifact repair still exits 0" "0" "$status"
  assert_contains "ChatGPT JSON artifact repair is explicitly recorded" "$output" "repaired observed ChatGPT JSON citation/quoted-attribute artifacts"
  assert_contains "repaired envelope reaches normal per-ticket validation" "$output" "1 usable ruling(s)"
  assert_eq "quoted service_tier content is preserved in the applied decision" \
    'Preserve service_tier="fast" literally.' "$(state_field "$normalize_home" 2605 '.advisor_decision')"
  assert_not_contains "UI citation token is removed from the applied comment" "$gh_log" ':chatgpt-content-reference{index="0"}'
  assert_eq "normalized ruling is recorded as applied" "true" "$(state_field "$normalize_home" 2605 'has("advisor_ruled_at")')"
  unset FAKE_GH_CAPTURE_BODY
}

# An unmodified VectA-shaped non-close reply must trigger a plan re-ask.
NO_PLAN_HOME="$(mktemp -d)"
TMP_DIRS+=("$NO_PLAN_HOME")
mkdir -p "$NO_PLAN_HOME/state"
seed_ticket "$NO_PLAN_HOME" 2002
export AGENT_HOME="$NO_PLAN_HOME"
export FAKE_GH_LOG="$NO_PLAN_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$NO_PLAN_HOME/web-advisor-provider.log"; : > "$FAKE_WEB_ADVISOR_PROVIDER_LOG"
export FAKE_BATCH_NDJSON='{"kind":"ruling","issue":2002,"verdict":"advised","risk_class":"","level":"","reasoning_md":"stored classification is already admissible.","decision_md":"reuse the existing snapshot-store precedent.","recut_md":"","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}'
NO_PLAN_OUTPUT="$(run_batch_complete 2002 2>&1)"
assert_contains "no-plan VectA reply dispatches corrective re-ask" "$NO_PLAN_OUTPUT" "dispatched exactly one corrective re-ask"
assert_eq "no-plan VectA reply remains unapplied" "needs-advisor" "$(state_field "$NO_PLAN_HOME" 2002 '.state')"
assert_eq "no-plan re-ask is recorded" "true" "$(jq -r '.job.plan_reask_attempted' "$NO_PLAN_HOME/advisor-batch.json")"
assert_not_contains "no-plan reply makes no issue writes" "$(cat "$FAKE_GH_LOG")" "gh issue edit 2002"

happy_home="$(mktemp -d)"
TMP_DIRS+=("$happy_home")
mkdir -p "$happy_home/state"
printf '{"max_safe_input_bytes":9000000}\n' > "$happy_home/advisor-batch.json"
cat > "$happy_home/recipients.json" <<'JSON'
{"founder_login":"founder","recipients":{"founder":"founder@fixture.invalid","testuser":"reporter@fixture.invalid"}}
JSON
: > "$happy_home/codex-probe-passed"
for n in 2001 2002 2003 2004 2005 2006 2007; do
  seed_ticket "$happy_home" "$n"
done
export AGENT_HOME="$happy_home"
export ZF_REPO_DIR="$FIXTURE_REPO"
export FAKE_GH_LOG="$happy_home/gh.log"
export FAKE_CODEX_LOG="$happy_home/codex.log"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$happy_home/web-advisor-provider.log"
: > "$FAKE_GH_LOG"; : > "$FAKE_CODEX_LOG"
export FAKE_BATCH_NDJSON="$NDJSON_HAPPY"
export FAKE_BATCH_ANSWER_ERR=$'MODEL_FALLBACK: Pro 不可用 -> 最新 / 极高\n本次实际使用：fake-web / max'
export FAKE_REAL_ISSUES="2001"
unset FAKE_ONHOLD_ISSUES FAKE_ISSUE_LIST FAKE_CODEX_STATUS
set +e
RUN_OUTPUT="$(run_batch_complete 2001 2002 2003 2004 2005 2006 2007)"
RUN_STATUS=$?
set -e
GH_LOG_CONTENT="$(cat "$FAKE_GH_LOG" 2>/dev/null || true)"
GH_WRITE_2003="$(grep -F 'gh issue edit 2003 ' <<< "$GH_LOG_CONTENT" || true)"
GH_WRITE_2004="$(grep -F 'gh issue edit 2004 ' <<< "$GH_LOG_CONTENT" || true)"
GH_WRITE_2005="$(grep -F 'gh issue edit 2005 ' <<< "$GH_LOG_CONTENT" || true)"
EMAIL_LOG_CONTENT="$(cat "$happy_home/emails.log" 2>/dev/null || true)"
CODEX_LOG_CONTENT="$(cat "$FAKE_CODEX_LOG" 2>/dev/null || true)"
BATCH_SPEND_CONTENT="$(cat "$happy_home"/spend/*.log 2>/dev/null || true)"
BATCH_SPEND_FALLBACK="$(printf '%s\n' "$BATCH_SPEND_CONTENT" | awk -F '\t' '$2 == "advisor-batch" { print $7; exit }')"

assert_eq "happy path: exits 0" "0" "$RUN_STATUS"
# #1461: batch transport is fixed to the existing web-advisor-provider advisor route;
# a Codex probe marker cannot silently select a different provider.
assert_eq "...a Codex probe marker does not reach Codex; batch is web-only" "" "$CODEX_LOG_CONTENT"
assert_eq "...dispatches exactly one web-advisor-provider job for whole batch" "1" "$(grep -c '^dispatch:' "$happy_home/web-advisor-provider.log")"
assert_contains "...records one completed batch call on actual web model" "$BATCH_SPEND_CONTENT" "advisor-batch"
assert_eq "...records Pro fallback reason in the spend ledger" "Pro 不可用 -> 最新 / 极高" "$BATCH_SPEND_FALLBACK"
unset FAKE_BATCH_ANSWER_ERR

# 2001: misclassified -> ready-for-agent, corrected classification stored.
assert_contains "...2001 (misclassified) gets ready-for-agent" "$(grep -F 'gh issue edit 2001 ' <<< "$GH_LOG_CONTENT" || true)" "--add-label ready-for-agent"
assert_contains "...2001 gets a comment with the reasoning" "$GH_LOG_CONTENT" "over-classified"
assert_eq "...2001 state corrected to P1" "P1" "$(state_field "$happy_home" 2001 '.risk_class')"
assert_eq "...2001 state corrected to L0" "L0" "$(state_field "$happy_home" 2001 '.level')"
assert_eq "...2001 records advisor_ruled_at" "true" "$(state_field "$happy_home" 2001 'has("advisor_ruled_at")')"
assert_eq "...2001 records advisor_batch: true (provenance)" "true" "$(state_field "$happy_home" 2001 '.advisor_batch')"

# 2002: advised, stored classification (P1/L1, seeded) already admissible ->
# rung 0 (ready-for-agent), not guarded.
assert_contains "...2002 (advised, admissible) gets ready-for-agent" "$(grep -F 'gh issue edit 2002 ' <<< "$GH_LOG_CONTENT" || true)" "--add-label ready-for-agent"
assert_not_contains "...2002 never gets the guarded comment" "$GH_LOG_CONTENT" "加强看护"
assert_eq "...2002 state carries advisor_decision" "reuse the existing snapshot-store precedent." "$(state_field "$happy_home" 2002 '.advisor_decision')"

# 2003: recut -> needs-recut, no ready-for-agent.
assert_contains "...2003 (recut) gets needs-recut" "$GH_WRITE_2003" "--add-label needs-recut"
assert_contains "...2003 gets the recut_md as its comment" "$GH_LOG_CONTENT" "split the write path"

# 2004 + 2005: each decision gets its own reporter-routed mail and thread.
assert_contains "...2004 (founder) gets needs-info" "$GH_WRITE_2004" "--add-label needs-info"
assert_contains "...2005 (founder) gets needs-info" "$GH_WRITE_2005" "--add-label needs-info"
assert_eq "...2004 stage is written once through the state-label transition" "1" \
  "$(grep -c '^gh issue edit 2004 ' <<< "$GH_LOG_CONTENT" || true)"
assert_eq "...2005 stage is written once through the state-label transition" "1" \
  "$(grep -c '^gh issue edit 2005 ' <<< "$GH_LOG_CONTENT" || true)"
assert_contains "...2004's business decision is on its own comment" "$GH_LOG_CONTENT" "海棠商店"
assert_contains "...2005's business decision is on its own comment" "$GH_LOG_CONTENT" "青禾贸易"
assert_contains "...2004 is routed to reporter only" "$EMAIL_LOG_CONTENT" "issue=2004"
assert_contains "...2004 mail has reporter recipient, not founder copy" "$EMAIL_LOG_CONTENT" "args=--maintainer-kind decision reporter@fixture.invalid"
assert_contains "...2005 is routed to a separate reporter mail" "$EMAIL_LOG_CONTENT" "issue=2005"
assert_not_contains "...founder inbox is not copied on either reporter-owned decision" "$EMAIL_LOG_CONTENT" "founder@fixture.invalid"
assert_eq "...2004 stores its own reply thread" "fixture-thread-2004" "$(state_field "$happy_home" 2004 '.needs_info_thread_id')"
assert_eq "...2005 stores a different reply thread" "fixture-thread-2005" "$(state_field "$happy_home" 2005 '.needs_info_thread_id')"
assert_eq "...2004 state moves to needs-info with its label" "needs-info" "$(state_field "$happy_home" 2004 '.state')"
assert_eq "...2005 state moves to needs-info with its label" "needs-info" "$(state_field "$happy_home" 2005 '.state')"

# 2006: duplicate of 2001 -> concluded + closed, names the survivor, no
# advisor_ruled_at (conclude_run's own concluded label already takes it out
# of the needs-advisor pool).
assert_contains "...2006 (duplicate) gets closed" "$GH_LOG_CONTENT" "gh issue close 2006"
assert_contains "...2006's closing comment names the survivor" "$GH_LOG_CONTENT" "#2001"
assert_eq "...2006 records duplicate_of evidence" "2001" "$(state_field "$happy_home" 2006 '.run.evidence.duplicate_of')"
assert_eq "...2006 does NOT get advisor_ruled_at (conclude_run already removed it from the pool)" \
  "false" "$(state_field "$happy_home" 2006 'has("advisor_ruled_at")')"

# 2007: an unrecognized verdict string -> malformed -> nothing applied, no
# label edit, no comment, still needs-advisor next time.
assert_not_contains "...2007 (unrecognized verdict) gets no label edit at all" "$GH_LOG_CONTENT" "issue edit 2007"
assert_not_contains "...2007 gets no comment either" "$GH_LOG_CONTENT" "issue comment 2007"

# A failed founder-stage label write must roll back the local needs-info
# state and thread metadata instead of leaving an invisible ticket.
FOUNDER_FAIL_HOME="$(mktemp -d)"
TMP_DIRS+=("$FOUNDER_FAIL_HOME")
mkdir -p "$FOUNDER_FAIL_HOME/state" "$FOUNDER_FAIL_HOME/locks"
cat > "$FOUNDER_FAIL_HOME/recipients.json" <<'JSON'
{"founder_login":"founder","recipients":{"founder":"founder@fixture.invalid","testuser":"reporter@fixture.invalid"}}
JSON
: > "$FOUNDER_FAIL_HOME/codex-probe-passed"
seed_ticket "$FOUNDER_FAIL_HOME" 2008
export AGENT_HOME="$FOUNDER_FAIL_HOME"
export FAKE_GH_LOG="$FOUNDER_FAIL_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_BATCH_NDJSON='{"kind":"advisor_batch_result","requested_issues":[2008],"cross_ticket_findings":{"ordering":[]},"rulings":[{"kind":"ruling","issue":2008,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"maintainer","risk_class":"","level":"","reasoning_md":"","decision_md":"","recut_md":"","founder_subject":"海棠商店配送时效需要确认","founder_question_md":"问题：是否应保留次日送达？\n客户/公司：海棠商店\n用户动作：下单时选择次日送达。\n结果：当前仓库排期无法保证次日发货。\nA）承诺次日送达；影响：需要承担加急配送成本。\nB）改为普通配送；影响：预计晚一天到货。\n建议：B\n请回复“B”","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}]}'
export FAKE_GH_APPLY_FAIL_ISSUE=2008
export FAKE_GH_APPLY_FAIL_SUBCOMMAND='issue edit'
export FAKE_GH_APPLY_FAIL_MATCH='--add-label needs-info'
export FAKE_GH_APPLY_FAIL_TEXT='simulated founder label write failure'
set +e
FOUNDER_FAIL_OUTPUT="$(run_batch_complete 2008 2>&1)"
FOUNDER_FAIL_STATUS=$?
set -e
unset FAKE_GH_APPLY_FAIL_ISSUE FAKE_GH_APPLY_FAIL_SUBCOMMAND FAKE_GH_APPLY_FAIL_MATCH FAKE_GH_APPLY_FAIL_TEXT
FOUNDER_FAIL_STATE="$(cat "$FOUNDER_FAIL_HOME/state/2008.json")"
assert_eq "batch founder label failure is isolated to its ticket" "0" "$FOUNDER_FAIL_STATUS"
assert_contains "batch records the failed founder transition" "$FOUNDER_FAIL_OUTPUT" "issue_transition: label write failed for #2008"
assert_not_contains "failed batch transition never records a needs-info label edit" \
  "$(cat "$FOUNDER_FAIL_HOME/gh.log")" "issue edit 2008"
assert_eq "failed batch transition restores needs-advisor state" "needs-advisor" \
  "$(echo "$FOUNDER_FAIL_STATE" | jq -r '.state')"
assert_eq "failed batch transition does not retain the email thread" "" \
  "$(echo "$FOUNDER_FAIL_STATE" | jq -r '.needs_info_thread_id // empty')"
# A pretty-printed ruling split across lines remains parseable after the
# known pasted-attachment chip is stripped from an intervening physical line.
WRAPPED_HOME="$(mktemp -d)"
TMP_DIRS+=("$WRAPPED_HOME")
mkdir -p "$WRAPPED_HOME/state"
seed_ticket "$WRAPPED_HOME" 3101
NDJSON_WRAPPED='{"kind":"cross_ticket_findings","ordering":[]}
{
"kind":"ruling",
"issue":3101,
粘贴的 markdown (1)。md +1
"verdict":"misclassified",
"risk_class":"P1",
"level":"L0",
"reasoning_md":"wrapped ruling survived chip cleanup",
"decision_md":"",
"recut_md":"",
"founder_question_md":"",
"merge_conditions_md":"",
"required_test_paths":[],
"expected_packages_addendum":[],
"duplicate_of":null
}'
export AGENT_HOME="$WRAPPED_HOME"
export FAKE_GH_LOG="$WRAPPED_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$WRAPPED_HOME/web-advisor-provider.log"
export FAKE_BATCH_NDJSON="$NDJSON_WRAPPED"
# Keep the original pasted-chip sample intact and supply a separate re-ask reply.
export FAKE_REASK_ANSWER='{"kind":"cross_ticket_findings","ordering":[]}
{"kind":"ruling","issue":3101,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"misclassified","risk_class":"P1","level":"L0","reasoning_md":"wrapped ruling survived chip cleanup","decision_md":"","recut_md":"","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}'
WRAPPED_OUTPUT="$(run_batch_complete 3101)"
unset FAKE_REASK_ANSWER
assert_contains "multiline ruling: one requested ticket is parsed" "$WRAPPED_OUTPUT" "1 usable ruling(s)"
assert_contains "...the complete ruling applies" "$(grep -F 'gh issue edit 3101 ' "$FAKE_GH_LOG" || true)" "--add-label ready-for-agent"
assert_eq "...no failed attempt is charged" "0" "$(state_field "$WRAPPED_HOME" 3101 '.attempts')"

# The 2026-09-25 ChatGPT composer rendered the NDJSON answer without line
# breaks, so complete objects arrived back to back on one physical line.
CONCAT_HOME="$(mktemp -d)"
TMP_DIRS+=("$CONCAT_HOME")
mkdir -p "$CONCAT_HOME/state"
seed_ticket "$CONCAT_HOME" 3201
seed_ticket "$CONCAT_HOME" 3202
export AGENT_HOME="$CONCAT_HOME"
export FAKE_GH_LOG="$CONCAT_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$CONCAT_HOME/web-advisor-provider.log"
export FAKE_BATCH_NDJSON='{"kind":"cross_ticket_findings","ordering":[]}{"kind":"ruling","issue":3201,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"misclassified","risk_class":"P1","level":"L0","reasoning_md":"joined line one.","decision_md":"","recut_md":"","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}{"kind":"ruling","issue":3202,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"misclassified","risk_class":"P1","level":"L0","reasoning_md":"joined line two.","decision_md":"","recut_md":"","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}'
CONCAT_OUTPUT="$(run_batch_complete 3201 3202)"
assert_contains "back-to-back NDJSON objects: both rulings parse" "$CONCAT_OUTPUT" "2 usable ruling(s)"
assert_contains "...the first joined ruling applies" "$(grep -F 'gh issue edit 3201 ' "$FAKE_GH_LOG" || true)" "--add-label ready-for-agent"
assert_contains "...the second joined ruling applies" "$(grep -F 'gh issue edit 3202 ' "$FAKE_GH_LOG" || true)" "--add-label ready-for-agent"
# Batch admission failure must keep that ticket's original stage and verdict.
ADMISSION_FAIL_HOME="$(mktemp -d)"
TMP_DIRS+=("$ADMISSION_FAIL_HOME")
mkdir -p "$ADMISSION_FAIL_HOME/state"
seed_ticket "$ADMISSION_FAIL_HOME" 8202
export AGENT_HOME="$ADMISSION_FAIL_HOME"
export FAKE_GH_LOG="$ADMISSION_FAIL_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_BATCH_NDJSON='{"kind":"cross_ticket_findings","ordering":[]}
{"kind":"ruling","issue":8202,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"advised","risk_class":"P1","level":"L0","reasoning_md":"safe read-only admission","decision_md":"Reuse existing helper","recut_md":"","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}'
export FAKE_GH_APPLY_FAIL_ISSUE=8202 FAKE_GH_APPLY_FAIL_SUBCOMMAND='issue edit'
export FAKE_GH_APPLY_FAIL_MATCH='--add-label ready-for-agent'
export FAKE_GH_APPLY_FAIL_TEXT='simulated admission label failure'
ADMISSION_FAIL_OUTPUT="$(run_batch_complete 8202 2>&1)"
unset FAKE_GH_APPLY_FAIL_ISSUE FAKE_GH_APPLY_FAIL_SUBCOMMAND FAKE_GH_APPLY_FAIL_MATCH FAKE_GH_APPLY_FAIL_TEXT
assert_eq "failed batch admission restores prior stage" needs-advisor "$(state_field "$ADMISSION_FAIL_HOME" 8202 '.state')"
assert_contains "failed batch admission logs rollback" "$ADMISSION_FAIL_OUTPUT" 'issue_transition: label write failed'
assert_eq "failed batch admission keeps pending verdict" true "$(state_field "$ADMISSION_FAIL_HOME" 8202 'has("pending_advisor_verdict")')"

# --- J5: a human edit after dispatch must not receive stale batch output ----
STALE_HOME="$(mktemp -d)"
TMP_DIRS+=("$STALE_HOME")
mkdir -p "$STALE_HOME/state"
seed_ticket "$STALE_HOME" 11801
NDJSON_STALE='{"kind":"cross_ticket_findings","ordering":[]}
{"kind":"ruling","issue":11801,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"misclassified","risk_class":"P1","level":"L0","reasoning_md":"must not apply after a human edit.","decision_md":"","recut_md":"","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}'
export AGENT_HOME="$STALE_HOME"
export FAKE_GH_LOG="$STALE_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_BATCH_NDJSON="$NDJSON_STALE"
export FAKE_REAL_ISSUES=""
export FAKE_BODY_ISSUE=11801
export FAKE_BODY_CONTENT='ORIGINAL_HUMAN_BODY'
set +e
STALE_FIRST="$(bash "$BATCH_SRC" 11801 2>&1)"
STALE_FIRST_STATUS=$?
set -e
assert_eq "stale input setup: dispatch persists initial member snapshot" "0" "$STALE_FIRST_STATUS"
export FAKE_BODY_CONTENT='UPDATED_HUMAN_BODY'
set +e
STALE_OUTPUT="$(bash "$BATCH_SRC" 11801 2>&1)"
STALE_STATUS=$?
set -e
STALE_GH_LOG="$(cat "$STALE_HOME/gh.log" 2>/dev/null || true)"
assert_eq "stale input: poll exits cleanly" "0" "$STALE_STATUS"
assert_contains "...detects the human edit before Apply" "$STALE_OUTPUT" "ticket changed after batch dispatch"
assert_eq "...records edited member for single-ticket recovery" "11801" \
  "$(jq -r '.deferred_issue_ids[]' "$STALE_HOME/advisor-batch.json")"
assert_not_contains "...never applies stale batch ruling" "$STALE_GH_LOG" "issue edit 11801"
unset FAKE_BODY_ISSUE FAKE_BODY_CONTENT

# 2026-09-25 (#1755): a new advisor episode started for one member after
# dispatch. Its ruling can never persist; retaining the whole batch stalled
# every other ruling for 90+ min. Defer only that member.
EPISODE_HOME="$(mktemp -d)"
TMP_DIRS+=("$EPISODE_HOME")
mkdir -p "$EPISODE_HOME/state"
seed_ticket "$EPISODE_HOME" 11803
export AGENT_HOME="$EPISODE_HOME"
export FAKE_GH_LOG="$EPISODE_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_BATCH_NDJSON='{"kind":"cross_ticket_findings","ordering":[]}
{"kind":"ruling","issue":11803,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"misclassified","risk_class":"P1","level":"L0","reasoning_md":"stale episode.","decision_md":"","recut_md":"","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}'
export FAKE_REAL_ISSUES=""
set +e
bash "$BATCH_SRC" 11803 >/dev/null 2>&1
set -e
jq '.advisor_episode_seq = ((.advisor_episode_seq // 0) + 5)' "$EPISODE_HOME/state/11803.json" > "$EPISODE_HOME/s.tmp"
mv "$EPISODE_HOME/s.tmp" "$EPISODE_HOME/state/11803.json"
set +e
EPISODE_OUTPUT="$(bash "$BATCH_SRC" 11803 2>&1)"
EPISODE_STATUS=$?
set -e
assert_eq "stale episode: poll exits cleanly" "0" "$EPISODE_STATUS"
assert_contains "...discards the stale-episode ruling" "$EPISODE_OUTPUT" "advisor episode moved on after dispatch"
assert_not_contains "...does not retain the whole batch" "$EPISODE_OUTPUT" "no Apply attempted until every usable ruling is persisted"
assert_eq "...defers only that member" "11803" "$(jq -r '.deferred_issue_ids[]' "$EPISODE_HOME/advisor-batch.json")"

# A batch member may move into release while its advisor job is in flight.
# Failure bookkeeping, a deferred requeue, and a successful ruling must all
# leave that newer terminal state alone.
RACE_SUCCESS_HOME="$(mktemp -d)"
TMP_DIRS+=("$RACE_SUCCESS_HOME")
mkdir -p "$RACE_SUCCESS_HOME/state"
seed_ticket "$RACE_SUCCESS_HOME" 11804
export AGENT_HOME="$RACE_SUCCESS_HOME"
export FAKE_GH_LOG="$RACE_SUCCESS_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$RACE_SUCCESS_HOME/web-advisor-provider.log"
export FAKE_BATCH_NDJSON='{"kind":"cross_ticket_findings","ordering":[]}
{"kind":"ruling","issue":11804,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"misclassified","risk_class":"P1","level":"L0","reasoning_md":"stale after merge.","decision_md":"","recut_md":"","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}'
export FAKE_REAL_ISSUES=""
set +e
bash "$BATCH_SRC" 11804 >/dev/null 2>&1
RACE_SUCCESS_DISPATCH_STATUS=$?
set -e
assert_eq "state-race success setup: batch records assembled member state" "needs-advisor" \
  "$(jq -r '.job.members[] | select(.issue == 11804) | .state' "$RACE_SUCCESS_HOME/advisor-batch.json")"
jq '.state = "awaiting-release" | .run = {outcome:"merged", evidence:{pr_number:"1801"}}' \
  "$RACE_SUCCESS_HOME/state/11804.json" > "$RACE_SUCCESS_HOME/state/11804.json.tmp" \
  && mv "$RACE_SUCCESS_HOME/state/11804.json.tmp" "$RACE_SUCCESS_HOME/state/11804.json"
set +e
RACE_SUCCESS_OUTPUT="$(bash "$BATCH_SRC" 11804 2>&1)"
RACE_SUCCESS_STATUS=$?
set -e
assert_eq "state-race success setup: batch dispatched" "0" "$RACE_SUCCESS_DISPATCH_STATUS"
assert_eq "state-race success: poll exits cleanly" "0" "$RACE_SUCCESS_STATUS"
assert_contains "...drops ruling after the member state advances" "$RACE_SUCCESS_OUTPUT" "state changed after batch dispatch"
assert_eq "...preserves awaiting-release" "awaiting-release" "$(state_field "$RACE_SUCCESS_HOME" 11804 '.state')"
assert_eq "...preserves merged outcome" "merged" "$(state_field "$RACE_SUCCESS_HOME" 11804 '.run.outcome')"
assert_not_contains "...does not apply stale issue writes" "$(cat "$RACE_SUCCESS_HOME/gh.log")" "issue edit 11804"

RACE_DEFER_HOME="$(mktemp -d)"
TMP_DIRS+=("$RACE_DEFER_HOME")
mkdir -p "$RACE_DEFER_HOME/state"
seed_ticket "$RACE_DEFER_HOME" 11805
export AGENT_HOME="$RACE_DEFER_HOME"
export FAKE_GH_LOG="$RACE_DEFER_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$RACE_DEFER_HOME/web-advisor-provider.log"
export FAKE_BATCH_NDJSON='{"kind":"cross_ticket_findings","ordering":[]}'
set +e
bash "$BATCH_SRC" 11805 >/dev/null 2>&1
RACE_DEFER_DISPATCH_STATUS=$?
set -e
jq '.state = "awaiting-release" | .run = {outcome:"merged", evidence:{pr_number:"1802"}}' \
  "$RACE_DEFER_HOME/state/11805.json" > "$RACE_DEFER_HOME/state/11805.json.tmp" \
  && mv "$RACE_DEFER_HOME/state/11805.json.tmp" "$RACE_DEFER_HOME/state/11805.json"
set +e
RACE_DEFER_OUTPUT="$(bash "$BATCH_SRC" 11805 2>&1)"
RACE_DEFER_STATUS=$?
set -e
assert_eq "state-race requeue setup: batch dispatched" "0" "$RACE_DEFER_DISPATCH_STATUS"
assert_eq "state-race requeue: poll exits cleanly" "0" "$RACE_DEFER_STATUS"
assert_eq "...does not put an advanced member back in deferred candidates" "false" \
  "$(jq -e '.deferred_issue_ids | index(11805) != null' "$RACE_DEFER_HOME/advisor-batch.json" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "...keeps merged outcome through missing-ruling recovery" "merged" \
  "$(state_field "$RACE_DEFER_HOME" 11805 '.run.outcome')"

RACE_CLOSED_HOME="$(mktemp -d)"
TMP_DIRS+=("$RACE_CLOSED_HOME")
mkdir -p "$RACE_CLOSED_HOME/state"
seed_ticket "$RACE_CLOSED_HOME" 11807
export AGENT_HOME="$RACE_CLOSED_HOME"
export FAKE_GH_LOG="$RACE_CLOSED_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$RACE_CLOSED_HOME/web-advisor-provider.log"
export FAKE_BATCH_NDJSON='{"kind":"cross_ticket_findings","ordering":[]}'
set +e
bash "$BATCH_SRC" 11807 >/dev/null 2>&1
RACE_CLOSED_DISPATCH_STATUS=$?
set -e
export FAKE_CLOSED_ISSUES=11807
set +e
RACE_CLOSED_OUTPUT="$(bash "$BATCH_SRC" 11807 2>&1)"
RACE_CLOSED_STATUS=$?
set -e
assert_eq "closed-member setup: batch dispatched" "0" "$RACE_CLOSED_DISPATCH_STATUS"
assert_eq "closed member: poll exits cleanly" "0" "$RACE_CLOSED_STATUS"
assert_contains "...does not requeue a closed GitHub issue" "$RACE_CLOSED_OUTPUT" "state changed after batch dispatch"
assert_eq "...does not add closed member to deferred candidates" "false" \
  "$(jq -e '.deferred_issue_ids | index(11807) != null' "$RACE_CLOSED_HOME/advisor-batch.json" >/dev/null 2>&1 && echo true || echo false)"
unset FAKE_CLOSED_ISSUES

RACE_JOB_FAILURE_HOME="$(mktemp -d)"
TMP_DIRS+=("$RACE_JOB_FAILURE_HOME")
mkdir -p "$RACE_JOB_FAILURE_HOME/state"
seed_ticket "$RACE_JOB_FAILURE_HOME" 11808
export AGENT_HOME="$RACE_JOB_FAILURE_HOME"
export FAKE_GH_LOG="$RACE_JOB_FAILURE_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$RACE_JOB_FAILURE_HOME/web-advisor-provider.log"
export FAKE_BATCH_NDJSON='{"kind":"cross_ticket_findings","ordering":[]}'
set +e
bash "$BATCH_SRC" 11808 >/dev/null 2>&1
RACE_JOB_FAILURE_DISPATCH_STATUS=$?
set -e
jq '.state = "awaiting-release" | .run = {outcome:"merged", evidence:{pr_number:"1804"}}' \
  "$RACE_JOB_FAILURE_HOME/state/11808.json" > "$RACE_JOB_FAILURE_HOME/state/11808.json.tmp" \
  && mv "$RACE_JOB_FAILURE_HOME/state/11808.json.tmp" "$RACE_JOB_FAILURE_HOME/state/11808.json"
export FAKE_BATCH_POLL_STATUS=1
set +e
RACE_JOB_FAILURE_OUTPUT="$(bash "$BATCH_SRC" 11808 2>&1)"
RACE_JOB_FAILURE_STATUS=$?
set -e
unset FAKE_BATCH_POLL_STATUS
set +e
RACE_JOB_RECOVERY_OUTPUT="$(bash "$BATCH_SRC" 11808 2>&1)"
RACE_JOB_RECOVERY_STATUS=$?
set -e
assert_eq "failed-web-job setup: batch dispatched" "0" "$RACE_JOB_FAILURE_DISPATCH_STATUS"
assert_eq "failed web batch: exits cleanly" "0" "$RACE_JOB_FAILURE_STATUS"
assert_contains "...records web-job failure and clears batch" "$RACE_JOB_FAILURE_OUTPUT" "preserved failed job evidence"
assert_eq "failed batch recovery: exits cleanly" "0" "$RACE_JOB_RECOVERY_STATUS"
assert_contains "...does not dispatch an advanced member again" "$RACE_JOB_RECOVERY_OUTPUT" "state changed before batch assembly"
assert_eq "...only original batch dispatched" "1" "$(grep -c '^dispatch:' "$RACE_JOB_FAILURE_HOME/web-advisor-provider.log")"
assert_eq "...keeps merged outcome after failed job recovery" "merged" \
  "$(state_field "$RACE_JOB_FAILURE_HOME" 11808 '.run.outcome')"

RACE_FAILURE_HOME="$(mktemp -d)"
TMP_DIRS+=("$RACE_FAILURE_HOME")
mkdir -p "$RACE_FAILURE_HOME/state"
seed_ticket "$RACE_FAILURE_HOME" 11806
export AGENT_HOME="$RACE_FAILURE_HOME"
export FAKE_GH_LOG="$RACE_FAILURE_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$RACE_FAILURE_HOME/web-advisor-provider.log"
export FAKE_BATCH_NDJSON='{"kind":"ruling","issue":11806, malformed}'
set +e
bash "$BATCH_SRC" 11806 >/dev/null 2>&1
RACE_FAILURE_DISPATCH_STATUS=$?
set -e
jq '.attempts = 3 | .state = "awaiting-release" | .run = {outcome:"merged", evidence:{pr_number:"1803"}}' \
  "$RACE_FAILURE_HOME/state/11806.json" > "$RACE_FAILURE_HOME/state/11806.json.tmp" \
  && mv "$RACE_FAILURE_HOME/state/11806.json.tmp" "$RACE_FAILURE_HOME/state/11806.json"
set +e
RACE_FAILURE_OUTPUT="$(bash "$BATCH_SRC" 11806 2>&1)"
RACE_FAILURE_STATUS=$?
set -e
assert_eq "state-race failure setup: batch dispatched" "0" "$RACE_FAILURE_DISPATCH_STATUS"
assert_eq "state-race failure: poll exits cleanly" "0" "$RACE_FAILURE_STATUS"
assert_contains "...retains failed output for evidence" "$RACE_FAILURE_OUTPUT" "retained unparseable record"
assert_eq "...does not count a stale parse failure" "3" "$(state_field "$RACE_FAILURE_HOME" 11806 '.attempts')"
assert_eq "...does not replace merged outcome" "merged" "$(state_field "$RACE_FAILURE_HOME" 11806 '.run.outcome')"
assert_eq "...does not replace awaiting-release" "awaiting-release" "$(state_field "$RACE_FAILURE_HOME" 11806 '.state')"

WEDGE_HOME="$(mktemp -d)"
TMP_DIRS+=("$WEDGE_HOME")
mkdir -p "$WEDGE_HOME/state" "$WEDGE_HOME/locks"
: > "$WEDGE_HOME/codex-probe-passed"
seed_ticket "$WEDGE_HOME" 14001
export AGENT_HOME="$WEDGE_HOME"
export FAKE_GH_LOG="$WEDGE_HOME/gh.log"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$WEDGE_HOME/web-advisor-provider.log"
export FAKE_WEB_ADVISOR_PROVIDER_PROMPT_LOG="$WEDGE_HOME/prompt.txt"
export FAKE_NOTIFY_LOG="$WEDGE_HOME/notify.log"
: > "$WEDGE_HOME/notify.log"
export FAKE_REAL_ISSUES=""
export FAKE_BATCH_ANSWER_ERR='FAIL: CDP Runtime.evaluate timed out after 30000ms'
export FAKE_BATCH_POLL_STATUS=1
set +e
WEDGE_OUTPUT="$(run_batch_complete 14001)"
WEDGE_STATUS=$?
set -e
WEDGE_SIGNATURE="$(sha256sum "$WEDGE_HOME/prompt.txt" | awk '{print $1}')"
WEDGE_RECORD="$WEDGE_HOME/quarantine/advisor-batch/prompt-$WEDGE_SIGNATURE.json"
assert_eq "renderer-timeout failure is recorded and exits cleanly" "0" "$WEDGE_STATUS"
assert_true "renderer-timeout persists exact prompt signature" test -f "$WEDGE_RECORD"
assert_eq "quarantine record carries prompt signature" "$WEDGE_SIGNATURE" "$(jq -r '.signature' "$WEDGE_RECORD")"
assert_contains "quarantine record preserves named failure" "$(jq -r '.failure' "$WEDGE_RECORD")" "CDP Runtime.evaluate timed out"
assert_contains "quarantine record names affected issue" "$(jq -r '.issues' "$WEDGE_RECORD")" "#14001"
assert_eq "one wedged job was dispatched" "1" "$(grep -c '^dispatch:' "$WEDGE_HOME/web-advisor-provider.log")"
assert_eq "quarantine notice queued in supervisor inbox once" "1" "$(grep -cF 'advisor-batch-quarantine job=' "$WEDGE_HOME/supervisor-inbox")"
assert_contains "supervisor inbox notice includes quarantine signature" "$(cat "$WEDGE_HOME/supervisor-inbox")" "$WEDGE_SIGNATURE"
assert_eq "quarantine notice never emails founder" "" "$(cat "$WEDGE_HOME/notify.log")"

unset FAKE_BATCH_POLL_STATUS
set +e
WEDGE_RETRY_OUTPUT="$(bash "$BATCH_SRC" 14001 2>&1)"
WEDGE_RETRY_STATUS=$?
set -e
assert_eq "same candidate after wedge exits cleanly" "0" "$WEDGE_RETRY_STATUS"
assert_contains "same prompt is skipped from quarantine" "$WEDGE_RETRY_OUTPUT" "quarantined signature matches this exact prompt"
assert_eq "same prompt is not dispatched again" "1" "$(grep -c '^dispatch:' "$WEDGE_HOME/web-advisor-provider.log")"
assert_eq "quarantine retry keeps one supervisor inbox notice" "1" "$(grep -cF 'advisor-batch-quarantine job=' "$WEDGE_HOME/supervisor-inbox")"
assert_eq "quarantine retry never emails founder" "" "$(cat "$WEDGE_HOME/notify.log")"

jq '.quarantined_at = "2000-01-01T00:00:00Z"' "$WEDGE_RECORD" > "$WEDGE_RECORD.expired"
mv "$WEDGE_RECORD.expired" "$WEDGE_RECORD"
set +e
WEDGE_EXPIRED_OUTPUT="$(bash "$BATCH_SRC" 14001 2>&1)"
WEDGE_EXPIRED_STATUS=$?
set -e
assert_eq "expired renderer quarantine exits cleanly" "0" "$WEDGE_EXPIRED_STATUS"
assert_not_contains "expired signature no longer skips the candidate" "$WEDGE_EXPIRED_OUTPUT" "quarantined signature matches this exact prompt"
assert_eq "same prompt retries after quarantine expiry" "2" "$(grep -c '^dispatch:' "$WEDGE_HOME/web-advisor-provider.log")"
assert_eq "expired quarantine record is cleared" "false" "$(test -e "$WEDGE_RECORD" && echo true || echo false)"
WEDGE_RESULT="$(find "$WEDGE_HOME/logs" -name 'advisor-batch-*.result.json' | sort | tail -1)"
assert_eq "expired quarantine has one eligible ticket in scheduler artifact" 1 "$(jq -r .eligible_count "$WEDGE_RESULT")"
assert_eq "expired quarantine terminal outcome is dispatched" dispatched "$(jq -r .outcome "$WEDGE_RESULT")"
assert_eq "scheduler artifact names dispatched job" "$(jq -r .job.job_id "$WEDGE_HOME/advisor-batch.json")" "$(jq -r .job_id "$WEDGE_RESULT")"
assert_eq "dispatch has no ruling artifact yet" null "$(jq -r .ruling_artifact "$WEDGE_RESULT")"
assert_eq "scheduler manifest artifact is retained" true "$(test -s "$(jq -r .job_artifact "$WEDGE_RESULT")" && echo true || echo false)"


# A stalled answer is a prompt wedge too: cool down this exact batch, then retry.
ANSWER_TIMEOUT_HOME="$(mktemp -d)"
TMP_DIRS+=("$ANSWER_TIMEOUT_HOME")
mkdir -p "$ANSWER_TIMEOUT_HOME/state" "$ANSWER_TIMEOUT_HOME/locks"
: > "$ANSWER_TIMEOUT_HOME/codex-probe-passed"
seed_ticket "$ANSWER_TIMEOUT_HOME" 14002
export AGENT_HOME="$ANSWER_TIMEOUT_HOME"
export FAKE_GH_LOG="$ANSWER_TIMEOUT_HOME/gh.log"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$ANSWER_TIMEOUT_HOME/web-advisor-provider.log"
export FAKE_WEB_ADVISOR_PROVIDER_PROMPT_LOG="$ANSWER_TIMEOUT_HOME/prompt.txt"
export FAKE_NOTIFY_LOG="$ANSWER_TIMEOUT_HOME/notify.log"
: > "$ANSWER_TIMEOUT_HOME/notify.log"
export FAKE_BATCH_ANSWER_ERR='FAIL: ADVISOR_ANSWER_TIMEOUT: 20 分钟内页面完全没有动静(既没 streaming,文本也没变长)'
export FAKE_BATCH_POLL_STATUS=1
set +e
ANSWER_TIMEOUT_OUTPUT="$(run_batch_complete 14002 2>&1)"
ANSWER_TIMEOUT_STATUS=$?
set -e
ANSWER_TIMEOUT_SIGNATURE="$(sha256sum "$ANSWER_TIMEOUT_HOME/prompt.txt" | awk '{print $1}')"
ANSWER_TIMEOUT_RECORD="$ANSWER_TIMEOUT_HOME/quarantine/advisor-batch/prompt-$ANSWER_TIMEOUT_SIGNATURE.json"
assert_eq "stalled-answer failure is recorded and exits cleanly" "0" "$ANSWER_TIMEOUT_STATUS"
assert_true "stalled-answer timeout persists exact prompt signature" test -f "$ANSWER_TIMEOUT_RECORD"
assert_contains "stalled-answer quarantine preserves timeout reason" "$(jq -r '.failure' "$ANSWER_TIMEOUT_RECORD" 2>/dev/null || true)" "ADVISOR_ANSWER_TIMEOUT"
assert_eq "one stalled batch was dispatched" "1" "$(grep -c '^dispatch:' "$ANSWER_TIMEOUT_HOME/web-advisor-provider.log")"
unset FAKE_BATCH_POLL_STATUS
set +e
ANSWER_TIMEOUT_RETRY_OUTPUT="$(bash "$BATCH_SRC" 14002 2>&1)"
ANSWER_TIMEOUT_RETRY_STATUS=$?
set -e
assert_eq "same stalled batch exits cleanly during cooldown" "0" "$ANSWER_TIMEOUT_RETRY_STATUS"
assert_contains "same stalled prompt is quarantined" "$ANSWER_TIMEOUT_RETRY_OUTPUT" "quarantined signature matches this exact prompt"
assert_eq "same stalled batch is not redispatched during cooldown" "1" "$(grep -c '^dispatch:' "$ANSWER_TIMEOUT_HOME/web-advisor-provider.log")"

# Browser failures belong to the cohort. A prompt-signature quarantine must
# not blame its first ticket or mutate the next batch's membership.
SPLIT_HOME="$(mktemp -d)"
TMP_DIRS+=("$SPLIT_HOME")
mkdir -p "$SPLIT_HOME/state" "$SPLIT_HOME/locks"
: > "$SPLIT_HOME/codex-probe-passed"
seed_ticket "$SPLIT_HOME" 14011
seed_ticket "$SPLIT_HOME" 14012
seed_ticket "$SPLIT_HOME" 14013
export AGENT_HOME="$SPLIT_HOME"
export FAKE_GH_LOG="$SPLIT_HOME/gh.log"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$SPLIT_HOME/web-advisor-provider.log"
export FAKE_WEB_ADVISOR_PROVIDER_PROMPT_LOG="$SPLIT_HOME/prompt.txt"
export FAKE_REAL_ISSUES=""
export FAKE_BATCH_ANSWER_ERR='FAIL: 未从当前会话的 composer 找到模型/推理 picker。'
export FAKE_BATCH_POLL_STATUS=1
set +e
SPLIT_FAILURE_OUTPUT="$(run_batch_complete 14011 14012 14013)"
SPLIT_FAILURE_STATUS=$?
set -e
assert_eq "failed three-ticket batch exits cleanly" "0" "$SPLIT_FAILURE_STATUS"
assert_eq "failed batch was dispatched once" "1" "$(grep -c '^dispatch:' "$SPLIT_HOME/web-advisor-provider.log")"
SPLIT_PROMPT="$(cat "$SPLIT_HOME/prompt.txt")"
assert_contains "environment failure keeps first cohort member" "$SPLIT_PROMPT" "# ticket #14011"
assert_contains "environment failure keeps remaining cohort member" "$SPLIT_PROMPT" "# ticket #14012"
assert_contains "environment failure keeps last cohort member" "$SPLIT_PROMPT" "# ticket #14013"

unset FAKE_BATCH_POLL_STATUS
set +e
SPLIT_RETRY_OUTPUT="$(bash "$BATCH_SRC" 14011 14012 14013 2>&1)"
SPLIT_RETRY_STATUS=$?
set -e
assert_eq "environment retry exits cleanly" "0" "$SPLIT_RETRY_STATUS"
assert_contains "environment retry skips same quarantined prompt" "$SPLIT_RETRY_OUTPUT" "quarantined signature matches this exact prompt"
assert_eq "environment retry does not dispatch an arbitrarily reduced cohort" "1" "$(grep -c '^dispatch:' "$SPLIT_HOME/web-advisor-provider.log")"

batch_result_for() {
  local ids_json
  ids_json="$(printf '%s\n' "$@" | jq -R 'tonumber' | jq -s .)"
  jq -cn --argjson ids "$ids_json" '
    {kind:"advisor_batch_result", requested_issues:$ids,
     cross_ticket_findings:{ordering:[]},
     rulings:[$ids[] | {kind:"ruling", issue:., verdict:"misclassified",
       plan:{changes:[{file:"engine/example.sh",symbol:"fixture",change:"Apply the ruling."}], tests_fail_first:["bash engine/example.test.sh"], non_goals:["Other behavior"]},
       risk_class:"P1", level:"L0", reasoning_md:"size-split fixture",
       decision_md:"", recut_md:"", founder_question_md:"", founder_subject:"",
       merge_conditions_md:"", required_test_paths:[], expected_packages_addendum:[],
       duplicate_of:null}]}
  '
}

# A measured size failure bisects by rendered ticket bytes. Each successful
# half records its actual request size as the safe bound for later groups.
SIZE_HOME="$(mktemp -d)"
TMP_DIRS+=("$SIZE_HOME")
mkdir -p "$SIZE_HOME/state" "$SIZE_HOME/locks"
: > "$SIZE_HOME/codex-probe-passed"
for n in 14111 14112 14113 14114; do seed_ticket "$SIZE_HOME" "$n"; done
export AGENT_HOME="$SIZE_HOME"
export FAKE_GH_LOG="$SIZE_HOME/gh.log"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$SIZE_HOME/web-advisor-provider.log"
export FAKE_WEB_ADVISOR_PROVIDER_PROMPT_LOG="$SIZE_HOME/prompt.txt"
export FAKE_REAL_ISSUES=""
export FAKE_BATCH_NDJSON=""
export FAKE_BATCH_ANSWER_ERR='FAIL: HTTP 413 Payload Too Large'
export FAKE_BATCH_POLL_STATUS=1
set +e
SIZE_FAILURE_OUTPUT="$(run_batch_complete 14111 14112 14113 14114 2>&1)"
SIZE_FAILURE_STATUS=$?
set -e
assert_eq "measured size failure exits cleanly" "0" "$SIZE_FAILURE_STATUS"
assert_contains "size failure bisects cohort" "$SIZE_FAILURE_OUTPUT" "measured size failure split 4 tickets"
assert_eq "first byte-balanced half is active" '[14111,14112]' "$(jq -c '.size_split.active_issue_ids' "$SIZE_HOME/advisor-batch.json")"
assert_eq "second half stays pending" '[[14113,14114]]' "$(jq -c '.size_split.pending_issue_groups' "$SIZE_HOME/advisor-batch.json")"

unset FAKE_BATCH_POLL_STATUS
export FAKE_BATCH_NDJSON="$(batch_result_for 14111 14112)"
SIZE_FIRST_OUTPUT="$(run_batch_complete 14111 14112 14113 14114 2>&1)"
SIZE_FIRST_PROMPT="$(cat "$SIZE_HOME/prompt.txt")"
assert_contains "first reduced batch keeps first member" "$SIZE_FIRST_PROMPT" "# ticket #14111"
assert_contains "first reduced batch keeps second member" "$SIZE_FIRST_PROMPT" "# ticket #14112"
assert_not_contains "first reduced batch excludes pending group" "$SIZE_FIRST_PROMPT" "# ticket #14113"
assert_eq "successful half records measured safe request bytes" "true" \
  "$(jq -e '.max_safe_input_bytes > 0' "$SIZE_HOME/advisor-batch.json" >/dev/null && echo true || echo false)"
assert_eq "successful half activates pending members" '[14113,14114]' \
  "$(jq -c '.size_split.active_issue_ids' "$SIZE_HOME/advisor-batch.json")"

export FAKE_BATCH_NDJSON="$(batch_result_for 14113 14114)"
SIZE_SECOND_OUTPUT="$(run_batch_complete 14111 14112 14113 14114 2>&1)"
SIZE_SECOND_PROMPT="$(cat "$SIZE_HOME/prompt.txt")"
assert_contains "pending reduced batch keeps third member" "$SIZE_SECOND_PROMPT" "# ticket #14113"
assert_contains "pending reduced batch keeps fourth member" "$SIZE_SECOND_PROMPT" "# ticket #14114"
assert_eq "both reduced groups receive rulings" "true" \
  "$(jq -se 'all(.[]; has("advisor_ruled_at"))' "$SIZE_HOME/state/14111.json" "$SIZE_HOME/state/14112.json" "$SIZE_HOME/state/14113.json" "$SIZE_HOME/state/14114.json" >/dev/null && echo true || echo false)"
assert_eq "size split clears after cohort is answered" "false" \
  "$(jq 'has("size_split")' "$SIZE_HOME/advisor-batch.json")"

# A timeout cools the prompt and keeps the cohort whole: it is no evidence of size.
TIMEOUT_COHORT_HOME="$(mktemp -d)"
TMP_DIRS+=("$TIMEOUT_COHORT_HOME")
mkdir -p "$TIMEOUT_COHORT_HOME/state" "$TIMEOUT_COHORT_HOME/locks"
: > "$TIMEOUT_COHORT_HOME/codex-probe-passed"
for n in 14121 14122; do seed_ticket "$TIMEOUT_COHORT_HOME" "$n"; done
export AGENT_HOME="$TIMEOUT_COHORT_HOME"
export FAKE_GH_LOG="$TIMEOUT_COHORT_HOME/gh.log"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$TIMEOUT_COHORT_HOME/web-advisor-provider.log"
export FAKE_WEB_ADVISOR_PROVIDER_PROMPT_LOG="$TIMEOUT_COHORT_HOME/prompt.txt"
export FAKE_BATCH_NDJSON=""
export FAKE_BATCH_ANSWER_ERR='FAIL: ADVISOR_ANSWER_TIMEOUT: stop button, empty text'
export FAKE_BATCH_POLL_STATUS=1
set +e
TIMEOUT_COHORT_OUTPUT="$(run_batch_complete 14121 14122 2>&1)"
TIMEOUT_COHORT_STATUS=$?
set -e
assert_eq "timed-out cohort exits cleanly" "0" "$TIMEOUT_COHORT_STATUS"
assert_not_contains "timeout does not bisect the cohort" "$TIMEOUT_COHORT_OUTPUT" "measured size failure split"
assert_eq "timeout leaves no size split" "false" "$(jq 'has("size_split")' "$TIMEOUT_COHORT_HOME/advisor-batch.json")"
assert_true "timeout still cools the prompt" compgen -G "$TIMEOUT_COHORT_HOME/quarantine/advisor-batch/prompt-*.json"
unset FAKE_BATCH_POLL_STATUS

# A size failure that persists for one ticket becomes a dead letter keyed to
# its exact input and episode; siblings continue and receive rulings.
POISON_HOME="$(mktemp -d)"
TMP_DIRS+=("$POISON_HOME")
mkdir -p "$POISON_HOME/state" "$POISON_HOME/locks"
: > "$POISON_HOME/codex-probe-passed"
seed_ticket "$POISON_HOME" 14211
seed_ticket "$POISON_HOME" 14212
export AGENT_HOME="$POISON_HOME"
export FAKE_GH_LOG="$POISON_HOME/gh.log"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$POISON_HOME/web-advisor-provider.log"
export FAKE_WEB_ADVISOR_PROVIDER_PROMPT_LOG="$POISON_HOME/prompt.txt"
export FAKE_BATCH_ANSWER_ERR='FAIL: HTTP 413 Payload Too Large'
export FAKE_BATCH_POLL_STATUS=1
set +e
POISON_BATCH_OUTPUT="$(run_batch_complete 14211 14212 2>&1)"
set -e
assert_contains "two-ticket size failure splits before attribution" "$POISON_BATCH_OUTPUT" "measured size failure split 2 tickets"
set +e
POISON_ITEM_OUTPUT="$(run_batch_complete 14211 14212 2>&1)"
set -e
assert_contains "singleton size failure records dead letter" "$POISON_ITEM_OUTPUT" "dead-lettered after a measured one-ticket size failure"
assert_contains "dead letter records actionable cause" "$(jq -r '.cause' "$POISON_HOME/quarantine/advisor-batch/issue-14211.json")" "recut or reduce question"
unset FAKE_BATCH_POLL_STATUS
export FAKE_BATCH_NDJSON="$(batch_result_for 14212)"
POISON_REMAINDER_OUTPUT="$(run_batch_complete 14211 14212 2>&1)"
POISON_REMAINDER_PROMPT="$(cat "$POISON_HOME/prompt.txt")"
assert_not_contains "next batch excludes known size poison" "$POISON_REMAINDER_PROMPT" "# ticket #14211"
assert_contains "next batch retains sibling" "$POISON_REMAINDER_PROMPT" "# ticket #14212"
assert_eq "sibling receives advisor ruling" "true" \
  "$(jq -e 'has("advisor_ruled_at")' "$POISON_HOME/state/14212.json" >/dev/null && echo true || echo false)"
POISON_STILL_OUTPUT="$(bash "$BATCH_SRC" 14211 2>&1)"
assert_contains "unchanged dead-letter stays excluded after split completes" "$POISON_STILL_OUTPUT" "size dead-letter remains active"
assert_eq "unchanged dead-letter is not dispatched again" "3" "$(grep -c '^dispatch:' "$POISON_HOME/web-advisor-provider.log")"
export FAKE_BODY_ISSUE=14211
export FAKE_BODY_CONTENT='recut with one smaller question'
export FAKE_BATCH_NDJSON="$(batch_result_for 14211)"
POISON_EDITED_OUTPUT="$(run_batch_complete 14211 2>&1)"
assert_contains "edited dead-letter input becomes eligible" "$(cat "$POISON_HOME/prompt.txt")" "# ticket #14211"
assert_eq "edited input clears stale dead-letter" "false" "$(test -e "$POISON_HOME/quarantine/advisor-batch/issue-14211.json" && echo true || echo false)"
unset FAKE_BODY_ISSUE FAKE_BODY_CONTENT
unset FAKE_BATCH_ANSWER_ERR FAKE_BATCH_NDJSON FAKE_REAL_ISSUES FAKE_GH_LOG FAKE_WEB_ADVISOR_PROVIDER_LOG FAKE_WEB_ADVISOR_PROVIDER_PROMPT_LOG
run_truncated_record_regression
run_oversize_regression
run_manifest_mismatch_regression
run_manifest_superset_regression
run_ordering_shape_regression
run_json_normalization_regression

# Repeating the same actionable ruling earns one final implement pass, then
# any failed pass routes to recut instead of reopening the advisor loop.
CONVERGENCE_HOME="$(mktemp -d)"
TMP_DIRS+=("$CONVERGENCE_HOME")
CONVERGENCE_SECOND_STATUS=0
mkdir -p "$CONVERGENCE_HOME/state"
seed_ticket "$CONVERGENCE_HOME" 2051
export AGENT_HOME="$CONVERGENCE_HOME"
export FAKE_GH_LOG="$CONVERGENCE_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$CONVERGENCE_HOME/web-advisor-provider.log"; : > "$FAKE_WEB_ADVISOR_PROVIDER_LOG"
export FAKE_BATCH_NDJSON='{"kind":"cross_ticket_findings","ordering":[]}
{"kind":"ruling","issue":2051,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"advised","risk_class":"P1","level":"L1","reasoning_md":"same engineering judgment","decision_md":"Fix the stale retry route in the shared admission seam.","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}'
run_batch_complete 2051 >/dev/null
set +e
CONVERGENCE_SECOND_OUTPUT="$(run_batch_complete 2051 2>&1)"
CONVERGENCE_SECOND_STATUS=$?
set -e
assert_eq "repeated identical advisor verdict exits cleanly" "0" "$CONVERGENCE_SECOND_STATUS"
assert_eq "repeated verdict arms exactly one implement pass" "true" \
  "$(state_field "$CONVERGENCE_HOME" 2051 '.advisor_convergence_pass == true')"
assert_contains "single implement pass brief carries repeated fix points" \
  "$(state_field "$CONVERGENCE_HOME" 2051 '.brief_md')" \
  "Fix the stale retry route in the shared admission seam."
ZF_ROADMAP_TREE_CACHE_FILE="$CONVERGENCE_HOME/roadmap-tree.json"
printf '{"roots":[]}' > "$ZF_ROADMAP_TREE_CACHE_FILE"
printf '2051\n' > "$ZF_ROADMAP_TREE_CACHE_FILE.placed"
export ZF_ROADMAP_TREE_CACHE_FILE
CONVERGENCE_PENDING_OUTPUT="$(bash -c 'source "$1/lib.sh"; route_to_advisor 2051 ready-for-agent' _ "$FAKE_SCRIPT_DIR" 2>&1)" || { echo "convergence route failed: $CONVERGENCE_PENDING_OUTPUT"; FAILED=1; }
assert_contains "convergence marker preserves implement route until an attempt runs" \
  "$CONVERGENCE_PENDING_OUTPUT" "still awaits its one implement pass"
assert_eq "convergence marker remains armed before implement attempt" "true" \
  "$(state_field "$CONVERGENCE_HOME" 2051 '.advisor_convergence_pass == true')"
jq '.attempts += 1' "$CONVERGENCE_HOME/state/2051.json" \
  > "$CONVERGENCE_HOME/state/2051.json.tmp" \
  && mv "$CONVERGENCE_HOME/state/2051.json.tmp" "$CONVERGENCE_HOME/state/2051.json"
bash -c 'source "$1/lib.sh"; route_to_advisor 2051 ready-for-agent' _ "$FAKE_SCRIPT_DIR"
assert_eq "failed convergence pass reaches terminal needs-recut" "needs-recut" \
  "$(state_field "$CONVERGENCE_HOME" 2051 '.state')"
CONVERGENCE_GH_LOG="$(cat "$FAKE_GH_LOG")"
CONVERGENCE_WRITE_2051="$(grep -F 'gh issue edit 2051 ' <<< "$CONVERGENCE_GH_LOG" || true)"
assert_contains "failed convergence pass is labeled for recut" \
  "$CONVERGENCE_WRITE_2051" "--add-label needs-recut"
unset ZF_ROADMAP_TREE_CACHE_FILE

# Main's persisted guarded rulings predate advisor_last_verdict.material. A
# matching legacy decision still gets one implement pass on its first rerun.
CONVERGENCE_LEGACY_HOME="$(mktemp -d)"
TMP_DIRS+=("$CONVERGENCE_LEGACY_HOME")
mkdir -p "$CONVERGENCE_LEGACY_HOME/state"
seed_ticket "$CONVERGENCE_LEGACY_HOME" 2053 P2 L3
jq --arg decision "Fix the stale retry route in the shared admission seam." \
  '.guarded = true | .advisor_decision = $decision | .advisor_ruled_at = "2026-10-01T00:00:00Z"' \
  "$CONVERGENCE_LEGACY_HOME/state/2053.json" > "$CONVERGENCE_LEGACY_HOME/state/2053.json.tmp" \
  && mv "$CONVERGENCE_LEGACY_HOME/state/2053.json.tmp" "$CONVERGENCE_LEGACY_HOME/state/2053.json"
export AGENT_HOME="$CONVERGENCE_LEGACY_HOME"
export FAKE_GH_LOG="$CONVERGENCE_LEGACY_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$CONVERGENCE_LEGACY_HOME/web-advisor-provider.log"; : > "$FAKE_WEB_ADVISOR_PROVIDER_LOG"
export FAKE_BATCH_NDJSON='{"kind":"cross_ticket_findings","ordering":[]}
{"kind":"ruling","issue":2053,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"advised","risk_class":"P1","level":"L1","reasoning_md":"same legacy judgment","decision_md":"Fix the stale retry route in the shared admission seam.","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}'
run_batch_complete 2053 >/dev/null
assert_eq "legacy guarded verdict arms one implement pass without a stored material record" "true" \
  "$(state_field "$CONVERGENCE_LEGACY_HOME" 2053 '.advisor_convergence_pass == true')"
assert_contains "legacy guarded brief carries repeated fix points" \
  "$(state_field "$CONVERGENCE_LEGACY_HOME" 2053 '.brief_md')" \
  "Fix the stale retry route in the shared admission seam."
NO_POINTS_RULING='{"verdict":"advised","decision_md":"","merge_conditions_md":"","required_test_paths":[]}'
NO_POINTS_PRIOR='{"state":"needs-advisor","guarded":true,"advisor_decision":"","advisor_ruled_at":"2026-10-01T00:00:00Z","merge_conditions_md":"","required_test_paths":[]}'
NO_POINTS_ACTION="$(bash -c 'source "$1/advisor-core.sh"; material="$(advisor_verdict_material "$2" guarded)"; advisor_convergence_action "$3" "$material" guarded "$2"' \
  _ "$SCRIPT_DIR" "$NO_POINTS_RULING" "$NO_POINTS_PRIOR")"
assert_eq "repeated guarded judgment without concrete fix points routes to recut" "recut" "$NO_POINTS_ACTION"

# The legacy-plan convergence boundary: only a prior with no advisor_plan key
# at all may converge onto a plan-bearing rerun; an empty or differing stored
# plan keeps the strict comparison and earns no one implement pass.
PLAN_BOUNDARY_PLAN="$(jq -nc '{changes:[{file:"engine/example.sh",symbol:"fixture",change:"Apply the ruling."}],tests_fail_first:["bash engine/example.test.sh"],non_goals:["Other behavior"]}')"
PLAN_BOUNDARY_OTHER="$(jq -c '.changes[0].change = "A different change."' <<<"$PLAN_BOUNDARY_PLAN")"
PLAN_BOUNDARY_RULING="$(jq -nc --argjson plan "$PLAN_BOUNDARY_PLAN" \
  '{verdict:"advised",plan:$plan,decision_md:"Fix the stale retry route in the shared admission seam.",merge_conditions_md:"",required_test_paths:[]}')"
plan_boundary_action() {
  bash -c 'source "$1/advisor-core.sh"; material="$(advisor_verdict_material "$2" advised)"; advisor_convergence_action "$3" "$material" advised "$2"' \
    _ "$SCRIPT_DIR" "$PLAN_BOUNDARY_RULING" "$1"
}
assert_eq "prior without an advisor_plan key converges onto a plan-bearing rerun" "one-pass" \
  "$(plan_boundary_action "$(jq -nc --arg decision "Fix the stale retry route in the shared admission seam." \
    '{state:"needs-advisor",advisor_decision:$decision,advisor_ruled_at:"2026-10-01T00:00:00Z",merge_conditions_md:"",required_test_paths:[]}')")"
assert_eq "empty stored advisor_plan compares strictly instead of converging" "new" \
  "$(plan_boundary_action "$(jq -nc --arg decision "Fix the stale retry route in the shared admission seam." \
    '{state:"needs-advisor",advisor_decision:$decision,advisor_ruled_at:"2026-10-01T00:00:00Z",advisor_plan:"",merge_conditions_md:"",required_test_paths:[]}')")"
assert_eq "differing stored advisor_plan compares strictly instead of converging" "new" \
  "$(plan_boundary_action "$(jq -nc --arg decision "Fix the stale retry route in the shared admission seam." --argjson plan "$PLAN_BOUNDARY_OTHER" \
    '{state:"needs-advisor",advisor_decision:$decision,advisor_ruled_at:"2026-10-01T00:00:00Z",advisor_plan:$plan,merge_conditions_md:"",required_test_paths:[]}')")"
unset PLAN_BOUNDARY_PLAN PLAN_BOUNDARY_OTHER PLAN_BOUNDARY_RULING

# A tracker ruling becomes terminal state and leaves child work in place.
TRACKER_VERDICT_HOME="$(mktemp -d)"
TMP_DIRS+=("$TRACKER_VERDICT_HOME")
mkdir -p "$TRACKER_VERDICT_HOME/state"
seed_ticket "$TRACKER_VERDICT_HOME" 2054
export AGENT_HOME="$TRACKER_VERDICT_HOME"
export FAKE_GH_LOG="$TRACKER_VERDICT_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$TRACKER_VERDICT_HOME/web-advisor-provider.log"; : > "$FAKE_WEB_ADVISOR_PROVIDER_LOG"
export FAKE_BATCH_NDJSON='{"kind":"cross_ticket_findings","ordering":[]}
{"kind":"ruling","issue":2054,"verdict":"tracker","risk_class":"P1","level":"L1","reasoning_md":"All remaining work belongs to child tickets.","decision_md":"","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}'
run_batch_complete 2054 >/dev/null
assert_eq "tracker ruling persists terminal tracker state" "tracker" \
  "$(state_field "$TRACKER_VERDICT_HOME" 2054 '.state')"
assert_eq "tracker ruling arms parent marker" "true" \
  "$(state_field "$TRACKER_VERDICT_HOME" 2054 '.tracker_parent == true')"
assert_contains "tracker ruling removes advisor lane label" \
  "$(cat "$TRACKER_VERDICT_HOME/gh.log")" "--remove-label needs-advisor"
assert_not_contains "tracker ruling does not dispatch implementation label" \
  "$(cat "$TRACKER_VERDICT_HOME/gh.log")" "--add-label ready-for-agent"

# Known tracker parents never enter the advisor batch, even when a stale
# needs-advisor label still selects them.
TRACKER_HOME="$(mktemp -d)"
TMP_DIRS+=("$TRACKER_HOME")
mkdir -p "$TRACKER_HOME/state"
seed_ticket "$TRACKER_HOME" 2052
jq '.state = "tracker" | .tracker_parent = true' \
  "$TRACKER_HOME/state/2052.json" > "$TRACKER_HOME/state/2052.json.tmp" \
  && mv "$TRACKER_HOME/state/2052.json.tmp" "$TRACKER_HOME/state/2052.json"
export AGENT_HOME="$TRACKER_HOME"
export FAKE_GH_LOG="$TRACKER_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$TRACKER_HOME/web-advisor-provider.log"; : > "$FAKE_WEB_ADVISOR_PROVIDER_LOG"
TRACKER_OUTPUT="$(run_batch_complete 2052 2>&1)"
assert_contains "tracker parent is refused from advisor batch" "$TRACKER_OUTPUT" "tracker parent"
assert_eq "tracker parent sends no advisor job" "" "$(cat "$TRACKER_HOME/web-advisor-provider.log" 2>/dev/null || true)"
assert_eq "tracker parent receives no advisor apply writes" "" "$(cat "$TRACKER_HOME/gh.log" 2>/dev/null || true)"
# Issue 2025: guarded admission updates state, then its ready-for-agent label
# write fails. Preserve the pending ruling and measure-only marker; the triage
# batch replay below models the later ready-for-agent label with stale step.
PARTIAL_HOME="$(mktemp -d)"
TMP_DIRS+=("$PARTIAL_HOME")
mkdir -p "$PARTIAL_HOME/state"
seed_ticket "$PARTIAL_HOME" 20731 P1 L2
jq '.model_policy={unit:"triage",step:"advisor",resume_stage:"triage"}' \
  "$PARTIAL_HOME/state/20731.json" > "$PARTIAL_HOME/state/20731.json.tmp"
mv "$PARTIAL_HOME/state/20731.json.tmp" "$PARTIAL_HOME/state/20731.json"
export AGENT_HOME="$PARTIAL_HOME"
export FAKE_GH_LOG="$PARTIAL_HOME/gh.log"
export FAKE_REAL_ISSUES=20731
: > "$FAKE_GH_LOG"
export FAKE_BATCH_NDJSON='{"kind":"cross_ticket_findings","ordering":[]}
{"kind":"ruling","issue":20731,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"advised","risk_class":"","level":"","reasoning_md":"keep guarded admission.","decision_md":"admit under guard.","recut_md":"","founder_question_md":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}'
export FAKE_GH_APPLY_FAIL_ISSUE=20731
export FAKE_GH_APPLY_FAIL_SUBCOMMAND='issue edit'
export FAKE_GH_APPLY_FAIL_MATCH='--add-label ready-for-agent'
export FAKE_GH_APPLY_FAIL_TEXT='Post "https://api.github.com/graphql": net/http: TLS handshake timeout'
set +e
PARTIAL_OUTPUT="$(run_batch_complete 20731 2>&1)"
PARTIAL_STATUS=$?
set -e
assert_eq "2025 partial apply exits cleanly for the next tick" "0" "$PARTIAL_STATUS"
assert_contains "2025 partial apply records the failed label write" "$PARTIAL_OUTPUT" "TLS handshake timeout"
assert_eq "2025 failed ready-for-agent label write rolls back local stage" "needs-advisor" \
  "$(state_field "$PARTIAL_HOME" 20731 '.state')"
assert_eq "2025 failed label write does not persist partial guarded admission" "false" \
  "$(state_field "$PARTIAL_HOME" 20731 '.guarded // false')"
assert_not_contains "2025 failed ready-for-agent label write is not logged as success" \
  "$(grep -F 'gh issue edit 20731 ' "$FAKE_GH_LOG" || true)" "--add-label ready-for-agent"
assert_eq "2025 partial apply keeps its stored ruling" "true" \
  "$(state_field "$PARTIAL_HOME" 20731 'has("pending_advisor_verdict")')"
assert_eq "2025 partial apply records measure-only admission" "true" \
  "$(state_field "$PARTIAL_HOME" 20731 '.advisor_admission_measure_only // false')"
assert_not_contains "2025 partial apply log avoids stale advisor-state claim" "$PARTIAL_OUTPUT" "ticket stays needs-advisor"
assert_eq "2025 partial apply still has the advisor step for recovery" "advisor" \
  "$(state_field "$PARTIAL_HOME" 20731 '.model_policy.step')"
unset FAKE_GH_APPLY_FAIL_ISSUE FAKE_GH_APPLY_FAIL_SUBCOMMAND FAKE_GH_APPLY_FAIL_MATCH FAKE_GH_APPLY_FAIL_TEXT

# Native GitHub parents without recut state must stay as trackers when the
# advisor's normal needs-advisor -> ready-for-agent route is applied.
NATIVE_PARENT_HOME="$(mktemp -d)"
TMP_DIRS+=("$NATIVE_PARENT_HOME")
mkdir -p "$NATIVE_PARENT_HOME/state"
seed_ticket "$NATIVE_PARENT_HOME" 20461
export AGENT_HOME="$NATIVE_PARENT_HOME"
export FAKE_GH_LOG="$NATIVE_PARENT_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_NATIVE_SUB_ISSUES_JSON='[{"number":20462,"state":"open","closed_at":null,"labels":[]}]'
export FAKE_BATCH_NDJSON='{"kind":"cross_ticket_findings","ordering":[]}
{"kind":"ruling","issue":20461,"plan":{"changes":[{"file":"engine/example.sh","symbol":"fixture","change":"Apply the ruling."}],"tests_fail_first":["bash engine/example.test.sh"],"non_goals":["Other behavior"]},"verdict":"misclassified","risk_class":"P1","level":"L0","reasoning_md":"parent classification","decision_md":"","recut_md":"","founder_question_md":"","founder_subject":"","merge_conditions_md":"","required_test_paths":[],"expected_packages_addendum":[],"duplicate_of":null}'
set +e
NATIVE_PARENT_OUTPUT="$(run_batch_complete 20461 2>&1)"
NATIVE_PARENT_STATUS=$?
set -e
NATIVE_PARENT_GH_LOG="$(cat "$FAKE_GH_LOG")"
assert_eq "native parent advisor ruling exits cleanly" "0" "$NATIVE_PARENT_STATUS"
assert_eq "native parent without recut state is retired as tracker" "true" \
  "$(state_field "$NATIVE_PARENT_HOME" 20461 '.tracker_parent == true and .native_subissue_parent == true')"
assert_contains "native parent leaves needs-advisor" "$NATIVE_PARENT_GH_LOG" \
  "--remove-label needs-advisor"
assert_not_contains "native parent never enters ready-for-agent from advisor" "$NATIVE_PARENT_GH_LOG" \
  "--add-label ready-for-agent"
unset FAKE_NATIVE_SUB_ISSUES_JSON

# A cached roadmap parent without the local tracker marker must leave the
# fresh advisor cohort, while a stored verdict remains available to the
# single-ticket resume path.
ROADMAP_PARENT_HOME="$(mktemp -d)"
TMP_DIRS+=("$ROADMAP_PARENT_HOME")
mkdir -p "$ROADMAP_PARENT_HOME/state"
seed_ticket "$ROADMAP_PARENT_HOME" 20471
ROADMAP_PARENT_TREE="$ROADMAP_PARENT_HOME/roadmap.json"
cat > "$ROADMAP_PARENT_TREE" <<'JSON'
{"roots":[{"number":90000,"title":"Roadmap","state":"open","labels":["roadmap"],"children":[{"number":20471,"title":"Parent","state":"open","labels":["needs-advisor"],"blockedBy":[{"number":20474,"state":"open"}],"children":[{"number":20472,"title":"Child","state":"open","labels":[],"children":[]}]}]}]}
JSON
export AGENT_HOME="$ROADMAP_PARENT_HOME"
export ZF_ROADMAP_TREE_CACHE_FILE="$ROADMAP_PARENT_TREE"
export FAKE_NATIVE_SUB_ISSUES_JSON='[]'
jq 'del(.roles.advisor.disabled) | .switches["roadmap-order"] = true' "$MODEL_POLICY_DEFAULT_FILE" \
  > "$ROADMAP_PARENT_HOME/model-policy.json"
export FAKE_GH_LOG="$ROADMAP_PARENT_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$ROADMAP_PARENT_HOME/web-advisor-provider.log"; : > "$FAKE_WEB_ADVISOR_PROVIDER_LOG"
ROADMAP_PARENT_OUTPUT="$(run_batch_complete 20471 2>&1)"
assert_eq "roadmap-only parent exits batch selection cleanly" "true" \
  "$(state_field "$ROADMAP_PARENT_HOME" 20471 '.state == "tracker" and .tracker_parent == true')"
assert_contains "roadmap-only parent records advisor exclusion" "$ROADMAP_PARENT_OUTPUT" \
  "roadmap parent waits on child tickets"
assert_not_contains "roadmap-only parent never starts a web advisor call" \
  "$(cat "$ROADMAP_PARENT_HOME/web-advisor-provider.log")" "dispatch:"
assert_not_contains "roadmap-only parent never enters ready-for-agent" \
  "$(cat "$ROADMAP_PARENT_HOME/gh.log")" "--add-label ready-for-agent"
assert_eq "roadmap parent child remains open" "open" \
  "$(jq -r '.roots[0].children[0].children[0].state' "$ROADMAP_PARENT_TREE")"
assert_eq "roadmap parent blocker remains open" "open" \
  "$(jq -r '.roots[0].children[0].blockedBy[0].state' "$ROADMAP_PARENT_TREE")"

ROADMAP_PENDING_HOME="$(mktemp -d)"
TMP_DIRS+=("$ROADMAP_PENDING_HOME")
mkdir -p "$ROADMAP_PENDING_HOME/state"
seed_ticket "$ROADMAP_PENDING_HOME" 20473
jq '.pending_advisor_verdict = {episode_seq: 1, computed_at:"2026-10-12T00:00:00Z", input:{title:"batch test issue #20473",body:null,comments:[]},result:{verdict:"misclassified"}}' \
  "$ROADMAP_PENDING_HOME/state/20473.json" > "$ROADMAP_PENDING_HOME/state/20473.json.tmp"
mv "$ROADMAP_PENDING_HOME/state/20473.json.tmp" "$ROADMAP_PENDING_HOME/state/20473.json"
jq 'del(.roles.advisor.disabled) | .switches["roadmap-order"] = true' "$MODEL_POLICY_DEFAULT_FILE" \
  > "$ROADMAP_PENDING_HOME/model-policy.json"
sed 's/20471/20473/g' "$ROADMAP_PARENT_TREE" > "$ROADMAP_PENDING_HOME/roadmap.json"
export AGENT_HOME="$ROADMAP_PENDING_HOME"
export ZF_ROADMAP_TREE_CACHE_FILE="$ROADMAP_PENDING_HOME/roadmap.json"
export FAKE_GH_LOG="$ROADMAP_PENDING_HOME/gh.log"; : > "$FAKE_GH_LOG"
export FAKE_WEB_ADVISOR_PROVIDER_LOG="$ROADMAP_PENDING_HOME/web-advisor-provider.log"; : > "$FAKE_WEB_ADVISOR_PROVIDER_LOG"
ROADMAP_PENDING_OUTPUT="$(run_batch_complete 20473 2>&1)"
assert_contains "stored roadmap-parent verdict is deferred to single-ticket resume" \
  "$ROADMAP_PENDING_OUTPUT" "single-ticket resume owns Apply"
assert_eq "stored roadmap-parent verdict remains pending" "true" \
  "$(state_field "$ROADMAP_PENDING_HOME" 20473 'has("pending_advisor_verdict")')"
assert_not_contains "stored roadmap-parent verdict makes no new advisor call" \
  "$(cat "$ROADMAP_PENDING_HOME/web-advisor-provider.log")" "dispatch:"
unset ZF_ROADMAP_TREE_CACHE_FILE MODEL_POLICY_FILE FAKE_NATIVE_SUB_ISSUES_JSON


[ "$FAILED" -eq 0 ] || exit 1
echo "ALL PASS"
