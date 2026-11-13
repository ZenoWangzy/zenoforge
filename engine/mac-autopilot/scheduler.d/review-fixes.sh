# Bounded reviewer fixes stay on the PR branch and become an approval only
# after the scheduler validates the exact commit and records its test receipt.

reviewer_git_name() { printf 'Zenoforge reviewer (%s/%s)' "$1" "$2"; }
reviewer_git_email() { printf 'zenoforge-reviewer@users.noreply.github.com'; }
reviewer_git_identity_configure() { # worktree provider model
  local dir="$1" provider="$2" model="$3"
  [[ -n "$dir" ]] && git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$dir" config user.name "$(reviewer_git_name "$provider" "$model")" \
    && git -C "$dir" config user.email "$(reviewer_git_email)"
}

review_fix_refusal_report() { # parsed findings reason unit head → report basename
  local parsed="$1" reason="$2" unit="$3" head="$4" safe_id out block
  safe_id="$(tr -c 'A-Za-z0-9._-' '-' <<<"$unit" | sed 's/-$//')"
  out="review-fix-refused-${safe_id}-${head:0:12}.md"
  if [[ -n "$parsed" ]]; then
    block="$(jq -c --rawfile reason <(printf '%s' "$reason") '
      .findings |= (if any(.[]; .status=="fixed-in-review") then
        map(if .status=="fixed-in-review" then
          .status="open"
          | .summary=((.summary // .id) + " Reviewer fix refused: " + $reason)
          | .rerun_command=("test receipt for " + (.test.path // "review fix"))
          | .rerun_output=$reason
          | del(.commit_sha,.test)
        else . end)
      else .findings + [{id:"RF1",severity:"P1",file:"review-fix",line:1,rule:"Review fix gate",status:"open",
        summary:("Reviewer changed the PR head outside the in-review fix contract: " + $reason),
        introduced_by:"candidate",base_evidence:"The reviewed head did not contain this commit.",
        rerun_command:"review fix scope and receipt gate",rerun_output:$reason}]
      end) | {findings:.findings,dispositions:[]}' <<<"$parsed")" || return 1
  else
    block="$(jq -cn --rawfile reason <(printf '%s' "$reason") '{findings:[{id:"RF1",severity:"P1",file:"review-fix",line:1,rule:"Review fix gate",status:"open",
      summary:("Reviewer changed the PR head outside the in-review fix contract: " + $reason),
      introduced_by:"candidate",base_evidence:"The reviewed head did not contain this commit.",
      rerun_command:"review fix scope and receipt gate",rerun_output:$reason}],dispositions:[]}')" || return 1
  fi
  {
    printf '# Reviewer fix gate\n\nREQUEST-CHANGES: %s\n\nVERDICT: NOT_READY\n\n' "$reason"
    printf '```review-findings\n%s\n```\n' "$block"
  } > "$SUP/$out" || return 1
  printf '%s\n' "$out"
}

review_fix_result() { # action verdict sha pr-head reason [report]
  jq -cn --arg action "$1" --arg verdict "$2" --arg sha "$3" --arg pr_head "$4" --arg reason "$5" --arg report "${6:-}" \
    '{action:$action,verdict:$verdict,sha:$sha,pr_head:$pr_head,reason:$reason} + (if $report=="" then {} else {report:$report} end)'
}

review_fix_test_path_valid() { # repo-relative test path
  [[ -n "$1" && "$1" != /* && "$1" != *$'\n'* && "$1" != *$'\r'* ]] || return 1
  [[ "$1" != *[[:space:]]* ]] || return 1
  [[ "$1" != -* ]] || return 1
  [[ "/$1/" != *"/../"* && "/$1/" != *"/./"* ]]
}

review_fix_source_path_valid() { # repository-relative source path; reject tests and non-code files
  [[ -n "$1" && "$1" != /* && "$1" != *[[:space:]]* && "$1" != -* \
    && "/$1/" != *"/../"* && "/$1/" != *"/./"* ]] || return 1
  case "$1" in
    *.sh|*.bash|*.js|*.mjs|*.cjs|*.ts|*.tsx|*.jsx|*.py|*.go|*.rs|*.java|*.c|*.h|*.cc|*.cpp|*.rb|*.php|*.sql) ;;
    *) return 1 ;;
  esac
  case "$1" in *.test.*|*.spec.*) return 1 ;; esac
}

review_fix_run_receipt() { # repo head test path → test runner rc, recorded at HEAD by tools/test-receipt.sh
  local repo="$1" head="$2" path="$3" engine_root common log timeout_s
  local -a command=()
  review_fix_test_path_valid "$path" || return 1
  case "$path" in
    *.test.sh) command=(bash "$path") ;;
    *.test.mjs) command=(node --test "$path") ;;
    *.test.py) command=(python3 "$path") ;;
    *) return 1 ;;
  esac
  [[ "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" == "$head" ]] || return 1
  [[ -z "$(git -C "$repo" status --porcelain --untracked-files=all 2>/dev/null)" ]] || return 1
  engine_root="${ENGINE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)}"
  [[ -f "$engine_root/tools/test-receipt.sh" ]] || return 1
  common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ "$common" == /* ]] || common="$repo/$common"
  mkdir -p -- "$common/zf-review-fix-tests" || return 1
  log="$common/zf-review-fix-tests/$head.log"
  timeout_s="${REVIEW_FIX_TEST_TIMEOUT:-${SELF_CHECK_STEP_TIMEOUT:-900}}"
  [[ "$timeout_s" =~ ^[0-9]+$ ]] && (( timeout_s > 0 )) || timeout_s=900
  (cd -- "$repo" && timeout -k 10 "$timeout_s" bash "$engine_root/tools/test-receipt.sh" "${command[@]}") > "$log" 2>&1
}

review_fix_gate() { # repo base-sha current-pr-head report provider model branch lane observed-pr-head unit → JSON result
  local repo="$1" base="$2" current="$3" report="$4" provider="$5" model="$6" branch="$7" lane="$8" observed="$9" unit="${10}"
  local parsed='' fixed_count=0 finding file test_path commit_sha parent author_name author_email committer_name committer_email base_author_name base_author_email expected_name expected_email status repo_head repo_is_git=false source_numstat adds dels source_lines reason='' refusal_report='' actual_branch
  parsed="$(findings_block_of "$report" 2>/dev/null || true)"
  if [[ -n "$parsed" ]]; then fixed_count="$(jq -r '[.findings[] | select(.status=="fixed-in-review")] | length' <<<"$parsed")" || fixed_count=0; fi
  [[ "$fixed_count" =~ ^[0-9]+$ ]] || fixed_count=0
  status="$(git -C "$repo" status --porcelain --untracked-files=all 2>/dev/null || true)"
  actual_branch="$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if (( fixed_count == 0 )); then
    if [[ -n "$repo" ]] && git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      repo_is_git=true; repo_head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    fi
    if [[ ( "$repo_is_git" == true && ( -n "$status" || "$repo_head" != "$base" ) ) \
       || ( "$lane" == pr && ( ! "$observed" =~ ^[0-9a-f]{40}$ || "$current" != "$observed" ) ) ]]; then
      reason='the reviewer changed the worktree or PR head without a fixed-in-review finding'
    else
      review_fix_result approve READY "$base" "$observed" ''
      return 0
    fi
  else
    finding="$(jq -c '[.findings[] | select(.status=="fixed-in-review")][0]' <<<"$parsed")"
    file="$(jq -r '.file' <<<"$finding")"
    test_path="$(jq -r '.test.path' <<<"$finding")"
    commit_sha="$(jq -r '.commit_sha' <<<"$finding")"
    if [[ "$lane" != pr ]]; then reason='in-review fixes require a PR branch';
    elif (( fixed_count != 1 )); then reason='one review pass may fix only one finding';
    elif [[ ! "$base" =~ ^[0-9a-f]{40}$ || "$current" != "$commit_sha" || "$current" == "$base" ]]; then reason='the reported fix commit is not the observed PR head';
    elif [[ "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" != "$current" || -n "$status" ]]; then reason='the pushed fix commit is not the clean worktree head';
    elif [[ ! "$branch" =~ ^[A-Za-z0-9._/-]+$ || "$actual_branch" != "$branch" || "$branch" == main ]]; then reason='the fix is not on the unit branch';
    else
      parent="$(git -C "$repo" rev-parse "$current^" 2>/dev/null || true)"
      author_name="$(git -C "$repo" show -s --format=%an "$current" 2>/dev/null || true)"
      author_email="$(git -C "$repo" show -s --format=%ae "$current" 2>/dev/null || true)"
      committer_name="$(git -C "$repo" show -s --format=%cn "$current" 2>/dev/null || true)"
      committer_email="$(git -C "$repo" show -s --format=%ce "$current" 2>/dev/null || true)"
      expected_name="$(reviewer_git_name "$provider" "$model")"
      expected_email="$(reviewer_git_email)"
      base_author_name="$(git -C "$repo" show -s --format=%an "$base" 2>/dev/null || true)"
      base_author_email="$(git -C "$repo" show -s --format=%ae "$base" 2>/dev/null || true)"
      if [[ "$parent" != "$base" ]]; then reason='the reviewer fix must be one commit directly on the reviewed head';
      elif [[ "$author_name" != "$expected_name" || "$author_email" != "$expected_email" \
        || "$committer_name" != "$expected_name" || "$committer_email" != "$expected_email" ]]; then reason='the fix commit does not carry the dispatched reviewer identity';
      elif [[ "$author_name" == "$base_author_name" && "$author_email" == "$base_author_email" ]]; then reason='the reviewer is the author of the reviewed head';
      elif ! review_fix_source_path_valid "$file"; then reason='the finding path is not a repository-relative source file';
      elif ! review_fix_test_path_valid "$test_path"; then reason='the named regression test path is not safe';
      elif [[ "$file" == "$test_path" ]]; then reason='the source file and regression test must be distinct files';
      elif ! git -C "$repo" cat-file -e "$current:$test_path" 2>/dev/null; then reason='the named regression test is absent from the fix commit';
      elif [[ "$(git -C "$repo" diff-tree --no-commit-id --name-only -r --no-renames "$current" 2>/dev/null | sort -u | tr '\n' ' ')" != "$(printf '%s\n' "$file" "$test_path" | sort -u | tr '\n' ' ')" ]]; then reason='the fix commit changes files outside the finding and its regression test';
      else
        source_numstat="$(git -C "$repo" --literal-pathspecs diff --numstat "$base" "$current" -- "$file" 2>/dev/null)"
        read -r adds dels _ <<<"$source_numstat"
        if [[ ! "$adds" =~ ^[0-9]+$ || ! "$dels" =~ ^[0-9]+$ ]]; then reason='the source-file change is not a text diff';
        else
          source_lines=$((adds + dels))
          if (( source_lines > 20 )); then reason="the source-file fix changes $source_lines lines (limit 20)";
          elif ! review_fix_run_receipt "$repo" "$current" "$test_path"; then reason='the named test receipt did not pass on the fix commit';
          elif [[ "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" != "$current" || -n "$(git -C "$repo" status --porcelain --untracked-files=all 2>/dev/null)" ]]; then reason='the test changed the reviewed commit or left a dirty worktree';
          else
            review_fix_result approve READY "$current" "$current" ''
            return 0
          fi
        fi
      fi
    fi
  fi
  refusal_report="$(review_fix_refusal_report "$parsed" "$reason" "$unit" "${current:-$base}")" || return 1
  review_fix_result request-changes NOT_READY "${current:-$base}" "${current:-$observed}" "$reason" "$refusal_report"
}

review_harvest_gate() { # worker-json report-path unit worker-type; sets harvest's v, wsha, wprhead, report and rep
  local worker="$1" path="$2" unit="$3" type="$4" workdir base current pr provider model branch lane observed result report_name
  v="$(verdict_of "$path")"
  [[ "$type" == review || "$type" == rereview ]] || return 0
  [[ "$v" == READY ]] || return 0
  workdir="$(jqf -r '.workdir // empty' <<<"$worker")"
  base="$(jqf -r '.sha // empty' <<<"$worker")"
  observed="$(jqf -r '.pr_head // empty' <<<"$worker")"
  pr="$(unit_field "$unit" '.pr // empty')"
  provider="$(jqf -r '.provider // empty' <<<"$worker")"
  model="$(jqf -r '.model // empty' <<<"$worker")"
  branch="$(unit_field "$unit" '.branch // empty')"
  lane="$(unit_field "$unit" '.lane // empty')"
  current="$observed"
  [[ "$lane" != pr ]] || current="$(tick_pr_head "$pr" 2>/dev/null || true)"
  result="$(review_fix_gate "$workdir" "$base" "$current" "$path" "$provider" "$model" "$branch" "$lane" "$observed" "$unit")" || return 1
  v="$(jqf -r '.verdict' <<<"$result")"
  wsha="$(jqf -r '.sha' <<<"$result")"
  wprhead="$(jqf -r '.pr_head' <<<"$result")"
  w="$(jqf --arg sha "$wsha" --arg pr_head "$wprhead" '.sha=$sha | .pr_head=$pr_head' <<<"$worker")" || return 1
  report_name="$(jqf -r '.report // empty' <<<"$result")"
  if [[ -n "$report_name" ]]; then report="$report_name"; rep="$SUP/$report_name"; fi
}
