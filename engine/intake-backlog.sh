#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  echo 'usage: intake-backlog.sh --repo <owner/name> --output <report.json> [--limit N] [--concurrency N] [--apply] [--dry-stub]' >&2
}

repo="${REPO:-}"
output=''
limit=100
concurrency=4
apply=0
dry_stub=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || { usage; exit 64; }; repo="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || { usage; exit 64; }; output="$2"; shift 2 ;;
    --limit) [[ $# -ge 2 ]] || { usage; exit 64; }; limit="$2"; shift 2 ;;
    --concurrency) [[ $# -ge 2 ]] || { usage; exit 64; }; concurrency="$2"; shift 2 ;;
    --apply) apply=1; shift ;;
    --dry-stub) dry_stub=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done
[[ "$repo" == */* && -n "$output" ]] || { usage; exit 64; }
[[ "$limit" =~ ^[1-9][0-9]{0,3}$ ]] && (( limit <= 1000 )) || { echo 'intake-backlog: --limit must be between 1 and 1000' >&2; exit 64; }
[[ "$concurrency" =~ ^[1-9][0-9]*$ ]] && (( concurrency <= 8 )) || { echo 'intake-backlog: --concurrency must be between 1 and 8' >&2; exit 64; }
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
if [[ -z "${ZF_ROADMAP_TREE_CACHE_FILE:-}" || ! -r "$ZF_ROADMAP_TREE_CACHE_FILE" ]]; then
  export ZF_ROADMAP_SNAPSHOT_FILE="$temp_dir/roadmap.snapshot.json"
  if roadmap_fetch_tree "$temp_dir/roadmap.json" "$repo"; then
    export ZF_ROADMAP_TREE_CACHE_FILE="$temp_dir/roadmap.json"
  fi
fi

issues="$(gh issue list --repo "$repo" --state open --limit "$limit" --json number,title,body,labels)" || {
  echo 'intake-backlog: could not read open issues' >&2
  exit 1
}
jq -e 'type == "array" and all(.[]; (.number | type == "number" and . > 0) and (.title | type == "string"))' <<< "$issues" >/dev/null || {
  echo 'intake-backlog: invalid open issue response' >&2
  exit 1
}
mapfile -t issue_numbers < <(jq -r '.[].number' <<< "$issues")
while IFS= read -r issue_json; do
  number="$(jq -r '.number' <<< "$issue_json")"
  jq -c '.' <<< "$issue_json" > "$temp_dir/$number.issue.json"
done < <(jq -c '.[]' <<< "$issues")

run_issue_judge() {
  local number="$1"; shift
  local args=(judge --repo "$repo" --issue-file "$temp_dir/$number.issue.json")
  if (( dry_stub == 1 )); then args+=(--dry-stub); fi
  if ! bash "$SCRIPT_DIR/intake-priority.sh" "${args[@]}" > "$temp_dir/$number.result.json" 2> "$temp_dir/$number.log"; then
    printf '%s\n' '{"status":"fallback","adopted":false,"candidate":null,"confidence":null,"intake_context":{"duplicate_candidates":[],"roadmap_containers":[]}}' > "$temp_dir/$number.result.json"
  fi
}

pids=()
pending=0
for number in "${issue_numbers[@]}"; do
  run_issue_judge "$number" &
  pids+=("$!")
  pending=$((pending + 1))
  if (( pending >= concurrency )); then
    for pid in "${pids[@]}"; do wait "$pid" || true; done
    pids=()
    pending=0
  fi
done
for pid in "${pids[@]}"; do wait "$pid" || true; done

records='[]'
for number in "${issue_numbers[@]}"; do
  issue_json="$(cat -- "$temp_dir/$number.issue.json")"
  result="$(cat -- "$temp_dir/$number.result.json")"
  decision="$(jq -c '
    def decode: if type == "string" then try fromjson catch {} elif type == "object" then . else {} end;
    (.candidate // .decision // null) as $raw | if $raw == null then {} else ($raw | decode) end
  ' <<< "$result")"
  record="$(jq -cn --argjson issue "$issue_json" --argjson result "$result" --argjson decision "$decision" --argjson config "$config" '
    ($result.intake_context.duplicate_candidates // []) as $candidates
    | {number:$issue.number,title:$issue.title,
       priority:($decision.priority // $config.labels.needs_triage),
       route:($decision.route // "none-fits"),
       confidence:($result.confidence // null),
       adopted:($result.status == "answered" and $result.adopted == true),
       low_confidence:(($result.confidence == null) or ($result.confidence < $config.minimum_confidence)
         or ($decision.needsTriage == true)),
       duplicate:($decision.duplicate // false),
       duplicate_candidates:(if ($decision.duplicate // false) then
         [($decision.duplicateCandidates // [])[] as $number | $candidates[] | select(.number == $number) | {number,title}]
         else [] end),
       stale:($decision.stale // false)}
  ')"
  records="$(jq -cn --argjson rows "$records" --argjson record "$record" '$rows + [$record]')"
  if (( apply == 1 )); then
    bash "$SCRIPT_DIR/intake-priority.sh" apply --repo "$repo" --issue-file "$temp_dir/$number.issue.json" --result-file "$temp_dir/$number.result.json" \
      || echo "intake-backlog: label update failed for issue #$number" >&2
  fi
done

report="$(jq -cn --arg repo "$repo" --argjson limit "$limit" --argjson rows "$records" '
  ($rows | group_by(.priority) | map({key:.[0].priority,value:length}) | from_entries) as $priorities
  | ($rows | group_by(.route) | map({key:.[0].route,value:length}) | from_entries) as $routes
  | {repo:$repo,scanned:($rows | length),limit:$limit,
     priority_counts:$priorities,route_counts:$routes,
     duplicate_candidates:[$rows[] | select(.duplicate) | {issue:.number,title:.title,candidates:.duplicate_candidates}],
     stale_candidates:[$rows[] | select(.stale) | {issue:.number,title:.title}],
     low_confidence_count:([$rows[] | select(.low_confidence)] | length),
     issues:$rows}
')" || exit 1
output_dir="$(dirname -- "$output")"
mkdir -p -- "$output_dir"
report_temp="$output.tmp.$$"
printf '%s\n' "$report" | jq '.' > "$report_temp"
mv -f -- "$report_temp" "$output"
printf 'intake-backlog: report=%s scanned=%s apply=%s\n' "$output" "$(jq -r '.scanned' <<< "$report")" "$apply"
