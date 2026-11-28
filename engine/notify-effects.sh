#!/usr/bin/env bash

if ! declare -F effect_run >/dev/null; then
  source "$(dirname -- "${BASH_SOURCE[0]}")/config.sh"
  coord_source_if_enabled
fi

_notify_gmail_send_request() {
  local token="$1" payload_file="$2"
  gmail_curl "$token" -sS --max-time "$GMAIL_TIMEOUT_SECONDS" -X POST "$GMAIL_SEND_URL" \
    -H "Content-Type: application/json" \
    --data-binary @"$payload_file" \
    -w '\n%{http_code}' 2>&1
}

_notify_strict_effect_send_request() {
  local subject="$1" body="$2" to_header="$3" issue_marker="$4" maintainer_kind="$5"
  local token="$6" payload_file="$7" effect_id effect_key effect_claim
  NOTIFY_EFFECT_RAW=""
  NOTIFY_EFFECT_SETUP_FAILED=0
  if [[ "${ZF_COORD:-off}" == on ]]; then
    effect_id="$(printf '%s\0%s\0%s' "$subject" "$body" "$to_header" \
      | git -C "${REPO_DIR:-$ZF_REPO_DIR}" hash-object --stdin)" || {
      NOTIFY_EFFECT_SETUP_FAILED=1
      return 3
    }
  else
    effect_id=off
  fi
  effect_key="mail:${issue_marker:-$maintainer_kind}:$effect_id"
  effect_claim="$(effect_claim_for "$effect_key")" || {
    NOTIFY_EFFECT_SETUP_FAILED=1
    return 3
  }
  if NOTIFY_EFFECT_RAW="$(effect_run "$effect_claim" "$effect_key" mail -- _notify_gmail_send_request "$token" "$payload_file")"; then
    return 0
  else
    return $?
  fi
}
