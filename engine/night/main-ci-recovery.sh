#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="${ZF_REPO_DIR:-$(cd -- "$SCRIPT_DIR/../.." && pwd -P)}"
H="${AGENT_HOME:-${ZF_HOME:-${HOME:?HOME is not set}/.zenoforge}}"
NIGHT="${ZF_NIGHT_DIR:-$H/night}"
WORKTREE_ROOT="${ZF_WORKTREE_ROOT:-$HOME/wt}"
export AGENT_HOME="$H" ZF_REPO="${ZF_REPO:-${ZF_GH_REPO:-}}"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/hand-agent-watchdog.sh"
REPO="$ZF_REPO"

main_ci_log_test_names() {
  sed -E 's/\x1B\[[0-9;?]*[[:alpha:]]//g' |
    awk '
      function emit(line) {
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line != "") print line
      }
      /FAIL[[:space:]]+/ {
        line = $0
        sub(/^.*FAIL[[:space:]]+/, "", line)
        emit(line)
      }
      /not ok [0-9]+ - / {
        line = $0
        sub(/^.*not ok [0-9]+ - /, "", line)
        emit(line)
      }
      /^[[:space:]]*FAILED[[:space:]]+/ {
        line = $0
        sub(/^[[:space:]]*FAILED[[:space:]]+/, "", line)
        emit(line)
      }
      /Test Files[[:space:]]+[1-9][0-9]*[[:space:]]+failed/ {
        line = $0
        if (match(line, /Test Files[[:space:]]+[1-9][0-9]*[[:space:]]+failed/))
          emit(substr(line, RSTART, RLENGTH))
      }
    ' | sort -u
}

main_ci_log_test_packages() {
  sed -E 's/\x1B\[[0-9;?]*[[:alpha:]]//g' |
    awk '
      /package[[:space:]]+[^[:space:]]+[[:space:]]+test failed/ {
        line = $0
        sub(/^.*package[[:space:]]+/, "", line)
        sub(/[[:space:]]+test failed.*$/, "", line)
        print line
      }
    ' | sort -u
}

main_ci_log_environmental_reason() {
  awk '
    {
      line = tolower($0)
      if (line ~ /checkout/) checkout = 1
      if (line ~ /egress|tls|proxy|network|connection reset|timed out|github.*timeout/) egress = 1
      if (line ~ /runner|capacity|enospc|no space left|disk full|out of memory/) capacity = 1
    }
    END {
      if (checkout) printf "checkout"
      if (egress) printf "%segress", (checkout ? "+" : "")
      if (capacity) printf "%srunner-capacity", (checkout || egress ? "+" : "")
      if (checkout || egress || capacity) printf "-failure\n"
    }
  '
}

main_ci_record_ledger_row() {
  local at="$1" workflow="$2" run_id="$3" job="$4" test_name="$5" ledger="$H/logs/ci-flakes.log"
  mkdir -p "$(dirname -- "$ledger")"
  if ! awk -F '\t' -v workflow="$workflow" -v run="$run_id" -v job="$job" -v test="$test_name" \
    '$2==workflow && $3==run && $4==job && $5==test {found=1} END {exit !found}' "$ledger" 2>/dev/null; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$at" "$workflow" "$run_id" "$job" "$test_name" >> "$ledger"
  fi
}

main_ci_recent_run_count() {
  local test_name="$1" since="$2" ledger="$H/logs/ci-flakes.log"
  awk -F '\t' -v since="$since" -v test="$test_name" \
    '$1 >= since && $5 == test {seen[$2 FS $3]=1} END {for (run in seen) count++; print count+0}' \
    "$ledger" 2>/dev/null || printf '0\n'
}

main_ci_test_evidence() {
  local test_name="$1" since="$2" ledger="$H/logs/ci-flakes.log"
  awk -F '\t' -v since="$since" -v test="$test_name" \
    '$1 >= since && $5 == test {printf "- %s | %s | run %s | job %s\n", $1, $2, $3, $4}' \
    "$ledger" 2>/dev/null
}

main_ci_issue_for_test() {
  local test_name="$1" run_id="$2" job_id="$3" since="$4" title marker encoded count evidence issues issue body existing_body comments issue_url issue_json body_file
  [[ "$test_name" != unknown ]] || return 0
  count="$(main_ci_recent_run_count "$test_name" "$since")"
  (( count >= 2 )) || return 0

  title="CI 间歇失败：$test_name"
  encoded="$(printf '%s' "$test_name" | base64 | tr -d '\n')"
  marker="<!-- main-ci-flake run=$run_id job=$job_id test=$encoded -->"
  evidence="$(main_ci_test_evidence "$test_name" "$since")"
  issues="$(gh issue list --repo "$REPO" --state all --limit 1000 \
    --search "in:title \"$title\"" --json number,title)" || return 1
  issue="$(jq -r --arg title "$title" '[.[] | select(.title==$title)][0].number // empty' <<< "$issues")"
  body="$BOT_DISCLAIMER
$marker

同一 main CI 测试在最近 7 天内至少两次失败后重跑通过，请定位并修复根因。

测试：$test_name

证据：
$evidence"
  if [ -z "$issue" ]; then
    if [[ "$(roadmap_switch_value)" == true ]]; then
      issue_url="$(guarded_write gh issue create --repo "$REPO" --title "$title" --body "$body")" || return 1
      issue="${issue_url##*/}"
      [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
      # $body contains unbounded test evidence; keep it out of jq argv.
      body_file="$(jq_arg_file "$body")" || return 1
      if ! issue_json="$(jq -cn --argjson number "$issue" --arg title "$title" --rawfile body "$body_file" \
        '{number:$number,title:$title,body:$body,state:"OPEN",labels:[]}')"; then
        rm -f -- "$body_file"
        return 1
      fi
      rm -f -- "$body_file"
      issue_transition "$issue" ready-for-agent main-ci-recovery-created . 0 "$issue_json"
      return $?
    fi
    guarded_write gh issue create --repo "$REPO" --title "$title" --label ready-for-agent --body "$body"
    return $?
  fi

  existing_body="$(gh issue view "$issue" --repo "$REPO" --json body --jq '.body // ""')" || return 1
  if grep -Fq "$marker" <<< "$existing_body"; then return 0; fi
  comments="$(gh api "repos/$REPO/issues/$issue/comments?per_page=100" --paginate --jq '.[].body')" || return 1
  if grep -Fq "$marker" <<< "$comments"; then return 0; fi
  guarded_write gh issue comment "$issue" --repo "$REPO" --body "$body"
}

main_ci_record_successful_rerun() {
  local workflow="$1" run_id="$2" head_sha="$3" jobs_json at since workflow_label job_line job_id job_name job_log test_names test_name
  case "$workflow" in
    pipeline-suites) workflow_label='Pipeline suites' ;;
    *) return 0 ;;
  esac
  jobs_json="$(gh run view "$run_id" --attempt 1 --json jobs --repo "$REPO")" || return 1
  jq -e '.jobs | type == "array"' <<< "$jobs_json" >/dev/null || return 1
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  since="$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  while IFS= read -r job_line; do
    [ -n "$job_line" ] || continue
    IFS=$'\t' read -r job_id job_name <<< "$job_line"
    job_log="$(gh run view "$run_id" --attempt 1 --job "$job_id" --log-failed --repo "$REPO" 2>/dev/null || true)"
    test_names="$(main_ci_log_test_names <<< "$job_log")"
    if [ -z "$test_names" ]; then test_names=unknown; fi
    while IFS= read -r test_name; do
      [ -n "$test_name" ] || continue
      main_ci_record_ledger_row "$at" "$workflow_label" "$run_id" "$job_name" "$test_name"
      main_ci_issue_for_test "$test_name" "$run_id" "$job_id" "$since" || \
        printf 'main-ci-recovery: could not report flake run=%s job=%s test=%s\n' "$run_id" "$job_name" "$test_name" >&2
    done <<< "$test_names"
  done < <(jq -r '.jobs[] | select(.conclusion=="failure") | [.databaseId,.name] | @tsv' <<< "$jobs_json")
}

main_ci_is_direct_pipeline_commit() {
  local commit="$1" subject="$2" parent_line
  shift 2
  local -a paths=("$@") parents=()
  [[ "$subject" == '[skip ci]'* && ${#paths[@]} -gt 0 ]] || return 1
  parent_line="$(git -C "$REPO_DIR" rev-list --parents -n 1 "$commit")" || return 1
  read -r -a parents <<< "$parent_line"
  ((${#parents[@]} == 2)) || return 1
  node --input-type=module - "$REPO_DIR/scripts/branch-delivery-policy.mjs" "$subject" "${paths[@]}" <<'NODE'
const { evaluateDirectMainDevelopmentSystemPush } = await import(process.argv[2]);
const subject = process.argv[3];
const paths = process.argv.slice(4);
const result = evaluateDirectMainDevelopmentSystemPush({
  sourceRef: 'ci-recovery', targetRef: 'main', changedPaths: paths, commitMessages: [subject],
});
process.exit(result.allowed ? 0 : 1);
NODE
}

main_ci_first_red_window() {
  local workflow="$1" run_id="$2" run_head="$3" allow_rerun_success="${4:-0}" runs timeline entry_id sha conclusion attempt page=1
  local green_sha="" first_red_sha="" first_red_run="" first_red_attempt="" target_found=0
  # ponytail: 10k-run history cap; raise only if inbox evidence shows older green anchors.
  while ((page <= 100)); do
    runs="$(gh api "repos/$REPO/actions/workflows/$workflow.yml/runs?branch=main&per_page=100&page=$page")" || return 1
    jq -e '.workflow_runs | type == "array"' <<< "$runs" >/dev/null || return 1
    timeline="$(jq -r '
      [.workflow_runs[]
        | select(.head_branch=="main" and (.event=="push" or .event=="workflow_dispatch"))
        | {id:(.id // .databaseId // 0), head_sha:(.head_sha // ""),
           conclusion:(.conclusion // ""), attempt:(.run_attempt // 1),
           created_at:(.created_at // "")}]
      | sort_by(.created_at, .id) | reverse[]
      | [.id, .head_sha, .conclusion, .attempt] | @tsv
    ' <<< "$runs")" || return 1
    [[ -n "$timeline" ]] || break
    while IFS=$'\t' read -r entry_id sha conclusion attempt; do
      [[ "$entry_id" =~ ^[0-9]+$ && "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
      if [[ "$target_found" == 0 ]]; then
        [[ "$entry_id" == "$run_id" ]] || continue
        [[ "$sha" == "$run_head" ]] || return 1
        if [[ "$conclusion" != failure ]]; then
          [[ "$workflow" == ci && "$allow_rerun_success" == 1 && "$attempt" =~ ^[2-9][0-9]*$ ]] || return 1
          local first_attempt_json first_attempt_conclusion
          first_attempt_json="$(gh run view "$run_id" --attempt 1 --json conclusion --repo "$REPO")" || return 1
          first_attempt_conclusion="$(jq -er '.conclusion' <<< "$first_attempt_json")" || return 1
          [[ "$first_attempt_conclusion" == failure ]] || return 1
          conclusion=failure
          attempt=1
        fi
        target_found=1
      fi
      git -C "$REPO_DIR" merge-base --is-ancestor "$sha" "$run_head" || continue
      case "$conclusion" in
        success)
          green_sha="$sha"
          break
          ;;
        failure)
          first_red_sha="$sha"
          first_red_run="$entry_id"
          first_red_attempt="$attempt"
          ;;
      esac
    done <<< "$timeline"
    [[ -n "$green_sha" ]] && break
    page=$((page + 1))
  done
  [[ "$target_found" == 1 && -n "$green_sha" && -n "$first_red_sha" ]] || return 1
  git -C "$REPO_DIR" merge-base --is-ancestor "$green_sha" "$first_red_sha" || return 1
  printf '%s\t%s\t%s\t%s\n' "$green_sha" "$first_red_run" "$first_red_sha" "$first_red_attempt"
}

main_ci_product_owner_state_file() {
  printf '%s/main-ci-product-owners.json\n' "$NIGHT"
}

main_ci_product_owner_state_read() {
  local file
  file="$(main_ci_product_owner_state_file)"
  if [[ ! -s "$file" ]]; then
    printf '{"version":1,"owners":{}}\n'
    return 0
  fi
  jq -ce 'if type=="object" and (.owners|type)=="object" then . else error("invalid main CI owner state") end' "$file"
}

main_ci_product_owner_state_put() {
  local key="$1" patch="$2" file state next temp lock_fd
  file="$(main_ci_product_owner_state_file)"
  mkdir -p "$NIGHT" || return 1
  exec {lock_fd}>"$file.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  state="$(main_ci_product_owner_state_read)" || { exec {lock_fd}>&-; return 1; }
  next="$(jq -cn --argjson state "$state" --arg key "$key" --argjson patch "$patch" \
    '$state | .owners[$key] = ((.owners[$key] // {}) + $patch)')" || { exec {lock_fd}>&-; return 1; }
  temp="$(mktemp "$NIGHT/.main-ci-product-owners.XXXXXX")" || { exec {lock_fd}>&-; return 1; }
  if ! printf '%s\n' "$next" > "$temp" || ! mv -- "$temp" "$file"; then
    exec {lock_fd}>&-
    return 1
  fi
  exec {lock_fd}>&-
}

main_ci_live_hand_owner() {
  local target="$1" kind="$2" row pid name model effort worktree brief report log attempt started_at role start_ticks owned_issues owned_nodes
  local roster="$NIGHT/agents.txt"
  [[ "$kind" == node || "$kind" == issue ]] || return 2
  [[ -r "$roster" ]] || return 1
  while IFS= read -r row || [[ -n "$row" ]]; do
    IFS=$'\x1f' read -r pid name model effort worktree brief report log attempt started_at role start_ticks owned_issues owned_nodes _ _ \
      <<< "${row//$'\t'/$'\x1f'}"
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$start_ticks" =~ ^[0-9]+$ ]] || continue
    hand_agent_pid_live "$pid" "$start_ticks" || continue
    if [[ "$kind" == node && " ${owned_nodes:-} " == *" $target "* ]] ||
      [[ "$kind" == issue && " ${owned_issues:-} " == *" $target "* ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < "$roster"
  return 1
}

main_ci_product_issue_class() {
  local package="$1" red_sha="$2" slug hash
  slug="${package#packages/}"
  slug="${slug//\//-}"
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || slug=unknown
  if ((${#slug} > 20)); then
    hash="$(printf '%s' "$package" | sha256sum | cut -c1-8)" || return 1
    slug="${slug:0:11}-$hash"
  fi
  printf 'ci-%s-%s\n' "$slug" "$red_sha"
}

MAIN_CI_FAILURE_CLASSIFICATION=environmental
MAIN_CI_FAILURE_REASON=""
MAIN_CI_FAILURE_JOB_ID=""
MAIN_CI_FAILURE_JOB_NAME=""
MAIN_CI_FAILURE_PACKAGES_JSON='[]'
MAIN_CI_FAILURE_TESTS_JSON='[]'

main_ci_product_read_failure() {
  local run_id="$1" attempt="$2" jobs_json job_line job_id job_name job_log packages tests
  MAIN_CI_FAILURE_CLASSIFICATION=environmental
  MAIN_CI_FAILURE_REASON=unclassified-no-named-tests
  MAIN_CI_FAILURE_JOB_ID=""
  MAIN_CI_FAILURE_JOB_NAME='Postsubmit validate'
  MAIN_CI_FAILURE_PACKAGES_JSON='[]'
  MAIN_CI_FAILURE_TESTS_JSON='[]'
  jobs_json="$(gh run view "$run_id" --attempt "$attempt" --json jobs --repo "$REPO")" || {
    MAIN_CI_FAILURE_REASON=failure-job-list-unavailable
    return 0
  }
  jq -e '.jobs | type=="array"' <<< "$jobs_json" >/dev/null || {
    MAIN_CI_FAILURE_REASON=failure-job-list-invalid
    return 0
  }
  job_line="$(jq -r '[.jobs[] | select(.name=="Postsubmit validate" and .conclusion=="failure")][0] | [.databaseId,.name] | @tsv' <<< "$jobs_json")" || return 1
  IFS=$'\t' read -r job_id job_name <<< "$job_line"
  [[ "$job_id" =~ ^[1-9][0-9]*$ ]] || {
    MAIN_CI_FAILURE_REASON=postsubmit-failure-job-not-found
    return 0
  }
  MAIN_CI_FAILURE_JOB_ID="$job_id"
  MAIN_CI_FAILURE_JOB_NAME="$job_name"
  job_log="$(gh run view "$run_id" --attempt "$attempt" --job "$job_id" --log-failed --repo "$REPO" 2>/dev/null)" || {
    MAIN_CI_FAILURE_REASON=failure-job-log-unavailable
    return 0
  }
  tests="$(main_ci_log_test_names <<< "$job_log")" || return 1
  packages="$(main_ci_log_test_packages <<< "$job_log")" || return 1
  if [[ -n "$packages" && -z "$tests" ]]; then
    tests='package test suite failed (case names unavailable)'
  fi
  if [[ -n "$tests" || -n "$packages" ]]; then
    MAIN_CI_FAILURE_CLASSIFICATION=test-failure
    MAIN_CI_FAILURE_REASON=named-test-failure
    [[ -n "$packages" ]] || packages=unknown
  else
    MAIN_CI_FAILURE_REASON="$(main_ci_log_environmental_reason <<< "$job_log")"
    [[ -n "$MAIN_CI_FAILURE_REASON" ]] || MAIN_CI_FAILURE_REASON=unclassified-no-named-tests
  fi
  MAIN_CI_FAILURE_PACKAGES_JSON="$(printf '%s\n' "$packages" | jq -Rsc 'split("\n") | map(select(length>0))')" || return 1
  MAIN_CI_FAILURE_TESTS_JSON="$(printf '%s\n' "$tests" | jq -Rsc 'split("\n") | map(select(length>0))')" || return 1
}

main_ci_product_owner_ring_once() {
  local key="$1" state entry alerted classification owner_type owner_id issue text package first_red_sha
  state="$(main_ci_product_owner_state_read)" || return 1
  entry="$(jq -c --arg key "$key" '.owners[$key] // empty' <<< "$state")"
  [[ -n "$entry" ]] || return 1
  alerted="$(jq -r '.alerted // false' <<< "$entry")"
  [[ "$alerted" != true ]] || return 0
  classification="$(jq -r '.classification' <<< "$entry")"
  package="$(jq -r '.package // "unknown"' <<< "$entry")"
  first_red_sha="$(jq -r '.first_red_sha' <<< "$entry")"
  if [[ "$classification" == test-failure ]]; then
    owner_type="$(jq -r '.owner_type' <<< "$entry")"
    owner_id="$(jq -r '.owner_id' <<< "$entry")"
    if [[ "$owner_type" == issue ]]; then
      issue="issue=#$owner_id owner=issue:#$owner_id"
    else
      issue="owner=agent:$owner_id"
    fi
    text="node=main-ci first-red-sha=$first_red_sha package=$package $issue"
    AGENT_HOME="$H" supervisor_inbox_append main-ci-product-owner "$text" || return 1
  else
    text="node=main-ci first-red-run=$(jq -r '.first_red_run' <<< "$entry") first-red-sha=$first_red_sha classification=environmental reason=$(jq -r '.reason' <<< "$entry")"
    AGENT_HOME="$H" supervisor_inbox_append main-ci-environmental "$text" || return 1
  fi
  main_ci_product_owner_state_put "$key" "$(jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{alerted:true,alerted_at:$at}')"
}

main_ci_product_issue_upsert() {
  local package="$1" first_red_run="$2" first_red_sha="$3" green_sha="$4" job_id="$5" job_name="$6" tests_json="$7" mode="$8"
  local classification="${9:-unknown}" reason="${10:-}" class title node body_file output issue test_name
  class="$(main_ci_product_issue_class "$package" "$first_red_sha")" || return 1
  title="主线 CI 测试失败：${package#packages/}"
  node="main-ci-product-red-${class#ci-}"
  mkdir -p "$NIGHT" || return 1
  body_file="$(mktemp "$NIGHT/.main-ci-product-issue.XXXXXX")" || return 1
  if [[ "$mode" == repeated ]]; then
    {
      printf '主线 CI 同一首红故障再次出现，继续由此 issue 跟进。\n\n'
      printf '复发 run：%s\n' "$first_red_run"
      printf '首红 SHA：%s\n' "$first_red_sha"
      printf '包：%s\n' "$package"
      printf '失败 job：%s (id %s)\n' "$job_name" "${job_id:-unknown}"
      if jq -e 'length > 0' <<< "$tests_json" >/dev/null 2>&1; then
        printf '失败测试：\n'
        while IFS= read -r test_name; do [[ -z "$test_name" ]] || printf -- '- %s\n' "$test_name"; done \
          < <(jq -r '.[]' <<< "$tests_json")
      else
        printf '本次分类：%s；原因：%s\n' "$classification" "${reason:-unknown}"
      fi
    } > "$body_file"
  else
    {
      printf '主线 CI Dagger 测试失败，按正常产品实现流程修复并走 PR。\n\n'
      printf '包：%s\n' "$package"
      printf '首红 run：%s\n' "$first_red_run"
      printf '首红 SHA：%s\n' "$first_red_sha"
      printf '最近绿 SHA：%s\n' "${green_sha:-unknown}"
      printf 'culprit commit range：%s..%s\n' "${green_sha:-unknown}" "$first_red_sha"
      printf '失败 job：%s (id %s)\n' "$job_name" "${job_id:-unknown}"
      printf '失败测试：\n'
      while IFS= read -r test_name; do [[ -z "$test_name" ]] || printf -- '- %s\n' "$test_name"; done \
        < <(jq -r '.[]' <<< "$tests_json")
    } > "$body_file"
  fi
  output="$(bash "$SCRIPT_DIR/../pipeline-issue-upsert.sh" --lane product --class "$class" \
    --title "$title" --body-file "$body_file" --repo "$REPO")" || {
    rm -- "$body_file"
    return 1
  }
  rm -- "$body_file"
  issue="$(grep -oE 'issues/[1-9][0-9]*|issue #[1-9][0-9]*' <<< "$output" | tail -n 1 | grep -oE '[1-9][0-9]*' || true)"
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\t%s\n' "$issue" "$node"
}

main_ci_product_red_owner() {
  local event_run="$1" event_attempt="$2" run_head="$3" allow_rerun_success="${4:-0}"
  local window green_sha="$run_head" first_red_run="$event_run" first_red_sha="$run_head" first_red_attempt="$event_attempt"
  local state entries entry package key class node live_owner issue_node issue owner_type owner_id tests_json job_id job_name reason reason_file payload last_run last_attempt first_red_epoch read_current=0 failure_read=0 stale_runs
  local -a packages=()
  if window="$(main_ci_first_red_window ci "$event_run" "$run_head" "$allow_rerun_success")"; then
    IFS=$'\t' read -r green_sha first_red_run first_red_sha first_red_attempt <<< "$window"
  else
    green_sha=""
  fi
  state="$(main_ci_product_owner_state_read)" || return 1
  entries="$(jq -c --arg sha "$first_red_sha" '[.owners | to_entries[] | select(.value.workflow=="ci" and .value.first_red_sha==$sha)]' <<< "$state")" || return 1
  if [[ "$entries" == '[]' ]]; then
    failure_read=1
  elif [[ "$allow_rerun_success" != 1 ]]; then
    stale_runs="$(jq -r --arg run "$event_run" --arg attempt "$event_attempt" \
      '[.[] | select(.value.last_red_run != $run or .value.last_red_attempt != $attempt)] | length' <<< "$entries")" || return 1
    [[ "$stale_runs" =~ ^[0-9]+$ ]] || return 1
    (( stale_runs == 0 )) || failure_read=1
  fi
  if (( failure_read )); then
    if [[ "$entries" == '[]' ]]; then
      main_ci_product_read_failure "$first_red_run" "$first_red_attempt" || return 1
    else
      main_ci_product_read_failure "$event_run" "$event_attempt" || return 1
      if [[ "$MAIN_CI_FAILURE_CLASSIFICATION" == test-failure ]] && \
        jq -e 'all(.[]; .value.classification=="environmental")' <<< "$entries" >/dev/null; then
        entries='[]'
        first_red_run="$event_run"
        first_red_attempt="$event_attempt"
      fi
    fi
  fi
  if [[ "$entries" != '[]' ]]; then
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      key="$(jq -r '.key' <<< "$entry")"
      package="$(jq -r '.value.package // "unknown"' <<< "$entry")"
      owner_type="$(jq -r '.value.owner_type // "none"' <<< "$entry")"
      owner_id="$(jq -r '.value.owner_id // ""' <<< "$entry")"
      last_run="$(jq -r '.value.last_red_run // ""' <<< "$entry")"
      last_attempt="$(jq -r '.value.last_red_attempt // ""' <<< "$entry")"
      if [[ "$last_run" != "$event_run" || "$last_attempt" != "$event_attempt" ]]; then
        if [[ "$owner_type" == issue ]]; then
          if (( failure_read )); then
            tests_json="$MAIN_CI_FAILURE_TESTS_JSON"
            job_id="$MAIN_CI_FAILURE_JOB_ID"
            job_name="$MAIN_CI_FAILURE_JOB_NAME"
          else
            tests_json="$(jq -c '.value.tests // []' <<< "$entry")"
            job_id="$(jq -r '.value.job_id // ""' <<< "$entry")"
            job_name="$(jq -r '.value.job_name // "Postsubmit validate"' <<< "$entry")"
          fi
          issue_node="$(main_ci_product_issue_upsert "$package" "$event_run" "$first_red_sha" "$green_sha" \
            "$job_id" "$job_name" "$tests_json" repeated "${MAIN_CI_FAILURE_CLASSIFICATION:-test-failure}" \
            "${MAIN_CI_FAILURE_REASON:-same run attempt reused first-red evidence}")" || return 1
        elif [[ "$owner_type" == hand ]]; then
          node="$(jq -r '.value.owner_node' <<< "$entry")"
          live_owner="$(main_ci_live_hand_owner "$node" node 2>/dev/null || true)"
          if [[ "$live_owner" != "$owner_id" ]]; then
            if (( failure_read )); then
              tests_json="$MAIN_CI_FAILURE_TESTS_JSON"
              job_id="$MAIN_CI_FAILURE_JOB_ID"
              job_name="$MAIN_CI_FAILURE_JOB_NAME"
            else
              tests_json="$(jq -c '.value.tests // []' <<< "$entry")"
              job_id="$(jq -r '.value.job_id // ""' <<< "$entry")"
              job_name="$(jq -r '.value.job_name // "Postsubmit validate"' <<< "$entry")"
            fi
            issue_node="$(main_ci_product_issue_upsert "$package" "$event_run" "$first_red_sha" "$green_sha" "$job_id" "$job_name" "$tests_json" initial)" || return 1
            IFS=$'\t' read -r owner_id node <<< "$issue_node"
            owner_type=issue
          fi
        fi
        payload="$(jq -cn --arg run "$event_run" --arg attempt "$event_attempt" --arg type "$owner_type" --arg id "$owner_id" \
          '{last_red_run:$run,last_red_attempt:$attempt,status:"open",owner_type:$type,owner_id:$id}')" || return 1
        main_ci_product_owner_state_put "$key" "$payload" || return 1
      fi
      main_ci_product_owner_ring_once "$key" || return 1
      printf 'first-red-run=%s first-red-sha=%s package=%s owner=%s:%s\n' \
        "$(jq -r '.value.first_red_run' <<< "$entry")" "$first_red_sha" "$package" "$owner_type" "$owner_id"
    done < <(jq -c '.[]' <<< "$entries")
    return 0
  fi

  if (( ! failure_read )); then
    main_ci_product_read_failure "$first_red_run" "$first_red_attempt" || return 1
  fi
  if [[ "$MAIN_CI_FAILURE_CLASSIFICATION" != test-failure ]]; then
    key="environmental-$first_red_sha"
    reason="$MAIN_CI_FAILURE_REASON"
    reason_file="$(jq_arg_file "$reason")" || return 1
    payload="$(jq -cn --arg run "$first_red_run" --arg sha "$first_red_sha" --arg green "$green_sha" \
      --arg attempt "$first_red_attempt" --arg job "$MAIN_CI_FAILURE_JOB_ID" --rawfile reason "$reason_file" \
      '{workflow:"ci",classification:"environmental",node:"main-ci",first_red_run:$run,first_red_sha:$sha,last_green_sha:$green,first_red_attempt:$attempt,job_id:$job,reason:$reason,status:"open",alerted:false}')" || {
        rm -f -- "$reason_file"
        return 1
      }
    rm -f -- "$reason_file"
    main_ci_product_owner_state_put "$key" "$payload" || return 1
    main_ci_product_owner_ring_once "$key" || return 1
    printf 'first-red-run=%s first-red-sha=%s classification=environmental reason=%s owner=none\n' \
      "$first_red_run" "$first_red_sha" "$reason"
    return 0
  fi
  packages=()
  while IFS= read -r package; do [[ -z "$package" ]] || packages+=("$package"); done \
    < <(jq -r '.[]' <<< "$MAIN_CI_FAILURE_PACKAGES_JSON")
  ((${#packages[@]} > 0)) || packages=(unknown)
  tests_json="$MAIN_CI_FAILURE_TESTS_JSON"
  first_red_epoch="$(date -u +%s)" || return 1
  for package in "${packages[@]}"; do
    class="$(main_ci_product_issue_class "$package" "$first_red_sha")" || return 1
    key="$class"
    node="main-ci-product-red-${class#ci-}"
    live_owner="$(main_ci_live_hand_owner "$node" node 2>/dev/null || true)"
    issue=""
    owner_type=issue
    owner_id=""
    if [[ -n "$live_owner" ]]; then
      owner_type=hand
      owner_id="$live_owner"
    else
      issue_node="$(main_ci_product_issue_upsert "$package" "$first_red_run" "$first_red_sha" "$green_sha" \
        "$MAIN_CI_FAILURE_JOB_ID" "$MAIN_CI_FAILURE_JOB_NAME" "$tests_json" initial)" || return 1
      IFS=$'\t' read -r issue node <<< "$issue_node"
      live_owner="$(main_ci_live_hand_owner "$issue" issue 2>/dev/null || true)"
      if [[ -n "$live_owner" ]]; then
        owner_type=hand
        owner_id="$live_owner"
      else
        owner_id="$issue"
      fi
    fi
    payload="$(jq -cn --arg package "$package" --arg run "$first_red_run" --arg sha "$first_red_sha" \
      --arg green "$green_sha" --arg attempt "$first_red_attempt" --arg event_run "$event_run" --arg event_attempt "$event_attempt" \
      --arg job "$MAIN_CI_FAILURE_JOB_ID" --arg job_name "$MAIN_CI_FAILURE_JOB_NAME" --arg owner_type "$owner_type" \
      --arg owner_id "$owner_id" --arg node "$node" --argjson tests "$tests_json" --argjson first_red_epoch "$first_red_epoch" \
      '{workflow:"ci",classification:"test-failure",node:$node,package:$package,first_red_run:$run,first_red_sha:$sha,last_green_sha:$green,culprit_range:($green+".."+$sha),first_red_attempt:$attempt,first_red_epoch:$first_red_epoch,last_red_run:$event_run,last_red_attempt:$event_attempt,job_id:$job,job_name:$job_name,tests:$tests,owner_type:$owner_type,owner_id:$owner_id,status:"open",alerted:false}')" || return 1
    main_ci_product_owner_state_put "$key" "$payload" || return 1
    main_ci_product_owner_ring_once "$key" || return 1
    printf 'first-red-run=%s first-red-sha=%s package=%s owner=%s:%s\n' \
      "$first_red_run" "$first_red_sha" "$package" "$owner_type" "$owner_id"
  done
}

main_ci_clear_product_red_owners() {
  local green_run="$1" green_sha="$2" state entry key status first_red_sha owner_type owner_id now epoch opened_epoch elapsed payload body
  state="$(main_ci_product_owner_state_read)" || return 1
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  epoch="$(date -u +%s)" || return 1
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    key="$(jq -r '.key' <<< "$entry")"
    status="$(jq -r '.value.status // ""' <<< "$entry")"
    [[ "$status" == open || "$(jq -r '.value.resolution_comment_pending // false' <<< "$entry")" == true ]] || continue
    first_red_sha="$(jq -r '.value.first_red_sha // ""' <<< "$entry")"
    [[ "$first_red_sha" =~ ^[0-9a-f]{40}$ ]] || continue
    git -C "$REPO_DIR" merge-base --is-ancestor "$first_red_sha" "$green_sha" || continue
    owner_type="$(jq -r '.value.owner_type // "none"' <<< "$entry")"
    owner_id="$(jq -r '.value.owner_id // ""' <<< "$entry")"
    if [[ "$status" == open ]]; then
      opened_epoch="$(jq -r '.value.first_red_epoch // empty' <<< "$entry")"
      elapsed=0
      [[ "$opened_epoch" =~ ^[0-9]+$ ]] && (( epoch >= opened_epoch )) && elapsed=$((epoch - opened_epoch))
      payload="$(jq -cn --arg run "$green_run" --arg sha "$green_sha" --arg at "$now" --argjson elapsed "$elapsed" \
        '{status:"resolved",green_run:$run,green_sha:$sha,resolved_at:$at,time_to_green_seconds:$elapsed,resolution_comment_pending:true}')" || return 1
      main_ci_product_owner_state_put "$key" "$payload" || return 1
    else
      elapsed="$(jq -r '.value.time_to_green_seconds // 0' <<< "$entry")"
    fi
    if [[ "$owner_type" == issue && "$owner_id" =~ ^[1-9][0-9]*$ ]]; then
      body="$(jq -r --arg sha "$green_sha" --arg run "$green_run" --argjson elapsed "$elapsed" \
        '"主线 CI 已恢复绿色。首红 SHA：" + .value.first_red_sha + "；绿色 run：" + $run + "；绿色 SHA：" + $sha + "；恢复耗时：" + ($elapsed|tostring) + " 秒。"' <<< "$entry")"
      if guarded_write gh issue comment "$owner_id" --repo "$REPO" --body "$body"; then
        payload="$(jq -cn --arg at "$now" '{resolution_comment_pending:false,resolution_comment_at:$at}')"
        main_ci_product_owner_state_put "$key" "$payload" || return 1
      else
        return 1
      fi
    else
      payload='{"resolution_comment_pending":false}'
      main_ci_product_owner_state_put "$key" "$payload" || return 1
    fi
  done < <(jq -c '.owners | to_entries[] | select(.value.workflow=="ci" and .value.classification=="test-failure")' <<< "$state")
}

main_ci_direct_pipeline_candidates() {
  local green_sha="$1" red_sha="$2" commit subject paths_output path
  local -a paths=()
  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    subject="$(git -C "$REPO_DIR" show -s --format=%s "$commit")" || continue
    [[ "$subject" == '[skip ci]'* ]] || continue
    paths_output="$(git -C "$REPO_DIR" diff-tree --no-commit-id --name-only -r "$commit")" || continue
    paths=()
    while IFS= read -r path; do [[ -z "$path" ]] || paths+=("$path"); done <<< "$paths_output"
    if main_ci_is_direct_pipeline_commit "$commit" "$subject" "${paths[@]}"; then
      printf '%s\n' "$commit"
    fi
  done < <(git -C "$REPO_DIR" rev-list --reverse "$green_sha..$red_sha")
}

main_ci_failed_pipeline_suite() {
  local run_id="$1" attempt="$2" jobs_json job_id job_log suite
  jobs_json="$(gh run view "$run_id" --attempt "$attempt" --json jobs --repo "$REPO")" || return 1
  job_id="$(jq -r '[.jobs[] | select(.conclusion=="failure")][0].databaseId // empty' <<< "$jobs_json")" || return 1
  [[ "$job_id" =~ ^[0-9]+$ ]] || return 1
  job_log="$(gh run view "$run_id" --attempt "$attempt" --job "$job_id" --log-failed --repo "$REPO")" || return 1
  suite="$(sed -E 's/\x1B\[[0-9;?]*[[:alpha:]]//g' <<< "$job_log" | awk '
    /\[pipeline suites\][[:space:]]+engine\/[[:alnum:]_.-]+\.test\.sh/ {
      line=$0
      sub(/^.*\[pipeline suites\][[:space:]]+/, "", line)
      sub(/[[:space:]].*$/, "", line)
      suite=line
    }
    END { if (suite != "") print suite }
  ')"
  [[ "$suite" =~ ^engine/[[:alnum:]_.-]+\.test\.sh$ ]] || return 1
  printf '%s\n' "$suite"
}

main_ci_candidate_suite_status() {
  local suite="$1" commit="$2" timeout_seconds="${3:-60}" root worktree status cleanup_failed=0
  root="$(mktemp -d "${TMPDIR:-/tmp}/main-ci-candidate.XXXXXX")" || return 2
  worktree="$root/tree"
  if ! git -C "$REPO_DIR" worktree add --quiet --detach "$worktree" "$commit"; then
    rm -rf -- "$root"
    return 2
  fi
  if [[ ! -f "$worktree/$suite" ]]; then
    status=0
  elif (cd -- "$worktree" && timeout --signal=TERM --kill-after=5s "${timeout_seconds}s" \
      env -i HOME="$HOME" PATH="$PATH" bash "$worktree/$suite" >/dev/null 2>&1); then
    status=0
  else
    status=$?
  fi
  git -C "$REPO_DIR" worktree remove --force "$worktree" >/dev/null 2>&1 || cleanup_failed=1
  rm -rf -- "$root"
  [[ "$cleanup_failed" == 0 ]] || return 2
  case "$status" in
    0) return 0 ;;
    124|137|143|126|127) return 2 ;;
    *) return 1 ;;
  esac
}

main_ci_find_first_failing_pipeline_candidate() {
  local suite="$1" started="$SECONDS" candidate parent_sha parent_status status remaining
  shift
  local -a candidates=("$@")
  # ponytail: four-minute attribution ceiling; raise only if inbox evidence shows real suites need longer.
  for candidate in "${candidates[@]}"; do
    remaining=$((240 - (SECONDS - started)))
    ((remaining > 0)) || return 2
    parent_sha="$(git -C "$REPO_DIR" rev-parse "${candidate}^")" || return 2
    if main_ci_candidate_suite_status "$suite" "$parent_sha" "$remaining"; then
      parent_status=0
    else
      parent_status=$?
    fi
    case "$parent_status" in
      0) ;;
      # Candidate inherited a red suite, so it cannot be named as the regression.
      1) return 3 ;;
      *) return 2 ;;
    esac

    remaining=$((240 - (SECONDS - started)))
    ((remaining > 0)) || return 2
    if main_ci_candidate_suite_status "$suite" "$candidate" "$remaining"; then
      status=0
    else
      status=$?
    fi
    case "$status" in
      0) continue ;;
      1) printf '%s\n' "$candidate"; return 0 ;;
      *) return 2 ;;
    esac
  done
  return 1
}

main_ci_recovery_current() {
  local workflow="$1" run_id="$2" run_head="$3" main_ref current_head runs active_status
  case "$workflow" in ci|pipeline-suites) ;; *) return 2 ;; esac
  main_ref="$(timeout -k 1 8 gh api "repos/$REPO/git/ref/heads/main" -H 'Cache-Control: no-cache')" || return 2
  current_head="$(jq -er '.object.sha | select(test("^[0-9a-f]{40}$"))' <<< "$main_ref")" || return 2
  if [[ "$current_head" == "$run_head" ]]; then
    for active_status in queued in_progress; do
      runs="$(timeout -k 1 8 gh api \
        "repos/$REPO/actions/workflows/$workflow.yml/runs?branch=main&status=$active_status&per_page=100" -H 'Cache-Control: no-cache')" || return 2
      jq -e '.workflow_runs | type == "array" and length < 100' <<< "$runs" >/dev/null || return 2
      if jq -e --argjson id "$run_id" 'any(.workflow_runs[];
          .head_branch == "main" and (.event == "push" or .event == "workflow_dispatch") and .id > $id)' \
          <<< "$runs" >/dev/null; then
        printf 'main-ci-recovery: run=%s superseded; newer main run covers it\n' "$run_id"
        return 1
      fi
    done
    return 0
  fi
  printf 'main-ci-recovery: run=%s superseded; newer main run covers it\n' "$run_id"
  return 1
}

# Attribution only: the scheduler owns the revert push (revert_squash_merge) and the unit hand-back.
# One report line: culprit=<sha> suite=<path> ..., or fallback=<reason> to keep the current rerun-verdict path.
main_ci_attribute_red() {
  local run_id="$1" attempt="$2" run_head="$3" window green_sha red_run red_sha red_attempt
  local candidates_output candidate suite culprit status total eligibility=0 candidate_json='[]' candidate_row subject files failed_log failed_tests judge_input judge_output judged_culprit
  local -a candidates=()
  [[ "$run_id" =~ ^[0-9]+$ && "$attempt" =~ ^[1-9][0-9]*$ && "$run_head" =~ ^[0-9a-f]{40}$ ]] || return 2
  main_ci_recovery_current pipeline-suites "$run_id" "$run_head" >/dev/null || eligibility=$?
  if ((eligibility != 0)); then echo "fallback=superseded-or-unreadable"; return 0; fi
  window="$(main_ci_first_red_window pipeline-suites "$run_id" "$run_head")" || { echo "fallback=failure-window-unavailable"; return 0; }
  IFS=$'\t' read -r green_sha red_run red_sha red_attempt <<< "$window"
  [[ "$red_run" != "$run_id" ]] || red_attempt="$attempt"
  candidates_output="$(main_ci_direct_pipeline_candidates "$green_sha" "$red_sha")" || { echo "fallback=candidate-list-failed"; return 0; }
  while IFS= read -r candidate; do [[ -z "$candidate" ]] || candidates+=("$candidate"); done <<< "$candidates_output"
  total="$(git -C "$REPO_DIR" rev-list --count "$green_sha..$red_sha")" || { echo "fallback=candidate-list-failed"; return 0; }
  if ((${#candidates[@]} == 0)); then echo "fallback=no-direct-pipeline-candidate"; return 0; fi
  # A pull-request merge or product commit in the window is not ours to revert from here.
  if ((${#candidates[@]} != total)); then echo "fallback=non-pipeline-commit-in-window"; return 0; fi
  suite="$(main_ci_failed_pipeline_suite "$red_run" "$red_attempt" 2>/dev/null)" || { echo "fallback=failing-suite-unavailable"; return 0; }
  culprit="$(main_ci_find_first_failing_pipeline_candidate "$suite" "${candidates[@]}")" || {
    status=$?
    case "$status" in
      1) echo "fallback=suite-did-not-reproduce" ;;
      3) echo "fallback=suite-failed-before-candidate" ;;
      *) echo "fallback=candidate-attribution-inconclusive" ;;
    esac
    return 0
  }
  judge_output=""
  if [[ -n "${TYPESAFE_API_KEY:-}${TYPESAFE_ENV_FILE:-}" ]]; then
    for candidate in "${candidates[@]}"; do
      subject="$(git -C "$REPO_DIR" log -1 --format=%s "$candidate" 2>/dev/null || true)"
      files="$(git -C "$REPO_DIR" diff-tree --no-commit-id --name-only -r "$candidate" 2>/dev/null | head -n 30 | jq -Rsc 'split("\n") | map(select(length > 0))')"
      candidate_row="$(jq -cn --arg sha "$candidate" --arg subject "$subject" --argjson files "${files:-[]}" '{sha:$sha,subject:$subject,files:$files}')"
      candidate_json="$(jq -cn --argjson rows "$candidate_json" --argjson row "$candidate_row" '$rows + [$row]')"
    done
    failed_log="$(gh run view "$red_run" --attempt "$red_attempt" --log-failed --repo "$REPO" 2>/dev/null || true)"
    failed_tests="$(printf '%s\n' "$failed_log" | rg -e 'FAILED suite=|not ok [0-9]+ -|^[[:space:]]*FAIL[[:space:]]+' | tail -n 40 | head -c 8000 || true)"
    judge_input="$(jq -cn --arg event_id "main-red:$red_run:$red_attempt" --arg current "$culprit" \
      --arg failedSuite "$suite" --arg failedTests "$failed_tests" --argjson candidates "$candidate_json" \
      '{event_id:$event_id,currentDecision:$current,failedSuite:$failedSuite,failedTests:$failedTests,candidates:$candidates}')"
    judge_output="$(printf '%s\n' "$judge_input" | bash "$REPO_DIR/engine/ts-judge.sh" main-red 2>/dev/null || true)"
  fi
  judged_culprit="$(jq -r 'select(.status=="answered" and .adopted==true) | .decision // empty' <<<"$judge_output" 2>/dev/null || true)"
  if [[ "$judged_culprit" =~ ^[0-9a-f]{40}$ ]] \
    && jq -e --arg sha "$judged_culprit" --argjson candidates "$candidate_json" 'any($candidates[]; .sha==$sha)' <<< '{}' >/dev/null 2>&1; then
    culprit="$judged_culprit"
  fi
  printf 'culprit=%s suite=%s first-red-run=%s green=%s\n' "$culprit" "$suite" "$red_run" "$green_sha"
}

main_ci_handle_event() {
  local workflow="$1" run_id="$2" attempt="$3" status="$4" conclusion="$5" head_sha="$6"
  [[ "$run_id" =~ ^[0-9]+$ && "$attempt" =~ ^[0-9]+$ ]] || return 0
  case "$status/$conclusion/$attempt" in
    completed/failure/1)
      if [[ "$workflow" == ci ]]; then
        if ! main_ci_product_red_owner "$run_id" "$attempt" "$head_sha"; then
          printf 'main-ci-recovery: could not assign first-red product owner run=%s head=%s\n' "$run_id" "$head_sha" >&2
          return 1
        fi
      fi
      local eligibility=0
      main_ci_recovery_current "$workflow" "$run_id" "$head_sha" || eligibility=$?
      case "$eligibility" in 0) ;; 1) return 0 ;; *) return "$eligibility" ;; esac
      guarded_write gh run rerun "$run_id" --repo "$REPO" --failed
      ;;
    completed/success/1)
      if [[ "$workflow" == ci ]]; then
        if ! main_ci_clear_product_red_owners "$run_id" "$head_sha"; then
          printf 'main-ci-recovery: could not clear product CI owners run=%s head=%s\n' "$run_id" "$head_sha" >&2
          return 1
        fi
      fi
      ;;
    completed/success/2)
      if [[ "$workflow" == ci ]]; then
        if ! main_ci_product_red_owner "$run_id" 1 "$head_sha" 1; then
          printf 'main-ci-recovery: could not recover first-red product owner run=%s head=%s\n' "$run_id" "$head_sha" >&2
          return 1
        fi
        if ! main_ci_clear_product_red_owners "$run_id" "$head_sha"; then
          printf 'main-ci-recovery: could not clear product CI owners run=%s head=%s\n' "$run_id" "$head_sha" >&2
          return 1
        fi
      else
        main_ci_record_successful_rerun "$workflow" "$run_id" "$head_sha"
      fi
      ;;
    completed/failure/2)
      if [[ "$workflow" == ci ]]; then
        if ! main_ci_product_red_owner "$run_id" "$attempt" "$head_sha"; then
          printf 'main-ci-recovery: could not recover failed product owner run=%s head=%s\n' "$run_id" "$head_sha" >&2
          return 1
        fi
      fi
      ;;
  esac
}

# Callers (scheduler, bell, zombie-watch) run `cancel-run` as one process per run. A repeat cancel goes
# to GitHub, which answers 409 for a run that is already completing; the CLI's exit status stays visible.
# The audit row is written before the request so the attempted-call count stays interpretable.
main_ci_cancel_run() {
  local run_id="$1" repo="${2:-$REPO}" at audit_file record status=0
  [[ "$run_id" =~ ^[0-9]+$ ]] || return 2
  if [ "$DRY_RUN" != 1 ]; then
    at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
    audit_file="$H/logs/actions-run-cancellations.jsonl"
    mkdir -p "$(dirname -- "$audit_file")" || return 1
    # ZF_CANCEL_REASON (optional, from the caller's environment) says why the cancel was sent, so
    # cancelled runner minutes can be attributed to a cause. Without it the record is unchanged.
    record="$(jq -cn --arg when "$at" --arg run_id "$run_id" --arg repo "$repo" \
      --arg reason "${ZF_CANCEL_REASON:-}" \
      '{when:$when,run_id:$run_id,repo:$repo} + (if $reason == "" then {} else {reason:$reason} end)')" || return 1
    printf '%s\n' "$record" >> "$audit_file" || return 1
  fi
  guarded_write gh run cancel "$run_id" --repo "$repo" || status=$?
  return "$status"
}

main_ci_cancel_closed_pr_runs() {
  local status pages run_ids run_id cache_file="${ZF_OPEN_ISSUES_CACHE_FILE:-}" failed=0 now
  [[ -n "$cache_file" && -s "$cache_file" ]] || {
    printf 'closed-PR CI cleanup: complete tick open-PR snapshot unavailable; deferred\n' >&2
    return 1
  }
  now="$(date +%s)"
  jq -e --argjson now "$now" '
    (.sampled_at | try fromdateiso8601 catch 0) as $sampled
    | ($sampled > 0 and $sampled <= $now and ($now - $sampled) <= 900)
      and (.open_prs | type == "array" and length < 1000
        and all(.[]; .number | type == "number" and . > 0))
  ' "$cache_file" >/dev/null 2>&1 || {
    printf 'closed-PR CI cleanup: tick open-PR snapshot invalid, capped, or stale; deferred\n' >&2
    return 1
  }
  # ponytail: GitHub caps filtered run listings at 1,000; add time-window partitioning if active PR runs reach that ceiling.
  for status in in_progress queued; do
    pages="$(gh api "repos/$REPO/actions/runs?status=$status&per_page=100" --paginate --slurp)" || return 1
    jq -e 'type == "array" and all(.[]; (.workflow_runs | type == "array"))' <<< "$pages" >/dev/null || return 1
    run_ids="$(jq -r --arg status "$status" --slurpfile snapshot "$cache_file" '
      ($snapshot[0].open_prs) as $open
      | .[].workflow_runs[]
      | select(.status == $status)
      | select(.event == "pull_request" or .event == "pull_request_target")
      | select(.path == ".github/workflows/ci.yml" or .path == ".github/workflows/pipeline-suites.yml")
      | . as $run
      | select(($run.pull_requests | type) == "array")
      | select(
          if ($run.pull_requests | length) > 0 then
            all($run.pull_requests[]; (.number | type == "number" and . > 0)
              and (.number as $number | ($open | all(.number != $number))))
          else
            ($run.head_branch | type == "string" and length > 0)
            and ($run.head_repository.full_name | type == "string" and length > 0)
            and ([$open[] | select(.headRefName == $run.head_branch
              and ((.headRepository.nameWithOwner // "") == $run.head_repository.full_name))] | length == 0)
          end
        )
      | $run.id | select(type == "number" and . > 0)
    ' <<< "$pages")" || return 1
    while IFS= read -r run_id; do
      [[ "$run_id" =~ ^[0-9]+$ ]] || continue
      main_ci_cancel_run "$run_id" || failed=1
    done <<< "$run_ids"
  done
  return "$failed"
}

# Recovery owns writes and log attribution; HEALTH only reads verdicts.
case "${1:-}" in
  handle)
    (($# == 7)) || exit 2
    shift
    main_ci_handle_event "$@"
    ;;
  attribute-red)
    (($# == 4)) || exit 2
    main_ci_attribute_red "$2" "$3" "$4"
    ;;
  cancel-closed-pr-runs)
    (($# == 1)) || exit 2
    main_ci_cancel_closed_pr_runs
    ;;
  cancel-run)
    (($# == 2 || $# == 3)) || exit 2
    main_ci_cancel_run "$2" "${3:-}"
    ;;
  *)
    printf 'Usage: %s handle <ci|pipeline-suites> <run-id> <attempt> <status> <conclusion> <head-sha> | attribute-red <run-id> <attempt> <head-sha> | cancel-closed-pr-runs | cancel-run <run-id> [repo]\n' "$0" >&2
    exit 2
    ;;
esac
