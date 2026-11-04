# ---------- 足迹持有 stage 判定（intake 与 dispatch 共用的唯一规则） ----------
# 足迹的意义是阻止两个正在写文件的单元同时改同一批文件（#4488）。持有哪些 stage 由
# 单元 stage 决定，不由 worker 台账决定：等待裁决的单元（supervisor-review/parked/
# needs-human）没有任何进程在写它的文件——台账里残留未收割的 implement/repair 记录也不算
# （2026-11-03 事故：supervisor-review 单元凭 worker 记录挡住 intake，没有 supervisor 可推进时
# 无关工作全部被跳过）。释放过足迹的单元恢复（裁决 requeue → *-pending）时在 _footprint_room
# 对照活单元重查后再派发，不会越界踩掉期间启动的单元。持有 = 有人正在或本拍即将写这批文件：
#   implement/repair   活实现/修复 worker（还需 workers.json 未收割记录，见 active_footprint_snapshot）
#   implement-pending/repair-pending/landing  本拍可派发的写手；repair-pending 的 open PR 分支
#                                             马上会被修复 worker 编辑，landing 的已批准分支
#                                             正由落地作业合入 main——分支仍在被流水线改动
# 只读评审（review/rereview 及其 pending）、等裁决、等外部依赖与终态不占。scheduler.d 出现
# 新 stage 必须先在下面三个集合里完成决策：footprint-holder-stages 测试会强制全表登记。
FOOTPRINT_LIVE_WRITER_STAGES='["implement","repair"]'
FOOTPRINT_QUEUED_WRITER_STAGES='["implement-pending","repair-pending","landing"]'
FOOTPRINT_RELEASED_STAGES='["supervisor-review","parked","needs-human","blocked-external","review","rereview","review-pending","rereview-pending","ready-to-merge","merged","landed","closed","awaiting-live-event","done","wontfix","duplicate"]'

footprint_owner_stage_active() { # stage -> unit reserves write scope in the shared holder model
  jqf -e --arg stage "$1" --argjson live "$FOOTPRINT_LIVE_WRITER_STAGES" \
    --argjson queued "$FOOTPRINT_QUEUED_WRITER_STAGES" '($live + $queued | index($stage)) != null' \
    <<< '{}' >/dev/null
}
footprint_owner_stage_live() { # stage -> an implementation/repair worker can be writing now
  jqf -e --arg stage "$1" --argjson live "$FOOTPRINT_LIVE_WRITER_STAGES" \
    '($live | index($stage)) != null' <<< '{}' >/dev/null
}
footprint_wait_owner_active() { # owner id -> 0 iff its ledger stage still holds footprint scope
  local stage
  stage="$(jqf -r --arg id "$1" '[.units[] | select(.id==$id) | .stage][0] // empty' "$UNITS")" || return $?
  [[ -n "$stage" ]] || return 1
  footprint_owner_stage_live "$stage" || return $?
  jqf -e --arg id "$1" \
    'any(.workers[]; .unit==$id and .harvested!=true and .lease_expired!=true and (.type | IN("implement","repair")))' \
    "$WORKERS" >/dev/null
}
footprint_waiters_revalidate() { # clear missing/released owners before any gate counts the marker as a wait
  local rows row id owner since since_epoch owner_status
  rows="$(jqf -c '[.units[] | select((.footprint_wait_owner // "") != "")
    | {id,owner:.footprint_wait_owner,since:(.footprint_wait_since // "")}]' "$UNITS")" || return 1
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    id="$(jqf -r .id <<<"$row")"
    owner="$(jqf -r .owner <<<"$row")"
    since="$(jqf -r .since <<<"$row")"
    if footprint_wait_owner_active "$owner"; then
      since_epoch="$(ap_iso_epoch "$since")"
      [[ "$since_epoch" =~ ^[0-9]+$ ]] && continue
      set_unit "$id" ".footprint_wait_since=$(js "$STAMP")" || return 1
      continue
    else
      owner_status=$?
    fi
    (( owner_status == 1 )) || return "$owner_status"
    set_unit "$id" 'del(.footprint_wait_owner,.footprint_wait_since)' || return 1
    say "footprint wait cleared unit=$id stale_owner=$owner"
  done < <(jqf -c '.[]' <<<"$rows")
}
footprint_owner_transition() { # id old_stage new_stage -> release its waiters when it leaves writer stages
  local owner="$1" old_stage="$2" new_stage="$3" current_stage waiters left_active=false
  current_stage="$(unit_field "$owner" '.stage')" || return 1
  [[ "$current_stage" == "$new_stage" ]] || return 0
  if footprint_owner_stage_live "$old_stage"; then
    footprint_owner_stage_live "$new_stage" || left_active=true
  elif footprint_owner_stage_active "$old_stage"; then
    footprint_owner_stage_active "$new_stage" || left_active=true
  else
    return 0
  fi
  [[ "$left_active" == true ]] || return 0
  waiters="$(jqf -r --arg owner "$owner" '[.units[] | select(.footprint_wait_owner==$owner) | .id] | join(",")' "$UNITS")" || return 1
  [[ -n "$waiters" ]] || return 0
  units_update --arg owner "$owner" \
    '.units |= map(if .footprint_wait_owner==$owner then del(.footprint_wait_owner,.footprint_wait_since) else . end)' \
    || return 1
  say "footprint wait release owner=$owner waiters=$waiters"
}

# #4488: 预测足迹挡不住在跑 worker 越界写共享文件（collisions_per_day=97，全是真实并发写）。
# 派发检查把在跑 unit 的 worktree 里已发生的改动（已提交 + 未提交 + 未跟踪）并进它的足迹。
live_writes_union() { # workdir scope_json -> scope ∪ 实际已写路径；workdir 不可读时退回预测
  local wd="$1" scope="$2" live base='' merge_head rebase_state onto_path
  if [[ -n "$wd" && -d "$wd" ]]; then
    # An in-progress merge or rebase leaves incoming main changes in the worktree.
    if merge_head="$(git -C "$wd" rev-parse -q --verify MERGE_HEAD 2>/dev/null)" && [[ -n "$merge_head" ]]; then
      base="$merge_head"
    else
      for rebase_state in rebase-merge rebase-apply; do
        onto_path="$(git -C "$wd" rev-parse --git-path "$rebase_state/onto" 2>/dev/null || true)"
        [[ -n "$onto_path" ]] || continue
        [[ "$onto_path" == /* ]] || onto_path="$wd/$onto_path"
        if [[ -f "$onto_path" ]]; then
          base="$(<"$onto_path")"
          break
        fi
      done
      [[ -n "$base" ]] || base="$(git -C "$wd" merge-base origin/main HEAD 2>/dev/null || true)"
    fi
    live="$(
      {
        {
          if [[ -n "$base" ]]; then
            timeout --kill-after=1s 3s git -C "$wd" diff --no-renames --name-only -z "$base" || true
          else
            timeout --kill-after=1s 3s git -C "$wd" diff --no-renames --name-only -z HEAD || true
          fi
        } &
        { timeout --kill-after=1s 3s git -C "$wd" ls-files --others --exclude-standard -z || true; } &
        wait || true
      } | jq -Rsc '[splits("\u0000") | select(length>0)]'
    )"
    scope="$(jq -cn --slurpfile scope <(printf '%s' "$scope") --slurpfile live <(printf '%s' "$live") '($scope[0] + $live[0]) | unique')"
  fi
  printf '%s\n' "$scope"
}
resolve_active_footprints() { # active-unit JSON array → fresh live scopes; scan worktrees concurrently, persist ledger changes once
  local active="$1" scan_dir other file scope workdir rows updates resolved rc=0 index=0 pid
  local -a pids=()
  scan_dir="$(mktemp -d)" || return 1
  while IFS= read -r other; do
    [[ -n "$other" ]] || continue
    file="$scan_dir/$index.json"
    {
      local other_scope other_workdir
      other_scope="$(scheduler_footprint "$other")" || exit 1
      other_workdir="$(jq -r '.live_workdir // empty' <<<"$other")"
      other_scope="$(live_writes_union "$other_workdir" "$other_scope")" || exit 1
      jq -c --slurpfile resolved <(printf '%s' "$other_scope") \
        '{id,stage,footprint,resolved_footprint:$resolved[0]}' <<<"$other" > "$file"
    } &
    pids+=("$!")
    index=$((index + 1))
  done < <(jq -c '.[]' <<<"$active")
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
  if (( rc != 0 )); then rm -rf -- "$scan_dir"; return 1; fi
  rows="$(cat "$scan_dir"/*.json | jqf -cs '.')" || { rm -rf -- "$scan_dir"; return 1; }
  updates="$(jqf -c '[.[] | select((.footprint // []) != .resolved_footprint) | {id, footprint:.resolved_footprint}]' <<<"$rows")" \
    || { rm -rf -- "$scan_dir"; return 1; }
  if jqf -e 'length > 0' <<<"$updates" >/dev/null; then
    units_update --slurpfile updates <(printf '%s' "$updates") \
      '.units |= map(. as $unit
        | ([$updates[0][] | select(.id == $unit.id)][0] // null) as $update
        | if $update == null then . else .footprint = $update.footprint end)' \
      || { rm -rf -- "$scan_dir"; return 1; }
  fi
  resolved="$(jqf -c 'map({id,stage,footprint:.resolved_footprint})' <<<"$rows")" \
    || { rm -rf -- "$scan_dir"; return 1; }
  rm -rf -- "$scan_dir"
  printf '%s\n' "$resolved"
}
footprint_drop_check_scope_cache() {
  TICK_CHECK_SCOPE_SOURCE=()
  TICK_CHECK_SCOPE=()
}
active_footprint_snapshot() { # refresh live writes for all active implementation workers
  local active
  active="$(jqf -c --slurpfile w "$WORKERS" --argjson live "$FOOTPRINT_LIVE_WRITER_STAGES" '
    [.units[] | . as $u
      | select(.stage as $s | $live | index($s) != null)
      | select(any($w[0].workers[]; .unit==$u.id and .harvested!=true and .lease_expired!=true and (.type | IN("implement","repair"))))
      | . + {live_workdir: ([$w[0].workers[] | select(.unit==$u.id and .harvested!=true and .lease_expired!=true and (.type | IN("implement","repair"))) | .workdir] | first)}]' "$UNITS")"
  [[ "$active" == '[]' ]] || active="$(resolve_active_footprints "$active")" || return 1
  printf '%s\n' "$active"
}
active_footprint_conflict() (
  REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$SCHEDULER_AGENT_LIB" || exit 2
  local candidate active_scope owner
  candidate="$(footprint_strip_shared_append "$1")"
  # Flatten active scopes once: the previous candidate × active-unit loop ran
  # expected_packages_collide (and its jq path parsing) once for every owner.
  active_scope="$(jq -c --arg id "$3" '[.[] | select(.id != $id) | .footprint[]?]' <<<"$2")"
  active_scope="$(footprint_strip_shared_append "$active_scope")"
  if expected_packages_collide "$candidate" "$active_scope"; then
    owner="$(jq -r --arg id "$3" --arg path "$EXPECTED_SCOPE_COLLISION_ACTIVE" \
      'first(.[] | select(.id != $id) | select(any(.footprint[]?; . == $path)) | .id) // empty' <<<"$2")"
    printf '%s\n' "$owner"
  fi
)
active_footprint_conflicts_batch() (
  REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$SCHEDULER_AGENT_LIB" || exit 2
  local active="$1" candidates="$2" id scope candidate active_scope owner
  while IFS=$'\t' read -r id scope; do
    [[ -n "$id" ]] || continue
    candidate="$(footprint_strip_shared_append "$scope")"
    active_scope="$(jq -c --arg id "$id" '[.[] | select(.id != $id) | .footprint[]?]' <<<"$active")"
    active_scope="$(footprint_strip_shared_append "$active_scope")"
    if expected_packages_collide "$candidate" "$active_scope"; then
      owner="$(jq -r --arg id "$id" --arg path "$EXPECTED_SCOPE_COLLISION_ACTIVE" \
        'first(.[] | select(.id != $id) | select(any(.footprint[]?; . == $path)) | .id) // empty' <<<"$active")"
      printf '%s\t%s\n' "$id" "${owner:-unknown}"
    fi
  done <<<"$candidates"
)
footprint_refresh_conflicts() {
  local refresh="${1:-true}" started=$SECONDS active candidates='' conflicts id scope owner elapsed
  if [[ "$refresh" == true ]]; then
    active="$(active_footprint_snapshot)" || { footprint_drop_check_scope_cache; return 1; }
    TICK_ACTIVE_FOOTPRINTS="$active"
    TICK_ACTIVE_FOOTPRINTS_VALID=true
  else
    [[ "$TICK_ACTIVE_FOOTPRINTS_VALID" == true ]] || { footprint_drop_check_scope_cache; return 1; }
    active="$TICK_ACTIVE_FOOTPRINTS"
  fi
  for id in "${TICK_FOOTPRINT_PREFLIGHT_IDS[@]}"; do
    [[ -n "$id" ]] || continue
    scope="${TICK_CHECK_SCOPE[$id]:-[]}"
    candidates+="$id"$'\t'"$scope"$'\n'
  done
  conflicts="$(active_footprint_conflicts_batch "$active" "$candidates")" \
    || { footprint_drop_check_scope_cache; return 1; }
  TICK_FOOTPRINT_PREFLIGHT_CONFLICT=()
  while IFS=$'\t' read -r id owner; do
    [[ -n "$id" ]] && TICK_FOOTPRINT_PREFLIGHT_CONFLICT["$id"]="${owner:-unknown}"
  done <<<"$conflicts"
  TICK_FOOTPRINT_CONFLICT_VALID=true
  elapsed=$((SECONDS - started))
  (( elapsed < 2 )) || say "dispatch detail footprint_conflict_refresh candidates=${#TICK_FOOTPRINT_PREFLIGHT_IDS[@]} secs=${elapsed}s"
}
footprint_preflight_snapshot() {
  if [[ "$TICK_FOOTPRINT_PREFLIGHT_STATUS" == ready ]]; then
    [[ "$TICK_FOOTPRINT_CONFLICT_VALID" == true ]] && return 0
    footprint_refresh_conflicts true || return 1
    return 0
  fi
  [[ "$TICK_FOOTPRINT_PREFLIGHT_STATUS" == not-started ]] || return 1
  TICK_FOOTPRINT_PREFLIGHT_STATUS=failed
  local started=$SECONDS scope_rows='' clear_scope_rows='' scope_candidates expanded_scopes row updates update_count u id scope check_scope elapsed candidate_count=0
  local candidate_filter='.units[] | select(.stage == "implement-pending" or .stage == "repair-pending")'
  [[ "$TICK_DISPATCH_LOCAL_REFILL" != true ]] || candidate_filter='.units[] | select(.stage == "implement-pending")'
  TICK_FOOTPRINT_PREFLIGHT_IDS=()
  while IFS= read -r u; do
    id="$(jqf -r '.id' <<<"$u")"
    scope="$(scheduler_footprint "$u")" || return 1
    TICK_FOOTPRINT_CACHE["$id"]="$scope"
    TICK_FOOTPRINT_PREFLIGHT_IDS+=("$id")
    TICK_CHECK_SCOPE_SOURCE["$id"]="$scope"
    TICK_CHECK_SCOPE["$id"]="$scope"
    scope_rows+="$id"$'\t'"$scope"$'\n'
    candidate_count=$((candidate_count + 1))
  done < <(jqf -c "$candidate_filter" "$UNITS")
  if (( candidate_count == 0 )); then
    TICK_FOOTPRINT_PREFLIGHT_STATUS=ready
    TICK_FOOTPRINT_CONFLICT_VALID=true
    return 0
  fi
  footprint_refresh_conflicts true || return 1
  while IFS=$'\t' read -r id scope; do
    [[ -n "$id" && -z "${TICK_FOOTPRINT_PREFLIGHT_CONFLICT[$id]:-}" ]] || continue
    clear_scope_rows+="$id"$'\t'"$scope"$'\n'
  done <<<"$scope_rows"
  if [[ -n "$clear_scope_rows" ]]; then
    scope_candidates="$(jqf -Rn '[inputs | split("\t") | select(length == 2) | {id:.[0],scope:(.[1] | fromjson)}]' <<<"$clear_scope_rows")" \
      || { footprint_drop_check_scope_cache; return 1; }
    hotspot_log >/dev/null # Subshell expansions must inherit the same history.
    expanded_scopes="$(hotspot_expand_batch "$scope_candidates")" \
      || { footprint_drop_check_scope_cache; return 1; }
    [[ "${HOTSPOT_LOG_OK:-false}" == true ]] || HOTSPOT_LOG_LOADED=false
    while IFS= read -r row; do
      id="$(jqf -r '.id' <<<"$row")"
      check_scope="$(jqf -c '.scope' <<<"$row")"
      check_scope="$(scheduler_footprint_filter_main "$check_scope")" || {
        footprint_drop_check_scope_cache
        return 1
      }
      TICK_CHECK_SCOPE["$id"]="$check_scope"
    done < <(jqf -c '.[]' <<<"$expanded_scopes")
    footprint_refresh_conflicts cached || return 1
  fi
  updates="$(jqf -Rn '[inputs | split("\t") | select(length == 2) | {key:.[0],value:(.[1] | fromjson)}] | from_entries' <<<"$scope_rows")" || return 1
  update_count="$(jqf --slurpfile scopes <(printf '%s' "$updates") '[.units[] | select($scopes[0][.id] != null and (.footprint // []) != $scopes[0][.id])] | length' "$UNITS")" || return 1
  if (( update_count > 0 )); then
    units_update --slurpfile scopes <(printf '%s' "$updates") \
      '.units |= map(if $scopes[0][.id] != null then .footprint=$scopes[0][.id] else . end)' || return 1
  fi
  TICK_FOOTPRINT_PREFLIGHT_STATUS=ready
  elapsed=$((SECONDS - started))
  (( elapsed < 2 )) || say "dispatch detail footprint_preflight candidates=$candidate_count secs=${elapsed}s"
}
# #4488 第二轮（spec #4495 的类级解法）：预测足迹本身也看不准，共享测试文件和
# 运行时热点是和历史共同修改耦合的。派发检查前把窗口内与预测文件同提交
# 出现过的热点文件（每提交每文件计一次，共同修改 ≥2 次，取次数前 12）并进
# 待派发 unit 的检查范围；命中在跑 worker 就先排队。扩展只在检查时计算，
# 不写进 .footprint——活跃足迹仍是 #4510 的预测 ∪ 实际写入，避免逐 tick 累积。
hotspot_log() { # 窗口内提交的文件分组清单，每 scheduler 进程取一次
  if [[ "${HOTSPOT_LOG_LOADED:-false}" != true ]]; then
    HOTSPOT_LOG_OK=true
    HOTSPOT_LOG="$(timeout --kill-after=1s 4s git -C "$ROOT" log --since=30.days --no-merges --no-renames --name-only --format=%x01 2>/dev/null)" || HOTSPOT_LOG_OK=false
    HOTSPOT_LOG_LOADED=true
  fi
  printf '%s' "$HOTSPOT_LOG"
}
hotspot_expand() { # scope_json -> scope ∪ 共同修改热点；历史读不出来时退回原足迹
  local scope="$1" added
  added="$(hotspot_log | jq -Rsc --slurpfile scope <(printf '%s' "$scope") '
    def in_scope: . as $f | any($scope[0][]; . as $s | $s == $f or ($f | startswith($s + "/")));
    [ split("\u0001")[]
      | split("\n") | map(select(length > 0)) | unique
      | select(length > 1 and length <= 40)
      | select(any(.[]; in_scope))
      | .[] | select(in_scope | not)
    ] | group_by(.) | map(select(length >= 2) | {f: .[0], n: length})
      | sort_by(-.n) | .[:12] | map(.f) | unique
  ' 2>/dev/null || true)"
  if [[ -n "$added" && "$added" != '[]' ]]; then
    scope="$(jq -cn --slurpfile scope <(printf '%s' "$scope") --slurpfile add <(printf '%s' "$added") '($scope[0] + $add[0]) | unique')"
  fi
  scope="$(scheduler_footprint_filter_main "$scope")" || return 1
  printf '%s\n' "$scope"
}
hotspot_expand_batch() { # [{id,scope}] → 同一份 30 天 git log 上批量扩展候选 check scope
  local candidates="$1" log
  log="$(hotspot_log)"
  jqf -Rsc --slurpfile candidates <(printf '%s' "$candidates") '
    def in_scope($scope; $path): any($scope[]; . as $s | . == $path or ($path | startswith($s + "/")));
    (split("\u0001") | map(split("\n") | map(select(length > 0)) | unique)) as $commits
    | [$candidates[0][] as $candidate
        | ($candidate.scope) as $scope
        | ([ $commits[]
             | select(length > 1 and length <= 40)
             | select(any(.[]; in_scope($scope; .)))
             | .[] | select(in_scope($scope; .) | not)
           ]
          | group_by(.) | map(select(length >= 2) | {f:.[0],n:length})
          | sort_by(-.n) | .[:12] | map(.f) | unique) as $added
        | {id:$candidate.id,scope:(($scope + $added) | unique)}]
  ' <<<"$log"
}
# shared-append 精确路径从足迹里剥离后再做互斥比较：两边只剩 shared-append 文件时不算冲突
# （不再串行 implement），文本冲突交给落地 rebase 处理，冲突率由 node_health 的
# ci.shared_append_rebase_conflict_pct 观测。目录条目不剥离：整包范围仍覆盖非共享文件，保持互斥。
footprint_strip_shared_append() { # scope_json -> 去掉 shared-append 精确路径后的 scope
  local scope="$1"
  local shared="${SHARED_APPEND:-[]}"
  [[ "$shared" != '[]' ]] || { printf '%s\n' "$scope"; return; }
  jqf -c --slurpfile sa <(printf '%s' "$shared") 'map(select(. as $x | any($sa[0][]; . == $x) | not))' <<<"$scope"
}
footprint_wait_mark() { # unit owner unit_json：记等待方与起始时间，intake 不把它算作占用产能
  say "footprint wait unit=$1 owner=$2"
  local marked_owner marked_since
  marked_owner="$(jqf -r '.footprint_wait_owner // empty' <<<"$3")"
  marked_since="$(jqf -r '.footprint_wait_since // empty' <<<"$3")"
  if [[ "$marked_owner" == "$2" && "$(ap_iso_epoch "$marked_since")" =~ ^[0-9]+$ ]]; then return 0; fi
  set_unit "$1" ".footprint_wait_owner=$(js "$2") | .footprint_wait_since=$(js "$STAMP")"
}
_footprint_room() {
  local id="$1" u="${2:-}" scope active conflict check_scope refreshed=false require_fresh="${3:-true}" stage
  # f9 kill switch（M2 故障注入 #4498）：footprint_mutex.enabled=false 跳过互斥。
  # 关掉后不再产生 "footprint wait" 事件，mechanism.silent 会在登记的沉默上限内报出。
  [[ "$(jqf -r 'if .footprint_mutex.enabled == false then "false" else "true" end' <<<"$CFG")" == true ]] || return 0
  [[ -n "$u" ]] || u="$(jqf -c --arg id "$id" '.units[] | select(.id==$id)' "$UNITS")"
  # 只读评审不写文件，不占互斥。implement/repair 候选一律对照活单元重查——尤其是释放过
  # 足迹又恢复的单元（supervisor-review/parked 裁决 requeue）：等待期间别的单元可能已在其
  # 足迹内启动，恢复派发必须先让位；自己的 PR 落地时才 rebase，救不了两个活 worker
  # 同时改同一批文件（#4488）。
  stage="$(jqf -r '.stage // empty' <<<"$u")"
  [[ "$stage" != review-pending && "$stage" != rereview-pending ]] || return 0
  if [[ "$require_fresh" != true ]] && footprint_preflight_snapshot; then
    conflict="${TICK_FOOTPRINT_PREFLIGHT_CONFLICT[$id]:-}"
    if [[ -n "$conflict" ]]; then
      footprint_wait_mark "$id" "$conflict" "$u"
      return 1
    fi
    [[ -n "${TICK_FOOTPRINT_CACHE[$id]+cached}" ]] && return 0
  fi
  scope="$(scheduler_footprint "$u")" || return 1
  if [[ -n "${TICK_FOOTPRINT_CACHE[$id]+cached}" ]]; then
    [[ "${TICK_FOOTPRINT_CACHE[$id]}" == "$scope" ]] || set_unit "$id" ".footprint=$scope"
  else
    [[ "$(jqf -c '.footprint // []' <<<"$u")" == "$scope" ]] || set_unit "$id" ".footprint=$scope"
  fi
  TICK_FOOTPRINT_CACHE["$id"]="$scope"
  if [[ "${TICK_CHECK_SCOPE_SOURCE[$id]:-}" == "$scope" ]]; then
    check_scope="${TICK_CHECK_SCOPE[$id]}"
  else
    hotspot_log >/dev/null
    check_scope="$(hotspot_expand "$scope")"
    [[ "${HOTSPOT_LOG_OK:-false}" == true ]] || HOTSPOT_LOG_LOADED=false
    TICK_CHECK_SCOPE_SOURCE["$id"]="$scope"
    TICK_CHECK_SCOPE["$id"]="$check_scope"
  fi
  if [[ "$TICK_ACTIVE_FOOTPRINTS_VALID" == true ]]; then
    active="$TICK_ACTIVE_FOOTPRINTS"
  else
    active="$(active_footprint_snapshot)" || return 1
    TICK_ACTIVE_FOOTPRINTS="$active"
    TICK_ACTIVE_FOOTPRINTS_VALID=true
    refreshed=true
  fi
  conflict="$(active_footprint_conflict "$check_scope" "$active" "$id")" || return 1
  if [[ -n "$conflict" ]]; then
    footprint_wait_mark "$id" "$conflict" "$u"
    return 1
  fi
  [[ "$require_fresh" == true ]] || return 0
  # A cached conflict can conservatively reject a candidate. A candidate that
  # appears clear must refresh every active worktree before it can be admitted.
  if [[ "$refreshed" != true ]]; then
    active="$(active_footprint_snapshot)" || return 1
    TICK_ACTIVE_FOOTPRINTS="$active"
    conflict="$(active_footprint_conflict "$check_scope" "$active" "$id")" || return 1
    if [[ -n "$conflict" ]]; then
      footprint_wait_mark "$id" "$conflict" "$u"
      return 1
    fi
  fi
}
footprint_room() { # unit type; report checks that materially delay dispatch
  local started=$SECONDS rc=0 elapsed
  _footprint_room "$@" || rc=$?
  # 放行后清掉等待记录；只在字段真有值时写 units.json
  if (( rc == 0 )) && [[ -n "$(jqf -r '.footprint_wait_owner // empty' <<<"${2:-null}")" ]]; then
    set_unit "$1" 'del(.footprint_wait_owner,.footprint_wait_since)'
  fi
  elapsed=$((SECONDS - started))
  (( elapsed >= 2 )) && say "dispatch detail footprint_check unit=$1 secs=${elapsed}s"
  return "$rc"
}
# Old wait-age markers are released only after their owner leaves the writer set. Do not weaken
# the footprint lock: this alert asks the supervisor to recut a convoy rather than admit conflicts.
footprint_convoy_alert() {
  local min_waiters wait_minutes owners owner waiters row id since since_epoch age waited_seconds aged_count aged_ids ids
  local max_age episode_epoch line key
  min_waiters="$(jqf -r '.footprint_mutex.convoy_min_waiters // 4' <<<"$CFG")"
  [[ "$min_waiters" =~ ^[1-9][0-9]*$ ]] || min_waiters=4
  wait_minutes="$(jqf -r '.footprint_mutex.convoy_wait_minutes // 15' <<<"$CFG")"
  [[ "$wait_minutes" =~ ^[1-9][0-9]*$ ]] || wait_minutes=15
  footprint_waiters_revalidate || return 1
  owners="$(jqf -r '[.units[] | select((.stage // "") | test("-pending$"))
    | select((.footprint_wait_owner // "") != "") | .footprint_wait_owner] | unique | .[]' "$UNITS")" || return 1
  while IFS= read -r owner; do
    [[ -n "$owner" ]] || continue
    waiters="$(jqf -c --arg owner "$owner" '[.units[] | select((.stage // "") | test("-pending$"))
      | select(.footprint_wait_owner==$owner) | {id,since:(.footprint_wait_since // "")}]' "$UNITS")" || return 1
    aged_ids='[]'; aged_count=0; max_age=0; episode_epoch=0
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      id="$(jqf -r .id <<<"$row")"
      since="$(jqf -r .since <<<"$row")"
      since_epoch="$(ap_iso_epoch "$since")"
      [[ "$since_epoch" =~ ^[0-9]+$ ]] || continue
      waited_seconds=$(( NOW_EPOCH - since_epoch ))
      (( waited_seconds > wait_minutes * 60 )) || continue
      age=$(( waited_seconds / 60 ))
      aged_count=$((aged_count + 1))
      (( age <= max_age )) || max_age=$age
      if (( episode_epoch == 0 || since_epoch < episode_epoch )); then episode_epoch=$since_epoch; fi
      aged_ids="$(jqf -cn --slurpfile ids <(printf '%s' "$aged_ids") --arg id "$id" '$ids[0] + [$id]')" || return 1
    done < <(jqf -c '.[]' <<<"$waiters")
    (( aged_count >= min_waiters )) || continue
    ids="$(jqf -r 'join(",")' <<<"$aged_ids")"
    line="footprint-convoy owner=$owner waiters=$ids oldest_wait_min=$max_age min_waiters=$min_waiters wait_minutes=$wait_minutes action=recut-overlapping-scopes"
    key="footprint-convoy:$owner:$episode_epoch"
    say "$line"
    (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "$key" "$line") \
      || say "footprint-convoy alert not delivered owner=$owner"
  done <<<"$owners"
}
refill_dispatch_metrics() { # log byte offset live count -> one-line refill state and skip totals
  local log_offset="$1" live="$2" free pending footprint handoff memory log_end log_bytes
  footprint_waiters_revalidate || return 1
  [[ "$live" =~ ^[0-9]+$ ]] || live=0
  free=$(( MAX - live )); (( free >= 0 )) || free=0
  pending="$(jqf '[.units[] | select((.stage // "") | test("^(implement|repair|review|rereview)-pending$"))] | length' "$UNITS")" || return 1
  footprint="$(jqf '[.units[] | select((.stage // "") | test("-pending$")) | select((.footprint_wait_owner // "") != "")] | length' "$UNITS")" || return 1
  handoff="$(jqf '[.units[] | select((.stage // "") | test("-pending$")) | select(.hold_handoff_waiting == true)] | length' "$UNITS")" || return 1
  memory=0
  if [[ "$log_offset" =~ ^[0-9]+$ && -f "$LOG" ]]; then
    log_end="$(wc -c < "$LOG")"
    if (( log_end < log_offset )); then log_offset=0; fi
    log_bytes=$((log_end - log_offset))
    if (( log_bytes > 0 )); then
      memory="$(tail -c +$((log_offset + 1)) "$LOG" 2>/dev/null | head -c "$log_bytes" \
        | awk '/execution admission decision mode=run-unit outcome=defer/ && /reason=resource-floor$/ { n++ } END { print n+0 }')"
    fi
    printf '%s\n' "$log_end" > "$A/.refill-dispatch-log-offset.tmp" \
      && mv -f -- "$A/.refill-dispatch-log-offset.tmp" "$A/.refill-dispatch-log-offset" || return 1
  fi
  printf 'free_slots=%s pending=%s skips=footprint:%s,handoff:%s,memory:%s\n' \
    "$free" "$pending" "$footprint" "$handoff" "$memory"
}
# 每 tick：活 worker 跑超 hog_alert_minutes 且挡住 >hog_alert_blocked 个 *-pending 单元时只告警，不停 worker（2026-10-30 issue-3015/4280）
footprint_hog_alert() {
  local minutes blocked_min w unit type started pid s age waiters blocked line
  minutes="$(jqf -r '.footprint_mutex.hog_alert_minutes // 120' <<<"$CFG")"; [[ "$minutes" =~ ^[0-9]+$ ]] || minutes=120
  blocked_min="$(jqf -r '.footprint_mutex.hog_alert_blocked // 3' <<<"$CFG")"; [[ "$blocked_min" =~ ^[0-9]+$ ]] || blocked_min=3
  while IFS= read -r w; do
    unit="$(jqf -r .unit <<<"$w")"; type="$(jqf -r .type <<<"$w")"; started="$(jqf -r .started <<<"$w")"; pid="$(jqf -r .pid <<<"$w")"
    [[ -n "$unit" && "$pid" =~ ^[0-9]+$ ]] && alive "$pid" || continue
    s="$(ap_iso_epoch "$started")"; [[ "$s" =~ ^[0-9]+$ ]] || continue
    age=$(( (NOW_EPOCH - s) / 60 ))
    (( age > minutes )) || continue
    waiters="$(jqf -c --arg u "$unit" '[.units[] | select(.stage | test("-pending$")) | select((.footprint_wait_owner // "") == $u) | .id]' "$UNITS")"
    blocked="$(jqf length <<<"$waiters")"
    (( blocked > blocked_min )) || continue
    line="footprint-hog unit=$unit type=$type age_min=$age blocks=$blocked units=$(jqf -r 'join(",")' <<<"$waiters")"
    say "$line"
    (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "footprint-hog:$unit:$started" "$line") \
      || say "footprint-hog alert not delivered unit=$unit"
  done < <(jqf -c '.workers[] | select(.harvested != true)' "$WORKERS")
}

# The Stop-hook pattern without an LLM: use the Touched packages job's selector.
# No workspace package in the diff means no package gate, not a new repo gate.
# The heavy install/build/test steps default to cihost through the pipeline's
# single remote execution entry; ZF_SELF_CHECK_LOCAL=1 is the operator
# escape hatch while cihost is under maintenance.
test_evidence_has_pass() {
  python3 "$HERE/test-evidence.py" has "$SUP/test-evidence.jsonl" "$1" "$2"
}
test_evidence_record_pass() {
  # Both outcomes reach scheduler.log: the mechanism-registry f5 heartbeat matches
  # "test evidence" on the recorded line, so a healthy ledger is not indistinguishable
  # from a dead one.
  if python3 "$HERE/test-evidence.py" record "$SUP/test-evidence.jsonl" "$1" "$2" "$3"; then
    say "test evidence recorded tree=$1 target=$2 source=$3"
  else
    say "test evidence not persisted tree=$1 target=$2 source=$3"
  fi
}
