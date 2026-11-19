# Footprint memo and cache helpers, sourced by footprint.sh. scheduler_footprint costs about 24 processes per row; these keep
# its per-pass result and the owner scopes it fills (inside dispatch_pending only, TICK_FOOTPRINT_MAIN set).
# scheduler_footprint is a pure function of the unit row, the issue state file and origin/main, and costs about 24 processes. One dispatch
# pass asked for it 3 to 4 times per candidate and once per live owner at every fresh snapshot. TICK_FOOTPRINT_MAIN (set by dispatch_pending;
# empty anywhere else, which bypasses the memo) keys the rows to the main they were filtered against.
declare -gA TICK_FOOTPRINT_SCOPE_MEMO=()
TICK_FOOTPRINT_MAIN=''
TICK_FOOTPRINT_HOT_CONFLICT_PATHS='[]'
TICK_FOOTPRINT_HOT_CONFLICT_PATHS_LOADED=false
footprint_hot_conflict_paths_load() {
  [[ "$TICK_FOOTPRINT_HOT_CONFLICT_PATHS_LOADED" == true ]] && return 0
  local archive_file now rc paths
  archive_file="$(mktemp)" || return 1
  if jqf_optional_file "${UNITS_ARCHIVE:-}" -c 'if type == "object" and (.units | type) == "array" then . else error("invalid archive") end' > "$archive_file"; then
    :
  else
    rc=$?
    rm -f -- "$archive_file"
    if (( rc == 64 )); then
      archive_file="$(mktemp)" || return 1
      printf '%s\n' '{"units":[]}' > "$archive_file" || { rm -f -- "$archive_file"; return 1; }
    else
      TICK_FOOTPRINT_HOT_CONFLICT_PATHS='[]'; TICK_FOOTPRINT_HOT_CONFLICT_PATHS_LOADED=true
      say "footprint hot-conflict paths unavailable rc=$rc paths=none"
      return 0
    fi
  fi
  now="$(date -u +%s)" || { rm -f -- "$archive_file"; return 1; }
  TICK_FOOTPRINT_HOT_CONFLICT_PATHS="$(jqf -c --argjson now "$now" --slurpfile live "$UNITS" --slurpfile archive "$archive_file" '
    (reduce (($archive[0].units // []) + ($live[0].units // []))[] as $unit ({}; .[$unit.id] = $unit) | [.[]]) as $units
    | [$units[] | (.history // [])[]? | select(.stage == "merge-conflict")
        | (try (.at | fromdateiso8601) catch null) as $at | select($at != null and $now - 86400 <= $at and $at <= $now)
        | (.conflict_files // "") as $files | select(($files | type) == "string")
        | select(($files | startswith("unavailable") or startswith("none ")) | not)
        | ($files | sub(" count=[0-9]+$"; "") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | unique[]) as $path
        | select($path != "") | $path]
    | group_by(.) | map(select(length >= 3) | .[0]) | sort' <<< '{}')" || {
      rc=$?; rm -f -- "$archive_file"
      TICK_FOOTPRINT_HOT_CONFLICT_PATHS='[]'; TICK_FOOTPRINT_HOT_CONFLICT_PATHS_LOADED=true
      say "footprint hot-conflict paths unavailable rc=$rc paths=none"
      return 0
    }
  rm -f -- "$archive_file"
  TICK_FOOTPRINT_HOT_CONFLICT_PATHS_LOADED=true
  paths="$(jqf -r 'if length == 0 then "none" else join(",") end' <<<"$TICK_FOOTPRINT_HOT_CONFLICT_PATHS")" || paths=unavailable
  say "footprint hot-conflict paths window=24h threshold=3 paths=$paths"
}
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
footprint_drop_check_scope_cache() {
  TICK_CHECK_SCOPE_SOURCE=()
  TICK_CHECK_SCOPE=()
  TICK_OLD_SCOPE=()
  TICK_HOTSPOT_COUNTS=()
}
footprint_active_rows() { # ledger rows that hold a live implement/repair worker, with the worker's workdir
  jqf -c --slurpfile w "$WORKERS" --argjson live "$FOOTPRINT_LIVE_WRITER_STAGES" '
    [.units[] | . as $u
      | select(.stage as $s | $live | index($s) != null)
      | select(any($w[0].workers[]; .unit==$u.id and .harvested!=true and .lease_expired!=true and (.type | IN("implement","repair"))))
      | . + {live_workdir: ([$w[0].workers[] | select(.unit==$u.id and .harvested!=true and .lease_expired!=true and (.type | IN("implement","repair"))) | .workdir] | first)}]' "$UNITS"
}
# Every snapshot is taken in $( ), where the memo cannot be filled: compute the owners' scopes here, in the caller's shell, first. A repeat
# snapshot of unchanged owners then finds them all in the memo.
footprint_prime_owner_scopes() {
  local other discard
  [[ -n "$TICK_FOOTPRINT_MAIN" ]] || return 0
  while IFS= read -r other; do
    footprint_scope_for "$other" discard || return 0
  done < <(footprint_active_rows | jqf -c '.[]')
}
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

footprint_filter_rows_main_fallback() { # preserve the old per-scope fallback if one batched Git read fails
  local rows="$1" records='' i scope old preserve has_old filtered filtered_old
  while IFS= read -r -d '' i && IFS= read -r -d '' scope && IFS= read -r -d '' old \
    && IFS= read -r -d '' preserve && IFS= read -r -d '' has_old; do
    filtered="$(scheduler_footprint_filter_main "$scope" "$preserve")" || return 1
    filtered_old='null'
    if [[ "$has_old" == true ]]; then
      filtered_old="$(scheduler_footprint_filter_main "$old" "$preserve")" || return 1
    fi
    records+="$i"$'\t'"$filtered"$'\t'"$has_old"$'\t'"$filtered_old"$'\n'
  done < <(jqf -j 'to_entries[] as $r | ($r.key|tostring),"\u0000",($r.value.scope|tojson),"\u0000",($r.value.old_scope|tojson),"\u0000",(($r.value.preserve // false)|tostring),"\u0000",(($r.value|has("old_scope"))|tostring),"\u0000"' <<<"$rows")
  jqf -Rn --slurpfile rows <(printf '%s' "$rows") '[inputs | split("\t") | select(length >= 4) as $p | ($p[0]|tonumber) as $i
    | $rows[0][$i] + {scope:($p[1]|fromjson)}
    | if $p[2] == "true" then . + {old_scope:($p[3]|fromjson)} else . end]' <<<"$records"
}

footprint_filter_rows_main() { # filter scope and optional old_scope for every row with one main-tree Git read
  local rows="$1" main_ref=refs/remotes/origin/main specs='' objects_output='' records='' i field path object kind row_index field_name
  local -a path_specs=() path_rows=() path_values=() objects=()
  specs="$main_ref^{tree}"$'\n'
  while IFS= read -r -d '' i && IFS= read -r -d '' field && IFS= read -r -d '' path; do
    path_specs+=("$main_ref:$path"); path_rows+=("$i"$'\t'"$field"$'\t'"$path"); path_values+=("$path")
  done < <(jqf -j 'to_entries[] as $r | ["scope","old_scope"][] as $field
    | ($r.value[$field] // null) as $scope
    | select(($r.value.preserve // false) != true and ($scope|type) == "array" and all($scope[]; type == "string"))
    | $scope[] as $path | ($r.key|tostring),"\u0000",$field,"\u0000",$path,"\u0000"' <<<"$rows")
  ((${#path_specs[@]})) || { printf '%s\n' "$rows"; return 0; }
  for path in "${path_specs[@]}"; do specs+="$path"$'\n'; done
  objects_output="$(printf '%s' "$specs" | git -C "$ROOT" cat-file --batch-check='%(objecttype)' 2>/dev/null)" \
    || { footprint_filter_rows_main_fallback "$rows"; return; }
  mapfile -t objects <<<"$objects_output"
  (( ${#objects[@]} == ${#path_specs[@]} + 1 )) \
    || { footprint_filter_rows_main_fallback "$rows"; return; }
  [[ -n "${objects[0]:-}" && "${objects[0]}" != *' missing' ]] || { printf '%s\n' "$rows"; return 0; }
  for ((i=0; i<${#path_specs[@]}; i++)); do
    object="${objects[$((i + 1))]:-}"
    if [[ -z "$object" ]]; then kind=empty
    elif [[ "$object" == *' missing' ]]; then kind=missing
    elif [[ -d "$ROOT/${path_values[$i]}" || "$object" == tree ]]; then kind=directory
    else kind=file
    fi
    row_index="${path_rows[$i]%%$'\t'*}"
    field_name="${path_rows[$i]#*$'\t'}"; field_name="${field_name%%$'\t'*}"
    records+="$row_index"$'\t'"$field_name"$'\t'"$kind"$'\t'"${path_values[$i]}"$'\n'
  done
  # Paths are grouped by (row, field) once: a scan of every path per row and field was quadratic (15 s at 800 rows).
  jqf -Rn --slurpfile rows <(printf '%s' "$rows") '[inputs | split("\t") | select(length >= 4) | {row:(.[0]|tonumber),field:.[1],kind:.[2],path:(.[3:]|join("\t"))}] as $paths
    | ($paths | group_by([.row,.field]) | map({key:"\(.[0].row)\u0001\(.[0].field)", value:.}) | from_entries) as $by
    | [$rows[0] | to_entries[] as $entry | $entry.value as $row
       | reduce ["scope","old_scope"][] as $field ($row;
           if (.preserve // false) == true or (.[$field]|type) != "array" or any(.[$field][]; type != "string") then .
           else (($by["\($entry.key)\u0001\($field)"] // []) as $found
             | if any($found[]; .kind == "empty") then .
               else .[$field] = ([$found[] | select(.kind != "missing") | .path] | unique) end)
           end)]' <<<"$records"
}

footprint_classify_scope_list() { # classify all candidate and original scopes with one main-tree Git read
  local scopes="$1" specs='' records='' index path object type
  local -a scope_indexes=() paths=() objects=()
  while IFS= read -r -d '' index && IFS= read -r -d '' path; do
    scope_indexes+=("$index"); paths+=("$path"); specs+="refs/remotes/origin/main:$path"$'\n'
  done < <(jqf -j 'to_entries[] as $scope | $scope.value[] as $path | ($scope.key|tostring),"\u0000",$path,"\u0000"' <<<"$scopes")
  ((${#paths[@]})) || { jqf -cn --slurpfile scopes <(printf '%s' "$scopes") '[range(0;($scopes[0]|length)) | []]'; return; }
  records="$(printf '%s' "$specs" | git -C "$ROOT" cat-file --batch-check='%(objecttype)' 2>/dev/null)" || records=''
  mapfile -t objects <<<"$records"
  records=''
  for ((index=0; index<${#paths[@]}; index++)); do
    type=file
    [[ -d "$ROOT/${paths[$index]}" || "${objects[$index]:-}" == tree ]] && type=directory
    records+="${scope_indexes[$index]}"$'\t'"$type"$'\t'"${paths[$index]}"$'\n'
  done
  jqf -Rn --slurpfile scopes <(printf '%s' "$scopes") '[inputs | split("\t") | select(length >= 3)
    | {scope:(.[0]|tonumber),type:.[1],path:(.[2:]|join("\t"))}] as $paths
    | [range(0;($scopes[0]|length)) as $scope
       | [$paths[] | select(.scope == $scope) | {path,type}]]' <<<"$records"
}

footprint_prepared_conflicts_batch() { # compare all candidates against prepared owners in one jq
  local active="$1" candidates="$2" rows='' scopes='' typed matches status id owner
  local -a batch_rows=()
  mapfile -t batch_rows < <(jqf -c -Rn \
    --argjson shared "${SHARED_APPEND:-[]}" --arg shared_raw "${SHARED_APPEND:-[]}" \
    --argjson hot "${TICK_FOOTPRINT_HOT_CONFLICT_PATHS:-[]}" '
      def strip($scope): if $shared_raw == "[]" then $scope else
        $scope | map(. as $path | select(test("(^|/)migrations/meta/_journal\\.json$")
          or (($shared | index($path)) == null) or (($hot | index($path)) != null))) end;
      ([inputs | split("\t") | select(length == 3) as $row
        | {id:$row[0],scope:strip($row[1]|fromjson),original:strip($row[2]|fromjson)}]) as $rows
      | [$rows[] | .scope,.original] as $scopes
      | $rows,$scopes' <<<"$candidates")
  rows="${batch_rows[0]:-}"; scopes="${batch_rows[1]:-}"
  [[ -n "$rows" && -n "$scopes" ]] || return 1
  ((${#FOOTPRINT_OWNER_IDS[@]})) || return 0
  typed="$(footprint_classify_scope_list "$scopes")" || return 1
  rows="$(jqf -cn --slurpfile rows <(printf '%s' "$rows") --slurpfile scopes <(printf '%s' "$typed") '
    [range(0;($rows[0]|length)) as $i
      | $rows[0][$i] + {scope_types:$scopes[0][2*$i],original_types:$scopes[0][2*$i+1]}]')" || return 1
  matches="$(jqf -nr --slurpfile rows <(printf '%s' "$rows") \
    --slurpfile owners <(printf '%s' "$FOOTPRINT_OWNERS_DOC") \
    --slurpfile active <(printf '%s' "$active") --argjson live "$FOOTPRINT_OWNER_LIVE_DOC" \
    --argjson hot "$TICK_FOOTPRINT_HOT_CONFLICT_PATHS" '
      def overlaps($a; $b): $a == $b or ($a | startswith($b + "/")) or ($b | startswith($a + "/"));
      def includes_hot($scope; $path): any($scope[]; . as $entry
        | $entry.path == $path or ($entry.type == "directory" and ($path | startswith($entry.path + "/"))));
      ($active[0] | map(.id | if type == "string" then . else tojson end)) as $ids
      | $rows[0][] as $candidate
      | (first(range($owners[0]|length) as $i | select($ids[$i] != $candidate.id)
          | $owners[0][$i] as $owner
          | if $owner == null then "F\($i)" else
              (any($candidate.original_types[]; .type == "file")) as $candidate_has_files
              | (any($owner[]; .type == "file")) as $owner_has_files
              | (any($candidate.scope_types[] as $a | $owner[] as $b
                    | select(overlaps($a.path; $b.path))
                    | select(($a.type == "file" and $b.type == "file") or ($candidate_has_files|not)
                      or ($owner_has_files|not) or ($a.path | test("(^|/)migrations/meta/_journal\\.json$"))
                      or ($b.path | test("(^|/)migrations/meta/_journal\\.json$"))); true)) as $collides
              | select($collides or ($live[$i] and any($hot[] as $path
                    | select((includes_hot($candidate.scope_types; $path) or includes_hot($candidate.original_types; $path))
                      and includes_hot($owner; $path)); true)))
              | "C\($i)"
            end) // "") as $hit
      | if $hit == "" then empty
        elif ($hit|startswith("F")) then "ERROR\t\($candidate.id)\t\($ids[($hit[1:]|tonumber)])"
        else "MATCH\t\($candidate.id)\t\($ids[($hit[1:]|tonumber)])" end')" || return 1
  while IFS=$'\t' read -r status id owner; do
    [[ -n "$status" ]] || continue
    if [[ "$status" == ERROR ]]; then
      say "footprint comparison failed candidate=$id owner=$owner step=classify rc=2"
      return 1
    fi
    printf '%s\t%s\n' "$id" "$owner"
  done <<<"$matches"
}

footprint_preflight_scope_rows() { # resolve direct ledger scopes in batches and memo the final scopes for unit checks
  local refill="$1" records='' rows filtered id unit head raw_scope preserve scope
  local -n rows_out="$2" heads_out="$3"
  rows_out=''; heads_out=(); TICK_FOOTPRINT_PREFLIGHT_IDS=()
  while IFS= read -r -d '' id && IFS= read -r -d '' unit && IFS= read -r -d '' head \
    && IFS= read -r -d '' raw_scope && IFS= read -r -d '' preserve; do
    if [[ "$raw_scope" == null ]]; then
      footprint_scope_for "$unit" scope || return 1
      preserve=true
    else
      scope="$raw_scope"
    fi
    records+="$id"$'\t'"$scope"$'\t'"$head"$'\t'"$preserve"$'\t'"$unit"$'\n'
  done < <(jqf -j --arg refill "$refill" '
    .units[] | select(.stage == "implement-pending" or ($refill != "true" and .stage == "repair-pending")) | . as $u
    | ([.history[]? | select(.stage == "write-end") | .result] | last // null) as $actual
    | (if ($u.footprint_source == "pr-diff" and ($u.footprint|type) == "array" and ($u.footprint|length) > 0)
        then $u.footprint
        elif (($actual|type) == "array" and ($actual|length) > 0) then $actual
        elif (($u.footprint // [])|length) > 0 then $u.footprint else null end) as $scope
    | (($u.footprint_source == "pr-diff" and ($u.footprint|type) == "array" and ($u.footprint|length) > 0)
        or (($actual|type) == "array" and ($actual|length) > 0)) as $preserve
    | ($u.id | if type == "string" then . else tojson end),"\u0000",($u|tojson),"\u0000",
      ($u.reviewed_pr_head // $u.reviewed_sha // $u.pr_head // $u.head_sha // ""),"\u0000",
      ($scope|tojson),"\u0000",($preserve|tostring),"\u0000"' "$UNITS")
  rows="$(jqf -Rn '[inputs | split("\t") | select(length == 5)
    | {id:.[0],scope:(.[1]|fromjson),head:.[2],preserve:(.[3] == "true"),unit:(.[4]|fromjson)}]' <<<"$records")" || return 1
  filtered="$(footprint_filter_rows_main "$rows")" || return 1
  while IFS= read -r -d '' id && IFS= read -r -d '' scope && IFS= read -r -d '' head && IFS= read -r -d '' unit; do
    rows_out+="$id"$'\t'"$scope"$'\n'; heads_out["$id"]="$head"
    TICK_FOOTPRINT_PREFLIGHT_IDS+=("$id"); TICK_FOOTPRINT_CACHE["$id"]="$scope"
    TICK_CHECK_SCOPE_SOURCE["$id"]="$scope"; TICK_CHECK_SCOPE["$id"]="$scope"
    TICK_OLD_SCOPE["$id"]="$scope"; TICK_HOTSPOT_COUNTS["$id"]='{}'
    [[ -z "$TICK_FOOTPRINT_MAIN" ]] || TICK_FOOTPRINT_SCOPE_MEMO["$TICK_FOOTPRINT_MAIN|$unit"]="$scope"
  done < <(jqf -j '.[] | .id,"\u0000",(.scope|tojson),"\u0000",(.head // ""),"\u0000",(.unit|tojson),"\u0000"' <<<"$filtered")
}

footprint_expand_rows() { # batch cache keys, reads and writes for rows [{id,scope,head}]
  local rows="$1" fresh="${2:-false}" dir="$A/footprint-cache" main='' rhead='' min day id head scope key file content cache_payload='' miss_ids='' miss_rows expanded filtered write_records='' tmp key_hash_output
  local total=0 hits=0 i; local -a ids=() heads=() scopes=() key_hashes=() miss=()
  local -A keys=() cache_by_key=() seen=() write_seen=()
  FOOTPRINT_CACHE_STATE=miss
  main="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)" || main=''
  rhead="$(git -C "$ROOT" rev-parse -q --verify HEAD 2>/dev/null)" || rhead=''
  min="$(hotspot_minimum)"; day="$(date -u +%F)"
  while IFS= read -r -d '' id && IFS= read -r -d '' head && IFS= read -r -d '' scope; do
    ids+=("$id"); heads+=("$head"); scopes+=("$scope"); total=$((total + 1))
  done < <(jqf -j '.[] | (.id | if type == "string" then . else tojson end),"\u0000",(.head // ""),"\u0000",(.scope|tojson),"\u0000"' <<<"$rows")
  if [[ -n "$main" && -n "$rhead" && "$total" -gt 0 ]]; then
    key_hash_output="$(jqf -j '.[] | (.head // ""),"\u0000",(.scope|tojson),"\u0000"' <<<"$rows" \
      | python3 -c 'import hashlib,sys
main,rhead,minimum,day=(x.encode() for x in sys.argv[1:])
parts=sys.stdin.buffer.read().split(b"\0")
if parts and parts[-1] == b"": parts.pop()
if len(parts) % 2: raise SystemExit(1)
for i in range(0,len(parts),2):
    data=b"\0".join((b"v1",main,rhead,parts[i],minimum,day,parts[i+1]))+b"\0"
    print(hashlib.sha256(data).hexdigest()[:40])' "$main" "$rhead" "$min" "$day")" || return 1
    mapfile -t key_hashes <<<"$key_hash_output"
  fi
  for ((i=0; i<total; i++)); do
    key=''
    if [[ -n "$main" && -n "$rhead" && -n "${key_hashes[$i]:-}" ]]; then key="$main-${key_hashes[$i]}.json"; fi
    keys["${ids[$i]}"]="$key"; file="$dir/$key"
    if [[ "$fresh" != true && -n "$key" && -s "$file" && -z "${seen[$key]:-}" ]]; then
      content=''; IFS= read -r -d '' content < "$file" || :; content="${content%$'\n'}"
      cache_payload+="$key"$'\t'"$content"$'\n'; seen["$key"]=1
    fi
  done
  if [[ -n "$cache_payload" ]]; then
    while IFS= read -r -d '' key && IFS= read -r -d '' scope && IFS= read -r -d '' head && IFS= read -r -d '' file; do
      cache_by_key["$key"]="$scope"$'\t'"$head"$'\t'"$file"
    done < <(jqf -j -Rn '
      inputs | split("\t") | select(length == 2) as $line
      | (try ($line[1] | fromjson) catch null) as $cache | select($cache != null)
      | $line[0],"\u0000",($cache.scope|tojson),"\u0000",($cache.old_scope|tojson),"\u0000",($cache.counts|tojson),"\u0000"' <<<"$cache_payload")
  fi
  for ((i=0; i<total; i++)); do
    id="${ids[$i]}"; key="${keys[$id]:-}"
    if [[ "$fresh" != true && -n "$key" && -n "${cache_by_key[$key]+cached}" ]]; then
      IFS=$'\t' read -r scope head file <<<"${cache_by_key[$key]}"
      TICK_CHECK_SCOPE["$id"]="$scope"; TICK_OLD_SCOPE["$id"]="$head"; TICK_HOTSPOT_COUNTS["$id"]="$file"
      hits=$((hits + 1))
    else
      miss+=("$id"); miss_ids+="$id"$'\n'
    fi
  done
  if ((${#miss[@]})); then
    hotspot_log >/dev/null
    miss_rows="$(jqf -cn --slurpfile rows <(printf '%s' "$rows") --rawfile ids <(printf '%s' "$miss_ids") '
      ($ids|split("\n")|map(select(length>0))) as $ids
      | [$rows[0][] | select((.id | if type == "string" then . else tojson end) as $id | $ids | index($id)) | {id,scope,head}]')" || return 1
    expanded="$(hotspot_expand_batch "$miss_rows")" || return 1
    [[ "${HOTSPOT_LOG_OK:-false}" == true ]] || HOTSPOT_LOG_LOADED=false
    filtered="$(footprint_filter_rows_main "$expanded")" || return 1
    while IFS= read -r -d '' id && IFS= read -r -d '' scope && IFS= read -r -d '' head && IFS= read -r -d '' file; do
      TICK_CHECK_SCOPE["$id"]="$scope"; TICK_OLD_SCOPE["$id"]="$head"; TICK_HOTSPOT_COUNTS["$id"]="$file"
      key="${keys[$id]:-}"
      if [[ "${HOTSPOT_LOG_OK:-false}" == true && -n "$key" && -z "${write_seen[$key]:-}" ]]; then
        write_records+="$key"$'\t'"$scope"$'\t'"$head"$'\t'"$file"$'\n'; write_seen["$key"]=1
      fi
    done < <(jqf -j '.[] | .id,"\u0000",(.scope|tojson),"\u0000",(.old_scope|tojson),"\u0000",(.counts|tojson),"\u0000"' <<<"$filtered")
    if [[ -n "$write_records" ]] && mkdir -p "$dir" 2>/dev/null; then
      printf '%s' "$write_records" | python3 -c 'import json,os,sys,tempfile
directory=sys.argv[1]
for line in sys.stdin:
    try:
        key,scope,old,counts=line.rstrip("\n").split("\t")
        value=json.dumps({"scope":json.loads(scope),"old_scope":json.loads(old),"counts":json.loads(counts)},separators=(",",":"))
        fd,tmp=tempfile.mkstemp(prefix="."+key+".",suffix=".tmp",dir=directory)
        try:
            with os.fdopen(fd,"w") as out: out.write(value+"\n")
            os.replace(tmp,os.path.join(directory,key))
        except Exception:
            try: os.unlink(tmp)
            except OSError: pass
    except Exception:
        pass' "$dir" 2>/dev/null || :
    fi
    [[ -z "$main" ]] || footprint_cache_prune "$main"
  fi
  (( total > 0 && hits == total )) && FOOTPRINT_CACHE_STATE=hit
  return 0
}
