#!/usr/bin/env bash
# Count masked log line shapes and file or update one issue per failing class (#999, slice of #390).
# shortcut: reads each log whole, so the caller passes a 24 h slice; upgrade when lines carry a usable timestamp filter.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../config.sh"
config="${ZF_LOG_SHAPE_CONFIG:-$(zf_config_file log-shapes.json || true)}"
if [[ -z "$config" ]] || ! jq -e 'type == "object"' "$config" >/dev/null 2>&1; then
  echo 'skip: log shape classes have no log-shapes.json configuration'
  exit 0
fi
threshold="$(jq -r '.threshold // 20' "$config")"
if [[ ! "$threshold" =~ ^[1-9][0-9]*$ ]]; then
  echo 'FAIL: log-shapes.json threshold must be a positive integer' >&2
  exit 2
fi

# signatures and allowlist match the masked shape, so write <n> for a number, never [0-9]+.
signatures=()
while IFS= read -r re; do signatures+=("$re"); done < <(jq -r '.signatures[]? // empty' "$config")
allowlist=()
while IFS= read -r re; do allowlist+=("$re"); done < <(jq -r '.allowlist[]? // empty' "$config")
for re in ${signatures[@]+"${signatures[@]}"} ${allowlist[@]+"${allowlist[@]}"}; do
  rc=0; printf '' | grep -E -- "$re" >/dev/null 2>&1 || rc=$?
  if (( rc == 2 )); then echo "FAIL: invalid regex in log-shapes.json: $re" >&2; exit 2; fi
done

# Numbers, hex ids and timestamps collapse so one failure gets one shape.
mask_shape() {
  sed -E \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.]+(Z|[+-][0-9:]+)?//g' \
    -e 's/[0-9a-fA-F]{12,}/<id>/g' \
    -e 's/[0-9]+(\.[0-9]+)?/<n>/g' \
    -e 's/^[[:space:]]+|[[:space:]]+$//g'
}

matches_any() {
  local shape="$1" re
  shift
  for re in ${1+"$@"}; do
    grep -E -q -- "$re" <<< "$shape" && return 0
  done
  return 1
}

# The public repo gets only the class id, count and log file names: raw shapes may carry paths, emails or tokens.
upsert_class() {
  local shape="$1" count="$2" id title list num state body
  id="cls-$(printf '%s' "$shape" | shasum -a 256 | cut -c1-12)"
  title="Repeated log shape $id"
  body="Class: $id
Count: $count occurrences in the last 24 h (threshold $threshold)
Logs: $log_names"
  list="$(gh issue list --repo "$ZF_GH_REPO" --state all --limit 50 --search "$id in:title" --json number,title,state)" || return 2
  read -r num state <<< "$(jq -r --arg id "$id" 'map(select(.title | contains($id))) | .[0] | "\(.number // "") \(.state // "")"' <<< "$list")"
  if [[ -z "$num" ]]; then
    gh issue create --repo "$ZF_GH_REPO" --title "$title" --body "$body" >/dev/null || return 2
  else
    if [[ "$state" == CLOSED ]]; then gh issue reopen "$num" --repo "$ZF_GH_REPO" >/dev/null || return 2; fi
    gh issue comment "$num" --repo "$ZF_GH_REPO" --body "Count $count occurrences in the last 24 h (threshold $threshold)." >/dev/null || return 2
  fi
}

# scheduler.log waits on #207 and stays out of this job.
log_files=()
log_names=""
for f in "$@"; do
  [[ "$(basename -- "$f")" == scheduler.log || ! -r "$f" ]] && continue
  log_files+=("$f")
  log_names="${log_names:+$log_names, }$(basename -- "$f")"
done
[[ ${#log_files[@]} -gt 0 ]] || exit 0

shapes="$(cat -- "${log_files[@]}" | mask_shape | grep -v '^$' | sort | uniq -c | sort -rn || true)"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  read -r count shape <<< "$line"
  (( count >= threshold )) || continue
  matches_any "$shape" ${allowlist[@]+"${allowlist[@]}"} && continue
  matches_any "$shape" ${signatures[@]+"${signatures[@]}"} || continue
  upsert_class "$shape" "$count" || exit 2
done <<< "$shapes"
