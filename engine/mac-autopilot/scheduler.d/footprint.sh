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
    # Merging anything else, such as a branch's own old tip, leaves that branch's history as the base: every
    # change on main since then would read as this worker's write (#2514: 3241 paths, and intake stopped).
    if merge_head="$(git -C "$wd" rev-parse -q --verify MERGE_HEAD 2>/dev/null)" && [[ -n "$merge_head" ]] \
      && git -C "$wd" merge-base --is-ancestor "$merge_head" refs/remotes/origin/main 2>/dev/null; then
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
# scheduler_footprint is a pure function of the unit row, the issue state file and origin/main, and costs about 24 processes. One dispatch
# pass asked for it 3 to 4 times per candidate and once per live owner at every fresh snapshot. TICK_FOOTPRINT_MAIN (set by dispatch_pending;
# empty anywhere else, which bypasses the memo) keys the rows to the main they were filtered against.
declare -gA TICK_FOOTPRINT_SCOPE_MEMO=()
TICK_FOOTPRINT_MAIN=''
footprint_scope_for() { # unit-json var-name -> sets the variable to scheduler_footprint's scope; fills the memo only in the caller's shell
  local key="$TICK_FOOTPRINT_MAIN|$1" out
  if [[ -z "$TICK_FOOTPRINT_MAIN" ]]; then
    out="$(scheduler_footprint "$1")" || return 1
  elif [[ -n "${TICK_FOOTPRINT_SCOPE_MEMO[$key]+set}" ]]; then
    out="${TICK_FOOTPRINT_SCOPE_MEMO[$key]}"
  else
    out="$(scheduler_footprint "$1")" || return 1
    TICK_FOOTPRINT_SCOPE_MEMO["$key"]="$out"
  fi
  printf -v "$2" %s "$out"
}
resolve_active_footprints() { # active-unit JSON array → fresh live scopes; scan worktrees concurrently, persist ledger changes once
  local active="$1" scan_dir other file scope workdir rows updates resolved rc=0 index=0 pid
  local -a pids=() memo_keys=()
  scan_dir="$(mktemp -d)" || return 1
  while IFS= read -r other; do
    [[ -n "$other" ]] || continue
    file="$scan_dir/$index.json"
    memo_keys+=("$TICK_FOOTPRINT_MAIN|$other")
    {
      local other_scope other_workdir
      if [[ -n "$TICK_FOOTPRINT_MAIN" && -n "${TICK_FOOTPRINT_SCOPE_MEMO[$TICK_FOOTPRINT_MAIN|$other]+set}" ]]; then
        other_scope="${TICK_FOOTPRINT_SCOPE_MEMO[$TICK_FOOTPRINT_MAIN|$other]}"
      else
        other_scope="$(scheduler_footprint "$other")" || exit 1
        printf '%s' "$other_scope" > "$file.scope" # the background job cannot fill the memo itself
      fi
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
  if [[ -n "$TICK_FOOTPRINT_MAIN" ]]; then
    for index in "${!memo_keys[@]}"; do
      [[ ! -f "$scan_dir/$index.json.scope" ]] || TICK_FOOTPRINT_SCOPE_MEMO["${memo_keys[$index]}"]="$(<"$scan_dir/$index.json.scope")"
    done
  fi
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
  TICK_OLD_SCOPE=()
  TICK_HOTSPOT_COUNTS=()
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
# A tree entry is a directory; missing paths remain file predictions (new files).
footprint_classify() {
  local scope="$1" path type specs='' types index=0 # one jq for the scope: a live scope can hold thousands of paths
  local -a paths=() objects=()
  mapfile -t paths < <(jq -r '.[]?' <<<"$scope")
  for path in "${paths[@]}"; do specs+="refs/remotes/origin/main:$path"$'\n'; done
  types="$(printf '%s' "$specs" | git -C "$ROOT" cat-file --batch-check='%(objecttype)' 2>/dev/null)" || types=''
  mapfile -t objects <<<"$types"
  for path in "${paths[@]}"; do
    type=file
    if [[ -d "$ROOT/$path" || "${objects[$index]:-}" == tree ]]; then type=directory; fi
    printf '%s\t%s\n' "$type" "$path"
    index=$((index + 1))
  done | jq -Rsc '[split("\n")[] | select(length > 0) | split("\t") | {path: (.[1:] | join("\t")), type: .[0]}]'
}
footprint_scopes_collide() { # scope, scope -> collision paths in EXPECTED_SCOPE_COLLISION_*
  local candidate="$1" owner="$2" original="${3:-$1}" result c o known
  if [[ "${ZF_FOOTPRINT_DIRECTORY_PREFIX_MATCHING:-0}" == 1 ]]; then
    expected_packages_collide "$candidate" "$owner"
    return $?
  fi
  FOOTPRINT_FAILED_STEP=classify
  c="$(footprint_classify "$candidate")" || return 2
  o="$(footprint_classify "$owner")" || return 2
  known="$(footprint_classify "$original")" || return 2
  FOOTPRINT_FAILED_STEP=compare
  # By file: argv holds 128KiB per value, and one owner over that fails every comparison against it.
  result="$(jq -cn --slurpfile c <(printf '%s' "$c") --slurpfile o <(printf '%s' "$o") --slurpfile known <(printf '%s' "$known") '
    def overlaps($a; $b): $a == $b or ($a | startswith($b + "/")) or ($b | startswith($a + "/"));
    (any($known[0][]; .type == "file")) as $cf | (any($o[0][]; .type == "file")) as $of
    | first($c[0][] as $a | $o[0][] as $b | select(overlaps($a.path; $b.path))
      | select(($a.type == "file" and $b.type == "file") or ($cf | not) or ($of | not)
        or ($a.path | test("(^|/)migrations/meta/_journal\\.json$")) or ($b.path | test("(^|/)migrations/meta/_journal\\.json$")))
      | [$a.path,$b.path]) // []')" || return 2
  EXPECTED_SCOPE_COLLISION_CANDIDATE="$(jq -r '.[0] // empty' <<<"$result")"
  EXPECTED_SCOPE_COLLISION_ACTIVE="$(jq -r '.[1] // empty' <<<"$result")"
  [[ -n "$EXPECTED_SCOPE_COLLISION_CANDIDATE" ]]
}
# A comparison batch classifies each distinct scope once and compares a candidate against every owner in one jq.
# The memo and the owner rows live in the shell that runs the batch: a command substitution cannot keep them, so
# active_footprint_conflict (one candidate) and active_footprint_conflicts_batch are subshell bodies around these.
declare -gA FOOTPRINT_CLASSIFY_MEMO=()
declare -ga FOOTPRINT_OWNER_IDS=() FOOTPRINT_OWNER_SCOPES=()
FOOTPRINT_OWNERS_DOC='[]'
FOOTPRINT_CONFLICT_OWNER=''
footprint_classify_memo() { # scope -> FOOTPRINT_CLASSIFIED; call in the batch shell, never inside $( )
  if [[ -z "${FOOTPRINT_CLASSIFY_MEMO[$1]+set}" ]]; then
    FOOTPRINT_CLASSIFY_MEMO["$1"]="$(footprint_classify "$1")" || return 1
  fi
  FOOTPRINT_CLASSIFIED="${FOOTPRINT_CLASSIFY_MEMO[$1]}"
}
footprint_owners_prepare() { # owners-json: ids, stripped scopes and classified rows (null when classify failed), memo reset
  local id scope sep=''
  FOOTPRINT_CLASSIFY_MEMO=(); FOOTPRINT_OWNER_IDS=(); FOOTPRINT_OWNER_SCOPES=(); FOOTPRINT_OWNERS_DOC='['
  while IFS= read -r -d '' id && IFS= read -r -d '' scope; do
    scope="$(footprint_strip_shared_append "$scope")"
    FOOTPRINT_OWNER_IDS+=("$id"); FOOTPRINT_OWNER_SCOPES+=("$scope")
    if [[ "${ZF_FOOTPRINT_DIRECTORY_PREFIX_MATCHING:-0}" != 1 ]]; then
      if footprint_classify_memo "$scope"; then FOOTPRINT_OWNERS_DOC+="$sep$FOOTPRINT_CLASSIFIED"; else FOOTPRINT_OWNERS_DOC+="${sep}null"; fi
      sep=,
    fi
  done < <(jq -j '.[] | (.id | if type == "string" then . else tojson end), "\u0000", ((.footprint // []) | tojson), "\u0000"' <<<"$1")
  FOOTPRINT_OWNERS_DOC+=']'
}
footprint_owner_conflict() { # candidate scope, self id, original scope -> FOOTPRINT_CONFLICT_OWNER; rc 0 or 2 as the legacy pair loop
  local candidate original i first=-1 flags='' sep='' c k hit rc
  FOOTPRINT_CONFLICT_OWNER=''
  original="$(footprint_strip_shared_append "${3:-$1}")"
  candidate="$(footprint_strip_shared_append "$1")"
  for i in "${!FOOTPRINT_OWNER_IDS[@]}"; do
    if [[ "${FOOTPRINT_OWNER_IDS[$i]}" == "$2" ]]; then flags+="${sep}true"; else flags+="${sep}false"; (( first >= 0 )) || first=$i; fi
    sep=,
  done
  (( first >= 0 )) || return 0
  if [[ "${ZF_FOOTPRINT_DIRECTORY_PREFIX_MATCHING:-0}" == 1 ]]; then # the old rule keeps its per-pair helper
    for i in "${!FOOTPRINT_OWNER_IDS[@]}"; do
      [[ "${FOOTPRINT_OWNER_IDS[$i]}" != "$2" ]] || continue
      if footprint_scopes_collide "$candidate" "${FOOTPRINT_OWNER_SCOPES[$i]}" "$original"; then
        FOOTPRINT_CONFLICT_OWNER="${FOOTPRINT_OWNER_IDS[$i]}"; return 0
      else
        rc=$?
        (( rc == 1 )) || { say "footprint comparison failed candidate=$2 owner=${FOOTPRINT_OWNER_IDS[$i]} step=${FOOTPRINT_FAILED_STEP:-unknown} rc=$rc"; return "$rc"; }
      fi
    done
    return 0
  fi
  if ! { footprint_classify_memo "$candidate" && c="$FOOTPRINT_CLASSIFIED" && footprint_classify_memo "$original" && k="$FOOTPRINT_CLASSIFIED"; }; then
    say "footprint comparison failed candidate=$2 owner=${FOOTPRINT_OWNER_IDS[$first]} step=classify rc=2"; return 2
  fi
  # By file: argv holds 128KiB per value, and one owner over that fails every comparison against it.
  hit="$(jq -rn --slurpfile c <(printf '%s' "$c") --slurpfile k <(printf '%s' "$k") --slurpfile o <(printf '%s' "$FOOTPRINT_OWNERS_DOC") --argjson skip "[$flags]" '
    def overlaps($a; $b): $a == $b or ($a | startswith($b + "/")) or ($b | startswith($a + "/"));
    (any($k[0][]; .type == "file")) as $cf
    | first(range($o[0] | length) as $i | select($skip[$i] | not) | $o[0][$i] as $e
      | if $e == null then "F\($i)" else
          (any($e[]; .type == "file")) as $of
          | select(any($c[0][] as $a | $e[] as $b | select(overlaps($a.path; $b.path))
            | select(($a.type == "file" and $b.type == "file") or ($cf | not) or ($of | not)
              or ($a.path | test("(^|/)migrations/meta/_journal\\.json$")) or ($b.path | test("(^|/)migrations/meta/_journal\\.json$"))); true))
          | "\($i)" end)')" \
    || { say "footprint comparison failed candidate=$2 owner=${FOOTPRINT_OWNER_IDS[$first]} step=compare rc=2"; return 2; }
  if [[ "$hit" == F* ]]; then
    say "footprint comparison failed candidate=$2 owner=${FOOTPRINT_OWNER_IDS[${hit#F}]} step=classify rc=2"; return 2
  fi
  [[ -z "$hit" ]] || FOOTPRINT_CONFLICT_OWNER="${FOOTPRINT_OWNER_IDS[$hit]}"
  return 0
}
active_footprint_conflict() (
  scheduler_scope_lib open-pr-collision || { say "footprint comparison failed candidate=$3 step=load-lib rc=2"; exit 2; }
  footprint_owners_prepare "$2"
  footprint_owner_conflict "$1" "$3" "${4:-$1}" || exit $?
  [[ -z "$FOOTPRINT_CONFLICT_OWNER" ]] || printf '%s\n' "$FOOTPRINT_CONFLICT_OWNER"
)
active_footprint_conflicts_batch() ( # one memo and one owner pass for every candidate row
  local active="$1" candidates="$2" id scope original prepared=false
  while IFS=$'\t' read -r id scope original; do
    [[ -n "$id" ]] || continue
    if [[ "$prepared" != true ]]; then
      scheduler_scope_lib open-pr-collision || { say "footprint comparison failed candidate=$id step=load-lib rc=2"; return 1; }
      footprint_owners_prepare "$active"; prepared=true
    fi
    footprint_owner_conflict "$scope" "$id" "${original:-$scope}" || return 1
    [[ -z "$FOOTPRINT_CONFLICT_OWNER" ]] || printf '%s\t%s\n' "$id" "$FOOTPRINT_CONFLICT_OWNER"
  done <<<"$candidates"
)
footprint_shadow_directory_rule() {
  [[ "${ZF_FOOTPRINT_DIRECTORY_PREFIX_MATCHING:-0}" != 1 ]] || return 0
  local id="$1" active="$2" old_owner
  old_owner="$(ZF_FOOTPRINT_DIRECTORY_PREFIX_MATCHING=1 active_footprint_conflict "${TICK_CHECK_SCOPE[$id]:-[]}" "$active" "$id")" || return 1
  [[ -z "$old_owner" ]] || say "footprint-shadow-old-rule-would-block unit=$id owner=$old_owner source=directory-prefix"
}
footprint_refresh_conflicts() {
  local refresh="${1:-true}" started=$SECONDS active candidates conflicts id owner elapsed
  if [[ "$refresh" == true ]]; then
    active="$(active_footprint_snapshot)" || { footprint_drop_check_scope_cache; return 1; }
    TICK_ACTIVE_FOOTPRINTS="$active"
    TICK_ACTIVE_FOOTPRINTS_VALID=true
  else
    [[ "$TICK_ACTIVE_FOOTPRINTS_VALID" == true ]] || { footprint_drop_check_scope_cache; return 1; }
    active="$TICK_ACTIVE_FOOTPRINTS"
  fi
  candidates="$(footprint_candidate_rows)"
  conflicts="$(active_footprint_conflicts_batch "$active" "$candidates")" \
    || { footprint_drop_check_scope_cache; return 1; }
  TICK_FOOTPRINT_PREFLIGHT_CONFLICT=()
  while IFS=$'\t' read -r id owner; do
    [[ -n "$id" ]] && TICK_FOOTPRINT_PREFLIGHT_CONFLICT["$id"]="${owner:-unknown}"
  done <<<"$conflicts"
  TICK_FOOTPRINT_CONFLICT_VALID=true
  TICK_FOOTPRINT_COMPARED_ACTIVE="$active"
  elapsed=$((SECONDS - started))
  (( elapsed < 2 )) || say "dispatch detail footprint_conflict_refresh candidates=${#TICK_FOOTPRINT_PREFLIGHT_IDS[@]} secs=${elapsed}s cache=$FOOTPRINT_CACHE_PREFLIGHT"
}
footprint_candidate_rows() { # [clear]: only candidates with no conflict yet
  local id scope
  for id in "${TICK_FOOTPRINT_PREFLIGHT_IDS[@]}"; do
    [[ -n "$id" ]] || continue
    [[ "${1:-}" != clear || -z "${TICK_FOOTPRINT_PREFLIGHT_CONFLICT[$id]:-}" ]] || continue
    scope="${TICK_CHECK_SCOPE[$id]:-[]}"
    printf '%s\t%s\t%s\n' "$id" "$scope" "${TICK_FOOTPRINT_CACHE[$id]:-$scope}"
  done
}
# After a start only owner rows changed since the last comparison can add a conflict: the fold, and any fresh snapshot in between that widened an owner.
# A conflict kept past its owner only delays that candidate until the next full comparison; the fresh admission check stays the guard either way.
footprint_merge_changed_owners() {
  local started=$SECONDS changed candidates conflicts id owner
  if [[ "$TICK_FOOTPRINT_CONFLICT_VALID" != true || -z "$TICK_FOOTPRINT_COMPARED_ACTIVE" ]]; then
    footprint_refresh_conflicts cached
    return
  fi
  changed="$(jqf -c --slurpfile old <(printf '%s' "$TICK_FOOTPRINT_COMPARED_ACTIVE") '. - $old[0]' <<<"$TICK_ACTIVE_FOOTPRINTS")" \
    || { footprint_drop_check_scope_cache; return 1; }
  candidates="$(footprint_candidate_rows clear)"
  conflicts="$(active_footprint_conflicts_batch "$changed" "$candidates")" \
    || { footprint_drop_check_scope_cache; return 1; }
  while IFS=$'\t' read -r id owner; do
    [[ -n "$id" ]] && TICK_FOOTPRINT_PREFLIGHT_CONFLICT["$id"]="${owner:-unknown}"
  done <<<"$conflicts"
  TICK_FOOTPRINT_COMPARED_ACTIVE="$TICK_ACTIVE_FOOTPRINTS"
  say "dispatch detail footprint_conflict_merge candidates=$(grep -c . <<<"$candidates") owners=$(jqf 'length' <<<"$changed") secs=$((SECONDS - started))s"
}
# Candidate expansion cache: hotspot_expand_batch is the slow step (2.7s for one 800-path scope, run per candidate in the preflight).
# A row is a pure function of the candidate scope, the unit's PR head, origin/main (filter_main), the checkout HEAD (hotspot_log reads it),
# ZF_FOOTPRINT_HOTSPOT_MIN and the UTC day (30-day window; shortcut: a commit aging out mid-day shows at the next day). Live owner writes are
# not in it: conflict checks always re-read the active worktrees. Files: $A/footprint-cache/<main sha>-<key>.json, like triage-cache.
FOOTPRINT_CACHE_KEEP=256 FOOTPRINT_CACHE_STATE=miss FOOTPRINT_CACHE_PREFLIGHT=miss FOOTPRINT_CACHE_PRUNED= # hit: no miss in the last batch, not fresh
footprint_unit_head() { jqf -r '.reviewed_pr_head // .reviewed_sha // .pr_head // .head_sha // ""' <<<"$1"; } # unit-json -> PR head sha or empty
footprint_cache_prune() { # main sha: keep only entries of the current main, then the newest FOOTPRINT_CACHE_KEEP
  local dir="$A/footprint-cache" f n=0
  [[ "$FOOTPRINT_CACHE_PRUNED" != "$1" ]] || return 0
  FOOTPRINT_CACHE_PRUNED="$1"
  rm -f -- "$dir"/.*.tmp 2>/dev/null || :
  for f in "$dir"/*; do
    [[ -e "$f" ]] || continue
    [[ "${f##*/}" == "$1-"*.json ]] || rm -f -- "$f"
  done
  for f in $(ls -t "$dir" 2>/dev/null); do
    n=$((n + 1)); (( n <= FOOTPRINT_CACHE_KEEP )) || rm -f -- "$dir/$f"
  done
}
footprint_expand_rows() { # rows [{id,scope,head}], fresh -> TICK_CHECK_SCOPE/OLD_SCOPE/HOTSPOT_COUNTS per id; fresh=true skips the lookup but still stores
  local rows="$1" fresh="${2:-false}" dir="$A/footprint-cache" main='' rhead='' min day id head scope key file row miss_ids='' total=0 hits=0
  local -A keys=(); local -a miss=() parts=()
  FOOTPRINT_CACHE_STATE=miss
  main="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)" || main=''
  rhead="$(git -C "$ROOT" rev-parse -q --verify HEAD 2>/dev/null)" || rhead=''
  min="$(hotspot_minimum)"; day="$(date -u +%F)"
  while IFS= read -r -d '' id && IFS= read -r -d '' head && IFS= read -r -d '' scope; do
    total=$((total + 1)); key=''
    if [[ -n "$main" && -n "$rhead" ]]; then
      key="$main-$(printf '%s\0' v1 "$main" "$rhead" "$head" "$min" "$day" "$scope" | sha256sum | cut -c1-40).json"
    fi
    keys["$id"]="$key"; file="$dir/$key"
    parts=()
    # Compact JSON has no raw newline: three lines are scope, old_scope, counts; anything else is a miss.
    [[ "$fresh" == true || -z "$key" || ! -s "$file" ]] || mapfile -t parts < <(jq -r '[(.scope | tojson), (.old_scope | tojson), (.counts | tojson)] | join("\n")' "$file" 2>/dev/null)
    if (( ${#parts[@]} == 3 )); then
      TICK_CHECK_SCOPE["$id"]="${parts[0]}"; TICK_OLD_SCOPE["$id"]="${parts[1]}"; TICK_HOTSPOT_COUNTS["$id"]="${parts[2]}"
      hits=$((hits + 1))
    else
      miss+=("$id"); miss_ids+="$id"$'\n'
    fi
  done < <(jq -j '.[] | (.id | if type == "string" then . else tojson end), "\u0000", (.head // ""), "\u0000", (.scope | tojson), "\u0000"' <<<"$rows")
  if (( ${#miss[@]} > 0 )); then
    local expanded filtered_scope filtered_old tmp
    hotspot_log >/dev/null # Subshell expansions must inherit the same history.
    expanded="$(hotspot_expand_batch "$(jq -c --argjson ids "$(printf '%s' "$miss_ids" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
      '[.[] | select((.id | if type == "string" then . else tojson end) as $i | $ids | index($i)) | {id,scope}]' <<<"$rows")")" || return 1
    [[ "${HOTSPOT_LOG_OK:-false}" == true ]] || HOTSPOT_LOG_LOADED=false
    while IFS= read -r row; do
      id="$(jqf -r '.id' <<<"$row")"
      filtered_scope="$(scheduler_footprint_filter_main "$(jqf -c '.scope' <<<"$row")")" || return 1
      filtered_old="$(scheduler_footprint_filter_main "$(jqf -c '.old_scope' <<<"$row")")" || return 1
      TICK_CHECK_SCOPE["$id"]="$filtered_scope"; TICK_OLD_SCOPE["$id"]="$filtered_old"
      TICK_HOTSPOT_COUNTS["$id"]="$(jqf -c '.counts' <<<"$row")"
      # A failed history read gives a degraded expansion: never store it.
      if [[ "${HOTSPOT_LOG_OK:-false}" == true && -n "${keys[$id]:-}" ]] && mkdir -p "$dir" 2>/dev/null; then
        tmp="$dir/.${keys[$id]}.$$.tmp"
        if jq -cn --argjson scope "$filtered_scope" --argjson old "$filtered_old" --argjson counts "${TICK_HOTSPOT_COUNTS[$id]}" \
          '{scope:$scope,old_scope:$old,counts:$counts}' >"$tmp" 2>/dev/null && mv -f -- "$tmp" "$dir/${keys[$id]}"; then :; else rm -f -- "$tmp"; fi
      fi
    done < <(jqf -c '.[]' <<<"$expanded")
    [[ -z "$main" ]] || footprint_cache_prune "$main"
  fi
  (( total > 0 && hits == total )) && FOOTPRINT_CACHE_STATE=hit
  return 0
}
footprint_preflight_snapshot() {
  if [[ "$TICK_FOOTPRINT_PREFLIGHT_STATUS" == ready ]]; then
    [[ "$TICK_FOOTPRINT_CONFLICT_VALID" == true ]] && return 0
    footprint_refresh_conflicts true || return 1
    return 0
  fi
  [[ "$TICK_FOOTPRINT_PREFLIGHT_STATUS" == not-started ]] || return 1
  TICK_FOOTPRINT_PREFLIGHT_STATUS=failed
  local started=$SECONDS scope_rows='' clear_scope_rows='' scope_candidates updates update_count u id head scope elapsed candidate_count=0
  local -A heads=()
  FOOTPRINT_CACHE_PREFLIGHT=miss
  local candidate_filter='.units[] | select(.stage == "implement-pending" or .stage == "repair-pending")'
  [[ "$TICK_DISPATCH_LOCAL_REFILL" != true ]] || candidate_filter='.units[] | select(.stage == "implement-pending")'
  TICK_FOOTPRINT_PREFLIGHT_IDS=()
  while IFS= read -r u; do
    id="$(jqf -r '.id' <<<"$u")"
    heads["$id"]="$(footprint_unit_head "$u")"
    footprint_scope_for "$u" scope || return 1
    TICK_FOOTPRINT_CACHE["$id"]="$scope"
    TICK_FOOTPRINT_PREFLIGHT_IDS+=("$id")
    TICK_CHECK_SCOPE_SOURCE["$id"]="$scope"
    TICK_CHECK_SCOPE["$id"]="$scope"
    TICK_OLD_SCOPE["$id"]="$scope"
    TICK_HOTSPOT_COUNTS["$id"]='{}'
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
    clear_scope_rows+="$id"$'\t'"$scope"$'\t'"${heads[$id]:-}"$'\n'
  done <<<"$scope_rows"
  if [[ -n "$clear_scope_rows" ]]; then
    scope_candidates="$(jqf -Rn '[inputs | split("\t") | select(length == 3) | {id:.[0],scope:(.[1] | fromjson),head:.[2]}]' <<<"$clear_scope_rows")" \
      || { footprint_drop_check_scope_cache; return 1; }
    footprint_expand_rows "$scope_candidates" false || { footprint_drop_check_scope_cache; return 1; }
    FOOTPRINT_CACHE_PREFLIGHT="$FOOTPRINT_CACHE_STATE"
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
  (( elapsed < 2 )) || say "dispatch detail footprint_preflight candidates=$candidate_count secs=${elapsed}s cache=$FOOTPRINT_CACHE_PREFLIGHT"
  refill_cost_record preflight "$elapsed"
}
# #4488 第二轮（spec #4495 的类级解法）：预测足迹本身也看不准，共享测试文件和
# 运行时热点是和历史共同修改耦合的。派发检查前把窗口内与预测文件同提交
# 出现过的热点文件（每提交每文件计一次，先取共同修改 ≥2 次的前 12，再按配置门槛过滤）并进
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
# Hotspot expansion is off unless ZF_FOOTPRINT_HOTSPOT_MIN is a count: 74% of its holds had no
# real overlap. footprint_shadow_old_rule still logs every start the old two-co-change rule would
# have held. To revert, set ZF_FOOTPRINT_HOTSPOT_MIN=10 (the previous default); 1 retains the
# historical floor.
hotspot_minimum() {
  local min="${ZF_FOOTPRINT_HOTSPOT_MIN-off}"
  if [[ "$min" != off ]] && { [[ ! "$min" =~ ^[0-9]+$ ]] || [[ ! "$min" =~ [1-9] ]]; }; then
    say "footprint-hotspot-invalid-min value=$min default=off" >&2
    min=off
  fi
  # jq handles large numeric inputs without shell arithmetic overflow.
  printf '%s\n' "$min"
}
hotspot_expand() {
  local scope="$1" result
  result="$(hotspot_expand_batch "$(jq -cn --argjson scope "$scope" '[{id:"single",scope:$scope}]')")" || return 1
  scheduler_footprint_filter_main "$(jq -c '.[0].scope' <<<"$result")"
}
hotspot_expand_batch() { # Includes old-rule scope and counts for attribution without rereading history.
  local candidates="$1" log min
  log="$(hotspot_log)"
  min="$(hotspot_minimum)"
  jqf -Rsc --arg min "$min" --slurpfile candidates <(printf '%s' "$candidates") '
    def in_scope($scope; $path): any($scope[]; . as $s | . == $path or ($path | startswith($s + "/")));
    (split("\u0001") | map(split("\n") | map(select(length > 0)) | unique)) as $commits
    | [$candidates[0][] as $candidate
        | ($candidate.scope) as $scope
        | ([ $commits[] | select(length > 1 and length <= 40)
             | select(any(.[]; in_scope($scope; .)))
             | .[] | select(in_scope($scope; .) | not) ]
          | group_by(.) | map(select(length >= 2) | {f:.[0],n:length})
          | sort_by(-.n) | .[:12]) as $old
        | ($old | map(select($min != "off" and .n >= ($min | tonumber)))) as $added
        | {id:$candidate.id, scope:(($scope + ($added | map(.f))) | unique),
           old_scope:(($scope + ($old | map(.f))) | unique),
           counts:($old | map({key:.f,value:.n}) | from_entries)}]
  ' <<<"$log"
}
# shared-append 精确路径从足迹里剥离后再做互斥比较：两边只剩 shared-append 文件时不算冲突
# （不再串行 implement），文本冲突交给落地 rebase 处理，冲突率由 node_health 的
# ci.shared_append_rebase_conflict_pct 观测。目录保留，供无已知文件时保守匹配。
footprint_strip_shared_append() { # scope_json -> 去掉 shared-append 精确路径后的 scope
  local scope="$1"
  local shared="${SHARED_APPEND:-[]}"
  [[ "$shared" != '[]' ]] || { printf '%s\n' "$scope"; return; }
  jqf -c --slurpfile sa <(printf '%s' "$shared") 'map(select(test("(^|/)migrations/meta/_journal\\.json$") or (. as $x | any($sa[0][]; . == $x) | not)))' <<<"$scope"
}
footprint_match_detail() ( # candidate scope, original scope, owner scope, count map
  scheduler_scope_lib open-pr-collision || exit 2
  local candidate owner origin count original
  original="$(footprint_strip_shared_append "$2")"
  candidate="$(footprint_strip_shared_append "$1")"
  owner="$(footprint_strip_shared_append "$3")"
  if footprint_scopes_collide "$candidate" "$owner" "$original"; then
    candidate="$EXPECTED_SCOPE_COLLISION_CANDIDATE"
    origin=expansion
    if jq -e --arg p "$candidate" 'index($p) != null' <<<"$2" >/dev/null; then origin=original; fi
    if [[ "$origin" == original ]]; then count=not-applicable; else count="$(jq -r --arg p "$candidate" '.[$p] // 0' <<<"$4")"; fi
    printf 'candidate_path=%s owner_path=%s source=%s cochange_count=%s' "$candidate" "$EXPECTED_SCOPE_COLLISION_ACTIVE" "$origin" "$count"
  fi
)
footprint_shadow_old_rule() {
  local id="$1" active="$2" old current detail
  old="${TICK_OLD_SCOPE[$id]:-[]}"
  current="${TICK_CHECK_SCOPE[$id]:-[]}"
  [[ "$old" != "$current" ]] || return 0
  # One in-memory comparison, only for a candidate whose old scope was wider.
  detail="$(jq -r --arg id "$id" --argjson old "$old" \
    --argjson shared "${SHARED_APPEND:-[]}" --argjson counts "${TICK_HOTSPOT_COUNTS[$id]:-\{\}}" '
    first($old[] as $candidate | select(($shared | index($candidate)) == null)
      | .[] | select(.id != $id) | .id as $owner | .footprint[]? as $path
      | select(($shared | index($path)) == null)
      | select($candidate == $path or ($candidate | startswith($path + "/")) or ($path | startswith($candidate + "/")))
      | "owner=\($owner) candidate_path=\($candidate) owner_path=\($path) source=expansion cochange_count=\($counts[$candidate] // 0)") // empty
  ' <<<"$active")" || return 1
  [[ -z "$detail" ]] || say "footprint-shadow-old-rule-would-block unit=$id $detail"
}
footprint_wait_mark() { # unit owner unit_json：记等待方与起始时间，intake 不把它算作占用产能
  local detail candidate owner_path origin count original active owner_scope
  # A rescoped candidate is only compared here, and the merge after a start skips what did not change.
  TICK_FOOTPRINT_PREFLIGHT_CONFLICT["$1"]="$2"
  original="${TICK_FOOTPRINT_CACHE[$1]:-[]}"
  active="${TICK_ACTIVE_FOOTPRINTS:-[]}"
  owner_scope="$(jq -c --arg id "$2" '[.[] | select(.id == $id) | .footprint[]?]' <<<"$active")"
  detail="$(footprint_match_detail "$original" "$original" "$owner_scope" "${TICK_HOTSPOT_COUNTS[$1]:-\{\}}")"
  [[ -n "$detail" ]] || detail="$(footprint_match_detail "${TICK_CHECK_SCOPE[$1]:-$original}" "$original" "$owner_scope" "${TICK_HOTSPOT_COUNTS[$1]:-\{\}}")"
  say "footprint wait unit=$1 owner=$2 ${detail:-candidate_path=unknown owner_path=unknown source=unknown cochange_count=unknown}"
  TICK_FOOTPRINT_DEFERRED["$1"]="$2"
  TICK_FOOTPRINT_DEFER_DETAIL["$1"]="${detail:-source=unknown}"
  local marked_owner marked_since
  marked_owner="$(jqf -r '.footprint_wait_owner // empty' <<<"$3")"
  marked_since="$(jqf -r '.footprint_wait_since // empty' <<<"$3")"
  if [[ "$marked_owner" == "$2" && "$(ap_iso_epoch "$marked_since")" =~ ^[0-9]+$ ]]; then return 0; fi
  set_unit "$1" ".footprint_wait_owner=$(js "$2") | .footprint_wait_since=$(js "$STAMP")"
}
footprint_admit_unordered() { # unit-id unit-json: keep the predicted scope for write-start; log what the old gate would have held
  local id="$1" u="$2" scope owner="${TICK_FOOTPRINT_DEFERRED[$1]:-}"
  footprint_scope_for "$u" scope || return 1
  if [[ -n "${TICK_FOOTPRINT_CACHE[$id]+cached}" ]]; then
    [[ "${TICK_FOOTPRINT_CACHE[$id]}" == "$scope" ]] || set_unit "$id" ".footprint=$scope"
  else
    [[ "$(jqf -c '.footprint // []' <<<"$u")" == "$scope" ]] || set_unit "$id" ".footprint=$scope"
  fi
  TICK_FOOTPRINT_CACHE["$id"]="$scope"
  if [[ -n "$owner" ]] && footprint_wait_owner_active "$owner"; then
    say "footprint-shadow-old-rule-would-block unit=$id owner=$owner ${TICK_FOOTPRINT_DEFER_DETAIL[$id]:-source=unknown}"
  fi
  unset 'TICK_FOOTPRINT_DEFERRED[$id]' 'TICK_FOOTPRINT_DEFER_DETAIL[$id]'
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
  # Footprint orders candidates, it never refuses one (Cursor and MergeGym: a lock on predicted files costs more than the
  # conflicts it avoids). Only the dispatch walk's first pass asks for a verdict; every other caller, and the second pass, starts.
  [[ "${TICK_FOOTPRINT_DEFER:-false}" == true ]] || { footprint_admit_unordered "$id" "$u"; return; }
  # The preflight is one step of 25 to 153s with no check inside: begin it only with room left in the refill.
  [[ "$require_fresh" == true || "$TICK_FOOTPRINT_PREFLIGHT_STATUS" != not-started ]] || refill_room preflight || return 75
  if [[ "$require_fresh" != true ]] && footprint_preflight_snapshot; then
    conflict="${TICK_FOOTPRINT_PREFLIGHT_CONFLICT[$id]:-}"
    if [[ -n "$conflict" ]]; then
      footprint_wait_mark "$id" "$conflict" "$u"
      return 1
    fi
    if [[ -n "${TICK_FOOTPRINT_CACHE[$id]+cached}" ]]; then
      footprint_shadow_directory_rule "$id" "$TICK_ACTIVE_FOOTPRINTS"
      return 0
    fi
  fi
  footprint_scope_for "$u" scope || return 1
  if [[ -n "${TICK_FOOTPRINT_CACHE[$id]+cached}" ]]; then
    [[ "${TICK_FOOTPRINT_CACHE[$id]}" == "$scope" ]] || set_unit "$id" ".footprint=$scope"
  else
    [[ "$(jqf -c '.footprint // []' <<<"$u")" == "$scope" ]] || set_unit "$id" ".footprint=$scope"
  fi
  TICK_FOOTPRINT_CACHE["$id"]="$scope"
  if [[ "${TICK_CHECK_SCOPE_SOURCE[$id]:-}" == "$scope" ]]; then
    check_scope="${TICK_CHECK_SCOPE[$id]}"
  else
    # require_fresh asks for a verdict that cannot be older than this call: it recomputes the expansion and refreshes the cache entry.
    footprint_expand_rows "$(jq -cn --arg id "$id" --argjson scope "$scope" --arg head "$(footprint_unit_head "$u")" '[{id:$id,scope:$scope,head:$head}]')" "$require_fresh" || return 1
    check_scope="${TICK_CHECK_SCOPE[$id]}"
    TICK_CHECK_SCOPE_SOURCE["$id"]="$scope"
  fi
  if [[ "$TICK_ACTIVE_FOOTPRINTS_VALID" == true ]]; then
    active="$TICK_ACTIVE_FOOTPRINTS"
  else
    active="$(active_footprint_snapshot)" || return 1
    TICK_ACTIVE_FOOTPRINTS="$active"
    TICK_ACTIVE_FOOTPRINTS_VALID=true
    refreshed=true
  fi
  conflict="$(active_footprint_conflict "$check_scope" "$active" "$id" "$scope")" || return 1
  if [[ -n "$conflict" ]]; then
    footprint_wait_mark "$id" "$conflict" "$u"
    return 1
  fi
  if [[ "$require_fresh" != true ]]; then
    footprint_shadow_directory_rule "$id" "$active"
    return 0
  fi
  # A cached conflict can conservatively reject a candidate. A candidate that
  # appears clear must refresh every active worktree before it can be admitted.
  if [[ "$refreshed" != true ]]; then
    active="$(active_footprint_snapshot)" || return 1
    TICK_ACTIVE_FOOTPRINTS="$active"
    conflict="$(active_footprint_conflict "$check_scope" "$active" "$id" "$scope")" || return 1
    if [[ -n "$conflict" ]]; then
      footprint_wait_mark "$id" "$conflict" "$u"
      return 1
    fi
  fi
  footprint_shadow_directory_rule "$id" "$active"
  footprint_shadow_old_rule "$id" "$active"
}
footprint_room() { # unit type; report checks that materially delay dispatch
  local started=$SECONDS rc=0 elapsed room_start="${EPOCHREALTIME:-0}" room_end
  FOOTPRINT_CACHE_STATE=''
  # Repair reaches this twice (room_for, then the handler); the walk is sequential, so one unit is one candidate.
  if [[ -n "${TICK_FOOTPRINT_CAP:-}" && "${TICK_FOOTPRINT_DEFER:-false}" == true && "$1" != "$TICK_FOOTPRINT_CAP_LAST" ]]; then
    TICK_FOOTPRINT_CAP_LAST="$1"
    if (( ++TICK_FOOTPRINT_CAP_SEEN > TICK_FOOTPRINT_CAP )); then
      say "dispatch walk stopped at cap $TICK_FOOTPRINT_CAP footprint candidates: units from $1 wait for the next refill"
      dispatch_skip footprint-cap; TICK_FOOTPRINT_CAP_HIT=true
      return 1
    fi
  fi
  _footprint_room "$@" || rc=$?
  # No room left in the refill: the unit keeps waiting untouched, and the walk ends here.
  if (( rc == 75 )); then dispatch_skip refill-room; TICK_FOOTPRINT_CAP_HIT=true; rc=1
  # A wait with an owner is already counted by the footprint skip; any other refusal is an error path.
  elif (( rc != 0 )) && [[ -z "$(unit_field "$1" '.footprint_wait_owner // empty')" ]]; then dispatch_skip footprint-error; fi
  room_end="${EPOCHREALTIME:-0}"
  TICK_FOOTPRINT_ROOM_USEC=$((${TICK_FOOTPRINT_ROOM_USEC:-0} + 10#${room_end/./} - 10#${room_start/./}))
  TICK_FOOTPRINT_ROOM_CALLS=$((${TICK_FOOTPRINT_ROOM_CALLS:-0} + 1)); (( rc == 0 )) || TICK_FOOTPRINT_ROOM_WAITS=$((${TICK_FOOTPRINT_ROOM_WAITS:-0} + 1))
  # 放行后清掉等待记录；只在字段真有值时写 units.json
  if (( rc == 0 )) && [[ -n "$(jqf -r '.footprint_wait_owner // empty' <<<"${2:-null}")" ]]; then
    set_unit "$1" 'del(.footprint_wait_owner,.footprint_wait_since)'
  fi
  elapsed=$((SECONDS - started))
  (( elapsed >= 2 )) && say "dispatch detail footprint_check unit=$1 secs=${elapsed}s cache=${FOOTPRINT_CACHE_STATE:-$FOOTPRINT_CACHE_PREFLIGHT}"
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
  local extra; extra="$(dispatch_skip_summary)"
  printf 'free_slots=%s pending=%s skips=footprint:%s,handoff:%s,memory:%s%s\n' \
    "$free" "$pending" "$footprint" "$handoff" "$memory" "${extra:+,$extra}"
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
