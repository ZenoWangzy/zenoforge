#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR" "$test_env_root"' EXIT

CURL_ARGS_LOG="$TMP_DIR/curl-args"
CURL_AUTH_LOG="$TMP_DIR/curl-auth"
EXPECTED_EFFECT_KEY='mail:unclassified:8effd3366908397e762055325b278962bd77c68b'
EXPECTED_EFFECT_CLAIM='effect-mail-unclassified-8effd3366908397e762055325b278962bd77c68b'

ZF_CONFIG_ROOT="$TMP_DIR/.zenoforge"
mkdir -p "$ZF_CONFIG_ROOT/prompts" "$TMP_DIR/bin" "$TMP_DIR/repo"
cp "$SCRIPT_DIR/prompts/founder-outcome.schema.json" "$ZF_CONFIG_ROOT/prompts/founder-outcome.schema.json"
cp "$SCRIPT_DIR/prompts/agent-settings.json" "$ZF_CONFIG_ROOT/prompts/agent-settings.json"
ZF_COORD=on
REPO_DIR="$TMP_DIR/repo"
ZF_REPO_DIR="$REPO_DIR"
git init -q --bare "$TMP_DIR/remote.git"
git -C "$REPO_DIR" init -q -b main
git -C "$REPO_DIR" config user.name fixture
git -C "$REPO_DIR" config user.email fixture@example.invalid
git -C "$REPO_DIR" commit --allow-empty -qm fixture
git -C "$REPO_DIR" remote add origin "$TMP_DIR/remote.git"
git -C "$REPO_DIR" push -q -u origin main
export ZF_CONFIG_ROOT ZF_COORD ZF_REPO_DIR
source "$SCRIPT_DIR/notify.sh"
source "$SCRIPT_DIR/notify-effects.sh"
source "$SCRIPT_DIR/lib.d/transport.sh"
GIT_FETCH_TIMEOUT_SEC=60
effect_owner="$(coord_new_owner)"
coord_acquire "$EXPECTED_EFFECT_CLAIM" "$effect_owner" effect "$EXPECTED_EFFECT_KEY" effect-mail effect
ZF_COORD_OWNER="$effect_owner"

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

claim_record="$(coord_read "$EXPECTED_EFFECT_CLAIM")"
jq -e --arg key "$EXPECTED_EFFECT_KEY" '
  .intents[$key].kind == "mail" and .intents[$key].state == "done"
  and (.intents[$key].result.stdout | contains("message-123"))
' <<<"$claim_record" >/dev/null || {
  printf 'mail intent was not completed in the coordinator record: %s\n' "$claim_record" >&2
  exit 1
}
coord_release "$EXPECTED_EFFECT_CLAIM" "$effect_owner"

readarray -d '' -t actual_request < "$CURL_ARGS_LOG"
[[ ${#actual_request[@]} == 14 && "${actual_request[11]}" == @* ]]
expected_request=(--config - -sS --max-time 15 -X POST "$GMAIL_SEND_URL" -H 'Content-Type: application/json' --data-binary "${actual_request[11]}" -w '\n%{http_code}')
assert_eq gmail-request "${expected_request[*]}" "${actual_request[*]}"
assert_eq gmail-auth-header 'header = "Authorization: Bearer fake-token"' "$(cat "$CURL_AUTH_LOG")"

printf 'notify-effects.test.sh: PASS\n'
