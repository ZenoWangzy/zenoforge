
# ---------- 4a. issue 收单：按可启动产能收并维持 ready buffer，不是固定 3 个 ----------
# 2026-10-20 maintainer：8 个 worker 是雇来干活的。实测平均只 2/8 在干、近半数 tick 0 个在干，而 open issue 有 500+：
# 根因是收单只收 pipeline-system 标签、在途上限 3。现在：慢拍补到 max_workers - 在跑 + ready_buffer；
# 非产品标签走直落车道，产品标签（默认 ready-for-agent）走 PR 车道（实现 → 推分支 → 流水线开 PR → 评审 → 合并 → 发布列车）。
# WIP 护栏（Little 定律）：开发/评审/返工环节在途 ≤ max_upstream（默认 2×max_workers）；待合并队列 ≥ max_ready（默认 30）时停止收单——瓶颈在合并车道，堆更多 WIP 只会拉长交付时间。
# founder-test 是维护者提的 issue，队列里排第一（docs/agents/issue-pipeline.md），不是跳过标签（2026-10-20 曾误跳过 30 个）。
intake_remote_read_reserve() { # Reserve one bounded GH read across this tick and any intake subprocesses.
  local cap="${ISSUE_INTAKE_REMOTE_READ_CAP:-24}" used=0 marker
  [[ -n "${TICK_INTAKE_READS_FILE:-}" ]] || return 0
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=24
  (
    exec 9>"$TICK_INTAKE_READS_FILE.lock" || exit 1
    flock -x 9 || exit 1
    IFS= read -r used < "$TICK_INTAKE_READS_FILE" || used=0
    [[ "$used" =~ ^[0-9]+$ ]] || used=0
    if (( used >= cap )); then
      marker="$TICK_INTAKE_READS_FILE.reached"
      if ( set -o noclobber; : > "$marker" ) 2>/dev/null; then say "intake remote read cap reached cap=$cap"; fi
      exit 75
    fi
    printf '%s\n' "$((used + 1))" > "$TICK_INTAKE_READS_FILE"
  )
}
intake_gh_read() {
  intake_remote_read_reserve || return $?
  local started=$SECONDS rc=0
  "${TICK_INTAKE_GH_INVOKE:-gh}" "$@" || rc=$?
  (( SECONDS - started < 2 )) || say "intake detail gh_${1:-read}_${2:-query} secs=$((SECONDS - started))s"
  return "$rc"
}
issue_skip_labels() {
  jqf -cn --arg hotfix "$(hotfix_lane_label)" \
    '["on-hold","needs-info","awaiting-release","ready-for-human","needs-owner","needs-advisor","needs-triage","roadmap-epic","roadmap-theme","roadmap","concluded","needs-recut","checks-blocked","awaiting-pipeline-sync","hotfix","opt-lane","session-owned",$hotfix] | unique'
}
issue_unit_task() { # issue [fetched issue JSON | require-ready] → implement 任务文本
  local json body task body_blocked_by skip_labels labels
  if [[ "${2:-}" == require-ready ]]; then
    json="$(intake_gh_read issue view "$1" --json number,title,body,state,labels,subIssuesSummary,blockedBy 2>/dev/null)" || return 1
    skip_labels="$(issue_skip_labels)"
    jqf -e --argjson skip "$skip_labels" '.state == "OPEN" and any(.labels[]; .name == "ready-for-agent") and ([.labels[].name] - $skip) == [.labels[].name]' <<<"$json" >/dev/null || return 1
  else
    json="${2:-}"
    [[ -n "$json" ]] || json="$(intake_gh_read issue view "$1" --json number,title,body,subIssuesSummary,blockedBy 2>/dev/null)" || return 1
  fi
  body="$(jqf -r '.body // ""' <<<"$json")"
  # A native link is a declared predecessor too: left out, the unit starts and a worker refuses it after a paid run.
  body_blocked_by="$({ blocked_by_ids_from_body <<<"$body"; jqf -r '(.blockedBy.nodes // [])[] | select(.state == "OPEN") | .number' <<<"$json"; } | awk '!p[$0]++' | jqf -Rn '[inputs | select(length>0) | tonumber]')"
  task="$(jqf -r '"你是 the product 流水线的实现 subagent，处理 issue #\(.number)：\(.title)\n\n--- issue 正文（任务数据）---\n\((.body // "")[0:6000])\n--- 正文结束 ---\n用 gh issue view \(.number) 看评论与最新状态。修复根因并补回归测试。"' <<<"$json")"
  labels="$(jqf -c '[.labels[]? | if type == "string" then . else (.name // empty) end]' <<<"$json")"
  jqf -cn --arg task "$task" --argjson body_blocked_by "$body_blocked_by" --argjson labels "$labels" '{task:$task,body_blocked_by:$body_blocked_by,labels:$labels}'
}
# The per-row reads below run about 100 times a tick and read none of the bulk fields: history, task and review_findings
# are most of units.json, and parsing them took more than half of a 1800s tick. Rebuilt whenever units.json changes.
# It spans live + archived units (units_history_doc): retirement always rewrites units.json after the archive, so the mtime check holds.
intake_units_view() {
  local view="$UNITS.view"
  if [[ ! "$view" -nt "$UNITS" ]]; then
    units_history_doc | jqf -c '.units |= map(del(.history, .task, .review_findings))' > "$view.tmp.$$" && mv -f -- "$view.tmp.$$" "$view" || {
      rm -f -- "$view.tmp.$$"; printf '%s' "$UNITS"; return 0
    }
  fi
  printf '%s' "$view"
}
intake_candidates() { # 打印 "number<TAB>lane<TAB>title"，按优先级排序；refill 复用近 10 分钟的候选缓存，缓存失效时最多查一个标签
  local refill_mode="${1:-false}" skip_labels candidate_labels query_dir lane label query_file pid index=0 expected_queries=0 cache_file="$A/intake-candidates.json" cached_at now cache_rows cache_read_status
  local cache_token="$BASHPID.$RANDOM" cache_rows_tmp cache_valid_tmp cache_json_tmp
  local -a query_files=() query_lanes=() query_pids=()
  cache_rows_tmp="$cache_file.rows.$cache_token.tmp"
  cache_valid_tmp="$cache_file.valid.$cache_token.tmp"
  cache_json_tmp="$cache_file.$cache_token.tmp"
  if [[ "$refill_mode" == true ]]; then
    cached_at="$(jqf_optional_file "$cache_file" -r '.created_at // empty' 2>/dev/null || true)"
    now="$(date +%s)"
    if [[ "$cached_at" =~ ^[0-9]+$ ]] && (( now >= cached_at && now - cached_at <= 600 )) \
      && jqf_optional_file "$cache_file" -e '.schema == 4 and (.rows | type == "string")' >/dev/null 2>&1; then
      if cache_rows="$(jqf_optional_file "$cache_file" -r '.rows')"; then
        printf '%s\n' "$cache_rows"
        return 0
      else
        cache_read_status=$?
        (( cache_read_status == 64 )) || return "$cache_read_status"
      fi
    fi
  fi
  skip_labels="$(issue_skip_labels)"
  if [[ "$refill_mode" == true ]]; then
    candidate_labels="$(jqf -r '[((.issue_intake.product_labels // ["ready-for-agent"])[] | ["pr", .]), ((.issue_intake.labels // [])[] | ["direct-main", .])] | .[] | @tsv' <<<"$CFG")"
  else
    candidate_labels="$(jqf -r '[((.issue_intake.labels // [])[] | ["direct-main", .]), ((.issue_intake.product_labels // ["ready-for-agent"])[] | ["pr", .])] | .[] | @tsv' <<<"$CFG")"
  fi
  expected_queries="$(awk 'NF {n++} END {print n+0}' <<<"$candidate_labels")"
  if [[ "$refill_mode" == true ]] && (( expected_queries > 1 )); then expected_queries=1; fi
  rm -f -- "$cache_valid_tmp"
  (
    query_dir="$(mktemp -d)" || exit 1
    chain_exit_trap 'rm -rf -- "$query_dir"'
    local valid_queries=0
    # 标签列表有界并行取（GH_PARALLEL）。
    while IFS=$'\t' read -r lane label; do
      [[ -n "$lane" && -n "$label" ]] || continue
      [[ "$refill_mode" != true || $index -lt 1 ]] || break
      query_file="$query_dir/$index.json"
      intake_gh_read issue list --state open --label "$label" --limit 200 --json number,title,body,state,labels,subIssuesSummary,blockedBy >"$query_file" 2>/dev/null &
      query_pids+=("$!"); query_files+=("$query_file"); query_lanes+=("$lane")
      gh_par_throttle query_pids
      index=$((index + 1))
    # 10-30 maintainer (#4724): pipeline-system tickets are the supervisor's (opt feeder), never this intake; no direct-main label by default.
    done <<<"$candidate_labels"
    for pid in "${query_pids[@]}"; do wait "$pid" || :; done
    for query_file in "${query_files[@]}"; do
      jqf -e 'type == "array"' "$query_file" >/dev/null 2>&1 && valid_queries=$((valid_queries + 1))
    done
    {
      for ((index = 0; index < ${#query_files[@]}; index++)); do
        jqf -c --arg lane "${query_lanes[$index]}" '.[] | . + {lane:$lane}' "${query_files[$index]}" || true
      done
    } | jqf -cs '.' \
      | PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}" python3 -c '
import json, sys
import founder_reqs
rows = json.load(sys.stdin)
prefix = founder_reqs.configured_anomaly_prefix()
for row in rows:
    row["_auto_filed"] = founder_reqs.is_auto_filed_ticket(row, prefix)
json.dump(rows, sys.stdout, separators=(",", ":"))
' | tee "$query_dir/rows.json" | jqf -r --argjson skip "$skip_labels" '
      def rank: [.labels[].name] as $n
        | if ($n | index("founder-test")) then 0 elif ($n | index("priority:top")) then 1
          elif ($n | index("critical-path")) then 2  # 批次 STATE 的关键路径（#4363）：排在普通功能前、遗留后
          elif ($n | index("focus")) then 3 elif ($n | index("finish-first")) then 4 elif ($n | index("bug")) then 5
          elif ($n | index("legacy")) then 7 else 6 end;
      map(select(([.labels[].name] - $skip) == [.labels[].name]))
      | group_by(.number) | map(sort_by(.lane) | .[0])
      | sort_by([rank, (if ._auto_filed then 1 else 0 end), -.number])
      | .[] | "\(.number)\t\(.lane)\t\(.title | gsub("\t"; " "))\t\([.labels[].name] | tojson)\t\({number,title,body,state,labels,subIssuesSummary,blockedBy} | @base64)"'
    intake_skip_label_report "$query_dir/rows.json" "$skip_labels"
    if (( valid_queries == expected_queries && ${#query_files[@]} == expected_queries )); then : >"$cache_valid_tmp"; fi
  ) >"$cache_rows_tmp"
  if [[ -f "$cache_valid_tmp" ]]; then
    rm -f -- "$cache_valid_tmp"
    now="$(date +%s)"
    if jqf -Rs --argjson created_at "$now" '{schema:4,created_at:$created_at,rows:rtrimstr("\n")}' \
      <"$cache_rows_tmp" >"$cache_json_tmp" && mv -f -- "$cache_json_tmp" "$cache_file"; then
      if [[ "$refill_mode" != true && -n "${INTAKE_FULL_SCAN_FLAG:-}" ]]; then : > "$INTAKE_FULL_SCAN_FLAG"; fi
    else
      rm -f -- "$cache_json_tmp"
    fi
  fi
  cat "$cache_rows_tmp" 2>/dev/null || true
  [[ -s "$cache_rows_tmp" ]] || printf '\n'
  rm -f -- "$cache_rows_tmp"
}
predecessor_candidates() { # 停在前置上的单元：先把前置 issue 批量拉进来（拓扑顺序）
  local dep issue skip_labels q response start
  local -a deps=() deps_filtered=() chunk=()
  local -A issue_in_ledger=()
  skip_labels="$(issue_skip_labels)"
  mapfile -t deps < <(jqf -r '[.units[] | select(.stage=="blocked-external" and .blocked_on != null) | .blocked_on] | unique | .[]' "$UNITS")
  while IFS= read -r issue; do [[ "$issue" =~ ^[0-9]+$ ]] && issue_in_ledger["$issue"]=1; done \
    < <(jqf -r '[.units[].issue | numbers] | unique | .[]' <(units_history_index))
  for dep in "${deps[@]}"; do
    [[ "${issue_in_ledger[$dep]:-}" == 1 ]] || deps_filtered+=("$dep")
  done
  for ((start=0; start<${#deps_filtered[@]}; start+=20)); do
    chunk=("${deps_filtered[@]:start:20}"); q=""
    for dep in "${chunk[@]}"; do
      [[ "$dep" =~ ^[0-9]+$ ]] || continue
      q+=" i$dep: issue(number: $dep) { number title body state labels(first: 100) { nodes { name } } blockedBy(first: 50) { nodes { number state } } }"
    done
    [[ -n "$q" ]] || continue
    response="$(intake_gh_read api graphql -F owner='{owner}' -F name='{repo}' -f query="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {$q} }" 2>/dev/null)" || continue
    jqf -r --argjson skip "$skip_labels" '
      [.data.repository | to_entries[] | .value | select(type=="object")
        | {number,title,body:(.body // ""),state,labels:[.labels.nodes[]? | {name}],blockedBy}]
      | sort_by(.number)[] | select(.state=="OPEN")
      | select(([.labels[].name] - $skip) == [.labels[].name])
      | "\(.number)\t\(if any(.labels[]; .name=="pipeline-system") then "direct-main" else "pr" end)\t\(.title | gsub("\t"; " "))\t\([.labels[].name] | tojson)\t\(. | @base64)"' <<<"$response"
  done
}
intake_footprint_snapshot() { # footprint holders under the shared stage rule: live writers plus queued writers
  local tmpdir active active_file owners_file candidates_file owner_rows_file scope_file unit id stage encoded
  tmpdir="$(mktemp -d)" || return 1
  active_file="$tmpdir/active-owners.json"
  owners_file="$tmpdir/owners.json"
  candidates_file="$tmpdir/candidates.jsonl"
  owner_rows_file="$tmpdir/owner-rows.jsonl"
  scope_file="$tmpdir/scope.json"
  active="$(active_footprint_snapshot)" || { rm -rf -- "$tmpdir"; return 1; }
  jqf -c 'map({id,stage,footprint})' <<<"$active" > "$active_file" \
    || { rm -rf -- "$tmpdir"; return 1; }
  jqf -c '.[]' "$active_file" > "$owner_rows_file" \
    || { rm -rf -- "$tmpdir"; return 1; }
  # Read units.json once. The streamed full unit is used only to calculate its
  # footprint; the persisted owner census contains id, stage, and footprint.
  jqf -r --argjson queued "$FOOTPRINT_QUEUED_WRITER_STAGES" --slurpfile owners "$active_file" '.units[]
    | select(.stage as $s | $queued | index($s) != null)
    | select((.supervisor_owned // false) != true)
    | select(.stage != "implement-pending" or (.task // "") != "")
    | select(. as $u | (any($owners[0][]; .id==$u.id) | not))
    | select(((.history // [] | last // {}) as $last
        | $last.stage == "supervisor-escalated"
          and (($last.result // "") | startswith("size admission:"))) | not)
    | [.id,.stage,(. | @base64)] | @tsv' "$UNITS" > "$candidates_file" \
    || { rm -rf -- "$tmpdir"; return 1; }
  while IFS=$'\t' read -r id stage encoded; do
    [[ -n "$id" && -n "$encoded" ]] || continue
    unit="$(printf '%s' "$encoded" | base64 -d)" \
      || { rm -rf -- "$tmpdir"; return 1; }
    scheduler_footprint "$unit" > "$scope_file" \
      || { rm -rf -- "$tmpdir"; return 1; }
    jqf -cn --arg id "$id" --arg stage "$stage" --slurpfile scope "$scope_file" \
      '{id:$id,stage:$stage,footprint:$scope[0]}' >> "$owner_rows_file" \
      || { rm -rf -- "$tmpdir"; return 1; }
  done < "$candidates_file"
  jqf -cs '.' "$owner_rows_file" > "$owners_file" || { rm -rf -- "$tmpdir"; return 1; }
  if ! cat "$owners_file"; then rm -rf -- "$tmpdir"; return 1; fi
  rm -rf -- "$tmpdir"
}
intake_eligible_filter() { # Shared jq predicate for startable pending and eligible upstream units.
  cat <<'JQ'
    | select((.footprint_wait_owner // "") == "")
    | select((.supervisor_owned // false) != true)
    | select(((.history // [] | last // {}) as $last
        | $last.stage == "supervisor-escalated"
          and (($last.result // "") | startswith("size admission:"))) | not)
JQ
}
startable_pending_count() { # pending units eligible to start under intake's #153 capacity predicate
  footprint_waiters_revalidate || return 1
  jqf "[.units[] | select(.stage | test(\"-pending$\")) $(intake_eligible_filter)] | length" "$UNITS"
}
# station_health.py reads this marker so a pass that took nothing on purpose is HELD, not STALLED. It keeps the hold's first
# time (a long hold is measured from its start) and goes when a pass gets past the held checks, which is when intake can add.
intake_hold_mark() { [[ -e "$A/intake-held-since" ]] || date -u +%Y-%m-%dT%H:%M:%SZ > "$A/intake-held-since"; }
intake_skip() { intake_skip_counts[$1]=$(( ${intake_skip_counts[$1]:-0} + 1 )); intake_mark "skip_$1"; } # bumps register_new_issues' local intake_skip_counts (dynamic scope); a skipped row's time goes to skip_<reason>
intake_census_prime() { # the open-PR census the handoff block reads; register_new_issues calls it, and so does a tick that left the walk to the existing-walk station
  local cached_prs pr_number
  HANDOFF_CENSUS_PARTIAL=0; HANDOFF_WAIT_PRS='[]'; HANDOFF_WAIT_BRANCHES='[]'
  tick_prs_prime
  cached_prs="$(tick_prs 2>/dev/null || true)"
  if [[ -n "$cached_prs" ]] && jqf -e 'type=="array" and length < 300' <<<"$cached_prs" >/dev/null; then
    HANDOFF_PR_CENSUS="$(jqf -c '[.[] | {number,headRefName,title,body,labels}]' <<<"$cached_prs")"
  else
    HANDOFF_PR_CENSUS="$(intake_gh_read pr list --state open --limit 500 --json number,headRefName,title,body,labels 2>/dev/null)" || HANDOFF_PR_CENSUS=""
  fi
  jqf -e 'type == "array" and all(.[]; (.number | type)=="number" and (.labels | type)=="array" and all(.labels[]; (.name | type)=="string"))' <<<"${HANDOFF_PR_CENSUS:-}" >/dev/null || HANDOFF_PR_CENSUS=""
  if [[ -z "$HANDOFF_PR_CENSUS" ]]; then
    HANDOFF_CENSUS_PARTIAL=1; HANDOFF_PR_CENSUS='[]'
    while read -r pr_number; do handoff_include_pr "$pr_number" || true; done < <(jqf -r '[.units[] | select((.stage | IN("merged","landed","closed","done","wontfix","duplicate")) | not) | .pr | select(type=="number")] | unique | .[]' "$UNITS")
  else
    units_update '.units |= map(if .hold_handoff_lookup_pending == true then del(.hold_handoff_lookup_pending) | if ((.hold_handoff_wait_issues // []) | length) == 0 then del(.hold_handoff_waiting) else . end else . end)'
  fi
}
register_new_issues() {
  local enabled live pending upstream total_upstream total_room max_up ready_q max_ready want added=0 n lane title labels task_record task body_blocked_by branch busy handoff state_file acceptance
  local episode existing_id existing_pr prior_pr pr_changed pr_state lane_policy handoff_all handoff_pr handoff_branch recovery_sha
  local cached_prs busy_prs issue64
  local existing_only="${1:-0}" only_pred=0 ids lookup handoff_rows matches ids_state pr_number known_prs known_failed hotfix_prs prior_worktree prior_reason episode_hash related_id related_hash unsafe_clones
  local issue_json parent_reason parent_status parent_step parent_transition_status intake_footprint_owners='[]' intake_candidate_json intake_candidate_scope intake_candidate_stage intake_conflict state_read_status state_read_value
  local refill_mode="${2:-false}" free_slots ready_buffer target_pending max_refill upstream_room
  local intake_budget intake_left intake_started=$SECONDS step_started=$SECONDS candidate_started full_at now fresh_seconds existing_issue
  local l_ambiguous wait_ops='' wait_ops_on=1 ix_sig='' ix_ok=0 cx_src=$'\001' cx_ok=0 lookup_fast=0 known_prs known_list=() hotfix_prs l_amb l_hot l_count l_first_pr l_first_head l_ids l_hotpath row_consumed lookup_rc
  local -A ix_issue=() ix_branch=() ix_pr=() ix_ref=() cx_issue=() cx_has=() cx_hotnum=() cx_bynum=(); local -a ix_id=() ix_stage=() ix_prn=() ix_ep=() ix_prnum=() ix_iany=() cx_num=() cx_amb=() cx_hotf=() cx_head=() cx_ent=() cx_entf=()
  local walk_cursor="$A/intake-existing-cursor" walk_from walk_start='' walk_rows=0 walk_broke=''
  local INTAKE_FULL_SCAN_FLAG="$A/.intake-full-scan.$BASHPID.$RANDOM"
  local -A intake_known_issues=() intake_skip_counts=() intake_step_secs=() intake_step_counts=()
  local intake_step_at=$SECONDS skip_key skip_line step_name step_line
  [[ "$refill_mode" != true ]] || refill_room register_new_issues || return 0
  if [[ "$refill_mode" == true ]]; then
    fresh_seconds="$(jqf -r '.issue_intake.refill_full_tick_fresh_seconds // 600' <<<"$CFG")"
    [[ "$fresh_seconds" =~ ^[0-9]+$ ]] || fresh_seconds=600
    full_at="$(cat "$A/intake-full-tick-at" 2>/dev/null || true)"
    now="$(date +%s)"
    if [[ "$full_at" =~ ^[0-9]+$ ]] && (( fresh_seconds > 0 && now >= full_at && now - full_at <= fresh_seconds )); then
      say "intake detail refill_skip age=$((now - full_at))s bound=${fresh_seconds}s"
      return 0
    fi
  fi
  if [[ "$refill_mode" == true ]]; then
    # Refill has no full handoff census; keep known-PR fallbacks partial and avoid another PR-list request.
    HANDOFF_PR_CENSUS="${HANDOFF_PR_CENSUS:-[]}"
    HANDOFF_CENSUS_PARTIAL="${HANDOFF_CENSUS_PARTIAL:-1}"
    HANDOFF_WAIT_PRS="${HANDOFF_WAIT_PRS:-[]}"
    HANDOFF_WAIT_BRANCHES="${HANDOFF_WAIT_BRANCHES:-[]}"
  fi
  [[ "$refill_mode" == true ]] || hotfix_issue_numbers >/dev/null || say "hotfix issue list unavailable; linked issue PRs may not be classified this tick"
  enabled="$(jqf -r 'if .issue_intake.enabled == false then "false" else "true" end' <<<"$CFG")"
  [[ "$enabled" == true || "$existing_only" == 1 ]] || return 0
  max_up="$(jqf -r ".issue_intake.max_upstream // $((2 * MAX))" <<<"$CFG")"; [[ "$max_up" =~ ^[0-9]+$ ]] || max_up=$((2 * MAX))
  if (( existing_only )); then
    # Existing units may consume their handoff at the normal cap, subject to the total ceiling.
    handoff_rows="$(existing_handoff_candidates)"
    [[ -n "$handoff_rows" ]] || { INTAKE_WALK_LAP=true; return 0; }
    # Numeric order, so a stored cursor resumes at the first row at or after it even when that row is gone; the rows before it come last (wrap).
    handoff_rows="$(sort -s -n -k1,1 <<<"$handoff_rows")"
    walk_from="$(cat "$walk_cursor" 2>/dev/null || true)"
    if [[ "$walk_from" =~ ^[0-9]+$ ]]; then
      handoff_rows="$(awk -F'\t' -v c="$walk_from" '$1+0 >= c' <<<"$handoff_rows"; awk -F'\t' -v c="$walk_from" '$1+0 < c' <<<"$handoff_rows")"
    fi
    walk_start="${handoff_rows%%$'\t'*}"
    INTAKE_EXISTING_WALKED=()
    [[ "${2:-}" == reuse ]] || intake_census_prime # the open-PR census the handoff block reads (also primed by the tick when the station walked)
    want=1000000000; busy=""
  else
  live="$(live_workers)"
  # Keep this predicate in one place: footprint waiters, supervisor-owned units,
  # and the most recently size-refused units do not consume startable capacity.
  pending="$(startable_pending_count)"
  max_ready="$(jqf -r '.issue_intake.max_ready // 30' <<<"$CFG")"; [[ "$max_ready" =~ ^[0-9]+$ ]] || max_ready=30
  if [[ "$refill_mode" == true ]]; then
    free_slots=$(( MAX - live ))
    (( free_slots > 0 && pending < free_slots )) || return 0
    max_refill="$(jqf -r '.issue_intake.refill_max // 2' <<<"$CFG")"; [[ "$max_refill" =~ ^[0-9]+$ ]] || max_refill=2
    want=$(( free_slots - pending ))
    (( want <= max_refill )) || want=$max_refill
    (( want > 0 )) || return 0
  else
    ready_buffer="$(jqf -r --argjson max "$MAX" '.issue_intake.ready_buffer // $max' <<<"$CFG")"; [[ "$ready_buffer" =~ ^[0-9]+$ ]] || ready_buffer="$MAX"
    target_pending=$(( MAX - live + ready_buffer ))
    want=$(( target_pending - pending ))
    (( want > 0 )) || { intake_hold_mark; say "intake held: startable pending $pending meets target $target_pending (live $live max $MAX)"; return 0; }
  fi
  upstream="$(jqf "[.units[] | select(.stage | test(\"^(implement|review|rereview|repair)(-pending)?$\")) $(intake_eligible_filter)] | length" "$UNITS")"
  total_upstream="$(jqf '[.units[] | select(.stage | test("^(implement|review|rereview|repair)(-pending)?$"))] | length' "$UNITS")"
  total_room=$(( 2 * max_up - total_upstream ))
  (( total_room > 0 )) || { intake_hold_mark; say "intake held: $total_upstream total units upstream (ceiling $((2 * max_up)))"; return 0; }
  (( want <= total_room )) || want=$total_room
  ready_q="$(jqf '[.units[] | select(.stage=="ready-to-merge" or .stage=="landing")] | length' "$UNITS")"
  upstream_room=$(( max_up - upstream ))
  # 合并车道约束时仍只收阻塞在前置上的 issue；与旧路径相同，这种解阻候选不受 max_upstream 限制。
  if (( ready_q >= max_ready )); then
    say "intake held: $ready_q units wait to merge (max_ready $max_ready); the merge lane is the constraint; predecessors still admitted"
    only_pred=1
  elif (( upstream_room < want )); then
    want=$upstream_room
  fi
  (( want > 0 )) || { intake_hold_mark; say "intake held: $upstream units upstream (max_upstream $max_up)"; return 0; }
  rm -f -- "$A/intake-held-since"
  # 只按可启动 pending 计目标；footprint 重叠只排序（dispatch 先派不重叠的），不再筛掉候选。
  # 已有 open PR 的 issue 不再收（#3957 已由 #3958 实现，分支名却不是 agent/issue-N）：看分支、标题和正文里是否提到它。
  # Now (intake_open_pr_holds): the branch is agent/issue-N, or a body line starts with Refs/Fixes/Closes/Resolves #N. A title or prose mention holds nothing.
  if [[ -n "${HANDOFF_PR_CENSUS:-}" && "${HANDOFF_CENSUS_PARTIAL:-0}" != 1 ]]; then
    busy="$(intake_busy_text <<<"$HANDOFF_PR_CENSUS")"
  else
    tick_prs_prime
    busy_prs="$(tick_prs 2>/dev/null)" || busy_prs=""
    if [[ -n "$busy_prs" ]]; then
      busy="$(intake_busy_text <<<"$busy_prs")"
    else
      busy_prs="$(intake_gh_read pr list --state open --limit 200 --json headRefName,title,body 2>/dev/null)" || return 0
      busy="$(intake_busy_text <<<"$busy_prs")"
    fi
  fi
  fi
  if (( ! existing_only )); then
    say "intake detail capacity_and_census secs=$((SECONDS - step_started))s"
    step_started=$SECONDS
    while IFS= read -r existing_issue; do
      [[ "$existing_issue" =~ ^[0-9]+$ ]] && intake_known_issues["$existing_issue"]=1
    done < <(jqf -r '.units[].issue | numbers' "$UNITS")
    intake_footprint_owners="$(intake_footprint_snapshot)" || {
      say "intake held: could not refresh footprint owners"
      return 0
    }
  fi
  say "intake detail footprint_snapshot secs=$((SECONDS - step_started))s"
  step_started=$SECONDS
  local -a intake_terminal_rows=()
  # A slow row must not cost the tick: refill is killed at 300s and dispatch still runs after this loop. Rows left wait a tick.
  intake_budget="${ISSUE_INTAKE_BUDGET_SECONDS:-$([[ "$refill_mode" == true ]] && echo 150 || { (( existing_only )) && echo "${ISSUE_INTAKE_EXISTING_BUDGET_SECONDS:-240}" || echo 600; })}"
  if [[ "$refill_mode" == true ]]; then # the kill counts from the tick's start: a 141s merge pass left this budget 87s of its 150 on 2026-11-07
    intake_left=$(( ${AUTOPI_REFILL_LIMIT_SECONDS:-300} - intake_started - 30 ))
    (( intake_budget <= intake_left )) || intake_budget=$(( intake_left > 0 ? intake_left : 0 ))
  fi
  while IFS=$'\t' read -r n lane title labels issue64; do
    intake_step_at=$SECONDS; [[ "$n" =~ ^[0-9]+$ ]] || { intake_skip badrow; continue; }
    (( added < want )) || break
    refill_stopped && break # a refused ledger lock wait ended the refill
    # The existing walk always takes its first row, so a census longer than the budget still moves the cursor.
    (( SECONDS - intake_started < intake_budget || (existing_only && walk_rows == 0) )) || { say "intake budget spent after ${intake_budget}s: rows from #$n wait for the next tick"; walk_broke="$n"; intake_skip budget; break; }
    walk_rows=$((walk_rows+1))
    intake_candidate_json=''; intake_candidate_scope=''; intake_conflict=''
    issue_json=""
    [[ -n "$issue64" ]] && issue_json="$(printf '%s' "$issue64" | base64 -d 2>/dev/null)" || true
    state_file="${AGENT_HOME:-${HOME:-}/.zenoforge}/state/$n.json"
    # Existing ordinary issues are already registered. Preserve the handoff path
    # whenever any state file exists, including unreadable or malformed files.
    if (( ! existing_only )) && [[ "${intake_known_issues[$n]:-}" == 1 && ! -e "$state_file" && ! -L "$state_file" ]]; then
      intake_skip known; continue
    fi
    episode=""; handoff_all='{}'; handoff_pr=""; handoff_branch=""; handoff=''
    # One read of the state file gives every field the row needs: episode, handoff record, its PR and branch, and the rescued start (unit-separator joined).
    if state_read_value="$(jqf_optional_file "$state_file" -j --arg n "$n" '
        (.state == "ready-for-agent") as $ready
        | (if $ready then (.scheduler_handoff // {}) else {} end) as $ha
        | [ (if $ready then (.scheduler_handoff.episode // "") else "" end), ($ha | tojson), ($ha.open_pr // ""), ($ha.open_branch // ""),
            (((.scheduler_handoff // {}) | select((.start_ref // "") | test("^rescued/.*(issue-|hand-)" + $n + "([^0-9]|$)")) | select((.start_sha // "") | test("^[0-9a-f]{40}$")) | tojson) // "") ]
        | map(if type == "string" then . else tojson end) | join("\u001f")' 2>/dev/null)"; then
      IFS=$'\037' read -r -d '' episode handoff_all handoff_pr handoff_branch handoff <<<"$state_read_value" || true
      handoff="${handoff%$'\n'}"
    else
      state_read_status=$?
      (( state_read_status == 64 )) || { intake_ops_flush; return "$state_read_status"; }
    fi
    [[ -n "$handoff_all" ]] || handoff_all='{}'
    intake_mark state_read
    if (( ! existing_only )); then intake_ops_flush; fi # the recut reopen writes wait marks too
    (( existing_only )) || ! intake_reopen_refused_recut "$n" "$state_file" || { intake_skip recut_reopen; continue; }
    # A row whose units are all terminal and whose episode (if any) is consumed has nothing to hand off:
    # skip it from the ledger before the handoff path reads PRs (gh pr view per merged PR).
    if (( ! existing_only )) && intake_row_terminal "$n" "$episode"; then
      intake_terminal_rows+=("$n"); intake_skip terminal; continue
    fi; intake_mark terminal_check
    if (( existing_only )); then
      intake_unit_for_row "$n" "$handoff_pr"; intake_mark recut_refused_precheck
      [[ -z "$existing_id" ]] || ! intake_recut_refused "$existing_id" || { intake_skip_refused_recut "$n" "$existing_id"; continue; }
    fi
    # The existing-only walk already took this row through the block below this tick, with the same ledger, census and state file, and the
    # new-issue walk adds nothing for an issue that has a unit (it ends at skip_existing): a repeat would be 6 gh/jq/ledger calls per row for nothing.
    # A unit found only by the recorded PR still goes the long way: handoff_pr is rewritten inside the block.
    if (( ! existing_only )) && [[ -n "$episode" && "${INTAKE_EXISTING_WALKED[$n]:-}" == ok ]] \
      && [[ "$n" =~ ^(0|[1-9][0-9]*)$ ]] && intake_index_load && [[ -n "${ix_issue[$n]:-}" ]]; then
      intake_skip existing; continue
    fi
    if [[ -n "$episode" ]]; then
      lookup_fast=0
      if [[ "$n" =~ ^(0|[1-9][0-9]*)$ ]] && intake_index_load && intake_census_load; then lookup_fast=1; fi
      if (( existing_only )); then
        # An unavailable PR lookup must not release an already known unit's old approval.
        if (( lookup_fast )) && ! intake_units_other_episode "$n" "$episode"; then :; else
          intake_op "$(jqf -cn --argjson n "$n" --arg episode "$episode" '{k:"ep",n:$n,episode:$episode}')"
        fi
      fi
      # Recorded PRs can be outside the census or attached to an existing unit.
      # Read their current labels before reusing them, rather than inferring
      # ownership from an old hold snapshot.
      if (( lookup_fast )) && intake_known_prs "$n" "$handoff_pr"; then :; else
        known_prs="$(jqf -c --argjson n "$n" --arg pr "$handoff_pr" '
          ([.units[] | select(.issue == $n or .branch == ("agent/issue-" + ($n | tostring))) | .pr | select(type == "number")]
            + (if ($pr | test("^[0-9]+$")) then [($pr | tonumber)] else [] end)) | unique' "$(intake_units_view)")"
        mapfile -t known_list < <(jqf -r '.[]' <<<"$known_prs")
      fi
      known_failed=0
      for pr_number in "${known_list[@]}"; do
        if ! intake_pr_in_census "$pr_number"; then
          handoff_include_pr "$pr_number" || known_failed=1
        fi
      done
      if (( known_failed )); then
        HANDOFF_WAIT_PRS="$(jqf -c --slurpfile add <(printf '%s' "$known_prs") '. + $add[0] | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
        HANDOFF_WAIT_BRANCHES="$(jqf -c --arg branch "$handoff_branch" 'if $branch == "" then . else (. + [$branch] | unique) end' <<<"${HANDOFF_WAIT_BRANCHES:-[]}")"
        intake_op "$(printf '{"k":"wb","n":%s,"prs":%s}' "$n" "$known_prs")"
        intake_skip handoff_wait; continue
      fi
      if [[ "$handoff_pr" =~ ^[0-9]+$ ]] && ! intake_pr_in_census "$handoff_pr"; then
        handoff_pr=""; handoff_branch=""
      fi
      # A PR can appear after the handoff, or use a non-agent branch.
      lookup_rc=2
      if (( lookup_fast )); then intake_lookup_fast "$n" "$handoff_pr" && lookup_rc=0 || lookup_rc=$?; fi
      if (( lookup_rc == 1 )); then
        # no census text: handoff_open_pr would have failed
        [[ -n "$handoff_pr" ]] || { intake_skip handoff_lookup; continue; }
        lookup='[]'; lookup_rc=3 # the read failed but a handoff PR is recorded: go on with no rows
      fi
      if (( lookup_rc >= 2 )); then
        lookup_fast=0
        if (( lookup_rc == 2 )); then
          lookup="$(handoff_open_pr "$n")" || { [[ -n "$handoff_pr" ]] && lookup='[]' || { intake_skip handoff_lookup; continue; }; }
        fi
        if [[ "$handoff_pr" =~ ^[0-9]+$ ]]; then
          lookup="$(jqf -c --argjson pr "$handoff_pr" --slurpfile census <(printf '%s' "${HANDOFF_PR_CENSUS:-[]}") '
            if any(.[]; .number == $pr) then . else
              . + [$census[0][] | select(.number == $pr) | {number,headRefName,ambiguousIssues:false,hotfix:any(.labels[]; .name == "hotfix")}]
            end' <<<"$lookup")"
        fi
        hotfix_prs="$(jqf -c --slurpfile prs <(printf '%s' "$known_prs") '[.[] | select(.number as $p | $prs[0] | index($p)) | select(any(.labels[]; .name == "hotfix")) | .number]' <<<"${HANDOFF_PR_CENSUS:-[]}")"
        l_hotpath=0
        if jqf -e --slurpfile known <(printf '%s' "$hotfix_prs") 'any(.[]; .hotfix == true) or ($known[0] | length > 0)' <<<"$lookup" >/dev/null; then l_hotpath=1; fi
      fi
      if (( l_hotpath )); then
        ids="$(jqf -c --slurpfile known <(printf '%s' "$hotfix_prs") '([.[].number] + $known[0]) | unique' <<<"$lookup")"
        HANDOFF_WAIT_PRS="$(jqf -c --slurpfile add <(printf '%s' "$ids") '. + $add[0] | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
        HANDOFF_WAIT_BRANCHES="$(jqf -c --slurpfile prs <(printf '%s' "$ids") --slurpfile census <(printf '%s' "${HANDOFF_PR_CENSUS:-[]}") --arg branch "$handoff_branch" '
          . + [$census[0][] | select(.number as $p | $prs[0] | index($p)) | .headRefName | select(type=="string" and length>0)] + (if $branch == "" then [] else [$branch] end) | unique' <<<"${HANDOFF_WAIT_BRANCHES:-[]}")"
        intake_op "$(printf '{"k":"wb","n":%s,"prs":%s}' "$n" "$ids")"
        intake_skip hotfix_wait; continue
      fi
      # Clear this issue's wait from a PR once its successfully read association
      # no longer points here; other handoffs may still be waiting on the PR.
      if (( lookup_fast )); then ids="$l_ids"; else ids="$(jqf -c '[.[].number] | unique' <<<"$lookup")"; fi
      if [[ "${HANDOFF_CENSUS_PARTIAL:-0}" == 1 ]]; then
        # Individually read ledger PRs can protect their old approvals, but do not
        # establish that an unregistered PR for this issue does not also exist.
        # The clear and the add for this row are queued wait marks (intake_ops_flush applies them in order, once).
        HANDOFF_WAIT_PRS="$(jqf -c --slurpfile add <(printf '%s' "$ids") '. + $add[0] | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
        intake_op "$(printf '{"k":"clr","n":%s,"prs":%s}' "$n" "$ids")"
        intake_op "$(printf '{"k":"wa","n":%s,"prs":%s}' "$n" "$ids")"
        intake_skip census_partial; continue
      fi
      intake_op "$(printf '{"k":"clr","n":%s,"prs":%s}' "$n" "$ids")"
      if (( lookup_fast )); then
        matches=$l_count; l_ambiguous=$l_amb
      else
        matches="$(jqf 'length' <<<"$lookup")"; l_ambiguous=0
        if jqf -e 'any(.[]; .ambiguousIssues == true)' <<<"$lookup" >/dev/null; then l_ambiguous=1; fi
      fi
      if (( matches > 1 || l_ambiguous )); then
        ids="$(jqf -c '[.[].number] | sort' <<<"$lookup")"
        HANDOFF_WAIT_PRS="$(jqf -c --slurpfile add <(printf '%s' "$ids") '. + $add[0] | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
        ids_state="$(jqf -r 'map(tostring) | join("-")' <<<"$ids")"
        intake_op "$(printf '{"k":"wa","n":%s,"prs":%s}' "$n" "$ids")"
        (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "handoff-pr-ambiguous:$n:$ids" "handoff-pr-ambiguous issue=#$n status=prs-$ids_state prs=$ids") \
          || say "handoff issue #$n: could not notify supervisor about ambiguous PRs $ids"
        intake_skip pr_ambiguous; continue
      elif (( matches == 1 )); then
        if (( lookup_fast )); then
          handoff_pr="$l_first_pr"; handoff_branch="$l_first_head"
        else
          handoff_pr="$(jqf -r '.[0].number' <<<"$lookup")"
          handoff_branch="$(jqf -r '.[0].headRefName' <<<"$lookup")"
        fi
      fi
    fi; intake_mark handoff_lookup
    if (( existing_only )) && [[ -n "$episode" ]]; then INTAKE_EXISTING_WALKED["$n"]=ok; fi
    [[ -n "$handoff" ]] || handoff='{}'
    intake_unit_for_row "$n" "$handoff_pr"; intake_mark unit_lookup
    if [[ -n "$existing_id" ]]; then
      (( existing_only )) || { intake_skip existing; continue; }
      [[ -n "$episode" ]] || { intake_skip no_episode; continue; }
      # Recut refused and the one reopen is spent: this door must not undo that, or each refusal buys another pass through stop-loss and recut.
      if intake_recut_refused "$existing_id"; then
        intake_skip_refused_recut "$n" "$existing_id"; continue
      fi
      if intake_row_units "$n" "$handoff_pr" "$episode"; then :; else
        ids="$(jqf -c --argjson n "$n" --arg pr "$handoff_pr" '[.units[] | select(.issue == $n or ($pr != "" and ((.pr // "") | tostring) == $pr)) | .id]' "$(intake_units_view)")"
        row_consumed=0
        if jqf -e --argjson n "$n" --arg pr "$handoff_pr" --arg episode "$episode" 'all(.units[] | select(.issue == $n or ($pr != "" and ((.pr // "") | tostring) == $pr)); .hold_handoff_episode == $episode) and ($pr == "" or any(.units[]; ((.pr // "") | tostring) == $pr))' "$(intake_units_view)" >/dev/null; then row_consumed=1; fi
      fi
      if (( row_consumed )); then
        intake_op "$(printf '{"k":"cons","n":%s,"ids":%s}' "$n" "$ids")"
        intake_skip consumed; continue
      fi
      HANDOFF_WAIT_PRS="$(jqf -c --slurpfile add <(jqf -c '[.[].number]' <<<"$lookup") '. + $add[0] | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
      # A restore adds the unit row to the ledger: the queued marks go first, so they cannot reach the restored row. A unit already in the ledger needs no restore.
      if ! jqf -e --arg id "$existing_id" 'any(.units[]; .id == $id)' "$UNITS" >/dev/null 2>&1; then
        intake_ops_flush
        restore_archived_unit "$existing_id" || { intake_skip restore; continue; } # a retired unit must be hot before its lane and PR are read, and for the update below
      fi
      lane="$(unit_field "$existing_id" '.lane // empty')"
      # Block the old approval while any matching unit still has a live owner.
      units_update --slurpfile ids <(printf '%s' "$ids") --argjson n "$n" '.units |= map(if (.id as $id | $ids[0] | index($id)) != null then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting=true else . end)'
      jqf -e --slurpfile ids <(printf '%s' "$ids") 'any(.workers[]; (.unit as $id | $ids[0] | index($id)) != null and .harvested != true)' "$WORKERS" >/dev/null && { intake_skip worker_live; continue; }
      # A worker which has already started may have read the old issue; do not
      # consume the new episode until it exits and the continuation can run.
      jqf -e --slurpfile ids <(printf '%s' "$ids") 'any(.units[]; (.id as $id | $ids[0] | index($id)) != null and (.stage == "landing" or .self_check_pid != null or .advisor_pid != null or .precheck_pid != null or (.stage == "blocked-external" and .blocked_on != null)))' "$(intake_units_view)" >/dev/null && { intake_skip unit_busy; continue; }
      # Any related unit may contain work that the chosen unit cannot deliver.
      unsafe_clones=0
      episode_hash="$(printf '%s' "$episode" | sha256sum)"; episode_hash="${episode_hash%% *}"
      while IFS= read -r related_id; do
        prior_worktree="$WT_ROOT/wt-$related_id"
        if prior_reason="$(worktree_cleanup_block_reason "$prior_worktree")"; then
          if [[ "$related_id" == "$existing_id" ]]; then
            if rescue_handoff_clone "$n" "$prior_worktree" </dev/null; then
              say "handoff issue #$n: rescued $prior_worktree ($prior_reason)${RESCUE_START_REF:+ to $RESCUE_START_REF}"
              [[ -z "$RESCUE_START_REF" ]] || handoff="$(jqf -c --arg ref "$RESCUE_START_REF" --arg sha "$RESCUE_START_SHA" '.start_ref = $ref | .start_sha = $sha' <<<"$handoff")"
              continue
            fi
            if preserve_refused_clone "$n" "$related_id" "$prior_worktree"; then continue; fi
            prior_reason+="; not rescued: $RESCUE_REFUSED"
            say "handoff issue #$n: $prior_reason" # the inbox line is once per episode, so a later refusal shows only here
          fi
          unsafe_clones=1
          related_hash="$(printf '%s' "$related_id" | sha256sum)"; related_hash="${related_hash%% *}"
          (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "handoff-preserved-clone:$n:$episode:$related_id" \
            "handoff-preserved-clone issue=#$n status=episode-$episode_hash-unit-$related_hash unit=$related_id worktree=$prior_worktree reason=$prior_reason") \
            || say "handoff issue #$n: could not notify supervisor about the preserved clone"
        fi
      done < <(jqf -r '.[]' <<<"$ids")
      (( unsafe_clones == 0 )) || { intake_skip preserved_clone; continue; }
      prior_pr="$(unit_field "$existing_id" '.pr // empty')"
      existing_pr="$prior_pr"; pr_changed=false
      if [[ "$handoff_pr" =~ ^[0-9]+$ ]]; then existing_pr="$handoff_pr"; fi
      pr_state=""
      if [[ "$existing_pr" =~ ^[0-9]+$ ]]; then
        pr_state="$(tick_pr_state "$existing_pr")" || { intake_skip pr_state; continue; }
      fi
      if [[ "$pr_state" == OPEN ]]; then
        lane="$(classify_lane "$existing_pr")" || { say "hold handoff issue #$n: cannot classify PR#$existing_pr; retry next tick"; intake_skip classify; continue; }
        lane_policy="$(lane_policy_blob)"
        [[ "$existing_pr" == "$prior_pr" ]] || pr_changed=true
      else
        [[ -n "$lane" ]] || lane=pr
        pr_changed=true
      fi
    else
      if [[ -n "$episode" ]]; then
        HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$(jqf -c '[.[].number]' <<<"$lookup")" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
      fi
      (( existing_only )) && { intake_skip no_unit; continue; }
      intake_ops_flush
      if [[ -n "$episode" && "$handoff_pr" =~ ^[0-9]+$ && -n "$handoff_branch" ]]; then
        pr_state="$(tick_pr_state "$handoff_pr")" || { intake_skip pr_state; continue; }
        if [[ "$pr_state" == OPEN ]]; then
          lane="$(classify_lane "$handoff_pr")" || { say "hold handoff issue #$n: cannot classify PR#$handoff_pr; retry next tick"; intake_skip classify; continue; }
          lane_policy="$(lane_policy_blob)"
        else
          handoff_pr=""
        fi
      else
        handoff_pr=""
      fi
      [[ -n "$handoff_pr" ]] || ! intake_open_pr_holds "$n" "$handoff_branch" || { intake_skip open_pr; intake_skip_note "$n" "an open PR's branch, title or body names it"; continue; }
    fi
    if (( ! existing_only )) && [[ -z "$episode" ]]; then
      ! intake_parent_retry_waiting "$n" || { intake_skip parent_retry; continue; }
      [[ -n "$issue_json" ]] || issue_json="$(intake_gh_read issue view "$n" --json number,title,body,state,labels,subIssuesSummary,blockedBy 2>/dev/null)" || { intake_skip issue_read; continue; }; intake_mark issue_read
      scheduler_lib_context || true # prime here: the substitution below is a subshell and cannot cache
      if parent_reason="$(scheduler_issue_intake_parent_reason "$n" "$issue_json")"; then
        if scheduler_issue_transition "$n" needs-triage "intake-parent:$parent_reason" . 0 "$issue_json"; then
          say "intake issue #$n -> needs-triage (parent: $parent_reason)"
          intake_parent_retry_clear "$n"
        else
          parent_transition_status=$?
          local retry_step
          # roadmap_ensure_issue_parent returns 3 only for a confirmed roadmap container.
          if (( parent_transition_status == 3 )); then
            if scheduler_issue_transition "$n" tracker "intake-parent:roadmap-container:$parent_reason" '.tracker_parent = true' 0 "$issue_json"; then
              say "intake issue #$n -> tracker (roadmap container parent: $parent_reason)"
              intake_parent_retry_clear "$n"
            else
              retry_step="$(intake_parent_retry_failed "$n")" || retry_step="? ?"
              say "intake issue #$n held: roadmap container parent tracker update failed (attempt ${retry_step% *}, retry in ${retry_step#* }s)"
            fi
          else
            retry_step="$(intake_parent_retry_failed "$n")" || retry_step="? ?"
            say "intake issue #$n held: parent detected but needs-triage label update failed (attempt ${retry_step% *}, retry in ${retry_step#* }s)"
          fi
        fi
        intake_skip parent; continue
      else
        parent_status=$?
        if (( parent_status != 1 )); then
          intake_parent_unverified "$n" "$parent_status" "$issue_json" "$parent_reason"
          intake_skip parent_unverified; continue
        fi
        intake_parent_retry_clear "$n"
      fi
    fi; intake_mark parent_detect
    if (( ! existing_only )) && [[ -z "$episode" && -z "${existing_id:-}" && "$lane" == direct-main ]]; then
      acceptance="$(jqf -r '.body // ""' <<<"$issue_json" | acceptance_block_from_body || true)"
      # M5（#4501）：pipeline-system 票的验收块必须绑定 live-event 到登记机制，否则退回补写。
      if ! acceptance_has_live_event "${acceptance:-}" || ! acceptance_live_event_registered "${acceptance:-}"; then
        if scheduler_issue_transition "$n" needs-info "m5-live-event-missing" . 0 "$issue_json"; then
          gh issue comment "$n" --body "M5 生效即验收（#4495/#4501）：pipeline-system 票的验收块（\`\`\`json 围栏内的 acceptance 数组）必须包含一项 id=live-event，并通过 event 字段或登记表 acceptance_item_ids 绑定到 engine/state/mechanism-registry.json 中的机制。补写后重新加 ready-for-agent 标签。" >/dev/null 2>&1
          say "intake issue #$n -> needs-info (M5 live-event missing)"
        else
          say "intake issue #$n: M5 live-event relabel failed; retry next tick"
        fi
        intake_skip m5; continue
      fi
    fi; intake_mark m5_admission
    if (( existing_only )) || [[ -n "$episode" ]]; then
      task_record="$(issue_unit_task "$n" require-ready)" || { intake_skip task; continue; }
    else
      task_record="$(issue_unit_task "$n" "$issue_json")" || { intake_skip task; continue; }
    fi; intake_mark issue_unit_task
    task="$(jqf -r .task <<<"$task_record")"
    body_blocked_by="$(jqf -c '.body_blocked_by // []' <<<"$task_record")"
    labels="$(jqf -c '.labels // []' <<<"$task_record")"
    if (( ! existing_only )) && [[ -z "$existing_id" ]]; then
      intake_candidate_json="$(jqf -cn --argjson issue "$n" --arg task "$task" '{issue:$issue,task:$task}')" || { intake_skip candidate; continue; }
      candidate_started=$SECONDS
      # Footprint orders work and never refuses it: an unreadable prediction or comparison admits the issue unordered.
      intake_candidate_scope="$(scheduler_footprint "$intake_candidate_json")" || {
        say "intake order issue #$n: predicted footprint unavailable, admitted unordered"
        intake_candidate_scope='[]'
      }
      (( SECONDS - candidate_started < 2 )) || say "intake detail footprint_predict issue=$n secs=$((SECONDS - candidate_started))s"; intake_mark footprint_predict
      candidate_started=$SECONDS
      intake_conflict="$(active_footprint_conflict "$intake_candidate_scope" "$intake_footprint_owners" "__intake-$n")" || {
        say "intake order issue #$n: footprint comparison unavailable, admitted unordered"
        intake_conflict=""
      }
      (( SECONDS - candidate_started < 2 )) || say "intake detail footprint_conflict issue=$n secs=$((SECONDS - candidate_started))s"; intake_mark footprint_compare
      if [[ -n "$intake_conflict" ]]; then
        intake_match="$(footprint_match_detail "$intake_candidate_scope" "$intake_candidate_scope" \
          "$(jqf -c --arg id "$intake_conflict" '[.[] | select(.id == $id) | .footprint[]?]' <<<"$intake_footprint_owners")" '{}')"
        say "intake order issue #$n: footprint overlaps unit=$intake_conflict candidate_unit=issue-$n owner=$intake_conflict ${intake_match:-candidate_path=unknown owner_path=unknown source=unknown cochange_count=unknown}; admitted, the dispatch walk runs it after units no live owner overlaps"
      fi
    fi
    if [[ "$lane" == direct-main ]]; then branch="agent/auto-issue-$n"; else branch="agent/issue-$n"; fi
    recovery_sha="$(jqf -r '.worktree_sha // .start_sha // empty' <<<"$handoff_all")"
    if [[ "$recovery_sha" =~ $SHA_RE ]]; then
      if [[ "$lane" == pr ]]; then branch="agent/issue-$n-recovered-${recovery_sha:0:12}"
      else branch="agent/auto-issue-$n-recovered-${recovery_sha:0:12}"; fi
    fi
    if [[ "$episode" == ruling-* ]]; then # the old branch is a closed PR's, up to thousands of commits behind main
      branch="agent/issue-$n-${episode//:/}"
    fi
    if (( existing_only )) && [[ -n "$existing_id" ]] && ! jqf -e --arg id "$existing_id" 'any(.units[]; .id == $id and (.stage | test("^(implement|review|rereview|repair)(-pending)?$")))' "$(intake_units_view)" >/dev/null; then
      total_upstream="$(jqf '[.units[] | select(.stage | test("^(implement|review|rereview|repair)(-pending)?$"))] | length' "$UNITS")"
      if (( max_up > 0 && total_upstream >= 2 * max_up )); then # max_up 0 is a paused pool: known units still resume, as they did before the ceiling.
        say "intake held: $total_upstream total units upstream (ceiling $((2 * max_up))); handoff issue #$n deferred"
        intake_skip ceiling; continue
      fi
    fi
    if [[ -n "$existing_id" ]] && intake_guarded_recut_roundtrip "$existing_id" "$n" "$state_file" "$episode"; then
      intake_skip guarded_recut_loop; continue
    fi
    if [[ -n "$existing_id" ]]; then
      units_update --arg id "$existing_id" --argjson n "$n" --arg episode "$episode" --arg pr_state "$pr_state" --arg task "$task" --argjson body_blocked_by "$body_blocked_by" --argjson labels "$labels" \
        --arg lane "$lane" --arg lane_policy "${lane_policy:-}" --arg branch "$branch" --arg existing_pr "$existing_pr" --arg handoff_branch "$handoff_branch" --argjson pr_changed "$pr_changed" --slurpfile ids <(printf '%s' "$ids") --argjson handoff "$handoff" --argjson handoff_all "$handoff_all" --arg at "$STAMP" \
        '.units |= map(if (.id as $unit | $ids[0] | index($unit)) != null then
          .hold_handoff_wait_issues = ((.hold_handoff_wait_issues // []) | map(select(. != $n)))
          | if (.hold_handoff_wait_issues | length) == 0 and .hold_handoff_lookup_pending != true then del(.hold_handoff_wait_issues, .hold_handoff_waiting) else . end
        else . end | if .id != $id then
          if (.id as $other | $ids[0] | index($other)) != null then
            .stage="parked" | .parked_reason="superseded" | .unpark_condition=("handoff unit " + $id + " settles") | .approved_sha=null | .hold_handoff_episode=$episode
            | .note=("Superseded by handoff unit " + $id)
          else . end
        else
          .issue = $n | .labels = $labels | .body_blocked_by = $body_blocked_by | .hold_handoff_episode = $episode | .approved_sha = null | .reviewed_sha = null | .reviewed_pr_head = null | del(.blocked_on, .self_fix_pending, .parked_reason, .unpark_condition)
          | if $pr_changed then del(.ci_adopt_head, .ci_adopt_at, .ci_sync_head, .ci_ready_sha, .ci_ready_at, .ci_held_sha, .ci_wip_wait, .gated, .lane_policy, .product_paths) else . end
          | .history = ((.history // []) + [{stage:"hold-handoff",result:"ownerless hold handoff; read issue comments",at:$at}])
          # An expired stop-loss hold promises to resume the issue, but the budget check ran again on the same 3-of-3 rounds and re-held it.
          # One supervisor-requeue (no decision, so it is not a ruling for dep_dead_ruled) restarts the count; the mark keeps a second stop-loss with the arbiter.
          | if $handoff_all.kind == "stop-loss" and .stop_loss_resumed_at == null then
              .history += [{stage:"supervisor-requeue",result:"stop-loss hold expired; resumed once with a refilled budget",at:$at}] | .stop_loss_resumed_at = $at
            else . end
          | if $pr_state == "OPEN" then
              .stage = "repair-pending" | .pr = ($existing_pr | tonumber) | .lane = $lane | .lane_policy = $lane_policy | del(.product_paths)
              | if $handoff_branch != "" then .branch = $handoff_branch else . end
              | .repair_hint = "Read the issue comments for the ownerless hold handoff and complete the existing PR."
            else
              .stage = "implement-pending" | .task = $task | .lane = $lane | .branch = $branch
              | del(.pr, .handoff_start_ref, .handoff_start_sha, .handoff_start_applied)
              | if $handoff.start_ref then .handoff_start_ref = $handoff.start_ref | .handoff_start_sha = $handoff.start_sha else . end
            end
          | del(.handoff_worktree, .handoff_worktree_sha, .handoff_worktree_dirty, .handoff_worktree_applied, .handoff_integration_sha, .handoff_original_pr_head, .handoff_delivery_verified_sha)
          | del(.handoff_start_ref, .handoff_start_sha, .handoff_start_applied)
          | if $handoff.start_ref then .handoff_start_ref = $handoff.start_ref | .handoff_start_sha = $handoff.start_sha else . end
          | if (($handoff_all.worktree_sha // "") | test("^[0-9a-f]{40}$")) then
              .handoff_worktree = $handoff_all.worktree | .handoff_worktree_sha = $handoff_all.worktree_sha | .handoff_worktree_dirty = $handoff_all.worktree_dirty
            else . end
          end)'
      footprint_waiters_revalidate || { say "hold handoff issue #$n: could not revalidate footprint waiters after the owner transition"; intake_ops_flush; return 1; }
      say "hold handoff issue #$n resumed existing unit=$existing_id"
    else
      if [[ "$handoff_pr" =~ ^[0-9]+$ ]]; then branch="$handoff_branch"; fi
      units_update --argjson n "$n" --arg title "$title" --argjson labels "${labels:-[]}" --arg task "$task" --argjson body_blocked_by "$body_blocked_by" --arg lane "$lane" --arg lane_policy "${lane_policy:-}" --arg branch "$branch" --arg episode "$episode" --argjson handoff "$handoff" --argjson handoff_all "$handoff_all" \
        --arg pr "$handoff_pr" --arg acceptance "${acceptance:-}" --slurpfile history <(units_history_index) \
        'if any($history[0].units[]; .issue == $n) then . else .units += [{id:("issue-"+($n|tostring)), issue:$n, title:$title, labels:$labels, stage:"implement-pending", lane:$lane, branch:$branch, task:$task, body_blocked_by:$body_blocked_by, history:[],hold_handoff_episode:$episode}
          + (if $acceptance != "" then {acceptance:($acceptance | fromjson)} else {} end)
          + (if $pr != "" then {pr:($pr | tonumber),stage:"repair-pending",lane_policy:$lane_policy,repair_hint:"Read the issue comments for the ownerless hold handoff and complete the existing PR."} else {} end)
          + (if (($handoff_all.worktree_sha // "") | test("^[0-9a-f]{40}$")) then {handoff_worktree:$handoff_all.worktree,handoff_worktree_sha:$handoff_all.worktree_sha,handoff_worktree_dirty:$handoff_all.worktree_dirty} else {} end)
          + (if $handoff.start_ref then {handoff_start_ref:$handoff.start_ref,handoff_start_sha:$handoff.start_sha} else {} end)] end'
    fi
    [[ "$episode" != ruling-* || -z "$existing_id" ]] || set_unit "$existing_id" '.task += "\n\n本轮从最新 main 的新分支开始，不要沿用旧分支：它属于已关闭的 PR。裁决里提到的旧 PR CI 失败，只有能从当前 main 复现才算本轮范围。"'; intake_mark unit_write
    if [[ -n "$intake_candidate_scope" ]]; then
      intake_candidate_stage=implement-pending
      if [[ -n "$existing_id" && "$pr_state" == OPEN ]] || [[ -z "$existing_id" && "$handoff_pr" =~ ^[0-9]+$ ]]; then
        intake_candidate_stage=repair-pending
      fi
      intake_footprint_owners="$(jqf -c --arg id "issue-$n" --arg stage "$intake_candidate_stage" \
        --slurpfile scope <(printf '%s' "$intake_candidate_scope") \
        '. + [{id:$id,stage:$stage,footprint:$scope[0]}]' <<<"$intake_footprint_owners")"
    fi; intake_mark footprint_owners
    intake_known_issues["$n"]=1
    added=$((added+1)); INTAKE_ADDED=$((${INTAKE_ADDED:-0}+1)) # refill dispatches again only when intake added work
    say "intake issue #$n -> implement-pending ($lane)"
  done < <(if (( existing_only )); then printf '%s\n' "$handoff_rows"; else predecessor_candidates; (( only_pred )) || intake_candidates "$refill_mode"; fi)
  intake_ops_flush
  if (( existing_only )); then
    if [[ -n "$walk_broke" ]]; then printf '%s\n' "$walk_broke" > "$walk_cursor"; else rm -f -- "$walk_cursor"; fi
    INTAKE_WALK_ROWS=$walk_rows; INTAKE_WALK_LAP=$([[ -z "$walk_broke" ]] && echo true || echo false) # the station's done line reads these
    say "intake detail existing_walk start=#$walk_start rows=$walk_rows lap_done=$INTAKE_WALK_LAP"
  fi
  if (( ${#intake_terminal_rows[@]} )); then
    say "intake closed units under open issues count=${#intake_terminal_rows[@]} ids=$(IFS=,; printf '%s' "${intake_terminal_rows[*]}")"
    intake_reopen_episodes "${intake_terminal_rows[@]}"
    intake_ruling_episodes "${intake_terminal_rows[@]}"
    intake_closed_unit_rows "${intake_terminal_rows[@]}"
  fi
  say "intake detail candidates secs=$((SECONDS - step_started))s added=$added total_secs=$((SECONDS - intake_started))s"
  intake_steps_say
  skip_line="intake skip counts refill=$refill_mode added=$added"
  if (( ${#intake_skip_counts[@]} )); then
    while IFS= read -r skip_key; do skip_line+=" $skip_key=${intake_skip_counts[$skip_key]}"; done < <(printf '%s\n' "${!intake_skip_counts[@]}" | sort)
  fi
  say "$skip_line"
  if [[ "$refill_mode" != true && "$existing_only" == 0 && -f "$INTAKE_FULL_SCAN_FLAG" ]]; then
    date +%s > "$INTAKE_FULL_SCAN_FLAG" && mv -f -- "$INTAKE_FULL_SCAN_FLAG" "$A/intake-full-tick-at"
  fi
  if (( ! existing_only && added == 0 && ! only_pred )) && [[ ! -f "$A/.idle-alert" || -n "$(find "$A/.idle-alert" -mmin +60 2>/dev/null)" ]]; then
    touch "$A/.idle-alert"
    echo "[$STAMP] IDLE-CAPACITY live=$live/$MAX pending=$pending: intake found no eligible issue (labels or skip labels too narrow?)" >> "$A/alerts/slo.md"
  fi
}
