_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

# 2026-09-13 #1098: run-triage.sh's ISSUE_JSON gives the model the full
# comment history but nothing about what actually happened to a PR that
# history mentions -- a PR's own state (closed, branch deleted) changes
# without ever posting a new issue comment, so a stale "PR #1099 left open,
# needs a human" comment from hours earlier still reads as current. The
# model cannot check for itself: `gh` is denied in prompts/agent-
# settings.json. Live proof: #1098's triage run read exactly that stale
# comment and returned state=finish-first citing PR #1099, which by then was
# CLOSED with its branch (`agent/issue-1098`) deleted -- and issue-
# pipeline.sh's section (c0) sends a finish-first issue with no colliding
# open PR/expected_packages straight back to needs-triage, so the very next
# triage run reads the same stale comment and returns finish-first again.
# An infinite loop, not a one-off.
#
# This function only renders; run-triage.sh gathers $2 with live `gh pr
# list`/`gh api .../branches/..` calls (outside the model's sandbox) before
# ever building the prompt. $2 is a JSON array of {number, state, isDraft,
# headRefName, branch_exists} -- branch_exists is the one signal a comment
# cannot carry, because it is derived from the CURRENT remote, not from
# anything anyone wrote. $3 is "1" when those `gh` queries themselves
# succeeded, "0" on any failure -- a failure must say so plainly and let
# triage proceed on its other evidence (issue thread, code reading), never
# render an empty block indistinguishable from "confirmed zero PRs".
render_pr_state_block() {
  local n="$1" prs_json="$2" query_ok="${3:-1}"
  echo "## Live pull request state for issue #$n (queried live via gh by the wrapper, not read from the thread)"
  if [ "$query_ok" != "1" ]; then
    echo "PR query failed. Treat live PR state as unknown for this run -- proceed with triage on the evidence above; a \`gh\` hiccup here is not a reason to withhold or grant any state."
    return 0
  fi
  local count
  count="$(echo "$prs_json" | jq 'length' 2>/dev/null || echo 0)"
  if [ "$count" -eq 0 ]; then
    echo "No open, closed, or merged pull request currently references issue #$n (checked head branch \`agent/issue-$n\` and any PR whose title or body mentions \`#$n\`)."
    return 0
  fi
  echo "$prs_json" | jq -r '
    .[] | "- PR #\(.number): \(.state)" +
      (if .isDraft then " (draft)" else "" end) +
      ", head branch `\(.headRefName)`, branch " +
      (if .branch_exists then "still exists on the remote" else "deleted from the remote" end)
  '
}


# One row per check name on the PR's current head, via the shared
# pr-required-aggregate.mjs --latest-checks reduction: SKIPPED rows are
# dropped and superseded same-name runs collapse to the newest run (the
# semantics live in that module). `gh pr checks` exposes the Actions run id
# in its link; PR statusCheckRollup rows carry a start/creation timestamp.
pr_latest_check_rows() {
  local lib_dir
  lib_dir="$(cd -- "$(dirname -- "$_AGENT_LIB_DIR/lib.sh")" && pwd -P)" || return 1
  node "$lib_dir/ci/pr-required-aggregate.mjs" --latest-checks <<< "$1"
}


# Classifies a `gh pr checks --json name,bucket[,link]` array ($1) into one
# of: pass / pending / fail, after discarding superseded same-name runs. Order matters:
#   1. any bucket=="fail"/"cancel" ANYWHERE fails the whole rollup immediately
#      -- no reason to keep waiting on an unrelated still-pending check once
#      something has definitively failed.
#   2. any bucket=="pending" left (on anything) means CI is still running --
#      keep waiting.
#   3. otherwise, every name in REQUIRED_PR_CHECKS must have at least one
#      pass row. The required rows are the always-concluding aggregates
#      (#4484): each one already rolls up its workflow's gates (pass, or a
#      legitimate skip), so no per-gate enumeration happens here anymore.
#      Missing rows fail closed; skipped rows never reach this far (the
#      --latest-checks reduction above drops them). Non-required check names
#      (this repo has no branch protection, so `gh pr checks` returns whatever
#      ran) are otherwise ignored -- see lib.test.sh for fixtures plus
#      real-failure, missing-required, skipped, and pending cases.
pr_checks_outcome() {
  local checks_json="$1" name rows latest_checks
  latest_checks="$(pr_latest_check_rows "$checks_json" 2>/dev/null)" || { echo "fail"; return 0; }
  checks_json="$latest_checks"
  if echo "$checks_json" | jq -e '.[] | select(.bucket=="fail" or .bucket=="cancel")' > /dev/null 2>&1; then
    echo "fail"
    return 0
  fi
  if echo "$checks_json" | jq -e '.[] | select(.bucket=="pending")' > /dev/null 2>&1; then
    echo "pending"
    return 0
  fi
  for name in "${REQUIRED_PR_CHECKS[@]}"; do
    rows="$(echo "$checks_json" | jq --arg n "$name" '[.[] | select(.name==$n)]')"
    if ! echo "$rows" | jq -e '.[] | select(.bucket=="pass")' > /dev/null 2>&1; then
      echo "fail"
      return 0
    fi
  done
  echo "pass"
}


# risk_class_hits_for_paths <newline-separated-paths>
#
# classifyWithKind() (risk-class.mjs), given an explicit path list instead
# of a git range -- risk-class.mjs's own CLI entrypoint always re-derives
# the path list itself via `git diff --name-only <range>` in cwd, which
# needs a real local checkout with that range available. The unattended
# merge sweeper has neither: it only ever has the file list GitHub itself
# already returned (`gh pr view --json files`). Same rule list, same
# classification, one source of truth (risk-class.mjs) -- just fed from
# whichever path source the caller actually has. lib_dir (not SCRIPT_DIR,
# a caller-only variable this file must not depend on -- see
# advisor_footprint_risky() above) is this file's OWN directory; risk-
# class.mjs always lives right next to lib.sh, by construction.
risk_class_hits_for_paths() {
  local paths="$1" lib_dir
  lib_dir="$(cd "$(dirname "$_AGENT_LIB_DIR/lib.sh")" && pwd)"
  RISK_CLASS_MODULE="$lib_dir/risk-class.mjs" node --input-type=module -e '
    const { classifyWithKind } = await import(process.env.RISK_CLASS_MODULE);
    const fs = await import("node:fs");
    const paths = fs.readFileSync(0, "utf8").split("\n").filter(Boolean);
    console.log(JSON.stringify(classifyWithKind(paths)));
  ' <<< "$paths"
}


# ci_run_is_retryable_infra_failure <run_id> [issue] [pr] [allow-flake-retry]
#
# Exit 0 for a known open flake or known transient transport failure, 1 for a
# real failure, and 2 when GitHub cannot classify it. Checkout failures are
# visible in job steps. Container image pulls fail before steps exist, so
# inspect failed logs for the observed Docker Hub DNS/connect timeout signature
# instead of treating every pre-step failure as retryable. Both the live CI
# poll and unattended sweeper share this classifier.
ci_flake_state_lock() {
  mkdir -p "$STATE_DIR/locks" || return 1
  exec {CI_FLAKE_LOCK_FD}>"$STATE_DIR/locks/ci-flake-signatures.lock" || return 1
  flock "$CI_FLAKE_LOCK_FD"
}


ci_flake_state_unlock() {
  [[ "${CI_FLAKE_LOCK_FD:-}" =~ ^[0-9]+$ ]] || return 0
  flock -u "$CI_FLAKE_LOCK_FD"
  exec {CI_FLAKE_LOCK_FD}>&-
  unset CI_FLAKE_LOCK_FD
}


ci_flake_state_ensure_unlocked() {
  CI_FLAKE_STATE_FILE="$STATE_DIR/ci-flake-signatures.json"
  mkdir -p "$STATE_DIR" || return 1
  if [[ -e "$CI_FLAKE_STATE_FILE" ]]; then
    jq -e '.version == 1 and (.signatures | type == "array") and (.occurrences | type == "array")' \
      "$CI_FLAKE_STATE_FILE" >/dev/null 2>&1
    return $?
  fi
  # One-time seed; active lookups use this state file. The pack's state/ci-known-flakes.json (a JSON array) is the seed when the
  # deployment ships one; otherwise the old model-policy list, which the generic default leaves empty.
  local seed tmp pack_flakes
  if pack_flakes="$(pack_file state/ci-known-flakes.json)"; then
    seed="$(jq -c . "$pack_flakes")" || return 1
  else
    seed="$(jq -c '.hand_loop_breaker.known_flakes // []' "$MODEL_POLICY_DEFAULT")" || return 1
  fi
  tmp="$(mktemp "$CI_FLAKE_STATE_FILE.XXXXXX")" || return 1
  if ! jq -n --argjson signatures "$seed" '{version:1,signatures:$signatures,occurrences:[]}' > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" && mv -f -- "$tmp" "$CI_FLAKE_STATE_FILE"
}


ci_flake_state_write_unlocked() {
  local state="$1" tmp
  jq -e '.version == 1 and (.signatures | type == "array") and (.occurrences | type == "array")' \
    <<< "$state" >/dev/null 2>&1 || return 1
  tmp="$(mktemp "$CI_FLAKE_STATE_FILE.XXXXXX")" || return 1
  printf '%s\n' "$state" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" && mv -f -- "$tmp" "$CI_FLAKE_STATE_FILE"
}


ci_flake_log_has_failure_marker() {
  local log
  log="$(sed -E 's/\x1B\[[0-9;?]*[[:alpha:]]//g' <<< "$1")"
  grep -Eiq '(^|[[:space:]])FAIL([[:space:]]|$)|not ok[[:space:]]+[0-9]+[[:space:]]+-|^[[:space:]]*FAILED([[:space:]]|$)|[1-9][0-9,]*[[:space:]]+failed([[:space:](]|$)|failed[[:space:]]*\([1-9][0-9,]*\)' <<< "$log"
}


ci_flake_log_passed_tests() {
  grep -Eiq '(Test Files|Tests?)[[:space:]]+[0-9][0-9,]*[[:space:]]+passed([[:space:](]|$)' <<< "$1"
}


ci_flake_log_unhandled_error() {
  grep -Eiq '[1-9][0-9,]*[[:space:]]+unhandled[[:space:]]+errors?' <<< "$1"
}


ci_flake_error_signature() {
  sed -E 's/\x1B\[[0-9;?]*[[:alpha:]]//g' <<< "$1" | awk '
    function clean(s) {
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
      gsub(/[[:space:]]+/, " ", s)
      return substr(s, 1, 240)
    }
    {
      line=$0
      if (match(line, /[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][[:space:]]+[^[:space:]].*/)) {
        print clean(substr(line, RSTART, RLENGTH)); exit
      }
      if (match(line, /(Unhandled Rejection|[[:alpha:]_]*Error):[[:space:]].*/)) {
        value=substr(line, RSTART, RLENGTH)
        sub(/^(Unhandled Rejection|[[:alpha:]_]*Error):[[:space:]]*/, "", value)
        print clean(value); exit
      }
    }
  '
}


ci_flake_record_matches_log() {
  local log="$1" record="$2" failed_test_id="${3:-}"
  local signature requires_passed test_name bound bound_seconds
  signature="$(jq -r '.signature // empty' <<< "$record")"
  requires_passed="$(jq -r '.requires_passed_tests // false' <<< "$record")"
  test_name="$(jq -r '.test // empty' <<< "$record")"
  bound="$(jq -r '.bound_ms // empty' <<< "$record")"
  if [[ -n "$signature" ]] && grep -Fq -- "$signature" <<< "$log"; then
    if [[ "$requires_passed" == true ]]; then
      ci_flake_log_passed_tests "$log" && ! ci_flake_log_has_failure_marker "$log" || return 1
    fi
    return 0
  fi
  [[ -n "$test_name" ]] && grep -Fq -- "$test_name" <<< "$log" || return 1
  [[ -z "$failed_test_id" || "$failed_test_id" == *"$test_name"* ]] || return 1
  if [[ -n "$bound" ]]; then
    [[ "$bound" =~ ^[1-9][0-9]*$ ]] || return 1
    bound_seconds=$((bound / 1000))
    grep -Eiq "$bound[[:space:]]?ms|${bound_seconds}[[:space:]]?s(ec(ond)?s?)?" <<< "$log" || return 1
  fi
}


# Return 0 + CI_FLAKE_MATCH_RECORD for open issue, 1 for no record,
# 2 for unreadable GitHub state, 3 when only closed matching issues exist.
ci_flake_find_open_match_unlocked() {
  local log="$1" failed_test_id="${2:-}" gh_cmd="${3:-gh}" record issue state_json state closed_match=0
  CI_FLAKE_MATCH_RECORD=""
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    ci_flake_record_matches_log "$log" "$record" "$failed_test_id" || continue
    issue="$(jq -r '.issue // empty' <<< "$record")"
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 2
    state_json="$("$gh_cmd" issue view "$issue" --repo "$REPO" --json state 2>/dev/null)" || return 2
    state="$(jq -r '.state // "" | ascii_upcase' <<< "$state_json" 2>/dev/null)" || return 2
    case "$state" in
      OPEN) CI_FLAKE_MATCH_RECORD="$record"; return 0 ;;
      CLOSED) closed_match=1 ;;
      *) return 2 ;;
    esac
  done < <(jq -c '.signatures[]?' "$CI_FLAKE_STATE_FILE")
  (( closed_match == 1 )) && return 3
  return 1
}


ci_flake_add_match() {
  local matches="$1" record="$2" job_name="$3" issue
  issue="$(jq -r '.issue' <<< "$record")" || return 1
  jq -cn --argjson matches "$matches" --argjson record "$record" --arg job "$job_name" --arg issue "$issue" \
    'if any($matches[]; (.issue|tostring) == $issue) then $matches else $matches + [$record + {job_name:$job}] end'
}


ci_flake_report_new_signature_unlocked() {
  local signature="$1" run_id="$2" pr_number="$3" job_name="$4" log="$5"
  local hash title marker issues issue created state_json issue_state excerpt body state created_url first_run issue_json
  hash="$(printf '%s' "$signature" | sha256sum | awk '{print substr($1,1,12)}')" || return 2
  title="CI 间歇失败：测试计数全通过后出现未处理错误 [$hash]"
  marker="<!-- ci-flake-signature $hash -->"
  issues="$(gh issue list --repo "$REPO" --state all --limit 1000 --search "$hash" --json number,title 2>/dev/null)" || return 2
  issue="$(jq -r --arg title "$title" '[.[] | select(.title==$title)][0].number // empty' <<< "$issues")" || return 2
  created=0; first_run=""
  if [[ -z "$issue" ]]; then
    excerpt="$(sed -E 's/\x1B\[[0-9;?]*[[:alpha:]]//g' <<< "$log" | awk '/Test Files|Tests? [0-9]+|unhandled error|57P01|Error:/ { print; n++; if (n==8) exit }')"
    body="CI job 在所有测试通过后因 Vitest 未处理错误退出失败。

观察：run ${run_id}，PR #${pr_number}，job ${job_name}，$(date -u +%Y-%m-%dT%H:%M:%SZ)。
签名：$signature

证据：
$excerpt

验收：定位并修复未处理错误根因；添加回归证据，区分真实测试失败与测试结束后的进程错误。

$marker
<!-- vecta-agent-comment -->"
    if [ "$(roadmap_switch_value)" = true ]; then
      created_url="$(guarded_write gh issue create --repo "$REPO" --title "$title" --label pipeline-system --body "$body")" || return 2
    else
      created_url="$(guarded_write gh issue create --repo "$REPO" --title "$title" --label pipeline-system --label ready-for-agent --body "$body")" || return 2
    fi
    if [[ "$created_url" =~ /issues/([1-9][0-9]*)$ ]]; then issue="${BASH_REMATCH[1]}"; else return 2; fi
    if [ "$(roadmap_switch_value)" = true ]; then
      issue_json="$(printf '%s' "$body" | jq -Rsc --argjson number "$issue" --arg title "$title" \
        '{number:$number,title:$title,body:.,state:"OPEN",labels:[{name:"pipeline-system"}]}')" || return 2
      issue_transition "$issue" needs-triage ci-flake-created . 0 "$issue_json" || return 2
    fi
    created=1; first_run="$run_id"
  fi
  state_json="$(gh issue view "$issue" --repo "$REPO" --json state 2>/dev/null)" || return 2
  issue_state="$(jq -r '.state // "" | ascii_upcase' <<< "$state_json")" || return 2
  [[ "$issue_state" == OPEN || "$issue_state" == CLOSED ]] || return 2
  state="$(jq --arg signature "$signature" --argjson issue "$issue" --arg run "$first_run" \
    'if any(.signatures[]?; .issue==$issue and .signature==$signature) then .
     else .signatures += [{issue:$issue,signature:$signature,requires_passed_tests:true,first_run:$run}] end' \
    "$CI_FLAKE_STATE_FILE")" || return 2
  ci_flake_state_write_unlocked "$state" || return 2
  CI_FLAKE_MATCH_RECORD="$(jq -cn --arg signature "$signature" --argjson issue "$issue" --arg run "$first_run" \
    '{issue:$issue,signature:$signature,requires_passed_tests:true,first_run:$run}')" || return 2
  CI_FLAKE_NEW_ISSUE_CREATED="$created"
  [[ "$issue_state" == OPEN ]] && return 0
  return 3
}


ci_flake_record_occurrences_unlocked() {
  local matches="$1" run_id="$2" pr_number="$3" record issue existing marker at jobs body state
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    issue="$(jq -r '.issue' <<< "$record")" || return 1
    existing="$(jq -r --argjson issue "$issue" --arg run "$run_id" --arg pr "$pr_number" \
      'any(.occurrences[]?; .issue==$issue and .run_id==$run and .pr==$pr)' "$CI_FLAKE_STATE_FILE")" || return 1
    [[ "$existing" == true ]] && continue
    marker="<!-- ci-flake-occurrence issue=$issue run=$run_id pr=$pr_number -->"
    at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jobs="$(jq -r --argjson issue "$issue" '[.[] | select(.issue==$issue) | .job_name] | unique | join(", ")' <<< "$matches")" || return 1
    body="Known CI flake occurrence: run $run_id, PR #$pr_number, job(s) $jobs, $at.
Run: https://github.com/$REPO/actions/runs/$run_id
$marker"
    guarded_write gh issue comment "$issue" --repo "$REPO" --body "$body" || return 1
    state="$(jq --argjson issue "$issue" --arg run "$run_id" --arg pr "$pr_number" --arg at "$at" \
      '.occurrences += [{issue:$issue,run_id:$run,pr:$pr,at:$at}]' "$CI_FLAKE_STATE_FILE")" || return 1
    ci_flake_state_write_unlocked "$state" || return 1
  done < <(jq -c 'unique_by(.issue)[]' <<< "$matches")
}


# Retry only registered, open signatures. New all-passed/unhandled-error
# signatures create one issue and leave their first occurrence blocking.
ci_flake_retry_failed_run() {
  local run_id="$1" issue="$2" pr_number="$3" allow_retry="$4" jobs="$5"
  local failed_jobs job_line job_id job_name log failed_ids failed_test_id match_status record first_run signature
  local status=1 matches='[]' attempt
  CI_FLAKE_CLASSIFICATION=real; CI_FLAKE_REASON=""
  # ponytail: serialize GitHub lookups under one lock; use per-signature locks if contention matters.
  ci_flake_state_lock || return 2
  if ! ci_flake_state_ensure_unlocked; then status=2
  else
    failed_jobs="$(jq -r '[.[]? | select(.conclusion=="failure")] | .[] | [.databaseId,.name] | @tsv' <<< "$jobs")" || status=2
    if [[ -n "$failed_jobs" ]]; then
      status=0
      while IFS=$'\t' read -r job_id job_name; do
        [[ "$job_id" =~ ^[1-9][0-9]*$ && -n "$job_name" ]] || { status=2; break; }
        log="$(gh run view "$run_id" --job "$job_id" --log-failed --repo "$REPO" 2>/dev/null)" || { status=2; break; }
        failed_ids="$(ci_failed_test_ids "$log")"
        if ci_flake_log_has_failure_marker "$log"; then
          [[ -n "$failed_ids" ]] || { status=1; break; }
          while IFS=$'\t' read -r _ failed_test_id; do
            [[ -n "$failed_test_id" ]] || continue
            match_status=0; ci_flake_find_open_match_unlocked "$log" "$failed_test_id" || match_status=$?
            case "$match_status" in
              0)
                first_run="$(jq -r '.first_run // empty' <<< "$CI_FLAKE_MATCH_RECORD")"
                [[ "$first_run" != "$run_id" ]] || { status=3; break; }
                matches="$(ci_flake_add_match "$matches" "$CI_FLAKE_MATCH_RECORD" "$job_name")" || { status=2; break; }
                ;;
              1|3) status=1; break ;;
              *) status=2; break ;;
            esac
          done <<< "$failed_ids"
          [[ "$status" == 0 ]] || break
        else
          match_status=0; ci_flake_find_open_match_unlocked "$log" || match_status=$?
          case "$match_status" in
            0)
              first_run="$(jq -r '.first_run // empty' <<< "$CI_FLAKE_MATCH_RECORD")"
              if [[ "$first_run" == "$run_id" ]]; then status=3; break; fi
              matches="$(ci_flake_add_match "$matches" "$CI_FLAKE_MATCH_RECORD" "$job_name")" || { status=2; break; }
              ;;
            1)
              if ci_flake_log_passed_tests "$log" && ci_flake_log_unhandled_error "$log"; then
                signature="$(ci_flake_error_signature "$log")"
                [[ -n "$signature" ]] || { status=1; break; }
                match_status=0; ci_flake_report_new_signature_unlocked "$signature" "$run_id" "$pr_number" "$job_name" "$log" || match_status=$?
                case "$match_status" in
                  0)
                    first_run="$(jq -r '.first_run // empty' <<< "$CI_FLAKE_MATCH_RECORD")"
                    if [[ "$first_run" == "$run_id" || "$CI_FLAKE_NEW_ISSUE_CREATED" == 1 ]]; then status=3; break; fi
                    matches="$(ci_flake_add_match "$matches" "$CI_FLAKE_MATCH_RECORD" "$job_name")" || { status=2; break; }
                    ;;
                  3) status=1; break ;;
                  *) status=2; break ;;
                esac
              else status=1; break
              fi
              ;;
            3) status=1; break ;;
            *) status=2; break ;;
          esac
        fi
      done <<< "$failed_jobs"
    fi
  fi
  if [[ "$status" == 0 ]]; then
    if [[ ! "$issue" =~ ^[1-9][0-9]*$ || ! "$pr_number" =~ ^[1-9][0-9]*$ ]]; then status=2
    else
      attempt="$(gh run view "$run_id" --repo "$REPO" --json attempt -q .attempt 2>/dev/null)" || attempt=""
      if [[ "$attempt" != 1 || "$allow_retry" != 1 ]]; then
        status=1; CI_FLAKE_CLASSIFICATION=exhausted; CI_FLAKE_REASON="known flake has no remaining run attempt"
      elif ! ci_flake_record_occurrences_unlocked "$matches" "$run_id" "$pr_number"; then status=2
      elif ! guarded_write gh run rerun "$run_id" --repo "$REPO" --failed; then status=2
      else
        CI_FLAKE_CLASSIFICATION=rerun; CI_FLAKE_REASON="known flake rerun once"; status=0
      fi
    fi
  elif [[ "$status" == 3 ]]; then
    CI_FLAKE_CLASSIFICATION=new-signature; CI_FLAKE_REASON="new all-passed/unhandled-error signature filed"
  elif [[ "$status" == 2 ]]; then CI_FLAKE_CLASSIFICATION=unknown
  fi
  ci_flake_state_unlock || true
  return "$status"
}


ci_flake_log_matches_open_issue() {
  local log="$1" gh_cmd="${2:-gh}" match_status=1 failed_ids failed_test_id
  ci_flake_state_lock || return 2
  if ! ci_flake_state_ensure_unlocked; then match_status=2
  elif ci_flake_log_has_failure_marker "$log"; then
    failed_ids="$(ci_failed_test_ids "$log")"
    if [[ -n "$failed_ids" ]]; then
      match_status=0
      while IFS=$'\t' read -r _ failed_test_id; do
        [[ -n "$failed_test_id" ]] || continue
        ci_flake_find_open_match_unlocked "$log" "$failed_test_id" "$gh_cmd" || match_status=$?
        [[ "$match_status" == 0 ]] || break
      done <<< "$failed_ids"
    fi
  else
    match_status=0
    ci_flake_find_open_match_unlocked "$log" "" "$gh_cmd" || match_status=$?
  fi
  ci_flake_state_unlock || true
  return "$match_status"
}


ci_run_is_retryable_infra_failure() {
  local run_id="$1" issue="${2:-0}" pr_number="${3:-0}" allow_flake_retry="${4:-0}" jobs checkout_failed capacity_gate_failed failed_step_count failed_job_without_steps logs capacity_f capacity_since seen now lock_fd flake_status=0
  CI_RETRYABLE_INFRA_REASON=""
  CI_RETRYABLE_INFRA_KIND=""
  [ -n "$run_id" ] || return 1
  jobs="$(gh run view "$run_id" --repo "$REPO" --json jobs -q '.jobs' 2>/dev/null)" || return 2
  checkout_failed="$(jq -r '[.[]? | .steps[]? | select((.name | startswith("Run actions/checkout")) and .conclusion=="failure")] | length > 0' <<< "$jobs")" || return 2
  if [ "$checkout_failed" = true ]; then
    CI_RETRYABLE_INFRA_REASON="GitHub Actions checkout step failed before project checks"
    CI_RETRYABLE_INFRA_KIND=transport
    record_env_fault env:ci-checkout infrastructure "$issue" "$CI_RETRYABLE_INFRA_REASON" "" "" 0 || true
    return 0
  fi
  capacity_gate_failed="$(jq -r '[.[]? | .steps[]? | select(.name=="Ensure CI runner has capacity before dependency install" and .conclusion=="failure")] | length > 0' <<< "$jobs")" || return 2
  if [ "$capacity_gate_failed" = true ]; then
    CI_RETRYABLE_INFRA_REASON="CI runner capacity gate failed: Ensure CI runner has capacity before dependency install"
    CI_RETRYABLE_INFRA_KIND=capacity
    mkdir -p "$AGENT_HOME/locks"
    exec {lock_fd}>"$AGENT_HOME/locks/ci-runner-capacity.lock"
    flock "$lock_fd"
    capacity_f="$(quarantine_file implement)"
    capacity_since="$(jq -r 'select(.signature == "env:ci-runner-capacity") | .since // 0' "$capacity_f" 2>/dev/null || echo 0)"
    case "$capacity_since" in ''|*[!0-9]*) capacity_since=0 ;; esac
    seen=0
    if [ "$capacity_since" -gt 0 ]; then
      seen="$(awk -F '\t' -v since="$capacity_since" -v issue="$issue" \
        '$1 >= since && $3 == issue && $4 == "env:ci-runner-capacity" { found=1 } END { print found+0 }' \
        "$ENV_FAULT_DIR/$(env_fault_key env:ci-runner-capacity).log" 2>/dev/null || echo 0)"
    fi
    if [ "$seen" -eq 0 ]; then
      now="$(date +%s)"
      record_env_fault env:ci-runner-capacity implement "$issue" "$CI_RETRYABLE_INFRA_REASON" "" "$now" || true
      quarantine_open implement env:ci-runner-capacity "$CI_RETRYABLE_INFRA_REASON" 1 "$now"
    fi
    unlock_fd "$lock_fd"
    return 0
  fi
  ci_flake_retry_failed_run "$run_id" "$issue" "$pr_number" "$allow_flake_retry" "$jobs" || flake_status=$?
  case "$flake_status" in
    0) CI_RETRYABLE_INFRA_REASON="$CI_FLAKE_REASON"; CI_RETRYABLE_INFRA_KIND=flake; return 0 ;;
    3) return 1 ;;
  esac
  failed_step_count="$(jq -r '[.[]? | .steps[]? | select(.conclusion=="failure")] | length' <<< "$jobs")" || return 2
  [ "$failed_step_count" -gt 0 ] && return 1
  failed_job_without_steps="$(jq -r '[.[]? | select(.conclusion=="failure" and ((.steps // []) | length == 0))] | length' <<< "$jobs")" || return 2
  [ "$failed_job_without_steps" -gt 0 ] || return 2
  logs="$(gh run view "$run_id" --repo "$REPO" --log-failed 2>/dev/null)" || return 2
  if grep -Fq 'Docker pull failed with exit code' <<< "$logs" \
    && grep -Eq 'failed to resolve reference "docker\.io/[^\"]+"' <<< "$logs" \
    && grep -Eq 'dial tcp .*: i/o timeout' <<< "$logs"; then
    CI_RETRYABLE_INFRA_REASON="Docker Hub DNS/connect timeout before job steps"
    CI_RETRYABLE_INFRA_KIND=transport
    record_env_fault env:docker-hub-dns infrastructure "$issue" "$CI_RETRYABLE_INFRA_REASON" "" "" 0 || true
    return 0
  fi
  return 2
}


# ci_failed_test_ids <failed-log> -> stable identifiers for supported test runners.
ci_failed_test_ids() {
  awk '
    function clean(value) {
      gsub(/\r/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/[[:space:]]+/, " ", value)
      return value
    }
    BEGIN { esc = sprintf("%c", 27) }
    {
      line = $0
      # GitHub job logs keep the runner colours; vitest wraps FAIL in them.
      gsub(esc "\\[[0-9;]*[A-Za-z]", "", line)
      if (match(line, /FAIL[[:space:]]+[^[:space:]]+[[:space:]]*>[[:space:]]+[^[:space:]].*/)) {
        id = substr(line, RSTART, RLENGTH)
        sub(/^.*FAIL[[:space:]]+/, "", id)
        print "vitest\t" clean(id)
      } else if (match(line, /not ok [0-9]+ - .+/)) {
        id = substr(line, RSTART, RLENGTH)
        sub(/^.*not ok [0-9]+ - /, "", id)
        print "node\t" clean(id)
      } else if (match(line, /FAILED[[:space:]]+.+/)) {
        id = substr(line, RSTART, RLENGTH)
        sub(/^.*FAILED[[:space:]]+/, "", id)
        sub(/[[:space:]]+-[[:space:]].*$/, "", id)
        print "pytest\t" clean(id)
      }
    }
  ' <<< "$1" | sort -u
}


# ci_failed_test_scope_from_log <failed-log> -> JSON paths for failing suites
# plus source files whose focused gate includes those suites. Empty scope
# makes main-red quarantine stay lane-wide.
ci_failed_test_scope_from_log() {
  local scope
  scope="$(printf '%s' "$1" | node --input-type=module -e '
    import fs from "node:fs";
    const repo = process.argv[1];
    const log = fs.readFileSync(0, "utf8").replace(/\u001b\[[0-9;]*[A-Za-z]/g, "");
    const tests = new Set();
    const pathPattern = /((?:\.github\/workflows|packages|apps|scripts|tests)\/[A-Za-z0-9._/-]+\.(?:(?:test|spec)\.(?:ts|tsx|js|jsx|mjs|cjs|sh|py)|(?:test_[A-Za-z0-9._-]+|[A-Za-z0-9._-]+_test)\.py))(?:[:][0-9]+(?::[0-9]+)?)?/;
    let failedContext = false;
    for (const line of log.split(/\r?\n/)) {
      if (/\bFAIL(?:ED)?\b/.test(line) || /\bnot ok [0-9]+\b/.test(line)) failedContext = true;
      const relevant = /\bFAIL(?:ED)?\b/.test(line) || /\bnot ok [0-9]+\b/.test(line)
        || (failedContext && /location:/.test(line));
      if (relevant) {
        const match = line.match(pathPattern);
        if (match) tests.add(match[1].replace(/^\.\//, ""));
      }
      if (/^\s*(?:ok|PASS|✓)\b/.test(line)) failedContext = false;
    }
    let sources = [];
    const mappedTests = new Set();
    try {
      const { RELATED_TESTS } = await import(`file://${repo}/engine/focused-test-paths.mjs`);
      for (const [source, suites] of RELATED_TESTS) {
        for (const suite of suites) {
          if (!tests.has(suite)) continue;
          sources.push(source);
          mappedTests.add(suite);
        }
      }
    } catch {}
    const packageRoots = [...tests].flatMap((test) =>
      /^(packages|apps)\/[^/]+\//.test(test) ? [test.split("/").slice(0, 2).join("/")] : []);
    if ([...tests].some((test) => !mappedTests.has(test) && !/^(packages|apps)\/[^/]+\//.test(test))) {
      process.stdout.write("[]");
    } else {
      process.stdout.write(JSON.stringify([...new Set([...tests, ...packageRoots, ...sources])].sort()));
    }
  ' "$REPO_DIR" 2>/dev/null)" || scope='[]'
  jq -ce 'if type == "array" and all(.[]; type == "string" and length > 0) then unique else [] end' <<< "$scope" 2>/dev/null || echo '[]'
}


# Query completed runs so queued work cannot bury the last verdict. One page
# bounds the read; no usable verdict in that page remains unknown.
ci_main_completed_push_runs() {
  local cache_window_start response workflow="${1:-ci.yml}" read_timeout="${2:-}"
  cache_window_start="$(ci_main_actions_cache_window_start)" || return 1
  response="$(
    # HEALTH gets one request, no retry, and an independent deadline.
    if [ -n "$read_timeout" ]; then
      main_gh() { gh_timeout -k 1 "$read_timeout" "$@"; }
    fi
    main_gh api -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    "repos/$REPO/actions/workflows/$workflow/runs?branch=main&status=completed&per_page=50&page=1&created=%3E%3D${cache_window_start}" \
    2>/dev/null)" || return 1
  jq -e 'type == "object" and (.workflow_runs | type == "array")' \
    <<< "$response" >/dev/null 2>&1 || return 1
  jq --arg workflow "$workflow" '
    if type == "array" then .[] else . end
    | .workflow_runs |= map(select(.event == "push" or .event == "workflow_dispatch")
      | select($workflow != "pipeline-suites.yml"
        or (((.display_title // "") | startswith("Pipeline suites post-land probe ")) | not))
      | if $workflow == "pipeline-suites.yml" and ((.display_title // "") | startswith("Pipeline suites post-land ")) then
          .head_sha = (.display_title | split(" ")[3])
        elif $workflow == "pipeline-suites.yml" and ((.display_title // "") | startswith("Pipeline suites full post-land ")) then
          .head_sha = (.display_title | split(" ")[4])
        else . end)' <<< "$response"
}


# Shared verdict selector for merge admission, main-red recovery and revalidation.
# Optional cutoff preserves the verdict that existed when a PR run started.
ci_main_latest_completed_push_run() {
  local runs="$1" before="${2:-}"
  jq -ce --arg before "$before" '
    [(if type == "array" then .[] else . end) | .workflow_runs[]?
      | select(.status == "completed" and (.conclusion | type == "string" and length > 0)
        and .conclusion != "cancelled" and .conclusion != "skipped"
        and ($before == "" or .created_at <= $before))]
    | sort_by([.created_at, .id, .run_attempt]) | last // empty
    | . + {verdict_age_seconds: (try ((now - (.created_at | fromdateiso8601)) | floor) catch null)}
    ' <<< "$runs" 2>/dev/null
}


# Return 0 only for a known success, 1 for a known non-success, 2 when GitHub
# cannot establish the newest verdict.
ci_main_latest_completed_push_verdict() {
  local runs="${1:-}" run conclusion
  [ -n "$runs" ] || runs="$(ci_main_completed_push_runs)" || return 2
  run="$(ci_main_latest_completed_push_run "$runs")" || return 2
  conclusion="$(jq -r '.conclusion' <<< "$run")" || return 2
  [ "$conclusion" = success ] && return 0
  return 1
}
