#!/usr/bin/env bash
set -euo pipefail

INTAKE_PRIORITY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$INTAKE_PRIORITY_DIR/lib.sh"

intake_priority_config() {
  local defaults override config_file merged
  defaults="$(jq -ce '.intake_priority | select(type == "object")' "$INTAKE_PRIORITY_DIR/mac-autopilot/config.template.json")" || return 1
  override='{}'
  config_file="$(zf_config_file night.json 2>/dev/null || true)"
  if [[ -n "$config_file" && -e "$config_file" ]]; then
    override="$(jq -ce 'if type != "object" then error("config must be an object") else (.intake_priority // {}) | if type == "object" then . else error("intake_priority must be an object") end end' "$config_file" 2>/dev/null)" || return 1
  fi
  merged="$(jq -cn --argjson defaults "$defaults" --argjson override "$override" '
    ($defaults * $override)
    | .labels = ($defaults.labels * ($override.labels // {}))
    | .score_thresholds = ($defaults.score_thresholds * ($override.score_thresholds // {}))
  ')" || return 1
  jq -ce '
    .enabled | type == "boolean"
  ' <<< "$merged" >/dev/null || return 1
  jq -ce '
    .labels as $labels
    | .score_thresholds as $thresholds
    | .minimum_confidence as $minimum
    | ($labels | type == "object")
      and all(["top","high","normal","low","needs_triage","route_prefix"][]; $labels[.] | type == "string" and length > 0)
      and (([$labels.top,$labels.high,$labels.normal,$labels.low,$labels.needs_triage] | unique | length) == 5)
      and ($thresholds | type == "object")
      and all(["normal","high","top"][]; ($thresholds[.] | type == "number" and . >= 0 and . <= 3))
      and ($thresholds.normal <= $thresholds.high and $thresholds.high <= $thresholds.top)
      and ($minimum | type == "number" and . >= 0 and . <= 1)
  ' <<< "$merged" >/dev/null || return 1
  printf '%s\n' "$merged"
}

intake_priority_judge_policy() {
  jq -c '{
    labels: {
      top: .labels.top,
      high: .labels.high,
      normal: .labels.normal,
      low: .labels.low,
      needsTriage: .labels.needs_triage,
      routePrefix: .labels.route_prefix
    },
    scoreThresholds: .score_thresholds,
    minimumConfidence: .minimum_confidence
  }' <<< "$1"
}

intake_priority_route_context() {
  local repo="$1" issue_json="$2" tree='' cache_file='' temp_dir='' containers='[]' route='none-fits' candidate
  cache_file="${ZF_ROADMAP_TREE_CACHE_FILE:-}"
  if [[ -n "$cache_file" && -r "$cache_file" ]]; then
    tree="$(cat -- "$cache_file")" || tree=''
  else
    temp_dir="$(mktemp -d)" || return 1
    export ZF_ROADMAP_SNAPSHOT_FILE="$temp_dir/snapshot.json"
    if roadmap_fetch_tree "$temp_dir/tree.json" "$repo"; then
      cache_file="$temp_dir/tree.json"
      tree="$(cat -- "$cache_file")" || tree=''
    fi
  fi
  if [[ -n "$tree" ]] && roadmap_tree_is_valid "$tree"; then
    containers="$(roadmap_epics "$tree" | jq -c 'map({number,title})')" || containers='[]'
    candidate="$(roadmap_choose_epic "$tree" "$issue_json" 2>/dev/null | jq -r '.epic // empty' 2>/dev/null || true)"
    [[ "$candidate" =~ ^[1-9][0-9]*$ ]] && route="$candidate"
  fi
  if [[ -n "$temp_dir" ]]; then rm -rf -- "$temp_dir"; fi
  jq -cn --argjson containers "$containers" --arg route "$route" '{containers:$containers, baseline_route:$route}'
}

intake_priority_duplicate_candidates() {
  local repo="$1" issue_json="$2" issue_number title query raw
  issue_number="$(jq -r '.number // empty' <<< "$issue_json")"
  title="$(jq -r '.title // empty' <<< "$issue_json")"
  query="$(jq -r '[(.title // "" | ascii_downcase | scan("[a-z0-9]{3,}"))][0:4] | join(" ")' <<< "$issue_json")"
  [[ -n "$query" ]] || query="${title:0:80}"
  [[ -n "$query" ]] || { printf '[]\n'; return 0; }
  if ! raw="$(gh issue list --repo "$repo" --state open --limit 10 --search "$query in:title" --json number,title 2>/dev/null)"; then
    printf '[]\n'
    return 0
  fi
  jq -ce --argjson current "${issue_number:-0}" '
    if type != "array" then error("invalid issue search response") else
      map(select((.number | type == "number") and .number > 0 and .number != $current and (.title | type == "string")))
      | map({number,title}) | .[0:10]
    end
  ' <<< "$raw"
}

intake_priority_recent_main_subjects() {
  local repo_dir="${ZF_REPO_DIR:-$REPO_DIR}" subjects
  if ! subjects="$(git -C "$repo_dir" log -n 20 --format=%s origin/main 2>/dev/null)"; then
    subjects="$(git -C "$repo_dir" log -n 20 --format=%s HEAD 2>/dev/null || true)"
  fi
  jq -Rsc 'split("\n") | map(select(length > 0)) | .[0:20]' <<< "$subjects"
}

intake_priority_prepare_state() {
  local repo="$1" issue_file="$2" triage_state="$3" config="$4" issue_json policy route_context duplicate_candidates recent baseline_priority baseline_duplicate baseline_stale current_decision event_id
  issue_json="$(jq -ce 'select(type == "object" and (.number | type == "number" and . > 0) and (.title | type == "string"))' "$issue_file")" || return 1
  policy="$(intake_priority_judge_policy "$config")" || return 1
  route_context="$(intake_priority_route_context "$repo" "$issue_json")" || return 1
  duplicate_candidates="$(intake_priority_duplicate_candidates "$repo" "$issue_json")" || duplicate_candidates='[]'
  recent="$(intake_priority_recent_main_subjects)" || recent='[]'
  baseline_priority="$(jq -r --arg top "$(jq -r '.labels.top' <<< "$config")" \
    --arg high "$(jq -r '.labels.high' <<< "$config")" --arg normal "$(jq -r '.labels.normal' <<< "$config")" \
    --arg low "$(jq -r '.labels.low' <<< "$config")" '
      [.labels[]? | if type == "string" then . else .name // "" end]
      | map(select(. == $top or . == $high or . == $normal or . == $low)) | .[0] // $normal
    ' <<< "$issue_json")" || return 1
  baseline_duplicate=false
  baseline_stale=false
  [[ "$triage_state" == duplicate ]] && baseline_duplicate=true
  [[ "$triage_state" == wontfix ]] && baseline_stale=true
  if jq -e '[.labels[]? | if type == "string" then . else .name // "" end] | index("duplicate") != null' <<< "$issue_json" >/dev/null; then baseline_duplicate=true; fi
  if jq -e '[.labels[]? | if type == "string" then . else .name // "" end] | any(. == "obsolete" or . == "wontfix")' <<< "$issue_json" >/dev/null; then baseline_stale=true; fi
  baseline_route="$(jq -r '.baseline_route' <<< "$route_context")"
  current_decision="$(jq -cn --arg priority "$baseline_priority" --arg route "$baseline_route" \
    --argjson duplicate "$baseline_duplicate" --argjson stale "$baseline_stale" \
    '{priority:$priority,route:$route,duplicate:$duplicate,duplicateCandidates:[],stale:$stale}')" || return 1
  event_id="intake-priority:$(jq -r '.number' <<< "$issue_json"):$(date +%s%N):$RANDOM"
  jq -cn --arg event_id "$event_id" --arg current "$current_decision" --argjson issue "$issue_json" \
    --argjson containers "$(jq -c '.containers' <<< "$route_context")" \
    --argjson duplicates "$duplicate_candidates" --argjson recent "$recent" --argjson policy "$policy" \
    '{event_id:$event_id,currentDecision:$current,issue:{number:$issue.number,title:$issue.title,body:($issue.body // "")},
      roadmapContainers:$containers,duplicateCandidates:$duplicates,recentMainSubjects:$recent,policy:$policy}'
}

intake_priority_judge() {
  local repo="$1" issue_file="$2" triage_state="$3" dry_stub="$4" config state result judge_script
  config="$(intake_priority_config)" || return 1
  if [[ "$dry_stub" == true ]]; then
    judge_script="${ZF_TS_JUDGE_SCRIPT:-}"
    [[ -n "$judge_script" && -x "$judge_script" ]] || { echo 'intake-priority: --dry-stub requires an executable ZF_TS_JUDGE_SCRIPT' >&2; return 64; }
    [[ "$(readlink -f -- "$judge_script")" != "$(readlink -f -- "$INTAKE_PRIORITY_DIR/ts-judge.sh")" ]] || { echo 'intake-priority: --dry-stub refuses the real TypeSafe judge' >&2; return 64; }
  else
    judge_script="${ZF_TS_JUDGE_SCRIPT:-$INTAKE_PRIORITY_DIR/ts-judge.sh}"
    [[ -n "${TYPESAFE_API_KEY:-}${TYPESAFE_ENV_FILE:-}" ]] || { echo 'intake-priority: TypeSafe key is not configured' >&2; return 78; }
  fi
  state="$(intake_priority_prepare_state "$repo" "$issue_file" "$triage_state" "$config")" || return 1
  if ! result="$(printf '%s\n' "$state" | bash "$judge_script" intake-priority)"; then
    echo 'intake-priority: judge failed' >&2
    return 1
  fi
  jq -ce --argjson duplicates "$(jq -c '.duplicateCandidates' <<< "$state")" \
    --argjson containers "$(jq -c '.roadmapContainers' <<< "$state")" \
    '. + {intake_context:{duplicate_candidates:$duplicates,roadmap_containers:$containers}}' <<< "$result"
}

intake_priority_place_route() {
  local REPO="$1" issue_file="$2" issue_number="$3" route="$4" cache_file="${ZF_ROADMAP_TREE_CACHE_FILE:-}" tree='' temp_dir='' rc
  [[ "$route" == none-fits ]] && return 0
  if [[ -n "$cache_file" && -r "$cache_file" ]]; then
    tree="$(cat -- "$cache_file")" || tree=''
  fi
  if [[ -z "$tree" ]] || ! roadmap_tree_is_valid "$tree"; then
    temp_dir="$(mktemp -d)" || return 1
    cache_file="$temp_dir/tree.json"
    if ! ZF_ROADMAP_SNAPSHOT_FILE="$temp_dir/snapshot.json" roadmap_fetch_tree "$cache_file" "$REPO"; then
      rm -rf -- "$temp_dir"
      echo 'intake-priority: roadmap tree fetch failed for selected route' >&2
      return 1
    fi
  fi
  if roadmap_place_issue "$cache_file" "$issue_number" "$(cat -- "$issue_file")" '' "$route"; then
    rc=0
  else
    rc=$?
  fi
  [[ -n "$temp_dir" ]] && rm -rf -- "$temp_dir"
  return "$rc"
}

intake_priority_ensure_labels() {
  local repo="$1"; shift
  local known label description
  known="$(gh label list --repo "$repo" --limit 1000 --json name | jq -r '[.[].name] | .[]')" || return 1
  for label in "$@"; do
    [[ -n "$label" ]] || continue
    if ! grep -Fqx -- "$label" <<< "$known"; then
      description='Intake priority and roadmap route'
      [[ "$label" == route:* ]] && description='Roadmap route selected during issue intake'
      guarded_write gh label create "$label" --repo "$repo" --color 6E7781 --description "$description" || return 1
      known+=$'\n'"$label"
    fi
  done
}

intake_priority_apply_result() {
  local repo="$1" issue_file="$2" result="$3" config decision issue_json issue_number priority route route_label prefix top high normal low low_confidence needs_triage labels label
  local -a edit_args=() ensure_labels=()
  config="$(intake_priority_config)" || return 1
  jq -e '.status == "answered" and .adopted == true' <<< "$result" >/dev/null || return 0
  decision="$(jq -er '.decision | select(type == "string") | fromjson' <<< "$result")" || return 1
  issue_json="$(jq -ce '.' "$issue_file")" || return 1
  issue_number="$(jq -er '.number | select(type == "number" and . > 0)' <<< "$issue_json")" || return 1
  top="$(jq -r '.labels.top' <<< "$config")"
  high="$(jq -r '.labels.high' <<< "$config")"
  normal="$(jq -r '.labels.normal' <<< "$config")"
  low="$(jq -r '.labels.low' <<< "$config")"
  low_confidence="$(jq -r '.labels.needs_triage' <<< "$config")"
  prefix="$(jq -r '.labels.route_prefix' <<< "$config")"
  priority="$(jq -er '.priority | select(type == "string")' <<< "$decision")" || return 1
  route="$(jq -er '.route | select(type == "string")' <<< "$decision")" || return 1
  needs_triage="$(jq -r '.needsTriage == true' <<< "$decision")"
  [[ "$priority" == "$top" || "$priority" == "$high" || "$priority" == "$normal" || "$priority" == "$low" ]] || return 1
  if [[ "$route" != none-fits ]]; then
    jq -e --arg route "$route" 'any(.intake_context.roadmap_containers[]?; (.number | tostring) == $route)' <<< "$result" >/dev/null || return 1
  fi
  intake_priority_place_route "$repo" "$issue_file" "$issue_number" "$route" || return 1
  route_label="$prefix$route"
  labels="$(jq -c '[.labels[]? | if type == "string" then . else .name // "" end]' <<< "$issue_json")"
  for label in "$top" "$high" "$normal" "$low"; do
    if [[ "$label" != "$priority" ]] && jq -e --arg label "$label" 'index($label) != null' <<< "$labels" >/dev/null; then
      edit_args+=(--remove-label "$label")
    fi
  done
  while IFS= read -r label; do
    [[ -n "$label" ]] || continue
    [[ "$label" == "$route_label" ]] || edit_args+=(--remove-label "$label")
  done < <(jq -r --arg prefix "$prefix" '.[] | select(startswith($prefix))' <<< "$labels")
  if ! jq -e --arg label "$priority" 'index($label) != null' <<< "$labels" >/dev/null; then
    edit_args+=(--add-label "$priority")
    ensure_labels+=("$priority")
  fi
  if [[ -n "$route_label" ]] && ! jq -e --arg label "$route_label" 'index($label) != null' <<< "$labels" >/dev/null; then
    edit_args+=(--add-label "$route_label")
    ensure_labels+=("$route_label")
  fi
  if [[ "$needs_triage" == true ]] && ! jq -e --arg label "$low_confidence" 'index($label) != null' <<< "$labels" >/dev/null; then
    edit_args+=(--add-label "$low_confidence")
    ensure_labels+=("$low_confidence")
  fi
  if (( ${#edit_args[@]} == 0 )); then return 0; fi
  intake_priority_ensure_labels "$repo" "${ensure_labels[@]}" || return 1
  guarded_write gh issue edit "$issue_number" --repo "$repo" "${edit_args[@]}"
}

intake_priority_triage() {
  local issue_number="$1" triage_state="$2" repo="$3" config enabled issue_file result decision priority
  config="$(intake_priority_config)" || { echo 'intake-priority: skipped (invalid-config)' >&2; return 0; }
  enabled="$(jq -r '.enabled' <<< "$config")"
  if [[ "$enabled" != true ]]; then
    echo 'intake-priority: skipped (disabled)' >&2
    return 0
  fi
  if [[ -z "${TYPESAFE_API_KEY:-}${TYPESAFE_ENV_FILE:-}" ]]; then
    echo 'intake-priority: skipped (missing-typesafe-key)' >&2
    return 0
  fi
  issue_file="$(mktemp)" || return 0
  cat > "$issue_file"
  if ! result="$(intake_priority_judge "$repo" "$issue_file" "$triage_state" false)"; then
    rm -f -- "$issue_file"
    echo "intake-priority: no adopted answer for issue #$issue_number" >&2
    return 0
  fi
  if jq -e '.status == "answered" and .adopted == true' <<< "$result" >/dev/null 2>&1; then
    if intake_priority_apply_result "$repo" "$issue_file" "$result"; then
      decision="$(jq -r '.decision | fromjson' <<< "$result")"
      priority="$(jq -r '.priority' <<< "$decision")"
      echo "intake-priority: applied issue=#$issue_number priority=$priority route=$(jq -r '.route' <<< "$decision")" >&2
      if [[ "$(jq -r '.needsTriage == true' <<< "$decision")" == true ]]; then
        printf 'needs-triage\n'
      fi
    else
      echo "intake-priority: label update failed for issue #$issue_number" >&2
    fi
  else
    echo "intake-priority: answer not adopted for issue #$issue_number" >&2
  fi
  rm -f -- "$issue_file"
}

usage() {
  echo 'usage: intake-priority.sh config | judge --repo <owner/name> --issue-file <json> [--triage-state <state>] [--dry-stub] | apply --repo <owner/name> --issue-file <json> --result-file <json> | triage <issue-number> <state> <owner/name>' >&2
}

mode="${1:-}"
shift || true
case "$mode" in
  config)
    [[ $# -eq 0 ]] || { usage; exit 64; }
    intake_priority_config
    ;;
  judge)
    repo="${REPO:-}" issue_file='' triage_state='' dry_stub=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo) [[ $# -ge 2 ]] || { usage; exit 64; }; repo="$2"; shift 2 ;;
        --issue-file) [[ $# -ge 2 ]] || { usage; exit 64; }; issue_file="$2"; shift 2 ;;
        --triage-state) [[ $# -ge 2 ]] || { usage; exit 64; }; triage_state="$2"; shift 2 ;;
        --dry-stub) dry_stub=true; shift ;;
        *) usage; exit 64 ;;
      esac
    done
    [[ -n "$repo" && -r "$issue_file" ]] || { usage; exit 64; }
    intake_priority_judge "$repo" "$issue_file" "$triage_state" "$dry_stub"
    ;;
  apply)
    repo="${REPO:-}" issue_file='' result_file=''
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo) [[ $# -ge 2 ]] || { usage; exit 64; }; repo="$2"; shift 2 ;;
        --issue-file) [[ $# -ge 2 ]] || { usage; exit 64; }; issue_file="$2"; shift 2 ;;
        --result-file) [[ $# -ge 2 ]] || { usage; exit 64; }; result_file="$2"; shift 2 ;;
        *) usage; exit 64 ;;
      esac
    done
    [[ -n "$repo" && -r "$issue_file" && -r "$result_file" ]] || { usage; exit 64; }
    intake_priority_apply_result "$repo" "$issue_file" "$(cat -- "$result_file")"
    ;;
  triage)
    [[ $# -eq 3 ]] || { usage; exit 64; }
    intake_priority_triage "$1" "$2" "$3"
    ;;
  *)
    usage
    exit 64
    ;;
esac
