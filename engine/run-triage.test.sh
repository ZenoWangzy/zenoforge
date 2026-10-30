#!/usr/bin/env bash
# Regression tests for run-triage.sh's wrapper, Codex strict-schema contract,
# and 2026-09-15 ladder behavior: a
# /to-tickets ticket is MEASURED, never re-triaged (lib.sh issue_is_precut(),
# ladder_state()), and every judgment stop the model or the wrapper used to
# turn into ready-for-human now goes to the advisor rung. Plain bash
# assertions, no framework -- same fake-gh/fake-claude/fake-gitnexus/real-git
# pattern as run-advisor.test.sh. The L2 impact wording is pinned below; this
# does not re-test the hash scrubber, PR-state block, or notes_md legibility.
#
# The live incident this pins: #1193-#1208, 18 tickets the maintainer cut with
# /to-tickets on his Mac and moved to ready-for-agent with his own Agent
# Brief comment; the pipeline bounced them to needs-triage for having no
# state file, re-triaged them one by one, and the triage model wrote that it
# had deliberately overridden his "Maintainer direction" and parked all of
# them on ready-for-human.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

jq -e '(.required | index("expected_paths")) != null and .properties.expected_paths.type == "array" and ((.properties.expected_paths | has("minItems")) | not)' \
  "$(dirname "${BASH_SOURCE[0]}")/prompts/triage.schema.json" >/dev/null
jq -e '.properties.external_deliverable.type == "object" and .properties.external_deliverable.properties.required.type == "boolean" and ((.required | index("external_deliverable")) != null)' \
  "$(dirname "${BASH_SOURCE[0]}")/prompts/triage.schema.json" >/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIAGE_SRC="$SCRIPT_DIR/run-triage.sh"
N="$((90044000 + $$))"
export AGENT_MODEL="$MODEL_POLICY_TEST_WORK_IDENTITY"

FAILED=0
TMP_DIRS=()
cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$HOME/wt/triage-$N"
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

TRIAGE_PROMPT_CONTENT="$(cat "$SCRIPT_DIR/prompts/triage.md")"
assert_contains "unknown impact cannot count as L2 evidence" "$TRIAGE_PROMPT_CONTENT" '`UNKNOWN`, `target not found`, an error'
assert_contains "unknown impact cannot admit or reject L2" "$TRIAGE_PROMPT_CONTENT" $'Do not admit or\n       reject based on it: route unresolved L2 to `needs-advisor`'
assert_contains "unknown L2 impact stays neutral and routes to advisor" "$TRIAGE_PROMPT_CONTENT" 'route unresolved L2 to `needs-advisor`'

TRIAGE_SCHEMA_MISSING_REQUIRED="$(jq -c '(.required // []) as $required | [(.properties // {} | keys[]) as $key | select(($required | index($key)) == null) | $key]' "$SCRIPT_DIR/prompts/triage.schema.json")"
assert_eq "triage schema requires every key for Codex structured output" '[]' "$TRIAGE_SCHEMA_MISSING_REQUIRED"

# --- fake gh/codex/gitnexus, shadowing the real binaries on PATH -----------
FAKE_BIN="$(mktemp -d)"
TMP_DIRS+=("$FAKE_BIN")

# Fake gh: issue view's body/author come from FAKE_ISSUE_BODY/FAKE_AUTHOR
# (set per case); pr list returns no PRs; api (branch existence) fails as it
# would for a missing branch; every mutation is logged to FAKE_GH_LOG.
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# Native sub-issue reads (issue 2046): these fixtures have none.
if [ "${1:-}" = api ] && [[ "${2:-}" == */sub_issues* ]]; then echo '[]'; exit 0; fi
set -u
sub="$1 ${2:-}"
case "$sub" in
  "issue view")
    if [ -n "${FAKE_GH_PARENT_ISSUE_NUMBER:-}" ] && [ "${3:-}" = "$FAKE_GH_PARENT_ISSUE_NUMBER" ]; then
      echo "gh $*" >> "$FAKE_GH_LOG"
      jq -n --arg body "${FAKE_GH_PARENT_ISSUE_BODY:-}" '{body:$body}'
      exit 0
    fi
    view_count_file="${FAKE_GH_LOG}.views"
    view_count="$(cat "$view_count_file" 2>/dev/null || echo 0)"
    view_count=$((view_count + 1))
    printf '%s\n' "$view_count" > "$view_count_file"
    state=OPEN
    labels='[{"name":"enhancement"}]'
    if [ "${FAKE_BUG_ISSUE:-0}" = "1" ]; then
      labels='[{"name":"bug"},{"name":"needs-triage"}]'
    fi
    if [ "${FAKE_PIPELINE_SYSTEM:-0}" = "1" ]; then
      labels='[{"name":"enhancement"},{"name":"pipeline-system"},{"name":"needs-triage"}]'
    fi
    if [ -e "${FAKE_GH_LOG}.founder-test" ]; then
      labels="$(jq -c '. + [{name:"founder-test"}]' <<< "$labels")"
    fi
    if [ "$view_count" -gt 1 ]; then
      case "${FAKE_TRIAGE_STALE_MODE:-}" in
        closed)
          state=CLOSED
          labels='[{"name":"priority:top"},{"name":"released"}]' ;;
        labels)
          labels="$(jq -c '. + [{name:"released"}]' <<< "$labels")" ;;
      esac
    fi
    jq -n --arg body "${FAKE_ISSUE_BODY:-}" --arg author "${FAKE_AUTHOR:-testuser}" \
      --arg state "$state" --arg updated_at "${FAKE_ISSUE_UPDATED_AT:-2026-01-01T00:00:00Z}" --argjson labels "$labels" \
      '{number: 1, title: "triage test issue", body: $body, author: {login: $author}, comments: [], createdAt: "2026-01-01T00:00:00Z", updatedAt: $updated_at, state: $state, labels: $labels}' ;;
  "pr list") echo '[]' ;;
  "api") exit 1 ;;
  "issue comment")
    echo "gh $*" >> "$FAKE_GH_LOG"
    if [ -n "${FAKE_GH_COMMENT_CAPTURE:-}" ]; then
      while [ "$#" -gt 0 ]; do
        if [ "$1" = --body-file ]; then
          cat "$2" >> "$FAKE_GH_COMMENT_CAPTURE"
          break
        fi
        shift
      done
    fi ;;
  "label create"|"issue edit"|"issue close")
    echo "gh $*" >> "$FAKE_GH_LOG"
    if [ "$sub" = "issue edit" ] && [ "${FAKE_TRIAGE_LABEL_FAIL:-0}" = 1 ] && [[ " $* " == *" --add-label ready-for-agent "* ]]; then
      echo 'simulated stage label failure' >&2
      exit 1
    fi
    if [ "$sub" = "issue edit" ] && [[ " $* " == *" --add-label founder-test "* ]]; then
      : > "${FAKE_GH_LOG}.founder-test"
    fi ;;
  "variable get")
    echo "${FAKE_AGENT_PHASE:-3}" ;;
  *) : ;;
esac
exit 0
EOF

# Fake Codex: captures stdin prompt and writes structured result through
# --output-last-message, matching run_codex_json's real transport.
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -u
last_message=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output-last-message" ] && [ "$#" -ge 2 ]; then
    last_message="$2"
    shift 2
  else
    shift
  fi
done
cat > "${FAKE_PROMPT_CAPTURE:-/dev/null}"
printf '%s' "$FAKE_TRIAGE_STRUCTURED" > "$last_message"
printf 'tokens used\n4321\n'
EOF

# Fake gitnexus: the freshness check compares .gitnexus/meta.json (absent in
# this fixture) against origin/main and will read "not confirmed" -- fine
# for every case below (none is L2, so the L2 retry path never fires).
cat > "$FAKE_BIN/gitnexus" <<'EOF'
#!/usr/bin/env bash
echo "up-to-date"
exit 0
EOF

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case " $* " in *' list-units '*) exit 0 ;; esac
exit 1
EOF
REAL_NODE="$(command -v node)"
cat > "$FAKE_BIN/node" <<'EOF'
#!/usr/bin/env bash
if [[ "${1##*/}" == benny-repro.mjs ]]; then
  printf '%s\n' "$*" >> "$FAKE_BENNY_LOG"
  exit 0
fi
exec "$REAL_NODE" "$@"
EOF
chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/codex" "$FAKE_BIN/gitnexus" "$FAKE_BIN/systemctl" "$FAKE_BIN/node"
export PATH="$FAKE_BIN:$PATH"
export REAL_NODE
export REPO="test/repo"
export ZF_REPO="test/repo"
export ZF_GCLOUD_BIN="/nonexistent/gcloud"

# --- one shared git fixture: a bare origin + a clone with one commit -------
FIXTURE_ORIGIN="$(mktemp -d)"
FIXTURE_REPO="$(mktemp -d)"
TMP_DIRS+=("$FIXTURE_ORIGIN" "$FIXTURE_REPO")
git init -q --bare "$FIXTURE_ORIGIN"
git -C "$FIXTURE_ORIGIN" symbolic-ref HEAD refs/heads/main
git -C "$FIXTURE_REPO" init -q -b main
git -C "$FIXTURE_REPO" config user.email test@example.com
git -C "$FIXTURE_REPO" config user.name "Test"
mkdir -p "$FIXTURE_REPO/engine"
cp "$SCRIPT_DIR/model-policy.default.json" "$FIXTURE_REPO/engine/model-policy.default.json"
echo seed > "$FIXTURE_REPO/seed.txt"
git -C "$FIXTURE_REPO" add -A
git -C "$FIXTURE_REPO" commit -q -m seed
git -C "$FIXTURE_REPO" remote add origin "$FIXTURE_ORIGIN"
git -C "$FIXTURE_REPO" push -q -u origin main

PRECUT_BODY='## Parent

[总计划](https://github.com/example/repo/issues/1)

## What to build

员工在现有 /chat/ 交代一次任务，看到排队、准备、工具进度与可打开的成果。

## Acceptance criteria

- [ ] 刷新或断线回来仍是同一任务

## Blocked by

- #2'

RAW_BODY='### 入口

网页

### 发生了什么

导出报表时忽略了所选的分组，返回了全部 34 条。'

MAINTAINER_LOGIN="maintainer-login-for-this-test"

# run_once <body> <author> -- seeds AGENT_HOME (with a roster naming the
# maintainer login, no addresses), runs run-triage.sh live (not --dry-run).
run_once() {
  local body="$1" author="${2:-testuser}" seed_codex_outage="${3:-0}" seed_advisor_job="${4:-0}" pipeline_system="${5:-0}" stale_mode="${6:-}" expired_freshness="${7:-0}" active_freshness="${8:-0}" analyze_outcomes="${9:-}" advisor_admission="${10:-0}" bug_report="${11:-0}" agent_home status_index=0 status
  local -a analyze_statuses=()
  agent_home="$(mktemp -d)"
  TMP_DIRS+=("$agent_home")
  mkdir -p "$agent_home/state" "$agent_home/night"
  jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$agent_home/model-policy.json"
  jq -n --arg f "$MAINTAINER_LOGIN" '{founder_login: $f, recipients: {}}' > "$agent_home/recipients.json"
  if [ -n "$analyze_outcomes" ]; then
    IFS=, read -r -a analyze_statuses <<< "$analyze_outcomes"
    for status in "${analyze_statuses[@]}"; do
      printf 'run\tfixture-%s\t%s\tfixture-sha\t10000000\t10000000\t%s\t0\n' \
        "$status_index" "$(date +%s)" "$status" >> "$agent_home/night/gitnexus-analyze-memory.tsv"
      status_index=$((status_index + 1))
    done
    printf '%s\n' "$(date +%s)" > "$agent_home/gitnexus-analyze-last-start"
  fi

  export AGENT_HOME="$agent_home"
  export ZF_REPO_DIR="$FIXTURE_REPO"
  export FAKE_ISSUE_BODY="$body"
  export FAKE_AUTHOR="$author"
  export FAKE_PIPELINE_SYSTEM="$pipeline_system"
  export FAKE_BUG_ISSUE="$bug_report"
  export FAKE_TRIAGE_STALE_MODE="$stale_mode"
  export FAKE_GH_LOG="$agent_home/gh.log"
  export FAKE_BENNY_LOG="$agent_home/benny.log"
  export FAKE_GH_COMMENT_CAPTURE="$agent_home/comments.log"
  export FAKE_PROMPT_CAPTURE="$agent_home/prompt.txt"
  : > "$FAKE_GH_LOG"
  rm -f "${FAKE_GH_LOG}.founder-test"
  : > "${FAKE_GH_LOG}.views"
  if [ "$seed_advisor_job" = "1" ]; then
    jq -n --arg j "triage-job-$N" \
      '{web_advisor_provider_job_id:$j,web_advisor_provider_job_started_at:1,web_advisor_provider_job_episode_seq:2}' \
      > "$agent_home/state/$N.json"
  fi
  if [ "$expired_freshness" = "1" ]; then
    jq -n --arg updated_at "2026-01-01T00:00:00Z" --argjson since "$(( $(date +%s) - 3 * 60 * 60 ))" \
      '{triage_freshness_deferred_issue_updated_at:$updated_at,triage_freshness_deferred_since_epoch:$since}' \
      > "$agent_home/state/$N.json"
  fi
  if [ "$active_freshness" = "1" ]; then
    ACTIVE_FRESHNESS_RETRY_EPOCH="$(( $(date +%s) + 600 ))"
    jq -n --arg updated_at "2026-01-01T00:00:00Z" --argjson retry "$ACTIVE_FRESHNESS_RETRY_EPOCH" --argjson since "$(date +%s)" \
      '{triage_retry_after_epoch:$retry,triage_freshness_deferred_issue_updated_at:$updated_at,triage_freshness_deferred_since_epoch:$since}' \
      > "$agent_home/state/$N.json"
  fi
  [ -z "${SEED_STATE_JSON:-}" ] || printf '%s\n' "$SEED_STATE_JSON" > "$agent_home/state/$N.json"
  if [ "$advisor_admission" = "1" ]; then
    local state_file="$agent_home/state/$N.json"
    if [ -s "$state_file" ]; then
      jq '. + {advisor_admission_measure_only:true,guarded:true} | .model_policy = ((.model_policy // {}) + {unit:"triage",step:"work_retry"})' \
        "$state_file" > "$state_file.tmp"
    else
      jq -n '{advisor_admission_measure_only:true,guarded:true,model_policy:{unit:"triage",step:"work_retry"}}' \
        > "$state_file.tmp"
    fi
    mv "$state_file.tmp" "$state_file"
  fi
  if [ "$seed_codex_outage" = "1" ]; then
    printf '%s\n' "$(( $(date +%s) - 1 ))" > "$agent_home/codex-exhausted-until"
    : > "$agent_home/codex-exhausted-until.alerted"
  fi

  set +e
  RUN_OUTPUT="$(bash "$TRIAGE_SRC" "$N" 2>&1)"
  RUN_STATUS=$?
  set -e

  GH_LOG_CONTENT="$(cat "$FAKE_GH_LOG" 2>/dev/null || true)"
  BENNY_LOG_CONTENT="$(cat "$FAKE_BENNY_LOG" 2>/dev/null || true)"
  COMMENT_CONTENT="$(cat "$FAKE_GH_COMMENT_CAPTURE" 2>/dev/null || true)"
  STATE_CONTENT="$(cat "$agent_home/state/$N.json" 2>/dev/null || true)"
  PROMPT_CONTENT="$(cat "$agent_home/prompt.txt" 2>/dev/null || true)"
  SPEND_CONTENT="$(cat "$agent_home"/spend/*.log 2>/dev/null || true)"
  INBOX_CONTENT="$(cat "$agent_home/supervisor-inbox" 2>/dev/null || true)"
}

verdict() {
  # verdict <state> <risk> <level> [category] -- a minimal structured triage output.
  jq -nc --arg s "$1" --arg r "$2" --arg l "$3" --arg c "${4:-enhancement}" \
    '{category: $c, state: $s, risk_class: $r, level: $l, entry_surface: "Web /chat/", acceptor: "maintainer", brief_md: "**Summary:** 测量简报。", notes_md: "有几个问题想确认。", expected_packages: ["packages/react-example"], expected_paths: [], estimated_changed_lines: 0, external_deliverable: {required:false, location:"", reason:""}}'
}

# --- precut, model says ready-for-human (the #1193 shape): measured, never -
# --- parked -- the ladder decides, and P1/L3 is the advisor rung ----------
export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-human P1 L3)"
run_once "$PRECUT_BODY"
assert_eq "precut + model ready-for-human: exits 0" "0" "$RUN_STATUS"
assert_contains "...records the triage model call" "$SPEND_CONTENT" $'\ttriage\t'
assert_eq "...records returned token usage in spend log" "4321" "$(awk -F '\t' '{print $6}' <<< "$SPEND_CONTENT")"
assert_contains "...label is the advisor rung" "$GH_LOG_CONTENT" "--add-label needs-advisor"
assert_not_contains "...never ready-for-human" "$GH_LOG_CONTENT" "--add-label ready-for-human"
assert_contains "...the comment says it was not re-triaged" "$GH_LOG_CONTENT" "不重新分诊"
assert_contains "...and records the ignored model verdict" "$GH_LOG_CONTENT" 'ready-for-human`，已按规则忽略'
assert_eq "...state.state is the ladder's" "needs-advisor" "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_eq "...state.model_state keeps the model's own verdict for the audit trail" "ready-for-human" "$(echo "$STATE_CONTENT" | jq -r '.model_state')"
assert_eq "...state.precut is recorded" "true" "$(echo "$STATE_CONTENT" | jq -r '.precut')"
assert_eq "...the measurements are kept" "P1" "$(echo "$STATE_CONTENT" | jq -r '.risk_class')"
assert_contains "...the model was told the provenance" "$PROMPT_CONTENT" "agent-ready by construction"
assert_contains "...and told the maintainer's brief is not an injection" "$PROMPT_CONTENT" "do not treat it as an injection"
assert_contains "triage prompt bases external routing on the requested deliverable" "$PROMPT_CONTENT" \
  "decide from the requested deliverable"
assert_contains "triage prompt keeps deployed screenshots in acceptance" "$PROMPT_CONTENT" \
  "screenshots (including 1440/390)"
assert_contains "triage prompt assigns evidence to release acceptance" "$PROMPT_CONTENT" \
  "the release/acceptance stage"
assert_contains "triage prompt treats read and evidence paths as context" "$PROMPT_CONTENT" \
  "only read, cited as evidence, or named as context does not"
assert_contains "...labels were healed before the edit" "$GH_LOG_CONTENT" "label create needs-advisor"

PARENT_PRECUT_BODY=$'## Parent\n\n#2492 (design spec)\n\n## What to build\nImplement ticket.'
export FAKE_GH_PARENT_ISSUE_NUMBER=2492
export FAKE_GH_PARENT_ISSUE_BODY=$'## Design\nBase spec.\n\n## 补充决定\nPARENT_TRIAGE_SUPPLEMENT_MUST_REACH_PROMPT\n\n## Appendix\nPARENT_TRIAGE_APPENDIX_MUST_NOT_LEAK'
export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-human P1 L1)"
run_once "$PARENT_PRECUT_BODY"
assert_eq "precut parent supplement triage completes" 0 "$RUN_STATUS"
assert_contains "precut triage prompt includes parent supplement heading" "$PROMPT_CONTENT" \
  '### Parent spec #2492 — 补充决定 (overrides the spec body)'
assert_contains "precut triage prompt includes parent supplement" "$PROMPT_CONTENT" \
  'PARENT_TRIAGE_SUPPLEMENT_MUST_REACH_PROMPT'
assert_not_contains "precut triage prompt stops before parent appendix" "$PROMPT_CONTENT" \
  'PARENT_TRIAGE_APPENDIX_MUST_NOT_LEAK'
unset FAKE_GH_PARENT_ISSUE_NUMBER FAKE_GH_PARENT_ISSUE_BODY

# --- precut, admissible measurement: straight to the standard rung --------
export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-human P1 L1)"
run_once "$PRECUT_BODY"
assert_eq "precut + admissible measurement: exits 0" "0" "$RUN_STATUS"
assert_contains "...label is ready-for-agent" "$GH_LOG_CONTENT" "--add-label ready-for-agent"

# Configured non-product issues get lightweight classification. Even a
# founder-authored question does not enter the product triage/advisor queue.
export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-human P2 L3)"
run_once "$RAW_BODY" testuser 0 0 1
assert_eq "pipeline-system lightweight classification: exits 0" "0" "$RUN_STATUS"
assert_contains "pipeline-system lightweight classification enters implement" "$GH_LOG_CONTENT" "--add-label ready-for-agent"
assert_not_contains "pipeline-system lightweight classification avoids advisor" "$GH_LOG_CONTENT" "--add-label needs-advisor"
assert_eq "pipeline-system triage does not call a model" "" "$PROMPT_CONTENT"
assert_eq "pipeline-system lane is persisted" "true" "$(echo "$STATE_CONTENT" | jq -r '.pipeline_system.enabled')"

export FAKE_TRIAGE_STRUCTURED="$(verdict needs-info P1 L1)"
run_once "$RAW_BODY" "$MAINTAINER_LOGIN" 0 0 1
assert_eq "pipeline-system maintainer issue also bypasses the advisor queue" "0" "$RUN_STATUS"
assert_contains "pipeline-system maintainer issue goes directly to implementation" "$GH_LOG_CONTENT" "--add-label ready-for-agent"
assert_not_contains "pipeline-system maintainer issue creates no product ruling" "$STATE_CONTENT" "product_ruling"
assert_not_contains "pipeline-system maintainer issue never reaches advisor" "$GH_LOG_CONTENT" "--add-label needs-advisor"

# --- precut, model says needs-info: nobody is asked, nothing is mailed ----
export FAKE_TRIAGE_STRUCTURED="$(verdict needs-info P1 L1)"
run_once "$PRECUT_BODY"
assert_eq "precut + model needs-info: exits 0" "0" "$RUN_STATUS"
assert_contains "...label is ready-for-agent (the ladder, not the model)" "$GH_LOG_CONTENT" "--add-label ready-for-agent"
assert_not_contains "...never needs-info" "$GH_LOG_CONTENT" "--add-label needs-info"
assert_not_contains "...no reporter email" "$RUN_OUTPUT" "notify_reporter_question"
assert_eq "...state.state is ready-for-agent" "ready-for-agent" "$(echo "$STATE_CONTENT" | jq -r '.state')"

# --- precut, model says wontfix/duplicate: also ignored -- the maintainer --
# --- cut it, the ticket is not closed by a measurement -------------------
export FAKE_TRIAGE_STRUCTURED="$(verdict wontfix P1 L1)"
run_once "$PRECUT_BODY"
assert_eq "precut + model wontfix: exits 0" "0" "$RUN_STATUS"
assert_not_contains "...never closes the issue" "$GH_LOG_CONTENT" "issue close"
assert_not_contains "...never applies wontfix" "$GH_LOG_CONTENT" "--add-label wontfix"
assert_contains "...admits it instead" "$GH_LOG_CONTENT" "--add-label ready-for-agent"

# A raw wontfix/duplicate conclusion owns an advisor job marker from an
# earlier episode in this regression fixture. The direct close path must retire
# it before the final state merge, not rely on run-advisor.sh having done so.
export FAKE_TRIAGE_STRUCTURED="$(verdict wontfix P1 L1)"
run_once "$RAW_BODY" testuser 0 1
assert_eq "raw + wontfix with an advisor job: exits 0" "0" "$RUN_STATUS"
assert_contains "raw + wontfix with an advisor job: closes the issue" "$GH_LOG_CONTENT" "issue close $N"
assert_eq "raw + wontfix with an advisor job: clears job id" "null" "$(echo "$STATE_CONTENT" | jq -r '.web_advisor_provider_job_id // null')"

export FAKE_TRIAGE_STRUCTURED="$(verdict duplicate P1 L1)"
run_once "$RAW_BODY" testuser 0 1
assert_eq "raw + duplicate with an advisor job: exits 0" "0" "$RUN_STATUS"
assert_contains "raw + duplicate with an advisor job: closes the issue" "$GH_LOG_CONTENT" "issue close $N"
assert_eq "raw + duplicate with an advisor job: clears job id" "null" "$(echo "$STATE_CONTENT" | jq -r '.web_advisor_provider_job_id // null')"

# --- raw report, model says ready-for-human: the advisor rung, not a human -
export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-human P1 L1)"
run_once "$RAW_BODY"
assert_eq "raw + model ready-for-human: exits 0" "0" "$RUN_STATUS"
assert_contains "...label is needs-advisor" "$GH_LOG_CONTENT" "--add-label needs-advisor"
assert_not_contains "...never ready-for-human" "$GH_LOG_CONTENT" "--add-label ready-for-human"
assert_contains "...the comment says why" "$GH_LOG_CONTENT" "Routed to the advisor instead of a human"
assert_eq "...state.precut is false for a raw report" "false" "$(echo "$STATE_CONTENT" | jq -r '.precut')"
assert_not_contains "...the model was NOT told it is precut" "$PROMPT_CONTENT" "agent-ready by construction"

# --- raw report, model over-admits P2/L3: the gate still refuses, and the --
# --- refusal still goes to the advisor (unchanged from the advisor leg) ----
export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-agent P2 L3)"
run_once "$RAW_BODY"
assert_eq "raw + over-admitted P2/L3: exits 0" "0" "$RUN_STATUS"
assert_contains "...label is needs-advisor" "$GH_LOG_CONTENT" "--add-label needs-advisor"
assert_not_contains "...never ready-for-agent" "$GH_LOG_CONTENT" "--add-label ready-for-agent"

# --- raw report, admissible: ready-for-agent, unchanged --------------------
export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-agent P1 L1)"
run_once "$RAW_BODY"
assert_eq "raw + admissible: exits 0" "0" "$RUN_STATUS"
assert_contains "...label is ready-for-agent" "$GH_LOG_CONTENT" "--add-label ready-for-agent"

# A new issue from the bug-report form gets a repro attempt after triage has
# mapped its expected path onto an existing Acceptance catalog feature.
export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-agent P1 L1 bug | jq '.expected_paths = ["packages/example-service/src/openai-compat"]')"
run_once "$RAW_BODY" testuser 0 0 0 "" 0 0 "" 0 1
assert_eq "user bug report triage exits 0" "0" "$RUN_STATUS"
assert_contains "user bug report dispatches Benny with its triage and issue fixtures" "$BENNY_LOG_CONTENT" \
  "benny-repro.mjs --issue-file"
assert_contains "user bug report passes the configured repository to Benny" "$BENNY_LOG_CONTENT" \
  "--repo test/repo"

# A single-ticket verdict also expires when any issue label changes while its
# model call is running.
run_once "$RAW_BODY" testuser 0 0 0 labels
assert_eq "changed labels discard a single-ticket verdict" "0" "$RUN_STATUS"
assert_contains "single-ticket stale guard explains label change" "$RUN_OUTPUT" "labels changed since snapshot"
assert_not_contains "single-ticket stale verdict applies no label" "$GH_LOG_CONTENT" "issue edit"
assert_not_contains "single-ticket stale verdict posts no comment" "$GH_LOG_CONTENT" "issue comment"
assert_eq "single-ticket stale verdict stores no classification" "false" "$(echo "$STATE_CONTENT" | jq 'has("risk_class")')"

# Expiry permits a probe; successful Codex call clears both outage markers.
run_once "$RAW_BODY" testuser 1
assert_eq "successful Codex triage clears its prior outage marker" "false" \
  "$([ -e "$AGENT_HOME/codex-exhausted-until" ] && echo true || echo false)"
assert_eq "successful Codex triage clears the one-outage alert latch" "false" \
  "$([ -e "$AGENT_HOME/codex-exhausted-until.alerted" ] && echo true || echo false)"

# --- raw report by the MAINTAINER, model says needs-info: the advisor picks --
# --- the defaults; used to be ready-for-human ------------------------------
export FAKE_TRIAGE_STRUCTURED="$(verdict needs-info P1 L1)"
run_once "$RAW_BODY" "$MAINTAINER_LOGIN"
assert_eq "founder-authored + needs-info: exits 0" "0" "$RUN_STATUS"
assert_contains "...label is needs-advisor" "$GH_LOG_CONTENT" "--add-label needs-advisor"
assert_not_contains "...never ready-for-human" "$GH_LOG_CONTENT" "--add-label ready-for-human"
assert_not_contains "...never needs-info" "$GH_LOG_CONTENT" "--add-label needs-info"
assert_contains "...the pending points and defaults are posted for the advisor" "$GH_LOG_CONTENT" "交给顾问按授权定案"
assert_not_contains "...no email to anyone" "$RUN_OUTPUT" "notify_reporter_question"

# --- raw report, needs-info, non-founder, legible: failed reporter delivery
# --- must transfer ownership to the advisor -------------------------------
export FAKE_TRIAGE_STRUCTURED="$(verdict needs-info P1 L1)"
run_once "$RAW_BODY" "someone-else"
assert_eq "non-founder needs-info with unavailable mail: exits 0" "0" "$RUN_STATUS"
assert_contains "...failed reporter delivery enters advisor queue" "$GH_LOG_CONTENT" "--add-label needs-advisor"
assert_contains "...failed reporter delivery removes needs-info" "$GH_LOG_CONTENT" "--remove-label needs-info"
assert_eq "...failed reporter delivery persists advisor ownership" "needs-advisor" "$(echo "$STATE_CONTENT" | jq -r '.state')"

# --- stale GitNexus freshness: defer this issue so priority cannot starve ----
# The model can only return ready-for-human at the L2 freshness gate. That is
# an environment deferral, not a ticket verdict; persist the next retry time so
# issue-pipeline.sh can spend its only triage slot on another issue meanwhile.
export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-human P1 L2)"
run_once "$RAW_BODY"
assert_eq "unconfirmed L2 freshness deferral: exits 0" "0" "$RUN_STATUS"
assert_contains "unconfirmed L2 freshness deferral is recorded" "$RUN_OUTPUT" "unconfirmed index freshness"
assert_eq "unconfirmed L2 freshness schedules a later retry" "true" \
  "$(echo "$STATE_CONTENT" | jq -e --argjson now "$(date +%s)" '.triage_retry_after_epoch > $now' >/dev/null && echo true || echo false)"
assert_eq "freshness retry records issue version" "2026-01-01T00:00:00Z" \
  "$(echo "$STATE_CONTENT" | jq -r '.triage_freshness_deferred_issue_updated_at')"
assert_eq "freshness retry records bounded deferral start" "true" \
  "$(echo "$STATE_CONTENT" | jq -e '.triage_freshness_deferred_since_epoch > 0' >/dev/null && echo true || echo false)"
assert_not_contains "unconfirmed L2 freshness leaves GitHub labels untouched" "$GH_LOG_CONTENT" "gh issue edit"

export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-agent P1 L2)"
run_once "$RAW_BODY" testuser 0 0 0 "" 0 0 "124,124,124"
assert_eq "three failed analyzes skip freshness deferral and triage immediately" "0" "$RUN_STATUS"
assert_eq "three failed analyzes keep the L2 gate closed" "needs-advisor" "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_eq "three failed analyzes do not schedule another deferral" "0" "$(echo "$STATE_CONTENT" | jq -r '.triage_retry_after_epoch // 0')"
assert_contains "decision comment explains the skipped deferral" "$GH_LOG_CONTENT" "last 3 GitNexus analyze runs failed"

run_once "$RAW_BODY" testuser 0 0 0 "" 0 0 "124,124,0"
assert_eq "a recent successful analyze keeps the existing freshness deferral" "0" "$RUN_STATUS"
assert_eq "a recent success still schedules the bounded retry" "true" \
  "$(echo "$STATE_CONTENT" | jq -e --argjson now "$(date +%s)" '.triage_retry_after_epoch > $now' >/dev/null && echo true || echo false)"

export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-agent P1 L2)"
run_once "$RAW_BODY" testuser 0 0 0 "" 1
assert_eq "expired single-ticket freshness deferral exits 0" "0" "$RUN_STATUS"
assert_contains "expired L2 freshness goes to advisor" "$GH_LOG_CONTENT" "--add-label needs-advisor"
assert_not_contains "expired L2 freshness never enters implement queue" "$GH_LOG_CONTENT" "--add-label ready-for-agent"
assert_not_contains "expired L2 freshness never uses human terminal" "$GH_LOG_CONTENT" "--add-label ready-for-human"
assert_eq "expired L2 freshness persists advisor state" "needs-advisor" "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_contains "advisor comment explains freshness gate" "$GH_LOG_CONTENT" "L2 impact freshness was not confirmed"

# Issue 2040: an advisor-admitted episode is measure-only even when triage
# returns ready-for-human and its L2 freshness check remains blocked.
export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-human P1 L2)"
run_once "$RAW_BODY" testuser 0 0 0 "" 1 0 "" 1
assert_eq "2040 advisor admission + blocked L2 measurement exits 0" "0" "$RUN_STATUS"
assert_contains "2040 keeps the admitted ready-for-agent label" "$GH_LOG_CONTENT" "--add-label ready-for-agent"
assert_not_contains "2040 never sends the admitted ticket back to advisor" "$GH_LOG_CONTENT" "--add-label needs-advisor"
assert_eq "2040 keeps ready-for-agent state despite model and freshness" "ready-for-agent" "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_eq "2040 retains guarded admission" true "$(echo "$STATE_CONTENT" | jq -r '.guarded')"
assert_eq "2040 keeps measured risk and level" "L2" "$(echo "$STATE_CONTENT" | jq -r '.level')"
assert_eq "2040 preserves raw model verdict for audit" "ready-for-human" "$(echo "$STATE_CONTENT" | jq -r '.model_state')"
assert_eq "2040 consumes the measure-only marker after measurement" "false" "$(echo "$STATE_CONTENT" | jq 'has("advisor_admission_measure_only")')"

# Founder-test bypasses the environment retry, but still sees the same
# unconfirmed-freshness L2 gate. It must continue to advisor, never agent.
export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-agent P1 L2)"
run_once "$RAW_BODY" "$MAINTAINER_LOGIN" 0 0 0 "" 0 1
assert_eq "founder-test + unconfirmed L2 freshness: exits 0" "0" "$RUN_STATUS"
assert_contains "founder-test label is persisted during direct triage" "$GH_LOG_CONTENT" "--add-label founder-test"
assert_contains "unconfirmed L2 verdict proceeds to advisor" "$GH_LOG_CONTENT" "--add-label needs-advisor"
assert_not_contains "unconfirmed L2 verdict never reaches implementation" "$GH_LOG_CONTENT" "--add-label ready-for-agent"
assert_eq "founder-test freshness bypass leaves existing retry deadline unchanged" "$ACTIVE_FRESHNESS_RETRY_EPOCH" \
  "$(echo "$STATE_CONTENT" | jq -r '.triage_retry_after_epoch')"

# Issue 2007: acceptance that writes outside this checkout belongs to
# supervisor/ops. Only the model's explicit judgment may route it there.
export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-agent P1 L1 | jq --arg location '~/.zenoforge/night/implement-concurrency-report.md' --arg reason 'Acceptance requires writing the requested report on the host.' '.expected_packages = [] | .expected_paths = [] | . + {external_deliverable:{required:true,location:$location,reason:$reason}}')"
run_once $'### Acceptance criteria\n- Record a real tick in `~/.zenoforge/night/implement-concurrency-report.md`.'
assert_eq "external ~/.zenoforge acceptance exits cleanly" 0 "$RUN_STATUS"
assert_eq "external ~/.zenoforge acceptance is on hold" on-hold "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_eq "external ~/.zenoforge acceptance retains its supervisor hold" external-deliverable "$(echo "$STATE_CONTENT" | jq -r '.hold.kind')"
assert_contains "external ~/.zenoforge acceptance gets on-hold label" "$GH_LOG_CONTENT" "--add-label on-hold"
assert_not_contains "external ~/.zenoforge acceptance skips implement label" "$GH_LOG_CONTENT" "--add-label ready-for-agent"
assert_contains "external ~/.zenoforge acceptance reaches supervisor inbox" "$INBOX_CONTENT" \
  '~/.zenoforge/night/implement-concurrency-report.md'
assert_not_contains "fresh external acceptance is not handed to scheduler before hold expiry" "$STATE_CONTENT" 'scheduler_handoff'
assert_contains "external hold posts issue comment" "$GH_LOG_CONTENT" "gh issue comment $N"
assert_contains "external hold comment explains the model's reason" "$COMMENT_CONTENT" \
  'Acceptance requires writing the requested report on the host.'

# Issue 2695: in-repo code anchors plus production screenshots/shared-account
# verification stay in implementation; deploy acceptance gathers that evidence.
export FAKE_TRIAGE_STRUCTURED="$(verdict on-hold P1 L1 | jq \
  --arg location 'production /chat/ screenshots and shared account' \
  --arg reason 'Acceptance requires 1440/390 screenshots after deployment using the shared account.' \
  '.expected_paths = ["packages/react-example/src/chat-progress.ts"] | . + {external_deliverable:{required:true,location:$location,reason:$reason}}')"
run_once $'### Change\nFix the chat progress stream in packages/react-example.\n\n### Acceptance criteria\n- After deploy, capture production /chat/ screenshots at 1440 and 390 widths using the shared account.'
assert_eq "in-repo code with production screenshot acceptance exits cleanly" 0 "$RUN_STATUS"
assert_eq "production screenshot acceptance stays implementable" ready-for-agent "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_contains "in-repo screenshot issue gets implement label" "$GH_LOG_CONTENT" "--add-label ready-for-agent"
assert_not_contains "in-repo screenshot issue skips external on-hold" "$GH_LOG_CONTENT" "--add-label on-hold"
assert_not_contains "in-repo screenshot issue skips supervisor inbox" "$INBOX_CONTENT" "external-deliverable"
assert_eq "product issue persists post-release ops acceptance" true "$(echo "$STATE_CONTENT" | jq -r '.ops_acceptance_after_release.required')"
assert_eq "product issue assigns step to release acceptance" release-acceptance "$(echo "$STATE_CONTENT" | jq -r '.ops_acceptance_after_release.owner')"
PRODUCT_BRIEF="$(echo "$STATE_CONTENT" | jq -r '.brief_md')"
assert_contains "product brief carries ops acceptance step" "$PRODUCT_BRIEF" "Ops acceptance after release"
assert_contains "wrapper records narrower product routing" "$RUN_OUTPUT" "outside acceptance moves to release"

export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-agent P1 L1 | jq --arg location 'example-infra manual workflow file' --arg reason 'Acceptance requires changing a workflow file in another repository.' '.expected_packages = [] | .expected_paths = [] | . + {external_deliverable:{required:true,location:$location,reason:$reason}}')"
run_once $'### Acceptance criteria\n- Change the example-infra manual workflow file to enable the requested build.'
assert_eq "other-repo and cihost acceptance exits cleanly" 0 "$RUN_STATUS"
assert_eq "other-repo and cihost acceptance is on hold" on-hold "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_eq "other-repo acceptance remains a supervisor hold" external-deliverable "$(echo "$STATE_CONTENT" | jq -r '.hold.kind')"
assert_contains "other-repo and cihost acceptance reaches supervisor inbox" "$INBOX_CONTENT" "example-infra"
assert_contains "other-repo hold comment includes model reason" "$COMMENT_CONTENT" \
  'Acceptance requires changing a workflow file in another repository.'

export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-agent P1 L1)"
# Issues 2185 and 2188: cihost names where each bug was observed, not its deliverable.
run_once $'## 现象\n出库提案卡缺单价。\n\n## 环境\ncihost 生产；example-uat'
assert_eq "cihost environment line exits cleanly" 0 "$RUN_STATUS"
assert_eq "cihost environment line stays implementable" ready-for-agent "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_not_contains "cihost environment line skips the supervisor inbox" "$INBOX_CONTENT" "external-deliverable"
run_once $'## Bug\nPrice missing from the Example proposal card.\n\n## Environment\nObserved on cihost production.'
assert_eq "second cihost observation stays implementable" ready-for-agent "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_not_contains "second cihost observation skips supervisor inbox" "$INBOX_CONTENT" "external-deliverable"

# A supervisor-released external hold is not re-applied on re-triage (1437, 2026-10-03).
SEED_STATE_JSON='{"external_deliverable_reviewed_at":"2026-10-03T08:55:00Z"}' \
  run_once $'### Context\nThe earlier ticket mentions the example-infra workflow.\n\n### Acceptance criteria\n- Fix the in-repository checker regression.'
assert_eq "reviewed external hold exits cleanly" 0 "$RUN_STATUS"
assert_eq "reviewed external hold is not re-applied" ready-for-agent "$(echo "$STATE_CONTENT" | jq -r '.state')"

# Issues 2256 and 2257: private evidence paths are input, not requested output.
run_once $'## 观察证据\n生产 gateway 返回500。\n\n私有日志：`~/.zenoforge/night/hand-2254-artifacts/chat-gateway.log`。\n\n## 可测试验收\n- 合法的健康事件返回成功。'
assert_eq "hand evidence path exits cleanly" 0 "$RUN_STATUS"
assert_eq "hand evidence path stays implementable" ready-for-agent "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_not_contains "hand evidence path skips the supervisor inbox" "$INBOX_CONTENT" "external-deliverable"
run_once $'## Evidence\nThe monitor showed the failed request in `~/.zenoforge/night/hand-2254-artifacts/monitor-final.jsonl`.\n\n## Acceptance\n- Return success for a valid health event.'
assert_eq "second hand evidence path stays implementable" ready-for-agent "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_not_contains "second hand evidence path skips supervisor inbox" "$INBOX_CONTENT" "external-deliverable"

# "separate reporting-policy version" is not a separate repo (2501, 2026-10-04).
run_once $'## Current behavior\n`ExamplePeriodCloseService` keeps the model version, but no separate reporting-policy version.'
assert_eq "separate reporting prose exits cleanly" 0 "$RUN_STATUS"
assert_eq "separate reporting prose stays implementable" ready-for-agent "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_not_contains "separate reporting prose skips the supervisor inbox" "$INBOX_CONTENT" "external-deliverable"

# Issue 2637: COORD is read as input; only the docs/ops change is delivered here.
export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-agent P1 L1 | jq 'del(.external_deliverable)')"
run_once $'### Context\nRead the COORD notes under `~/.zenoforge/` before touching containers.\n\n### Acceptance criteria\n- Write the manual record from COORD into docs/ops/.'
assert_eq "2637 missing external judgment defaults to implement" ready-for-agent "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_not_contains "2637 missing external judgment skips supervisor inbox" "$INBOX_CONTENT" "external-deliverable"

export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-agent P1 L1 | jq '. + {external_deliverable:{required:"true",location:"example-infra manual workflow file",reason:"malformed flag"}}')"
run_once $'### Context\nThe issue mentions example-infra.\n\n### Acceptance criteria\n- Add in-repository workflow parsing coverage.'
assert_eq "malformed external judgment defaults to implement" ready-for-agent "$(echo "$STATE_CONTENT" | jq -r '.state')"
assert_not_contains "malformed external judgment skips supervisor inbox" "$INBOX_CONTENT" "external-deliverable"

export FAKE_TRIAGE_STRUCTURED="$(verdict ready-for-agent P1 L1)"
export FAKE_TRIAGE_LABEL_FAIL=1
SEED_STATE_JSON='{"state":"needs-triage"}' run_once "$RAW_BODY"
unset FAKE_TRIAGE_LABEL_FAIL
assert_eq "failed triage stage edit exits nonzero" 1 "$RUN_STATUS"
assert_eq "failed triage stage edit restores the prior state" needs-triage "$(jq -r '.state' <<< "$STATE_CONTENT")"
assert_contains "failed triage stage edit logs rollback" "$RUN_OUTPUT" 'issue_transition: label write failed'

if [ "$FAILED" -eq 1 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS"
