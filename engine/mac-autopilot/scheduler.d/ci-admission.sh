mark_product_paths() { # 就绪单元第一次见到时查一次 PR 文件，记 .product_paths（true/false）
  local id pr i files product updates='{}' query_timeout limit remote repo_path owner repo_name owner_json repo_json query raw updates_file rc
  local -a ids=() prs=()
  query_timeout="${CI_PRODUCT_PATH_LOOKUP_TIMEOUT_SECONDS:-10}"
  [[ "$query_timeout" =~ ^[1-9][0-9]*$ ]] || query_timeout=10
  limit="${PRODUCT_PATHS_PER_TICK:-20}"
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=20
  while IFS=$'\t' read -r id pr; do
    [[ -n "$id" && "$pr" =~ ^[0-9]+$ ]] || continue
    ids+=("$id")
    prs+=("$pr")
  done < <(jqf -r '.units[] | select((.stage | IN("ready-to-merge","ci-pending")) and (.pr // null) != null and .product_paths == null) | [.id, .pr] | @tsv' "$UNITS" | head -"$limit")
  (( ${#ids[@]} > 0 )) || return 0

  # Files are the path-classification read missing from the regular PR census.
  # Query every bounded candidate in one GraphQL request instead of one `gh pr view`
  # per PR; this still classifies non-product exemptions when product runner slots are full.
  repo_path="${GH_REPO:-}"
  if [[ "$repo_path" != */* ]]; then
    remote="$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null)" || return 0
    remote="${remote%.git}"
    remote="${remote/:/\/}"
    remote="${remote%/}"
    repo_name="${remote##*/}"
    owner="${remote%/*}"
    owner="${owner##*/}"
    repo_path="$owner/$repo_name"
  fi
  owner="${repo_path%%/*}"
  repo_name="${repo_path#*/}"
  [[ -n "$owner" && -n "$repo_name" && "$repo_name" != */* ]] || return 0
  owner_json="$(jqf -Rn --arg value "$owner" '$value')" || return 0
  repo_json="$(jqf -Rn --arg value "$repo_name" '$value')" || return 0
  query="query { repository(owner:$owner_json, name:$repo_json) {"
  for pr in "${prs[@]}"; do
    query+=" pr_$pr: pullRequest(number:$pr) { files(first:100) { nodes { path } } }"
  done
  query+=" } }"
  raw="$(cd "$ROOT" && AUTOPI_GH_TIMEOUT_SECONDS="$query_timeout" gh api graphql -f query="$query" 2>/dev/null)" || return 0
  jqf -e '.data.repository | type == "object"' <<<"$raw" >/dev/null 2>&1 || return 0

  for i in "${!ids[@]}"; do
    id="${ids[$i]}"; pr="${prs[$i]}"
    files="$(jqf -r --arg alias "pr_$pr" '.data.repository[$alias].files.nodes[]?.path // empty' <<<"$raw")"
    [[ -n "$files" ]] || continue
    if grep -vqE "$NONPRODUCT_PATHS_RE" <<<"$files"; then product=true; else product=false; fi
    updates="$(jqf --arg id "$id" --argjson product "$product" '. + {($id):$product}' <<<"$updates")"
  done
  [[ "$updates" == '{}' ]] && return 0
  updates_file="$(scheduler_jq_arg_file "$updates")" || return 0
  if units_update --rawfile paths "$updates_file" \
    '($paths|fromjson) as $path_map | .units |= map(.id as $id | if (.stage | IN("ready-to-merge","ci-pending")) and .product_paths == null and $path_map[$id] != null then .product_paths=$path_map[$id] else . end)'; then
    rc=0
  else
    rc=$?
  fi
  rm -f -- "$updates_file"
  return "$rc"
}
# 本机预检（precheck.sh）：等名额的单元先在本机跑 PR 自己改动的测试，PASS/SKIP 才给 CI 名额，FAIL 直接返工。
# 10-22：批准后 CI 红 14/14 是 PR 自己改动的测试文件；12 小时 CI 判红 69 次、合并 12 次，每次红白等名额 + 45–60 分钟。
# 一次只跑一个（独立 clone wt-precheck，内存守卫在脚本里），已在跑 CI 的单元不受影响。
precheck_harvest() {
  local id pid head out first fails
  while IFS=$'\t' read -r id pid head; do
    alive "$pid" && continue
    out="$SUP/precheck-$id.out"; first="$(head -1 "$out" 2>/dev/null)"
    case "$first" in
      "PRECHECK: FAIL"*)
        fails="$(sed -n '2,12p' "$out" 2>/dev/null)"
        set_unit "$id" "$(hist precheck-red "${first#PRECHECK: }") | del(.precheck_pid) | del(.ci_wip_wait) | .approved_sha=null | .repair_hint=$(js "批准后本机预检（未占 CI 名额）：PR 自己改动的测试在本机失败。${fails} 完整输出 ${out}。本机用 PGTEST_URL 复现（RUN_INTEGRATION=1 npx vitest run <文件>），修根因并补回归测试后 push。") | .stage=\"repair-pending\""
        say "precheck red unit=$id head=${head:0:9} -> repair-pending without spending a CI slot" ;;
      *)
        set_unit "$id" "$(hist precheck "${first:-PRECHECK: SKIP no output}") | del(.precheck_pid) | .precheck_sha=$(js "$head")"
        say "precheck unit=$id head=${head:0:9}: ${first:-PRECHECK: SKIP no output}" ;;
    esac
  done < <(jqf -r '.units[] | select(.precheck_pid != null) | [.id, .precheck_pid, (.precheck_head // "")] | @tsv' "$UNITS")
}
precheck_launch() { # id pr head
  local dir pid
  dir="$(ensure_clone precheck)" || return 1
  (cd "$dir" && exec setsid bash "$HERE/precheck.sh" "$dir" "$2" "$3") > "$SUP/precheck-$1.out" 2>&1 < /dev/null &
  pid=$!
  set_unit "$1" ".precheck_pid=$pid | .precheck_head=$(js "$3")"
  say "precheck pid=$pid unit=$1 PR#$2 head=${3:0:9}"
}
# 占到名额之前先同步落后 main 的 head；门控草稿的 update-branch 若干净沿用批准，可在本拍继续领取名额。
# 每个 head 只试一次；真冲突转 repair，不消耗 CI 运行，名额让给下一个就绪单元。mergeability 或 head 数据未知不做任何转移。
# 返回 0 = 已请求 update-branch 或处理冲突（除携带批准的门控草稿外调用方延后），1 = 照常占名额。
SLOT_SYNC_CARRIED_HEAD=""
SLOT_SYNC_SPENT=0 # 本拍 update-branch 名额同步预算计数（SLOT_SYNC_MAX）：每条 MERGEABLE 链 5-7 个串行 gh 调用，是 wip_assignment 的大头
slot_sync() { # id head gated
  local pr state updated_head
  SLOT_SYNC_CARRIED_HEAD=""
  pr="$(unit_field "$1" .pr)"; [[ "$pr" =~ ^[0-9]+$ && "$2" =~ $SHA_RE ]] || return 1
  [[ "$(unit_field "$1" '.slot_sync_sha // empty')" != "$2" ]] || return 1
  pr_behind_main "$pr" "$2" || return 1
  state="$(tick_pr_mergeable "$pr")"
  case "$state" in
    MERGEABLE)
      if (( SLOT_SYNC_SPENT++ >= ${SLOT_SYNC_MAX:-2} )); then
        return 2 # 本拍 update-branch 预算用完：调用方延后该单元（不占名额），下一拍再同步
      fi
      set_unit "$1" ".slot_sync_sha=$(js "$2")" || :
      ci_update_branch "$pr" "$2" || return 1
      set_unit "$1" "$(hist slot-sync "PR#$pr behind main; update-branch at $2 before the CI slot")"
      say "slot sync PR#$pr: behind main, update-branch requested before CI starts"
      if [[ "${3:-0}" == 1 ]]; then
        updated_head="$(pr_view "$pr" headRefOid)"
        if [[ "$updated_head" =~ $SHA_RE && "$updated_head" != "$2" ]] && approval_carries "$pr" "$2" "$updated_head"; then
          set_unit "$1" "$(hist approval-carried "clean main merge $updated_head on approved $2") | .approved_sha=$(js "$updated_head") | .ci_gate_required=true | .ci_wait_sha=$(js "$updated_head") | .stage=\"ci-pending\" | del(.ci_green_sha)" || return 0
          say "approval carried PR#$pr $2 -> $updated_head (clean update-branch merge)"
          post_approved_status "$1" "$updated_head"
          SLOT_SYNC_CARRIED_HEAD="$updated_head"
        fi
      fi
      return 0 ;;
    CONFLICTING)
      set_unit "$1" ".slot_sync_sha=$(js "$2")" || :
      merge_conflict_to_repair "$1" "$pr" "conflicts with main before its CI slot" "PR 与最新 main 冲突，占 CI 名额前发现。git merge --no-edit origin/main，按两边意图解决冲突，跑受影响测试，推送。" "$2"
      return 0 ;;
  esac
  return 1
}

ci_assign_wip() {
  local wip k=0 id br head r st jobs n=0 started=0 pre_id="" precheck_on gated gdraft ghead synced_pr cancelled_runs sync_rc
  local detail_started detail_elapsed
  local -a jobs_to_load=()
  SLOT_SYNC_SPENT=0
  precheck_on="$(jqf -r 'if .precheck == false then 0 else 1 end' <<<"$CFG")"
  detail_started=$SECONDS
  mark_product_paths
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "ci admission detail product_path_lookup=${detail_elapsed}s"
  (( precheck_on )) && precheck_harvest
  wip="$(ci_pr_free_slots)" || { say "ci wip: PR runner capacity unavailable; admission skipped"; return 0; }
  local -A wait_of=() gwait_of=()
  GATED_SLOT=()
  if jqf -e 'any(.units[]; (.stage | IN("ready-to-merge","ci-pending")) and (.pr // null) != null)' "$UNITS" >/dev/null; then
    if [[ "$GATED_CENSUS_LOADED" != true ]]; then
      gated_load || say "ci wip: gated PR listing unavailable; no draft/ready flips this pass"
    fi
  else
    GATED_OF=()
  fi
  if [[ "$GATED_CENSUS_LOADED" == true ]]; then
    # 普查已读就跑豁免分类：热修/非产品单元不占产品名额、直接 ready。条件不能是 GATED_OF 非空——
    # 没有任何带标签 PR 时（只剩未标签热修 draft）豁免类也要照常处理（2026-11-03 饿死事故的形态之一）。
    gated_ready_exempt
  fi
  while IFS=$'\t' read -r id br head; do
    [[ -n "$id" ]] || continue
    tick_prs_prime
    gated=0; gdraft=false
    if [[ -n "${GATED_OF[$br]:-}" ]]; then
      gated=1; read -r _ gdraft ghead <<<"${GATED_OF[$br]}"
      [[ "$ghead" == "$head" ]] || continue
      if [[ "$gdraft" == false && "$(unit_field "$id" '.ci_ready_sha // empty')" == "$head" && -n "$(unit_field "$id" '.ci_ready_at // empty')" ]]; then
        continue
      fi
    elif [[ "$(unit_field "$id" '.ci_wip_wait // empty')" != "$head" ]]; then
      continue
    fi
    k=$((k + 1))
    if (( k <= wip )); then
      if [[ "$gated:$gdraft" != "1:false" ]]; then
        sync_rc=0
        slot_sync "$id" "$head" "$gated" || sync_rc=$?
        if (( sync_rc == 2 )); then
          k=$((k - 1)); continue # 本拍同步预算用完：名额让给已同步单元，下一拍再试
        elif (( sync_rc == 0 )); then
          if (( gated )) && [[ -n "$SLOT_SYNC_CARRIED_HEAD" ]]; then
            head="$SLOT_SYNC_CARRIED_HEAD"
            read -r synced_pr _ <<<"${GATED_OF[$br]}"
            GATED_OF["$br"]="$synced_pr true $head"
          else
            k=$((k - 1)); continue
          fi
        fi
      fi
      if (( precheck_on )) && [[ "$gated:$gdraft" != "1:false" ]] && [[ "$(unit_field "$id" '.precheck_sha // empty')" != "$head" ]]; then
        # 没有本机预检结论的不占名额：排给预检，名额留给下一个已预检的单元（已 ready 在跑的门控 PR 不再预检）
        [[ -n "$pre_id" || -n "$(unit_field "$id" '.precheck_pid // empty')" ]] || pre_id="$id"
        k=$((k - 1)); if (( gated )); then gwait_of["$br"]="$id:$head"; else wait_of["$br"]="$id:$head"; fi
        continue
      fi
      if (( gated )); then gated_ready "$id" "$br" "$head"; continue; fi
      cancelled_runs="$(gh run list --commit "$head" --json databaseId,conclusion --jq '.[] | select(.conclusion=="cancelled") | .databaseId' 2>/dev/null)" \
        || { say "ci wip unit=$id: could not list cancelled runs for head $head; admission deferred"; k=$((k-1)); continue; }
      for r in $cancelled_runs; do
        gh run rerun "$r" --failed >/dev/null 2>&1 || true
      done
      set_unit "$id" "$(hist ci-wip-start "slot $k/$wip") | del(.ci_wip_wait) | del(.ci_cancel_reruns)"
      started=$((started + 1))
    else
      if (( gated )); then gwait_of["$br"]="$id:$head"; else wait_of["$br"]="$id:$head"; fi
      # 名额满时也提前预检排队中的下一个：名额一空出就有已预检的单元可上
      if (( precheck_on )) && [[ -z "$pre_id" && "$(unit_field "$id" '.precheck_sha // empty')" != "$head" && -z "$(unit_field "$id" '.precheck_pid // empty')" ]]; then
        pre_id="$id"
      fi
    fi
  # 同一优先级按 ready_since 先后；critical 与可解锁依赖只在 readiness 相同时作 tie-break。
  done < <(jqf -r --argjson hotfix "${CI_HOTFIX_BRANCHES:-[]}" '[.units[] | select(.stage == "blocked-external") | .blocked_on | numbers] as $deps
      | [.units[] | select((.stage | IN("ready-to-merge","ci-pending")) and (.hold_handoff_waiting // false) == false and (.pr // null) != null and (.lane // "") != "direct-main"
      and (.hotpatch // false) != true and (.branch // "") != ""
      and ((.branch as $br | $hotfix | index($br)) == null)
      and .product_paths != false)]
      | sort_by([(if .main_red == true then 0 elif .ci_priority == true then 1 else 2 end),
                 '"$(ready_since_epoch)"', (if .critical == true then 0 else 1 end),
                 (if (.issue as $i | $deps | index($i)) or (.branch as $b | any($deps[]; $b == "agent/issue-\(.)")) then 0 else 1 end)])
      | .[] | [.id, .branch, (.approved_sha // "")] | @tsv' "$UNITS")
  while IFS=$'\t' read -r r st br; do
    [[ "$st" != queued && -n "${wait_of[$br]:-}" ]] && jobs_to_load+=("$r")
  done < <(unfinished_runs | jqf -r '.[] | select(.event == "pull_request") | [.databaseId, .status, .headBranch] | @tsv' 2>/dev/null)
  ci_jobs_prefetch "${jobs_to_load[@]}" || :
  if (( ${#wait_of[@]} > 0 )); then
    while IFS=$'\t' read -r r st br; do
      [[ -n "$r" && -n "${wait_of[$br]:-}" ]] || continue
      if [[ "$st" != queued ]]; then
        jobs="$(ci_jobs_status "$r")" || continue
        jqf -e 'all(.[]; . != "in_progress")' <<<"$jobs" >/dev/null 2>&1 || continue
      fi
      ci_cancel_run_once "$r" "ci wip" && n=$((n + 1))
    done < <(unfinished_runs | jqf -r '.[] | select(.event == "pull_request") | [.databaseId, .status, .headBranch] | @tsv' 2>/dev/null)
    for br in "${!wait_of[@]}"; do
      id="${wait_of[$br]%%:*}"; head="${wait_of[$br]#*:}"
      [[ "$(unit_field "$id" '.ci_wip_wait // empty')" == "$head" ]] || set_unit "$id" ".ci_wip_wait=$(js "$head")"
    done
  fi
  for br in "${!gwait_of[@]}"; do
    id="${gwait_of[$br]%%:*}"; head="${gwait_of[$br]#*:}"
    gated_wait "$id" "$br" "$head"
    [[ "$(unit_field "$id" '.ci_wip_wait // empty')" == "$head" ]] || set_unit "$id" ".ci_wip_wait=$(js "$head")"
  done
  if (( ${#GATED_OF[@]} > 0 )); then
    gated_demote_unapproved
  fi
  if [[ -n "$pre_id" ]] && ! jqf -e 'any(.units[]; .precheck_pid != null)' "$UNITS" >/dev/null; then
    precheck_launch "$pre_id" "$(unit_field "$pre_id" .pr)" "$(unit_field "$pre_id" '.approved_sha // empty')" || say "precheck clone unavailable for $pre_id"
  fi
  (( n + started > 0 )) && say "ci wip: $wip free PR runner slot(s); $(( ${#wait_of[@]} + ${#gwait_of[@]} )) ready unit(s) wait for a CI slot (cancelled $n queued run(s)); started $started"
  return 0
}

# 复发护栏（2026-11-03 草稿饿死事故）：设计上，ready-to-merge 单元的 draft PR 在有空闲名额的
# 第一个准入拍就必须被翻转（豁免类立即翻，门控类占到名额翻）。累计 CI_SLOT_STARVE_SLOW_TICKS
# （默认 3）个有空闲名额的慢拍仍未翻转 → 每拍 say 一行，并按单元一次性写 alerts/slo.md。
# 名额为 0 属于正常排队，不计时也不告警。
ci_slot_starve_watch() {
  local wip prs_file rows_file tmpdir id pr since ticks threshold
  threshold="${CI_SLOT_STARVE_SLOW_TICKS:-3}"
  [[ "$threshold" =~ ^[1-9][0-9]*$ ]] || threshold=3
  wip="$(ci_pr_free_slots)" || return 0
  (( wip > 0 )) || return 0
  tmpdir="$(mktemp -d)" || return 0
  prs_file="$tmpdir/prs.json"
  rows_file="$tmpdir/starved-drafts.tsv"
  tick_prs > "$prs_file" || { rm -rf -- "$tmpdir"; return 0; }
  jqf -r --slurpfile prs "$prs_file" '.units[]
      | select((.stage | IN("ready-to-merge","ci-pending")) and (.pr // null) != null and (.hold_handoff_waiting // false) == false
          and (.lane // "") != "direct-main" and (.approved_sha // "") != "")
      | . as $u | ($prs[0][] | select(.number == $u.pr) | select(.isDraft == true)) | [$u.id, ($u.pr | tostring), ($u.ci_slot_wait_since // "")] | @tsv' "$UNITS" > "$rows_file" \
    || { rm -rf -- "$tmpdir"; return 0; }
  while IFS=$'\t' read -r id pr since; do
    [[ -n "$id" ]] || continue
    if [[ -z "$since" ]]; then
      ticks=1
      set_unit "$id" ".ci_slot_wait_since=$(js "$STAMP") | .ci_slot_wait_ticks=1" || :
    else
      ticks="$(unit_field "$id" '.ci_slot_wait_ticks // 1')"
      [[ "$ticks" =~ ^[0-9]+$ ]] || ticks=1
      ticks=$((ticks + 1))
      set_unit "$id" ".ci_slot_wait_ticks=$ticks" || :
    fi
    (( ticks >= threshold )) || continue
    say "ci slot starvation unit=$id PR#$pr: still draft with $wip free slot(s) after $ticks slow tick(s); admission cannot ready it"
    if [[ "$(unit_field "$id" '.ci_slot_starve_alerted // empty')" != true ]]; then
      echo "[$STAMP] CI-SLOT-STARVE unit=$id PR#$pr free_slots=$wip waited_ticks=$ticks" >> "$A/alerts/slo.md" \
        && set_unit "$id" '.ci_slot_starve_alerted=true' || :
    fi
  done < "$rows_file"
  rm -rf -- "$tmpdir"
  return 0
}

# Sole CI admission decision point for a scheduler tick. Gate-managed hotfixes are readied first; then
# review deferral and WIP slots apply, both exempting hotfix branches. The shared cancel set makes the
# first selected action authoritative for the rest of this pass.
ci_admission() {
  local CI_HOTFIX_BRANCHES
  local detail_started detail_elapsed
  local -A CI_ADMISSION_CANCELLED=()
  tick_prs_prime
  detail_started=$SECONDS
  CI_HOTFIX_BRANCHES="$(ci_hotfix_branches)" || { say "ci admission paused: open PR census unavailable for hotfix classification"; return 0; }
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "ci admission detail hotfix_classification=${detail_elapsed}s"
  detail_started=$SECONDS
  ci_ready_hotfix_gated
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "ci admission detail gated_ready=${detail_elapsed}s"
  detail_started=$SECONDS
  ci_defer_unapproved
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "ci admission detail defer_unapproved=${detail_elapsed}s"
  detail_started=$SECONDS
  ci_assign_wip
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "ci admission detail wip_assignment=${detail_elapsed}s"
  ci_slot_starve_watch
}
