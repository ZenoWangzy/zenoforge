
# 尺寸准入的计数：分支相对 PR 基线（普通 PR 为 main，堆叠 PR 为父分支）的代码加删行数；文档、生成物、锁文件与测试快照不计，
# 避免这些内容单独变大就触发重切。数不出来（clone 丢了、fetch 失败）返回空，不挡评审。
changed_lines_count() {
  awk -F'\t' '$3 ~ /(^|\/)fixtures?\/.*\.json$/ { f += $1 + $2; next } $3 !~ /(^|\/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock)$/ && $3 !~ /^(docs|lessons|\.trellis)\// && $3 !~ /(^|\/)[^/]+\.md$/ && $3 !~ /(^|\/)(__snapshots__|generated|dist|build|coverage)(\/|$)/ && $3 !~ /(^|\/)[^/]*\.generated\.[^/]+$/ && $3 !~ /\.snap$/ { n += $1 + $2 } END { if (f > 500) n += f; print n }'  # shortcut: fixture JSON counts only past 500 lines (then in full), hardcoded; move to config if it needs tuning
}
changed_lines_of() { # dir branch base-branch [refs-current] → 行数或空
  local base base_branch="${3:-main}" refs_current="${4:-false}"
  if [[ "$refs_current" != true || "$base_branch" != main ]]; then
    git -C "$1" fetch -q origin "+refs/heads/$base_branch:refs/remotes/origin/$base_branch" "+refs/heads/$2:refs/remotes/origin/$2" 2>/dev/null || return 0
  fi
  base="$(git -C "$1" merge-base "refs/remotes/origin/$base_branch" "refs/remotes/origin/$2" 2>/dev/null)" || return 0
  git -C "$1" diff --numstat "$base" "refs/remotes/origin/$2" 2>/dev/null | changed_lines_count
}
changed_lines_in_checkout() { # dir base-branch → checkout diff 行数或空
  local base
  base="$(git -C "$1" merge-base "refs/remotes/origin/$2" HEAD 2>/dev/null)" || return 0
  [[ -n "$base" ]] || return 0
  git -C "$1" diff --numstat "$base" 2>/dev/null | changed_lines_count
}
changed_files_of() { # dir branch base-branch → actual diff paths as JSON
  local base
  base="$(git -C "$1" merge-base "refs/remotes/origin/$3" "refs/remotes/origin/$2" 2>/dev/null)" || return 0
  [[ -n "$base" ]] || return 0
  (set -o pipefail; git -C "$1" diff --no-renames --name-only -z "$base" "refs/remotes/origin/$2" 2>/dev/null \
    | jqf -Rsc '[splits("\u0000") | select(length > 0)]')
}

size_admission_exempt_unit() { # unit-json → true when the configured hotpatch exemption applies
  jqf -e --slurpfile cfg <(printf '%s' "$CFG") '($cfg[0].size_admission // {}) as $sa
    | (.hotpatch == true)
      and (if ($sa | has("exempt_hotpatch")) then $sa.exempt_hotpatch == true else true end)' <<<"$1" >/dev/null
}

# 监督者写入的 .size_waiver = {max_lines, by, at, reason}：owner 评论后用 hold.sh --rule <issue> --requeue --comment <id>
# --size-waiver <max_lines>，由 scheduler.sh --rule 在 scheduler 锁内写（rule_entry，范围见 size_waiver_range_check）：只抬高该
# unit 的上限，不是豁免——复查仍计数，改动行数超过 max_lines 的 head 照样拒绝。字段缺失或非数值时回落默认上限。
size_admission_estimate_line() { printf '%s\n' $((SIZE_ADMISSION_LINES * 80 / 100)); } # an unwaived estimate past this line is cut before a worker starts
size_waiver_range_check() { # max_lines → 0 when an integer above the estimate line (what stops an unwaived ticket) and at most twice it; else says why, 1
  local lo hi; lo="$(size_admission_estimate_line)"; hi=$((lo * 2))
  [[ "$1" =~ ^[1-9][0-9]*$ ]] && (( $1 > lo && $1 <= hi )) && return 0
  echo "rule: --size-waiver must be an integer above $lo and at most $hi (the size limit is $SIZE_ADMISSION_LINES), got '${1:-}'" >&2; return 1
}
size_admission_limit_for() { # unit-json → effective limit: a supervisor size_waiver.max_lines raises the configured floor
  local waived
  waived="$(jqf -r '.size_waiver.max_lines | select(type == "number") // empty' <<<"$1")"
  if [[ "$waived" =~ ^[0-9]+$ ]] && (( waived > SIZE_ADMISSION_LINES )); then
    printf '%s\n' "$waived"
  else
    printf '%s\n' "$SIZE_ADMISSION_LINES"
  fi
}

# 尺寸准入在 write-start、开 PR、派已有 PR 的 implement/repair 前和每次 repair/self-fix 交付后复查。
# repair-pending 的超线 PR 先走现有 needs-recut 通道，不占 worker；同一 head 已拒过或不能路由时转 supervisor。
# repair/self-fix 仍需复查新 head（#4482：PR #4396 从 611 增到 1090、#4403 从 796 增到 1063）。返回 1 = 已升级。
# A head already sent to recut routes again after a held or resumed recut; only a refused recut (recut_refused_at on the
# issue state) makes it a person's problem. An unreadable state stays refused. The head moves with main while a
# write-start has no worktree (its head is the checkout's HEAD), so a recut at the same line count (the estimate) also counts
# as already sent: 6570 went through four refused recuts at 1100 lines on four different heads (11-14).
size_recut_refused_on_head() { # unit head issue lines
  local state
  jqf -e --arg id "$1" --arg head "$2" --arg lines "$4" 'any(.units[] | select(.id==$id) | .history[]?; .stage=="size-recut" and ((.result | contains("head="+$head)) or (.result | contains(" "+$lines+" lines exceed "))))' "$UNITS" >/dev/null || return 1
  state="$(scheduler_issue_state "$3" 2>/dev/null)" || return 0
  jqf -e 'has("recut_refused_at") or has("recut_children")' <<<"$state" >/dev/null
}
unit_history_count() { # unit stage [result-regex] → history entries of that stage whose result matches
  jqf -r --arg id "$1" --arg st "$2" --arg re "${3:-}" '[.units[] | select(.id==$id) | (.history // [])[] | select(.stage==$st and ((.result // "") | test($re)))] | length' "$UNITS"
}
unit_history_count_since_ruling() { # unit stage → history entries after the latest supervisor/advisor ruling
  jqf -r --arg id "$1" --arg st "$2" '
    ([.units[] | select(.id==$id) | (.history // [])][0] // []) as $h
    | ([$h | to_entries[] | select(
        .value.stage == "advisor-ruling" or .value.stage == "review-approve"
        or (((.value.stage // "") | startswith("supervisor-")) and (
          .value.decision.owner == "supervisor"
          or ((.value.result // "") | startswith("supervisor ruling"))
        ))
      ) | .key] | max // -1) as $ruling
    | [$h[($ruling + 1):][] | select(.stage==$st)] | length' "$UNITS"
}
# A refused recut leaves the issue at the same scope, so escalating a second time cannot change the outcome (28 lines over
# 11 units in 24 h). The implement brief already carries the SPLIT contract (first independent slice, remainder filed as a
# needs-triage ticket, see dispatch-queue.sh); admit the worker once per ruling on that contract. Harvest still recounts the real diff, so the limit holds.
size_split_admit() { # unit issue lines limit → 0 after recording the one admission
  set_unit "$1" "$(hist size-split-admitted "issue #$2: $3 lines exceed $4 and recut refused; one worker run on the SPLIT contract")"
}
size_admission_reject() { # unit lines branch context head estimate actual checkpoint [limit]
  local issue limit="${9:-$SIZE_ADMISSION_LINES}" refused=false
  issue="$(unit_field "$1" '.issue // empty')"
  if [[ "$5" =~ $SHA_RE && "$issue" =~ ^[0-9]+$ ]]; then
    ! size_recut_refused_on_head "$1" "$5" "$issue" "$2" || refused=true
  fi
  # Repair-pending dispatch (5374: the repair that trims the PR was refused on every tick) gets the same one admission.
  if [[ ( "$8" == write-start || "$4" == repair-pending* ) && "$refused" == true ]] \
    && (( $(unit_history_count "$1" supervisor-escalated '^size admission:') >= 1 )) \
    && (( $(unit_history_count_since_ruling "$1" size-split-admitted) == 0 )) \
    && size_split_admit "$1" "$issue" "$2" "$limit"; then
    say "size admission write-start unit=$1 issue=#$issue estimate=${6:-unknown} actual=${7:-unknown} limit=$limit -> admitted once for a SPLIT delivery"
    return 0
  fi
  if [[ "$5" =~ $SHA_RE && "$issue" =~ ^[0-9]+$ && "$refused" == false ]] \
    && scheduler_size_recut "$issue" "$2" "$limit" "$1" "$3" "$5"; then
    set_unit "$1" "$(hist_blocked size-recut '' size-admission "issue #$issue: $2 lines exceed $limit; head=$5") | .stage=\"blocked-external\" | .size_recut_pending=true"
    if [[ "$8" == write-start ]]; then
      say "size admission write-start unit=$1 issue=#$issue estimate=${6:-unknown} actual=${7:-unknown} limit=$limit -> needs-recut"
    else
      say "unit $1 size admission routed issue #$issue to recut"
    fi
    return 1
  fi
  to_supervisor "$1" "size admission: ${2} changed lines $4 exceed the ${limit}-line limit (documentation, generated files, lockfiles, and snapshots excluded): re-scope or split before review" \
    'Request recut or split before review' 'changed lines exceed the size admission limit' \
    "${2} changed lines $4 exceed ${limit}-line limit" \
    '["Open PR for review without recutting"]'
  if [[ "$8" == write-start ]]; then
    say "size admission write-start unit=$1 issue=${issue:-none} estimate=${6:-unknown} actual=${7:-unknown} limit=$limit -> supervisor-review"
  fi
  return 1
}
size_admission_recheck_impl() { # unit dir branch context [initial-head] [refs-current]
  local lines base_branch head="${5:-}" files pr unit_json limit memo
  unit_json="$(jqf -c --arg id "$1" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
  size_admission_exempt_unit "$unit_json" && return 0
  [[ -n "${head}" ]] || say "size recheck without head: $1 $4"
  [[ -n "$2" && -n "$3" ]] || return 0
  base_branch="$(unit_field "$1" '.stacked_on_branch // "main"')"
  memo="$1|$head"
  # 同一 pass 内同一 unit、同一 head 已读过：复用行数与文件清单，不再 fetch 也不调 gh（TICK_SIZE_RECHECK_MEMO 与 TICK_SIZE_RECHECK_PASS 由 dispatch_pending_pass 声明，pass 外不生效；${x+set} 对关联数组只看 0 号键，故另设标记）。
  if [[ -n "$head" && "${TICK_SIZE_RECHECK_PASS:-false}" == true && -n "${TICK_SIZE_RECHECK_MEMO[$memo]+set}" ]]; then
    lines="${TICK_SIZE_RECHECK_MEMO[$memo]%%$'\t'*}"; files="${TICK_SIZE_RECHECK_MEMO[$memo]#*$'\t'}"
  else
    lines="$(changed_lines_of "$2" "$3" "$base_branch" "${6:-false}")"
    [[ "$lines" =~ ^[0-9]+$ ]] || return 0
    # PR 自己的文件清单（GitHub 权威，不依赖本地 refs 的新旧）；本地 refs 过期时 merge-base 退回旧提交，
    # 把合入分支的 main 改动算进来（#4631 实 13 个文件却记成 362）。超过 100 个文件 gh 会截断，退回 git diff。
    pr="$(unit_field "$1" '.pr // empty')"
    files=""
    if [[ "$pr" =~ ^[0-9]+$ ]]; then
      files="$(gh pr view "$pr" --json files --jq '.files[].path' | jqf -Rsc '[split("\n")[] | select(length > 0)]' || true)"
    fi
    jqf -e 'type == "array" and length > 0 and length < 100' <<<"$files" >/dev/null 2>&1 || files="$(changed_files_of "$2" "$3" "$base_branch")"
    if [[ -n "$head" && "${TICK_SIZE_RECHECK_PASS:-false}" == true ]]; then TICK_SIZE_RECHECK_MEMO[$memo]="$lines"$'\t'"$files"; fi
  fi
  if jqf -e 'type == "array"' <<<"$files" >/dev/null 2>&1; then
    # set_unit 要抢调度锁：footprint 没变就不写（每个候选每 pass 都写一次，ledger_write 中位 16 s）。
    if [[ "$(jqf -c '.footprint // null' <<<"$unit_json")" != "$(jqf -c . <<<"$files")" || "$(jqf -r '.footprint_source // empty' <<<"$unit_json")" != pr-diff ]]; then
      set_unit "$1" ".footprint=$files | .footprint_source=\"pr-diff\""
    fi
  fi
  limit="$(size_admission_limit_for "$unit_json")"
  (( lines > limit )) || return 0
  size_admission_reject "$1" "$lines" "$3" "$4" "$head" "" "$lines" admission "$limit"
}
size_admission_recheck() { # Keep the per-candidate diff+fetch visible inside dispatch_pending's phase total.
  local started=$SECONDS rc=0 elapsed
  size_admission_recheck_impl "$@" || rc=$?
  elapsed=$((SECONDS - started))
  (( elapsed < 2 )) || say "dispatch detail size_recheck unit=$1 secs=${elapsed}s"
  return "$rc"
}
size_admission_write_start() { # unit workdir unit-json → block before worker launch when estimate or current diff is oversized
  local issue estimate actual="" lines="" source="" branch base_branch head state limit est_limit reject_limit waived
  size_admission_exempt_unit "$3" && return 0
  issue="$(jqf -r '.issue // empty' <<<"$3")"
  estimate="$(jqf -r '.estimated_changed_lines // empty' <<<"$3")"
  if [[ ! "$estimate" =~ ^[0-9]+$ && "$issue" =~ ^[1-9][0-9]*$ ]]; then
    state="$(scheduler_issue_state "$issue" 2>/dev/null || true)"
    estimate="$(jqf -r '.estimated_changed_lines // empty' <<<"$state")"
  fi
  branch="$(jqf -r '.branch // empty' <<<"$3")"
  base_branch="$(jqf -r 'if .stacked_on_released == true then "main" else .stacked_on_branch // "main" end' <<<"$3")"
  if [[ -n "$2" && -d "$2" ]]; then
    actual="$(changed_lines_in_checkout "$2" "$base_branch")"
  fi
  head="$(git -C "$2" rev-parse -q --verify HEAD 2>/dev/null || true)"
  limit="$(size_admission_limit_for "$3")"
  # An unwaived ticket whose estimate passes 80% of the limit is cut before a worker starts (row 117: 41.2% of 641-800 estimates needed a size recut later, only 20.9% of 481-640); a waiver already means the recut ran out.
  est_limit="$limit"; (( limit != SIZE_ADMISSION_LINES )) || est_limit="$(size_admission_estimate_line)"
  waived="$(jqf -r '.size_waiver.max_lines | select(type == "number") // empty' <<<"$3")" # a waiver between the 80% line and the limit lifts the estimate line to itself
  [[ ! "$waived" =~ ^[0-9]+$ ]] || (( waived <= est_limit )) || est_limit="$waived"
  if [[ "$estimate" =~ ^[0-9]+$ ]] && (( estimate > est_limit )); then
    lines="$estimate"; source=estimate
  fi
  if [[ "$actual" =~ ^[0-9]+$ ]] && (( actual > limit )) && (( actual > ${lines:-0} )); then
    lines="$actual"; source=diff
  fi
  reject_limit="$limit"; [[ "$source" != estimate ]] || reject_limit="$est_limit"
  [[ -n "$lines" ]] || return 0
  [[ "$source" != estimate || ! "$actual" =~ ^[0-9]+$ ]] || (( actual > limit )) || (( $(unit_history_count_since_ruling "$1" size-split-admitted) == 0 )) || return 0
  # The 30-second refill may start implement workers using local data only. It
  # defers an oversized ticket for the slow tick, which owns the existing recut
  # issue transition and records the decision once.
  [[ "${TICK_DISPATCH_LOCAL_REFILL:-false}" != true ]] || return 2 # 2 = deferred, not a rejection (dispatch_if_room logs it apart)
  size_admission_reject "$1" "$lines" "$branch" "write-start ($source)" "$head" "${estimate:-unknown}" "${actual:-unknown}" write-start "$reject_limit"
}
pre_dispatch_pr_admission() { # unit branch PR context → prepared clone; nonzero means defer or recut
  local id="$1" branch="$2" pr="$3" context="$4" head dir
  head="$(tick_pr_head "$pr")" || return 1
  dir="$(ensure_clone "$id" "$branch" 1 "$head")" || { say "$context unit=$id: PR branch unavailable"; return 1; }
  size_admission_recheck "$id" "$dir" "$branch" "$context" "$head" true || return 1
  printf '%s\n' "$dir"
}

# "Delivered nothing twice" recurs once per arbiter round, because the retry counter never resets: 9 lines over 2 units in
# 24 h. After a supervisor ruling has already followed one such escalation, send the issue through the same recut route the
# cap triage uses (once per unit); a unit that already had a recut, an uncommitted tree or no issue still goes to the supervisor.
implement_nothing_escalate() { # unit message [dirty]
  local issue
  issue="$(unit_field "$1" '.issue // empty')"
  if [[ -z "${3:-}" && "$issue" =~ ^[1-9][0-9]*$ ]] \
    && (( $(unit_history_count "$1" supervisor-escalated '^implement (delivered no changes|pushed no branch)') >= 1 )) \
    && jqf -e --arg id "$1" '[.units[] | select(.id==$id)][0] | (.recut_routed != true) and all((.history // [])[]; .stage != "supervisor-budget-recut" and .stage != "supervisor-cap-triage-recut" and .stage != "supervisor-cap-default")' "$UNITS" >/dev/null; then
    supervisor_budget_recut "$1" "$2; escalated before and ruled on, same result" null "implement delivered nothing again" "implement delivered nothing again after a supervisor ruling"
    return 0
  fi
  to_supervisor "$1" "$2"
}
# NO-CHANGE repeat (row 613). A ruling is a human/head decision, not an arbiter or scheduler verdict: advisor-ruling, review-approve,
# supervisor-approve, or a hand-written supervisor-* entry with no decision object (hold.sh --rule, head requeue). Arbiter and
# scheduler entries always carry a decision, so the arbiter's own requeue never resets the window, which is the loop being stopped.
# Reason match: equal after the "(report <name>)" suffix is dropped and whitespace is trimmed and collapsed. No fuzzy matching.
NO_CHANGE_RULING_JQ='
  def norm: (. // "") | sub("\\s*\\(report [^()]*\\)\\s*$"; "") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
  def ruling: (.stage // "") as $s
    | $s == "advisor-ruling" or $s == "review-approve" or $s == "supervisor-approve"
      or (($s | startswith("supervisor-")) and ($s | startswith("supervisor-arbiter") | not)
          and $s != "supervisor-escalated" and $s != "supervisor-review" and (.decision == null));'
no_change_repeat() { # unit-json reason → 0 when an earlier NO-CHANGE escalation with the same reason lies after the last ruling
  jqf -e --arg reason "$2" "$NO_CHANGE_RULING_JQ"'
    (.history // []) as $h
    | ([$h | to_entries[] | select(.value | ruling) | .key] | max // -1) as $r
    | [$h[($r + 1):][] | select(.stage == "supervisor-escalated" and ((.result // "") | startswith("decision: implementer chose no change on purpose:"))
        and ((.result | norm) == ($reason | norm)))] | length > 0' <<<"$1" >/dev/null
}
supervisor_no_change_waiting() { # unit-json → 0 while the latest escalation is a repeated NO-CHANGE and no ruling came after it (no arbiter run)
  jqf -e "$NO_CHANGE_RULING_JQ"'
    (.history // []) as $h
    | ([$h | to_entries[] | select(.value.stage == "supervisor-escalated") | .key] | last) as $e
    | $e != null and ($h[$e].no_change_repeat == true) and ([$h[($e + 1):][] | select(ruling)] | length == 0)' <<<"$1" >/dev/null
}
# 产品 issue 的实现：worker 推分支，流水线开 PR（Refs #N）→ 进评审；OBSOLETE 直接结案。
pr_create_failure_transient() { # gh output rc → true for retryable server/transport failures
  local output="${1:-}" rc="${2:-0}"
  [[ "$rc" == 124 ]] && return 0
  grep -Eiq 'HTTP([[:space:]]|/[0-9.]+[[:space:]])5[0-9]{2}|GraphQL:[[:space:]]*Something went wrong|ECONNRESET|ETIMEDOUT|timeout|timed[[:space:]]+out|deadline exceeded' <<<"$output"
}
pr_create_backoff_refused() { # gh output rc → true when the shared GitHub back-off refused the call (rc 75 or its text), or a REST create met a PR that already exists (the next tick adopts it)
  local output="${1:-}" rc="${2:-0}"
  [[ "$rc" == 75 ]] && return 0
  grep -Eiq 'rate-limit backoff active|secondary rate limit|API rate limit (already )?exceeded|pull request already exists' <<<"$output"
}
pr_open_held_expr() { # report-path → jq update that marks the PR open as owed; recover_orphans retries it without a worker; keeps the first since
  printf '.pr_open_held={report:%s,since:%s}' "$(js "$1")" "$(js "${PR_OPEN_HELD_SINCE:-$STAMP}")"
}
pr_create_held() { # unit branch output report → keep the unit at implement for the next tick; escalate after 3 h of holds
  local unit="$1" branch="$2" out="$3" expr latest
  if [[ -n "${PR_OPEN_HELD_SINCE:-}" ]] && (( $(date -u -d "$STAMP" +%s) - $(date -u -d "$PR_OPEN_HELD_SINCE" +%s) > 10800 )); then
    to_supervisor "$unit" "PR open held by GitHub back-off for 3 h on $branch: ${out:0:160}"
    return 0
  fi
  # A tick is one process (the harvest station too, one pass per process): this resets by itself and caps recover_orphans at one refused call per tick.
  PR_OPEN_REFUSED_THIS_TICK=true
  say "unit $unit PR open held by GitHub back-off on $branch; retry next tick"
  latest="$(unit_field "$unit" '.history[-1].stage // empty')"
  expr="$(pr_open_held_expr "$4")"
  [[ "$latest" == pr-create-held ]] || expr="$(hist pr-create-held "${out:0:120}") | $expr"
  set_unit "$unit" "$expr"
}
pr_open_retry() { # unit → retry an owed PR open on the finished clone without a new worker (recover_orphans); the field is cleared first, a new hold writes it again
  local unit="$1" report dir="$WT_ROOT/wt-$1" PR_OPEN_HELD_SINCE
  report="$(unit_field "$unit" '.pr_open_held.report // empty')"
  PR_OPEN_HELD_SINCE="$(unit_field "$unit" '.pr_open_held.since // empty')"
  set_unit "$unit" 'del(.pr_open_held)'
  if [[ ! -s "$report" || ! -d "$dir" ]]; then
    to_supervisor "$unit" "PR open retry lost its report or clone on $(unit_field "$unit" .branch)"
    return 0
  fi
  harvest_pr_implement "$unit" "$report"
}
pr_create_rest() { # branch base title body → SCHED_PR_NUM/OUT/RC; the GraphQL back-off does not cover the REST pulls endpoint (transport.sh classes an api call without graphql as rest)
  local gated=false out0="$SCHED_PR_OUT" rc0="$SCHED_PR_RC" args=(api "repos/{owner}/{repo}/pulls" -X POST --jq .number)
  [[ "$1" =~ $GATED_BRANCH_RE ]] && gated=true && args+=(-F draft=true)
  args+=(-f "title=$(scrub_closing_keywords <<<"$3")" -f "head=$1" -f "base=$2" -f "body=$(scrub_closing_keywords <<<"$4")")
  if SCHED_PR_OUT="$(gh "${args[@]}" 2>&1)"; then SCHED_PR_RC=0; else SCHED_PR_RC=$?; fi
  SCHED_PR_NUM="$(grep -xE '[0-9]+' <<<"$SCHED_PR_OUT" | tail -1)"
  # An answer with neither a PR nor an error says nothing: the GraphQL refusal stands.
  [[ -n "$SCHED_PR_NUM" || "$SCHED_PR_RC" != 0 ]] || { SCHED_PR_OUT="$out0"; SCHED_PR_RC="$rc0"; }
  [[ -n "$SCHED_PR_NUM" && "$gated" == true ]] || return 0
  gh api "repos/{owner}/{repo}/issues/$SCHED_PR_NUM/labels" -X POST -f "labels[]=$GATED_LABEL" >/dev/null 2>&1 || say "PR#$SCHED_PR_NUM created through REST as a draft without the $GATED_LABEL label"
}
harvest_pr_implement() { # unit report-path
  local first issue branch dir head title pr out base pr_title pr_body hold local_head ahead dirty push_out create_error create_rc retry_limit retry_count adopt_rc reason repeat
  local PR_OPEN_HELD_SINCE="${PR_OPEN_HELD_SINCE:-$(unit_field "$1" '.pr_open_held.since // empty')}" # the first hold's time: the 3 h bound counts from it, not from write-end
  first="$(grep -m1 -v '^[[:space:]]*$' "$2" 2>/dev/null)"
  issue="$(unit_field "$1" .issue)"; branch="$(unit_field "$1" .branch)"; dir="$WT_ROOT/wt-$1"
  local dep; dep="$(blocked_on_of "$2")"
  [[ -n "$dep" ]] && { park_blocked "$1" "$dep"; return 0; }
  if [[ "$first" == OBSOLETE:* ]]; then
    obsolete_unit_close "$1" "$issue" "$first"; return 0
  fi
  if [[ "$first" == NEEDS-DIRECT:* ]]; then
    needs_direct_route "$1" "$first"; return 0
  fi
  head="$(git -C "$dir" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ "$head" =~ $SHA_RE ]]; then
    local_head="$(git -C "$dir" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null || true)"
    if [[ "$local_head" =~ $SHA_RE && "$local_head" != "$head" ]] \
      && git -C "$dir" merge-base --is-ancestor "$head" "$local_head" 2>/dev/null; then
      # A handoff can leave a committed rescue descendant in the worker clone while
      # the PR branch already exists at its older head. Publish the same topic ref
      # with a fast-forward before opening/reusing the PR; the missing-branch path
      # below cannot recover this common case because ls-remote already succeeded.
      # A branch fast-forwarded to main has no commit of its own: no push, the empty-delivery route below (issue-6882).
      git -C "$dir" fetch -q origin main 2>/dev/null || true
      if [[ -z "$(git -C "$dir" rev-list -n1 "refs/remotes/origin/main..$local_head" 2>/dev/null)" ]]; then
        head=""
      elif push_out="$(git -C "$dir" push origin "refs/heads/$branch:refs/heads/$branch" 2>&1)"; then
        head="$local_head"
        set_unit "$1" "$(hist implement-push-recovered "engine pushed worker commit $local_head to $branch")"
        say "implement-no-push unit=$1: engine pushed committed work $local_head -> $branch"
      else
        push_out="$(grep -am1 -E '(! \[remote rejected\]|^error:|^fatal:|^remote:)' <<<"$push_out" | cut -c1-160)"
        [[ -n "$push_out" ]] || push_out="git push exited nonzero"
        to_supervisor "$1" "implement committed $local_head on $branch but publishing it failed: ${push_out} (report $(basename "$2"))"
        return 0
      fi
    fi
  fi
  if [[ ! "$head" =~ $SHA_RE ]]; then
    # 远端没有分支时先诊断 worktree，再决定是否值得再跑一轮 implement（#5180/#5071/#5246）。
    local_head=""; ahead=""; dirty=""
    if [[ -d "$dir" ]]; then
      local_head="$(git -C "$dir" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null)"
      [[ "$local_head" =~ $SHA_RE ]] && ahead="$(git -C "$dir" rev-list -n1 "refs/remotes/origin/main..$local_head" 2>/dev/null)"
      dirty="$(git -C "$dir" status --porcelain 2>/dev/null | head -1)"
    fi
    if [[ -n "$ahead" ]]; then
      # 已提交未推送（worker 遵守产品侧 preflight 拒绝、网络故障等，交付提交留在 clone 里）：
      # 分支本来就要经 scheduler_pr_open 开 PR 再过评审与合并门禁，引擎代推 topic 分支
      # 不落 main、不绕过任何门禁；推不动才带 push 错误转 supervisor，不盲跑第二轮。
      if push_out="$(git -C "$dir" push origin "refs/heads/$branch:refs/heads/$branch" 2>&1)"; then
        head="$local_head"
        set_unit "$1" "$(hist implement-push-recovered "engine pushed worker commit $local_head to $branch")"
        say "implement-no-push unit=$1: engine pushed committed work $local_head -> $branch"
      else
        push_out="$(grep -am1 -E '(! \[remote rejected\]|^error:|^fatal:|^remote:)' <<<"$push_out" | cut -c1-160)"
        [[ -n "$push_out" ]] || push_out="$(printf '%s\n' "$push_out" | head -1 | cut -c1-160)"
        to_supervisor "$1" "implement committed $local_head on $branch but publishing it failed: ${push_out:-git push exited nonzero} (report $(basename "$2"))"
        return 0
      fi
    elif [[ "$local_head" =~ $SHA_RE && -z "$dirty" ]]; then
      # 空交付是独立的 no changes 类（改动落在了别的 checkout/远端，指定 worktree 既无提交
      # 也无未提交改动）：提示语点名原因，两次空交付才转 supervisor，消息同样带原因。
      if [[ "$first" == NO-CHANGE:* ]]; then
        # 实现者有意不改代码（如 SPLIT 无可独立交付切片）是决定，不是交付失败：不重试，连同原因交 supervisor。
        # 同一原因再来一次（裁决之后）：留在 supervisor-review，不派 arbiter 也不重排，等人或 head 裁决。
        reason="decision: implementer chose no change on purpose:${first#NO-CHANGE:}"
        repeat=false
        no_change_repeat "$(jqf -c --arg id "$1" '[.units[] | select(.id==$id)][0]' "$UNITS")" "$reason" && repeat=true
        to_supervisor "$1" "$reason (report $(basename "$2"))"
        if [[ "$repeat" == true ]]; then
          set_unit "$1" '(.history | map(.stage) | rindex("supervisor-escalated")) as $k | .history[$k].no_change_repeat=true'
          say "no-change repeat unit=$1: same reason again; waits at supervisor-review for a ruling, no arbiter run"
        fi
        return 0
      fi
      if [[ "$(unit_retries "$1" implement-no-changes)" == 0 ]]; then
        # 重试提示给出绝对 worktree 路径与分支，并要求报告前核对提交，使 worker 知道改动该落在哪里。
        set_unit "$1" "$(hist implement-no-changes "$(basename "$2")") | .task += $(js "

上一轮交付了报告，但指定 worktree 的 ${branch} 上既没有本地提交也没有未提交改动（改动可能落在了别的 checkout 或别的远端）。指定 worktree 绝对路径：${dir}，分支：${branch}。本轮必须在该路径内完成并提交到该分支（或按协议写 OBSOLETE:），报告前运行 git -C ${dir} log -1 核对提交。若确认本轮有意不改代码，报告首行写 NO-CHANGE: <原因>。") | .stage=\"implement-pending\""
      else
        implement_nothing_escalate "$1" "implement delivered no changes in the assigned worktree twice: $branch has no local commits and a clean tree, so the work likely landed in another checkout or remote (report $(basename "$2"))"
      fi
      return 0
    else
      if [[ "$(unit_retries "$1" implement-no-push)" == 0 ]]; then
        set_unit "$1" "$(hist implement-no-push "$(basename "$2")") | .task += $(js "

上一轮交付了报告但 origin 上没有分支 ${branch}：本轮必须通过 push preflight 并 push 该分支。") | .stage=\"implement-pending\""
      else
        implement_nothing_escalate "$1" "implement pushed no branch $branch twice (report $(basename "$2"))${dirty:+; the worktree holds uncommitted edits but no local commit on the branch}" "$dirty"
      fi
      return 0
    fi
  fi
  size_admission_recheck "$1" "$dir" "$branch" "on $branch" "$head" || return 0
  title="$(unit_field "$1" .title)"
  base="$(unit_field "$1" '.stacked_on_branch // "main"')"
  pr_title="${title:-$1}${issue:+ (#$issue)}"
  pr_body="${issue:+Refs #$issue

}Implemented by the the product autopilot. Implementer report (first lines):

$(head -40 "$2")"
  scheduler_pr_open "$branch" "$pr_title" "$pr_body" "$base"
  pr="$SCHED_PR_NUM"; out="$SCHED_PR_OUT"
  # Only the GraphQL back-off refused the create: the REST pulls endpoint has its own marker, so try it once before holding.
  if [[ ! "$pr" =~ ^[0-9]+$ && "${SCHED_PR_RC:-0}" == 75 && "$out" =~ graphql\ (rate-limit\ backoff\ active|secondary\ rate\ limit) ]]; then
    pr_create_rest "$branch" "$base" "$pr_title" "$pr_body"
    pr="$SCHED_PR_NUM"; out="$SCHED_PR_OUT"
  fi
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    create_rc="${SCHED_PR_RC:-0}"
    if pr_create_backoff_refused "$out" "$create_rc"; then
      pr_create_held "$1" "$branch" "$out" "$2"; return 0
    fi
    if [[ "${SCHED_PR_CREATE_ATTEMPTED:-false}" == true ]] && pr_create_failure_transient "$out" "$create_rc"; then
      create_error="$out"
      [[ -n "$create_error" ]] || create_error="gh pr create exited with rc=$create_rc"
      if scheduler_pr_adopt_open "$branch" "$base" true; then
        pr="$SCHED_PR_NUM"
        say "unit $1 adopted PR#$pr after transient create failure on $branch"
      else
        adopt_rc=$?
        if (( adopt_rc == 2 )); then
          to_supervisor "$1" "could not adopt the open PR for $branch after a transient create failure: ${SCHED_PR_OUT:0:200}"
          return 0
        fi
      fi
      if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
        retry_count="$(unit_retries "$1" pr-create-retry)"
        [[ "$retry_count" =~ ^[0-9]+$ ]] || retry_count=0
        retry_count=$((retry_count + 1))
        retry_limit="$(jqf -r '.pr_create_retry_limit // 3' <<<"$CFG")"
        [[ "$retry_limit" =~ ^[1-9][0-9]*$ ]] || retry_limit=3
        hold=""
        # The next tick retries on the finished clone through recover_orphans (pr_open_retry), not through a new implement worker.
        (( retry_count >= retry_limit )) || { hold=" | $(pr_open_held_expr "$2")"; PR_OPEN_REFUSED_THIS_TICK=true; }
        set_unit "$1" "$(hist pr-create-retry "$retry_count/$retry_limit: $create_error")$hold"
        if (( retry_count >= retry_limit )); then
          to_supervisor "$1" "could not open a PR for $branch after $retry_count transient failures: ${create_error:0:200}"
        else
          say "unit $1 transient PR create failure ($retry_count/$retry_limit) on $branch; retry next tick"
        fi
        return 0
      fi
    else
      to_supervisor "$1" "could not open a PR for $branch: ${out:0:200}"
      return 0
    fi
  fi
  set_unit "$1" "$(hist pr-opened "PR#$pr $head") | .pr=$pr | .lane=\"pr\" | .stage=\"review-pending\" | del(.pr_open_held)$([[ "$branch" =~ $GATED_BRANCH_RE ]] && printf ' | .gated=true')"
  say "unit $1 implemented on $branch -> PR#$pr review-pending"
  # SPLIT 交付（#4482）：尺寸契约在派发简报里前置后，worker 交第一个可独立交付切片 +
  # SPLIT 首行声明剩余范围；切片 PR 进评审的同时，剩余范围落成续作票（needs-triage，
  # 重新量尺寸），不再丢失也不再把原票整票重派。幂等：一个 unit 只建一张（.split_followup）。
  if [[ "$first" == SPLIT:* && -z "$(unit_field "$1" '.split_followup // empty')" ]]; then
    split_followup_issue "$1" "$issue" "$pr" "$first" "$2"
  fi
}

# SPLIT 交付的续作票（#4482）：worker 按尺寸准入只交付了第一个可独立交付切片，报告首行
# SPLIT: <剩余范围一句话>。剩余范围需要一张自己的票承载——生而 needs-triage，走正常分诊
# （含行数估算），不会再被整票派发。创建失败记 supervisor inbox，单元保持评审队列。
split_followup_issue() { # unit issue pr split-line report-path
  local unit="$1" issue="$2" pr="$3" first="$4" rep="$5" remainder body url num parent
  remainder="$(printf '%s' "$first" | sed -E 's/^SPLIT:[[:space:]]*//')"
  body="## Parent

由 #$issue 按尺寸准入拆分出的续作票：第一个可独立交付切片在 PR #$pr 送评审，本票承接剩余范围，会走正常的分诊流程（含行数估算），不跳过分诊。

## 剩余范围

$remainder

## 切片交付说明（worker 报告）

$(head -n 200 "$rep" 2>/dev/null)"
  # The follow-up is the parent's sibling: an open child makes the parent a roadmap container, which refuses awaiting-release.
  parent="$(gh api "repos/{owner}/{repo}/issues/$issue/parent" --jq '.number // empty' 2>/dev/null || true)"
  url="$(scheduler_auto_filed_issue_create --title "$(unit_field "$unit" .title)（续作自 #${issue}）" --body "$body" --label needs-triage ${parent:+--parent "$parent"} 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    num="${url##*/}"
    set_unit "$unit" "$(hist split-followup "issue #$num: $remainder") | .split_followup=$num"
    say "unit $unit split delivery: remainder #$num filed; slice in PR #$pr"
  else
    # 切片 PR 已在评审，失败只报 supervisor inbox，不把单元踢出评审队列；剩余范围仍在 worker 报告与 PR 描述里。
    ( source "$SCHEDULER_AGENT_LIB" && supervisor_inbox_append_once "split-followup-failed:$unit" "split 续作票创建失败 unit=$unit 原票 #$issue 切片 PR #${pr}：剩余范围见报告 $(basename "$rep")" ) >/dev/null 2>&1 \
      || say "unit $unit split followup create failed; remainder in $(basename "$rep")"
  fi
}
