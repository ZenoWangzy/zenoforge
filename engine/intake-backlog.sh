#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  echo 'usage: intake-backlog.sh --repo <owner/name> --output <report.json> [--limit N] [--concurrency N] [--rate-floor N] [--apply] [--dry-stub] [--skip-labelled]' >&2
}

repo="${REPO:-}"
output=''
limit=100
concurrency=4
rate_floor=1500
apply=0
dry_stub=0
skip_labelled=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || { usage; exit 64; }; repo="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || { usage; exit 64; }; output="$2"; shift 2 ;;
    --limit) [[ $# -ge 2 ]] || { usage; exit 64; }; limit="$2"; shift 2 ;;
    --concurrency) [[ $# -ge 2 ]] || { usage; exit 64; }; concurrency="$2"; shift 2 ;;
    --rate-floor) [[ $# -ge 2 ]] || { usage; exit 64; }; rate_floor="$2"; shift 2 ;;
    --apply) apply=1; shift ;;
    --dry-stub) dry_stub=1; shift ;;
    --skip-labelled) skip_labelled=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done
[[ "$repo" == */* && -n "$output" ]] || { usage; exit 64; }
[[ "$limit" =~ ^[1-9][0-9]{0,3}$ ]] && (( limit <= 1000 )) || { echo 'intake-backlog: --limit must be between 1 and 1000' >&2; exit 64; }
[[ "$concurrency" =~ ^[1-9][0-9]*$ ]] && (( concurrency <= 8 )) || { echo 'intake-backlog: --concurrency must be between 1 and 8' >&2; exit 64; }
[[ "$rate_floor" =~ ^[0-9]{1,9}$ ]] || { echo 'intake-backlog: --rate-floor must be a non-negative integer' >&2; exit 64; }
rate_floor=$((10#$rate_floor))
if (( dry_stub == 1 && apply == 1 )); then
  echo 'intake-backlog: --apply cannot be combined with --dry-stub' >&2
  exit 64
fi

config="$(bash "$SCRIPT_DIR/intake-priority.sh" config)" || { echo 'intake-backlog: invalid intake priority config' >&2; exit 78; }
if [[ "$(jq -r '.enabled' <<< "$config")" != true && "$dry_stub" != 1 ]]; then
  echo 'intake-backlog: intake_priority.enabled is false; refusing backlog run' >&2
  exit 78
fi
if (( dry_stub == 1 )); then
  [[ -n "${ZF_TS_JUDGE_SCRIPT:-}" && -x "$ZF_TS_JUDGE_SCRIPT" ]] || { echo 'intake-backlog: --dry-stub requires an executable ZF_TS_JUDGE_SCRIPT' >&2; exit 64; }
elif [[ -z "${TYPESAFE_API_KEY:-}${TYPESAFE_ENV_FILE:-}" ]]; then
  echo 'intake-backlog: TypeSafe key is not configured' >&2
  exit 78
fi

temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"' EXIT
rate_limit_signal="$temp_dir/rate-limit.signal"
rate_limit_cache="$temp_dir/rate-limit.cache"
rate_limit_cache_lock="$temp_dir/rate-limit-cache.lock"
export ZF_INTAKE_RATE_LIMIT_SIGNAL="$rate_limit_signal"
records_file="$temp_dir/records.jsonl"
: > "$records_file"
partial=false
stop_reason=''

write_report() {
  local report output_dir report_temp
  report="$(jq -cn --arg repo "$repo" --argjson limit "$limit" --argjson partial "$partial" \
    --arg stop_reason "$stop_reason" --slurpfile rows "$records_file" '
    ($rows | group_by(.priority) | map({key:.[0].priority,value:length}) | from_entries) as $priorities
    | ($rows | group_by(.route) | map({key:.[0].route,value:length}) | from_entries) as $routes
    | {repo:$repo,scanned:($rows | length),limit:$limit,partial:$partial,
       stop_reason:(if $partial then $stop_reason else null end),
       priority_counts:$priorities,route_counts:$routes,
       duplicate_candidates:[$rows[] | select(.duplicate) | {issue:.number,title:.title,candidates:.duplicate_candidates}],
       stale_candidates:[$rows[] | select(.stale) | {issue:.number,title:.title}],
       low_confidence_count:([$rows[] | select(.low_confidence)] | length),
       issues:$rows}
  ')" || return 1
  output_dir="$(dirname -- "$output")"
  mkdir -p -- "$output_dir"
  report_temp="$output.tmp.$$"
  printf '%s\n' "$report" | jq '.' > "$report_temp"
  mv -f -- "$report_temp" "$output"
}

intake_backlog_rate_allows_apply() {
  local lock_fd='' now='' checked_at='' response='' cache_temp='' core='' graphql='' rc=0
  [[ ! -e "$rate_limit_signal" ]] || return 1
  exec {lock_fd}>"$rate_limit_cache_lock" || return 1
  if ! flock -x "$lock_fd"; then
    exec {lock_fd}>&-
    return 1
  fi
  now="$(date +%s)" || rc=1
  if (( rc == 0 )) && [[ -s "$rate_limit_cache" ]]; then
    checked_at="$(jq -er '.checked_at | select(type == "number")' "$rate_limit_cache" 2>/dev/null || true)"
    if [[ "$checked_at" =~ ^[0-9]+$ ]] && (( now >= checked_at && now - checked_at < 30 )); then
      response="$(jq -c '.response' "$rate_limit_cache" 2>/dev/null || true)"
    fi
  fi
  if (( rc == 0 )) && [[ -z "$response" ]]; then
    if ! response="$(gh api rate_limit 2>&1)"; then
      if [[ "$response" == *'API rate limit already exceeded'* ]]; then
        printf 'intake-backlog: %s\n' "$response" >&2
        printf 'rate-limit\n' > "$rate_limit_signal"
      else
        printf 'intake-backlog: rate-limit check failed: %s\n' "${response//$'\n'/; }" >&2
        printf 'rate-check-failed\n' > "$rate_limit_signal"
      fi
      rc=1
    elif ! jq -e 'type == "object"
      and (.resources.core.remaining | type == "number" and . >= 0 and floor == .)
      and (.resources.graphql.remaining | type == "number" and . >= 0 and floor == .)' <<< "$response" >/dev/null; then
      echo 'intake-backlog: invalid gh api rate_limit response' >&2
      printf 'rate-check-failed\n' > "$rate_limit_signal"
      rc=1
    else
      cache_temp="$rate_limit_cache.tmp.$$"
      if jq -cn --argjson checked_at "$now" --argjson response "$response" \
        '{checked_at:$checked_at,response:$response}' > "$cache_temp" \
        && mv -f -- "$cache_temp" "$rate_limit_cache"; then
        :
      else
        rm -f -- "$cache_temp"
        echo 'intake-backlog: could not cache gh api rate_limit response' >&2
        printf 'rate-check-failed\n' > "$rate_limit_signal"
        rc=1
      fi
    fi
  fi
  if (( rc == 0 )); then
    core="$(jq -er '.resources.core.remaining | select(type == "number")' <<< "$response")" || rc=1
    graphql="$(jq -er '.resources.graphql.remaining | select(type == "number")' <<< "$response")" || rc=1
    if (( rc == 0 && (core < rate_floor || graphql < rate_floor) )); then
      printf 'intake-backlog: rate floor reached (core=%s graphql=%s floor=%s)\n' \
        "$core" "$graphql" "$rate_floor" >&2
      printf 'rate-limit\n' > "$rate_limit_signal"
      rc=1
    fi
  fi
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  return "$rc"
}

if [[ -z "${ZF_ROADMAP_TREE_CACHE_FILE:-}" || ! -r "$ZF_ROADMAP_TREE_CACHE_FILE" ]]; then
  export ZF_ROADMAP_SNAPSHOT_FILE="$temp_dir/roadmap.snapshot.json"
  if roadmap_fetch_tree "$temp_dir/roadmap.json" "$repo" > "$temp_dir/roadmap.log" 2>&1; then
    export ZF_ROADMAP_TREE_CACHE_FILE="$temp_dir/roadmap.json"
  else
    cat "$temp_dir/roadmap.log" >&2
    if grep -Fq 'API rate limit already exceeded' "$temp_dir/roadmap.log"; then
      partial=true
      stop_reason=rate-limit
    fi
  fi
fi
if [[ "$stop_reason" == rate-limit ]]; then
  echo 'intake-backlog: API rate limit exceeded; writing partial report' >&2
  write_report || exit 1
  printf 'intake-backlog: report=%s scanned=0 apply=%s partial=true\n' "$output" "$apply"
  exit 0
fi

if ! issues="$(gh issue list --repo "$repo" --state open --limit "$limit" --json number,title,body,labels 2> "$temp_dir/issue-list.log")"; then
  cat "$temp_dir/issue-list.log" >&2
  if grep -Fq 'API rate limit already exceeded' "$temp_dir/issue-list.log"; then
    partial=true
    stop_reason=rate-limit
    echo 'intake-backlog: API rate limit exceeded; writing partial report' >&2
    write_report || exit 1
    printf 'intake-backlog: report=%s scanned=0 apply=%s partial=true\n' "$output" "$apply"
    exit 0
  fi
  echo 'intake-backlog: could not read open issues' >&2
  exit 1
fi
jq -e 'type == "array" and all(.[]; (.number | type == "number" and . > 0) and (.title | type == "string"))' <<< "$issues" >/dev/null || {
  echo 'intake-backlog: invalid open issue response' >&2
  exit 1
}
jq -c --argjson skip_labelled "$skip_labelled" '
  def has_priority_label:
    [(.labels // [])[] | if type == "string" then . else .name // "" end]
    | any(startswith("priority:"));
  [.[] | select(($skip_labelled != 1) or (has_priority_label | not))]
' <<< "$issues" > "$temp_dir/selected-issues.json"
mapfile -t issue_numbers < <(jq -r '.[].number' "$temp_dir/selected-issues.json")
while IFS= read -r issue_json; do
  number="$(jq -r '.number' <<< "$issue_json")"
  jq -c '.' <<< "$issue_json" > "$temp_dir/$number.issue.json"
done < <(jq -c '.[]' "$temp_dir/selected-issues.json")

run_issue() {
  local number="$1" status status_temp
  local args=(judge --repo "$repo" --issue-file "$temp_dir/$number.issue.json")
  if [[ ! -e "$rate_limit_signal" ]]; then
    if (( dry_stub == 1 )); then args+=(--dry-stub); fi
    if ! bash "$SCRIPT_DIR/intake-priority.sh" "${args[@]}" > "$temp_dir/$number.result.json" 2> "$temp_dir/$number.log"; then
      printf '%s\n' '{"status":"fallback","adopted":false,"candidate":null,"confidence":null,"intake_context":{"duplicate_candidates":[],"roadmap_containers":[]}}' > "$temp_dir/$number.result.json"
    fi
    if grep -Fq 'API rate limit already exceeded' "$temp_dir/$number.log"; then
      printf 'rate-limit\n' > "$rate_limit_signal"
    fi
    if (( apply == 1 )) && [[ ! -e "$rate_limit_signal" ]] \
      && ! grep -Fq 'API rate limit already exceeded' "$temp_dir/$number.log"; then
      if intake_backlog_rate_allows_apply; then
        if ! bash "$SCRIPT_DIR/intake-priority.sh" apply --repo "$repo" --issue-file "$temp_dir/$number.issue.json" \
          --result-file "$temp_dir/$number.result.json" >> "$temp_dir/$number.log" 2>&1; then
          if grep -Fq 'API rate limit already exceeded' "$temp_dir/$number.log"; then
            printf 'rate-limit\n' > "$rate_limit_signal"
          else
            printf 'intake-backlog: label update failed for issue #%s\n' "$number" >&2
          fi
        fi
      fi
    fi
  fi
  status=done
  if grep -Fq 'API rate limit already exceeded' "$temp_dir/$number.log"; then status=rate-limit; fi
  if [[ -e "$rate_limit_signal" ]]; then status=rate-limit; fi
  status_temp="$temp_dir/$number.status.tmp.$$"
  printf '%s\n' "$status" > "$status_temp"
  mv -f -- "$status_temp" "$temp_dir/$number.status"
}

active_pids=()
active_numbers=()
next_issue=0
rate_limited=0
while (( next_issue < ${#issue_numbers[@]} || ${#active_pids[@]} > 0 )); do
  while (( rate_limited == 0 && next_issue < ${#issue_numbers[@]} && ${#active_pids[@]} < concurrency )) \
    && [[ ! -e "$rate_limit_signal" ]]; do
    number="${issue_numbers[$next_issue]}"
    run_issue "$number" &
    active_pids+=("$!")
    active_numbers+=("$number")
    next_issue=$((next_issue + 1))
  done
  if (( ${#active_pids[@]} == 0 )); then break; fi
  completed=0
  [[ -e "$rate_limit_signal" ]] && rate_limited=1
  remaining_pids=()
  remaining_numbers=()
  for index in "${!active_pids[@]}"; do
    pid="${active_pids[$index]}"
    number="${active_numbers[$index]}"
    status_file="$temp_dir/$number.status"
    if [[ -s "$status_file" ]]; then
      wait "$pid" || true
      completed=1
      if [[ "$(cat -- "$status_file")" == rate-limit ]]; then rate_limited=1; fi
    else
      remaining_pids+=("$pid")
      remaining_numbers+=("$number")
    fi
  done
  active_pids=("${remaining_pids[@]}")
  active_numbers=("${remaining_numbers[@]}")
  if (( completed == 0 && ${#active_pids[@]} > 0 )); then sleep 0.2; fi
done

for number in "${issue_numbers[@]}"; do
  [[ -r "$temp_dir/$number.result.json" && -r "$temp_dir/$number.issue.json" ]] || continue
  result="$(cat -- "$temp_dir/$number.result.json")"
  decision="$(jq -c '
    def decode: if type == "string" then try fromjson catch {} elif type == "object" then . else {} end;
    (.candidate // .decision // null) as $raw | if $raw == null then {} else ($raw | decode) end
  ' <<< "$result")"
  printf '%s' "$decision" > "$temp_dir/$number.decision.json"
  record="$(jq -cn --slurpfile issue_rows "$temp_dir/$number.issue.json" --argjson result "$result" --slurpfile decision_rows "$temp_dir/$number.decision.json" --argjson config "$config" '
    $issue_rows[0] as $issue | $decision_rows[0] as $decision
    | ($result.intake_context.duplicate_candidates // []) as $candidates
    | {number:$issue.number,title:$issue.title,
       priority:($decision.priority // $config.labels.needs_triage),
       overlay:($decision.overlay // $result.overlay // null),
       route:($decision.route // "none-fits"),
       confidence:($result.confidence // null),
       adopted:($result.status == "answered" and $result.adopted == true),
       low_confidence:(($result.confidence == null) or ($result.confidence < $config.minimum_confidence)
         or ($decision.unsure != null)),
       duplicate:($decision.duplicate // false),
       duplicate_candidates:(if ($decision.duplicate // false) then
         [($decision.duplicateCandidates // [])[] as $number | $candidates[] | select(.number == $number) | {number,title}]
         else [] end),
       stale:($decision.stale // false)}
  ')"
  printf '%s\n' "$record" >> "$records_file"
done

if (( rate_limited == 1 )) || [[ -e "$rate_limit_signal" ]]; then
  partial=true
  stop_reason="$(cat -- "$rate_limit_signal" 2>/dev/null || true)"
  [[ -n "$stop_reason" ]] || stop_reason=rate-limit
  echo 'intake-backlog: rate guard stopped the pass; writing partial report' >&2
fi
write_report || exit 1
printf 'intake-backlog: report=%s scanned=%s apply=%s partial=%s\n' \
  "$output" "$(jq -r '.scanned' "$output")" "$apply" "$partial"
