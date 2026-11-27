GH_HEAD="$H1"; GH_STATE=OPEN; GH_MERGE_SHA=""; GH_RUNS='[]'; GH_LOG=""
GH_MERGES=(); GH_RERUNS=()
# PR runner 名额（60ba960cf 起；6adc3ba00 起按 runner busy 折算）：默认 1 个在线 PR runner、不忙；
# 离线和非 PR 池（cihost-ci-main）的不算。GH_RUNNERS 是 actions/runners 的响应体，应答时套调用方
# 的 --jq；GH_RUN_JOBS 按 run id 给 {jobs:[...]}。
GH_RUNNERS='{"runners":[{"id":1,"status":"online","busy":false,"labels":[{"name":"cihost-ci"}]},{"id":2,"status":"offline","busy":false,"labels":[{"name":"cihost-ci"}]},{"id":3,"status":"online","busy":false,"labels":[{"name":"cihost-ci-main"}]}]}'
# per-head check-runs reads land in their own log so GH_PR_CALLS line-shape asserts stay about pr commands
GH_CHECK_RUNS_CALLS="$fixture/check-runs.calls"; : > "$GH_CHECK_RUNS_CALLS"
GH_MERGES_FILE="$fixture/gh-merges.calls"; : > "$GH_MERGES_FILE"
GH_RUN_JOBS='{}'
GH_CHECKS_PASS='[{"name":"ci","bucket":"pass"}]'
# open PR 表放在文件里（$(...) 和后台任务里的调用也算数）。用例把 GH_PR_TABLE 指到一个文件才打开；
# 没指时 `gh pr list` 照旧不出声。列表和真 CLI 一样：只回 --json 要的字段，再套 --jq。
GH_PR_CALLS="$fixture/gh-pr-calls"
gh_pr_open() { # number head draft(true|false) mergeable branch [statusCheckRollup-json]
  local t; t="$(jq -c --argjson n "$1" --arg h "$2" --argjson d "$3" --arg m "$4" --arg b "$5" --argjson r "${6:-[]}" \
    '. += [{number:$n, headRefOid:$h, isDraft:$d, mergeable:$m, headRefName:$b, labels:[], statusCheckRollup:$r}]' "$GH_PR_TABLE")" && printf '%s\n' "$t" > "$GH_PR_TABLE"
}
gh_pr_is_draft() { jq -r --argjson n "$1" '.[] | select(.number == $n) | .isDraft' "$GH_PR_TABLE"; }
gh_pr_list() { # pr list ... [--json fields] [--jq expr]
  local fields="" query="." n rows='[]'
  echo "$*" >> "$GH_PR_CALLS"
  if [[ -z "${GH_PR_TABLE:-}" ]]; then
    # No table: light census rows for the ready PRs; the check rows come from the per-head check-runs stub (GH_CHECKS),
    # the head is the one `pr view` reports (GH_HEAD).
    while (( $# )); do case "$1" in --jq) query="$2" ;; esac; shift; done
    for n in $(jq -r '.units[] | select(.stage == "ready-to-merge" and .pr != null) | .pr' "$UNITS"); do
      rows="$(jq -c --argjson n "$n" --arg head "${GH_HEAD:-}" --arg mergeable "${GH_MERGEABLE_STATE:-}" '. += ([{number: $n, headRefOid: (if $head == "" then null else $head end), isDraft: false}] | map(. + (if $mergeable == "" then {} else {mergeable:$mergeable} end)))' <<<"$rows")"
    done
    jq -cr "$query" <<<"$rows"
    return 0
  fi
  while (( $# )); do case "$1" in --json) fields="$2" ;; --jq) query="$2" ;; esac; shift; done
  jq -c --arg f "$fields" '($f | split(",")) as $k | map(with_entries(select(.key as $x | $k | index($x))))' "$GH_PR_TABLE" | jq -cr "$query"
}
gh_pr_ready() { # number [--undo]：幂等，已在目标状态也成功
  local t; echo "pr ready $*" >> "$GH_PR_CALLS"
  [[ -n "${GH_PR_TABLE:-}" ]] || return 0
  t="$(jq -c --argjson n "$1" --argjson d "$([[ "${2:-}" == --undo ]] && echo true || echo false)" 'map(if .number == $n then .isDraft = $d else . end)' "$GH_PR_TABLE")" \
    && printf '%s\n' "$t" > "$GH_PR_TABLE"
}
gated_unit() { # id pr branch approved_sha → 一个 ready-to-merge 单元行，标成调度器自己的（gated）
  jq -cn --arg id "$1" --argjson pr "$2" --arg b "$3" --arg s "$4" '{id:$id, pr:$pr, branch:$b, stage:"ready-to-merge", approved_sha:$s, gated:true, history:[]}'
}
gh() {
  case "$1 $2" in
    # #4725 条件请求包装（gh_api_cached）发出的 `gh api -i [-H …] …`：剥掉 -i/-H 后按原样
    # 递归分发到下面的既有分支，再用 200 + ETag 头信封包一层，让包装走 200 缓存分支。
    "api -i")
      local rest=() skip_next=0 arg body
      for arg in "$@"; do
        (( skip_next )) && { skip_next=0; continue; }
        case "$arg" in
          -i) ;;
          -H) skip_next=1 ;;
          *) rest+=("$arg") ;;
        esac
      done
      body="$(gh "${rest[@]}")" || return $?
      printf 'HTTP/2.0 200 OK\nEtag: "stub"\n\n%s\n' "$body"
      return 0 ;;
    "pr list") gh_pr_list "$@" ;;
    "pr ready") shift 2; gh_pr_ready "$@" ;;
    "pr edit")
      printf '%s\n' "$*" >> "$fixture/pr-edit.calls"
      local edit_status="${GH_PR_EDIT_STATUS:-0}"
      [[ "$edit_status" == 0 ]] || return "$edit_status"
      if [[ -n "${GH_PR_TABLE:-}" ]]; then
        local updated_table
        case "$4" in
          --remove-label)
            updated_table="$(jq -c --argjson n "$3" --arg label "$5" 'map(if .number == $n then .labels = [(.labels // [])[] | select(.name != $label)] else . end)' "$GH_PR_TABLE")" ;;
          --add-label)
            updated_table="$(jq -c --argjson n "$3" --arg label "$5" 'map(if .number == $n then .labels = ((.labels // []) | map(select(.name != $label)) + [{name:$label}]) else . end)' "$GH_PR_TABLE")" ;;
        esac
        [[ -z "${updated_table:-}" ]] || printf '%s\n' "$updated_table" > "$GH_PR_TABLE"
      fi
      return 0 ;;
    "pr update-branch") echo "$*" >> "$GH_PR_CALLS" ;;
    "pr view")
      case "$5" in
        headRefOid) echo "$GH_HEAD" ;; state) echo "$GH_STATE" ;; headRefName) echo "fix/branch" ;;
        mergeCommit) echo "$GH_MERGE_SHA" ;; *) echo "" ;;
      esac ;;
    "pr checks") echo "${GH_CHECKS:-$GH_CHECKS_PASS}" ;;
    "pr merge") printf '%s\n' "$*" >> "$GH_MERGES_FILE" ;;
    "run list")
      local jq_expr="" has_jq=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --jq) jq_expr="$2"; has_jq=true; shift 2 ;;
          --json) shift 2 ;;
          *) shift ;;
        esac
      done
      if [[ -n "${GH_RUN_JSON:-}" ]]; then
        if [[ "$has_jq" == true ]]; then jq -r "$jq_expr" <<<"$GH_RUN_JSON"; else printf '%s\n' "$GH_RUN_JSON"; fi
      else printf '%s\n' "$GH_RUNS"; fi
      return "${GH_RUN_LIST_FAIL:-0}" ;;
    "run rerun")
      local rerun_rc="${GH_RERUN_FAIL:-0}"
      GH_RERUNS+=("$*")
      [[ -z "${GH_RERUN_FAIL_ID:-}" || "$3" != "$GH_RERUN_FAIL_ID" ]] || rerun_rc=1
      [[ "$rerun_rc" != 0 ]] || gh_run_jobs_invalidate "$3" || :
      return "$rerun_rc" ;;
    'api repos/example-maintainer/example-repo/issues/'*'/sub_issues?per_page=100') echo '[]' ;;
    "api --paginate")
      case "$3" in
        # 在线 PR runner 名额（60ba960cf）：套调用方的 --jq，让过滤表达式本身被测到
        "repos/{owner}/{repo}/actions/runners?per_page=100")
          local runners_jq="" runners_prev="" arg
          for arg in "$@"; do [[ "$runners_prev" == --jq ]] && runners_jq="$arg"; runners_prev="$arg"; done
          if [[ -n "$runners_jq" ]]; then jq -r "$runners_jq" <<<"$GH_RUNNERS"; else printf '%s\n' "$GH_RUNNERS"; fi ;;
        # 按状态列 run（8ca4eceaa 的 unfinished_runs / ci_pr_free_slots）：从 GH_RUNS 过滤，
        # 调用方 --jq 只做形状映射，这里直接给映射后的行（run 对象或 id）
        "repos/{owner}/{repo}/actions/runs?status="*)
          local st="$3" runs_jq="" runs_prev="" arg
          st="${st#*status=}"; st="${st%%&*}"
          for arg in "$@"; do [[ "$runs_prev" == --jq ]] && runs_jq="$arg"; runs_prev="$arg"; done
          if [[ "$runs_jq" == '.workflow_runs[].id' ]]; then
            jq -r --arg st "$st" '.[] | select(.status == $st) | .databaseId' <<<"$GH_RUNS"
          else
            jq -c --arg st "$st" '.[] | select(.status == $st)' <<<"$GH_RUNS"
          fi ;;
      esac ;;
    # #4725 gh_api_cached 递归分发落进来的直连形态（`gh api <url> --jq …`，无 --paginate）：
    # 与上面 --paginate 分支同款逻辑，URL 从 $2 取。jobs 走下面既有的 jobs 分支。
    "api repos/{owner}/{repo}/actions/runners?per_page=100")
      local runners_jq="" runners_prev="" arg
      for arg in "$@"; do [[ "$runners_prev" == --jq ]] && runners_jq="$arg"; runners_prev="$arg"; done
      jq -r "${runners_jq:-.runners[].id}" <<<"$GH_RUNNERS" ;;
    "api repos/{owner}/{repo}/actions/runs?status="*)
      local st="$2" runs_jq="" runs_prev="" arg
      st="${st#*status=}"; st="${st%%&*}"
      for arg in "$@"; do [[ "$runs_prev" == --jq ]] && runs_jq="$arg"; runs_prev="$arg"; done
      if [[ "$runs_jq" == '.workflow_runs[].id' ]]; then
        jq -r --arg st "$st" '.[] | select(.status == $st) | .databaseId' <<<"$GH_RUNS"
      else
        jq -c --arg st "$st" '.[] | select(.status == $st)' <<<"$GH_RUNS"
      fi ;;
    # 检查行按 head SHA 单取（轻量 census 不再带 statusCheckRollup）：表模式把该 head 所在 PR 的
    # statusCheckRollup 行转成 REST check_runs（同一 head 有多行时取第一个 PR）；无表时把 GH_CHECKS
    # 的 bucket 行转成 REST 行，pending 即未完成的 status。
    "api repos/{owner}/{repo}/commits/"*"/check-runs"*)
      local cr_sha="$2" cr_jq="" cr_prev=""
      cr_sha="${cr_sha#*commits/}"; cr_sha="${cr_sha%%/*}"
      echo "check-runs $cr_sha" >> "$GH_CHECK_RUNS_CALLS"
      for arg in "$@"; do [[ "$cr_prev" == --jq ]] && cr_jq="$arg"; cr_prev="$arg"; done
      if [[ -n "${GH_PR_TABLE:-}" ]] && jq -e --arg sha "$cr_sha" 'any(.[]; .headRefOid == $sha)' "$GH_PR_TABLE" >/dev/null 2>&1; then
        jq -c --arg sha "$cr_sha" '[.[] | select(.headRefOid == $sha)][0].statusCheckRollup // []
          | {total_count: length, check_runs: map({name: (.name // ""), details_url: (.detailsUrl // ""), started_at: (.startedAt // null),
              status: ((.status // "completed") | ascii_downcase),
              conclusion: (if (.conclusion // null) == null then null else (.conclusion | ascii_downcase) end)})}' "$GH_PR_TABLE" | jq -r "${cr_jq:-.}"
      else
        jq -c '{total_count: length, check_runs: map({name: .name, details_url: (.link // ""), started_at: (.started_at // null),
            status: (if .bucket == "pending" then "in_progress" else "completed" end),
            conclusion: ({pass: "success", fail: "failure", skipping: "skipped", neutral: "neutral", cancel: "cancelled"}[.bucket] // null)})}' <<<"${GH_CHECKS:-$GH_CHECKS_PASS}" | jq -r "${cr_jq:-.}"
      fi ;;
    # 一个 run 的 job 快照：[{status, runner_id}]（cd947d120 的共享缓存契约）
    "api repos/{owner}/{repo}/actions/runs/"*"/jobs"*)
      local jobs_id="$2" jobs_jq="" jobs_prev="" arg
      jobs_id="${jobs_id#*actions/runs/}"; jobs_id="${jobs_id%%/*}"
      for arg in "$@"; do [[ "$jobs_prev" == --jq ]] && jobs_jq="$arg"; jobs_prev="$arg"; done
      jq -c --arg id "$jobs_id" '.[$id] // {jobs:[]}' <<<"$GH_RUN_JOBS" | jq -r "${jobs_jq:-.}" ;;
    "run view") printf '%s\n' "$*" >> "$fixture/run-view.calls"; echo "$GH_LOG" ;;
  esac
}

merge_lane_real="$(declare -f run_merge_lane)"
eval "${merge_lane_real/run_merge_lane ()/run_merge_lane_real ()}"
run_merge_lane() {
  local rc=0
  : > "$GH_MERGES_FILE"
  run_merge_lane_real "$@" || rc=$?
  mapfile -t GH_MERGES < "$GH_MERGES_FILE"
  return "$rc"
}
