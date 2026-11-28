#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

EFFECT_LOG="$TMP_DIR/effect-call"
CLAIM_LOG="$TMP_DIR/effect-claim"
CURL_ARGS_LOG="$TMP_DIR/curl-args"
CURL_AUTH_LOG="$TMP_DIR/curl-auth"
EXPECTED_EFFECT_KEY='mail:unclassified:8effd3366908397e762055325b278962bd77c68b'

ZF_CONFIG_ROOT="$TMP_DIR/.zenoforge"
mkdir -p "$ZF_CONFIG_ROOT/prompts" "$TMP_DIR/bin"
cp "$SCRIPT_DIR/prompts/founder-outcome.schema.json" "$ZF_CONFIG_ROOT/prompts/founder-outcome.schema.json"
cp "$SCRIPT_DIR/prompts/agent-settings.json" "$ZF_CONFIG_ROOT/prompts/agent-settings.json"
ZF_COORD=on
REPO_DIR="$MODEL_POLICY_TEST_REPO"
export ZF_CONFIG_ROOT ZF_COORD
source "$SCRIPT_DIR/notify.sh"
source "$SCRIPT_DIR/notify-effects.sh"

effect_claim_for() {
  printf '%s\0' "$1" > "$CLAIM_LOG"
  printf 'claim-123'
}

effect_run() {
  printf '%s\0' "$@" > "$EFFECT_LOG"
  [[ "$3" == mail && "$4" == -- ]] || return 94
  [[ -f "$7" ]] || return 95
  "$5" "$6" "$7"
}

DRY_RUN=0
NOTIFY_LOG_FILE="$TMP_DIR/notify.log"
ZF_GCLOUD_BIN="$TMP_DIR/bin/gcloud"
export NOTIFY_LOG_FILE ZF_GCLOUD_BIN CURL_ARGS_LOG CURL_AUTH_LOG

cat > "$ZF_GCLOUD_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'fake-token'
EOF
cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$CURL_ARGS_LOG"
cat > "$CURL_AUTH_LOG"
printf '%s\n' '{"id":"message-123","threadId":"thread-1"}' 200
EOF
chmod +x "$ZF_GCLOUD_BIN" "$TMP_DIR/bin/curl"
PATH="$TMP_DIR/bin:$PATH"
export PATH

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  [[ "$actual" == "$expected" ]] || {
    printf '%s: expected %q, got %q\n' "$name" "$expected" "$actual" >&2
    exit 1
  }
}

if send_output="$(send_email_strict 'Test subject' 'Test body' to@example.test 2>"$TMP_DIR/send.stderr")"; then
  :
else
  status=$?
  printf 'strict notification send failed with status %s: %s\n' "$status" "$(cat "$TMP_DIR/send.stderr")" >&2
  exit 1
fi

assert_eq message-id message-123 "$send_output"

readarray -d '' -t actual_claim < "$CLAIM_LOG"
assert_eq effect-claim "$EXPECTED_EFFECT_KEY" "${actual_claim[0]}"

readarray -d '' -t actual_effect < "$EFFECT_LOG"
assert_eq effect-claim-id claim-123 "${actual_effect[0]}"
assert_eq effect-key "$EXPECTED_EFFECT_KEY" "${actual_effect[1]}"
assert_eq effect-kind mail "${actual_effect[2]}"
assert_eq effect-command-separator -- "${actual_effect[3]}"
assert_eq effect-request-helper _notify_gmail_send_request "${actual_effect[4]}"
assert_eq access-token fake-token "${actual_effect[5]}"
[[ ${#actual_effect[@]} == 7 && -n "${actual_effect[6]}" ]]

readarray -d '' -t actual_request < "$CURL_ARGS_LOG"
expected_request=(--config - -sS --max-time 15 -X POST "$GMAIL_SEND_URL" -H 'Content-Type: application/json' --data-binary "@${actual_effect[6]}" -w '\n%{http_code}')
assert_eq gmail-request "${expected_request[*]}" "${actual_request[*]}"
assert_eq gmail-auth-header 'header = "Authorization: Bearer fake-token"' "$(cat "$CURL_AUTH_LOG")"

printf 'notify-effects.test.sh: PASS\n'
