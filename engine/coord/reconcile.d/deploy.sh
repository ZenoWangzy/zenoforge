#!/usr/bin/env bash
set -euo pipefail
effect_key="${2:-}"
[[ "$effect_key" =~ ^deploy:([A-Za-z0-9._-]+)$ ]] || exit 3
release_seq="${BASH_REMATCH[1]}"
engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
deployments="$(bash "$engine_dir/production-deployment-read.sh" "${REPO:-${ZF_REPO:?ZF_REPO is not set}}")" || exit 3
jq -e 'type == "array"' <<<"$deployments" >/dev/null || exit 3
deployment="$(jq -c --arg seq "$release_seq" \
  '[.[] | select(((.payload.release_seq // "") | tostring) == $seq or ((.id // "") | tostring) == $seq)] | first // empty' \
  <<<"$deployments")" || exit 3
[[ -n "$deployment" ]] || exit 2
jq -cn --argjson deployment "$deployment" \
  '{deployment_id:$deployment.id,sha:$deployment.sha,success_at:$deployment.success_at}'
