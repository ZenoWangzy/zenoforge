# #4488: 预测足迹挡不住在跑 worker 越界写共享文件（collisions_per_day=97，全是真实并发写）。
# 派发检查把在跑 unit 的 worktree 里已发生的改动（已提交 + 未提交 + 未跟踪）并进它的足迹。
live_writes_union() { # workdir scope_json -> scope ∪ 实际已写路径；workdir 不可读时退回预测
  local wd="$1" scope="$2" live base
  if [[ -n "$wd" && -d "$wd" ]]; then
    base="$(git -C "$wd" merge-base origin/main HEAD 2>/dev/null || true)"
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
    scope="$(jq -cn --argjson scope "$scope" --argjson live "$live" '($scope + $live) | unique')"
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
      jq -cn --argjson unit "$other" --argjson scope "$other_scope" \
        '$unit + {resolved_footprint:$scope}' > "$file"
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
    units_update --argjson updates "$updates" \
      '.units |= map(. as $unit
        | ([$updates[] | select(.id == $unit.id)][0] // null) as $update
        | if $update == null then . else .footprint = $update.footprint end)' \
      || { rm -rf -- "$scan_dir"; return 1; }
  fi
  resolved="$(jqf -c 'map(. + {footprint:.resolved_footprint} | del(.resolved_footprint, .live_workdir))' <<<"$rows")" \
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
  active="$(jqf -c --slurpfile w "$WORKERS" '
    [.units[] | . as $u
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
    expanded_scopes="$(hotspot_expand_batch "$scope_candidates")" \
      || { footprint_drop_check_scope_cache; return 1; }
    while IFS= read -r row; do
      id="$(jqf -r '.id' <<<"$row")"
      check_scope="$(jqf -c '.scope' <<<"$row")"
      TICK_CHECK_SCOPE["$id"]="$check_scope"
    done < <(jqf -c '.[]' <<<"$expanded_scopes")
    footprint_refresh_conflicts cached || return 1
  fi
  updates="$(jqf -Rn '[inputs | split("\t") | select(length == 2) | {key:.[0],value:(.[1] | fromjson)}] | from_entries' <<<"$scope_rows")" || return 1
  update_count="$(jqf --argjson scopes "$updates" '[.units[] | select($scopes[.id] != null and (.footprint // []) != $scopes[.id])] | length' "$UNITS")" || return 1
  if (( update_count > 0 )); then
    units_update --argjson scopes "$updates" \
      '.units |= map(if $scopes[.id] != null then .footprint=$scopes[.id] else . end)' || return 1
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
  if [[ -z "${HOTSPOT_LOG:-}" ]]; then
    HOTSPOT_LOG="$(timeout --kill-after=1s 4s git -C "$ROOT" log --since=30.days --no-merges --no-renames --name-only --format=%x01 2>/dev/null || true)"
  fi
  printf '%s' "$HOTSPOT_LOG"
}
hotspot_expand() { # scope_json -> scope ∪ 共同修改热点；历史读不出来时退回原足迹
  local scope="$1" added
  added="$(hotspot_log | jq -Rsc --argjson scope "$scope" '
    def in_scope: . as $f | any($scope[]; . as $s | $s == $f or ($f | startswith($s + "/")));
    [ split("\u0001")[]
      | split("\n") | map(select(length > 0)) | unique
      | select(length > 1 and length <= 40)
      | select(any(.[]; in_scope))
      | .[] | select(in_scope | not)
    ] | group_by(.) | map(select(length >= 2) | {f: .[0], n: length})
      | sort_by(-.n) | .[:12] | map(.f) | unique
  ' 2>/dev/null || true)"
  if [[ -n "$added" && "$added" != '[]' ]]; then
    scope="$(jq -cn --argjson scope "$scope" --argjson add "$added" '($scope + $add) | unique')"
  fi
  printf '%s\n' "$scope"
}
hotspot_expand_batch() { # [{id,scope}] → 同一份 30 天 git log 上批量扩展候选 check scope
  local candidates="$1" log
  log="$(hotspot_log)"
  jqf -Rsc --argjson candidates "$candidates" '
    def in_scope($scope; $path): any($scope[]; . as $s | . == $path or ($path | startswith($s + "/")));
    (split("\u0001") | map(split("\n") | map(select(length > 0)) | unique)) as $commits
    | [$candidates[] as $candidate
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
  jqf -c --argjson sa "$shared" 'map(select(. as $x | any($sa[]; . == $x) | not))' <<<"$scope"
}
_footprint_room() {
  local id="$1" u="${2:-}" scope active conflict check_scope refreshed=false require_fresh="${3:-true}"
  # f9 kill switch（M2 故障注入 #4498）：footprint_mutex.enabled=false 跳过互斥。
  # 关掉后不再产生 "footprint wait" 事件，mechanism.silent 会在登记的沉默上限内报出。
  [[ "$(jqf -r 'if .footprint_mutex.enabled == false then "false" else "true" end' <<<"$CFG")" == true ]] || return 0
  [[ -n "$u" ]] || u="$(jqf -c --arg id "$id" '.units[] | select(.id==$id)' "$UNITS")"
  if [[ "$require_fresh" != true ]] && footprint_preflight_snapshot; then
    conflict="${TICK_FOOTPRINT_PREFLIGHT_CONFLICT[$id]:-}"
    if [[ -n "$conflict" ]]; then
      say "footprint wait unit=$id owner=$conflict"
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
    check_scope="$(hotspot_expand "$scope")"
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
    say "footprint wait unit=$id owner=$conflict"
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
      say "footprint wait unit=$id owner=$conflict"
      return 1
    fi
  fi
}
footprint_room() { # unit type; report checks that materially delay dispatch
  local started=$SECONDS rc=0 elapsed
  _footprint_room "$@" || rc=$?
  elapsed=$((SECONDS - started))
  (( elapsed >= 2 )) && say "dispatch detail footprint_check unit=$1 secs=${elapsed}s"
  return "$rc"
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
  python3 "$HERE/test-evidence.py" record "$SUP/test-evidence.jsonl" "$1" "$2" "$3" \
    || say "test evidence not persisted tree=$1 target=$2 source=$3"
}
