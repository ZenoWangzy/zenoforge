explore_log() {
  local runtime_dir="${MAC_AUTOPILOT_RUNTIME_DIR:-${REPO_DIR:+$REPO_DIR/.scratch-supervisor/autopi}}"
  [[ -n "$runtime_dir" ]] || return 0
  mkdir -p -- "$runtime_dir" 2>/dev/null || return 0
  printf '[%s] issue-pipeline: %s\n' "$(date -u +%FT%TZ)" "$1" >> "$runtime_dir/scheduler.log" 2>/dev/null || true
}

explore_sha_valid() {
  [[ "$1" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]
}

explore_realpath() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

explore_run_dir() {
  printf '%s/state/explore/%s\n' "$AGENT_HOME" "$1"
}

explore_state_file() {
  printf '%s/state.json\n' "$(explore_run_dir "$1")"
}

explore_state_update() {
  local sha="$1" filter="$2" path tmp
  path="$(explore_state_file "$sha")"
  [[ -f "$path" ]] || return 1
  tmp="$(mktemp "$(dirname -- "$path")/.state.XXXXXX")" || return 1
  if jq "$filter" "$path" > "$tmp"; then
    mv -f -- "$tmp" "$path"
  else
    rm -f -- "$tmp"
    return 1
  fi
}

explore_state_create() {
  local sha="$1" state="$2" reason="$3" unit="$4" wall="$5" at="$6" path tmp reason_file status
  path="$(explore_state_file "$sha")"
  mkdir -p -- "$(dirname -- "$path")"
  tmp="$(mktemp "$(dirname -- "$path")/.state.XXXXXX")" || return 1
  reason_file="$(jq_arg_file "$reason")" || { rm -f -- "$tmp"; return 1; }
  if jq -cn --arg state "$state" --arg sha "$sha" --rawfile reason "$reason_file" --arg unit "$unit" \
    --arg at "$at" --argjson wall "$wall" \
    '{state:$state,release_sha:$sha,reason:(if $reason=="" then null else $reason end),unit:(if $unit=="" then null else $unit end),wall_seconds:$wall,started_at:$at,started_epoch:(now|floor)}' \
    > "$tmp"; then
    rm -f -- "$reason_file"
    mv -f -- "$tmp" "$path"
  else
    status=$?
    rm -f -- "$reason_file" "$tmp"
    return "$status"
  fi
}

explore_config_load() {
  local config map_rel map_file effects valid_ids
  EXPLORE_SKIP_REASON=
  EXPLORE_CONFIG_FILE="$(zf_config_file state/exploration.json 2>/dev/null || true)"
  if [[ -z "$EXPLORE_CONFIG_FILE" ]]; then EXPLORE_SKIP_REASON=no-config; return 1; fi
  if ! jq . "$EXPLORE_CONFIG_FILE" >/dev/null 2>&1; then EXPLORE_SKIP_REASON=invalid-config; return 1; fi
  config="$EXPLORE_CONFIG_FILE"
  if [[ "$(jq -r '.enabled // false' "$config")" != true ]]; then EXPLORE_SKIP_REASON=disabled; return 1; fi
  if ! jq -e '.driver.argv | type=="array" and length>0 and all(.[]; type=="string" and length>0 and (contains("\u0000")|not) and (contains("\n")|not))' "$config" >/dev/null 2>&1; then
    if ! jq -e '.driver | type=="object" and has("argv")' "$config" >/dev/null 2>&1; then EXPLORE_SKIP_REASON=no-driver; else EXPLORE_SKIP_REASON=invalid-config; fi
    return 1
  fi
  if ! jq -e '(.driver.timeout_s|type=="number" and .>0 and floor==.) and (.driver.evidence_dir|type=="string" and length>0 and (startswith("/")|not) and (split("/")|index("..")==null) and (contains("\u0000")|not)) and ((.budget.wall_seconds // 3600)|type=="number" and .>0 and .<=86400 and floor==.) and ((.budget.max_tokens // 1500000)|type=="number" and .>0 and floor==.) and ((.budget.max_features // 70)|type=="number" and .>0 and floor==.) and ((.max_filed_per_run // 3)|type=="number" and .>0 and floor==.)' "$config" >/dev/null 2>&1; then
    EXPLORE_SKIP_REASON=invalid-config
    return 1
  fi
  effects="$(jq -c '.allowed_effects // ["read"]' "$config")"
  if ! jq -e 'type=="array" and length>0 and all(.[]; .=="read")' <<< "$effects" >/dev/null 2>&1; then
    EXPLORE_SKIP_REASON=unsafe-effects
    return 1
  fi
  map_rel="$(jq -r '.feature_map // "state/feature-map.json"' "$config")"
  if [[ "$map_rel" == /* || "/$map_rel/" == *"/../"* ]]; then EXPLORE_SKIP_REASON=no-feature-map; return 1; fi
  map_file="$(zf_config_file "$map_rel" 2>/dev/null || true)"
  if [[ -z "$map_file" ]] || ! jq -e 'type=="object" and (.features|type=="array" and length>0) and all(.features[]; type=="object" and (.id|type=="string" and test("^[a-z0-9][a-z0-9-]{0,63}$")) and (.title|type=="string" and length>0 and (contains("\n")|not) and (contains("\t")|not))) and (([.features[].id]|unique|length)==(.features|length))' "$map_file" >/dev/null 2>&1; then
    EXPLORE_SKIP_REASON=no-feature-map
    return 1
  fi
  EXPLORE_FEATURES_JSON="$(jq -c '.features | map({id,title})' "$map_file")"
  EXPLORE_FEATURE_MAP_FILE="$map_file"
  EXPLORE_WALL_SECONDS="$(jq -r '.budget.wall_seconds // 3600' "$config")"
  EXPLORE_MAX_TOKENS="$(jq -r '.budget.max_tokens // 1500000' "$config")"
  EXPLORE_MAX_FEATURES="$(jq -r '.budget.max_features // 70' "$config")"
  EXPLORE_MAX_FILED="$(jq -r '.max_filed_per_run // 3' "$config")"
  EXPLORE_DRIVER_TIMEOUT="$(jq -r '.driver.timeout_s' "$config")"
  EXPLORE_EVIDENCE_REL="$(jq -r '.driver.evidence_dir' "$config")"
  mapfile -t EXPLORE_DRIVER_ARGV < <(jq -r '.driver.argv[]' "$config")
  EXPLORE_SELECTED_FEATURES="$(jq -c --argjson max "$EXPLORE_MAX_FEATURES" '.[:$max]' <<< "$EXPLORE_FEATURES_JSON")"
  EXPLORE_SELECTED_COUNT="$(jq 'length' <<< "$EXPLORE_SELECTED_FEATURES")"
  valid_ids="$(jq '[.[]|.id]|unique|length' <<< "$EXPLORE_SELECTED_FEATURES")"
  [[ "$valid_ids" == "$EXPLORE_SELECTED_COUNT" ]]
}

explore_reclaim_old_runs() {
  local root="$AGENT_HOME/state/explore" retention_days="${ZF_EXPLORE_RETAIN_DAYS:-14}" retention_seconds now run_dir sha state_file state age_seconds lock_file
  local repo_real evidence_root evidence_real evidence_run reclaimed=0 removed_run status=0
  [[ "$retention_days" =~ ^[0-9]{1,5}$ ]] || return 64
  retention_days=$((10#$retention_days))
  retention_seconds=$((retention_days * 86400))
  [[ -d "$root" ]] || return 0
  now="$(date +%s)" || return 1
  evidence_root=
  if explore_config_load; then
    repo_real="$(explore_realpath "$ZF_REPO_DIR" 2>/dev/null || true)"
    evidence_root="$ZF_REPO_DIR/$EXPLORE_EVIDENCE_REL"
    evidence_real="$(explore_realpath "$evidence_root" 2>/dev/null || true)"
    if [[ -z "$repo_real" || -z "$evidence_real" || ( "$evidence_real" != "$repo_real" && "$evidence_real" != "$repo_real/"* ) ]]; then
      evidence_root=
      status=1
    else
      evidence_root="$evidence_real"
    fi
  fi
  for run_dir in "$root"/*; do
    [[ -d "$run_dir" && ! -L "$run_dir" ]] || continue
    sha="${run_dir##*/}"
    explore_sha_valid "$sha" || continue
    state_file="$run_dir/state.json"
    [[ -f "$state_file" && ! -L "$state_file" ]] || continue
    state="$(jq -r '.state // empty' "$state_file" 2>/dev/null || true)"
    case "$state" in
      done|skipped|killed) ;;
      *) continue ;;
    esac
    age_seconds="$(python3 -c 'import os,sys; print(max(0,int(float(sys.argv[1])-os.stat(sys.argv[2]).st_mtime)))' "$now" "$state_file" 2>/dev/null || true)"
    [[ "$age_seconds" =~ ^[0-9]+$ ]] || { status=1; continue; }
    (( age_seconds >= retention_seconds )) || continue
    removed_run=0
    if rm -rf -- "$run_dir"; then removed_run=1; else status=1; fi
    lock_file="$root/$sha.lock"
    if [[ -e "$lock_file" || -L "$lock_file" ]]; then
      if rm -f -- "$lock_file"; then removed_run=1; else status=1; fi
    fi
    if [[ -n "$evidence_root" ]]; then
      evidence_run="$evidence_root/explore-$sha"
      if [[ -e "$evidence_run" || -L "$evidence_run" ]]; then
        if rm -rf -- "$evidence_run"; then removed_run=1; else status=1; fi
      fi
    fi
    if (( removed_run == 1 )); then reclaimed=$((reclaimed + 1)); fi
  done
  if (( reclaimed > 0 )); then explore_log "explore: reclaimed runs=$reclaimed"; fi
  return "$status"
}

explore_age_seconds() {
  python3 - "$1" <<'PY'
from datetime import datetime, timezone
import sys

value = sys.argv[1].replace("Z", "+00:00")
at = datetime.fromisoformat(value)
if at.tzinfo is None:
    raise SystemExit(1)
print(max(0, int((datetime.now(timezone.utc) - at.astimezone(timezone.utc)).total_seconds())))
PY
}

explore_summary_from_progress() {
  local sha="$1" stop="$2" path="$(explore_run_dir "$1")/progress.jsonl" stats started now wall
  stats='{"features":0,"findings":0,"filed":0,"tokens":0}'
  if [[ -s "$path" ]]; then
    stats="$(jq -sc '{features:length,findings:(map(.findings // 0)|add // 0),filed:(map(.filed // 0)|add // 0),tokens:(map(.tokens // 0)|add // 0)}' "$path" 2>/dev/null || printf '%s' "$stats")"
  fi
  started="$(jq -r '.started_epoch // now|floor' "$(explore_state_file "$sha")" 2>/dev/null || date +%s)"
  now="$(date +%s)"
  wall=$((now - started))
  explore_log "explore: summary release=${sha:0:12} features=$(jq -r .features <<< "$stats")/$(jq -r '.selected_features // 0' "$(explore_state_file "$sha")" 2>/dev/null || echo 0) findings=$(jq -r .findings <<< "$stats") filed=$(jq -r .filed <<< "$stats") tokens=$(jq -r .tokens <<< "$stats") wall=$wall stop=$stop"
}

explore_state_started_at_epoch() {
  jq -r '.started_epoch // 0' "$(explore_state_file "$1")" 2>/dev/null || echo 0
}

explore_pending_count() {
  local dir="$(explore_run_dir "$1")/pending" count=0 metadata
  [[ -d "$dir" ]] || { echo 0; return; }
  while IFS= read -r metadata; do
    [[ "$(jq -r '.state // empty' "$metadata" 2>/dev/null || true)" == pending ]] && count=$((count + 1))
  done < <(find "$dir" -maxdepth 1 -type f -name '*.json' -print)
  echo "$count"
}

explore_start_unit() {
  local sha="$1" mode="$2" wall="$3" unit="${UNIT_PREFIX_TRANSIENT:-zf}-explore-$1" status
  export http_proxy="${http_proxy:-${HTTP_PROXY:-}}" https_proxy="${https_proxy:-${HTTPS_PROXY:-}}" no_proxy="${no_proxy:-${NO_PROXY:-}}"
  local -a runtime_env=(-E PATH -E HOME -E http_proxy -E https_proxy -E HTTP_PROXY -E HTTPS_PROXY -E no_proxy -E NO_PROXY \
    -E ALL_PROXY -E NODE_USE_ENV_PROXY -E AGENT_HOME="$AGENT_HOME" -E ZF_ENGINE_DIR="$ZF_ENGINE_DIR" \
    -E ZF_REPO_DIR="$ZF_REPO_DIR" -E ZF_CONFIG_ROOT="$ZF_CONFIG_ROOT" -E MAC_AUTOPILOT_RUNTIME_DIR="${MAC_AUTOPILOT_RUNTIME_DIR:-}")
  [[ -z "${ZF_CDP_BROWSER_LEASE_SCRIPT:-}" ]] || runtime_env+=(-E ZF_CDP_BROWSER_LEASE_SCRIPT="$ZF_CDP_BROWSER_LEASE_SCRIPT")
  [[ -z "${ZF_REPO:-}" ]] || runtime_env+=(-E ZF_REPO="$ZF_REPO")
  [[ -z "${ZF_PACK_DIR:-}" ]] || runtime_env+=(-E ZF_PACK_DIR="$ZF_PACK_DIR")
  [[ -z "${ZF_UNIT_PREFIX:-}" ]] || runtime_env+=(-E ZF_UNIT_PREFIX="$ZF_UNIT_PREFIX")
  [[ -z "${CODEX_HOME:-}" ]] || runtime_env+=(-E CODEX_HOME="$CODEX_HOME")
  if guarded_write systemd-run --user --collect --unit "$unit" --slice="${ZF_BATCH_SLICE:-zf-batch.slice}" \
    -p "RuntimeMaxSec=$wall" -p TimeoutStopSec=15 -p SuccessExitStatus=75 "${runtime_env[@]}" \
    /bin/bash "$ZF_ENGINE_DIR/run-explore.sh" "$mode" "$sha"; then
    explore_log "explore: started release=${sha:0:12} unit=$unit mode=$mode"
    return 0
  else
    status=$?
  fi
  if [[ "$status" == 75 ]]; then
    explore_log "explore: dispatch deferred release=${sha:0:12} reason=admission"
  else
    explore_log "explore: dispatch failed release=${sha:0:12} status=$status"
  fi
  return "$status"
}

explore_dispatch_live_release() (
  local live_file="$AGENT_HOME/state/live-sha.json" sha at age run_dir state unit now started_epoch started_age lockfd status reason mode wall
  [[ -r "$live_file" ]] || return 0
  sha="$(jq -r '.sha // empty' "$live_file" 2>/dev/null || true)"
  at="$(jq -r '.at // empty' "$live_file" 2>/dev/null || true)"
  explore_sha_valid "$sha" || { explore_log 'explore: skipped release=unknown reason=invalid-live-sha'; return 0; }
  age="$(explore_age_seconds "$at" 2>/dev/null || true)"
  [[ "$age" =~ ^[0-9]+$ ]] || { explore_log "explore: skipped release=${sha:0:12} reason=invalid-live-sha"; return 0; }
  run_dir="$(explore_run_dir "$sha")"
  mkdir -p -- "$(dirname -- "$run_dir")"
  exec {lockfd}>"$(dirname -- "$run_dir")/$sha.lock"
  flock -n "$lockfd" || return 0
  if [[ -f "$run_dir/state.json" ]]; then
    state="$(jq -r '.state // empty' "$run_dir/state.json" 2>/dev/null || true)"
    case "$state" in
      done|skipped|killed) return 0 ;;
      needs-filing)
        unit="${UNIT_PREFIX_TRANSIENT:-zf}-explore-$sha"
        systemctl --user is-active --quiet "$unit" 2>/dev/null && return 0
        explore_start_unit "$sha" file 120
        return $? ;;
      started)
        unit="$(jq -r '.unit // empty' "$run_dir/state.json")"
        [[ -n "$unit" ]] && systemctl --user is-active --quiet "$unit" 2>/dev/null && return 0
        now="$(date +%s)"
        started_epoch="$(explore_state_started_at_epoch "$sha")"
        started_age=$((now - started_epoch))
        if (( started_age < 60 )); then return 0; fi
        if (( $(explore_pending_count "$sha") > 0 )); then
          explore_state_update "$sha" '.state="needs-filing" | .reason="worker-ended-with-pending-findings"'
          explore_start_unit "$sha" file 120
          return $?
        fi
        explore_summary_from_progress "$sha" killed
        explore_state_update "$sha" '.state="killed" | .stop="killed" | .finished_at=(now|todate)'
        return 0 ;;
      *) rm -rf -- "$run_dir" ;;
    esac
  elif [[ -e "$run_dir" ]]; then
    rm -rf -- "$run_dir"
  fi
  if (( age > 86400 )); then
    mkdir -p -- "$run_dir"
    explore_state_create "$sha" skipped expired "" 0 "$at"
    explore_log "explore: skipped release=${sha:0:12} reason=expired"
    return 0
  fi
  if ! explore_config_load; then
    reason="$EXPLORE_SKIP_REASON"
    mkdir -p -- "$run_dir"
    explore_state_create "$sha" skipped "$reason" "" 0 "$at"
    explore_log "explore: skipped release=${sha:0:12} reason=$reason"
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    explore_log "explore: dry-run release=${sha:0:12} features=$EXPLORE_SELECTED_COUNT"
    return 0
  fi
  unit="${UNIT_PREFIX_TRANSIENT:-zf}-explore-$sha"
  wall="$EXPLORE_WALL_SECONDS"
  mkdir -p -- "$run_dir"
  explore_state_create "$sha" started "" "$unit" "$wall" "$(date -u +%FT%TZ)"
  explore_state_update "$sha" ".selected_features=$EXPLORE_SELECTED_COUNT | .max_tokens=$EXPLORE_MAX_TOKENS | .max_filed=$EXPLORE_MAX_FILED"
  mkdir -p -- "$run_dir/results" "$run_dir/pending" "$run_dir/evidence"
  if explore_start_unit "$sha" run "$wall"; then return 0; else status=$?; fi
  if [[ "$status" == 75 ]] || ! systemctl --user is-active --quiet "$unit" 2>/dev/null; then
    rm -rf -- "$run_dir"
    return "$status"
  fi
  return "$status"
)

explore_result_valid() {
  local result="$1" feature_id="$2"
  jq -e --arg id "$feature_id" '
    type=="object" and .feature_id==$id and (.status=="pass" or .status=="fail" or .status=="skip")
    and (.steps|type=="array" and length<=100 and all(.[];type=="string" and length<=2000))
    and ((.evidence // [])|type=="array" and length<=25 and ([.[]]|unique|length)==length and all(.[];type=="string" and length>0 and (contains("#")|not) and (contains("\n")|not) and (startswith("/")|not) and (split("/")|index(".." )==null) and test("\\.(png|gif|jpe?g|svg|mp4|mov|webm)$";"i")))
    and (if .status=="fail" then (.failing_step_id|type=="string" and test("^[a-z0-9][a-z0-9-]{0,63}$")) and (.error_class|type=="string" and test("^[A-Za-z][A-Za-z0-9_.-]{0,63}$")) and ((.evidence // [])|length>0) else true end)
    and (.session_id==null or (.session_id|type=="string" and test("^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")))
  ' "$result" >/dev/null 2>&1
}

explore_session_tokens() {
  local session_id="$1" usage
  [[ -n "$session_id" ]] || { echo 0; return 0; }
  usage="$(python3 "$ZF_ENGINE_DIR/mac-autopilot/usage_reader.py" codex-session-usage \
    "${CODEX_HOME:-$HOME/.codex}/sessions" "$session_id" 2>/dev/null || true)"
  [[ -n "$usage" && "$usage" != null ]] || return 1
  jq -er '.raw|select(type=="number" and .>=0 and floor==.)' <<< "$usage"
}

explore_evidence_copy() {
  local sha="$1" feature_id="$2" attempt="$3" evidence_dir="$4" result="$5" relative source destination resolved_root resolved_file hash size
  local -a files=()
  while IFS= read -r relative; do files+=("$relative"); done < <(jq -r '.evidence[]?' "$result")
  (( ${#files[@]} > 0 )) || return 1
  for relative in "${files[@]}"; do
    case "/$relative/" in */../*) return 1 ;; esac
    source="$evidence_dir/$relative"
    [[ -f "$source" && ! -L "$source" ]] || return 1
    resolved_root="$(explore_realpath "$evidence_dir")" || return 1
    resolved_file="$(explore_realpath "$source")" || return 1
    [[ "$resolved_file" == "$resolved_root/"* ]] || return 1
    size="$(wc -c < "$resolved_file" | tr -d ' ')" || return 1
    [[ "$size" =~ ^[0-9]+$ ]] && (( size > 0 && size <= 10485760 )) || return 1
    destination="$(explore_run_dir "$sha")/evidence/$feature_id/attempt-$attempt/$relative"
    mkdir -p -- "$(dirname -- "$destination")"
    cp -- "$source" "$destination" || return 1
    hash="$(shasum -a 256 "$destination" | awk '{print $1}')" || return 1
    printf 'evidence/%s/attempt-%s/%s sha256:%s\n' "$feature_id" "$attempt" "$relative" "$hash"
  done
}

explore_evidence_attachment_paths() {
  local sha="$1" feature_id="$2" attempt="$3" result="$4" relative destination
  while IFS= read -r -d '' relative; do
    destination="$(explore_run_dir "$sha")/evidence/$feature_id/attempt-$attempt/$relative"
    [[ -f "$destination" && ! -L "$destination" && -r "$destination" ]] || return 1
    printf '%s\0' "$destination"
  done < <(jq -j '.evidence[]? | ., "\u0000"' "$result")
}

explore_remove_attempt_evidence() {
  local path repo_real
  repo_real="$(explore_realpath "$ZF_REPO_DIR" 2>/dev/null || true)"
  for path in "${EXPLORE_FIRST_EVIDENCE_DIR:-}" "${EXPLORE_ATTEMPT_EVIDENCE_DIR:-}"; do
    [[ -n "$path" && -n "$repo_real" && "$path" == "$repo_real/"* ]] || continue
    rm -rf -- "$path"
  done
  EXPLORE_FIRST_EVIDENCE_DIR=
  EXPLORE_ATTEMPT_EVIDENCE_DIR=
}

explore_issue_body() {
  local sha="$1" feature_id="$2" title="$3" signature="$4" first="$5" second="$6" first_evidence="$7" second_evidence="$8" destination="$9"
  {
    printf 'A live release reproduced this defect twice through the configured product driver.\n\n'
    printf 'Release: `%s`\nFeature: `%s` — %s\nSignature: `%s`\n' "$sha" "$feature_id" "$title" "$signature"
    printf '\n### Reproduction run 1\n'
    jq -r '.steps[] | "- " + .' "$first"
    printf '\nEvidence:\n%s\n' "$first_evidence"
    printf '\n### Reproduction run 2\n'
    jq -r '.steps[] | "- " + .' "$second"
    printf '\nEvidence:\n%s\n' "$second_evidence"
    printf '\n### Driver results\n```json\n'
    jq -c '{feature_id,status,failing_step_id,error_class,steps,evidence}' "$first"
    jq -c '{feature_id,status,failing_step_id,error_class,steps,evidence}' "$second"
    printf '```\n'
  } > "$destination"
}

explore_upsert_finding() {
  local sha="$1" feature_id="$2" title="$3" signature="$4" body_path="$5" class="$6" run_dir metadata pending_dir upsert attachment_json attachment
  shift 6
  local -a attachments=("$@") upsert_args=()
  run_dir="$(explore_run_dir "$sha")"
  pending_dir="$run_dir/pending"
  mkdir -p -- "$pending_dir"
  metadata="$pending_dir/$class.json"
  attachment_json="$(jq -cn --args '$ARGS.positional' -- "${attachments[@]}")"
  jq -cn --arg class "$class" --arg title "$title" --arg body_file "$body_path" --arg feature "$feature_id" --argjson attachments "$attachment_json" \
    '{class:$class,title:$title,body_file:$body_file,feature_id:$feature,attachments:$attachments,state:"pending"}' > "$metadata"
  upsert="${ZF_EXPLORE_ISSUE_UPSERT:-$ZF_ENGINE_DIR/pipeline-issue-upsert.sh}"
  upsert_args=(--lane product --class "$class" --label explore-found --title "$title" --body-file "$body_path")
  for attachment in "${attachments[@]}"; do upsert_args+=(--attach "$attachment"); done
  if bash "$upsert" "${upsert_args[@]}"; then
    jq '.state="filed"' "$metadata" > "$metadata.tmp" && mv -f -- "$metadata.tmp" "$metadata"
    return 0
  fi
  explore_state_update "$sha" '.state="needs-filing" | .reason="issue-upsert-failed"'
  explore_log "explore: finding pending release=${sha:0:12} feature=$feature_id class=$class"
  return 1
}

explore_file_pending() {
  local sha="$1" pending_dir="$(explore_run_dir "$1")/pending" metadata class title body feature_id upsert filed=0 attachment
  local -a attachments=() upsert_args=()
  [[ -d "$pending_dir" ]] || {
    explore_state_update "$sha" '.state="done" | .reason=null | .finished_at=(now|todate)'
    return 0
  }
  upsert="${ZF_EXPLORE_ISSUE_UPSERT:-$ZF_ENGINE_DIR/pipeline-issue-upsert.sh}"
  while IFS= read -r metadata; do
    [[ "$(jq -r '.state' "$metadata" 2>/dev/null || true)" == pending ]] || continue
    class="$(jq -r '.class' "$metadata")"
    title="$(jq -r '.title' "$metadata")"
    body="$(jq -r '.body_file' "$metadata")"
    feature_id="$(jq -r '.feature_id' "$metadata")"
    attachments=()
    while IFS= read -r -d '' attachment; do attachments+=("$attachment"); done < <(jq -j '.attachments[]? | ., "\u0000"' "$metadata")
    upsert_args=(--lane product --class "$class" --label explore-found --title "$title" --body-file "$body")
    for attachment in "${attachments[@]}"; do upsert_args+=(--attach "$attachment"); done
    if ! bash "$upsert" "${upsert_args[@]}"; then
      explore_log "explore: finding pending release=${sha:0:12} feature=$feature_id class=$class"
      return 1
    fi
    jq '.state="filed"' "$metadata" > "$metadata.tmp" && mv -f -- "$metadata.tmp" "$metadata"
    filed=$((filed + 1))
  done < <(find "$pending_dir" -maxdepth 1 -type f -name '*.json' -print | sort)
  if (( $(explore_pending_count "$sha") == 0 )); then
    explore_state_update "$sha" '.state="done" | .reason=null | .finished_at=(now|todate)'
    explore_log "explore: pending findings filed release=${sha:0:12} filed=$filed"
  fi
}

explore_driver_attempt() {
  local sha="$1" feature_id="$2" title="$3" attempt="$4" max_tokens="$5" remaining="$6" result evidence_dir log_file status timeout_seconds wall_limited=0 repo_real evidence_base_real
  EXPLORE_ATTEMPT_EVIDENCE_DIR=
  result="$(explore_run_dir "$sha")/results/$feature_id-attempt-$attempt.json"
  log_file="$(explore_run_dir "$sha")/results/$feature_id-attempt-$attempt.log"
  mkdir -p -- "$ZF_REPO_DIR/$EXPLORE_EVIDENCE_REL" || { EXPLORE_ATTEMPT_STATUS=error; return 0; }
  repo_real="$(explore_realpath "$ZF_REPO_DIR")" || { EXPLORE_ATTEMPT_STATUS=error; return 0; }
  evidence_base_real="$(explore_realpath "$ZF_REPO_DIR/$EXPLORE_EVIDENCE_REL")" || { EXPLORE_ATTEMPT_STATUS=error; return 0; }
  if [[ "$evidence_base_real" != "$repo_real" && "$evidence_base_real" != "$repo_real/"* ]]; then EXPLORE_ATTEMPT_STATUS=error; return 0; fi
  evidence_dir="$evidence_base_real/explore-$sha/$feature_id/attempt-$attempt"
  EXPLORE_ATTEMPT_EVIDENCE_DIR="$evidence_dir"
  mkdir -p -- "$(dirname -- "$result")" "$evidence_dir"
  rm -f -- "$result"
  timeout_seconds="$EXPLORE_DRIVER_TIMEOUT"
  if (( remaining <= timeout_seconds )); then timeout_seconds="$remaining"; wall_limited=1; fi
  if (( timeout_seconds <= 0 )); then EXPLORE_ATTEMPT_STATUS=budget-time; return 0; fi
  local -a command=("${EXPLORE_DRIVER_ARGV[@]}")
  if [[ -n "${ZF_CDP_BROWSER_LEASE_SCRIPT:-}" && -x "$ZF_CDP_BROWSER_LEASE_SCRIPT" ]]; then
    command=("$ZF_CDP_BROWSER_LEASE_SCRIPT" -- "${EXPLORE_DRIVER_ARGV[@]}")
  fi
  if (cd -- "$ZF_REPO_DIR" && \
      ZF_EXPLORATION_RELEASE_SHA="$sha" ZF_EXPLORATION_FEATURE_ID="$feature_id" \
      ZF_EXPLORATION_FEATURE_TITLE="$title" ZF_EXPLORATION_ATTEMPT="$attempt" \
      ZF_EXPLORATION_RUN_ID="$sha-$feature_id-$attempt" ZF_EXPLORATION_FRESH_SESSION=1 \
      ZF_EXPLORATION_EVIDENCE_DIR="$evidence_dir" ZF_EXPLORATION_RESULT_FILE="$result" \
      ZF_EXPLORATION_MAX_TOKENS="$max_tokens" ZF_EXPLORATION_ALLOWED_EFFECTS=read \
      timeout --kill-after=1s "${timeout_seconds}s" "${command[@]}" > "$log_file" 2>&1); then
    EXPLORE_ATTEMPT_STATUS=ok
  else
    status=$?
    if [[ "$status" == 124 && "$wall_limited" == 1 ]]; then
      EXPLORE_ATTEMPT_STATUS=budget-time
    elif [[ -s "$result" ]]; then
      EXPLORE_ATTEMPT_STATUS=ok
    else
      EXPLORE_ATTEMPT_STATUS=error
    fi
  fi
  EXPLORE_ATTEMPT_RESULT="$result"
  EXPLORE_ATTEMPT_EVIDENCE_DIR="$evidence_dir"
}

explore_run_release() {
  local mode="$1" sha="$2" state run_dir start_epoch now elapsed remaining total id title first second first_status second_status
  local first_session second_session first_tokens second_tokens feature_tokens signature error_class step_id hash class issue_title
  local first_evidence second_evidence body pending_count confirmed max_filed stop=done result_status feature_finding feature_filed class_feature attachment
  local -a attachments=()
  local -A used_sessions=()
  local features_done=0 findings=0 filed=0 tokens=0
  explore_sha_valid "$sha" || return 64
  run_dir="$(explore_run_dir "$sha")"
  [[ -r "$(explore_state_file "$sha")" ]] || return 0
  state="$(jq -r '.state // empty' "$(explore_state_file "$sha")")"
  if [[ "$mode" == file || "$state" == needs-filing ]]; then explore_file_pending "$sha"; return $?; fi
  [[ "$mode" == run && "$state" == started ]] || return 0
  if ! explore_config_load; then
    explore_state_update "$sha" '.state="skipped" | .reason="config-changed" | .finished_at=(now|todate)'
    explore_log "explore: skipped release=${sha:0:12} reason=config-changed"
    return 0
  fi
  total="$EXPLORE_SELECTED_COUNT"
  max_filed="$EXPLORE_MAX_FILED"
  start_epoch="$(explore_state_started_at_epoch "$sha")"
  [[ "$start_epoch" =~ ^[0-9]+$ ]] || start_epoch="$(date +%s)"
  EXPLORE_RUN_SHA="$sha"
  EXPLORE_RUN_FEATURES_DONE=0
  EXPLORE_RUN_FINDINGS=0
  EXPLORE_RUN_FILED=0
  EXPLORE_RUN_TOKENS=0
  EXPLORE_RUN_TOTAL="$total"
  EXPLORE_RUN_START="$start_epoch"
  trap 'explore_run_signal' TERM INT
  while IFS=$'\t' read -r id title; do
    now="$(date +%s)"
    elapsed=$((now - start_epoch))
    remaining=$((EXPLORE_WALL_SECONDS - elapsed))
    if (( remaining <= 0 )); then stop=budget-time; break; fi
    if (( tokens >= EXPLORE_MAX_TOKENS )); then stop=budget-tokens; break; fi
    feature_tokens=0
    feature_finding=0
    feature_filed=0
    first="$(explore_run_dir "$sha")/results/$id-attempt-1.json"
    explore_driver_attempt "$sha" "$id" "$title" 1 "$((EXPLORE_MAX_TOKENS - tokens))" "$remaining"
    first_status="$EXPLORE_ATTEMPT_STATUS"
    if [[ "$first_status" == budget-time ]]; then explore_remove_attempt_evidence; stop=budget-time; break; fi
    if [[ "$first_status" != ok ]] || ! explore_result_valid "$EXPLORE_ATTEMPT_RESULT" "$id"; then
      explore_log "explore: driver error release=${sha:0:12} feature=$id attempt=1"
      explore_remove_attempt_evidence
      features_done=$((features_done + 1))
      jq -cn --arg id "$id" '{feature:$id,findings:0,filed:0,tokens:0,outcome:"driver-error"}' >> "$run_dir/progress.jsonl"
      continue
    fi
    EXPLORE_FIRST_EVIDENCE_DIR="$EXPLORE_ATTEMPT_EVIDENCE_DIR"
    first_session="$(jq -r '.session_id // empty' "$first")"
    first_tokens=0
    if [[ -n "$first_session" ]]; then
      if [[ -n "${used_sessions[$first_session]:-}" ]] || ! first_tokens="$(explore_session_tokens "$first_session")"; then
        explore_log "explore: token usage unavailable release=${sha:0:12} feature=$id attempt=1"
        explore_remove_attempt_evidence
        tokens="$EXPLORE_MAX_TOKENS"
        stop=budget-tokens
        break
      fi
      used_sessions[$first_session]=1
    fi
    feature_tokens=$((feature_tokens + first_tokens))
    tokens=$((tokens + first_tokens))
    result_status="$(jq -r '.status' "$first")"
    if [[ "$result_status" != fail ]]; then
      features_done=$((features_done + 1))
      jq -cn --arg id "$id" --arg outcome "$result_status" --argjson tokens "$feature_tokens" \
        '{feature:$id,findings:0,filed:0,tokens:$tokens,outcome:$outcome}' >> "$run_dir/progress.jsonl"
      explore_remove_attempt_evidence
      if (( tokens >= EXPLORE_MAX_TOKENS )); then stop=budget-tokens; break; fi
      continue
    fi
    now="$(date +%s)"
    elapsed=$((now - start_epoch))
    remaining=$((EXPLORE_WALL_SECONDS - elapsed))
    if (( remaining <= 0 )); then
      features_done=$((features_done + 1))
      jq -cn --arg id "$id" --argjson tokens "$feature_tokens" '{feature:$id,findings:0,filed:0,tokens:$tokens,outcome:"unconfirmed-budget-time"}' >> "$run_dir/progress.jsonl"
      explore_remove_attempt_evidence
      stop=budget-time
      break
    fi
    if (( tokens >= EXPLORE_MAX_TOKENS )); then
      features_done=$((features_done + 1))
      jq -cn --arg id "$id" --argjson tokens "$feature_tokens" '{feature:$id,findings:0,filed:0,tokens:$tokens,outcome:"unconfirmed-budget-tokens"}' >> "$run_dir/progress.jsonl"
      explore_remove_attempt_evidence
      stop=budget-tokens
      break
    fi
    second="$(explore_run_dir "$sha")/results/$id-attempt-2.json"
    explore_driver_attempt "$sha" "$id" "$title" 2 "$((EXPLORE_MAX_TOKENS - tokens))" "$remaining"
    second_status="$EXPLORE_ATTEMPT_STATUS"
    if [[ "$second_status" == budget-time ]]; then
      features_done=$((features_done + 1))
      jq -cn --arg id "$id" --argjson tokens "$feature_tokens" '{feature:$id,findings:0,filed:0,tokens:$tokens,outcome:"unconfirmed-budget-time"}' >> "$run_dir/progress.jsonl"
      explore_remove_attempt_evidence
      stop=budget-time
      break
    fi
    second_session=
    second_tokens=0
    if [[ "$second_status" == ok ]] && explore_result_valid "$EXPLORE_ATTEMPT_RESULT" "$id"; then
      second_session="$(jq -r '.session_id // empty' "$second")"
      if [[ -n "$second_session" ]]; then
        if [[ -n "${used_sessions[$second_session]:-}" ]] || ! second_tokens="$(explore_session_tokens "$second_session")"; then
          explore_log "explore: token usage unavailable release=${sha:0:12} feature=$id attempt=2"
          explore_remove_attempt_evidence
          tokens="$EXPLORE_MAX_TOKENS"
          stop=budget-tokens
          break
        fi
        used_sessions[$second_session]=1
      fi
    fi
    feature_tokens=$((feature_tokens + second_tokens))
    tokens=$((tokens + second_tokens))
    if [[ "$second_status" == ok ]] && explore_result_valid "$second" "$id" \
      && [[ -z "$first_session" || -z "$second_session" || "$first_session" != "$second_session" ]]; then
      signature="$id|$(jq -r '.failing_step_id' "$first")|$(jq -r '.error_class' "$first")"
      if [[ "$(jq -r '.status' "$second")" == fail ]] \
        && [[ "$signature" == "$id|$(jq -r '.failing_step_id' "$second")|$(jq -r '.error_class' "$second")" ]]; then
        findings=$((findings + 1))
        hash="$(printf '%s' "$signature" | shasum -a 256 | awk '{print substr($1,1,8)}')"
        class_feature="${id:0:47}"
        class="explore-$class_feature-$hash"
        issue_title="Release exploration: $title"
        issue_title="${issue_title:0:180}"
        first_evidence="$(explore_evidence_copy "$sha" "$id" 1 "$EXPLORE_FIRST_EVIDENCE_DIR" "$first")" || first_evidence=
        second_evidence="$(explore_evidence_copy "$sha" "$id" 2 "$EXPLORE_ATTEMPT_EVIDENCE_DIR" "$second")" || second_evidence=
        if [[ -z "$first_evidence" || -z "$second_evidence" ]]; then
          explore_log "explore: invalid evidence release=${sha:0:12} feature=$id"
        elif (( filed < max_filed )); then
          attachments=()
          while IFS= read -r -d '' attachment; do attachments+=("$attachment"); done < <(explore_evidence_attachment_paths "$sha" "$id" 1 "$first")
          while IFS= read -r -d '' attachment; do attachments+=("$attachment"); done < <(explore_evidence_attachment_paths "$sha" "$id" 2 "$second")
          if (( ${#attachments[@]} == 0 )); then
            explore_log "explore: invalid evidence release=${sha:0:12} feature=$id reason=attachment-missing"
            explore_remove_attempt_evidence
            features_done=$((features_done + 1))
            jq -cn --arg id "$id" --argjson tokens "$feature_tokens" '{feature:$id,findings:1,filed:0,tokens:$tokens,outcome:"invalid-evidence"}' >> "$run_dir/progress.jsonl"
            EXPLORE_RUN_FEATURES_DONE="$features_done" EXPLORE_RUN_FINDINGS="$findings" EXPLORE_RUN_FILED="$filed" EXPLORE_RUN_TOKENS="$tokens"
            stop=invalid-evidence
            explore_finish "$sha" "$stop" "$features_done" "$total" "$findings" "$filed" "$tokens" "$start_epoch"
            trap - TERM INT
            return 1
          fi
          body="$run_dir/findings/$class.md"
          mkdir -p -- "$(dirname -- "$body")"
          explore_issue_body "$sha" "$id" "$title" "$signature" "$first" "$second" "$first_evidence" "$second_evidence" "$body"
          if explore_upsert_finding "$sha" "$id" "$issue_title" "$signature" "$body" "$class" "${attachments[@]}"; then
            filed=$((filed + 1))
            feature_filed=1
          else
            features_done=$((features_done + 1))
            jq -cn --arg id "$id" --argjson tokens "$feature_tokens" '{feature:$id,findings:1,filed:0,tokens:$tokens,outcome:"pending-filing"}' >> "$run_dir/progress.jsonl"
            EXPLORE_RUN_FEATURES_DONE="$features_done" EXPLORE_RUN_FINDINGS="$findings" EXPLORE_RUN_FILED="$filed" EXPLORE_RUN_TOKENS="$tokens"
            stop=filing-error
            explore_finish "$sha" "$stop" "$features_done" "$total" "$findings" "$filed" "$tokens" "$start_epoch"
            trap - TERM INT
            return 1
          fi
        else
          explore_log "explore: finding release=${sha:0:12} feature=$id class=$class filed=0 reason=max-filed-per-run"
        fi
        feature_finding=1
        explore_log "explore: reproduced release=${sha:0:12} feature=$id class=$class filed=$feature_filed"
      else
        explore_log "explore: unconfirmed release=${sha:0:12} feature=$id"
      fi
    else
      explore_log "explore: unconfirmed release=${sha:0:12} feature=$id"
    fi
    features_done=$((features_done + 1))
    jq -cn --arg id "$id" --argjson findings "$feature_finding" --argjson filed "$feature_filed" \
      --argjson tokens "$feature_tokens" '{feature:$id,findings:$findings,filed:$filed,tokens:$tokens,outcome:"checked"}' >> "$run_dir/progress.jsonl"
    explore_remove_attempt_evidence
    if (( tokens >= EXPLORE_MAX_TOKENS )); then stop=budget-tokens; break; fi
  done < <(jq -r '.[] | [.id,.title] | @tsv' <<< "$EXPLORE_SELECTED_FEATURES")
  if [[ "$stop" == done ]] && (( features_done < total )); then stop=budget-time; fi
  EXPLORE_RUN_FEATURES_DONE="$features_done" EXPLORE_RUN_FINDINGS="$findings" EXPLORE_RUN_FILED="$filed" EXPLORE_RUN_TOKENS="$tokens"
  explore_finish "$sha" "$stop" "$features_done" "$total" "$findings" "$filed" "$tokens" "$start_epoch"
  trap - TERM INT
}

explore_finish() {
  local sha="$1" stop="$2" features="$3" total="$4" findings="$5" filed="$6" tokens="$7" start="$8" now wall state
  now="$(date +%s)"
  wall=$((now - start))
  state=done
  if [[ "$stop" == killed ]]; then
    if (( $(explore_pending_count "$sha") > 0 )); then state=needs-filing; else state=killed; fi
  elif [[ "$stop" == filing-error ]]; then state=needs-filing
  fi
  explore_state_update "$sha" ".state=\"$state\" | .stop=\"$stop\" | .finished_at=(now|todate) | .features_done=$features | .findings=$findings | .filed=$filed | .tokens=$tokens | .wall_seconds_elapsed=$wall" || true
  explore_log "explore: summary release=${sha:0:12} features=$features/$total findings=$findings filed=$filed tokens=$tokens wall=$wall stop=$stop"
}

explore_run_signal() {
  trap - TERM INT
  explore_remove_attempt_evidence
  explore_finish "$EXPLORE_RUN_SHA" killed "${EXPLORE_RUN_FEATURES_DONE:-0}" "${EXPLORE_RUN_TOTAL:-0}" \
    "${EXPLORE_RUN_FINDINGS:-0}" "${EXPLORE_RUN_FILED:-0}" "${EXPLORE_RUN_TOKENS:-0}" "${EXPLORE_RUN_START:-$(date +%s)}"
  exit 143
}
