#!/usr/bin/env bash
set -euo pipefail

repo="${1:-${ZF_REPO:?ZF_REPO is not set}}"
per_page="${2:-20}"
timeout_seconds="${RELEASE_GH_TIMEOUT_SECONDS:-30}"
[[ "$per_page" =~ ^([1-9]|[1-9][0-9]|100)$ ]] || exit 64
deployments="$(timeout "$timeout_seconds" gh api "repos/$repo/deployments?environment=production&per_page=$per_page")" || exit 1
jq -e 'type == "array" and all(.[]; (.id | type == "number") and (.sha | type == "string" and test("^[0-9a-f]{40}$")) and ((.payload // {}) | type == "object"))' \
  <<< "$deployments" >/dev/null || exit 1

records='[]'
while IFS= read -r deployment; do
  [[ -n "$deployment" ]] || continue
  id="$(jq -r '.id' <<< "$deployment")"
  statuses="$(timeout "$timeout_seconds" gh api "repos/$repo/deployments/$id/statuses")" || exit 1
  jq -e 'type == "array" and all(.[]; (.state | type == "string"))' <<< "$statuses" >/dev/null || exit 1
  # The NEWEST status decides whether a record is current production: a
  # rolled-back release posts `inactive` after its success status, and the
  # newest success would otherwise keep serving a SHA whose images were rolled
  # back as the next release's baseline (release 4061, #4293).
  latest="$(jq -c 'max_by(.created_at // "") // empty' <<< "$statuses")"
  [[ -n "$latest" ]] || continue
  jq -e '.state == "success"' <<< "$latest" >/dev/null || continue
  record="$(jq -cn --argjson deployment "$deployment" --argjson status "$latest" \
    '{id:$deployment.id,sha:$deployment.sha,created_at:$deployment.created_at,success_at:$status.created_at,payload:($deployment.payload // {})}')"
  records="$(jq -cn --argjson records "$records" --argjson record "$record" '$records + [$record]')"
done < <(jq -c '.[]' <<< "$deployments")

printf '%s\n' "$records"
