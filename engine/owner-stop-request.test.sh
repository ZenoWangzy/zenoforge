#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(mktemp -d)"
trap 'rm -rf -- "$ROOT"' EXIT
STOP_RECORDER="$SCRIPT_DIR/owner-stop-request.sh"
FAKE_BIN="$ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SYSTEMCTL_CALL_LOG"
case "$*" in
  *"-p Result --value") printf '%s\n' "${SYSTEMD_RESULT:-success}" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$FAKE_BIN/systemctl"
for tool in ps kill pgrep pkill; do
  cat > "$FAKE_BIN/$tool" <<'EOF'
#!/usr/bin/env bash
touch "$FORBIDDEN_PROCESS_SCAN"
exit 99
EOF
  chmod +x "$FAKE_BIN/$tool"
done
export PATH="$FAKE_BIN:$PATH"
export SYSTEMCTL_CALL_LOG="$ROOT/systemctl.log" FORBIDDEN_PROCESS_SCAN="$ROOT/process-scan"

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "ok - $desc"
  else echo "not ok - $desc (expected [$expected], got [$actual])"; exit 1; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "ok - $desc"
  else echo "not ok - $desc (missing [$needle])"; exit 1; fi
}
new_manifest() {
  jq -n --arg log "$2" --arg unit "$3" \
    '{status:"running",pid:123,pid_start_ticks:"456",unit_name:$unit,log_file:$log}' > "$1"
  : > "$2"
}
assert_request_identity() {
  local desc="$1" manifest="$2"
  jq -e '.stop_request.requested_at | test("^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' \
    "$manifest" >/dev/null
  echo "ok - $desc records UTC request time"
  assert_eq "$desc records unit and PID identity" "$unit:123:456" \
    "$(jq -r '"\(.stop_request.unit_name):\(.stop_request.pid):\(.stop_request.pid_start_ticks)"' "$manifest")"
}
assert_before_term() {
  local log="$1" request_line term_line
  printf '%s TERM_SENT\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$log"
  request_line="$(grep -n 'owner-stop-request' "$log" | cut -d: -f1)"
  term_line="$(grep -n 'TERM_SENT' "$log" | cut -d: -f1)"
  [ "$request_line" -lt "$term_line" ] || { echo 'not ok - stop intent precedes TERM'; exit 1; }
  echo 'ok - stop intent precedes TERM'
}

unit=zf-node-owner-fixture.service
manifest="$ROOT/signature.json"
log="$ROOT/signature.log"
new_manifest "$manifest" "$log" "$unit"
"$STOP_RECORDER" "$manifest" "$log" "$unit" supervisor signature-changed >/dev/null
assert_eq 'signature stop records caller' supervisor "$(jq -r '.stop_request.caller' "$manifest")"
assert_eq 'signature stop records exact reason' signature-changed "$(jq -r '.stop_request.reason' "$manifest")"
assert_request_identity 'signature stop' "$manifest"
grep -Eq '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z owner-stop-request ' "$log"
assert_before_term "$log"
"$STOP_RECORDER" "$manifest" "$log" "$unit" UNKNOWN direct-signal >/dev/null
assert_eq 'later stop cannot overwrite first intent' signature-changed "$(jq -r '.stop_request.reason' "$manifest")"

manifest="$ROOT/pr-resolution.json"
log="$ROOT/pr-resolution.log"
new_manifest "$manifest" "$log" "$unit"
"$STOP_RECORDER" "$manifest" "$log" "$unit" supervisor pr-resolved >/dev/null
assert_eq 'PR resolution records distinct cause' pr-resolved "$(jq -r '.stop_request.reason' "$manifest")"
assert_request_identity 'PR resolution' "$manifest"
assert_before_term "$log"

manifest="$ROOT/operator.json"
log="$ROOT/operator.log"
new_manifest "$manifest" "$log" "$unit"
SYSTEMD_RESULT=success "$STOP_RECORDER" "$manifest" "$log" "$unit" >/dev/null
assert_eq 'external systemd stop keeps sender explicitly unknown' UNKNOWN "$(jq -r '.stop_request.caller' "$manifest")"
assert_eq 'external systemd stop records mechanism' external-systemd-stop "$(jq -r '.stop_request.reason' "$manifest")"
assert_request_identity 'external systemd stop' "$manifest"
assert_eq 'external systemd stop queries only its own unit' "--user show $unit -p Result --value" "$(tail -n 1 "$SYSTEMCTL_CALL_LOG")"
assert_before_term "$log"

manifest="$ROOT/completed.json"
log="$ROOT/completed.log"
new_manifest "$manifest" "$log" "$unit"
jq '.status="exited"' "$manifest" > "$manifest.tmp"
mv "$manifest.tmp" "$manifest"
SYSTEMD_RESULT=success "$STOP_RECORDER" "$manifest" "$log" "$unit" >/dev/null
assert_eq 'clean exit does not become a false stop request' null "$(jq -r '.stop_request // null' "$manifest")"

manifest="$ROOT/runtime-max.json"
log="$ROOT/runtime-max.log"
new_manifest "$manifest" "$log" "$unit"
SYSTEMD_RESULT=timeout "$STOP_RECORDER" "$manifest" "$log" "$unit" >/dev/null
assert_eq 'RuntimeMaxSec remains attributable to systemd' systemd "$(jq -r '.stop_request.caller' "$manifest")"
assert_eq 'RuntimeMaxSec has typed reason' runtime-max-sec "$(jq -r '.stop_request.reason' "$manifest")"

manifest="$ROOT/budget.json"
log="$ROOT/budget.log"
new_manifest "$manifest" "$log" "$unit"
jq '.stop_reason="budget-tokens" | .stop_requested_at="2026-10-12T00:00:00Z"' "$manifest" > "$manifest.tmp"
mv "$manifest.tmp" "$manifest"
"$STOP_RECORDER" "$manifest" "$log" "$unit" UNKNOWN direct-signal >/dev/null
assert_eq 'existing budget intent stays unchanged' supervisor "$(jq -r '.stop_request.caller' "$manifest")"
assert_eq 'budget reason survives signal trap' budget-tokens "$(jq -r '.stop_request.reason' "$manifest")"

[ ! -e "$FORBIDDEN_PROCESS_SCAN" ] || { echo 'not ok - helper scanned or killed processes'; exit 1; }
echo 'ALL PASSED'
