#!/usr/bin/env bash
set -euo pipefail

repo="${1:-${ZF_REPO:?ZF_REPO is not set}}"
per_page="${2:-20}"
timeout_seconds="${RELEASE_GH_TIMEOUT_SECONDS:-30}"
[[ "$per_page" =~ ^([1-9]|[1-9][0-9]|100)$ ]] || exit 64
deployments="$(timeout "$timeout_seconds" gh api "repos/$repo/deployments?environment=production&per_page=$per_page")" || exit 1
jq -e 'type == "array" and all(.[]; (.id | type == "number") and (.sha | type == "string" and test("^[0-9a-f]{40}$")) and ((.payload // {}) | type == "object"))' \
  <<< "$deployments" >/dev/null || exit 1

tmpdir="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$tmpdir"' EXIT
records_file="$tmpdir/records.jsonl"
latest_file="$tmpdir/latest-status.json"
status_cache_dir="${ZF_PRODUCTION_DEPLOYMENT_CACHE_DIR:-}"
status_cache_repo="$(printf '%s' "$repo" | cksum | awk '{print $1}')"
if [[ -n "$status_cache_dir" ]] && ! mkdir -p -- "$status_cache_dir"; then status_cache_dir=""; fi
: > "$records_file"
while IFS= read -r deployment; do
  [[ -n "$deployment" ]] || continue
  id="$(jq -r '.id' <<< "$deployment")"
  status_cache_file=""
  if [[ -n "$status_cache_dir" ]]; then status_cache_file="$status_cache_dir/$status_cache_repo-$id.json"; fi
  if [[ -n "$status_cache_file" && -f "$status_cache_file" ]]; then
    statuses="$(cat "$status_cache_file")"
    jq -e 'type == "object" and .reader_failed == true' <<< "$statuses" >/dev/null && exit 1
  else
    if ! statuses="$(timeout "$timeout_seconds" gh api "repos/$repo/deployments/$id/statuses")"; then
      if [[ -n "$status_cache_file" ]]; then printf '{"reader_failed":true}\n' > "$status_cache_file.tmp.$BASHPID" && mv -f -- "$status_cache_file.tmp.$BASHPID" "$status_cache_file"; fi
      exit 1
    fi
    if [[ -n "$status_cache_file" ]]; then printf '%s\n' "$statuses" > "$status_cache_file.tmp.$BASHPID" && mv -f -- "$status_cache_file.tmp.$BASHPID" "$status_cache_file"; fi
  fi
  jq -e 'type == "array" and all(.[]; (.state | type == "string"))' <<< "$statuses" >/dev/null || exit 1
  # The NEWEST status decides whether a record is current production: a
  # rolled-back release posts `inactive` after its success status, and the
  # newest success would otherwise keep serving a SHA whose images were rolled
  # back as the next release's baseline (release 4061, #4293).
  jq -c 'max_by(.created_at // "") // empty' <<< "$statuses" > "$latest_file"
  [[ -s "$latest_file" ]] || continue
  jq -e '.state == "success"' "$latest_file" >/dev/null || continue
  jq -c --slurpfile status "$latest_file" \
    '{id,sha,created_at,success_at:$status[0].created_at,payload:(.payload // {})}' \
    <<< "$deployment" >> "$records_file"
done < <(jq -c '.[]' <<< "$deployments")

jq -cs '.' "$records_file"
