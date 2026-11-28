#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

EFFECT_LOG="$TMP_DIR/effect-call"
CLAIM_LOG="$TMP_DIR/effect-claim"
GMAIL_CALL_LOG="$TMP_DIR/gmail-call"
EXPECTED_EFFECT_KEY='mail:9301:8effd3366908397e762055325b278962bd77c68b'

effect_claim_for() {
  printf '%s\0' "$1" > "$CLAIM_LOG"
  printf 'claim-123'
}

effect_run() {
  printf '%s\0' "$@" > "$EFFECT_LOG"
  [[ "$3" == mail && "$4" == -- ]] || return 94
  "$5" "$6" "$7"
}

gmail_curl() {
  printf '%s\0' "$@" > "$GMAIL_CALL_LOG"
  printf 'accepted\n202'
}

source "$SCRIPT_DIR/notify-effects.sh"
ZF_COORD=on
REPO_DIR="$MODEL_POLICY_TEST_REPO"
GMAIL_TIMEOUT_SECONDS=15
GMAIL_SEND_URL=https://gmail.googleapis.com/gmail/v1/users/me/messages/send
payload_file="$TMP_DIR/payload.json"
printf '{"raw":"fixture"}' > "$payload_file"

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  [[ "$actual" == "$expected" ]] || {
    printf '%s: expected %q, got %q\n' "$name" "$expected" "$actual" >&2
    exit 1
  }
}

if _notify_strict_effect_send_request 'Test subject' 'Test body' 'to@example.test' 9301 notice test-token "$payload_file"; then
  :
else
  status=$?
  printf 'strict notification effect failed with status %s\n' "$status" >&2
  exit 1
fi

assert_eq setup-failed 0 "$NOTIFY_EFFECT_SETUP_FAILED"
assert_eq effect-output $'accepted\n202' "$NOTIFY_EFFECT_RAW"

readarray -d '' -t actual_claim < "$CLAIM_LOG"
assert_eq effect-claim "$EXPECTED_EFFECT_KEY" "${actual_claim[0]}"

readarray -d '' -t actual_effect < "$EFFECT_LOG"
expected_effect=(claim-123 "$EXPECTED_EFFECT_KEY" mail -- _notify_gmail_send_request test-token "$payload_file")
assert_eq effect-call "${expected_effect[*]}" "${actual_effect[*]}"

readarray -d '' -t actual_request < "$GMAIL_CALL_LOG"
expected_request=(test-token -sS --max-time 15 -X POST "$GMAIL_SEND_URL" -H 'Content-Type: application/json' --data-binary "@$payload_file" -w '\n%{http_code}')
assert_eq gmail-request "${expected_request[*]}" "${actual_request[*]}"

printf 'notify-effects.test.sh: PASS\n'
