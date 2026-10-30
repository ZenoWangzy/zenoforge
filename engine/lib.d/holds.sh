_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

hold_stage_label_is_valid() {
  [ "$1" != on-hold ] && [ "$1" != concluded ] && ticket_stage_is_label "$1"
}


hold_stage_before() {
  local state_json="$1" issue_json="${2:-}" state_stage state_from existing_stage candidate label
  state_stage="$(jq -r '.state // empty' <<< "$state_json" 2>/dev/null)"
  state_from="$(jq -r '.state_changed_from // empty' <<< "$state_json" 2>/dev/null)"
  existing_stage="$(jq -r '.hold.stage_before // empty' <<< "$state_json" 2>/dev/null)"
  if [ "$state_stage" = on-hold ]; then
    for candidate in "$existing_stage" "$state_from"; do
      if hold_stage_label_is_valid "$candidate"; then echo "$candidate"; return 0; fi
    done
  else
    for candidate in "$state_stage" "$state_from" "$existing_stage"; do
      if hold_stage_label_is_valid "$candidate"; then echo "$candidate"; return 0; fi
    done
  fi
  if [ -n "$issue_json" ]; then
    while IFS= read -r label; do
      if hold_stage_label_is_valid "$label"; then echo "$label"; return 0; fi
    done < <(jq -r '.labels[]?.name // empty' <<< "$issue_json" 2>/dev/null)
  fi
  echo needs-triage
}


hold_expiry_resolve() {
  local spec="$1" now_epoch expiry_epoch
  now_epoch="$(date -u +%s)" || return 1
  if [[ "$spec" =~ ^([1-9][0-9]*)h$ ]]; then
    expiry_epoch=$((now_epoch + BASH_REMATCH[1] * 3600))
  else
    expiry_epoch="$(agent_epoch -u "$spec" 2>/dev/null)" || return 1
  fi
  (( expiry_epoch > now_epoch )) || return 1
  date -u -d "@$expiry_epoch" +%Y-%m-%dT%H:%M:%SZ
}


# hold_issue <issue> --holder X --release TEXT --expires 24h [--kind NAME] [--stage-before LABEL]
# Shared write path for pipeline and operator holds. hold.sh exposes the same
# contract as a command for holds created outside this checkout.
hold_issue() {
  local n="${1:-}" holder="" release_condition="" expires_spec="" kind=manual stage_before_override=""
  local expiry_at state_json issue_json stage_before record_json hold_label=on-hold
  shift || true
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "hold_issue: valid issue number required" >&2; return 64; }
  while (($#)); do
    case "$1" in
      --holder|--release|--expires|--kind|--stage-before)
        (($# >= 2)) || { echo "hold_issue: value required for $1" >&2; return 64; }
        case "$1" in
          --holder) holder="$2" ;;
          --release) release_condition="$2" ;;
          --expires) expires_spec="$2" ;;
          --kind) kind="$2" ;;
          --stage-before) stage_before_override="$2" ;;
        esac
        shift 2
        ;;
      --remove-label)
        (($# >= 2)) || { echo "hold_issue: label required after --remove-label" >&2; return 64; }
        ticket_stage_is_label "$2" && [ "$2" != on-hold ] || {
          echo "hold_issue: invalid stage label '$2'" >&2
          return 64
        }
        shift 2
        ;;
      *) echo "hold_issue: unexpected argument '$1'" >&2; return 64 ;;
    esac
  done
  [ -n "$holder" ] && [ -n "$release_condition" ] && [ -n "$expires_spec" ] || {
    echo "hold_issue: --holder, --release, and --expires are required" >&2
    return 64
  }
  [[ "${holder,,}" != unknown ]] || { echo "hold_issue: unknown holder is not valid hold metadata" >&2; return 64; }
  [[ "$kind" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]] || { echo "hold_issue: invalid kind '$kind'" >&2; return 64; }
  if [ -n "$stage_before_override" ] && ! hold_stage_label_is_valid "$stage_before_override"; then
    echo "hold_issue: invalid --stage-before '$stage_before_override'" >&2
    return 64
  fi
  expiry_at="$(hold_expiry_resolve "$expires_spec")" || {
    echo "hold_issue: --expires must be a future duration in hours or timestamp" >&2
    return 64
  }
  state_json="$(state_read "$n")" || return 1
  if ! jq -e 'type == "object"' <<< "$state_json" >/dev/null 2>&1; then
    echo "hold_issue: invalid state for #$n" >&2
    return 1
  fi
  issue_json="$(gh issue view "$n" --repo "$REPO" --json state,labels 2>/dev/null)" || {
    echo "hold_issue: could not inspect #$n before applying hold" >&2
    return 1
  }
  if ! jq -e '(.state // "" | ascii_downcase) == "open" and (.labels | type == "array")' \
      <<< "$issue_json" >/dev/null 2>&1; then
    echo "hold_issue: #$n is not an open issue or labels could not be read" >&2
    return 1
  fi
  stage_before="${stage_before_override:-$(hold_stage_before "$state_json" "$issue_json")}" || return 1
  record_json="$(jq -cn --arg holder "$holder" --arg release "$release_condition" \
    --arg expires "$expiry_at" --arg stage "$stage_before" --arg kind "$kind" \
    '{holder:$holder,release_condition:$release,expires_at:$expires,stage_before:$stage,kind:$kind,created_at:(now|todate),durable_record:false}')" || return 1
  issue_transition "$n" "$hold_label" hold-applied ".hold = $record_json" || return 1
  return 0
}


# One issue-json predicate keeps label and title marks consistent at intake and hold expiry.
is_hotfix_lane_issue() {
  jq -e '
    any(.labels[]?; (.name // "" | ascii_downcase) == "hotfix")
    or ((.title // "") | test("(?i)(\\[\\s*hotfix\\s*\\]|\\[\\s*hot-fix\\s*\\]|\\[\\s*热修\\s*\\]|【\\s*热修\\s*】|（[^）]*热修）)"))
  ' <<< "$1" >/dev/null 2>&1
}


hold_comment_has_marker() {
  jq -e --arg marker "$2" 'any(.comments[]?; (.body // "") | contains($marker))' \
    <<< "$1" >/dev/null 2>&1
}


hold_durable_record_payload() {
  jq -ce '{holder,release_condition,expires_at,stage_before,kind} + (if has("created_at") then {created_at} else {} end) + (if has("hand_owner") then {hand_owner} else {} end)' <<< "$1"
}


hold_durable_record_valid() {
  local record="$1" stage
  jq -e '
    type == "object"
    and (.holder | type == "string" and length > 0 and ascii_downcase != "unknown")
    and (.release_condition | type == "string" and length > 0)
    and (.expires_at | type == "string" and (try fromdateiso8601 catch null) != null)
    and (.stage_before | type == "string" and length > 0)
    and (.kind | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and . != "backfill")
    and (if has("hand_owner") then (.hand_owner | type == "string" and test("^hand-[1-9][0-9]*$")) else true end)
    and (if has("created_at") then (.created_at | type == "string" and (try fromdateiso8601 catch null) != null) else true end)
  ' <<< "$record" >/dev/null 2>&1 || return 1
  stage="$(jq -r '.stage_before' <<< "$record")" || return 1
  hold_stage_label_is_valid "$stage"
}


hold_assign_hand_owner() {
  local n="$1" owner="$2" state hold owner_json record_json
  [[ "$n" =~ ^[1-9][0-9]*$ && "$owner" == "hand-$n" ]] || return 64
  state="$(state_read "$n")" || return 1
  jq -e '.state == "on-hold" and (.hold | type) == "object" and .hold.kind != ""' <<< "$state" >/dev/null 2>&1 || return 1
  owner_json="$(jq -cn --arg owner "$owner" '$owner')" || return 1
  state_merge "$n" ".hold.holder = \"supervisor\" | .hold.hand_owner = $owner_json | .hold.durable_record = false" || return 1
  record_json="$(state_read "$n" | jq -c '.hold')" || return 1
  hold_durable_record_publish "$n" "$record_json" || return 1
  state_merge "$n" '.hold.durable_record = true'
}


hold_clear_hand_owner() {
  local n="$1" state record_json
  state="$(state_read "$n")" || return 1
  jq -e '.state == "on-hold" and (.hold.hand_owner // "") != ""' <<< "$state" >/dev/null 2>&1 || return 0
  state_merge "$n" '.hold = (.hold | del(.hand_owner) | .durable_record = false)' || return 1
  record_json="$(state_read "$n" | jq -c '.hold')" || return 1
  hold_durable_record_publish "$n" "$record_json" || return 1
  state_merge "$n" '.hold.durable_record = true'
}


hold_durable_record_publish() {
  local n="$1" hold_json="$2" payload encoded marker issue_json="${3:-}" body
  payload="$(hold_durable_record_payload "$hold_json")" || return 2
  hold_durable_record_valid "$payload" || return 2
  encoded="$(jq -rn --argjson record "$payload" '$record | @base64')" || return 1
  marker="<!-- vecta-hold-record-v1 issue=$n record=$encoded -->"
  [ -n "$issue_json" ] || issue_json="$(gh issue view "$n" --repo "$REPO" --json comments 2>/dev/null)" || return 1
  jq -e 'type == "object" and (.comments | type == "array")' <<< "$issue_json" >/dev/null 2>&1 || return 1
  hold_comment_has_marker "$issue_json" "$marker" && return 0
  body="$BOT_DISCLAIMER
Durable hold record: holder=$(jq -r '.holder' <<< "$payload"); kind=$(jq -r '.kind' <<< "$payload"); expiry=$(jq -r '.expires_at' <<< "$payload"); stage=$(jq -r '.stage_before' <<< "$payload"); release=$(jq -r '.release_condition' <<< "$payload")
$marker"
  guarded_issue_comment "$n" "$body"
}


hold_durable_record_from_issue() {
  local n="$1" issue_json="$2" prefix encoded decoded payload
  prefix="<!-- vecta-hold-record-v1 issue=$n record="
  encoded="$(jq -r --arg prefix "$prefix" '
    [.comments[]? | (.body // "") | select(contains($prefix))
      | split($prefix)[1] | split(" -->")[0]] | last // empty
  ' <<< "$issue_json")" || return 2
  [ -n "$encoded" ] || return 1
  decoded="$(jq -Rr '@base64d' <<< "$encoded")" || return 2
  payload="$(hold_durable_record_payload "$decoded")" || return 2
  hold_durable_record_valid "$payload" || return 2
  printf '%s\n' "$payload"
}


hold_restore() {
  local n="$1" issue_json="${2:-}" state_json hold_json durable_record record_json status=0 stages stage_labels stage_before local_record_valid=0
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "hold_restore: valid issue number required" >&2; return 64; }
  [ -n "$issue_json" ] || issue_json="$(gh issue view "$n" --repo "$REPO" --json state,labels,comments 2>/dev/null)" || {
      echo "hold_restore: could not inspect #$n" >&2
      return 1
    }
  stages="$(printf '%s\n' "${ALL_STATE_LABELS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
  if ! jq -e --argjson stages "$stages" '
      (.state // "" | ascii_downcase) == "open"
      and (.labels | type == "array") and (.comments | type == "array")
      and any(.labels[]?; .name == "on-hold")
    ' <<< "$issue_json" >/dev/null 2>&1; then
    echo "hold_restore: #$n must be open and on-hold" >&2
    return 1
  fi
  state_json="$(state_read "$n")" || return 1
  hold_json="$(jq -c '.hold // {}' <<< "$state_json")" || return 1
  if hold_durable_record_valid "$hold_json"; then
    local_record_valid=1
    durable_record="$hold_json"
  else
    durable_record="$(hold_durable_record_from_issue "$n" "$issue_json")" || status=$?
    if [ "$status" -ne 0 ]; then
      echo "hold_restore: #$n has no exact durable hold record; issue left unchanged" >&2
      return 3
    fi
    hold_json="$durable_record"
  fi

  stage_before="$(jq -r '.stage_before' <<< "$durable_record")" || return 1
  stage_labels="$(jq -c --argjson stages "$stages" \
    '[.labels[]?.name | select(. as $label | ($stages | index($label)) != null)] | unique' \
    <<< "$issue_json")" || return 1
  if ! jq -e --arg stage "$stage_before" 'length == 0 or . == [$stage]' <<< "$stage_labels" >/dev/null 2>&1; then
    echo "hold_restore: #$n has stage labels that conflict with exact durable stage $stage_before; issue left unchanged" >&2
    return 1
  fi

  if (( local_record_valid )); then
    if jq -e '.durable_record == true' <<< "$hold_json" >/dev/null 2>&1; then
      echo "hold_restore: #$n already has complete durable hold metadata" >&2
      return 0
    fi
    if ! hold_durable_record_publish "$n" "$hold_json" "$issue_json" \
      || ! state_merge "$n" '.hold.durable_record = true'; then
      echo "hold_restore: could not persist complete local hold metadata for #$n" >&2
      return 1
    fi
    echo "hold_restore: #$n archived its complete local hold metadata" >&2
    return 0
  fi

  record_json="$(jq -c '. + {durable_record:true}' <<< "$durable_record")" || return 1
  if ! issue_transition "$n" on-hold hold-restore ".hold = $record_json"; then
    echo "hold_restore: could not restore durable hold metadata for #$n" >&2
    return 1
  fi
  echo "hold_restore: restored exact GitHub hold metadata for #$n" >&2
}


hold_hand_owner_name() {
  local holder="$1"
  if [[ "$holder" =~ (^|[^[:alnum:]_.-])(hand-[1-9][0-9]*)([^[:alnum:]_.-]|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}


hold_hand_owner_from_record() {
  local record="$1" owner holder
  owner="$(jq -r '.hand_owner // empty' <<< "$record" 2>/dev/null || true)"
  [[ "$owner" =~ ^hand-[1-9][0-9]*$ ]] && { printf '%s\n' "$owner"; return 0; }
  holder="$(jq -r '.holder // empty' <<< "$record" 2>/dev/null || true)"
  hold_hand_owner_name "$holder"
}


hold_hand_owner_report_is_recent() {
  local owner="$1" now_epoch="$2" cutoff report row pid name model effort worktree brief log attempt started_at role start_ticks issues nodes report_epoch
  cutoff=$((now_epoch - 10800))
  if [ -r "$NIGHT/agents.txt" ]; then
    while IFS= read -r row || [ -n "$row" ]; do
      [[ "$row" == *$'\t'* ]] || continue
      IFS=$'\x1f' read -r pid name model effort worktree brief report log attempt started_at role start_ticks issues nodes \
        <<< "${row//$'\t'/$'\x1f'}"
      [[ "$name" == "$owner" || "$name" == "$owner-"* ]] || continue
      case "$report" in "$NIGHT"/*) ;; *) continue ;; esac
      report_epoch="$(stat -c %Y -- "$report" 2>/dev/null || true)"
      [[ "$report_epoch" =~ ^[0-9]+$ ]] && [ "$report_epoch" -ge "$cutoff" ] && return 0
    done < "$NIGHT/agents.txt"
  fi
  for report in "$NIGHT/$owner-report"* "$NIGHT/$owner.report"* "$NIGHT/$owner-"*report*; do
    [ -f "$report" ] || continue
    report_epoch="$(stat -c %Y -- "$report" 2>/dev/null || true)"
    [[ "$report_epoch" =~ ^[0-9]+$ ]] && [ "$report_epoch" -ge "$cutoff" ] && return 0
  done
  return 1
}


hand_agent_role_is_supported() {
  local identity
  identity="$(model_policy identity "$1" 2>/dev/null)" || return 1
  case "$identity" in codex:*|zcode:*) return 0 ;; esac
  return 1
}


blocked_hand_agent_upsert() {
  local pid="$1" name="$2" role="$3" worktree="$4" brief_path="$5" report="$6" log="$7" attempt="$8" dependency="$9" start_ticks="${10}" owned_issues="${11}" owned_nodes="${12}"
  local dependency_override="${13:-}" item tmp dependency_satisfied=false
  local night_dir="${ZF_NIGHT_DIR:-$AGENT_HOME/night}" blocked_file="${BLOCKED_HAND_AGENTS:-${ZF_NIGHT_DIR:-$AGENT_HOME/night}/blocked-hand-agents.json}"
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$attempt" =~ ^[0-9]+$ && "$name" =~ ^[[:alnum:]_.-]+$ ]] || return 1
  hand_agent_role_is_supported "$role" || return 1
  case "$dependency" in *$'\t'*|*$'\n'*) return 1 ;; esac
  if [[ "$dependency_override" == true || "$dependency_override" == false ]]; then
    dependency_satisfied="$dependency_override"
  elif declare -F blocked_hand_agent_dependency_landed >/dev/null && blocked_hand_agent_dependency_landed "$dependency"; then
    dependency_satisfied=true
  fi
  mkdir -p -- "$(dirname -- "$blocked_file")" || return 1
  [ -f "$blocked_file" ] || printf '[]\n' > "$blocked_file"
  jq -e 'type=="array"' "$blocked_file" >/dev/null 2>&1 || return 1
  item="$(jq -cn --argjson pid "$pid" --arg name "$name" --arg role "$role" \
    --arg worktree "$worktree" --arg brief "$brief_path" --arg report "$report" --arg log "$log" \
    --argjson attempt "$attempt" --arg dependency "$dependency" --arg start_ticks "$start_ticks" \
    --arg owned_issues "$owned_issues" --arg owned_nodes "$owned_nodes" --argjson dependency_satisfied "$dependency_satisfied" \
    --argjson blocked_at "$(date +%s)" \
    '{pid:$pid,name:$name,role:$role,worktree:$worktree,brief:$brief,report:$report,log:$log,attempt:$attempt,dependency:$dependency,dependency_satisfied:$dependency_satisfied,start_ticks:$start_ticks,owned_issues:$owned_issues,owned_nodes:$owned_nodes,blocked_at:$blocked_at}')" || return 1
  tmp="$(mktemp "${night_dir}/.blocked-hand-agents.XXXXXX")" || return 1
  jq --argjson item "$item" 'map(select(.name != $item.name)) + [$item]' "$blocked_file" > "$tmp" \
    && mv -- "$tmp" "$blocked_file" || { rm -f -- "$tmp"; return 1; }
  if declare -F say >/dev/null; then
    say "HAND-AGENT-BLOCKED-RECORDED $name dependency=$dependency"
  else
    printf '%s HAND-AGENT-BLOCKED-RECORDED %s dependency=%s\n' "$(date -u +%FT%TZ)" "$name" "$dependency" >> "$night_dir/night.log"
  fi
}


hold_hand_owner_is_live() {
  local owner="$1" now_epoch="$2" units unit_status=0 lib_dir row pid name model effort worktree brief report log attempt started_at role start_ticks issues nodes
  if ! declare -F hand_agent_pid_live >/dev/null; then
    lib_dir="$(cd -- "$(dirname -- "$_AGENT_LIB_DIR/lib.sh")" && pwd -P)" || return 2
    source "$lib_dir/night/hand-agent-watchdog.sh" || return 2
  fi
  if [ -r "$NIGHT/agents.txt" ]; then
    while IFS= read -r row || [ -n "$row" ]; do
      [[ "$row" == *$'\t'* ]] || continue
      IFS=$'\x1f' read -r pid name model effort worktree brief report log attempt started_at role start_ticks issues nodes \
        <<< "${row//$'\t'/$'\x1f'}"
      [[ "$name" == "$owner" || "$name" == "$owner-"* ]] || continue
      [[ "$pid" =~ ^[1-9][0-9]*$ && "$start_ticks" =~ ^[0-9]+$ ]] || continue
      hand_agent_pid_live "$pid" "$start_ticks" && return 0
    done < "$NIGHT/agents.txt"
  fi
  if units="$(systemctl --user list-units --state=active --no-legend --no-pager "${UNIT_PREFIX_TRANSIENT}-hand-$owner-*" 2>/dev/null)"; then
    if awk -v prefix="${UNIT_PREFIX_TRANSIENT}-hand-$owner-" 'index($1, prefix) == 1 { found = 1 } END { exit !found }' <<< "$units"; then
      return 0
    fi
  else
    unit_status=2
  fi
  hold_hand_owner_report_is_recent "$owner" "$now_epoch" && return 0
  [ "$unit_status" -eq 0 ] && return 1
  return 2
}


hold_sweep_age_notice() {
  local n="$1" state_json="$2" hold_json="$3" now_epoch="$4" holder kind created_at created_epoch age_seconds window last_window age_hours
  kind="$(jq -r '.kind // empty' <<< "$hold_json")"
  [[ "$kind" == supervisor || "$kind" == manual ]] || return 0
  created_at="$(jq -r '.created_at // empty' <<< "$hold_json")"
  [ -n "$created_at" ] || return 0
  created_epoch="$(agent_epoch -u "$created_at" 2>/dev/null || true)"
  [[ "$created_epoch" =~ ^[0-9]+$ ]] && [ "$created_epoch" -le "$now_epoch" ] || return 0
  age_seconds=$((now_epoch - created_epoch))
  (( age_seconds >= 172800 )) || return 0
  window=$((age_seconds / 172800))
  last_window="$(jq -r '.hold.aging_window // 0' <<< "$state_json")"
  [[ "$last_window" =~ ^[0-9]+$ ]] || last_window=0
  (( window > last_window )) || return 0
  holder="$(jq -r '.holder // "unknown"' <<< "$hold_json" | tr '\r\n\t' '   ')"
  age_hours=$((age_seconds / 3600))
  supervisor_inbox_append_once "hold-aging:$n:$window" \
    "hold-aging issue=#$n holder=$holder kind=$kind age=${age_hours}h" || return 1
  state_merge "$n" ".hold.aging_window = $window"
}


hold_sweep() {
  local NIGHT="${ZF_NIGHT_DIR:-$AGENT_HOME/night}"
  local held_numbers live_hold_numbers numbers n issue_json state_json hold_json holder release_condition expires_at kind hand_owner owner_status dead_owner
  local stage now_epoch expiry_epoch marker body record_json expiry_at renewal_expiry hold_created_at state_path state_label_json live_stage_labels durable_record
  local routing_stage inbox_key github_state handoff_patch
  local failure=0
  if ! held_numbers="$(gh issue list --repo "$REPO" --state open --label on-hold --limit 1000 --json number)"; then
    echo "hold_sweep: could not list open on-hold issues" >&2
    return 1
  fi
  if ! jq -e 'type == "array" and all(.[]; (.number | type) == "number")' \
      <<< "$held_numbers" >/dev/null 2>&1; then
    echo "hold_sweep: invalid issue list response" >&2
    return 1
  fi
  live_hold_numbers="$(jq -r '.[].number' <<< "$held_numbers")" || return 1
  numbers="$live_hold_numbers"
  for state_path in "$STATE_DIR"/*.json; do
    [ -f "$state_path" ] || continue
    [ "$(jq -r '.state // empty' "$state_path" 2>/dev/null || true)" = on-hold ] || continue
    n="${state_path##*/}"
    n="${n%.json}"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    grep -Fxq "$n" <<< "$numbers" || numbers="${numbers}${numbers:+$'\n'}$n"
  done
  numbers="$(printf '%s\n' "$numbers" | LC_ALL=C sort -u)" || return 1
  state_label_json="$(printf '%s\n' "${ALL_STATE_LABELS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
  now_epoch="$(date -u +%s)" || return 1
  while IFS= read -r n; do
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    state_json="$(state_read "$n")" || { failure=1; continue; }
    hold_json="$(jq -c '.hold // {}' <<< "$state_json" 2>/dev/null)"
    kind="$(jq -r '.kind // empty' <<< "$hold_json")"
    if ! grep -Fxq "$n" <<< "$live_hold_numbers"; then
      [ "$(jq -r '.state // empty' <<< "$state_json")" = on-hold ] || continue
      if ! issue_json="$(gh issue view "$n" --repo "$REPO" --json state,stateReason,closedAt,labels,comments,title 2>/dev/null)"; then
        echo "hold_sweep: could not inspect state-only held #$n; leaving state untouched" >&2
        failure=1
        continue
      fi
      if ! jq -e '(.state | type) == "string" and (.labels | type) == "array" and all(.labels[]; (.name | type) == "string")
          and ((.stateReason == null) or (.stateReason | type == "string"))
          and ((.closedAt == null) or (.closedAt | type == "string"))' \
          <<< "$issue_json" >/dev/null 2>&1; then
        echo "hold_sweep: invalid issue state or labels for state-only held #$n; leaving state untouched" >&2
        failure=1
        continue
      fi
      github_state="$(jq -r '.state | ascii_downcase' <<< "$issue_json")"
      if [ "$github_state" = closed ]; then
        if ! issue_reconcile_closed_state "$n" "$issue_json"; then
          echo "hold_sweep: could not reconcile closed hold for #$n" >&2
          failure=1
          continue
        fi
        echo "hold_sweep: reconciled closed hold for #$n" >&2
        continue
      fi
      # The advisor owns open holds and their escalation cadence.
      [ "$kind" != supervisor-inbox ] || continue
      [ "$github_state" = open ] || continue
      if jq -e 'any(.labels[]; .name == "on-hold")' <<< "$issue_json" >/dev/null 2>&1; then
        continue
      fi
      live_stage_labels="$(jq -c --argjson stage_labels "$state_label_json" \
        '[.labels[]?.name | select(. as $label | ($stage_labels | index($label)) != null)] | unique' \
        <<< "$issue_json")" || { failure=1; continue; }
      case "$(jq 'length' <<< "$live_stage_labels")" in
        0) stage="$(hold_stage_before "$state_json" "$issue_json")" || { failure=1; continue; } ;;
        1) stage="$(jq -r '.[0]' <<< "$live_stage_labels")" ;;
        *)
          if jq -e '.durable_record == true' <<< "$hold_json" >/dev/null 2>&1 \
            && hold_durable_record_valid "$hold_json"; then
            stage="$(jq -r '.stage_before' <<< "$hold_json")" || { failure=1; continue; }
            echo "hold_sweep: reconciling released #$n from durable stage=$stage despite stale labels" >&2
          else
            echo "hold_sweep: ambiguous live stage labels for released #$n; leaving state untouched" >&2
            failure=1
            continue
          fi
          ;;
      esac
      if ! issue_transition_allowed on-hold "$stage" hold-release; then
        echo "hold_sweep: unsafe stage '$stage' for released #$n; leaving state untouched" >&2
        failure=1
        continue
      fi
      if ! issue_transition "$n" "$stage" hold-release; then
        echo "hold_sweep: could not reconcile released hold for #$n" >&2
        failure=1
        continue
      fi
      echo "hold_sweep: reconciled manually released hold for #$n at stage=$stage" >&2
      continue
    fi
    # Durable metadata lets the common case avoid a GitHub comments read.
    if hold_durable_record_valid "$hold_json" \
      && jq -e '.durable_record == true' <<< "$hold_json" >/dev/null 2>&1; then
      holder="$(jq -r '.holder' <<< "$hold_json")"
      hand_owner="$(hold_hand_owner_from_record "$hold_json")"
      dead_owner=""
      if [ -n "$hand_owner" ]; then
        owner_status=0
        hold_hand_owner_is_live "$hand_owner" "$now_epoch" || owner_status=$?
        [ "$owner_status" -ne 1 ] || dead_owner="$hand_owner"
      fi
      if [ -z "$dead_owner" ] && jq -e --argjson now "$now_epoch" \
        '(.expires_at | fromdateiso8601) > $now' <<< "$hold_json" >/dev/null 2>&1; then
        hold_sweep_age_notice "$n" "$state_json" "$hold_json" "$now_epoch" || failure=1
        continue
      fi
    fi
    if ! issue_json="$(gh issue view "$n" --repo "$REPO" --json state,labels,comments,title 2>/dev/null)"; then
      echo "hold_sweep: could not inspect #$n; leaving hold untouched" >&2
      failure=1
      continue
    fi
    if ! jq -e '(.state // "" | ascii_downcase) == "open" and (.labels | type == "array") and (.comments | type == "array") and any(.labels[]?; .name == "on-hold")' \
        <<< "$issue_json" >/dev/null 2>&1; then
      continue
    fi
    if ! jq -e '.durable_record == true' <<< "$hold_json" >/dev/null 2>&1 \
      || ! hold_durable_record_valid "$hold_json"; then
      status=0
      hold_restore "$n" "$issue_json" || status=$?
      if [ "$status" -eq 3 ]; then
        kind="$(jq -r '.kind // "unknown"' <<< "$hold_json")"
        holder="$(jq -r '.holder // "missing"' <<< "$hold_json")"
        inbox_key="ownerless-hold:#$n"
        if ! supervisor_inbox_append_once "$inbox_key" \
          "ownerless-hold issue=#$n kind=$kind holder=$holder action=restore-an-exact-GitHub-hold-record-or-verify-metadata-before-release"; then
          failure=1
        fi
        echo "hold_sweep: #$n is ownerless; no exact durable hold record, leaving on-hold unchanged" >&2
        continue
      elif [ "$status" -ne 0 ]; then
        echo "hold_sweep: could not restore durable hold record for #$n" >&2
        failure=1
        continue
      fi
      state_json="$(state_read "$n")" || { failure=1; continue; }
      hold_json="$(jq -c '.hold' <<< "$state_json")" || { failure=1; continue; }
    fi
    kind="$(jq -r '.kind // empty' <<< "$hold_json")"
    # The advisor owns these holds and their escalation cadence.
    [ "$kind" != supervisor-inbox ] || continue
    holder="$(jq -r '.holder' <<< "$hold_json")"
    release_condition="$(jq -r '.release_condition' <<< "$hold_json")"
    expires_at="$(jq -r '.expires_at' <<< "$hold_json")"
    hold_sweep_age_notice "$n" "$state_json" "$hold_json" "$now_epoch" || failure=1
    hand_owner="$(hold_hand_owner_from_record "$hold_json")"
    dead_owner=""
    if [ -n "$hand_owner" ]; then
      owner_status=0
      hold_hand_owner_is_live "$hand_owner" "$now_epoch" || owner_status=$?
      [ "$owner_status" -ne 1 ] || dead_owner="$hand_owner"
    fi
    if [ -n "$dead_owner" ]; then
      kind="$(jq -r '.kind // empty' <<< "$hold_json")"
      case "$kind" in
        external-deliverable|ops-acceptance-after-release|pipeline-system-fastlane|guarded-recut-repeat|hand-dispatch|supervisor-hand|blocked-on-resolution)
          scheduler_requeue_issue "$n" "hold owner $dead_owner is inactive" "$issue_json" "" "" "" . "" "$hold_json" || failure=1
          continue ;;
      esac
      stage="$(jq -r '.stage_before // empty' <<< "$hold_json")"
      if ! hold_stage_label_is_valid "$stage"; then
        stage="$(hold_stage_before "$state_json" "$issue_json")" || { failure=1; continue; }
      fi
      hold_created_at="$(jq -r '.created_at // .expires_at' <<< "$hold_json")"
      marker="<!-- vecta-hold-dead-owner issue=$n owner=$dead_owner hold=$hold_created_at -->"
      if ! hold_comment_has_marker "$issue_json" "$marker"; then
        body="$BOT_DISCLAIMER
Hold released because hand agent $dead_owner is inactive: no active systemd unit or report newer than 3 hours. Resuming at stage $stage.
$marker"
        if ! guarded_issue_comment "$n" "$body"; then
          echo "hold_sweep: could not record dead owner $dead_owner for #$n; leaving hold untouched" >&2
          failure=1
          continue
        fi
      fi
      handoff_patch='.'
      if [ "$stage" = ready-for-agent ]; then
        scheduler_requeue_issue "$n" "hold owner $dead_owner is inactive" "$issue_json" "" "hold-$hold_created_at" "" . "" "$hold_json" || failure=1
        continue
      fi
      if ! issue_transition "$n" "$stage" hold-dead-owner "$handoff_patch" 0 "" "" 0 "$hold_json"; then
        echo "hold_sweep: could not release dead-owner hold for #$n" >&2
        failure=1
        continue
      fi
      continue
    fi
    if ! expiry_epoch="$(agent_epoch -u "$expires_at" 2>/dev/null)"; then
      echo "hold_sweep: invalid expiry in hold record for #$n; leaving hold untouched" >&2
      failure=1
      continue
    fi
    (( expiry_epoch <= now_epoch )) || continue
    kind="$(jq -r '.kind // empty' <<< "$hold_json")"
    renewal_reason=""
    if [ "$kind" = pipeline-system-fastlane ] && [ "$holder" = "hand-$n" ]; then
      if supervisor_hold_owner_state "$n"; then
        case "$SUPERVISOR_HOLD_OWNER_STATE" in
          queued|running|blocked|worktree-live) renewal_reason="while the pipeline-system hand owner remains active" ;;
        esac
      else
        owner_status=$?
        if ((owner_status != 1)); then
          echo "hold_sweep: could not confirm pipeline-system hand owner for #$n; leaving hold untouched: $SUPERVISOR_HOLD_OWNER_DETAIL" >&2
          failure=1
          continue
        fi
      fi
    elif { [ "$kind" = label-churn ] && [ "$holder" = detect-label-churn ]; } \
      || { [ "$kind" = repeat-cap ] && [ "$holder" = implement-repeat-cap ]; }; then
      hand_name="hand-$n"
      hand_root="${ZF_WORKTREE_ROOT:-$HOME/wt}"
      hand_wt="$hand_root/$hand_name"
      if supervisor_hand_owner_status "$hand_name" "$hand_wt"; then
        renewal_reason="while the hand agent owns the ticket"
      else
        owner_status=$?
        if ((owner_status != 1)); then
          echo "hold_sweep: could not confirm hand owner for #$n; leaving hold untouched: $SUPERVISOR_HAND_OWNER_ERROR" >&2
          failure=1
          continue
        fi
      fi
    # The hot-fix mechanism closed on 2026-10-04. Holds it left behind keep renewing until the supervisor hands
    # each issue back to the pipeline (hand-hotfix-sort); delete this branch and is_hotfix_lane_issue then.
    elif [ "$kind" = hotfix-lane ] && is_hotfix_lane_issue "$issue_json"; then
      renewal_reason="while the issue remains marked for the hot-fix lane"
    fi
    if [ -n "$renewal_reason" ]; then
      renewal_expiry="$(hold_expiry_resolve 168h)" || { failure=1; continue; }
      if ! (
        f="$(state_file "$n")" || exit 1
        exec {hold_lock_fd}>"$f.lock" && flock -x "$hold_lock_fd" || exit 1
        current="$(state_read "$n")" || exit 1
        jq -e --argjson expected "$hold_json" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$current" >/dev/null || exit 1
        marker="<!-- vecta-hold-renewed issue=$n expires=$expires_at -->"
        if ! hold_comment_has_marker "$issue_json" "$marker"; then
          body="$BOT_DISCLAIMER
Hold renewed for 168 hours $renewal_reason. Holder: $holder; next expiry: $renewal_expiry.
$marker"
          guarded_issue_comment "$n" "$body" || exit 1
        fi
        record_json="$(jq -c --arg expires "$renewal_expiry" '.expires_at = $expires | .durable_record = false' <<< "$hold_json")" || exit 1
        state_merge "$n" ".hold = $record_json" __issue_transition_lock_held \
          && hold_durable_record_publish "$n" "$record_json" "$issue_json" \
          && state_merge "$n" '.hold.durable_record = true' __issue_transition_lock_held
      ); then
        echo "hold_sweep: could not renew hold for #$n" >&2
        failure=1
      fi
      continue
    fi
    case "$kind" in
      external-deliverable|ops-acceptance-after-release|pipeline-system-fastlane|guarded-recut-repeat|hand-dispatch|supervisor-hand|blocked-on-resolution)
        scheduler_requeue_issue "$n" "hold expired; $release_condition" "$issue_json" "" "" "" . "" "$hold_json" || failure=1
        continue ;;
    esac
    stage="$(jq -r '.stage_before // empty' <<< "$hold_json")"
    if ! hold_stage_label_is_valid "$stage"; then
      stage="$(hold_stage_before "$state_json" "$issue_json")" || { failure=1; continue; }
    fi
    marker="<!-- vecta-hold-expired issue=$n expires=$expires_at -->"
    if ! hold_comment_has_marker "$issue_json" "$marker"; then
      body="$BOT_DISCLAIMER
Hold expired. Holder: $holder. Release condition was not met: $release_condition. Resuming at stage $stage.
$marker"
      if ! guarded_issue_comment "$n" "$body"; then
        echo "hold_sweep: could not record expiry for #$n; leaving hold untouched" >&2
        failure=1
        continue
      fi
    fi
    # Reset the attempt budget in the same locked transition as the release.
    handoff_patch='.attempts = 0 | if .pipeline_system.enabled == true then if ((.pipeline_system.resume_artifact_sha // "") | test("^[0-9a-f]{40,64}$")) then .pipeline_system.resume_artifact_attempt = .attempts else del(.pipeline_system.resume_artifact_sha, .pipeline_system.resume_artifact_attempt) end else . end'
    if [ "$stage" = ready-for-agent ]; then
      hold_created_at="$(jq -r '.created_at // .expires_at' <<< "$hold_json")"
      scheduler_requeue_issue "$n" "hold expired; $release_condition" "$issue_json" "" "hold-$hold_created_at" "" "$handoff_patch" "" "$hold_json" || failure=1
      continue
    fi
    if ! issue_transition "$n" "$stage" hold-expired "$handoff_patch" 0 "" "" 0 "$hold_json"; then
      echo "hold_sweep: could not release expired hold for #$n" >&2
      failure=1
      continue
    fi
  done <<< "$numbers"
  [ "$failure" -eq 0 ]
}


# Operator-selected answer: refresh roadmap context outside the scheduler, then
# use the same serialized requeue. The patch checks the hold episode under the
# transition lock, so a new decision request cannot consume an older answer.
hold_answer() (
  local n="${1:-}" comment_id="${2:-}" state requested hold_created comment answer patch
  [[ "$n" =~ ^[1-9][0-9]*$ && "$comment_id" =~ ^[1-9][0-9]*$ ]] || return 64
  state="$(state_read "$n")" || return 1
  jq -e '.state == "on-hold" and .hold.holder == "supervisor-inbox"
    and .hold.kind == "conclusion" and .hold.stage_before == "ready-for-agent"
    and .implement_decision.route == "supervisor-inbox"
    and (.implement_decision.requested_at // "") != ""' <<< "$state" >/dev/null || {
    echo "hold_answer: #$n has no pending implement supervisor decision" >&2
    return 1
  }
  requested="$(jq -r '.implement_decision.requested_at' <<< "$state")" || return 1
  hold_created="$(jq -r '.hold.created_at' <<< "$state")" || return 1
  comment="$(gh api "repos/$REPO/issues/comments/$comment_id")" || return 1
  answer="$(jq -ce --arg issue_url "https://api.github.com/repos/$REPO/issues/$n" \
    --arg requested "$requested" --argjson id "$comment_id" '
    select(.id == $id and .issue_url == $issue_url and .author_association == "OWNER"
      and ((.created_at | fromdateiso8601) >= ($requested | fromdateiso8601))
      and (.body | type == "string" and test("\\S")))
    | {id, url:.html_url, body, created_at, applied_at:(now|todate)}' <<< "$comment")" || {
    echo "hold_answer: comment $comment_id is not a fresh owner answer on #$n" >&2
    return 1
  }
  patch="$(jq -nr --arg requested "$requested" --arg created "$hold_created" --argjson answer "$answer" '
    "if .state == \"on-hold\" and .hold.holder == \"supervisor-inbox\" and .hold.kind == \"conclusion\""
    + " and .hold.created_at == " + ($created|tojson)
    + " and .implement_decision.requested_at == " + ($requested|tojson)
    + " then .implement_decision.answer = " + ($answer|tojson)
    + " | .brief_md = ((.brief_md // \"\" | gsub(\"(?s)<!-- ZF_SUPERVISOR_WORKFLOW_DECISION:BEGIN -->.*?<!-- ZF_SUPERVISOR_WORKFLOW_DECISION:END -->\"; \"\")) + "
    + ("\n\n<!-- ZF_SUPERVISOR_WORKFLOW_DECISION:BEGIN -->\n## Supervisor workflow decision (automated engineering guidance; not founder-authored facts or authority)\nSource: "
       + $answer.url + "\n\n" + $answer.body + "\n<!-- ZF_SUPERVISOR_WORKFLOW_DECISION:END -->" | tojson) + ")"
    + " else error(\"supervisor decision episode changed\") end"')" || return 1
  state_requeue "$n" release-hold hold-requeue "$patch"
)


# hold_rule N|issue-N|pr-N requeue|approve|arbiter|recut COMMENT: a supervisor ruling. Records supervisor-<action> in the
# unit history (refills the stop-loss/arbitration budgets; a parked unit is moved by scheduler.sh --rule) and releases a
# scheduler-stop-loss hold if the issue has one. COMMENT must be an owner comment on the issue (or the PR for pr-N).
hold_rule() {
  local target="${1:-}" action="${2:-}" comment_id="${3:-}" blocker="${4:-}" unit n state="" comment sched
  [[ "$target" =~ ^[1-9][0-9]*$ ]] && target="issue-$target"
  [[ "$target" =~ ^(issue|pr)-([1-9][0-9]*)$ && "$action" =~ ^(requeue|approve|arbiter|recut|reblock)$ && "$comment_id" =~ ^[1-9][0-9]*$ ]] || return 64
  unit="$target"; n="${unit#*-}"
  if [[ "$unit" == issue-* ]]; then
    state="$(state_read "$n")" || return 1
    jq -e '.state != "on-hold" or .hold.holder == "scheduler-stop-loss"' <<< "$state" >/dev/null || {
      echo "hold_rule: #$n is held by someone other than scheduler-stop-loss" >&2
      return 1
    }
  fi
  comment="$(gh api "repos/$REPO/issues/comments/$comment_id")" || return 1
  jq -e --arg u "https://api.github.com/repos/$REPO/issues/$n" '.issue_url == $u and .author_association == "OWNER"' <<< "$comment" >/dev/null || {
    echo "hold_rule: comment $comment_id is not an owner comment on #$n" >&2
    return 1
  }
  sched="$(dirname -- "$_AGENT_LIB_DIR/lib.sh")/mac-autopilot/scheduler.sh"
  # recut needs the issue out of on-hold first, or route_to_recut leaves it on-hold
  if [[ "$action" == recut && -n "$state" ]] && jq -e '.state == "on-hold"' <<< "$state" >/dev/null; then
    state_requeue "$n" release-hold hold-requeue . "$(jq -c .hold <<< "$state")" || return 1
    state=""
  fi
  bash "$sched" --rule "$unit" "$action" "$(jq -r .html_url <<< "$comment")" "$(jq -r '.body[0:4000]' <<< "$comment")" "$blocker" || return 1
  if [[ -n "$state" ]] && jq -e '.state == "on-hold"' <<< "$state" >/dev/null; then
    state_requeue "$n" release-hold hold-requeue . "$(jq -c .hold <<< "$state")"
  fi
}


hold_cli_main() {
  if [ "${1:-}" = --sweep ]; then
    shift
    (($# == 0)) || { echo "usage: hold.sh --sweep" >&2; return 64; }
    hold_sweep
  elif [ "${1:-}" = --hold ]; then
    shift
    (($# >= 1)) || { echo "usage: hold.sh --hold <issue> --holder <name> --release <condition> --expires <duration>" >&2; return 64; }
    hold_issue "$@"
  elif [ "${1:-}" = --restore ]; then
    (($# == 2)) || { echo "usage: hold.sh --restore <issue>" >&2; return 64; }
    hold_restore "$2"
  elif [ "${1:-}" = --rule ]; then
    (($# == 5 || $# == 7)) && [[ "$3" =~ ^--(requeue|approve|arbiter|recut|reblock)$ && "$4" = --comment ]] && { (($# == 5)) || [ "$6" = --blocked-on ]; } || { echo "usage: hold.sh --rule <issue|issue-N|pr-N> --requeue|--approve|--arbiter|--recut|--reblock --comment <id> [--blocked-on <N>]" >&2; return 64; }
    hold_rule "$2" "${3#--}" "$5" "${7:-}"
  elif [ "${1:-}" = --answer ]; then
    (($# == 4)) && [ "$3" = --comment ] || { echo "usage: hold.sh --answer <issue> --comment <id>" >&2; return 64; }
    hold_answer "$2" "$4"
  else
    hold_issue "$@"
  fi
}


# advisor_role_disabled -- the effective policy marks the advisor role disabled (the generic default policy ships it disabled; the
# the product pack's policy enables it). A policy that cannot be read is not "disabled": callers then follow their normal path.
advisor_role_disabled() {
  local effective
  model_policy identity advisor >/dev/null 2>&1 && return 1
  effective="$(model_policy_effective_live_json "$MODEL_POLICY_FILE")" || return 1
  jq -e '.roles.advisor.disabled == true' <<< "$effective" >/dev/null
}


# hold_for_missing_advisor <n> [remove_label] -- park the issue for the maintainer, who rules and requeues it.
hold_for_missing_advisor() {
  local n="$1" remove_label="${2:-ready-for-agent}"
  hold_issue "$n" --holder supervisor --expires 168h --kind advisor-disabled \
    --release "the advisor role is disabled: the maintainer rules on this issue, then requeues it" \
    --remove-label "$remove_label" || return 1
  supervisor_inbox_append_once "advisor-disabled:$n" \
    "issue $n held for the maintainer: the advisor role is disabled, so no ruling can be requested"
}


# issue_on_hold_live <n> -- the merge-time hold read: the issue's own labels,
# never the bulk on-hold list. That list lags edits, so a merge right after
# `state_requeue N release-hold` read the released hold and refused (#2686,
# 2026-10-08). A failed read stays fail-closed (on hold).
issue_on_hold_live() {
  local labels
  if ! labels="$(gh issue view "$1" --repo "$REPO" --json labels -q '.labels[].name' 2>&1)"; then
    echo "issue_on_hold_live: gh issue view failed for #$1 -- treating as ON-HOLD (fail-closed): $labels" >&2
    return 0
  fi
  grep -Fqx -- on-hold <<< "$labels"
}


is_on_hold() {
  local status
  if cached_issue_has_label "$1" on-hold; then
    return 0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] && return 1
  echo "is_on_hold: gh issue view failed for #$1 -- cannot confirm on-hold status, treating as ON-HOLD (fail-closed): ${ISSUE_LABEL_VIEW_ERROR[$1]:-unknown label state}" >&2
  ON_HOLD_QUERY_FAILURE_COUNT=$((ON_HOLD_QUERY_FAILURE_COUNT + 1))
  case " $ON_HOLD_QUERY_FAILURE_ISSUES " in
    *" $1 "*) ;;
    *) ON_HOLD_QUERY_FAILURE_ISSUES="${ON_HOLD_QUERY_FAILURE_ISSUES:+$ON_HOLD_QUERY_FAILURE_ISSUES }$1" ;;
  esac
  return 0
}


# Transfer the existing hold brief to the issue before making it schedulable.
# The episode marker makes a failed transition safe to retry on the next tick.
scheduler_requeue_issue() {
  local n="$1" reason="$2" issue_json="${3:-}" context="${4:-}" state findings hold_id marker body owner_status=0 prs rescue_refs
  local hold_kind start_ref="" start_sha="" patch="${7:-.}" matched_pr pr_handoff handoff_data transition_reason="${6:-pipeline-requeue}"
  local old_worktree="${8:-}" expected_hold="${9:-}" old_head old_status hand_name default_tree recorded_tree candidate
  SCHEDULER_REQUEUE_RESULT=failed
  state="$(state_read "$n")" || return 1
  if [ -n "$expected_hold" ] && ! jq -e --argjson expected "$expected_hold" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$state" >/dev/null; then
    echo "scheduler_requeue_issue: hold for #$n changed before handoff; retry from the current hold" >&2
    return 1
  fi
  if [ -z "$issue_json" ]; then
    issue_json="$(gh issue view "$n" --repo "$REPO" --json state,comments)" || return 1
  fi
  # A previously closed issue must not be made schedulable by a stale handoff.
  if ! jq -e '(.state // "OPEN" | ascii_upcase) == "OPEN"' <<< "$issue_json" >/dev/null; then
    SCHEDULER_REQUEUE_RESULT=closed
    return 0
  fi
  if [ "$(jq -r '.hold.kind // empty' <<< "$state")" = ops-acceptance-after-release ]; then
    supervisor_ops_acceptance_handoff "$n" "$state" "$reason" "$expected_hold" || return 1
    SCHEDULER_REQUEUE_RESULT=held
    return 0
  fi
  if [ "$(jq -r '.state // empty' <<< "$state")" = on-hold ]; then
    supervisor_hold_owner_state "$n" "$(jq -r '.hold.kind // empty' <<< "$state")" || owner_status=$?
    (( owner_status == 0 )) || return 1
    case "$SUPERVISOR_HOLD_OWNER_STATE" in
      queued|running|worktree-live|waiting|blocked) SCHEDULER_REQUEUE_RESULT=owned; return 0 ;;
      none) ;;
      *) return 1 ;;
    esac
  fi
  findings="$(supervisor_hand_issue_findings "$state")" || return 1
  prs="$(gh pr list --repo "$REPO" --head "agent/issue-$n" --state open --json number,url,headRefName)" || return 1
  jq -e 'type == "array"' <<< "$prs" >/dev/null || return 1
  matched_pr="$(jq -r --arg branch "agent/issue-$n" '[.[] | select(.headRefName == $branch)] | length' <<< "$prs")" || return 1
  pr_handoff="$(jq -c --arg branch "agent/issue-$n" '[.[] | select(.headRefName == $branch)][0] // {} | if .number then {open_pr:.number,open_branch:.headRefName} else {} end' <<< "$prs")" || return 1
  hold_kind="$(jq -r '.hold.kind // empty' <<< "$state")" || return 1
  # Include remote rescues created by other checkouts for every handoff kind.
  git_fetch_hand_bounded "$REPO_DIR" "$n" "$([ "$matched_pr" -eq 0 ] || printf 'agent/issue-%s' "$n")" || return 1
  hold_id="${5:-$(jq -r '.hold.created_at // .hold.expires_at // .run.implement_started_at // .state_changed_at // .requeued_at // "unheld"' <<< "$state")}" || return 1
  rescue_refs="$(git -C "$REPO_DIR" for-each-ref --sort=-committerdate --format='%(refname:short)' refs/remotes/origin/rescued/ \
    | awk -v issue="(issue-|hand-)$n" '$0 ~ (issue "([^0-9]|$)") {print}')" || return 1
  if [ -n "$rescue_refs" ]; then
    start_ref="${rescue_refs%%$'\n'*}"
    start_sha="$(git -C "$REPO_DIR" rev-parse --verify "$start_ref^{commit}")" || return 1
    handoff_data="$(jq -cn --arg episode "$hold_id" --arg ref "${start_ref#origin/}" --arg sha "$start_sha" --argjson pr "$pr_handoff" '{episode:$episode,start_ref:$ref,start_sha:$sha} + $pr')"
  else
    handoff_data="$(jq -cn --arg episode "$hold_id" --argjson pr "$pr_handoff" '{episode:$episode} + $pr')"
  fi
  if [ -z "$old_worktree" ]; then
    hand_name="$(jq -r '.hold.holder // empty' <<< "$state")"
    [[ "$hand_name" == hand-* ]] || hand_name="hand-$n"
    default_tree="${ZF_WORKTREE_ROOT:-${HOME:?HOME is not set}/wt}/$hand_name"
    recorded_tree="$(agent_latest_worktree_for_hand "$REPO_DIR" "$hand_name" "$AGENT_HOME/night/hand-registry/$hand_name.json" "$AGENT_HOME/night/$hand_name.report" "$default_tree" 0 2>/dev/null || true)"
    if [ -n "$recorded_tree" ]; then
      old_worktree="$recorded_tree"
    elif [ -e "$default_tree" ]; then
      supervisor_inbox_append_once "handoff-worktree-unusable:$hand_name" \
        "handoff-worktree-unusable issue=#$n worktree=$default_tree" || return 1
      return 1
    fi
  fi
  if [ -d "$old_worktree" ]; then
    agent_worktree_is_usable "$REPO_DIR" "$old_worktree" || return 1
    old_head="$(git -C "$old_worktree" rev-parse --verify HEAD)" || return 1
    old_status="$(git -C "$old_worktree" status --porcelain=v1 --untracked-files=all)" || return 1
    handoff_data="$(jq -c --arg path "$old_worktree" --arg sha "$old_head" --argjson dirty "$([ -n "$old_status" ] && printf true || printf false)" \
      '. + {worktree:$path,worktree_sha:$sha,worktree_dirty:$dirty}' <<< "$handoff_data")" || return 1
  else
    for candidate in "hand/$n" "hand-$n"; do
      old_head="$(git -C "$REPO_DIR" rev-parse --verify "$candidate^{commit}" 2>/dev/null || true)"
      [[ "$old_head" =~ ^[0-9a-f]{40}$ ]] || continue
      git -C "$REPO_DIR" merge-base --is-ancestor "$old_head" origin/main 2>/dev/null && continue
      handoff_data="$(jq -c --arg sha "$old_head" '. + {worktree:"",worktree_sha:$sha,worktree_dirty:false}' <<< "$handoff_data")" || return 1
      break
    done
  fi
  patch+=" | .scheduler_handoff = $handoff_data"
  context+="
Existing PRs: $(jq -c '.' <<< "$prs")
Rescued refs (newest first): ${rescue_refs:-none}"
  marker="<!-- vecta-scheduler-handoff issue=$n hold=$hold_id -->"
  if ! hold_comment_has_marker "$issue_json" "$marker"; then
    body="$BOT_DISCLAIMER
The scheduler will resume this issue: $reason.

$findings
$context
$marker"
    guarded_issue_comment "$n" "$body" || return 1
  fi
  if [ "$(jq -r '.state // empty' <<< "$state")" = on-hold ]; then
    state_requeue "$n" release-hold hold-requeue "$patch" "${expected_hold:-$(jq -c '.hold' <<< "$state")}" || return $?
  elif [ "$(jq -r '.state // empty' <<< "$state")" != ready-for-agent ]; then
    state_requeue "$n" "" "$transition_reason" "$patch" || return $?
  else
    state_merge "$n" "$patch" || return $?
  fi
  SCHEDULER_REQUEUE_RESULT=requeued
}
